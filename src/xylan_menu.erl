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
%%% @author Malotte Westma Lonne <malotte@malotte.net>
%%% @copyright (C) 2014, Tony Rogvall
%%% @doc
%%%    Proxy wedding ssh with host menu.
%%%
%%% Created : Jan 2015 by Malotte W Lonne
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_menu).

-include_lib("lager/include/log.hrl").
-include_lib("ssh/include/ssh.hrl").

-export([spec/0, example/0, menu/0]).

menu() ->
    Spec = spec(),
    Config = example(),
    %% Validate start spec
    hex:validate_flags(Config, Spec),
    Output = fun(Key) ->
		     io:format("~p~n",[Key])
	     end,
    Input = fun() ->
		    io:get_line(">")
	    end,

    menu_loop(Spec, Config, Output, Input).

menu_loop(Spec, Config, Output, Input) ->
    case menu(Spec, Spec, Config, Output, Input) of
	repeat -> menu_loop(Spec, Config, Output, Input);
	{continue, NewSpec} -> menu_loop(NewSpec, Config, Output, Input);
	{continue, NewSpec, NewConfig} -> menu_loop(NewSpec, NewConfig, Output, Input);
	exit -> ok
    end.



menu([], Spec, Config, Output, Input) ->
    Choice = Input(),
    case Choice of
	"?\n" -> repeat;
	"exit\n" -> exit;
	_ -> scan_input(Choice, Spec, Config)
    end;
menu([{key, Key, TS} | List], Spec, Config, Output, Input) ->
    lager:debug("menu: key ~p ignored.",[Key]),
    menu(List, Spec, Config, Output, Input);
menu([{Type, Key, TS} | List], Spec, Config, Output, Input) ->
    Output(Key),
    menu(List, Spec, Config, Output, Input).


scan_input(Choice, Spec, Config) ->
    case string:tokens(Choice, [$ , $\n]) of
	[Key, Value] -> search_spec(list_to_atom(Key), Value, Spec, Config);
	[Key] -> search_spec(list_to_atom(Key), "", Spec, Config);
	_ -> repeat
    end.

search_spec(Key, Value, Spec, Config) ->
    lager:debug("search_spec: ~p = ~p, ~p, ~p", [Key, Value, Spec, Config]),
    case lists:keyfind(Key, 2, Spec) of
	{leaf, Key, TS} -> verify_ts(Key, Value, TS, Spec, Config);
	{_, Key, NewSpec} -> {continue, NewSpec} %% Pushed on old spec ??
    end.

verify_ts(Key, Value, [{type, enumeration, Enums}], Spec, Config) ->
    case lists:keymember(list_to_atom(Value), 2, Enums) of
	true -> change_config(Key, list_to_atom(Value), Spec, Config);
	false ->repeat
    end;
verify_ts(Key, Value, [{type, string, _}], Spec, Config) when is_list(Value) ->
    change_config(Key, Value, Spec, Config);
verify_ts(Key, Value, [{type, string, _}], Spec, Config) ->
    repeat;
verify_ts(Key, Value, [{type, uint32, _}], Spec, Config) ->
    try list_to_integer(Value) of
	Int -> change_config(Key, Int, Spec, Config)
    catch
	error:_E -> repeat
    end.
	    
change_config(Key, Value, Spec, Config) ->
    lager:debug("change_config: ~p = ~p", [Key,Value]),
    {continue, Spec, Config}. %% Pushed on old config ??
			       
	    
	    

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
	     {leaf, number, [{type, uint32, []}]}]}]},
	 {'case', 'ip-and-number',
	  [{container, 'ip-and-number',
	    [{leaf, ip, [{type, 'yang:ip-address', []}]},
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
