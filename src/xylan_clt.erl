%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2014, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2014, Tony Rogvall
%%% @doc
%%%    Proxy wedding client,
%%% @end
%%% Created : 18 Dec 2014 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(xylan_clt).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(DEFAULT_CNTL_PORT, 29390).   %% client proxy control port
-define(DEFAULT_DATA_PORT, 29391).   %% client proxy data port
-define(DEFAULT_PONG_TIMEOUT, 3000).
-define(DEFAULT_PING_INTERVAL, 20000).
-define(DEFAULT_RECONNECT_INTERVAL, 5000).
-define(DEFAULT_AUTH_TIMEOUT, 3000).

-include_lib("lager/include/log.hrl").
-include_lib("xylan_socket.hrl").

-type timer() :: reference().

-record(state,
	{
	  id :: string(),  %% client id
	  tag = tcp,
	  tag_closed = tcp_closed,
	  tag_error  = tcp_error,
	  server_sock :: xylan_socket(),  %% user listen socket
	  server_ip   :: inet:ip_address(),
	  server_port :: integer(),
	  server_chal :: binary(),
	  server_auth = false :: boolean(),
	  auth_timeout = ?DEFAULT_AUTH_TIMEOUT :: timeout(),
	  auth :: timer(),
	  server_id  = "",
	  server_key  :: binary(),
	  client_key  :: binary(),
	  ping_interval = ?DEFAULT_PING_INTERVAL :: timeout(),
	  pong_timeout  = ?DEFAULT_PONG_TIMEOUT  :: timeout(),
	  reconnect_interval = ?DEFAULT_RECONNECT_INTERVAL :: timeout(),
	  user_list = [] :: [{pid(),reference(),binary()}], %% user sessions
	  reconnect :: reference(),  %% reconnect timer
	  ping :: reference(),   %% when to send next ping, control channel
	  pong :: reference(),   %% wdt timer for pong
	  route = []
	}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Options) ->
    ID = proplists:get_value(id,Options,""),  %% reject if not set ?
    IP = proplists:get_value(server_ip,Options,"127.0.0.1"),
    Port = proplists:get_value(server_port,Options,?DEFAULT_CNTL_PORT),
    Route = proplists:get_value(route,Options,[]),
    PingInterval = proplists:get_value(ping_interval,Options,?DEFAULT_PING_INTERVAL),
    PongTimeout = proplists:get_value(pong_timeout,Options,?DEFAULT_PONG_TIMEOUT),
    ReconnectInterval = proplists:get_value(reconnect_interval,Options,?DEFAULT_RECONNECT_INTERVAL),
    ClientKey = xylan_lib:make_key(proplists:get_value(client_key,Options)),
    ServerKey = xylan_lib:make_key(proplists:get_value(server_key,Options)),
    Authtimeout = proplists:get_value(auth_timeout,Options),
    self() ! reconnect,
    {ok, #state{ id = ID, 
		 server_ip = IP, 
		 server_port = Port, 
		 server_key = ServerKey,
		 client_key = ClientKey,
		 route = Route,
		 ping_interval = PingInterval,
		 pong_timeout = PongTimeout,
		 reconnect_interval = ReconnectInterval,
		 auth_timeout = Authtimeout
	       }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

%% server data message
handle_info(_Info={Tag,Socket,Data}, State) when
      State#state.server_auth =:= false,
      Tag =:= State#state.tag,
      Socket =:= (State#state.server_sock)#xylan_socket.socket ->
    xylan_socket:setopts(State#state.server_sock, [{active, once}]),
    try binary_to_term(Data, [safe]) of
	_Mesg={auth_res,[{id,ServerID},{chal,Chal},{cred,Cred}]} -> %% auth and cred from server
	    ?debug("auth_res: ~p ok", [_Mesg]),
	    %% crypto:sha is used instead of crypto:hash R15!!
	    case crypto:sha([State#state.server_key,State#state.server_chal]) of
		Cred ->
		    ?debug("handle_info: credential from server ~p ok", [ServerID]),
		    cancel_timer(State#state.auth),
		    %% crypto:sha is used instead of crypto:hash R15!!
		    Cred1 = crypto:sha([State#state.client_key,Chal]),
		    send(State#state.server_sock, {auth_ack,[{id,State#state.id},{cred,Cred1}]}),
		    Ping = erlang:start_timer(State#state.ping_interval, self(), ping),
		    {noreply, State#state { server_id = ServerID, server_auth = true,
					    auth = undefined, ping = Ping }};
		_CredFail ->
		    ?debug("handle_info: credential failed"),
		    close(State#state.server_sock),
		    TRef = reconnect_after(State#state.reconnect_interval),
		    {noreply, State#state { server_sock=undefined, server_auth=false,
					    reconnect=TRef }}
	    end;
	_Mesg ->
	    ?warning("handle_info: (control channel) unkown ~p", [_Mesg]),
	    {noreply, State}
    catch
	error:Reason ->
	    ?error("~p", [Reason]),
	    {noreply, State}
    end;

handle_info(_Info={Tag,Socket,Data}, State) when
      State#state.server_auth =:= true,
      Tag =:= State#state.tag,
      Socket =:= (State#state.server_sock)#xylan_socket.socket ->
    xylan_socket:setopts(State#state.server_sock, [{active, once}]),
    try binary_to_term(Data, [safe]) of
	pong when State#state.ping =:= undefined ->
	    ?debug("handle_info: (control channel) pong"),
	    cancel_timer(State#state.pong),
	    Ping = erlang:start_timer(State#state.ping_interval, self(), ping),
	    {noreply, State#state { pong = undefined, ping = Ping }};
	pong ->
	    ?debug("handle_info: (control channel) spourius pong", []),
	    {noreply, State};
	    
	Route={route,DataPort,SessionKey,RouteInfo} ->
	    ?debug("handle_info: (control channel) route ~p", [Route]),
	    case route(State#state.route,RouteInfo) of
		{ok,{LocalIP,LocalPort}} ->
		    RemoteIP = State#state.server_ip,
		    ?debug("connect to server ~p:~p\n", [RemoteIP,DataPort]),
		    ?debug("connect to local  ~p:~p\n", [LocalIP,LocalPort]),
		    case xylan_proxy:start(SessionKey) of
			{ok,Pid} ->
			    gen_server:cast(Pid,{connect,
						 LocalIP,LocalPort,
						 RemoteIP,DataPort})
		    end,
		    {noreply, State};
		false ->
		    ?warning("failed to route ~p", [RouteInfo]),
		    {noreply, State}
	    end;
	_Message ->
	    ?warning("handle_info: (control channel) unkown ~p", [_Message]),
	    {noreply, State}
    catch
	error:Reason ->
	    ?error("~p", [Reason]),
	    {noreply, State}
    end;

%% client data socket closed before proxy connection is established
handle_info(_Info={Tag,Socket}, State) when
      Tag =:= State#state.tag_closed,
      Socket =:= (State#state.server_sock)#xylan_socket.socket ->
    ?debug("handle_info: (control channel) ~p", [_Info]),
    close(State#state.server_sock),
    cancel_timer(State#state.auth),
    cancel_timer(State#state.pong),
    cancel_timer(State#state.ping),
    TRef = reconnect_after(State#state.reconnect_interval),
    {noreply, State#state { server_sock = undefined, reconnect=TRef,
			    ping=undefined,pong=undefined,auth=undefined }};

%% data socket got error before proxy established
handle_info(_Info={Tag,Socket,_Error}, State) when 
      Tag =:= State#state.tag_error,
      Socket =:= (State#state.server_sock)#xylan_socket.socket ->
    ?debug("handle_info: (data channel) ~p", [_Info]),
    close(State#state.server_sock),
    cancel_timer(State#state.auth),
    cancel_timer(State#state.pong),
    cancel_timer(State#state.ping),
    TRef = reconnect_after(State#state.reconnect_interval),
    {noreply, State#state { server_sock = undefined, reconnect=TRef,
			    ping=undefined,pong=undefined,auth=undefined }};

handle_info({timeout,T,reconnect}, State) when T =:= State#state.reconnect ->
    %% a bit ugly
    handle_info(reconnect, State#state { reconnect = undefined });
handle_info(reconnect, State) when State#state.server_sock =:= undefined ->
    case xylan_socket:connect(State#state.server_ip,State#state.server_port,
			    [{mode,binary},{packet,4},{nodelay,true}],
			    3000) of
	{ok, Socket} ->
	    ?debug("server ~p:~p connected", 
		   [State#state.server_ip,State#state.server_port]),
	    Chal = crypto:rand_bytes(16),
	    send(Socket, {auth_req,[{id,State#state.id},{chal,Chal}]}),
	    xylan_socket:setopts(Socket, [{active, once}]),
	    TRef = erlang:start_timer(State#state.auth_timeout, self(), auth_timeout),
	    {T,C,E} = xylan_socket:tags(Socket),
	    {noreply, State#state { server_sock = Socket,
				    server_chal = Chal,
				    server_auth = false,
				    auth = TRef,
				    tag=T, tag_closed=C, tag_error=E }};
	Error ->
	    ?warning("server not connected, ~p", [Error]),
	    TRef = reconnect_after(State#state.reconnect_interval),
	    {noreply, State#state { reconnect=TRef }}
    end;

handle_info({timeout,T,ping}, State) when T =:= State#state.ping ->
    if State#state.server_sock =/= undefined ->
	    ?debug("ping timeout send ping"),
	    send(State#state.server_sock, ping),
	    Timeout = State#state.pong_timeout,
	    Pong=erlang:start_timer(Timeout, self(),pong),
	    {noreply, State#state { ping=undefined, pong=Pong}};
       true ->
	    ?debug("old ping timeout?"),
	    {noreply, State}
    end;

handle_info({timeout,T,pong}, State) when T =:= State#state.pong ->
    if State#state.server_sock =/= undefined ->
	    ?debug("pong timeout reconnect socket"),
	    close(State#state.server_sock),
	    TRef = reconnect_after(State#state.reconnect_interval),
	    {noreply, State#state { server_sock=undefined, pong=undefined,reconnect=TRef}};
       true ->
	    ?debug("old pong timeout?"),
	    {noreply, State}
    end;

handle_info({timeout,T,auth_timeout}, State) when T =:= State#state.auth ->
    ?debug("auth timeout, reconnect"),
    TRef = reconnect_after(State#state.reconnect_interval),
    close(State#state.server_sock),
    {noreply, State#state { server_sock=undefined, auth=undefined, reconnect=TRef}};

handle_info(_Info, State) ->
    ?warning("handle_info: got: ~p\n", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

close(undefined) -> ok;
close(Socket) -> xylan_socket:close(Socket).

cancel_timer(undefined) -> false;
cancel_timer(Timer) -> erlang:cancel_timer(Timer).

reconnect_after(Timeout) ->
    erlang:start_timer(Timeout, self(),reconnect).

send(Socket, Term) ->
    xylan_socket:send(Socket, term_to_binary(Term)).

route([{R,L}|Rs], RouteInfo) ->
    case match(R, RouteInfo) of
	true ->
	    case proplists:get_value(port,L) of
		undefined ->
		    ?warning("route has not target port, ignored"),
		    false;
		Port ->
		    case proplists:get_value(ip,L,{127,0,0,1}) of
			IP when is_tuple(IP) ->
			    {ok,{IP,Port}};
			Name when is_list(Name) ->
			    case xylan_lib:lookup_ip(Name,inet) of
				{ok,IP} ->
				    {ok,{IP,Port}};
				Error ->
				    ?warning("ip ~p is not found: ~p", [Name,Error]),
				    false
			    end
		    end
	    end;
	false ->
	    route(Rs, RouteInfo)
    end;
route([], _RouteInfo) ->
    false.

match([{data,RE}|R], RouteInfo) ->
    case proplists:get_value(data, RouteInfo) of
	undefined -> false;
	Data -> match_data(Data, RE, R, RouteInfo)
    end;
match([{dst_ip,RE}|R], RouteInfo) ->
    case proplists:get_value(dst_ip, RouteInfo) of
	undefined -> false;
	RE -> true;
	IP when is_tuple(IP) -> match_data(inet:ntoa(IP), RE, R, RouteInfo);
	IP when is_list(IP) ->  match_data(IP, RE, R, RouteInfo);
	_ -> false
    end;
match([{dst_port,RE}|R], RouteInfo) ->
    case proplists:get_value(dst_port, RouteInfo) of
	undefined -> false;
	Port when is_integer(Port) ->
	    match_data(integer_to_list(Port), RE, R, RouteInfo);
	Port when is_list(Port) ->  match_data(Port, RE, R, RouteInfo);
	_ -> false
    end;
match([{src_ip,RE}|R], RouteInfo) ->
    case proplists:get_value(src_ip, RouteInfo) of
	undefined -> false;
	RE -> true;
	IP when is_tuple(IP) -> match_data(inet:ntoa(IP), RE, R, RouteInfo);
	IP when is_list(IP) ->  match_data(IP, RE, R, RouteInfo);
	_ -> false
    end;
match([{src_port,RE}|R], RouteInfo) ->
    case proplists:get_value(src_port, RouteInfo) of
	undefined -> false;
	Port when is_integer(Port) ->
	    match_data(integer_to_list(Port), RE, R, RouteInfo);
	Port when is_list(Port) ->  match_data(Port, RE, R, RouteInfo);
	_ -> false
    end;
match([M|_R], _RouteInfo) ->
    ?warning("unknown route match ~p", [M]),
    false;
match([], _RouteInfo) ->
    true.

match_data(String, RE, R, RouteInfo) when is_integer(RE) -> 
    match_data(String, integer_to_list(RE), R, RouteInfo);
match_data(String, RE, R, RouteInfo) ->	
    case re:run(String,RE) of
	{match,_} -> match(R, RouteInfo);
	nomatch -> false
    end.
