%%% coding: latin-1
%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2016, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @author Marina Westman Lonne <malotte@malotte.net>
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%    Utility functions
%%%
%%% Created : 18 Dec 2014 by Tony Rogvall 
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_lib).

-export([make_key/1]).
-export([lookup_ip/2]).
-export([lookup_ifaddr/2]).
-export([filter_options/2]).

make_key(Key) when is_binary(Key) ->  Key;
make_key(Key) when is_integer(Key) -> <<Key:64>>;
make_key(Key) when is_list(Key) -> erlang:iolist_to_binary(Key);
make_key(Key) when is_atom(Key) -> erlang:atom_to_binary(Key,latin1).

lookup_ip(Name,Family) ->
    case inet_parse:address(Name) of
	{error,_} ->
	    lookup_ifaddr(Name,Family);
	Res -> Res
    end.

lookup_ifaddr(Name,Family) ->
    case inet:getifaddrs() of
	{ok,List} ->
	    case lists:keyfind(Name, 1, List) of
		false -> {error, enoent};
		{_, Flags} ->
		    AddrList = proplists:get_all_values(addr, Flags),
		    get_family_addr(AddrList, Family)
	    end;
	_ ->
	    {error, enoent}
    end.
	
get_family_addr([IP|_IPs], inet) when tuple_size(IP) =:= 4 -> {ok,IP};
get_family_addr([IP|_IPs], inet6) when tuple_size(IP) =:= 8 -> {ok,IP};
get_family_addr([_|IPs],Family) -> get_family_addr(IPs,Family);
get_family_addr([],_Family) -> {error, enoent}.


-spec filter_options(client | server,
		    Options::list({Key::atom, Value::term()})) ->
			   OkOptions::list({Key::atom, Value::term()}).

filter_options(_Tag, []) ->
    [];
filter_options(Tag, Options) ->
    filter_options(Tag, Options, []).

filter_options(_Tag, [], Acc) ->
    Acc;
filter_options(Tag, [{active, once} | Rest], Acc) ->
    filter_options(Tag, Rest, Acc);
filter_options(Tag, [{active, Value} | Rest], Acc) when Value =:= once->
    lager:warning("active value ~p will be ignored", [Value]),
    filter_options(Tag, Rest, Acc);
filter_options(Tag, [{mode, _Value} | Rest], Acc) ->
    lager:warning("mode value ~p will be ignored", [_Value]),
    filter_options(Tag, Rest, Acc);
filter_options(Tag, [{packet, _Value} | Rest], Acc) ->
    lager:warning("packet value ~p will be ignored", [_Value]),
    filter_options(Tag, Rest, Acc);
filter_options(Tag, [{nodelay, _Value} | Rest], Acc) ->
    lager:warning("nodelay value ~p will be ignored", [_Value]),
    filter_options(Tag, Rest, Acc);
filter_options(Tag, [Option | Rest], Acc) ->
    %% What else should be checked??
    filter_options(Tag, Rest, [Option | Acc]).
