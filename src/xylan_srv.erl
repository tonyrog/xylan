%%% coding: latin-1
%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2016, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%    Proxy wedding server, accept "clients" proxies to register a session
%%%    to act as the real servers. Users connect and rules determine where
%%%    the connection will be sent.
%%%
%%% Created : 18 Dec 2014 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_srv).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([start_link/1]).
-export([get_status/0]).
-export([config_change/3]).
-export([get_client_list/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(DEFAULT_CNTL_PORT, 29390).   %% client proxy control port
-define(DEFAULT_DATA_PORT, 29391).   %% client proxy data port
%% tls ports are disabled by default, set client_tls_port/data_tls_port
-define(DEFAULT_TLS_VERSIONS, ['tlsv1.3','tlsv1.2']).
-define(DEFAULT_MAX_TLS_HANDSHAKES, 64).        %% concurrent, total
-define(DEFAULT_MAX_TLS_HANDSHAKES_PER_IP, 8).  %% concurrent, per peer ip
-define(DEFAULT_PORT, 46122).        %% user connect port
-define(DEFAULT_AUTH_TIMEOUT, 5000). %% timeout for authentication packet
-define(DEFAULT_DATA_TIMEOUT, 5000). %% timeout for proxy data connection
-define(DEFAULT_PING_TIMEOUT, 30000). %% timeout for lack of ping packet

-define(is_ipv4(IP),
	(((element(1,(IP)) bor element(2,(IP)) bor
	   element(3,(IP)) bor element(4,(IP))) band (bnot 16#ff)) =:= 0)).
-define(is_port(Port), (((Port) band (bnot 16#ffff)) =:= 0)).

-include("xylan_log.hrl").
-include("xylan_socket.hrl").

-define(IS_LISTENER(XSock, Listen, Ref0, Ref),
	(is_record((XSock), xylan_socket) andalso
	 (XSock)#xylan_socket.socket =:= (Listen) andalso (Ref0) =:= (Ref))).


-type interface() :: atom() | string().
-type timer() :: reference().
-type socket_ref() :: integer().

-type user_port() :: 
	inet:port_number() |
	{inet:ip_address(), inet:port_number()} |
	{interface(), inet:port_number()} |
	{atom(),inet:ip_address(), inet:port_number()} |
	{atom(),interface(), inet:port_number()}.

-type user_ports() :: user_port() | [user_port()].

-type regexp() :: iodata().

-type route_config() :: 
	{data, regexp()} |
	{src_ip, inet:ip_address()|regexp()} |
	{dst_ip, inet:ip_address()|regexp()} |
	{src_port, integer()} |
	{dst_port, integer()|atom()}.

-record(client,
	{
	  id :: string(),            %% name of client
	  server_key :: binary(),    %% server side key
	  client_key :: binary(),    %% client side key
	  auth_timeout :: timeout(), %% authentication timeout value
	  ping_timeout :: timeout(), %% ping not received timeout value
	  a_socket_options :: list(),  %%
	  b_socket_options :: list(),  %%
	  require_tls = false :: boolean(), %% only tls+hmac_sha256 accepted
	  client_cert :: undefined | [string()], %% pinned client cert fingerprints
	  pid :: pid(),              %% client process
	  mon :: reference(),        %% monitor of above
	  route :: [[route_config()]]  %% config
	}).
	  
-record(state,
	{
	  server_id :: string(),
	  %% fixme: may need to be able to have multiple control sockets
	  cntl_sock :: xylan_socket() | undefined, %% control chan listen socket
	  cntl_port :: integer() | none,
	  cntl_ref  :: socket_ref() | undefined, %% async accept reference
	  data_sock :: xylan_socket() | undefined, %% data chan listen socket
	  data_port :: integer() | none,
	  data_ref  :: socket_ref() | undefined, %% async accept reference
	  %% tls versions of the above
	  cntl_tls_sock :: xylan_socket() | undefined,
	  cntl_tls_port :: integer() | none,
	  cntl_tls_ref  :: socket_ref() | undefined,
	  data_tls_sock :: xylan_socket() | undefined,
	  data_tls_port :: integer() | none,
	  data_tls_ref  :: socket_ref() | undefined,
	  tls_options = [] :: [ssl:tls_server_option()],
	  %% ongoing tls handshakes Mon => PeerIP
	  handshakes = #{} :: #{reference() => inet:ip_address() | undefined},
	  max_handshakes = ?DEFAULT_MAX_TLS_HANDSHAKES :: non_neg_integer(),
	  max_handshakes_per_ip = ?DEFAULT_MAX_TLS_HANDSHAKES_PER_IP ::
	    non_neg_integer(),
	  user_socks :: [{xylan_socket(),socket_ref()}], %% listen sockets
	  user_ports :: user_ports(),
	  clients = []  :: [#client{}],
	  %% {Socket, Timer, IsTls}
	  auth_list = [] :: [{xylan_socket(),timer(),boolean()}], %% client sesion
	  data_list = [] :: [{xylan_socket(),timer(),boolean()}], %% client data
	  %% {Proxy, Mon, SessionKey, Bound} Bound is undefined until routed
	  %% then true|false telling which data channel type must be used
	  proxy_list = [] :: [{pid(),reference(),binary(),
			       undefined|boolean()}],     %% proxy sessions
	  auth_timeout  = ?DEFAULT_AUTH_TIMEOUT :: timeout(),
	  data_timeout  = ?DEFAULT_DATA_TIMEOUT :: timeout()
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

get_status() ->
    case gen_server:call(?SERVER, get_clients) of
	{ok,Clients} ->
	    {ok,
	     lists:map(
	       fun({CName,CPid}) ->
		       case gen_server:call(CPid, get_status) of
			   {ok,Status} ->
			       Status;
			   Error ->
			       [{id,CName},Error]
		       end
	       end, Clients)};
	Error ->
	    Error
    end.

config_change(Changed,New,Removed) ->
    gen_server:call(?SERVER, {config_change,Changed,New,Removed}).
    
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
init(Args0) ->
    Args = Args0 ++ application:get_all_env(xylan),
    CntlPort    = validate_port_or_none(client_port,
	            proplists:get_value(client_port,Args,?DEFAULT_CNTL_PORT)),
    DataPort    = validate_port_or_none(data_port,
		    proplists:get_value(data_port,Args,?DEFAULT_DATA_PORT)),
    CntlTlsPort = validate_port_or_none(client_tls_port,
		    proplists:get_value(client_tls_port,Args,none)),
    DataTlsPort = validate_port_or_none(data_tls_port,
		    proplists:get_value(data_tls_port,Args,none)),
    UserPorts   = validate_listen_ports(proplists:get_value(port,Args,?DEFAULT_PORT)),
    ServerID    = proplists:get_value(id,Args,""),
    AuthTimeout = proplists:get_value(auth_timeout,Args,?DEFAULT_AUTH_TIMEOUT),
    PingTimeout = proplists:get_value(ping_timeout,Args,?DEFAULT_PING_TIMEOUT),
    ASocketOpts = xylan_lib:filter_options(server,proplists:get_value(user_socket_options,Args,[])),
    BSocketOpts = xylan_lib:filter_options(server,proplists:get_value(client_socket_options,Args,[])),
    ClientList = validate_clients(get_client_list(Args), UserPorts),
    AnyClientCert = lists:any(fun({_,CC}) ->
				      proplists:get_value(client_cert,CC) =/=
					  undefined
			      end, ClientList),
    TlsOptions  = validate_tls_options(CntlTlsPort, DataTlsPort,
				       proplists:get_value(tls_options,Args,[]),
				       AnyClientCert),
    
    Clients =
	[begin
	     SKey=proplists:get_value(server_key,ClientConf),
	     CKey=proplists:get_value(client_key,ClientConf),
	     RequireTls=proplists:get_value(require_tls,ClientConf,false),
	     ClientCert=proplists:get_value(client_cert,ClientConf),
	     if RequireTls, CntlTlsPort =:= none ->
		     ?warning("client ~s require_tls but no client_tls_port",
			      [ClientID]);
		true -> ok
	     end,
	     %% CPingTimeout = proplists:get_value(ping_timeout,ClientConf,PingTimeout),
	     Route = proplists:get_value(route, ClientConf),
	     ASocketOpts1=xylan_lib:merge_options(ASocketOpts,xylan_lib:filter_options(server,proplists:get_value(user_socket_options,ClientConf,[]))),
	     BSocketOpts1=xylan_lib:merge_options(BSocketOpts,xylan_lib:filter_options(server,proplists:get_value(client_socket_options,ClientConf,[]))),
	     {ok,CPid} = xylan_session:start(),
	     CMon = erlang:monitor(process, CPid),
	     Config = [{client_id,ClientID},
		       {server_id,ServerID},
		       {server_key,SKey},
		       {client_key,CKey},
		       {auth_timeout,AuthTimeout},
		       {ping_timeout,PingTimeout},
		       {require_tls,RequireTls},
		       {client_cert,ClientCert}
		      ],
	     gen_server:cast(CPid, {set_config,Config}),
	     #client { id = ClientID,
		       server_key = SKey,
		       client_key = CKey,
		       auth_timeout = AuthTimeout,
		       ping_timeout = PingTimeout,
		       require_tls = RequireTls,
		       client_cert = ClientCert,
		       a_socket_options = ASocketOpts1,
		       b_socket_options = BSocketOpts1,
		       pid = CPid,
		       mon = CMon,
		       route = Route }
	 end || {ClientID,ClientConf} <- ClientList],
    {CntlSock,CntlRef} = start_client_listen(client, CntlPort),
    {DataSock,DataRef} = start_client_listen(data, DataPort),
    {CntlTlsSock,CntlTlsRef} = start_client_listen(client_tls, CntlTlsPort),
    {DataTlsSock,DataTlsRef} = start_client_listen(data_tls, DataTlsPort),
    UserSocks = start_user(UserPorts),
    DataTimeout = proplists:get_value(data_timeout,Args,?DEFAULT_DATA_TIMEOUT),
    {ok, #state{ server_id = ServerID,
		 cntl_sock=CntlSock, cntl_port = CntlPort, cntl_ref=CntlRef,
		 data_sock=DataSock, data_port = DataPort, data_ref=DataRef,
		 cntl_tls_sock=CntlTlsSock, cntl_tls_port=CntlTlsPort,
		 cntl_tls_ref=CntlTlsRef,
		 data_tls_sock=DataTlsSock, data_tls_port=DataTlsPort,
		 data_tls_ref=DataTlsRef,
		 tls_options = TlsOptions,
		 max_handshakes =
		     proplists:get_value(max_tls_handshakes, Args,
					 ?DEFAULT_MAX_TLS_HANDSHAKES),
		 max_handshakes_per_ip =
		     proplists:get_value(max_tls_handshakes_per_ip, Args,
					 ?DEFAULT_MAX_TLS_HANDSHAKES_PER_IP),
		 user_socks=UserSocks, user_ports = UserPorts,
		 clients = Clients,
		 auth_timeout = AuthTimeout,
		 data_timeout = DataTimeout
	       }}.


%% Listen for client connections, tls ports are listen as plain tcp
%% and upgraded in a separate handshake process (see start_tls_handshake)
start_client_listen(_Name, none) ->
    {undefined, undefined};
start_client_listen(Name, Port) ->
    {ok,Sock} = xylan_socket:listen(Port, [tcp], [{reuseaddr,true},
						  {nodelay, true},
						  {mode,binary},
						  {packet,4}]),
    ?info("open ~s port ~w", [Name, Port]),
    {ok,Ref} = xylan_socket:async_accept(Sock),
    {Sock, Ref}.

start_user(Ports) when is_list(Ports) ->
    lists:foldl(
      fun({Name,IP,Port},Acc) when is_atom(Name), is_integer(Port) ->
	      ?info("open user port ~s ~w @ ~w\n", 
			 [Name,Port,IP]),
	      open_user_port(Port,IP) ++ Acc
      end, [], Ports).

open_user_port(Port,IP) when is_integer(Port) ->
    case xylan_socket:listen(Port, [tcp], [{reuseaddr,true},
					   {nodelay, true},
					   {mode,binary},
					   {ifaddr,IP},
					   {packet,0}]) of
	{ok,Socket} ->
	    {ok,Ref} = xylan_socket:async_accept(Socket),
	    [{Ref,Socket}];
	Error ->
	    ?warning("Error listen to port ~w:~p ~p",[Port,IP,Error]),
	    []
    end.

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

handle_call(get_clients, _From, State) ->
    Clients = [{C#client.id, C#client.pid} || C <- State#state.clients],
    {reply, {ok,Clients}, State};

handle_call({config_change,_Changed,_New,_Removed},_From,State) ->
    io:format("config_change changed=~p, new=~p, removed=~p\n",
	      [_Changed,_New,_Removed]),
    {reply, ok, State};
    
handle_call(_Request, _From, State) ->
    ?warning("got unknown request ~p\n", [_Request]),
    {reply, {error, bad_call}, State}.

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

handle_cast(Msg={route,SessionKey,RouteInfo,Proxy}, State) ->
    %% user session got some data, try to route to a client
    %% by some rule, current rule is to take first client
    %% fixme: verify user ?  yes!
    ?debug("got route : ~p", [Msg]),
    case route_cs(State#state.clients, RouteInfo) of
	false ->
	    ?warning("failed to route ~p", [RouteInfo]),
	    {noreply, State};
	{ok,Client} when is_pid(Client#client.pid) ->
	    %% the session selects the data port matching its control
	    %% channel and reply with {session_bound,SessionKey,Tls}
	    DataPorts = {State#state.data_port, State#state.data_tls_port},
	    gen_server:cast(Client#client.pid,
			    {route,DataPorts,SessionKey,RouteInfo}),
	    %% Set options now when we have identified the client
	    gen_server:cast(Proxy,
			    {socket_options,
			     Client#client.a_socket_options,
			     Client#client.b_socket_options}),
	    {noreply, State};
	{ok,Client} ->
	    ?warning("client ~s not connected",[Client#client.id]),
	    {noreply, State}
    end;
handle_cast({session_bound,SessionKey,Tls}, State) ->
    handle_cast({session_bound,SessionKey,Tls,undefined}, State);
handle_cast({session_bound,SessionKey,Tls,ClientCert}, State) ->
    case lists:keyfind(SessionKey, 3, State#state.proxy_list) of
	false ->
	    ?debug("session_bound: session gone", []),
	    {noreply, State};
	{Pid,Mon,SessionKey,_} ->
	    %% data connection must use same channel type (and client cert)
	    Ls = lists:keyreplace(SessionKey, 3, State#state.proxy_list,
				  {Pid,Mon,SessionKey,{Tls,ClientCert}}),
	    {noreply, State#state { proxy_list = Ls }}
    end;
handle_cast(_Msg, State) ->
    ?warning("got unknown message ~p\n", [_Msg]),
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


%% accept incoming socket requests
handle_info({inet_async, Listen, Ref, {ok,Socket}} = _Msg, State) ->
    case which_listener(Listen, Ref, State) of
	client ->
	    ?debug("(client control) ~p", [_Msg]),
	    {ok,Ref1} = xylan_socket:async_accept(State#state.cntl_sock),
	    State1 = State#state { cntl_ref = Ref1 },
	    case xylan_socket:async_socket(State#state.cntl_sock, Socket) of
		{ok, XSocket} ->
		    {noreply, add_cntl_socket(XSocket, false, State1)};
		_Error ->
		    ?error("inet_accept: ~p", [_Error]),
		    {noreply, State1}
	    end;
	data ->
	    ?debug("(client data) ~p", [_Msg]),
	    {ok,Ref1} = xylan_socket:async_accept(State#state.data_sock),
	    State1 = State#state { data_ref = Ref1 },
	    case xylan_socket:async_socket(State#state.data_sock, Socket) of
		{ok, XSocket} ->
		    {noreply, add_data_socket(XSocket, false, State1)};
		_Error ->
		    ?error("~p", [_Error]),
		    {noreply, State1}
	    end;
	client_tls ->
	    ?debug("(client tls control) ~p", [_Msg]),
	    {ok,Ref1} = xylan_socket:async_accept(State#state.cntl_tls_sock),
	    State1 = State#state { cntl_tls_ref = Ref1 },
	    case xylan_socket:async_socket(State#state.cntl_tls_sock,Socket) of
		{ok, XSocket} ->
		    {noreply, start_tls_handshake(cntl, XSocket, State1)};
		_Error ->
		    ?error("inet_accept: ~p", [_Error]),
		    {noreply, State1}
	    end;
	data_tls ->
	    ?debug("(client tls data) ~p", [_Msg]),
	    {ok,Ref1} = xylan_socket:async_accept(State#state.data_tls_sock),
	    State1 = State#state { data_tls_ref = Ref1 },
	    case xylan_socket:async_socket(State#state.data_tls_sock,Socket) of
		{ok, XSocket} ->
		    {noreply, start_tls_handshake(data, XSocket, State1)};
		_Error ->
		    ?error("inet_accept: ~p", [_Error]),
		    {noreply, State1}
	    end;
	user ->
	    ?debug("(user connect) ~p", [_Msg]),
	    case take_socket_ref(Listen, Ref, State#state.user_socks) of
		false ->
		    ?error("listen socket not found"),
		    {noreply, State};
		{value,UserSock,UserSocks} ->
		    {ok,Ref1} = xylan_socket:async_accept(UserSock),
		    UsersSocks1 = [{Ref1,UserSock}|UserSocks],
		    SessionKey = crypto:strong_rand_bytes(16),
		    case xylan_socket:async_socket(UserSock,Socket) of
			{ok, XSocket} ->
			    case xylan_proxy:start(SessionKey) of
				{ok, Pid} ->
				    Mon = erlang:monitor(process, Pid),
				    xylan_socket:controlling_process(XSocket, Pid),
				    gen_server:cast(Pid, {set_a,XSocket}),
				    Ls = [{Pid,Mon,SessionKey,undefined}|State#state.proxy_list],
				    {noreply, State#state { proxy_list = Ls,
							    user_socks=UsersSocks1}};
				_Error ->
				    ?error("inet_accept: (user) ~p", [_Error]),
				    xylan_socket:close(XSocket),
				    {noreply, State#state { user_socks=UsersSocks1}}
			    end;
			_Error ->
			    ?error("inet_accept: (user) ~p", [_Error]),
			    {noreply, State#state { user_socks=UsersSocks1}}
		    end
	    end
    end;

%% tls handshake done (see start_tls_handshake)
handle_info({tls_accepted, cntl, XSocket}, State) ->
    {noreply, add_cntl_socket(XSocket, true, State)};
handle_info({tls_accepted, data, XSocket}, State) ->
    {noreply, add_data_socket(XSocket, true, State)};

%% client data message
handle_info(_Info={Tag,Socket,Data}, State) when
      (Tag =:= tcp orelse Tag =:= ssl) ->
    ?debug("(data channel) ~p", [_Info]),
    case take_socket(Socket, 1, State#state.data_list) of
	false ->
	    case take_socket(Socket, 1, State#state.auth_list) of
		false ->
		    ?warning("socket not found, data=~p",[Data]),
		    %% FIXME: close this?
		    {noreply, State};
		{value,{XSocket,TRef,Tls},AuthList} ->
		    %% session socket data received
		    cancel_timer(TRef),
		    State1 = State#state { auth_list = AuthList },
		    try binary_to_term(Data, [safe]) of
			Message = {auth_req,Props} when is_list(Props) ->
			    ID = proplists:get_value(id, Props),
			    auth_client(ID, Tls, XSocket, Message, State1);
			Other ->
			    ?warning("bad client message=~p",[Other]),
			    xylan_socket:close(XSocket),
			    {noreply, State1}
		    catch
			error:Reason ->
			    ?warning("bad client message=~p",[{error,Reason}]),
			    xylan_socket:close(XSocket),
			    {noreply, State1}
		    end
	    end;

	{value,{XSocket,TRef,Tls},Ls} ->
	    cancel_timer(TRef),
	    %% data packet <<SessionKey:16>>
	    case lists:keyfind(Data,3,State#state.proxy_list) of
		false ->
		    ?warning("no user found id=~p",[Data]),
		    xylan_socket:close(XSocket),
		    {noreply, State#state { data_list=Ls }};
		{Proxy,Mon,_Data,{Tls,CC}} when
		      CC =:= undefined; Tls =:= true ->
		    %% session is routed and data channel type match
		    case CC =:= undefined orelse
			lists:member(xylan_lib:peer_fingerprint(XSocket), CC) of
			true ->
			    ProxyList = lists:keydelete(Data,3,State#state.proxy_list),
		    erlang:demonitor(Mon, [flush]),
		    xylan_socket:controlling_process(XSocket, Proxy),
		    gen_server:cast(Proxy, {set_b,XSocket}),
		    {noreply, State#state { proxy_list = ProxyList,data_list=Ls }};
			false ->
			    ?warning("data channel client certificate mismatch"),
			    xylan_socket:close(XSocket),
			    {noreply, State#state { data_list=Ls }}
		    end;
		{_Proxy,_Mon,_Data,Bound} ->
		    %% keep the session, the real client may still connect
		    ?warning("data channel mismatch session=~w data_tls=~w",
			     [Bound, Tls]),
		    xylan_socket:close(XSocket),
		    {noreply, State#state { data_list=Ls }}
	    end
    end;

%% client data socket closed before proxy connection is established
handle_info(_Info={Tag,Socket}, State) when
      (Tag =:= tcp_closed orelse Tag =:= ssl_closed) ->
    ?debug("(data channel) ~p", [_Info]),
    {noreply, close_socket(Socket, State)};

%% data socket got error before proxy established
handle_info(_Info={Tag,Socket,_Error}, State) when 
      (Tag =:= tcp_error orelse Tag =:= ssl_error) ->
    ?debug("(data channel) ~p", [_Info]),
    {noreply, close_socket(Socket, State)};

handle_info({timeout,TRef,auth_timeout}, State) ->
    case lists:keytake(TRef,2,State#state.auth_list) of
	false ->
	    ?debug("auth_timeout already removed"),
	    {noreply, State};
	{value,{Socket,TRef,_Tls},Ls} ->
	    ?info("auth_timeout"),
	    xylan_socket:close(Socket),
	    {noreply, State#state { auth_list = Ls}}
    end;

handle_info({timeout,TRef,data_timeout}, State) ->
    case lists:keytake(TRef,2,State#state.data_list) of
	false ->
	    ?debug("data_timeout already removed"),
	    {noreply, State};
	{value,{Socket,TRef,_Tls},Ls} ->
	    ?info("data_timeout"),
	    xylan_socket:close(Socket),
	    {noreply, State#state { data_list = Ls}}
    end;

handle_info({'DOWN',Ref,process,_Pid,_Reason}, State) when
      is_map_key(Ref, State#state.handshakes) ->
    {noreply, State#state { handshakes = maps:remove(Ref,
						     State#state.handshakes) }};
handle_info(_Info={'DOWN',Ref,process,_Pid,_Reason}, State) ->
    ?debug("got: ~p\n", [_Info]),
    case lists:keytake(Ref, 2, State#state.proxy_list) of
	{value,_Proxy,Ls} ->
	    ?debug("proxy stopped ~p\n", [_Reason]),
	    {noreply, State#state { proxy_list = Ls}};
	false ->
	    case lists:keytake(Ref, #client.mon, State#state.clients) of
		false ->
		    {noreply, State};
		{value,C,Clients} ->
		    ?debug("client stopped ~p restart client ~s", [_Reason,C#client.id]),
		    {ok,CPid} = xylan_session:start(),
		    CMon = erlang:monitor(process, CPid),
		    Clients1 = [C#client { pid = CPid,mon = CMon } | Clients],
		    Config =  [{client_id,C#client.id},
			       {server_id,State#state.server_id},
			       {server_key,C#client.server_key},
			       {client_key,C#client.client_key},
			       {auth_timeout,C#client.auth_timeout},
			       {ping_timeout,C#client.ping_timeout},
			       {require_tls,C#client.require_tls},
			       {client_cert,C#client.client_cert}
			      ],
		    gen_server:cast(CPid,{set_config,Config}),
		    {noreply, State#state { clients = Clients1 }}
	    end
    end;
handle_info(_Info, State) ->
    ?warning("got unknown info ~p\n", [_Info]),
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

which_listener(Listen, Ref, State) ->
    if ?IS_LISTENER(State#state.cntl_sock, Listen, State#state.cntl_ref, Ref) ->
	    client;
       ?IS_LISTENER(State#state.data_sock, Listen, State#state.data_ref, Ref) ->
	    data;
       ?IS_LISTENER(State#state.cntl_tls_sock, Listen,
		    State#state.cntl_tls_ref, Ref) ->
	    client_tls;
       ?IS_LISTENER(State#state.data_tls_sock, Listen,
		    State#state.data_tls_ref, Ref) ->
	    data_tls;
       true ->
	    user
    end.

%% new client control socket, wait for auth_req
add_cntl_socket(XSocket, Tls, State) ->
    case xylan_socket:peername(XSocket) of
	{ok,{SrcIP,SrcPort}} ->
	    ?info("client connected from ~s:~w (tls=~w)\n",
		  [inet:ntoa(SrcIP),SrcPort,Tls]);
	_ -> ok
    end,
    xylan_socket:setopts(XSocket, [{active,once}]),
    TRef=erlang:start_timer(State#state.auth_timeout,self(),auth_timeout),
    Ls = [{XSocket,TRef,Tls}|State#state.auth_list],
    State#state { auth_list=Ls }.

%% new client data socket, wait for the SessionKey
add_data_socket(XSocket, Tls, State) ->
    xylan_socket:setopts(XSocket, [{active,once}]),
    TRef=erlang:start_timer(State#state.data_timeout,self(),data_timeout),
    Ls = [{XSocket,TRef,Tls}|State#state.data_list],
    State#state { data_list = Ls }.

%% Run the tls handshake in a separate process so a slow (or hostile)
%% peer can not block the server. The handshake is limited by auth_timeout
%% and the result is sent back as {tls_accepted, Kind, XSocket}
start_tls_handshake(Kind, XSocket, State) ->
    PeerIP = case xylan_socket:peername(XSocket) of
		 {ok,{IP,_}} -> IP;
		 _ -> undefined
	     end,
    Hs = State#state.handshakes,
    NumIP = length([ok || P <- maps:values(Hs), P =:= PeerIP]),
    if map_size(Hs) >= State#state.max_handshakes ->
	    ?warning("tls handshake limit reached, ~s rejected",
		     [format_ip(PeerIP)]),
	    xylan_socket:close(XSocket),
	    State;
       NumIP >= State#state.max_handshakes_per_ip ->
	    ?warning("tls handshake limit per ip reached, ~s rejected",
		     [format_ip(PeerIP)]),
	    xylan_socket:close(XSocket),
	    State;
       true ->
	    Srv = self(),
	    Opts = State#state.tls_options,
	    Timeout = State#state.auth_timeout,
	    {Pid,Mon} = spawn_monitor(fun() -> tls_handshake(Srv, Kind, XSocket,
							     Opts, Timeout)
				      end),
	    case xylan_socket:controlling_process(XSocket, Pid) of
		ok ->
		    Pid ! {go, Srv};
		_Error ->
		    ?warning("tls handshake: controlling_process ~p", [_Error]),
		    exit(Pid, kill),
		    xylan_socket:close(XSocket)
	    end,
	    State#state { handshakes = Hs#{ Mon => PeerIP } }
    end.

format_ip(undefined) -> "?";
format_ip(IP) -> inet:ntoa(IP).

tls_handshake(Srv, Kind, XSocket, Opts, Timeout) ->
    receive
	{go, Srv} -> ok
    after Timeout ->
	    exit(normal)
    end,
    case xylan_socket:tls_accept(XSocket, Opts, Timeout) of
	{ok, XSocket1} ->
	    case xylan_socket:controlling_process(XSocket1, Srv) of
		ok ->
		    Srv ! {tls_accepted, Kind, XSocket1};
		_Error ->
		    ?warning("tls handshake: controlling_process ~p",[_Error]),
		    xylan_socket:close(XSocket1)
	    end;
	{error, _Reason} ->
	    ?info("tls handshake ~s failed: ~p", [Kind, _Reason]),
	    try xylan_socket:close(XSocket) catch _:_ -> ok end
    end.

%% find client and hand over the control socket to the client session
auth_client(ID, Tls, XSocket, Message, State) ->
    case lists:keyfind(ID, #client.id, State#state.clients) of
	false ->
	    ?warning("client ~p not found",[ID]),
	    xylan_socket:close(XSocket),
	    {noreply, State};
	Client when Client#client.require_tls, not Tls ->
	    %% reject before handover so the current session is not closed
	    ?warning("client ~p requires tls, rejected",[ID]),
	    xylan_socket:close(XSocket),
	    {noreply, State};
	Client when Client#client.client_cert =/= undefined,
		    is_pid(Client#client.pid) ->
	    FP = xylan_lib:peer_fingerprint(XSocket),
	    case lists:member(FP, Client#client.client_cert) of
		true ->
		    ?info("client ~p connected (client cert ok)\n", [ID]),
		    xylan_socket:controlling_process(XSocket, Client#client.pid),
		    gen_server:cast(Client#client.pid,
				    {auth_socket, XSocket, Tls, Message}),
		    {noreply, State};
		false ->
		    ?warning("client ~p bad client certificate ~s, rejected",
			     [ID, if FP =:= undefined -> "(none)";
				     true -> FP end]),
		    xylan_socket:close(XSocket),
		    {noreply, State}
	    end;
	Client when is_pid(Client#client.pid) ->
	    ?info("client ~p connected (tls=~w)\n", [ID, Tls]),
	    xylan_socket:controlling_process(XSocket, Client#client.pid),
	    gen_server:cast(Client#client.pid,
			    {auth_socket, XSocket, Tls, Message}),
	    {noreply, State};
	_Client ->
	    ?warning("client ~p pid not present", [ID]),
	    xylan_socket:close(XSocket),
	    {noreply, State}
    end.

validate_port_or_none(_Name, none) -> none;
validate_port_or_none(_Name, undefined) -> none;
validate_port_or_none(_Name, Port) when ?is_port(Port) -> Port;
validate_port_or_none(Name, Port) ->
    ?error("bad ~s value ~p", [Name, Port]),
    erlang:error(bad_port).

validate_tls_options(none, none, Opts, _AnyClientCert) ->
    Opts;
validate_tls_options(_, _, Opts0, AnyClientCert) ->
    Opts = xylan_lib:tls_server_options(xylan_lib:tls_password(Opts0),
					AnyClientCert),
    HasCert = lists:any(fun(K) -> proplists:is_defined(K, Opts) end,
			[certfile, cert, certs_keys]),
    if not HasCert ->
	    ?error("tls port configured but tls_options has no certificate"),
	    erlang:error(missing_tls_certificate);
       true ->
	    case proplists:get_value(certfile, Opts) of
		undefined -> ok;
		CertFile ->
		    ?info("tls certificate ~s fingerprint ~s",
			  [CertFile, xylan_lib:cert_fingerprint(CertFile)])
	    end,
	    case proplists:is_defined(versions, Opts) of
		true -> Opts;
		false -> [{versions, ?DEFAULT_TLS_VERSIONS} | Opts]
	    end
    end.

take_socket_ref(Sock, Ref, SocketList) ->
    take_socket_ref_(Sock, Ref, SocketList, []).

take_socket_ref_(Sock, Ref, [A={Ref,XSock}|SocketList], Acc) ->
    if XSock#xylan_socket.socket =:= Sock ->
	    {value,XSock,lists:reverse(Acc, SocketList)};
       true ->
	    take_socket_ref_(Sock, Ref, SocketList, [A|Acc])
    end;
take_socket_ref_(Sock, Ref, [A|SocketList], Acc) ->
    take_socket_ref_(Sock, Ref, SocketList, [A|Acc]);    
take_socket_ref_(_Sock, _Ref, [], _) ->
    false.


socket_status(XSocket) ->
    if is_port(XSocket#xylan_socket.socket) ->
	    case prim_inet:getstatus(XSocket#xylan_socket.socket) of
		{ok,Status} -> io_lib:format("~p", [Status]);
		_ -> " "
	    end;
       true ->
	    "???"
    end.


validate_clients(Clients, UserPorts) ->
    [validate_client(C,UserPorts) || C <- Clients].

validate_client({Name,C}, UserPorts) ->
    ClientCert = case proplists:get_value(client_cert, C) of
		     undefined -> undefined;
		     FP when is_list(FP), FP =/= [] ->
			 xylan_lib:normalize_fingerprints(FP);
		     _ -> ?error("client ~s bad client_cert value", [Name]),
			  erlang:error(bad_client_cert)
		 end,
    %% keys are optional when the client is authenticated by certificate
    KeysOptional = ClientCert =/= undefined,
    SKey = validate_key(server_key,proplists:get_value(server_key, C),
			KeysOptional),
    CKey = validate_key(client_key,proplists:get_value(client_key, C),
			KeysOptional),
    if (SKey =:= undefined) =/= (CKey =:= undefined) ->
	    ?error("client ~s both or none of server_key/client_key", [Name]),
	    erlang:error(bad_key_format);
       true -> ok
    end,
    Route = validate_route(proplists:get_value(route,C,[]), UserPorts),
    UOpts = proplists:get_value(user_socket_options,C,[]),
    COpts = proplists:get_value(client_socket_options,C,[]),
    RequireTls = case proplists:get_value(require_tls,C,false) of
		     _ when ClientCert =/= undefined -> true;
		     B when is_boolean(B) -> B;
		     _ -> ?error("client ~s bad require_tls value", [Name]),
			  erlang:error(bad_require_tls)
		 end,
    C1 = {Name,[{server_key, SKey},
		{client_key, CKey},
		{require_tls, RequireTls},
		{client_cert, ClientCert},
		{route, Route},
		{user_socket_options, UOpts},
		{client_socket_options, COpts}]},
    C1.

validate_key(_KeyType,undefined,true) ->
    undefined;
validate_key(KeyType,undefined,false) ->
    ?error("~s missing\n", [KeyType]),
    erlang:error(bad_key_format);
validate_key(KeyType,Key,_Optional) ->
    try xylan_lib:make_key(Key) of
	BinKey -> BinKey
    catch
	error:_ ->
	    ?error("~s key format error\n", [KeyType]),
	    erlang:error(bad_key_format)
    end.

validate_route(Route, UserPorts) ->
    [validate_rts(R,UserPorts)||R<-Route].

validate_rts([{dst_port,Port}|R], UserPorts) ->
    [{dst_port,validate_port(Port,UserPorts)}|validate_rts(R,UserPorts)];
validate_rts([{src_port,Port}|R], UserPorts) ->
    [{src_port,validate_port(Port,[])}|validate_rts(R,UserPorts)];
validate_rts([{dst_ip,IP}|R], UserPorts) ->
    [{dst_ip,validate_ip(IP)}|validate_rts(R,UserPorts)];
validate_rts([{src_ip,IP}|R], UserPorts) ->
    [{src_ip,validate_ip(IP)}|validate_rts(R,UserPorts)];
validate_rts([{data,Data}|R], UserPorts) ->
    [{data,validate_route_data(Data)}|validate_rts(R,UserPorts)];
validate_rts([], _UserPorts) ->
    [].

validate_route_data(undefined) -> undefined;
validate_route_data(ssl) -> ssl;
validate_route_data(RE) -> validate_re(RE).

validate_re(RE) when is_list(RE); is_binary(RE) ->
    case re:compile(RE) of
	{ok,_Comp} -> RE;  %% may return Comp!!!
	{error,{Error,_}} ->
	    ?error("bad regular expression ~s ~s\n",
			[RE, Error]),
	    erlang:error(bad_re_expr)
    end.

validate_ip(undefined) ->
    undefined;
validate_ip(IP) when ?is_ipv4(IP) ->
    IP;
validate_ip(IPorIFName) when is_list(IPorIFName) ->
    case re:compile(IPorIFName) of
	{ok,_Comp} -> IPorIFName;
	{error,{Error,_}} ->
	    ?error("bad regular expression ~s ~s\n",
			[IPorIFName, Error]),
	    erlang:error(bad_re_expr)
    end;
validate_ip(_IP) ->
    ?error("bad ip name ~p\n", [_IP]),
    erlang:error(bad_ip).

validate_listen_ports(Ps) when is_list(Ps) ->
    [validate_listen_port(P) || P <- Ps];
validate_listen_ports(P) ->
    [validate_listen_port(P)].

validate_listen_port(Port) when ?is_port(Port) ->
    {undefined,any,Port};
validate_listen_port({any,Port}) when ?is_port(Port) ->
    {undefined,any,Port};
validate_listen_port({IfName,Port}) when ?is_port(Port) ->
    case xylan_lib:lookup_ip(IfName,inet) of
	{error,_} ->
	    ?warning("No such interface ~p",[IfName]),
	    erlang:error(bad_interface);
	{ok,IP} ->
	    {undefined,IP,Port}
    end;
validate_listen_port({Name,IfName,Port}) when is_atom(Name),?is_port(Port) ->
    case xylan_lib:lookup_ip(IfName,inet) of
	{error,_} ->
	    ?warning("No such interface ~p",[Name]),
	    erlang:error(bad_interface);
	{ok,IP} ->
	    {Name,IP,Port}
    end.

validate_port(undefined, _) -> undefined;
validate_port(Port,_) when is_integer(Port), Port >= 0, Port =< 65535 ->
    Port;
validate_port(PortRE,_UserPort) when is_list(PortRE) ->
    case re:compile(PortRE) of
	{ok,_Comp} -> PortRE;
	{error,{Error,_}} ->
	    ?error("bad regular expression ~s ~s\n",
			[PortRE, Error]),
	    erlang:error(bad_re_expr)
    end;
validate_port(Port,UserPort) when is_atom(Port) ->
    case lists:keyfind(Port,1,UserPort) of
	false ->
	    ?error("port name ~s not declared", [Port]),
	    erlang:error(bad_port);
	{_PortName,IfName,PortNum} -> {IfName,PortNum}
    end.

get_client_list() ->
    get_client_list(application:get_all_env(xylan)).

get_client_list(Args) ->
    proplists:get_value(clients,Args,[]) ++ load_client_configs(Args).

load_client_configs(Args) ->
    case proplists:get_value(config_dir,Args) of
	undefined -> [];
	Dir ->
	    case file:list_dir(Dir) of
		{ok,Files} ->
		    lists:append([xylan_lib:load_config(Dir,File) || 
				     File <- Files]);
		{error,Reason} ->
		    ?error("unable to list client configs dir ~s ~p",
				[Dir, Reason]),
		    []
	    end
    end.

cancel_timer(undefined) -> false;
cancel_timer(Timer) -> erlang:cancel_timer(Timer).

close_socket(Socket, State) ->
    %% remove socket from auth_list or data_lsit and close it
    case take_socket(Socket,1,State#state.data_list) of
	false ->
	    case take_socket(Socket,1,State#state.auth_list) of
		false ->
		    State;
		{value,{XSocket,TRef,_Tls},Ls} ->
		    ?debug("close client socket"),
		    cancel_timer(TRef),
		    xylan_socket:close(XSocket),
		    State#state { auth_list = Ls }
	    end;
	{value,{XSocket,TRef,_Tls},Ls} ->
	    ?debug("close data socket"),
	    cancel_timer(TRef),
	    xylan_socket:close(XSocket),
	    State#state { data_list = Ls }
    end.

take_socket(Socket,Pos,SocketList) when is_integer(Pos), Pos >= 0 ->
    take(fun (#xylan_socket { socket=S }) -> S=:=Socket end, Pos, SocketList).

take(Fun, Pos, List) when is_function(Fun), is_list(List) ->
    take_(Fun, Pos, List, []).

take_(Fun, Pos, [H|T], Acc) ->
    Elem = if Pos =:= 0 -> H; true -> element(Pos,H) end,
    case Fun(Elem) of
	true ->
	    {value,H,lists:reverse(Acc, T)};
	false ->
	    take_(Fun,Pos,T,[H|Acc])
    end;
take_(_Fun, _Pos, [], _Acc) ->
    false.


route_cs([Client|Cs], RouteInfo) ->
    case match_route(Client#client.route, RouteInfo) of
	true -> {ok,Client};
	false -> route_cs(Cs, RouteInfo)
    end;
route_cs([], _RouteInfo) ->
    false.

match_route([R|Rs], RouteInfo) ->
    case match(R, RouteInfo) of
	true  -> true;
	false -> match_route(Rs, RouteInfo)
    end;
match_route([], _RouteInfo) ->
    false.

match([{data,RE}|R], RouteInfo) ->
    case proplists:get_value(data, RouteInfo) of
	undefined -> false;
	Data -> match_data(Data, RE, R, RouteInfo)
    end;
match([{dst_ip,RE}|R], RouteInfo) ->
    case proplists:get_value(dst_ip, RouteInfo) of
	undefined -> false;
	RE -> match(R, RouteInfo);  %% exact ip tuple
	IP when is_tuple(IP) -> match_data(inet:ntoa(IP), RE, R, RouteInfo);
	IP when is_list(IP) ->  match_data(IP, RE, R, RouteInfo);
	_ -> false
    end;
match([{dst_port,RE}|R], RouteInfo) ->
    case proplists:get_value(dst_port, RouteInfo) of
	undefined -> false;
	RE -> match(R, RouteInfo);
	Port when is_integer(Port) ->
	    match_data(integer_to_list(Port), RE, R, RouteInfo);
	Port when is_list(Port) ->  match_data(Port, RE, R, RouteInfo);
	_ -> false
    end;
match([{src_ip,RE}|R], RouteInfo) ->
    case proplists:get_value(src_ip, RouteInfo) of
	undefined -> false;
	RE -> match(R, RouteInfo);  %% exact ip tuple
	IP when is_tuple(IP) -> match_data(inet:ntoa(IP), RE, R, RouteInfo);
	IP when is_list(IP) ->  match_data(IP, RE, R, RouteInfo);
	_ -> false
    end;
match([{src_port,RE}|R], RouteInfo) ->
    case proplists:get_value(src_port, RouteInfo) of
	undefined -> false;
	RE -> match(R, RouteInfo);
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

match_data(String, ssl, R, RouteInfo) ->
    case xylan_socket:request_type(String) of
	ssl -> match(R, RouteInfo);
	_ -> false
    end;
match_data(String, RE, R, RouteInfo) when is_tuple(RE) ->
    %% ip tuple in the route, RouteInfo has the address as a string
    case inet:ntoa(RE) =:= String of
	true -> match(R, RouteInfo);
	false -> false
    end;
match_data(String, RE, R, RouteInfo) when is_integer(RE) -> 
    match_data(String, integer_to_list(RE), R, RouteInfo);
match_data(String, RE, R, RouteInfo) ->	
    case re:run(String,RE) of
	{match,_} -> match(R, RouteInfo);
	nomatch -> false
    end.
