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
-export([merge_options/2]).
-export([load_config/2]).

-include("xylan_log.hrl").

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


-type option() :: Key::atom() |
		 {Key::atom(), Value::term()} |
		 {Key::atom(), Value1::term(), Value2::term(), Value3::term()}.

-spec filter_options(client | server, Options::list(option())) ->
			    OkOptions::list(option()).
%% Note: KeyValue may contain the raw option and that 
filter_options(Tag, Options) ->
    filter_options_(Tag, Options, [packet,
				   mode, list, binary,
				   deliver,
				   line_delimiter,
				   active,
				   header,
				   exit_on_close,
				   raw,
				   line_delimiter
				  ]).

filter_options_(Tag, [KeyValue|Options], Filter) ->
    Key = get_option_key(KeyValue),
    case lists:member(Key, Filter) of
	true ->
	    ?warning("~w: filter option ~w will be ignored", [Tag, Key]),
	    filter_options_(Tag, Options, Filter);
	false ->
	    [KeyValue|filter_options_(Tag,Options,Filter)]
    end;
filter_options_(_Tag, [], _Filter) ->
    [].

-spec merge_options(Options::list(option()),
		    NewOtions::list(option())) ->
			   list(option()).

merge_options(Options, NewOptions) ->
    merge_options(Options, NewOptions, NewOptions).

merge_options(Options, [KeyValue|NewOptions], NewOptions0) ->
    Key = get_option_key(KeyValue),
    merge_options(proplists:delete(Key, Options), NewOptions, NewOptions0);
merge_options(Options, [], NewOptions0) ->
    Options ++ NewOptions0.

get_option_key(Key) when is_atom(Key) -> Key;
get_option_key(KeyValue) when is_tuple(KeyValue) -> element(1,KeyValue).

load_config(Dir, File) ->
    case filename:extension(File) of
	".config" ->
	    FileName = filename:join(Dir, File),
	    case file:consult(FileName) of
		{ok,Config} ->
		    Config;
		{error,{Ln,Mod,Error}} when is_integer(Ln), is_atom(Mod) ->
		    ?error("unable to load config file ~s:~w: ~s",
				[FileName,Ln,Mod:format_error(Error)]),
		    [];
		{error,Error} ->
		    ?error("unable to load config file ~s ~p\n", 
				[FileName, Error]),
		    []
	    end;
	_ ->
	    ?error("ignore file ~s must have extension .config\n",
			[File]),
	    []
    end.
