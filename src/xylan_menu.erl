%%% coding: latin-1
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
%%% @author Malotte Westman Lönne <malotte@malotte.net>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Proxy wedding ssh with host menu.
%%%
%%% Created : Jan 2015 by Malotte W Lonne
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_menu).

-export([spec/0, example/0, menu/0]).

-include("xylan_log.hrl").

menu() ->
    Spec = spec(),
    Config = example(),
    %% Validate start spec
    hex:validate_flags(Config, Spec),
    Db = load(Config, []),
    ?debug("menu: db ~p", Db),
    Output = fun(Key) ->
		     io:format("~p~n",[Key])
	     end,
    Input = fun() ->
		    io:get_line(">")
	    end,

    menu_loop(Spec, Db, Output, Input).

menu_loop(Spec, Db, Output, Input) ->
    case menu(Spec, Spec, Db, Output, Input) of
	repeat -> 
	    menu_loop(Spec, Db, Output, Input);
	{continue, NewSpec} -> 
	    menu_loop(push(NewSpec, Spec), Db, Output, Input);
	{continue, NewSpec, NewDb} -> 
	    menu_loop(push(NewSpec, Spec), NewDb, Output, Input);
	back -> 
	    menu_loop(pop(Spec), Db, Output, Input);
	exit -> 
	    ok
    end.

push(New, Old) ->
    [New, Old].

pop([_Last | Prev]) ->
    Prev.


menu([], Spec, Db, _Output, Input) ->
    Choice = Input(),
    case Choice of
	"..\n" -> back;
	".\n" -> repeat;
	"?\n" -> repeat;
	"exit\n" -> exit;
	_ -> scan_input(Choice, Spec, Db)
    end;
menu([{key, Key, _TS} | List], Spec, Db, Output, Input) ->
    ?debug("menu: key ~p ignored.",[Key]),
    menu(List, Spec, Db, Output, Input);
menu([{_Type, Key, _TS} | List], Spec, Db, Output, Input) ->
    Output(Key),
    menu(List, Spec, Db, Output, Input).


scan_input(Choice, Spec, Db) ->
    case string:tokens(Choice, [$ , $\n]) of
	[Key, Value] -> search_spec(list_to_atom(Key), Value, Spec, Db);
	[Key] -> search_spec(list_to_atom(Key), "", Spec, Db);
	_ -> repeat
    end.

search_spec(Key, Value, Spec, Db) ->
    ?debug("search_spec: ~p = ~p, ~p, ~p", [Key, Value, Spec, Db]),
    case lists:keyfind(Key, 2, Spec) of
	{leaf, Key, TS} -> verify_ts(Key, Value, TS, Spec, Db);
	{key, Key, []} = KeyPost -> search_spec(Key, Value, lists:delete(KeyPost, Spec), Db);
	{_, Key, NewSpec} -> {continue, NewSpec} %% Pushed on old spec ??
    end.

verify_ts(Key, Value, [{type, enumeration, Enums}], Spec, Db) ->
    case lists:keymember(list_to_atom(Value), 2, Enums) of
	true -> change_config(Key, list_to_atom(Value), Spec, Db);
	false ->repeat
    end;
verify_ts(Key, Value, [{type, string, _}], Spec, Db) when is_list(Value) ->
    change_config(Key, Value, Spec, Db);
verify_ts(_Key, _Value, [{type, string, _}], _Spec, _Db) ->
    repeat;
verify_ts(Key, Value, [{type, UInt, _}], Spec, Db) when UInt =:= uint32;
							UInt =:= uint64 ->
    try list_to_integer(Value) of
	Int -> change_config(Key, Int, Spec, Db)
    catch
	error:_E -> repeat
    end.
	    
change_config(Key, Value, Spec, Db) ->
    ?debug("change_config: ~p = ~p", [Key,Value]),
    {continue, Spec, Db}. 
			       
	    
load([], Db) ->
    Db;
load([{Key, [Value]} | Rest], Db) when is_tuple(Value) -> 
    load(Rest, load_list(Key, 1, Value, []) ++ Db);
load([{_Key, Value} | Rest], Db) when is_tuple(Value) ->	    
    load(Rest, Db);
load([{Key, Value} | Rest], Db) ->
    load(Rest, [{Key, Value} |Db]).

load_list(_Key, _N, [], Acc) ->
    Acc;
load_list(Key, N, [{Key, Value} | Rest], Acc) ->
    load_list(Key, N+1, Rest, [{[Key, N, Key], Value} | Acc]).


spec() ->
    [
     {leaf, mode, [{type, enumeration, [{enum, server, []},
					{enum, client, []}]}]},
     {leaf, id, [{type, string, []}]},
     {list, ports, 
      [{key, port, []},
       {choice, port,
	[
	 {'case', number,
	  [{leaf, number, [{type, uint32, []}]}]},
	 {'case', 'interface-and-number',
	  [{container, 'interface-and-number', 
	    [{leaf, interface, [{type, string, []}]},
	     {leaf, number, [{type, uint32, []}]}]}]}]}]},
     {leaf, client_port, [{type, uint32, []}]},
     {leaf, data_port, [{type, uint32, []}]},
     {leaf, auth_timeout, [{type, uint32, []}]},
     {leaf, data_timeout, [{type, uint32, []}]},
     {list, clients, 
      [{key, client, []},
       {container, client,
	[{leaf, name, [{type, string, []}]},
	 {choice, server_key,
	  [{'case', binarykey,
	    [{leaf, binarykey, [{type, binary, []}]}]},
	   {'case', stringkey,
	    [{leaf, stringkey, [{type, string, []}]}]},
	   {'case', uintkey,
	    [{leaf, uintkey, [{type, uint64, []}]}]}]},
	 {choice, client_key,
	  [{'case', binarykey,
	    [{leaf, binarykey, [{type, binary, []}]}]},
	   {'case', stringkey,
	    [{leaf, stringkey, [{type, string, []}]}]},
	   {'case', uintkey,
	    [{leaf, uintkey, [{type, uint64, []}]}]}]},
	 {list, matches,
	  [{key, match, []},
	   {container, match,
	    [{leaf, data, [{type, string, []}]},
	     {leaf, ip, [{type, 'yang:ip-address', []}]},
	     {leaf, port, [{type, uint32, []}]}]}]}]}]}].
	   
		      
example() ->
[{mode, server},
 {id, "server"},   %% id of server (may be used when server is also client?)
 {ports, 
  [{number, 46122},
   {'interface-and-number',[{interface, "en1"},{number, 2222}]},
   {'ip-and-number',[{ip, {127,0,0,1}}, {number, 2222}]}]},
 {client_port, 29390},  %% port where client connects
 {data_port,   29391},  %% client callback proxy port
 {auth_timeout, 5000},  %% client session auth timeout
 {data_timeout, 5000},  %% user initial data timeout
 {clients,  %% configure known clients
  [{client,
    [{name, "local"},
     {server_key, {uintkey, 3177648541185394227}},   %% server is signing using this key
     {client_key, {uintkey, 12187761947737533676}},  %% client is signing using this key
     {matches,
      [{match, [{data, "SSH-2.0.*"}]},   %% match port and initial
       {match, [{data, "GET .*"}]}]       %% match a specific url
     }
    ]}
]} 

  ].
