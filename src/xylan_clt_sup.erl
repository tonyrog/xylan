%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2017, Tony Rogvall
%%% @doc
%%%
%%% @end
%%% Created : 18 Mar 2017 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(xylan_clt_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-define(CHILD(I, E, Type), {I, {I, start_link, E}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart intensity, and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    Servers = case application:get_env(xylan, servers) of
		  {ok,List} -> List;
		  undefined -> []
	      end,
    ChildList =
	if Servers =:= [] ->
		Name = case application:get_env(xylan, server_id) of
			   {ok,ID} -> ID;
			   _ -> ""
		       end,
		[{Name, {xylan_clt,start_link,[[{server_id,Name}]]},
		  permanent, 5000, worker, [xylan_clt]}];
	   true ->
		[{Name, {xylan_clt,start_link,[[{server_id,Name}]]},
		  permanent, 5000, worker, [xylan_clt]} ||
		    {Name,_Opts}<-Servers]
	end,
    {ok, { {one_for_one, 5, 10}, ChildList} }.

%%%===================================================================
%%% Internal functions
%%%===================================================================

