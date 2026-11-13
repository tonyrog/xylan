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
%%%    Self signed server certificates (EC P-256, ecdsa-with-SHA256)
%%%
%%%    generate(Name, Options) writes <Dir>/<Name>.pem and <Dir>/<Name>.key
%%%    Options:
%%%      {dir, Dir}          default "."
%%%      {hosts, [Host]}     dns names and/or ip addresses for subjectAltName
%%%                          default [Name]
%%%      {days, Days}        validity, default 3650
%%%      {usage, server|client|both}  extended key usage, default server
%%%      {force, true}       overwrite existing files
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_cert).

-export([generate/2]).

-include_lib("public_key/include/public_key.hrl").

generate(Name, Options) ->
    Dir = proplists:get_value(dir, Options, "."),
    Hosts = proplists:get_value(hosts, Options, [Name]),
    Days = proplists:get_value(days, Options, 3650),
    Force = proplists:get_value(force, Options, false),
    Usage = case proplists:get_value(usage, Options, server) of
		server -> [?'id-kp-serverAuth'];
		client -> [?'id-kp-clientAuth'];
		both -> [?'id-kp-serverAuth', ?'id-kp-clientAuth']
	    end,
    CertFile = filename:join(Dir, Name ++ ".pem"),
    KeyFile = filename:join(Dir, Name ++ ".key"),
    Exists = filelib:is_file(CertFile) orelse filelib:is_file(KeyFile),
    if Exists, not Force ->
	    {error, {exists, CertFile}};
       true ->
	    {Der, Key} = make_cert(Hosts, Days, Usage),
	    CertPem = public_key:pem_encode([{'Certificate', Der, not_encrypted}]),
	    KeyPem = public_key:pem_encode(
		       [public_key:pem_entry_encode('ECPrivateKey', Key)]),
	    ok = filelib:ensure_dir(CertFile),
	    ok = write_file(KeyFile, KeyPem, 8#600),
	    ok = write_file(CertFile, CertPem, 8#644),
	    {ok, CertFile, KeyFile, xylan_lib:der_fingerprint(Der)}
    end.

write_file(File, Data, Mode) ->
    Tmp = File ++ ".tmp",
    ok = file:write_file(Tmp, <<>>),
    ok = file:change_mode(Tmp, Mode),   %% set mode before writing secrets
    ok = file:write_file(Tmp, Data),
    file:rename(Tmp, File).

make_cert(Hosts = [CN|_], Days, Usage) ->
    Key = public_key:generate_key({namedCurve, ?'secp256r1'}),
    #'ECPrivateKey'{ publicKey = PubPoint, parameters = Params } = Key,
    Subject = {rdnSequence,
	       [[#'AttributeTypeAndValue'{ type = ?'id-at-commonName',
					   value = {utf8String,
						    unicode:characters_to_binary(
						      host_string(CN))} }]]},
    Now = calendar:universal_time(),
    NowS = calendar:datetime_to_gregorian_seconds(Now),
    From = calendar:gregorian_seconds_to_datetime(NowS - 3600),
    To = calendar:gregorian_seconds_to_datetime(NowS + Days*86400),
    SigAlg = #'SignatureAlgorithm'{ algorithm = ?'ecdsa-with-SHA256',
				    parameters = asn1_NOVALUE },
    TBS = #'OTPTBSCertificate'{
	     version = v3,
	     serialNumber = binary:decode_unsigned(crypto:strong_rand_bytes(15)),
	     signature = SigAlg,
	     issuer = Subject,
	     validity = #'Validity'{ notBefore = asn1_time(From),
				     notAfter = asn1_time(To) },
	     subject = Subject,
	     subjectPublicKeyInfo =
		 #'OTPSubjectPublicKeyInfo'{
		    algorithm = #'PublicKeyAlgorithm'{
				   algorithm = ?'id-ecPublicKey',
				   parameters = Params },
		    subjectPublicKey = #'ECPoint'{ point = PubPoint } },
	     extensions =
		 [#'Extension'{ extnID = ?'id-ce-subjectAltName',
				critical = false,
				extnValue = [san(H) || H <- Hosts] },
		  #'Extension'{ extnID = ?'id-ce-basicConstraints',
				critical = true,
				extnValue = #'BasicConstraints'{ cA = false } },
		  #'Extension'{ extnID = ?'id-ce-keyUsage',
				critical = true,
				extnValue = [digitalSignature] },
		  #'Extension'{ extnID = ?'id-ce-extKeyUsage',
				critical = false,
				extnValue = Usage }]
	    },
    Der = public_key:pkix_sign(TBS, Key),
    {Der, Key}.

san(IP) when is_tuple(IP) ->
    {iPAddress, ip_bin(IP)};
san(Host) ->
    case inet:parse_address(Host) of
	{ok, IP} -> {iPAddress, ip_bin(IP)};
	{error, _} -> {dNSName, Host}
    end.

ip_bin({A,B,C,D}) -> <<A,B,C,D>>;
ip_bin(IP) when tuple_size(IP) =:= 8 -> << <<X:16>> || X <- tuple_to_list(IP) >>.

host_string(IP) when is_tuple(IP) -> inet:ntoa(IP);
host_string(Host) -> Host.

%% utcTime before 2050, generalTime after (RFC 5280)
asn1_time({{Y,Mo,D},{H,Mi,S}}) when Y < 2050 ->
    {utcTime, lists:flatten(io_lib:format("~2..0w~2..0w~2..0w~2..0w~2..0w~2..0wZ",
					  [Y rem 100,Mo,D,H,Mi,S]))};
asn1_time({{Y,Mo,D},{H,Mi,S}}) ->
    {generalTime, lists:flatten(io_lib:format("~4..0w~2..0w~2..0w~2..0w~2..0w~2..0wZ",
					      [Y,Mo,D,H,Mi,S]))}.
