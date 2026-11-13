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
%%%    API key gateway, placed close to the web service (e.g ollama).
%%%    Terminates (optional) tls, checks the API key and forwards the
%%%    request to the target.
%%%
%%%    Accepted key headers:
%%%       Authorization: Bearer sk-xyl-...    (OpenAI style)
%%%       x-api-key: sk-xyl-...               (Anthropic style)
%%%
%%%    The key headers are removed before forwarding. Each connection
%%%    carries exactly one request (Connection: close is forced) so every
%%%    request is checked and its headers rewritten without the need to
%%%    parse the HTTP message framing.
%%%
%%%    Config (xylan env):
%%%    {api_gateways,
%%%      [{ollama, [{port, 11443},
%%%                 {ip, {127,0,0,1}},                %% listen address
%%%                 {target, {"127.0.0.1", 11434}},
%%%                 {tls, [{certfile,"..."},{keyfile,"..."}]}, %% optional
%%%                 {host, rewrite},                  %% rewrite | keep
%%%                 {max_connections, 64},
%%%                 {header_timeout, 10000},
%%%                 {idle_timeout, 600000}
%%%                ]}]}
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_gw).

-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("xylan_log.hrl").

-define(MAX_HEADER, 32768).

-record(conf,
	{
	  name :: atom(),
	  tls :: undefined | list(),
	  target :: {inet:hostname()|inet:ip_address(), inet:port_number()},
	  host = rewrite :: rewrite | keep,
	  header_timeout = 10000 :: timeout(),
	  idle_timeout = 600000 :: timeout()
	}).

-record(state,
	{
	  conf :: #conf{},
	  listen :: gen_tcp:socket(),
	  acceptor :: pid(),
	  conns = #{} :: #{reference() => pid()},
	  max_conns = 64 :: non_neg_integer()
	}).

start_link(Name, Opts) when is_atom(Name) ->
    gen_server:start_link({local, list_to_atom("xylan_gw_" ++
						   atom_to_list(Name))},
			  ?MODULE, [Name, Opts], []).

init([Name, Opts]) ->
    process_flag(trap_exit, true),
    Port = proplists:get_value(port, Opts),
    IP = proplists:get_value(ip, Opts, {127,0,0,1}),
    Target = case proplists:get_value(target, Opts) of
		 {TIP, TPort} when is_integer(TPort) -> {TIP, TPort};
		 _ -> erlang:error({bad_target, Name})
	     end,
    Tls = case proplists:get_value(tls, Opts) of
	      undefined -> undefined;
	      TlsOpts when is_list(TlsOpts) ->
		  Defaults = [{versions, ['tlsv1.3','tlsv1.2']},
			      {alpn_preferred_protocols, [<<"http/1.1">>]}],
		  lists:ukeymerge(1, lists:ukeysort(1, TlsOpts),
				  lists:ukeysort(1, Defaults))
	  end,
    Conf = #conf { name = Name,
		   tls = Tls,
		   target = Target,
		   host = proplists:get_value(host, Opts, rewrite),
		   header_timeout = proplists:get_value(header_timeout,Opts,10000),
		   idle_timeout = proplists:get_value(idle_timeout,Opts,600000) },
    case gen_tcp:listen(Port, [binary, {ip,IP}, {active,false},
			       {reuseaddr,true}, {nodelay,true},
			       {backlog,128}]) of
	{ok, L} ->
	    ?info("api gateway ~s listen ~s:~w tls=~w target ~p",
		  [Name, inet:ntoa(IP), Port, Tls =/= undefined, Target]),
	    Self = self(),
	    Acceptor = spawn_link(fun() -> accept_loop(Self, L) end),
	    {ok, #state { conf = Conf, listen = L, acceptor = Acceptor,
			  max_conns = proplists:get_value(max_connections,
							  Opts, 64) }};
	{error, Reason} ->
	    {stop, {listen, Port, Reason}}
    end.

handle_call(accepted, _From, State) ->
    case maps:size(State#state.conns) >= State#state.max_conns of
	true ->
	    {reply, reject, State};
	false ->
	    Conf = State#state.conf,
	    Pid = spawn(fun() -> conn_init(Conf) end),
	    Mon = erlang:monitor(process, Pid),
	    {reply, {ok, Pid},
	     State#state { conns = (State#state.conns)#{ Mon => Pid } }}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, State) ->
    {noreply, State#state { conns = maps:remove(Mon, State#state.conns) }};
handle_info({'EXIT', Pid, Reason}, State) when
      Pid =:= State#state.acceptor ->
    {stop, {acceptor, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    gen_tcp:close(State#state.listen),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Acceptor
%%%===================================================================

accept_loop(Gw, L) ->
    case gen_tcp:accept(L) of
	{ok, S} ->
	    case gen_server:call(Gw, accepted) of
		{ok, Pid} ->
		    case gen_tcp:controlling_process(S, Pid) of
			ok -> Pid ! {go, S};
			_ -> gen_tcp:close(S), exit(Pid, kill)
		    end;
		reject ->
		    ?warning("api gateway too many connections"),
		    gen_tcp:close(S)
	    end,
	    accept_loop(Gw, L);
	{error, closed} ->
	    exit(normal);
	{error, _Reason} ->
	    timer:sleep(100),
	    accept_loop(Gw, L)
    end.

%%%===================================================================
%%% Connection
%%%===================================================================

conn_init(Conf) ->
    S = receive {go, S0} -> S0
	after 5000 -> exit(normal)
	end,
    Peer = case inet:peername(S) of
	       {ok, {PIP, PPort}} -> inet:ntoa(PIP) ++ ":" ++ integer_to_list(PPort);
	       _ -> "?"
	   end,
    case tls_accept(S, Conf) of
	{ok, C} ->
	    handle_request(C, Peer, Conf);
	{error, _Reason} ->
	    ?info("api gateway ~s tls handshake from ~s failed ~p",
		  [Conf#conf.name, Peer, _Reason]),
	    gen_tcp:close(S)
    end.

tls_accept(S, #conf { tls = undefined }) ->
    {ok, {gen_tcp, S}};
tls_accept(S, #conf { tls = Opts, header_timeout = Timeout }) ->
    case ssl:handshake(S, Opts, Timeout) of
	{ok, SS} -> {ok, {ssl, SS}};
	Error -> Error
    end.

handle_request(C, Peer, Conf) ->
    Name = Conf#conf.name,
    Deadline = erlang:monotonic_time(millisecond) + Conf#conf.header_timeout,
    case read_header(C, <<>>, Deadline) of
	{ok, Head, Rest} ->
	    case parse_head(Head) of
		{ok, ReqLine, Headers} ->
		    Style = error_style(Headers),
		    case find_key(Headers) of
			undefined ->
			    ?info("api gateway ~s: ~s no api key", [Name, Peer]),
			    reply_error(C, 401, Style, "missing api key");
			Key ->
			    case xylan_apikey:verify(Key, Name) of
				{ok, Id, KeyName} ->
				    ?info("api gateway ~s: ~s key ~s (~s) ~s",
					  [Name, Peer, Id, KeyName, ReqLine]),
				    forward(C, ReqLine, Headers, Rest, Conf);
				{error, Reason} ->
				    ?warning("api gateway ~s: ~s rejected ~p",
					     [Name, Peer, Reason]),
				    reply_error(C, 401, Style,
						"invalid api key")
			    end
		    end;
		{error, _} ->
		    reply_error(C, 400, openai, "bad request")
	    end;
	{error, too_large} ->
	    reply_error(C, 431, openai, "request header too large");
	{error, _} ->
	    close(C)
    end.

read_header(C, Buf, Deadline) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
	{Pos, 4} ->
	    <<Head:Pos/binary, _:4/binary, Rest/binary>> = Buf,
	    {ok, Head, Rest};
	nomatch when byte_size(Buf) > ?MAX_HEADER ->
	    {error, too_large};
	nomatch ->
	    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
	    case recv(C, Timeout) of
		{ok, Data} -> read_header(C, <<Buf/binary, Data/binary>>,
					  Deadline);
		Error -> Error
	    end
    end.

%% returns request line and [{LowerName, Line}]
parse_head(Head) ->
    [ReqLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    case binary:split(ReqLine, <<" ">>, [global]) of
	[_Method, _Target, <<"HTTP/1.", _>>] ->
	    try {ok, ReqLine, [parse_header_line(L) || L <- Lines]}
	    catch throw:Reason -> {error, Reason}
	    end;
	_ ->
	    {error, bad_request_line}
    end.

parse_header_line(<<C, _/binary>>) when C =:= $\s; C =:= $\t ->
    throw(obs_fold);  %% obsolete line folding is rejected
parse_header_line(Line) ->
    case binary:split(Line, <<":">>) of
	[Name, Value] when byte_size(Name) > 0 ->
	    {string:lowercase(Name), string:trim(Value), Line};
	_ ->
	    throw(bad_header)
    end.

find_key(Headers) ->
    case lists:keyfind(<<"x-api-key">>, 1, Headers) of
	{_, Key, _} -> Key;
	false ->
	    case lists:keyfind(<<"authorization">>, 1, Headers) of
		{_, <<Bearer:7/binary, Key/binary>>, _} ->
		    case string:lowercase(Bearer) of
			<<"bearer ">> -> string:trim(Key);
			_ -> undefined
		    end;
		_ -> undefined
	    end
    end.

error_style(Headers) ->
    case lists:keymember(<<"x-api-key">>, 1, Headers) orelse
	lists:keymember(<<"anthropic-version">>, 1, Headers) of
	true -> anthropic;
	false -> openai
    end.

%% headers never forwarded to the target
-define(STRIP, [<<"authorization">>, <<"x-api-key">>, <<"connection">>,
		<<"keep-alive">>, <<"proxy-connection">>, <<"upgrade">>,
		<<"te">>]).

forward(C, ReqLine, Headers, Rest, Conf) ->
    {TIP, TPort} = Conf#conf.target,
    Strip = case Conf#conf.host of
		rewrite -> [<<"host">> | ?STRIP];
		keep -> ?STRIP
	    end,
    Host = case Conf#conf.host of
	       rewrite -> [<<"Host: ">>, host_string(TIP), $:,
			   integer_to_list(TPort), <<"\r\n">>];
	       keep -> []
	   end,
    Head = [ReqLine, <<"\r\n">>,
	     [[Line, <<"\r\n">>] || {N, _V, Line} <- Headers,
				    not lists:member(N, Strip)],
	     Host,
	     <<"Connection: close\r\n\r\n">>, Rest],
    case gen_tcp:connect(TIP, TPort, [binary, {active,false}, {nodelay,true}],
			 5000) of
	{ok, T} ->
	    ok = gen_tcp:send(T, Head),
	    relay(C, T, Conf#conf.idle_timeout);
	{error, Reason} ->
	    ?warning("api gateway ~s: target ~p:~w ~p",
		     [Conf#conf.name, TIP, TPort, Reason]),
	    reply_error(C, 502, openai, "service unavailable")
    end.

host_string(IP) when is_tuple(IP) -> inet:ntoa(IP);
host_string(Host) when is_atom(Host) -> atom_to_list(Host);
host_string(Host) -> Host.

relay(C={_, CS}, T, Idle) ->
    setopts(C, [{active, once}]),
    inet:setopts(T, [{active, once}]),
    relay_loop(C, CS, T, Idle).

relay_loop(C, CS, T, Idle) ->
    receive
	{tcp, T, Data} ->
	    case send(C, Data) of
		ok -> inet:setopts(T, [{active, once}]),
		      relay_loop(C, CS, T, Idle);
		_ -> done(C, T)
	    end;
	{Tag, CS, Data} when Tag =:= tcp; Tag =:= ssl ->
	    case gen_tcp:send(T, Data) of
		ok -> setopts(C, [{active, once}]),
		      relay_loop(C, CS, T, Idle);
		_ -> done(C, T)
	    end;
	{tcp_closed, T} -> done(C, T);
	{tcp_error, T, _} -> done(C, T);
	{Tag, CS} when Tag =:= tcp_closed; Tag =:= ssl_closed -> done(C, T);
	{Tag, CS, _} when Tag =:= tcp_error; Tag =:= ssl_error -> done(C, T)
    after Idle ->
	    done(C, T)
    end.

done(C, T) ->
    gen_tcp:close(T),
    close(C).

reply_error(C, Status, Style, Message) ->
    Body = error_body(Style, Status, Message),
    Auth = if Status =:= 401 -> <<"WWW-Authenticate: Bearer\r\n">>;
	      true -> <<>>
	   end,
    send(C, [<<"HTTP/1.1 ">>, integer_to_list(Status), $\s,
	     status_text(Status), <<"\r\n">>,
	     <<"Content-Type: application/json\r\n">>,
	     <<"Content-Length: ">>, integer_to_list(iolist_size(Body)),
	     <<"\r\n">>, Auth,
	     <<"Connection: close\r\n\r\n">>, Body]),
    close(C).

%% Message is a constant (no json escaping needed)
error_body(anthropic, Status, Message) ->
    Type = case Status of
	       401 -> "authentication_error";
	       502 -> "api_error";
	       _ -> "invalid_request_error"
	   end,
    ["{\"type\":\"error\",\"error\":{\"type\":\"", Type,
     "\",\"message\":\"", Message, "\"}}"];
error_body(openai, Status, Message) ->
    Code = case Status of
	       401 -> "\"invalid_api_key\"";
	       _ -> "null"
	   end,
    ["{\"error\":{\"message\":\"", Message,
     "\",\"type\":\"invalid_request_error\",\"code\":", Code, "}}"].

status_text(400) -> "Bad Request";
status_text(401) -> "Unauthorized";
status_text(431) -> "Request Header Fields Too Large";
status_text(502) -> "Bad Gateway";
status_text(_) -> "Error".

recv({gen_tcp, S}, Timeout) -> gen_tcp:recv(S, 0, Timeout);
recv({ssl, S}, Timeout) -> ssl:recv(S, 0, Timeout).

send({gen_tcp, S}, Data) -> gen_tcp:send(S, Data);
send({ssl, S}, Data) -> ssl:send(S, Data).

setopts({gen_tcp, S}, Opts) -> inet:setopts(S, Opts);
setopts({ssl, S}, Opts) -> ssl:setopts(S, Opts).

close({gen_tcp, S}) -> gen_tcp:close(S);
close({ssl, S}) -> ssl:close(S).
