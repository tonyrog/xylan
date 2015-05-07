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
%%%    Proxy server session hold the connection to the "client" proxy
%%% @end
%%% Created : 18 Dec 2014 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(xylan_session).

-behaviour(gen_server).

%% API
-export([start/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type timer() :: reference().

-include_lib("lager/include/log.hrl").
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
	  tag=tcp,tag_closed=tcp_closed,tag_error=tcp_error,
	  parent :: pid(),
	  mon    :: reference(),  %% parent monitor
	  socket :: xylan_socket:xylan_socket()  %% client proxy socket
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
start(AuthTimeout) ->
    gen_server:start(?MODULE, [self(),AuthTimeout], []).

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
init([Parent,AuthTimeout]) ->
    Mon = erlang:monitor(process, Parent),
    {ok, #state{parent=Parent, mon = Mon, 
		auth_timeout = AuthTimeout
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
    ?warning("~s:handle_call: got ~p\n", [_Request]),
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
    close(State#state.socket),  %% close old socket
    {T,C,E} = xylan_socket:tags(Socket),
    xylan_socket:setopts(Socket, [{active,once}]),
    Timeout = State#state.auth_timeout,
    TRef=erlang:start_timer(Timeout,self(),auth_timeout),
    {noreply, State#state { socket=Socket,auth_timer=TRef,tag=T,tag_closed=C,tag_error=E }};
handle_cast({set_config,Conf}, State) ->
    State1 =
	lists:foldl(
	  fun({client_id,ID}, S)   -> S#state { client_id = ID };
	     ({server_id,ID}, S)   -> S#state { server_id = ID };
	     ({client_key,Key}, S) -> S#state { client_key = Key };
	     ({server_key,Key}, S) -> S#state { server_key = Key }
	  end, State, Conf),
    ?debug("set_config ~p", [State1]),
    {noreply, State1};
%% server has set config and accepted the challange go on and issue the challenge
handle_cast(_Req={auth_req,[{id,_ID},{chal,Chal}]}, State) when
      State#state.client_auth =:= false ->
    ?debug("auth_req: ~p", [_Req]),
    Chal1 = crypto:rand_bytes(16),  %% generate challenge
    %% crypto:sha is used instead of crypto:hash R15!!
    Cred = crypto:sha([State#state.server_key,Chal]), %% server cred
    send(State#state.socket, {auth_res,[{id,State#state.server_id},{chal,Chal1},{cred,Cred}]}),
    ?info("client ~p reply and challenge sent", [State#state.client_id]),
    {noreply, State#state { client_chal = Chal1 }};
handle_cast(Route={route,_DataPort,_SessionKey,_RouteInfo}, State) when
      State#state.client_auth =:= true ->
    send(State#state.socket,Route),
    {noreply, State};
handle_cast(_Msg, State) ->
    ?debug("handle_cast: got ~p (client_auth=~p, socket=~p\n", 
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
	    ?debug("auth_ack: ~p", [_Mesg]),
	    %% crypto:sha is used instead of crypto:hash R15!!
	    case crypto:sha([State#state.client_key,State#state.client_chal]) of
		Cred ->
		    ?info("client ~p credential accepted", [State#state.client_id]),
		    xylan_socket:setopts(State#state.socket, [{active,once}]),
		    cancel_timer(State#state.auth_timer),
		    {noreply, State#state { auth_timer = undefined, client_auth = true }};
		_CredFail ->
		    ?info("client ~p credential failed", [State#state.client_id]),
		    close(State#state.socket),
		    {noreply, State#state { socket = undefined,
					    client_auth = false}}
	    end;
	_Mesg ->
	    close(State#state.socket),
	    ?info("client ~p authentication failed (bad message)", [State#state.client_id]),
	    {noreply, State#state { socket = undefined, client_auth = false}}
    catch
	error:Reason ->
	    ?error("client ~p authentication,bad data ~p", [{error,Reason}]),
	    close(State#state.socket),
	    {noreply, State#state { socket = undefined, client_auth = false}}
    end;

handle_info({Tag,Socket,Data}, State) when 
      Tag =:= State#state.tag,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    xylan_socket:setopts(State#state.socket, [{active,once}]),
    try binary_to_term(Data, [safe]) of
	ping when State#state.client_auth =:= true ->
	    ?debug("got session ping", []),
	    send(State#state.socket, pong),  %% client ping, just reply with pong
	    {noreply, State};
	Message ->
	    ?warning("got session message: ~p", [Message]),
	    {noreply, State}
    catch
	error:Reason ->
	    ?error("bad session data ~p", [{error,Reason}]),
	    close(State#state.socket),
	    {noreply, State#state { socket = undefined, client_auth = false}}
    end;

handle_info({Tag,Socket}, State) when
      Tag =:= State#state.tag_closed,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    ?info("client ~p close", [State#state.client_id]),
    close(State#state.socket),
    cancel_timer(State#state.auth_timer),
    {noreply, State#state { socket = undefined, client_auth = false, auth_timer=undefined }};

handle_info({Tag,Socket,Error}, State) when
      Tag =:= State#state.tag_error,
      Socket =:= (State#state.socket)#xylan_socket.socket ->
    ?info("client ~p error ~p", [State#state.client_id, Error]),
    close(State#state.socket),
    cancel_timer(State#state.auth_timer),
    {noreply, State#state { socket = undefined, client_auth = false, auth_timer=undefined }};

handle_info({timeout,TRef,auth_timeout}, State) when 
      TRef =:= State#state.auth_timer ->
    ?info("client ~p autentication timeout", [State#state.client_id]),
    close(State#state.socket),
    {noreply, State#state { socket = undefined, client_auth = false, auth_timer=undefined }};

handle_info(_Info={'DOWN',Ref,process,_Pid,_Reason}, State) when
      Ref =:= State#state.mon ->
    ?debug("handle_info: got: ~p\n", [_Info]),
    {stop, _Reason, State};

handle_info(_Info, State) ->
    ?warning("handle_info: got ~p\n", [_Info]),
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
    ?debug("terminate ~p", [_Reason]),
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

close(undefined) -> ok;
close(Socket) -> xylan_socket:close(Socket).

cancel_timer(Timer) when is_reference(Timer) -> 
    erlang:cancel_timer(Timer);
cancel_timer(undefined) -> false.

send(Socket, Term) ->
    xylan_socket:send(Socket, term_to_binary(Term)).
