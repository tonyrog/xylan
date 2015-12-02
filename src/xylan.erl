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
%%%    Proxy wedding server, accept "clients" proxies to register a session
%%%    to act as the real servers. Users connect and rules determine where
%%%    the connection will be sent.
%%% @end
%%% Created : 18 Dec 2014 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(xylan).

-export([start/0]).
-export([status/0]).
-export([generate_key/0]).

start() ->
    lager:start(),
    ssl:start(),
    application:start(xylan).

status() ->
    Env = application:get_all_env(xylan),
    case proplists:get_value(mode,Env) of    
	client ->
	    case xylan_clt:get_status() of
		{ok,Status} ->
		    format_prop_list(Status);
		_Error ->
		    io:format("error: ~p\n", [_Error])
	    end;
	server ->
	    case xylan_srv:get_status() of
		{ok,StatusLists} ->
		    lists:foreach(fun format_prop_list/1, StatusLists);
		_Error ->
		    io:format("error: ~p\n", [_Error])
	    end
    end.

format_prop_list(PropList) ->
    lists:foreach(fun display_prop/1, PropList),
    io:format("\n", []).
		    
display_prop({K,V}) ->
    Key = atom_to_list(K),
    Value = if is_integer(V) -> integer_to_list(V);
	       is_atom(V) -> atom_to_list(V);
	       is_list(V) -> V
	    end,
    io:format("~s=~s ", [Key,Value]).

%% Generate a 64-bit random key used for signing packets
generate_key() ->
    <<X:64>> = crypto:rand_bytes(8),
    X.

    
