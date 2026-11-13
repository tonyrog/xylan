%%% coding: latin-1
%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2026, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @doc
%%%    API keys in the style of Anthropic/OpenAI keys
%%%
%%%      sk-xyl-<id>-<secret><crc>
%%%
%%%    id     8 chars base62, public, used for lookup, logging and revoke
%%%    secret 43 chars base62 (256 bit random)
%%%    crc    6 chars base62 crc32 of the rest, catches typos before lookup
%%%
%%%    Only sha256 of the full key is stored:
%%%
%%%      {Id, [{name,Name},{hash,"sha256:<hex>"},
%%%            {created,{Y,M,D}}, {expires,{Y,M,D}}, {disabled,true},
%%%            {allow,[GatewayName]}]}
%%%
%%%    Keys are read from the xylan env api_keys and from the
%%%    file api_key_file (erlang terms), the file is managed by
%%%    add_key/2, revoke/1 and list/0.
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_apikey).

-export([generate/0]).
-export([parse/1]).
-export([hash/1]).
-export([verify/2]).
-export([add_key/2, revoke/1, list/0]).
-export([keys/0]).

-define(PREFIX, "sk-xyl-").
-define(ID_LEN, 8).
-define(SECRET_LEN, 43).
-define(CRC_LEN, 6).

-type key() :: string().
-type key_id() :: string().

%% Generate a new key, returns {Key, Id, Hash}
-spec generate() -> {key(), key_id(), string()}.
generate() ->
    Id = base62(rand_int(8) rem pow62(?ID_LEN), ?ID_LEN),
    Secret = base62(rand_int(32), ?SECRET_LEN),
    Body = ?PREFIX ++ Id ++ "-" ++ Secret,
    Key = Body ++ crc(Body),
    {Key, Id, hash(Key)}.

%% Check format and checksum, return the key id
-spec parse(Key::key() | binary()) -> {ok, key_id()} | {error, term()}.
parse(Key) when is_binary(Key) ->
    parse(binary_to_list(Key));
parse(?PREFIX ++ Rest = Key) when length(Key) =:=
				  length(?PREFIX)+?ID_LEN+1+?SECRET_LEN+?CRC_LEN ->
    case Rest of
	[_,_,_,_,_,_,_,_,$-|SecretCrc] ->
	    Id = lists:sublist(Rest, ?ID_LEN),
	    Body = lists:sublist(Key, length(Key)-?CRC_LEN),
	    Crc = lists:nthtail(?SECRET_LEN, SecretCrc),
	    case is_base62(Id) andalso is_base62(SecretCrc) andalso
		crc(Body) =:= Crc of
		true -> {ok, Id};
		false -> {error, bad_key}
	    end;
	_ ->
	    {error, bad_key}
    end;
parse(_) ->
    {error, bad_key}.

-spec hash(Key::key()) -> string().
hash(Key) ->
    "sha256:" ++ hex(crypto:hash(sha256, Key)).

%% Verify a presented key for use with Gateway
-spec verify(Key::key()|binary(), Gateway::atom()) ->
	  {ok, key_id(), Name::string()} | {error, term()}.
verify(Key0, Gateway) ->
    Key = if is_binary(Key0) -> binary_to_list(Key0); true -> Key0 end,
    case parse(Key) of
	{ok, Id} ->
	    case lists:keyfind(Id, 1, keys()) of
		false ->
		    {error, {unknown_key, Id}};
		{Id, Props} ->
		    check_key(Key, Id, Props, Gateway)
	    end;
	Error ->
	    Error
    end.

check_key(Key, Id, Props, Gateway) ->
    Stored = list_to_binary(proplists:get_value(hash, Props, "")),
    Hash = list_to_binary(hash(Key)),
    Today = element(1, calendar:universal_time()),
    Allow = proplists:get_value(allow, Props, all),
    Name = proplists:get_value(name, Props, ""),
    Valid = xylan_lib:auth_cred_equal(Stored, Hash),
    if not Valid ->
	    {error, {bad_secret, Id}};
       true ->
	    case proplists:get_value(disabled, Props, false) of
		true ->
		    {error, {disabled, Id}};
		false ->
		    case proplists:get_value(expires, Props) of
			Exp when Exp =/= undefined, Exp < Today ->
			    {error, {expired, Id}};
			_ when Allow =/= all ->
			    case lists:member(Gateway, Allow) of
				true -> {ok, Id, Name};
				false -> {error, {not_allowed, Id}}
			    end;
			_ ->
			    {ok, Id, Name}
		    end
	    end
    end.

%% All configured keys, file entries override env entries
keys() ->
    EnvKeys = application:get_env(xylan, api_keys, []),
    FileKeys = case read_file() of
		   {ok, Ks} -> Ks;
		   {error, _} -> []
	       end,
    lists:ukeymerge(1, lists:ukeysort(1, FileKeys), lists:ukeysort(1, EnvKeys)).

%% Generate a key and store it in api_key_file.
%% Options: {expires,{Y,M,D}}, {allow,[Gateway]}
%% Returns {ok, Key} the key is only shown once.
add_key(Name, Options) ->
    case key_file() of
	undefined ->
	    {error, no_api_key_file};
	File ->
	    {ok, Keys} = case read_file() of
			     {error, enoent} -> {ok, []};
			     R -> R
			 end,
	    {Key, Id, Hash} = generate(),
	    case lists:keymember(Id, 1, Keys) of
		true ->
		    add_key(Name, Options);  %% id collision, try again
		false ->
		    Entry = {Id, [{name,Name},{hash,Hash},
				  {created,element(1,calendar:universal_time())}
				 | Options]},
		    ok = write_file(File, Keys ++ [Entry]),
		    {ok, Key, Entry}
	    end
    end.

revoke(Id) ->
    case {key_file(), read_file()} of
	{undefined, _} -> {error, no_api_key_file};
	{_, {error,_}=E} -> E;
	{File, {ok, Keys}} ->
	    case lists:keyfind(Id, 1, Keys) of
		false -> {error, not_found};
		{Id, Props} ->
		    Props1 = [{disabled,true} | proplists:delete(disabled, Props)],
		    write_file(File, lists:keyreplace(Id, 1, Keys, {Id, Props1}))
	    end
    end.

%% list keys without hashes
list() ->
    [{Id, proplists:delete(hash, Props)} || {Id, Props} <- keys()].

key_file() ->
    application:get_env(xylan, api_key_file, undefined).

read_file() ->
    case key_file() of
	undefined -> {error, enoent};
	File -> file:consult(File)
    end.

write_file(File, Keys) ->
    Tmp = File ++ ".tmp",
    Data = ["%% -*- erlang -*-\n",
	    "%% xylan api keys, managed by xylan:generate_api_key/1,2\n",
	    [io_lib:format("~p.\n", [K]) || K <- Keys]],
    ok = file:write_file(Tmp, Data),
    _ = file:change_mode(Tmp, 8#600),
    file:rename(Tmp, File).

%% utils

rand_int(Bytes) ->
    binary:decode_unsigned(crypto:strong_rand_bytes(Bytes)).

pow62(0) -> 1;
pow62(N) -> 62 * pow62(N-1).

crc(Body) ->
    base62(erlang:crc32(Body), ?CRC_LEN).

-define(B62, "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").

base62(N, Len) ->
    S = base62_(N, []),
    lists:duplicate(max(0, Len-length(S)), $0) ++ S.

base62_(0, []) -> "0";
base62_(0, Acc) -> Acc;
base62_(N, Acc) -> base62_(N div 62, [lists:nth(N rem 62 + 1, ?B62)|Acc]).

is_base62(S) ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
			    (C >= $A andalso C =< $Z) orelse
			    (C >= $a andalso C =< $z) end, S).

hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
