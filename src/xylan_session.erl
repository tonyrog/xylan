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
%%%    Proxy server session, holds the connection to the "client" proxy
%%%
%%% Created : 18 Dec 2014 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_session).

-behaviour(gen_server).

%% API
-export([start/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% test
-export([dump/0]).

-type timer() :: reference().

-include("xylan_log.hrl").
-include("xylan_socket.hrl").

-define(MAX_PENDING, 8).  %% max concurrent unauthenticated sockets

%% A control socket that is not yet authenticated. The active (authenticated)
%% socket is kept until a pending socket has proved knowledge of the client
%% key, so a peer that only knows the client id can not close the session.
-record(pending, {
	  socket :: xylan_socket:xylan_socket(),
	  tls = false :: boolean(),
	  alg = sha :: sha | hmac_sha256,
	  chal :: binary(),       %% our challenge to the client
	  timer :: timer(),       %% auth timeout
	  tags :: {atom(),atom(),atom()}
	 }).

-record(state, {
	  server_id  :: string(),
	  client_id  :: string(),
	  client_key :: binary(),
	  server_key :: binary(),
	  client_auth = false :: boolean(), %% true when socket is authenticated
	  tls = false :: boolean(),          %% active control channel is tls
	  require_tls = false :: boolean(),  %% only accept tls+hmac_sha256
	  auth_timeout :: timeout(),
	  ping_timeout :: timeout(),
	  ping_timer :: timer(),
	  ping_time :: erlang:timestamp(),
	  session_time :: erlang:timestamp(),
	  tag=tcp,tag_closed=tcp_closed,tag_error=tcp_error,
	  parent :: pid(),
	  mon    :: reference(), %% parent monitor
	  socket :: xylan_socket:xylan_socket(), %% active authenticated socket
	  pending = [] :: [#pending{}]
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
start() ->
    gen_server:start(?MODULE, [self()], []).

dump() ->
    gen_server:call(?MODULE, dump).
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
init([Parent]) ->
    Mon = erlang:monitor(process, Parent),
    {ok, #state{parent=Parent, mon=Mon }}.



%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------

handle_call(get_status, _From, State) ->
    Status =
	if State#state.client_auth =:= true ->
		LastPing = time_since_ms(os:timestamp(),
					 State#state.ping_time),
		SessionTime = time_since_ms(os:timestamp(),
					    State#state.session_time),
		[{status,up},{session_time,SessionTime},{last_ping,LastPing},
		 {tls,State#state.tls}];
	   State#state.pending =/= [] ->
		[P|_] = State#state.pending,
		AuthTimeRemain = read_timer(P#pending.timer),
		[{status,auth},{auth_time_remain,AuthTimeRemain}];
	   true ->
		LastSeen = time_since_ms(os:timestamp(),
					 State#state.session_time),
		[{status,down},{last_seen,LastSeen}]
	end,
    {reply, {ok, [{id,State#state.client_id} | Status]}, State};

handle_call(dump, _From, State) ->
    io:format("State:\n~p\n",[State]),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    ?warning("got unknown request ~p\n", [_Request]),
    Reply = {error,einval},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------

handle_cast({set_config,Conf}, State) ->
    State1 =
	lists:foldl(
	  fun({client_id,ID}, S)     -> S#state { client_id = ID };
	     ({server_id,ID}, S)     -> S#state { server_id = ID };
	     ({client_key,Key}, S)   -> S#state { client_key = Key };
	     ({server_key,Key}, S)   -> S#state { server_key = Key };
	     ({auth_timeout,T}, S)   -> S#state { auth_timeout = T };
	     ({ping_timeout,T}, S)   -> S#state { ping_timeout = T };
	     ({require_tls,B}, S) when is_boolean(B) ->
		  S#state { require_tls = B };
	     (Item, S) ->
		  ?warning("bad config item ~p", [Item]),
		  S
	  end, State, Conf),
    ?debug("set_config ~p", [State1]),
    {noreply, State1};

%% New control socket from xylan_srv (we are controlling process) together
%% with the initial auth_req. Reply with our credential and a challenge.
handle_cast({auth_socket, Socket, Tls, {auth_req,Props}}, State)
  when is_list(Props) ->
    ?debug("auth_req: ~p", [Props]),
    Chal = proplists:get_value(chal, Props),
    Alg  = proplists:get_value(alg, Props, sha),
    ID = State#state.client_id,
    if length(State#state.pending) >= ?MAX_PENDING ->
	    ?warning("client ~p too many pending auth sockets", [ID]),
	    close(Socket),
	    {noreply, State};
       not is_binary(Chal); byte_size(Chal) < 16 ->
	    ?warning("client ~p bad challenge", [ID]),
	    close(Socket),
	    {noreply, State};
       Alg =/= sha, Alg =/= hmac_sha256 ->
	    ?warning("client ~p unsupported auth alg ~p", [ID, Alg]),
	    close(Socket),
	    {noreply, State};
       State#state.require_tls, (Alg =/= hmac_sha256 orelse not Tls) ->
	    ?warning("client ~p requires tls and hmac_sha256 (tls=~w alg=~w)",
		     [ID, Tls, Alg]),
	    close(Socket),
	    {noreply, State};
       true ->
	    Chal1 = crypto:strong_rand_bytes(16),  %% generate challenge
	    Cred = xylan_lib:auth_cred(Alg,State#state.server_key,server,Chal),
	    send(Socket, {auth_res,[{id,State#state.server_id},
				    {chal,Chal1},{cred,Cred}]}),
	    xylan_socket:setopts(Socket, [{active,once}]),
	    Timer = start_timer(State#state.auth_timeout, auth_timeout),
	    P = #pending { socket = Socket, tls = Tls, alg = Alg,
			   chal = Chal1, timer = Timer,
			   tags = xylan_socket:tags(Socket) },
	    ?info("client ~p reply and challenge sent (tls=~w, alg=~w)",
		  [ID, Tls, Alg]),
	    {noreply, State#state { pending = [P|State#state.pending] }}
    end;

%% DataPorts = {PlainDataPort, TlsDataPort}, select data port matching
%% the control channel. The session key is bound to that channel type
%% in the parent (xylan_srv) before the route is sent to the client.
handle_cast({route,{DataPort,DataTlsPort},SessionKey,RouteInfo}, State) when
      State#state.client_auth =:= true ->
    Tls = State#state.tls,
    Port = if Tls -> DataTlsPort; true -> DataPort end,
    if is_integer(Port) ->
	    gen_server:cast(State#state.parent,
			    {session_bound, SessionKey, Tls}),
	    send(State#state.socket,{route,Port,SessionKey,RouteInfo});
       true ->
	    ?warning("client ~p no data port available (tls=~w)",
		     [State#state.client_id, Tls])
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    ?debug("got unknown msg ~p (client_auth=~p, socket=~p\n",
	   [_Msg,State#state.client_auth, State#state.socket]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------

%% data on the active (authenticated) socket
handle_info({Tag,Socket,Data}, State) when
      State#state.client_auth =:= true,
      Tag =:= State#state.tag,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    xylan_socket:setopts(State#state.socket, [{active,once}]),
    try binary_to_term(Data, [safe]) of
	ping ->
	    ?debug("got session ping", []),
	    %% client ping, just reply with pong
	    send(State#state.socket, pong),
	    cancel_timer(State#state.ping_timer),
	    Timer = start_timer(State#state.ping_timeout,ping_timeout),
	    {noreply, State#state { ping_time = os:timestamp(),
				    ping_timer = Timer }};
	Message ->
	    ?warning("got session message: ~p", [Message]),
	    {noreply, State}
    catch
	error:Reason ->
	    ?error("bad session data ~p", [{error,Reason}]),
	    {noreply, close_client(State)}
    end;

handle_info({Tag,Socket}, State) when
      State#state.client_auth =:= true,
      Tag =:= State#state.tag_closed,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    ?info("client ~p close", [State#state.client_id]),
    {noreply, close_client(State)};

handle_info({Tag,Socket,Error}, State) when
      State#state.client_auth =:= true,
      Tag =:= State#state.tag_error,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    ?info("client ~p error ~p", [State#state.client_id, Error]),
    {noreply, close_client(State)};

handle_info({timeout,TRef,ping_timeout}, State) when 
      TRef =:= State#state.ping_timer ->
    ?info("client ~p ping timeout", [State#state.client_id]),
    {noreply, close_client(State)};

handle_info({timeout,TRef,auth_timeout}, State) ->
    case lists:keytake(TRef, #pending.timer, State#state.pending) of
	{value, P, Ps} ->
	    ?info("client ~p autentication timeout", [State#state.client_id]),
	    close(P#pending.socket),
	    {noreply, State#state { pending = Ps }};
	false ->
	    {noreply, State}
    end;

handle_info(_Info={'DOWN',Ref,process,_Pid,_Reason}, State) when
      Ref =:= State#state.mon ->
    ?debug("parent died: ~p\n", [_Info]),
    {stop, _Reason, State};

%% possibly a message on a pending socket
handle_info(Info, State) when is_tuple(Info), tuple_size(Info) >= 2 ->
    Socket = element(2, Info),
    case take_pending(Socket, State#state.pending) of
	{value, P, Ps} ->
	    {noreply, pending_info(Info, P, State#state { pending = Ps })};
	false ->
	    ?warning("unexpected info ~p\n", [Info]),
	    {noreply, State}
    end;

handle_info(_Info, State) ->
    ?warning("unexpected info ~p\n", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ?debug("~p", [_Reason]),
    close(State#state.socket),
    [close(P#pending.socket) || P <- State#state.pending],
    ok.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% message on a pending socket, P is already removed from pending list
pending_info({Tag,_Socket,Data}, P=#pending{tags={Tag,_,_}}, State) ->
    cancel_timer(P#pending.timer),
    ID = State#state.client_id,
    try binary_to_term(Data, [safe]) of
	{auth_ack, [{id,_ClientID},{cred,Cred}]} ->
	    Cred0 = xylan_lib:auth_cred(P#pending.alg, State#state.client_key,
					client, P#pending.chal),
	    case xylan_lib:auth_cred_equal(Cred0, Cred) of
		true ->
		    ?info("client ~p credential accepted (tls=~w)",
			  [ID, P#pending.tls]),
		    promote(P, State);
		false ->
		    ?info("client ~p credential failed", [ID]),
		    close(P#pending.socket),
		    State
	    end;
	_Mesg ->
	    ?info("client ~p authentication failed (bad message)", [ID]),
	    close(P#pending.socket),
	    State
    catch
	error:Reason ->
	    ?error("client ~p authentication, bad data ~p",
		   [ID, {error,Reason}]),
	    close(P#pending.socket),
	    State
    end;
pending_info({Tag,_Socket}, P=#pending{tags={_,Tag,_}}, State) ->
    ?debug("client ~p pending socket closed", [State#state.client_id]),
    cancel_timer(P#pending.timer),
    close(P#pending.socket),
    State;
pending_info({Tag,_Socket,_Error}, P=#pending{tags={_,_,Tag}}, State) ->
    ?debug("client ~p pending socket error", [State#state.client_id]),
    cancel_timer(P#pending.timer),
    close(P#pending.socket),
    State;
pending_info(Info, P, State) ->
    ?warning("unexpected info ~p\n", [Info]),
    State#state { pending = [P|State#state.pending] }.

%% authenticated pending socket replaces the active socket
promote(P, State) ->
    State1 = close_client(State),
    Socket = P#pending.socket,
    {T,C,E} = P#pending.tags,
    xylan_socket:setopts(Socket, [{active,once}]),
    PingTimer = start_timer(State1#state.ping_timeout, ping_timeout),
    State1#state { socket = Socket,
		   client_auth = true,
		   tls = P#pending.tls,
		   tag=T,tag_closed=C,tag_error=E,
		   ping_timer = PingTimer,
		   session_time = os:timestamp() }.

take_pending(Socket, Ps) ->
    take_pending_(Socket, Ps, []).

take_pending_(Socket, [P|Ps], Acc) ->
    case (P#pending.socket)#xylan_socket.socket =:= Socket of
	true -> {value, P, lists:reverse(Acc, Ps)};
	false -> take_pending_(Socket, Ps, [P|Acc])
    end;
take_pending_(_Socket, [], _Acc) ->
    false.

time_since_ms(_T1, undefined) ->
    never;
time_since_ms(T1, T0) ->
    timer:now_diff(T1, T0) div 1000.

%% close the active socket (pending sockets are kept)
close_client(State) ->
    close(State#state.socket),
    cancel_timer(State#state.ping_timer),
    State#state { socket = undefined, 
		  client_auth = false,
		  tls = false,
		  ping_timer=undefined }.

close(undefined) -> ok;
close(Socket) -> xylan_socket:close(Socket).

read_timer(undefined) -> undefined;
read_timer(Timer) -> erlang:read_timer(Timer).

cancel_timer(Timer) when is_reference(Timer) ->
    erlang:cancel_timer(Timer);
cancel_timer(undefined) -> 
    false.

start_timer(undefined,_Tag) -> undefined;
start_timer(infinity,_Tag) -> undefined;
start_timer(Time,Tag) when is_integer(Time), Time >= 0 ->
    erlang:start_timer(Time,self(),Tag).
    
send(Socket, Term) ->
    xylan_socket:send(Socket, term_to_binary(Term)).
