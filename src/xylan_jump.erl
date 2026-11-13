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
%%%    SSH proxy jump server.
%%%
%%%    A ProxyJump compatible ssh daemon (ssh -J) that only forwards
%%%    (direct-tcpip) to named targets, typically xylan user ports bound
%%%    to loopback addresses that route into the xylan tunnels. The ssh
%%%    session to the final machine is end-to-end, this server only sees
%%%    the encrypted inner session. No shell, exec or sftp.
%%%
%%%    {ssh_jump,
%%%     [{port, 2222},
%%%      {ip, any},
%%%      {system_dir, "/etc/xylan/ssh"},   %% ssh_host_*_key
%%%      {virtual_port, 10022},            %% port used for {Name, IP} targets
%%%      {targets,
%%%       [{"home",     {127,0,1,1}},      %% xylan user port 127.0.1.1:10022
%%%        {"nas.home", {127,0,1,2}},
%%%        {"xylan2",   {"xylan2.example.com", 2222}}]},  %% next jump
%%%      {users,
%%%       [{"tony",  [{keys, ["ssh-ed25519 AAAA... tony@laptop"]},
%%%                   {allow, all}]},
%%%        {"guest", [{authorized_keys, "/etc/xylan/ssh/guest.pub"},
%%%                   {allow, ["home"]}]}]}]}
%%%
%%%    Users connect with
%%%       ssh -J tony@xylan3.example.com:2222 -p 10022 home
%%%    or in ~/.ssh/config
%%%       Host *.x
%%%           ProxyJump tony@xylan3.example.com:2222
%%%           Port 10022
%%%
%%%    Target names are registered in the node resolver (inet_db) so the
%%%    forwarding connects to the configured address. Only names are
%%%    accepted, never raw addresses.
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_jump).

-behaviour(gen_server).

-export([start_link/1]).
-export([generate_host_key/1]).
-export([host_key_fingerprints/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("xylan_log.hrl").

-define(DEFAULT_PORT, 2222).
-define(DEFAULT_VIRTUAL_PORT, 10022).
-define(USER_KEY, xylan_jump_user).  %% process dictionary, connection process

-record(state,
	{
	  daemon :: pid(),
	  port :: inet:port_number(),
	  names = [] :: [{inet:ip_address(), [string()]}]
	}).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% Create an ECDSA P-256 host key (PEM, readable by OpenSSH and OTP)
%% in Dir unless one exists. Returns the ssh fingerprints of the host keys.
generate_host_key(Dir) ->
    File = filename:join(Dir, "ssh_host_ecdsa_key"),
    case filelib:is_file(File) of
	true ->
	    ok;
	false ->
	    ok = filelib:ensure_dir(File),
	    Priv = public_key:generate_key({namedCurve, secp256r1}),
	    Pem = public_key:pem_encode(
		    [public_key:pem_entry_encode('ECPrivateKey', Priv)]),
	    Tmp = File ++ ".tmp",
	    ok = file:write_file(Tmp, <<>>),
	    ok = file:change_mode(Tmp, 8#600),
	    ok = file:write_file(Tmp, Pem),
	    ok = file:rename(Tmp, File)
    end,
    host_key_fingerprints(Dir).

%% [{File, "SHA256:..."}] for the host keys in Dir
host_key_fingerprints(Dir) ->
    Files = filelib:wildcard(filename:join(Dir, "ssh_host_*_key")),
    lists:append(
      [case host_key_fingerprint(F) of
	   undefined -> [];
	   FP -> [{F, FP}]
       end || F <- Files]).

host_key_fingerprint(File) ->
    try
	{ok, Bin} = file:read_file(File),
	Priv = case public_key:pem_decode(Bin) of
		   [Entry] -> public_key:pem_entry_decode(Entry);
		   [] -> element(1, hd(ssh_file:decode(Bin, openssh_key_v1)))
	       end,
	ssh:hostkey_fingerprint(sha256, ssh_file:extract_public_key(Priv))
    catch
	_:_ -> undefined
    end.

%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(ssh),
    Port = proplists:get_value(port, Opts, ?DEFAULT_PORT),
    IP = proplists:get_value(ip, Opts, any),
    SystemDir = proplists:get_value(system_dir, Opts),
    VPort = proplists:get_value(virtual_port, Opts, ?DEFAULT_VIRTUAL_PORT),
    Targets = [target(T, VPort) || T <- proplists:get_value(targets, Opts, [])],
    Users = maps:from_list([user(U) || U <- proplists:get_value(users, Opts, [])]),
    case host_key_fingerprints(SystemDir) of
	[] ->
	    ?error("ssh jump: no host key in ~p, create one with "
		   "xylan:generate_ssh_host_key(Dir)", [SystemDir]),
	    {stop, no_host_key};
	FPs ->
	    [?info("ssh jump host key ~s ~s", [F, FP]) || {F, FP} <- FPs],
	    Names = register_names(Targets),
	    DaemonOpts =
		[{system_dir, SystemDir},
		 {key_cb, {xylan_jump_keys, [{users, Users}]}},
		 {auth_methods, "publickey"},
		 {tcpip_tunnel_in, tunnel_fun(Targets, Users)},
		 {tcpip_tunnel_out, false},
		 {ssh_cli, no_cli},             %% no shell / exec
		 {subsystems, []},              %% no sftp
		 {connectfun, fun connected/3},
		 {failfun, fun failed/3}],
	    case ssh:daemon(IP, Port, DaemonOpts) of
		{ok, Daemon} ->
		    link(Daemon),
		    ?info("ssh jump listen ~p:~w, ~w targets, ~w users",
			  [IP, Port, length(Targets), maps:size(Users)]),
		    {ok, #state { daemon = Daemon, port = Port, names = Names }};
		{error, Reason} ->
		    unregister_names(Names),
		    {stop, {ssh_daemon, Port, Reason}}
	    end
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State) when Pid =:= State#state.daemon ->
    {stop, {ssh_daemon, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    try ssh:stop_daemon(State#state.daemon) catch _:_ -> ok end,
    unregister_names(State#state.names),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

%% {Name, IP, Port}
target({Name, {Addr, Port}}, _VPort) when is_integer(Port) ->
    {Name, resolve(Name, Addr), Port};
target({Name, Addr}, VPort) ->
    {Name, resolve(Name, Addr), VPort}.

resolve(_Name, IP) when is_tuple(IP) -> IP;
resolve(Name, Host) ->
    case inet:getaddr(Host, inet) of
	{ok, IP} -> IP;
	{error, Reason} ->
	    ?error("ssh jump target ~s: can not resolve ~s ~p",
		   [Name, Host, Reason]),
	    erlang:error({bad_target, Name})
    end.

%% {UserName, #{keys => [PublicKey], allow => all | [Name]}}
user({Name, Props}) ->
    Lines = [list_to_binary(K) || K <- proplists:get_value(keys, Props, [])] ++
	case proplists:get_value(authorized_keys, Props) of
	    undefined -> [];
	    File ->
		case file:read_file(File) of
		    {ok, Bin} -> [Bin];
		    {error, Reason} ->
			?error("ssh jump user ~s: ~s ~p", [Name, File, Reason]),
			[]
		end
	end,
    Keys = lists:append([decode_keys(L) || L <- Lines]),
    if Keys =:= [] -> ?warning("ssh jump user ~s has no keys", [Name]);
       true -> ok
    end,
    {Name, #{ keys => Keys,
	      allow => proplists:get_value(allow, Props, []) }}.

decode_keys(Bin) ->
    try ssh_file:decode(Bin, auth_keys) of
	KeyAttrs when is_list(KeyAttrs) -> [K || {K, _} <- KeyAttrs];
	_ -> []
    catch
	_:_ -> []
    end.

%% make the target names resolve to their addresses in this node
register_names(Targets) ->
    case inet_db:res_option(lookup) of
	[file | _] -> ok;
	Lookup -> inet_db:set_lookup([file | Lookup -- [file]])
    end,
    ByIP = lists:foldl(fun({Name, IP, _}, Acc) ->
			       maps:update_with(IP, fun(Ns) -> [Name|Ns] end,
						[Name], Acc)
		       end, #{}, Targets),
    [begin inet_db:add_host(IP, Names), {IP, Names} end ||
	{IP, Names} <- maps:to_list(ByIP)].

unregister_names(Names) ->
    [inet_db:del_host(IP) || {IP, _} <- Names],
    ok.

%% runs in the ssh connection process
connected(User, {IP, Port}, _Method) ->
    put(?USER_KEY, User),
    ?info("ssh jump: ~s logged in from ~s:~w", [User, inet:ntoa(IP), Port]).

failed(User, {IP, Port}, Reason) ->
    ?warning("ssh jump: ~s from ~s:~w login failed ~p",
	     [User, inet:ntoa(IP), Port, Reason]).

%% decide on a direct-tcpip request, runs in the connection process
tunnel_fun(Targets, Users) ->
    fun(Host, Port) ->
	    User = get(?USER_KEY),
	    Allowed = case lists:keyfind(Host, 1, Targets) of
			  {Host, _IP, Port} -> allowed(User, Host, Users);
			  {Host, _IP, TPort} -> {false, {port, TPort}};
			  false -> {false, unknown_target}
		      end,
	    case Allowed of
		true ->
		    ?info("ssh jump: ~s -> ~s:~w", [User, Host, Port]),
		    true;
		{false, Why} ->
		    ?warning("ssh jump: ~s -> ~s:~w denied ~p",
			     [User, Host, Port, Why]),
		    denied
	    end
    end.

allowed(undefined, _Host, _Users) ->
    {false, not_authenticated};
allowed(User, Host, Users) ->
    case maps:find(User, Users) of
	{ok, #{ allow := all }} -> true;
	{ok, #{ allow := Allow }} ->
	    case lists:member(Host, Allow) of
		true -> true;
		false -> {false, not_allowed}
	    end;
	error -> {false, unknown_user}
    end.
