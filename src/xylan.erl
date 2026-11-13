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
-export([set_debug/1]).
-export([set_module_debug/2]).
-export([generate_key/0, generate_key/1]).
-export([cert_fingerprint/1]).
-export([generate_cert/1, generate_cert/2]).
-export([generate_ssh_host_key/1]).
-export([generate_api_key/1, generate_api_key/2]).
-export([revoke_api_key/1, list_api_keys/0]).

start() ->
    ssl:start(),
    application:start(afunix),
    application:start(xylan).

set_debug(true) ->
    logger:set_primary_config(level, debug);
set_debug(false) ->
    logger:set_primary_config(level, info).

set_module_debug(Module, true) ->
    logger:set_module_level(Module, debug);
set_module_debug(Module, false) ->
    logger:set_module_level(Module, info).

status() ->
    Env = application:get_all_env(xylan),
    case proplists:get_value(mode,Env) of    
	client ->
	    case xylan_clt:get_status() of
		{ok,StatusLists} ->
		    lists:foreach(fun format_prop_list/1, StatusLists);
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

%% Generate a 64-bit random key used for signing packets (legacy)
generate_key() ->
    generate_key(64).

%% Generate a random key, use 256 for clients using tls/hmac_sha256.
%% Prints the key in decimal and hex form, both may be pasted into the
%% config as server_key/client_key (they are the same key).
generate_key(Bits) when Bits =:= 64; Bits =:= 256 ->
    <<X:Bits>> = crypto:strong_rand_bytes(Bits div 8),
    io:format("decimal: ~w\nhex:     16#~s\n", [X, integer_to_list(X, 16)]),
    X.

%% Generate a new api key. If api_key_file is configured the key is
%% stored there, otherwise the config entry is printed.
%% Options: {expires,{Y,M,D}}, {allow,[GatewayName]}
%% The key itself is only shown once.
generate_api_key(Name) ->
    generate_api_key(Name, []).

generate_api_key(Name, Options) ->
    case xylan_apikey:add_key(Name, Options) of
	{ok, Key, _Entry} ->
	    io:format("api key (shown once): ~s\n", [Key]),
	    io:format("stored in ~s\n",
		      [application:get_env(xylan, api_key_file, "")]),
	    ok;
	{error, no_api_key_file} ->
	    {Key, Id, Hash} = xylan_apikey:generate(),
	    io:format("api key (shown once): ~s\n", [Key]),
	    io:format("add to {api_keys, [...]} in the config:\n  ~p\n",
		      [{Id, [{name,Name},{hash,Hash}|Options]}]),
	    ok
    end.

revoke_api_key(Id) ->
    xylan_apikey:revoke(Id).

list_api_keys() ->
    lists:foreach(fun({Id, Props}) -> io:format("~s ~p\n", [Id, Props]) end,
		  xylan_apikey:list()).

%% Generate a self signed certificate <Dir>/<Name>.pem + <Dir>/<Name>.key
%% Options: {dir,Dir} {hosts,[DnsName|IP]} {days,Days} {force,true}
%% Prints the fingerprint used by clients for pinning (server_tls).
generate_cert(Name) ->
    generate_cert(Name, []).

generate_cert(Name, Options) ->
    case xylan_cert:generate(Name, Options) of
	{ok, CertFile, KeyFile, FP} ->
	    io:format("certificate: ~s\nkey:         ~s\nfingerprint: ~s\n",
		      [CertFile, KeyFile, FP]),
	    ok;
	Error ->
	    Error
    end.

%% Create an ssh host key for the ssh jump server (ssh_jump system_dir)
%% unless one exists, prints the host key fingerprint(s) users see on
%% first connect.
generate_ssh_host_key(Dir) ->
    [io:format("~s ~s\n", [File, FP]) ||
	{File, FP} <- xylan_jump:generate_host_key(Dir)],
    ok.

%% sha256 fingerprint of server certificate, for client pinning
cert_fingerprint(CertFile) ->
    lists:flatten(xylan_lib:cert_fingerprint(CertFile)).

    
