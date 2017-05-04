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

-include("xylan_socket.hrl").

-record(state, {
	  server_id  :: string(),
	  client_id  :: string(),
	  client_key :: binary(),
	  server_key :: binary(),
	  client_auth = false :: boolean(),
	  client_chal = <<>> :: binary(),
	  auth_timeout :: timeout(),
	  auth_timer :: timer(),
	  ping_timeout :: timeout(),
	  ping_timer :: timer(),
	  ping_time :: erlang:timestamp(),
	  session_time :: erlang:timestamp(),
	  tag=tcp,tag_closed=tcp_closed,tag_error=tcp_error,
	  parent :: pid(),
	  mon    :: reference(), %% parent monitor
	  %% fixme: close socket if now ping arrive in time
	  socket :: xylan_socket:xylan_socket()
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

handle_call(get_status, _From, State) ->
    Status =
	if State#state.socket =/= undefined,
	   State#state.client_auth =:= false ->
		AuthTimeRemain = erlang:read_timer(State#state.auth_timer),
		[{status,auth},{auth_time_remain,AuthTimeRemain}];
	   State#state.socket =/= undefined,
	   State#state.client_auth =:= true ->
		LastPing = time_since_ms(os:timestamp(),
					 State#state.ping_time),
		SessionTime = time_since_ms(os:timestamp(),
					    State#state.session_time),
		[{status,up},{session_time,SessionTime},{last_ping,LastPing}];
	   State#state.socket =:= undefined ->
		LastSeen = time_since_ms(os:timestamp(),
					 State#state.session_time),
		[{status,down},{last_seen,LastSeen}]
	end,
    {reply, {ok, [{id,State#state.client_id} | Status]}, State};

handle_call(dump, _From, State) ->
    io:format("State:\n~p\n",[State]),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    lager:warning("got unknown request ~p\n", [_Request]),
    Reply = {error,einval},
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
handle_cast({set_socket, Socket}, State) ->
    State1 = close_client(State),  %% close old socket
    {T,C,E} = xylan_socket:tags(Socket),
    xylan_socket:setopts(Socket, [{active,once}]),
    Timer = start_timer(State1#state.auth_timeout,auth_timeout),
    {noreply, State1#state { socket=Socket,
			     auth_timer=Timer,
			     session_time = os:timestamp(),
			     tag=T,tag_closed=C,tag_error=E }};

handle_cast({set_config,Conf}, State) ->
    State1 =
	lists:foldl(
	  fun({client_id,ID}, S)     -> S#state { client_id = ID };
	     ({server_id,ID}, S)     -> S#state { server_id = ID };
	     ({client_key,Key}, S)   -> S#state { client_key = Key };
	     ({server_key,Key}, S)   -> S#state { server_key = Key };
	     ({auth_timeout,T}, S)   -> S#state { auth_timeout = T };
	     ({ping_timeout,T}, S)   -> S#state { ping_timeout = T };
	     (Item, S) ->
		  lager:warning("bad config item ~p", [Item]),
		  S
	  end, State, Conf),
    lager:debug("set_config ~p", [State1]),
    {noreply, State1};

%% server has set config and accepted the challenge
%% go on and issue the challenge
handle_cast(_Req={auth_req,[{id,_ID},{chal,Chal}]}, State) when
      State#state.client_auth =:= false ->
    lager:debug("auth_req: ~p", [_Req]),
    Chal1 = crypto:strong_rand_bytes(16),  %% generate challenge
    Cred = crypto:hash(sha,[State#state.server_key,Chal]), %% server cred
    send(State#state.socket, {auth_res,[{id,State#state.server_id},
					{chal,Chal1},{cred,Cred}]}),
    lager:info("client ~p reply and challenge sent", [State#state.client_id]),
    {noreply, State#state { client_chal = Chal1 }};

handle_cast(Route={route,_DataPort,_SessionKey,_RouteInfo}, State) when
      State#state.client_auth =:= true ->
    send(State#state.socket,Route),
    {noreply, State};

handle_cast(_Msg, State) ->
    lager:debug("got unknown msg ~p (client_auth=~p, socket=~p\n",
	   [_Msg,State#state.client_auth, State#state.socket]),
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

handle_info({Tag,Socket,Data}, State) when 
      Tag =:= State#state.tag,
      Socket =:= (State#state.socket)#xylan_socket.socket,
      State#state.client_auth =:= false ->
    try binary_to_term(Data, [safe]) of
	_Mesg={auth_ack, [{id,_ClientID},{cred,Cred}]} ->
	    lager:debug("auth_ack: ~p", [_Mesg]),
	    case crypto:hash(sha,[State#state.client_key,State#state.client_chal]) of
		Cred ->
		    lager:info("client ~p credential accepted", 
			  [State#state.client_id]),
		    xylan_socket:setopts(State#state.socket,[{active,once}]),
		    cancel_timer(State#state.auth_timer),
		    PingTimer = start_timer(State#state.ping_timeout,
					    ping_timeout),
		    {noreply, State#state { auth_timer = undefined,
					    ping_timer = PingTimer,
					    client_auth = true }};
		_CredFail ->
		    lager:info("client ~p credential failed", 
			  [State#state.client_id]),
		    {noreply, close_client(State)}
	    end;
	_Mesg ->
	    lager:info("client ~p authentication failed (bad message)", 
		  [State#state.client_id]),
	    {noreply, close_client(State)}
    catch
	error:Reason ->
	    lager:error("client ~p authentication,bad data ~p", 
			[{error,Reason}]),
	    {noreply, close_client(State)}
    end;

handle_info({Tag,Socket,Data}, State) when 
      Tag =:= State#state.tag,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    xylan_socket:setopts(State#state.socket, [{active,once}]),
    try binary_to_term(Data, [safe]) of
	ping when State#state.client_auth =:= true ->
	    lager:debug("got session ping", []),
	    %% client ping, just reply with pong
	    send(State#state.socket, pong),
	    cancel_timer(State#state.ping_timer),
	    Timer = start_timer(State#state.ping_timeout,ping_timeout),
	    {noreply, State#state { ping_time = os:timestamp(),
				    ping_timer = Timer }};
	Message ->
	    lager:warning("got session message: ~p", [Message]),
	    {noreply, State}
    catch
	error:Reason ->
	    lager:error("bad session data ~p", [{error,Reason}]),
	    {noreply, close_client(State)}
    end;

handle_info({Tag,Socket}, State) when
      Tag =:= State#state.tag_closed,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    lager:info("client ~p close", [State#state.client_id]),
    {noreply, close_client(State)};

handle_info({Tag,Socket,Error}, State) when
      Tag =:= State#state.tag_error,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    lager:info("client ~p error ~p", [State#state.client_id, Error]),
    {noreply, close_client(State)};

handle_info({timeout,TRef,auth_timeout}, State) when
      TRef =:= State#state.auth_timer ->
    lager:info("client ~p autentication timeout", [State#state.client_id]),
    {noreply, close_client(State)};

handle_info({timeout,TRef,ping_timeout}, State) when 
      TRef =:= State#state.ping_timer ->
    lager:info("client ~p ping timeout", [State#state.client_id]),
    {noreply, close_client(State)};

handle_info(_Info={'DOWN',Ref,process,_Pid,_Reason}, State) when
      Ref =:= State#state.mon ->
    lager:debug("parent died: ~p\n", [_Info]),
    {stop, _Reason, State};

handle_info(_Info, State) ->
    lager:warning("unexpected info ~p\n", [_Info]),
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
terminate(_Reason, State) ->
    lager:debug("~p", [_Reason]),
    close(State#state.socket),
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

time_since_ms(_T1, undefined) ->
    never;
time_since_ms(T1, T0) ->
    timer:now_diff(T1, T0) div 1000.

close_client(State) ->
    close(State#state.socket),
    cancel_timer(State#state.auth_timer),
    cancel_timer(State#state.ping_timer),
    State#state { socket = undefined, 
		  client_auth = false,
		  auth_timer=undefined,
		  ping_timer=undefined }.
    

close(undefined) -> ok;
close(Socket) -> xylan_socket:close(Socket).

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
