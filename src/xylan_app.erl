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
-module(xylan_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-export([config_change/3]).
%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    xylan_sup:start_link().

stop(_State) ->
    ok.

%% application changed config callback
config_change(Changed,New,Removed) ->
    case erlang:whereis(xylan_srv) of
	undefined ->
	    case erlang:whereis(xylan_clt) of
		undefined ->
		    ok;
		Clt when is_pid(Clt) ->
		    xylan_clt:config_change(Changed,New,Removed)
	    end;
	Srv when is_pid(Srv) ->
	    xylan_srv:config_change(Changed,New,Removed)
    end.
