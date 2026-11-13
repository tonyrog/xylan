%%% coding: latin-1
%%%---- BEGIN COPYRIGHT --------------------------------------------------------
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
%%%---- END COPYRIGHT ----------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @doc
%%%    Tests of the tls tunnel, client certificates, tls handshake limits,
%%%    api keys and the api gateway. Everything runs in the test node,
%%%    certificates are generated with xylan_cert in priv_dir and all
%%%    ports are allocated dynamically.
%%%
%%%    Run: make -C test ct    (or ct_run -dir test -pa ebin)
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_tls_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").

-define(OLD_SKEY, 3177648541185394227).
-define(OLD_CKEY, 12187761947737533676).
-define(SKEY, 16#a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90).
-define(CKEY, 16#0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0).

-define(MSG, <<"SSH-2.0-test hello\r\n">>).

suite() ->
    [{timetrap, {minutes, 2}}].

all() ->
    [{group, apikey},
     {group, tunnel},
     {group, client_cert},
     {group, handshake_limits},
     {group, rotation},
     {group, gateway},
     {group, ssh_jump}].

groups() ->
    [{apikey, [sequence],
      [key_format, key_parse, key_verify, key_file]},
     {tunnel, [sequence],
      [legacy_client_relays,
       tls_route_and_data,
       kick_attempt_keeps_session,
       reconnect_replaces_socket,
       idle_auth_socket_does_not_block,
       xylan_clt_tls_relays,
       xylan_clt_bad_fingerprint,
       require_tls_on_plain_port,
       sha_rejected_for_require_tls,
       wrong_client_key,
       stalled_handshake_does_not_block]},
     {client_cert, [sequence],
      [cert_clients_relay,
       cert_impersonation_rejected,
       cert_data_channel_bound]},
     {rotation, [sequence],
      [key_password,
       encrypted_server_key,
       fingerprint_list_client,
       client_cert_list_server]},
     {handshake_limits, [sequence],
      [handshake_limit_per_ip,
       handshake_timeout]},
     {ssh_jump, [sequence],
      [jump_direct,
       jump_chain,
       jump_user_acl,
       jump_unknown_key,
       jump_names_only,
       jump_no_shell]},
     {gateway, [sequence],
      [gw_missing_key,
       gw_bad_key,
       gw_valid_key_forward,
       gw_obs_fold,
       gw_httpc,
       gw_end_to_end]}].

%%--------------------------------------------------------------------
%% suite / group setup
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    ok = application:load(xylan),
    Dir = filename:join(?config(priv_dir, Config), "certs"),
    Gen = fun(Name, Usage) ->
		  {ok, C, K, FP} = xylan_cert:generate(
				     Name, [{dir, Dir}, {usage, Usage},
					    {hosts, ["localhost", "127.0.0.1"]}]),
		  {C, K, FP}
	  end,
    [{certs, #{ server => Gen("server", server),
		gw => Gen("gw", server),
		home_a => Gen("home-a", client),
		home_b => Gen("home-b", client) }} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(apikey, Config) ->
    Config;
init_per_group(tunnel, Config) ->
    P = ports([user_old, user_new, user_clt, user_badfp,
	       cntl, data, cntl_tls, data_tls, echo]),
    {SC, SK, SFP} = cert(server, Config),
    Echo = start_echo(port(echo, P)),
    Srv = start_srv([{port, [{old, "127.0.0.1", port(user_old, P)},
			     {new, "127.0.0.1", port(user_new, P)},
			     {clt, "127.0.0.1", port(user_clt, P)},
			     {badfp, "127.0.0.1", port(user_badfp, P)}]},
		     {client_port, port(cntl, P)}, {data_port, port(data, P)},
		     {client_tls_port, port(cntl_tls, P)},
		     {data_tls_port, port(data_tls, P)},
		     {tls_options, [{certfile, SC}, {keyfile, SK}]},
		     {clients,
		      [{"old", [{server_key, ?OLD_SKEY}, {client_key, ?OLD_CKEY},
				{route, [[{dst_port, port(user_old, P)}]]}]},
		       {"new", [{server_key, ?SKEY}, {client_key, ?CKEY},
				{require_tls, true},
				{route, [[{dst_port, port(user_new, P)}]]}]},
		       {"clt", [{server_key, ?SKEY}, {client_key, ?CKEY},
				{require_tls, true},
				{route, [[{dst_port, port(user_clt, P)}]]}]},
		       {"badfp", [{server_key, ?SKEY}, {client_key, ?CKEY},
				  {require_tls, true},
				  {route, [[{dst_port, port(user_badfp, P)}]]}]}]}]),
    Old = start_clt([{id, "old"}, {server_port, port(cntl, P)},
		     {server_key, ?OLD_SKEY}, {client_key, ?OLD_CKEY},
		     {route, [{[{dst_port, ".*"}], [{port, port(echo, P)}]}]}]),
    Clt = start_clt([{id, "clt"}, {server_port, port(cntl_tls, P)},
		     {server_tls, [{fingerprint, string:lowercase(SFP)}]},
		     {server_key, ?SKEY}, {client_key, ?CKEY},
		     {route, [{[{dst_port, ".*"}], [{port, port(echo, P)}]}]}]),
    BadFP = "sha256:" ++ lists:duplicate(31, "00:") ++ "00",
    Bad = start_clt([{id, "badfp"}, {server_port, port(cntl_tls, P)},
		     {server_tls, [{fingerprint, BadFP}]},
		     {server_key, ?SKEY}, {client_key, ?CKEY},
		     {reconnect_interval, 60000},
		     {route, [{[{dst_port, ".*"}], [{port, port(echo, P)}]}]}]),
    timer:sleep(500),
    [{ports, P}, {procs, [Srv, Old, Clt, Bad, Echo]}, {badfp_clt, Bad} | Config];

init_per_group(client_cert, Config) ->
    P = ports([u1, u2, u3, cntl_tls, data_tls, echo]),
    {SC, SK, SFP} = cert(server, Config),
    {AC, AK, AFP} = cert(home_a, Config),
    {BC, BK, BFP} = cert(home_b, Config),
    Echo = start_echo(port(echo, P)),
    Srv = start_srv([{port, [{a, "127.0.0.1", port(u1, P)},
			     {b, "127.0.0.1", port(u2, P)},
			     {c, "127.0.0.1", port(u3, P)}]},
		     {client_port, none}, {data_port, none},
		     {client_tls_port, port(cntl_tls, P)},
		     {data_tls_port, port(data_tls, P)},
		     {tls_options, [{certfile, SC}, {keyfile, SK}]},
		     {clients,
		      [{"certonly", [{client_cert, string:lowercase(AFP)},
				     {route, [[{dst_port, port(u1, P)}]]}]},
		       {"certkeys", [{client_cert, BFP},
				     {server_key, ?SKEY}, {client_key, ?CKEY},
				     {route, [[{dst_port, port(u2, P)}]]}]},
		       {"keysonly", [{server_key, ?SKEY}, {client_key, ?CKEY},
				     {require_tls, true},
				     {route, [[{dst_port, port(u3, P)}]]}]}]}]),
    Clt = fun(Id, Tls, Keys) ->
		  start_clt([{id, Id}, {server_port, port(cntl_tls, P)},
			     {server_tls, [{fingerprint, SFP} | Tls]},
			     {route, [{[{dst_port, ".*"}],
				       [{port, port(echo, P)}]}]} | Keys])
	  end,
    Keys = [{server_key, ?SKEY}, {client_key, ?CKEY}],
    C1 = Clt("certonly", [{certfile, AC}, {keyfile, AK}], []),
    C2 = Clt("certkeys", [{certfile, BC}, {keyfile, BK}], Keys),
    C3 = Clt("keysonly", [], Keys),
    timer:sleep(700),
    [{ports, P}, {procs, [Srv, C1, C2, C3, Echo]} | Config];

init_per_group(rotation, Config) ->
    %% server key encrypted, password from environment variable
    P = ports([u1, cntl_tls, data_tls, echo]),
    Dir = filename:join(?config(priv_dir, Config), "rotation"),
    {ok, SC, SK, SFP} = xylan_cert:generate("server", [{dir, Dir},
							{password, "hemligt"}]),
    os:putenv("XYLAN_TEST_KEY_PW", "hemligt"),
    {_, _, AFP} = cert(home_a, Config),
    {_, _, BFP} = cert(home_b, Config),
    Echo = start_echo(port(echo, P)),
    Srv = start_srv([{port, [{a, "127.0.0.1", port(u1, P)}]},
		     {client_port, none}, {data_port, none},
		     {client_tls_port, port(cntl_tls, P)},
		     {data_tls_port, port(data_tls, P)},
		     {tls_options, [{certfile, SC}, {keyfile, SK},
				    {password, {env, "XYLAN_TEST_KEY_PW"}}]},
		     {clients,
		      %% old and new client certificate during rotation
		      [{"rot", [{client_cert, [AFP, BFP]},
				{route, [[{dst_port, port(u1, P)}]]}]}]}]),
    [{ports, P}, {procs, [Srv, Echo]}, {server_fp, SFP},
     {rotation_dir, Dir} | Config];
init_per_group(handshake_limits, Config) ->
    P = ports([user, cntl_tls, data_tls]),
    {SC, SK, _} = cert(server, Config),
    Srv = start_srv([{port, [{u, "127.0.0.1", port(user, P)}]},
		     {client_port, none}, {data_port, none},
		     {client_tls_port, port(cntl_tls, P)},
		     {data_tls_port, port(data_tls, P)},
		     {max_tls_handshakes_per_ip, 2}, {auth_timeout, 1500},
		     {tls_options, [{certfile, SC}, {keyfile, SK}]},
		     {clients, []}]),
    [{ports, P}, {procs, [Srv]} | Config];

init_per_group(ssh_jump, Config) ->
    case {os:find_executable("ssh"),
	  gen_tcp:listen(0, [{ip, {127,0,1,1}}])} of
	{false, _} -> {skip, "no ssh client"};
	{_, {error, _}} -> {skip, "can not bind 127.0.1.1"};
	{_, {ok, L}} ->
	    gen_tcp:close(L),
	    init_ssh_jump(Config)
    end;
init_per_group(gateway, Config) ->
    P = ports([gw, backend, user, cntl_tls, data_tls]),
    {GC, GK, _} = cert(gw, Config),
    {SC, SK, SFP} = cert(server, Config),
    {Key, Id, Hash} = xylan_apikey:generate(),
    application:set_env(xylan, api_keys, [{Id, [{name, "test"}, {hash, Hash}]}]),
    Backend = start_http_backend(port(backend, P)),
    Gw = start_gw(ollama, [{port, port(gw, P)},
			   {target, {"127.0.0.1", port(backend, P)}},
			   {tls, [{certfile, GC}, {keyfile, GK}]}]),
    Srv = start_srv([{port, [{gw, "127.0.0.1", port(user, P)}]},
		     {client_port, none}, {data_port, none},
		     {client_tls_port, port(cntl_tls, P)},
		     {data_tls_port, port(data_tls, P)},
		     {tls_options, [{certfile, SC}, {keyfile, SK}]},
		     {clients, [{"home", [{server_key, ?SKEY}, {client_key, ?CKEY},
					  {require_tls, true},
					  {route, [[{dst_port, port(user, P)}]]}]}]}]),
    Clt = start_clt([{id, "home"}, {server_port, port(cntl_tls, P)},
		     {server_tls, [{fingerprint, SFP}]},
		     {server_key, ?SKEY}, {client_key, ?CKEY},
		     {route, [{[{data, ssl}], [{port, port(gw, P)}]}]}]),
    timer:sleep(500),
    [{ports, P}, {api_key, Key}, {procs, [Gw, Srv, Clt, Backend]} | Config].

end_per_group(apikey, _Config) ->
    application:unset_env(xylan, api_keys),
    application:unset_env(xylan, api_key_file),
    ok;
end_per_group(gateway, Config) ->
    application:unset_env(xylan, api_keys),
    stop_procs(Config);
end_per_group(_Group, Config) ->
    stop_procs(Config).

init_ssh_jump(Config) ->
    {ok, _} = application:ensure_all_started(ssh),
    Priv = ?config(priv_dir, Config),
    Dir = filename:join(Priv, "jump"),
    P = ports([vport, j1, j2, home_sshd, nas_sshd, cntl, data]),
    %% user keys (OpenSSH reads PEM private keys)
    {TonyCfg, TonyPub} = ssh_user(Dir, "tony"),
    {GuestCfg, GuestPub} = ssh_user(Dir, "guest"),
    {OtherCfg, _} = ssh_user(Dir, "other"),
    %% the final machines: plain ssh daemons with exec
    Home = start_sshd(filename:join(Dir, "home"), port(home_sshd, P),
		      "home", [TonyPub, GuestPub]),
    Nas = start_sshd(filename:join(Dir, "nas"), port(nas_sshd, P),
		     "nas", [TonyPub, GuestPub]),
    %% xylan: two loopback user ports routed on dst_ip to client "home",
    %% a non matching ip tuple route is tried first
    VP = port(vport, P),
    Srv = start_srv([{port, [{jh, "127.0.1.1", VP}, {jn, "127.0.1.2", VP}]},
		     {client_port, port(cntl, P)}, {data_port, port(data, P)},
		     {clients,
		      [{"other", [{server_key, ?OLD_SKEY}, {client_key, ?OLD_CKEY},
				  {route, [[{dst_ip, {127,0,1,9}}]]}]},
		       {"home", [{server_key, ?SKEY}, {client_key, ?CKEY},
				 {route, [[{dst_ip, {127,0,1,1}}],
					  [{dst_ip, {127,0,1,2}}]]}]}]}]),
    Clt = start_clt([{id, "home"}, {server_port, port(cntl, P)},
		     {server_key, ?SKEY}, {client_key, ?CKEY},
		     {route, [{[{dst_ip, {127,0,1,1}}], [{port, port(home_sshd, P)}]},
			      {[{dst_ip, {127,0,1,2}}], [{port, port(nas_sshd, P)}]}]}]),
    J2Dir = filename:join(Dir, "j2"),
    J1Dir = filename:join(Dir, "j1"),
    _ = xylan_jump:generate_host_key(J2Dir),
    _ = xylan_jump:generate_host_key(J1Dir),
    J2 = start_jump([{port, port(j2, P)}, {system_dir, J2Dir}, {virtual_port, VP},
		     {targets, [{"home", {127,0,1,1}}, {"nas.home", {127,0,1,2}}]},
		     {users, [{"tony", [{keys, [TonyPub]}, {allow, all}]},
			      {"guest", [{keys, [GuestPub]}, {allow, ["home"]}]}]}]),
    J1 = start_jump([{port, port(j1, P)}, {system_dir, J1Dir},
		     {targets, [{"xylan2", {"127.0.0.1", port(j2, P)}}]},
		     {users, [{"tony", [{keys, [TonyPub]}, {allow, all}]}]}]),
    timer:sleep(500),
    [{ports, P}, {ssh_cfg, #{ tony => TonyCfg, guest => GuestCfg, other => OtherCfg }},
     {procs, [J1, J2, Clt, Srv, Home, Nas]} | Config].

%%--------------------------------------------------------------------
%% apikey
%%--------------------------------------------------------------------

key_format(_Config) ->
    {Key, _Id, Hash} = xylan_apikey:generate(),
    true = lists:prefix("sk-xyl-", Key),
    65 = length(Key),
    true = lists:prefix("sha256:", Hash),
    ok.

key_parse(_Config) ->
    {Key, Id, _} = xylan_apikey:generate(),
    {ok, Id} = xylan_apikey:parse(Key),
    {ok, Id} = xylan_apikey:parse(list_to_binary(Key)),
    {error, bad_key} = xylan_apikey:parse(flip(Key, 30)),
    {error, bad_key} = xylan_apikey:parse("sk-xyl-nope"),
    {error, bad_key} = xylan_apikey:parse("sk-ant-api03-" ++ lists:duplicate(52, $a)),
    true = lists:all(fun(_) -> {K, I, _} = xylan_apikey:generate(),
			       xylan_apikey:parse(K) =:= {ok, I} end,
		     lists:seq(1, 2000)),
    ok.

key_verify(_Config) ->
    [{K1,I1,H1}, {K2,I2,H2}, {K3,I3,H3}, {K4,I4,H4}, {K5,_,_}] =
	[xylan_apikey:generate() || _ <- lists:seq(1, 5)],
    application:set_env(xylan, api_keys,
			[{I1, [{name, "tony"}, {hash, H1}]},
			 {I2, [{name, "old"}, {hash, H2}, {expires, {2020,1,1}}]},
			 {I3, [{name, "off"}, {hash, H3}, {disabled, true}]},
			 {I4, [{name, "other"}, {hash, H4}, {allow, [other]}]}]),
    {ok, I1, "tony"} = xylan_apikey:verify(K1, ollama),
    {error, {expired, I2}} = xylan_apikey:verify(K2, ollama),
    {error, {disabled, I3}} = xylan_apikey:verify(K3, ollama),
    {error, {not_allowed, I4}} = xylan_apikey:verify(K4, ollama),
    {ok, I4, "other"} = xylan_apikey:verify(K4, other),
    {error, {unknown_key, _}} = xylan_apikey:verify(K5, ollama),
    ok.

key_file(Config) ->
    File = filename:join(?config(priv_dir, Config), "api_keys.conf"),
    application:set_env(xylan, api_key_file, File),
    {ok, Key, {Id, _}} = xylan_apikey:add_key("laptop", [{expires, {2099,1,1}}]),
    {ok, Id, "laptop"} = xylan_apikey:verify(Key, ollama),
    {ok, Bin} = file:read_file(File),
    nomatch = binary:match(Bin, list_to_binary(Key)),
    {ok, #file_info{ mode = Mode }} = file:read_file_info(File),
    8#600 = Mode band 8#777,
    true = lists:keymember(Id, 1, xylan_apikey:list()),
    ok = xylan_apikey:revoke(Id),
    {error, {disabled, Id}} = xylan_apikey:verify(Key, ollama),
    ok.

%%--------------------------------------------------------------------
%% tunnel
%%--------------------------------------------------------------------

legacy_client_relays(Config) ->
    true = user_echo(port(user_old, Config)).

tls_route_and_data(Config) ->
    {ok, C} = tls_auth(Config, "new", ?SKEY, ?CKEY, hmac_sha256, []),
    Self = self(),
    spawn(fun() -> Self ! {user, user_echo(port(user_new, Config))} end),
    {route, DPort, Sk, _Info} = recv_term(C),
    DPort = port(data_tls, Config),
    %% session key presented on the plain data port is rejected
    {ok, Bad} = gen_tcp:connect("127.0.0.1", port(data, Config),
				[binary, {packet,4}, {active,false}]),
    ok = gen_tcp:send(Bad, Sk),
    {error, closed} = gen_tcp:recv(Bad, 0, 2000),
    %% the real data connection over tls
    data_echo(Config, Sk, []),
    receive {user, true} -> ok
    after 5000 -> ct:fail(no_user_echo)
    end,
    ssl:close(C).

kick_attempt_keeps_session(Config) ->
    {ok, C} = tls_auth(Config, "new", ?SKEY, ?CKEY, hmac_sha256, []),
    {ok, Kick} = ssl:connect("127.0.0.1", port(cntl_tls, Config), tls_opts([])),
    ok = ssl:send(Kick, term_to_binary({auth_req, [{id,"new"},
		       {chal,crypto:strong_rand_bytes(16)},{alg,hmac_sha256}]})),
    {ok, _} = ssl:recv(Kick, 0, 2000),
    ok = ssl:send(Kick, term_to_binary({auth_ack, [{id,"new"},{cred,<<0:256>>}]})),
    timer:sleep(200),
    true = ping_ok(C),
    ssl:close(C).

reconnect_replaces_socket(Config) ->
    {ok, C1} = tls_auth(Config, "new", ?SKEY, ?CKEY, hmac_sha256, []),
    {ok, C2} = tls_auth(Config, "new", ?SKEY, ?CKEY, hmac_sha256, []),
    timer:sleep(200),
    true = ping_ok(C2),
    false = ping_ok(C1),
    ssl:close(C2).

idle_auth_socket_does_not_block(Config) ->
    {ok, _Idle} = ssl:connect("127.0.0.1", port(cntl_tls, Config), tls_opts([])),
    {ok, C} = tls_auth(Config, "new", ?SKEY, ?CKEY, hmac_sha256, []),
    ssl:close(C).

xylan_clt_tls_relays(Config) ->
    true = user_echo(port(user_clt, Config)).

xylan_clt_bad_fingerprint(Config) ->
    {ok, Status} = gen_server:call(?config(badfp_clt, Config), get_status),
    true = lists:member({status, down}, Status),
    false = user_echo(port(user_badfp, Config)).

require_tls_on_plain_port(Config) ->
    {ok, C} = gen_tcp:connect("127.0.0.1", port(cntl, Config),
			      [binary, {packet,4}, {active,false}]),
    rejected = auth(gen_tcp, C, "new", ?SKEY, ?CKEY, hmac_sha256).

sha_rejected_for_require_tls(Config) ->
    rejected = tls_auth(Config, "new", ?SKEY, ?CKEY, sha, []).

wrong_client_key(Config) ->
    rejected = tls_auth(Config, "new", ?SKEY, ?OLD_CKEY, hmac_sha256, []).

stalled_handshake_does_not_block(Config) ->
    {ok, _Idle} = gen_tcp:connect("127.0.0.1", port(cntl_tls, Config), [binary]),
    T0 = erlang:monotonic_time(millisecond),
    true = user_echo(port(user_old, Config)),
    true = erlang:monotonic_time(millisecond) - T0 < 1000,
    ok.

%%--------------------------------------------------------------------
%% client certificates
%%--------------------------------------------------------------------

cert_clients_relay(Config) ->
    true = user_echo(port(u1, Config)),   %% certificate only
    true = user_echo(port(u2, Config)),   %% certificate + hmac
    true = user_echo(port(u3, Config)).   %% hmac only, same port

cert_impersonation_rejected(Config) ->
    A = cert_opts(home_a, Config),
    B = cert_opts(home_b, Config),
    rejected = tls_auth(Config, "certonly", ?SKEY, ?CKEY, cert, B),
    rejected = tls_auth(Config, "certonly", ?SKEY, ?CKEY, cert, []),
    rejected = tls_auth(Config, "certkeys", ?SKEY, ?CKEY, hmac_sha256, []),
    rejected = tls_auth(Config, "keysonly", ?SKEY, ?CKEY, cert, A),
    rejected = tls_auth(Config, "certonly", ?SKEY, ?CKEY, hmac_sha256, A),
    ok.

cert_data_channel_bound(Config) ->
    A = cert_opts(home_a, Config),
    B = cert_opts(home_b, Config),
    {ok, C} = tls_auth(Config, "certonly", ?SKEY, ?CKEY, cert, A),
    Self = self(),
    spawn(fun() -> Self ! {user, user_echo(port(u1, Config))} end),
    {route, _DPort, Sk, _} = recv_term(C),
    rejected = data_connect(Config, Sk, B),
    rejected = data_connect(Config, Sk, []),
    data_echo(Config, Sk, A),
    receive {user, true} -> ok
    after 5000 -> ct:fail(no_user_echo)
    end,
    ssl:close(C).

%%--------------------------------------------------------------------
%% rotation / key password
%%--------------------------------------------------------------------

key_password(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "pw"),
    {ok, C, K, _} = xylan_cert:generate("pw", [{dir, Dir}, {password, "s3cret"}]),
    {ok, KeyPem} = file:read_file(K),
    {_, _} = binary:match(KeyPem, <<"ENCRYPTED">>),
    PwFile = filename:join(Dir, "pw.txt"),
    ok = file:write_file(PwFile, <<"s3cret\n">>),
    [{password, "s3cret"} | _] =
	xylan_lib:tls_password([{password, {file, PwFile}}, {certfile, C}]),
    %% the key loads with the password and not without
    {ok, L} = ssl:listen(0, [{certfile, C}, {keyfile, K}, {password, "s3cret"}]),
    ssl:close(L),
    {error, _} = (catch ssl:listen(0, [{certfile, C}, {keyfile, K}])),
    {'EXIT', {{password_env_not_set, "XYLAN_NO_SUCH_VAR"}, _}} =
	(catch xylan_lib:tls_password([{password, {env, "XYLAN_NO_SUCH_VAR"}}])),
    ok.

encrypted_server_key(Config) ->
    %% the server started with an encrypted key (password from env)
    {ok, S} = ssl:connect("127.0.0.1", port(cntl_tls, Config),
			  [{verify, verify_none}], 3000),
    {ok, Der} = ssl:peercert(S),
    true = xylan_lib:der_fingerprint(Der) =:= ?config(server_fp, Config),
    ssl:close(S).

fingerprint_list_client(Config) ->
    %% client pins old (unknown) and new server fingerprint
    Old = "sha256:" ++ lists:duplicate(31, "AB:") ++ "AB",
    Clt = start_clt([{id, "rot"}, {server_port, port(cntl_tls, Config)},
		     {server_tls, [{fingerprint, [Old, ?config(server_fp, Config)]}
				   | cert_opts(home_a, Config)]},
		     {route, [{[{dst_port, ".*"}], [{port, port(echo, Config)}]}]}]),
    timer:sleep(500),
    true = user_echo(port(u1, Config)),
    exit(Clt, shutdown),
    timer:sleep(100),
    ok.

client_cert_list_server(Config) ->
    %% both the old (home-a) and new (home-b) client certificate accepted
    {ok, CA} = tls_auth(Config, "rot", ?SKEY, ?CKEY, cert, cert_opts(home_a, Config)),
    ssl:close(CA),
    {ok, CB} = tls_auth(Config, "rot", ?SKEY, ?CKEY, cert, cert_opts(home_b, Config)),
    ssl:close(CB),
    {ok, _, _, _} = xylan_cert:generate("other", [{dir, ?config(rotation_dir, Config)}]),
    Other = [{certfile, filename:join(?config(rotation_dir, Config), "other.pem")},
	     {keyfile, filename:join(?config(rotation_dir, Config), "other.key")}],
    rejected = tls_auth(Config, "rot", ?SKEY, ?CKEY, cert, Other),
    ok.

%%--------------------------------------------------------------------
%% handshake limits
%%--------------------------------------------------------------------

handshake_limit_per_ip(Config) ->
    Port = port(cntl_tls, Config),
    Idle = [begin
		{ok, I} = gen_tcp:connect("127.0.0.1", Port, [binary, {active,false}]),
		I
	    end || _ <- [1, 2]],
    timer:sleep(100),
    {ok, Third} = gen_tcp:connect("127.0.0.1", Port, [binary, {active,false}]),
    {error, closed} = gen_tcp:recv(Third, 0, 1000),
    {error, _} = ssl:connect("127.0.0.1", Port, [{verify,verify_none}], 1000),
    [gen_tcp:close(I) || I <- Idle],
    timer:sleep(200),
    {ok, S} = ssl:connect("127.0.0.1", Port, [{verify,verify_none}], 2000),
    ssl:close(S).

handshake_timeout(Config) ->
    {ok, Slow} = gen_tcp:connect("127.0.0.1", port(cntl_tls, Config),
				 [binary, {active,false}]),
    {error, closed} = gen_tcp:recv(Slow, 0, 3000),
    ok.

%%--------------------------------------------------------------------
%% ssh jump
%%--------------------------------------------------------------------

jump_direct(Config) ->
    Out = ssh_run(Config, tony, ["-J tony@127.0.0.1:", j(j2, Config),
				 " -p ", j(vport, Config), " home echo hi"]),
    true = string:find(Out, "home:echo hi") =/= nomatch,
    ok.

jump_chain(Config) ->
    %% laptop -> jump1 -> xylan2 (jump2) -> xylan tunnel -> nas
    Out = ssh_run(Config, tony, ["-J tony@127.0.0.1:", j(j1, Config),
				 ",tony@xylan2:", j(j2, Config),
				 " -p ", j(vport, Config), " nas.home uname"]),
    true = string:find(Out, "nas:uname") =/= nomatch,
    ok.

jump_user_acl(Config) ->
    Ok = ssh_run(Config, guest, ["-J guest@127.0.0.1:", j(j2, Config),
				 " -p ", j(vport, Config), " home id"]),
    true = string:find(Ok, "home:id") =/= nomatch,
    Denied = ssh_run(Config, guest, ["-J guest@127.0.0.1:", j(j2, Config),
				     " -p ", j(vport, Config), " nas.home id"]),
    nomatch = string:find(Denied, "nas:id"),
    ok.

jump_unknown_key(Config) ->
    Out = ssh_run(Config, other, ["-J tony@127.0.0.1:", j(j2, Config),
				  " -p ", j(vport, Config), " home id"]),
    nomatch = string:find(Out, "home:id"),
    ok.

jump_names_only(Config) ->
    %% raw address and wrong port are refused
    Ip = ssh_run(Config, tony, ["-J tony@127.0.0.1:", j(j2, Config),
				" -p ", j(vport, Config), " 127.0.1.1 id"]),
    nomatch = string:find(Ip, "home:id"),
    Port = ssh_run(Config, tony, ["-J tony@127.0.0.1:", j(j2, Config),
				  " -p 22 home id"]),
    nomatch = string:find(Port, "home:id"),
    ok.

jump_no_shell(Config) ->
    Out = ssh_run(Config, tony, ["-p ", j(j2, Config), " tony@127.0.0.1 echo hi"]),
    nomatch = string:find(Out, "echo hi"),
    nomatch = string:find(Out, "hi\n"),
    ok.

%%--------------------------------------------------------------------
%% api gateway
%%--------------------------------------------------------------------

gw_missing_key(Config) ->
    {401, B} = http_req(port(gw, Config), "GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n"),
    {_, _} = binary:match(B, <<"invalid_api_key">>),
    ok.

gw_bad_key(Config) ->
    Bad = flip(?config(api_key, Config), 30),
    {401, B} = http_req(port(gw, Config),
			["POST /v1/messages HTTP/1.1\r\nHost: x\r\nx-api-key: ", Bad,
			 "\r\nContent-Length: 2\r\n\r\n{}"]),
    {_, _} = binary:match(B, <<"authentication_error">>),
    ok.

gw_valid_key_forward(Config) ->
    Key = ?config(api_key, Config),
    Body = <<"{\"model\":\"llama3\",\"prompt\":\"hej\"}">>,
    {200, B} = http_req(port(gw, Config),
			["POST /api/generate HTTP/1.1\r\nHost: ollama.example.com\r\n",
			 "Authorization: Bearer ", Key, "\r\n",
			 "Connection: keep-alive\r\n",
			 "Content-Type: application/json\r\n",
			 "Content-Length: ", integer_to_list(byte_size(Body)), "\r\n\r\n",
			 Body]),
    %% the backend echoes the request it received
    nomatch = binary:match(B, list_to_binary(Key)),
    nomatch = binary:match(string:lowercase(B), <<"authorization">>),
    Host = iolist_to_binary(["Host: 127.0.0.1:", integer_to_list(port(backend, Config))]),
    {_, _} = binary:match(B, Host),
    nomatch = binary:match(B, <<"ollama.example.com">>),
    {_, _} = binary:match(B, <<"Connection: close">>),
    nomatch = binary:match(B, <<"keep-alive">>),
    {_, _} = binary:match(B, Body),
    ok.

gw_obs_fold(Config) ->
    {400, _} = http_req(port(gw, Config),
			"GET / HTTP/1.1\r\nHost: x\r\n folded: header\r\n\r\n"),
    ok.

gw_httpc(Config) ->
    Url = "https://localhost:" ++ integer_to_list(port(gw, Config)) ++ "/api/tags",
    %% Erlang ssl rejects any self-signed peer (selfsigned_peer) even when it
    %% is in cacertfile, so verify_none here. curl/openssl accept gw.pem
    %% with --cacert; xylan itself uses fingerprint pinning.
    {ok, {{_, 200, _}, _, _}} =
	httpc:request(get, {Url, [{"authorization", "Bearer " ++ ?config(api_key, Config)}]},
		      [{ssl, [{verify, verify_none}]}], []),
    ok.

gw_end_to_end(Config) ->
    Key = ?config(api_key, Config),
    {200, _} = http_req(port(user, Config),
			["GET /api/tags HTTP/1.1\r\nHost: x\r\n",
			 "Authorization: Bearer ", Key, "\r\n\r\n"]),
    {401, _} = http_req(port(user, Config), "GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n"),
    ok.

%%--------------------------------------------------------------------
%% helpers
%%--------------------------------------------------------------------

cert(Name, Config) ->
    maps:get(Name, ?config(certs, Config)).

cert_opts(Name, Config) ->
    {C, K, _} = cert(Name, Config),
    [{certfile, C}, {keyfile, K}].

%% allocate free ports
ports(Names) ->
    Ls = [begin {ok, L} = gen_tcp:listen(0, [{reuseaddr,true}]), {N, L} end
	  || N <- Names],
    Ps = maps:from_list([{N, element(2, inet:port(L))} || {N, L} <- Ls]),
    [gen_tcp:close(L) || {_, L} <- Ls],
    Ps.

port(Name, Config) when is_list(Config) ->
    port(Name, ?config(ports, Config));
port(Name, Ports) when is_map(Ports) ->
    maps:get(Name, Ports).

start_srv(Args) ->
    {ok, Pid} = xylan_srv:start_link([{id, "srv"} | Args]),
    unlink(Pid),
    Pid.

start_clt(Args) ->
    {ok, Pid} = xylan_clt:start_link([{server_ip, "127.0.0.1"},
				      {auth_timeout, 3000} | Args]),
    unlink(Pid),
    Pid.

start_jump(Opts) ->
    {ok, Pid} = xylan_jump:start_link(Opts),
    unlink(Pid),
    Pid.

%% ssh user key (PEM) + ssh client config, returns {ConfigFile, PubLine}
ssh_user(Dir, Name) ->
    KeyFile = filename:join(Dir, Name ++ "_key"),
    ok = filelib:ensure_dir(KeyFile),
    Key = public_key:generate_key({namedCurve, secp256r1}),
    ok = file:write_file(KeyFile, public_key:pem_encode(
				    [public_key:pem_entry_encode('ECPrivateKey', Key)])),
    ok = file:change_mode(KeyFile, 8#600),
    Pub = binary_to_list(
	    string:trim(ssh_file:encode([{ssh_file:extract_public_key(Key),
					  [{comment, Name}]}], openssh_key))),
    Cfg = filename:join(Dir, Name ++ ".ssh_config"),
    ok = file:write_file(Cfg, ["Host *\n",
			       "  IdentityFile ", KeyFile, "\n",
			       "  IdentitiesOnly yes\n",
			       "  StrictHostKeyChecking no\n",
			       "  UserKnownHostsFile /dev/null\n",
			       "  BatchMode yes\n",
			       "  LogLevel ERROR\n"]),
    {Cfg, Pub}.

%% a plain ssh daemon answering exec with "<Name>:<Command>"
start_sshd(Dir, Port, Name, Pubs) ->
    _ = xylan_jump:generate_host_key(Dir),
    UserDir = filename:join(Dir, "user"),
    ok = filelib:ensure_dir(filename:join(UserDir, "x")),
    ok = file:write_file(filename:join(UserDir, "authorized_keys"),
			 [[P, "\n"] || P <- Pubs]),
    Parent = self(),
    Pid = spawn(fun() ->
			{ok, D} = ssh:daemon(Port, [{system_dir, Dir}, {user_dir, UserDir},
						    {auth_methods, "publickey"},
						    {exec, {direct, fun(Cmd) ->
								     {ok, Name ++ ":" ++ Cmd}
							     end}}]),
			link(D),
			Parent ! {self(), ready},
			receive stop -> ok end
		end),
    receive {Pid, ready} -> Pid
    after 5000 -> ct:fail({sshd_not_started, Name})
    end.

ssh_run(Config, User, Args) ->
    Cfg = maps:get(User, ?config(ssh_cfg, Config)),
    Cmd = lists:flatten(["timeout 15 ssh -F ", Cfg, " ", Args, " 2>&1"]),
    Out = os:cmd(Cmd),
    ct:log("~s~n~s", [Cmd, Out]),
    Out.

j(Name, Config) ->
    integer_to_list(port(Name, Config)).

start_gw(Name, Opts) ->
    {ok, Pid} = xylan_gw:start_link(Name, Opts),
    unlink(Pid),
    Pid.

stop_procs(Config) ->
    [begin
	 Mon = erlang:monitor(process, P),
	 exit(P, shutdown),   %% no crash reports from sessions/proxies
	 receive {'DOWN', Mon, _, _, _} -> ok
	 after 1000 ->
		 exit(P, kill),
		 receive {'DOWN', Mon, _, _, _} -> ok end
	 end
     end || P <- ?config(procs, Config)],
    timer:sleep(100),  %% sessions/proxies follow their parents
    ok.

tls_opts(Extra) ->
    [binary, {packet,4}, {active,false}, {verify,verify_none} | Extra].

tls_auth(Config, ID, SKey, CKey, Alg, Extra) ->
    {ok, C} = ssl:connect("127.0.0.1", port(cntl_tls, Config), tls_opts(Extra), 3000),
    auth(ssl, C, ID, SKey, CKey, Alg).

auth(M, C, ID, SKey0, CKey0, Alg) ->
    SKey = xylan_lib:make_key(SKey0),
    CKey = xylan_lib:make_key(CKey0),
    Chal = crypto:strong_rand_bytes(16),
    Req = case Alg of
	      sha -> {auth_req, [{id,ID}, {chal,Chal}]};
	      _ -> {auth_req, [{id,ID}, {chal,Chal}, {alg,Alg}]}
	  end,
    ok = M:send(C, term_to_binary(Req)),
    case M:recv(C, 0, 2000) of
	{ok, B} ->
	    {auth_res, [{id,_}, {chal,SChal}, {cred,Cred}]} = binary_to_term(B),
	    Cred = xylan_lib:auth_cred(Alg, SKey, server, Chal),
	    Cred1 = xylan_lib:auth_cred(Alg, CKey, client, SChal),
	    ok = M:send(C, term_to_binary({auth_ack, [{id,ID}, {cred,Cred1}]})),
	    case ping_ok({M, C}) of
		true -> {ok, C};
		false -> rejected
	    end;
	_ ->
	    rejected
    end.

ping_ok(C) when not is_tuple(C); element(1, C) =:= sslsocket ->
    ping_ok({ssl, C});
ping_ok({M, C}) ->
    case M:send(C, term_to_binary(ping)) of
	ok ->
	    case M:recv(C, 0, 1000) of
		{ok, P} -> binary_to_term(P) =:= pong;
		_ -> false
	    end;
	_ -> false
    end.

recv_term(C) ->
    {ok, B} = ssl:recv(C, 0, 5000),
    binary_to_term(B).

data_connect(Config, Sk, Extra) ->
    {ok, D} = ssl:connect("127.0.0.1", port(data_tls, Config), tls_opts(Extra), 3000),
    ok = ssl:send(D, Sk),
    case ssl:recv(D, 0, 1500) of
	{error, closed} -> rejected;
	Other -> Other
    end.

%% act as client proxy B side + echo service
data_echo(Config, Sk, Extra) ->
    {ok, D} = ssl:connect("127.0.0.1", port(data_tls, Config), tls_opts(Extra), 3000),
    ok = ssl:send(D, Sk),
    ok = ssl:setopts(D, [{packet,0}]),
    Pid = spawn(fun() -> receive go -> echo_loop(ssl, D) end end),
    ok = ssl:controlling_process(D, Pid),
    Pid ! go,
    ok.

user_echo(Port) ->
    {ok, U} = gen_tcp:connect("127.0.0.1", Port, [binary, {active,false}]),
    ok = gen_tcp:send(U, ?MSG),
    R = gen_tcp:recv(U, byte_size(?MSG), 5000),
    gen_tcp:close(U),
    R =:= {ok, ?MSG}.

start_echo(Port) ->
    Parent = self(),
    Pid = spawn(fun() ->
			{ok, L} = gen_tcp:listen(Port, [binary, {reuseaddr,true},
							{active,false}]),
			Parent ! {self(), ready},
			echo_accept(L)
		end),
    receive {Pid, ready} -> Pid end.

echo_accept(L) ->
    {ok, S} = gen_tcp:accept(L),
    Pid = spawn(fun() -> receive go -> echo_loop(gen_tcp, S) end end),
    ok = gen_tcp:controlling_process(S, Pid),
    Pid ! go,
    echo_accept(L).

echo_loop(M, S) ->
    case M:recv(S, 0) of
	{ok, Data} -> M:send(S, Data), echo_loop(M, S);
	_ -> M:close(S)
    end.

%% http backend replying 200 with the received request as body
start_http_backend(Port) ->
    Parent = self(),
    Pid = spawn(fun() ->
			{ok, L} = gen_tcp:listen(Port, [binary, {reuseaddr,true},
							{active,false}]),
			Parent ! {self(), ready},
			backend_loop(L)
		end),
    receive {Pid, ready} -> Pid end.

backend_loop(L) ->
    {ok, S} = gen_tcp:accept(L),
    Req = backend_read(S, <<>>),
    gen_tcp:send(S, ["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n",
		     "Content-Length: ", integer_to_list(byte_size(Req)),
		     "\r\nConnection: close\r\n\r\n", Req]),
    gen_tcp:close(S),
    backend_loop(L).

backend_read(S, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
	{P, 4} ->
	    Len = case re:run(Acc, "Content-Length: *([0-9]+)",
			      [{capture, [1], list}, caseless]) of
		      {match, [N]} -> list_to_integer(N);
		      _ -> 0
		  end,
	    if byte_size(Acc) >= P + 4 + Len -> Acc;
	       true -> backend_read(S, recv_more(S, Acc))
	    end;
	nomatch ->
	    backend_read(S, recv_more(S, Acc))
    end.

recv_more(S, Acc) ->
    {ok, D} = gen_tcp:recv(S, 0, 5000),
    <<Acc/binary, D/binary>>.

%% raw request over tls, returns {Status, WholeResponse}
http_req(Port, Req) ->
    {ok, S} = ssl:connect("127.0.0.1", Port, [binary, {active,false},
					     {verify,verify_none}], 5000),
    ok = ssl:send(S, Req),
    R = recv_all(S, <<>>),
    ssl:close(S),
    case R of
	<<"HTTP/1.1 ", St:3/binary, _/binary>> -> {binary_to_integer(St), R};
	_ -> {0, R}
    end.

recv_all(S, Acc) ->
    case ssl:recv(S, 0, 5000) of
	{ok, D} -> recv_all(S, <<Acc/binary, D/binary>>);
	_ -> Acc
    end.

flip(K, N) ->
    {A, [C | B]} = lists:split(N, K),
    A ++ [if C =:= $a -> $b; true -> $a end | B].
