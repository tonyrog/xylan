%%% coding: latin-1
%%%---- BEGIN COPYRIGHT --------------------------------------------------------
%%%
%%% Copyright (C) 2016, Rogvall Invest AB, <tony@rogvall.se>
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
%%%---- END COPYRIGHT ----------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Marina Westman Lönne <malotte@malotte.net>
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%        Test of Xylan 
%%%
%%% Created : August 2016 by Marina Westman Lönne
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_SUITE).

%% Note: This directive should only be used in test suites.
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(SERVER, xylan_server).
-define(CLIENT, xylan_client).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%%  Returns list of tuples to set default properties
%%  for the suite.
%%
%% Note: The suite/0 function is only meant to be used to return
%% default data values, not perform any other operations.
%%
%% @end
%%--------------------------------------------------------------------
-spec suite() -> Info::list(tuple()).

suite() ->
    [{timetrap,{minutes,10}}].


%%--------------------------------------------------------------------
%% @doc
%%  Returns the list of groups and test cases that
%%  are to be executed.
%%
%% @end
%%--------------------------------------------------------------------
-spec all() -> list(GroupsAndTestCases::atom() | tuple()) | 
	       {skip, Reason::term()}.

all() -> 
    [
     break
    ].

%%--------------------------------------------------------------------
%% @doc
%% Returns a list of test case group definitions.
%% @end
%%--------------------------------------------------------------------
-spec groups() -> 
    [{GroupName::atom(),
      list(Prop::parallel | 
		 sequence | 
		 shuffle | {shuffle,Seed::{integer(),integer(),integer()}} |
		 repeat | 
		 repeat_until_all_ok | 
		 repeat_until_all_fail |              
		 repeat_until_any_ok | 
		 {repeat_until_any_fail,N::integer() | forever}),
      list(TestCases::atom())}].

groups() ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% Initialization before the whole suite
%% @end
%%--------------------------------------------------------------------
-spec init_per_suite(Config0::list(tuple())) ->
			    (Config1::list(tuple())) | 
			    {skip,Reason::term()} | 
			    {skip_and_save,Reason::term(),
			     Config1::list(tuple())}.
init_per_suite(Config) ->
    start_system(Config),
    Config.

%%--------------------------------------------------------------------
%% @doc
%% Cleanup after the whole suite
%% @end
%%--------------------------------------------------------------------
-spec end_per_suite(Config::list(tuple())) -> ok.

end_per_suite(Config) ->
    stop_system(Config),
    ok.


%%--------------------------------------------------------------------
%% @doc
%% Initialization before each test case group.
%% @end
%%--------------------------------------------------------------------
-spec init_per_group(GroupName::atom(), Config0::list(tuple())) ->
			    Config1::list(tuple()) | 
			    {skip,Reason::term()} | 
			    {skip_and_save,Reason::term(),
			     Config1::list(tuple())}.

init_per_group(GroupName, Config) ->
    ct:pal("TestGroup: ~p", [GroupName]),
    Config.

%%--------------------------------------------------------------------
%% @doc
%% Cleanup after each test case group.
%%
%% @end
%%--------------------------------------------------------------------
-spec end_per_group(GroupName::atom(), Config0::list(tuple())) ->
			   no_return() | 
			   {save_config, Config1::list(tuple())}.

end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Initialization before each test case
%% @end
%%--------------------------------------------------------------------
-spec init_per_testcase(TestCase::atom(), Config0::list(tuple())) ->
			    (Config1::list(tuple())) | 
			    {skip,Reason::term()} | 
			    {skip_and_save,Reason::term(),
			     Config1::list(tuple())}.

init_per_testcase(TestCase, Config) ->
    ct:pal("TestCase: ~p", [TestCase]),
    Config.


%%--------------------------------------------------------------------
%% @doc
%% Cleanup after each test case
%% @end
%%--------------------------------------------------------------------
-spec end_per_testcase(TestCase::atom(), Config0::list(tuple())) ->
			      ok |
			      {save_config,Config1::list(tuple())}.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
	
  

%%--------------------------------------------------------------------
%% @doc 
%% Dummy test case to have a test environment running.
%% Stores Config in ets table.
%% @end
%%--------------------------------------------------------------------
-spec break(Config::list(tuple())) -> ok.

break(Config) ->
    ets:new(config, [set, public, named_table]),
    ets:insert(config, Config),
    test_server:break("Break for test development\n" ++
		      "Get Config by C = ets:tab2list(config)."),
    ok.


%%--------------------------------------------------------------------
%% Help functions
%%--------------------------------------------------------------------

start_system(Config) ->
    ok = start_xylan(Config, ?SERVER, "server.config"),
    timer:sleep(1000),
    ok = start_xylan(Config, ?CLIENT, "client.config"),
    ok.

stop_system(_Config) ->
    ok = stop_xylan(?CLIENT),
    timer:sleep(1000),
    ok = stop_xylan(?SERVER),
    ok.

start_xylan(Config, Name, File0) ->
    File1 = filename:join(?config(data_dir, Config), File0),
    ct:pal("Using ~p for configuration", [File1]),
    NodeName =
	case ct_slave:start(Name,
			    [{erl_flags, " -s xylan -config " ++ File1},
			     {monitor_master, true}, {boot_timeout, 5}]) of
	    {ok, NN} ->
		NN;
	    {error, started_not_connected, NN} ->
		pong = net_adm:ping(NN),
		NN;
	    Other ->
		ct:pal("Start of ~p failed, reason ~p", [Name, Other]),
		undefined
	    end,
    ct:pal("xylan node ~p started", [NodeName]),
    ok.
    
stop_xylan(Node) ->
    ct_slave:stop(Node).
    
