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
-export([auth_cred/4, auth_cred_equal/2]).
-export([cert_fingerprint/1, der_fingerprint/1]).
-export([tls_client_options/1, tls_check_peer/2]).
-export([peer_fingerprint/1, normalize_fingerprint/1]).
-export([normalize_fingerprints/1]).
-export([tls_password/1]).
-export([tls_server_options/2]).
-export([lookup_ip/2]).
-export([lookup_ifaddr/2]).
-export([filter_options/2]).
-export([merge_options/2]).
-export([load_config/2]).

-include("xylan_log.hrl").

make_key(undefined) -> undefined;
make_key(Key) when is_binary(Key) ->  Key;
make_key(Key) when is_integer(Key), Key >= 0, Key < (1 bsl 64) ->
    <<Key:64>>;  %% legacy 64-bit keys
make_key(Key) when is_integer(Key), Key >= 0, Key < (1 bsl 256) ->
    <<Key:256>>;
make_key(Key) when is_integer(Key), Key >= 0 ->
    binary:encode_unsigned(Key);
make_key(Key) when is_list(Key) -> erlang:iolist_to_binary(Key);
make_key(Key) when is_atom(Key) -> erlang:atom_to_binary(Key,latin1).

%% Authentication credential, Role is the side that proves knowledge of Key
%%   sha         - legacy: sha1(Key ++ Chal)
%%   hmac_sha256 - hmac-sha256(Key, RoleTag ++ Chal)
-spec auth_cred(Alg::sha|hmac_sha256, Key::binary(),
		Role::server|client, Chal::binary()) -> binary().
auth_cred(cert, _Key, _Role, _Chal) ->
    <<>>;  %% authenticated by tls client certificate
auth_cred(sha, Key, _Role, Chal) ->
    crypto:hash(sha, [Key, Chal]);
auth_cred(hmac_sha256, Key, server, Chal) ->
    crypto:mac(hmac, sha256, Key, [<<"xylan-server-v1:">>, Chal]);
auth_cred(hmac_sha256, Key, client, Chal) ->
    crypto:mac(hmac, sha256, Key, [<<"xylan-client-v1:">>, Chal]).

%% constant time compare of credentials
auth_cred_equal(A, B) when is_binary(A), is_binary(B),
			   byte_size(A) =:= byte_size(B) ->
    try crypto:hash_equals(A, B)
    catch
	error:undef ->  %% before OTP 25
	    crypto:exor(A, B) =:= <<0:(byte_size(A))/unit:8>>
    end;
auth_cred_equal(_, _) ->
    false.

%% sha256 fingerprint of the first certificate in a PEM file
%% formatted as "sha256:AB:CD:..."
cert_fingerprint(CertFile) ->
    {ok, Bin} = file:read_file(CertFile),
    [Der|_] = [D || {'Certificate', D, not_encrypted} <-
			public_key:pem_decode(Bin)],
    der_fingerprint(Der).

der_fingerprint(Der) ->
    Hash = crypto:hash(sha256, Der),
    lists:flatten(
      ["sha256:" | lists:join($:, [io_lib:format("~2.16.0B",[B]) ||
				      <<B>> <= Hash])]).

%% Client side tls options from the server_tls config
%%   [{fingerprint,"sha256:..."} | ssl:tls_client_option()]
%% With a fingerprint the certificate chain is not validated, instead
%% the peer certificate must match the pinned fingerprint
%% (checked with tls_check_peer/2 before anything is sent).
%% fingerprint may be a single fingerprint or a list (certificate rotation)
-spec tls_client_options(Conf::list()) ->
	  {SslOpts::list(), Fingerprints::[string()]|undefined}.
tls_client_options(Conf0) ->
    Conf = tls_password(Conf0),
    case proplists:get_value(fingerprint, Conf) of
	undefined ->
	    {Conf, undefined};
	FP ->
	    Opts = proplists:delete(fingerprint, Conf),
	    AcceptAll = fun(_Cert, {extension,_}, St) -> {unknown, St};
			   (_Cert, _Event, St) -> {valid, St}
			end,
	    %% verify_peer requires cacerts, the chain is accepted by the
	    %% verify_fun and the pinned fingerprint decides
	    {[{verify, verify_peer}, {cacerts, []},
	      {verify_fun, {AcceptAll, []}} | Opts],
	     normalize_fingerprints(FP)}
    end.

%% Resolve the key password in ssl options
%%   {password, "secret"}             - as is
%%   {password, {env, "VAR"}}         - from environment variable
%%   {password, {file, "/path"}}      - first line of a file
tls_password(Opts) ->
    case proplists:get_value(password, Opts) of
	{env, Var} ->
	    case os:getenv(Var) of
		false -> erlang:error({password_env_not_set, Var});
		Pw -> set_password(Pw, Opts)
	    end;
	{file, File} ->
	    case file:read_file(File) of
		{ok, Bin} ->
		    [Line|_] = binary:split(Bin, [<<"\n">>, <<"\r">>]),
		    set_password(binary_to_list(Line), Opts);
		{error, Reason} ->
		    erlang:error({password_file, File, Reason})
	    end;
	_ ->
	    Opts
    end.

set_password(Pw, Opts) ->
    [{password, Pw} | proplists:delete(password, Opts)].

%% Server side, request (but do not require) a client certificate.
%% The certificate chain is accepted here, the certificate fingerprint
%% is checked per client (client_cert) when the client presents its id.
tls_server_options(Opts, false) ->
    Opts;
tls_server_options(Opts, true) ->
    case proplists:is_defined(verify, Opts) of
	true ->
	    Opts;  %% user has own verify setup
	false ->
	    AcceptAll = fun(_Cert, {extension,_}, St) -> {unknown, St};
			   (_Cert, _Event, St) -> {valid, St}
			end,
	    [{verify, verify_peer}, {fail_if_no_peer_cert, false},
	     {cacerts, []}, {verify_fun, {AcceptAll, []}} | Opts]
    end.

%% fingerprint of the peer certificate or undefined
peer_fingerprint(XSocket) ->
    try ssl:peercert(xylan_socket:socket(XSocket)) of
	{ok, Der} -> der_fingerprint(Der);
	_ -> undefined
    catch
	_:_ -> undefined
    end.

tls_check_peer(_XSocket, undefined) ->
    ok;
tls_check_peer(XSocket, FPs) when is_list(FPs) ->
    case ssl:peercert(xylan_socket:socket(XSocket)) of
	{ok, Der} ->
	    FP = der_fingerprint(Der),
	    case lists:member(FP, FPs) of
		true -> ok;
		false -> {error, {fingerprint_mismatch, FP}}
	    end;
	Error ->
	    Error
    end.

%% "sha256:.." | ["sha256:..", ...] -> [normalized]
normalize_fingerprints([C|_] = FP) when is_integer(C) ->
    [normalize_fingerprint(FP)];
normalize_fingerprints(FPs) when is_list(FPs) ->
    [normalize_fingerprint(FP) || FP <- FPs].

normalize_fingerprint(FP) ->
    case string:lowercase(lists:sublist(FP, 7)) of
	"sha256:" -> "sha256:" ++ string:uppercase(lists:nthtail(7, FP));
	_ -> "sha256:" ++ string:uppercase(FP)
    end.

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
