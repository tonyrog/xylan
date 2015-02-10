%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2015, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @author Marina Westman Lonne <malotte@venus.local>
%%% @copyright (C) 2015, Marina Westman Lonne
%%% @doc
%%%            Dummy connection manager
%%% Created :  9 Feb 2015 by Marina Westman Lonne 
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_dummy_cm).

-behaviour(gen_fsm).

-include_lib("lager/include/log.hrl").

%% API
-export([start_link/1,
	 close/2]).

%% gen_fsm callbacks
-export([init/1, 
	 run/2, 
	 run/3, 
	 handle_event/3,
	 handle_sync_event/4, 
	 handle_info/3, 
	 terminate/3, 
	 code_change/4]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [Args], []).


%%--------------------------------------------------------------------
-spec close(pid(), term()) -> ok.
%%--------------------------------------------------------------------
close(ConnectionHandler, ChannelId) ->
    gen_fsm:sync_send_all_state_event(ConnectionHandler, {close, ChannelId}).


%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([Pid]) ->
    ?debug("init: pid ~p", [Pid]),
    gen_fsm:send_event(self(), {manipulate, Pid}),
    {ok, run, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @spec run(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
run({manipulate, Pid} = _Event, State) ->
    ?debug("run: ~p", [_Event]),
    %% Ugly hack to make ssh_channel NOT terminate
    %% when receiving closed from user side.
    %% Will only work if ssh_channel state record is unchanged
    ?debug("run: old state: ~n~p", [sys:get_state(Pid)]),
    %% state tuple from ssh_channel
    Self = self(),
    sys:replace_state(Pid, fun(SSHState) ->
				   setelement(2, SSHState, Self)
			   end),
    ?debug("run: new state: ~n~p", [sys:get_state(Pid)]),
    Pid ! xylan_dummy_up,
    {next_state, run, State};

run(_Event, State) ->
    ?debug("run: ~p", [_Event]),
    {next_state, run, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @spec run(Event, From, State) ->
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, Reply,NewState}
%% @end
%%--------------------------------------------------------------------
run(_Event, _From, State) ->
    ?debug("run: ~p", [_Event]),
    {reply, ok, run, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    ?debug("handle_event: ~p", [_Event]),
   {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event({close, _ChannelId} = _Event, _, StateName, State) ->
    ?debug("handle_sync_event: ~p", [_Event]),
    {reply, ok, StateName, State};

handle_sync_event(_Event, _From, StateName, State) ->
    ?debug("handle_sync_event: ~p", [_Event]),
    {reply, ok, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    ?debug("handle_info: ~p", [_Info]),
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
   ?debug("terminate: ~p", [_Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


