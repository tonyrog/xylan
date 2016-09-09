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
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%    xylan sockets
%%%
%%% Created : 17 Jan 2015 by Tony Rogvall
%%% @end

-module(xylan_socket).

-export([listen/1, listen/2, listen/3]).
-export([accept/1, accept/2]).
-export([async_accept/1, async_accept/2]).
-export([connect/2, connect/3, connect/4, connect/5]).
%% -export([async_connect/2, async_connect/3, async_connect/4]).
-export([async_socket/2]).
-export([close/1, shutdown/2]).
-export([send/2, recv/2, recv/3]).
-export([getopts/2, setopts/2, sockname/1, peername/1]).
-export([controlling_process/2]).
-export([pair/0]).
-export([stats/0, getstat/2]).
-export([tags/1, socket/1]).
-export([request_type/1]).

-include("xylan_socket.hrl").

%%
%% List of protocols supported
%%  [tcp]
%%  [tcp,ssl]
%%  [tcp,ssl,http]
%%  [tcp,propbe_ssl,http]
%%  [tcp,http]
%%
%% coming soon: sctcp, ssh
%%
%%
listen(Port) ->
    listen(Port, [tcp], []).

listen(Port, Opts) ->
    listen(Port,[tcp], Opts).

listen(Port, Protos=[tcp|_], Opts0) ->
    Opts1 = proplists:expand([{binary, [{mode, binary}]},
			      {list, [{mode, list}]}], Opts0),
    {TcpOpts, Opts2} = split_options(tcp_listen_options(), Opts1),
    lager:debug("listen options=~w, other=~w\n", [TcpOpts, Opts2]),
    Active = proplists:get_value(active, TcpOpts, false),
    Mode   = proplists:get_value(mode, TcpOpts, list),
    Packet = proplists:get_value(packet, TcpOpts, 0),
    {_, TcpOpts1} = split_options([active,packet,mode], TcpOpts),
    TcpListenOpts = [{active,false},{packet,0},{mode,binary}|TcpOpts1],
    case gen_tcp:listen(Port, TcpListenOpts) of
	{ok, L} ->
	    {ok, #xylan_socket { mdata    = gen_tcp,
			       mctl     = inet,
			       protocol = Protos,
			       transport = L,
			       socket   = L,
			       active   = Active,
			       mode     = Mode,
			       packet   = Packet,
			       opts     = Opts2,
			       tags     = {tcp,tcp_closed,tcp_error}
			     }};
	Error ->
	    Error
    end.

%% 
%%
%%
connect(Host, Port) ->
    connect(Host, Port, [tcp], [], infinity).

connect(Host, Port, Opts) ->
    connect(Host, Port, [tcp], Opts, infinity).

connect(Host, Port, Opts, Timeout) ->
    connect(Host, Port, [tcp], Opts, Timeout).

connect(_Host, File, Protos=[tcp|_], Opts0, Timeout)
  when is_list(File) -> %% unix domain socket
    Opts1 = proplists:expand([{binary, [{mode, binary}]},
			      {list, [{mode, list}]}], Opts0),
    {TcpOpts, Opts2} = split_options(tcp_connect_options(), Opts1),
    Active = proplists:get_value(active, TcpOpts, false),
    Mode   = proplists:get_value(mode, TcpOpts, list),
    Packet = proplists:get_value(packet, TcpOpts, 0),
    {_, TcpOpts1} = split_options([active,packet,mode], TcpOpts),
    TcpConnectOpts = [{active,false},{packet,0},{mode,binary}|TcpOpts1],
    case afunix:connect(File, TcpConnectOpts, Timeout) of
	{ok, S} ->
	    X = 
		#xylan_socket { mdata   = afunix,
				mctl    = afunix,
				protocol = Protos,
				transport = S,
				socket   = S,
				active   = Active,
				mode     = Mode,
				packet   = Packet,
				opts     = Opts2,
				tags     = {tcp,tcp_closed,tcp_error}
			      },
	    connect_upgrade(X, tl(Protos), Timeout);
	Error ->
	    Error
    end;
connect(Host, Port, Protos=[tcp|_], Opts0, Timeout) -> %% tcp socket
    Opts1 = proplists:expand([{binary, [{mode, binary}]},
			      {list, [{mode, list}]}], Opts0),
    {TcpOpts, Opts2} = split_options(tcp_connect_options(), Opts1),
    Active = proplists:get_value(active, TcpOpts, false),
    Mode   = proplists:get_value(mode, TcpOpts, list),
    Packet = proplists:get_value(packet, TcpOpts, 0),
    {_, TcpOpts1} = split_options([active,packet,mode], TcpOpts),
    TcpConnectOpts = [{active,false},{packet,0},{mode,binary}|TcpOpts1],
    case gen_tcp:connect(Host, Port, TcpConnectOpts, Timeout) of
	{ok, S} ->
	    X = 
		#xylan_socket { mdata   = gen_tcp,
				mctl    = inet,
				protocol = Protos,
				transport = S,
				socket   = S,
				active   = Active,
				mode     = Mode,
				packet   = Packet,
				opts     = Opts2,
				tags     = {tcp,tcp_closed,tcp_error}
			    },
	    connect_upgrade(X, tl(Protos), Timeout);
	Error ->
	    Error
    end.

connect_upgrade(X, Protos0, Timeout) ->
    lager:debug("connect protos=~w\n", [Protos0]),
    case Protos0 of
	[ssl|Protos1] ->
	    Opts = X#xylan_socket.opts,
	    {SSLOpts0,Opts1} = split_options(ssl_connect_opts(),Opts),
	    {_,SSLOpts} = split_options([ssl_imp], SSLOpts0),
	    lager:debug("SSL upgrade, options = ~w\n", [SSLOpts]),
	    lager:debug("before ssl:connect opts=~w\n", 
		 [getopts(X, [active,packet,mode])]),
	    case ssl_connect(X#xylan_socket.socket, SSLOpts, Timeout) of
		{ok,S1} ->
		    lager:debug("ssl:connect opt=~w\n", 
			 [ssl:getopts(S1, [active,packet,mode])]),
		    X1 = X#xylan_socket { socket=S1,
					  mdata = ssl,
					  mctl  = ssl,
					  opts=Opts1,
					  tags={ssl,ssl_closed,ssl_error}},
		    connect_upgrade(X1, Protos1, Timeout);
		Error={error,_Reason} ->
		    lager:warning("ssl:connect error=~w\n", [_Reason]),
		    Error
	    end;
	[http|Protos1] ->
	    {_, Close,Error} = X#xylan_socket.tags,
	    X1 = X#xylan_socket { packet = http, 
				  tags = {http, Close, Error }},
	    connect_upgrade(X1, Protos1, Timeout);
	[] ->
	    setopts(X, [{mode,X#xylan_socket.mode},
			{packet,X#xylan_socket.packet},
			{active,X#xylan_socket.active}]),
	    lager:debug("after upgrade opts=~w\n", 
		 [getopts(X, [active,packet,mode])]),
	    {ok,X}
    end.
			       
ssl_connect(Socket, Options, Timeout) ->    
    case ssl:connect(Socket, Options, Timeout) of
	{error, ssl_not_started} ->
	    ssl:start(),
	    ssl:connect(Socket, Options, Timeout);
	Result ->
	    Result
    end.

%% using this little trick we avoid code loading
%% problem in a module doing blocking accept call
async_accept(X) ->
    async_accept(X,infinity).

async_accept(X,infinity) ->
    async_accept(X, -1);
async_accept(X,Timeout) when
      is_integer(Timeout), Timeout >= -1, is_record(X, xylan_socket) ->
    case X#xylan_socket.protocol of
	[tcp|_] ->
	    case prim_inet:async_accept(X#xylan_socket.socket, Timeout) of
		{ok,Ref} ->
		    {ok, Ref};
		Error ->
		    Error
	    end;
	_ ->
	    {error, proto_not_supported}
    end.

async_socket(Listen, Socket)
  when is_record(Listen, xylan_socket), is_port(Socket) ->
    Inherit = [nodelay,keepalive,delay_send,priority,tos],
    case getopts(Listen, Inherit) of
        {ok, Opts} ->  %% transfer listen options
	    %% FIXME: here inet is assumed and currently the only option
	    case inet:setopts(Socket, Opts) of
		ok ->
		    {ok,Mod} = inet_db:lookup_socket(Listen#xylan_socket.socket),
		    inet_db:register_socket(Socket, Mod),
		    X = Listen#xylan_socket { transport=Socket, socket=Socket },
		    accept_upgrade(X, tl(X#xylan_socket.protocol), infinity);
		Error ->
		    prim_inet:close(Socket),
		    Error
	    end;
	Error ->
	    prim_inet:close(Socket),
	    Error
    end.

    
accept(X) when is_record(X, xylan_socket) ->
    accept_upgrade(X, X#xylan_socket.protocol, infinity).

accept(X, Timeout) when 
      is_record(X, xylan_socket), 
      (Timeout =:= infnity orelse (is_integer(Timeout) andalso Timeout >= 0)) ->
    accept_upgrade(X, X#xylan_socket.protocol, Timeout).

accept_upgrade(X=#xylan_socket { mdata = M }, Protos0, Timeout) ->
    lager:debug("accept protos=~w\n", [Protos0]),
    case Protos0 of
	[tcp|Protos1] ->
	    case M:accept(X#xylan_socket.socket, Timeout) of
		{ok,A} ->
		    X1 = X#xylan_socket {transport=A,socket=A},
		    accept_upgrade(X1,Protos1,Timeout);
		Error ->
		    Error
	    end;
	[ssl|Protos1] ->
	    Opts = X#xylan_socket.opts,
	    {SSLOpts0,Opts1} = split_options(ssl_listen_opts(),Opts),
	    {_,SSLOpts} = split_options([ssl_imp], SSLOpts0),
	    lager:debug("SSL upgrade, options = ~w\n", [SSLOpts]),
	    lager:debug("before ssl_accept opt=~w\n", 
		 [getopts(X, [active,packet,mode])]),
	    case ssl_accept(X#xylan_socket.socket, SSLOpts, Timeout) of
		{ok,S1} ->
		    lager:debug("ssl_accept opt=~w\n", 
			 [ssl:getopts(S1, [active,packet,mode])]),
		    X1 = X#xylan_socket{socket=S1,
				      mdata = ssl,
				      mctl  = ssl,
				      opts=Opts1,
				      tags={ssl,ssl_closed,ssl_error}},
		    accept_upgrade(X1, Protos1, Timeout);
		Error={error,_Reason} ->
		    lager:warning("ssl:ssl_accept error=~w\n", 
			 [_Reason]),
		    Error
	    end;
	[probe_ssl|Protos1] ->
	    accept_probe_ssl(X,Protos1,Timeout);
	[http|Protos1] ->
	    {_, Close,Error} = X#xylan_socket.tags,
	    X1 = X#xylan_socket { packet = http, 
				tags = {http, Close, Error }},
	    accept_upgrade(X1,Protos1,Timeout);
	[] ->
	    setopts(X, [{mode,X#xylan_socket.mode},
			{packet,X#xylan_socket.packet},
			{active,X#xylan_socket.active}]),
	    lager:debug("after upgrade opts=~w\n", 
		 [getopts(X, [active,packet,mode])]),
	    {ok,X}
    end.

accept_probe_ssl(X=#xylan_socket { mdata=M, socket=S,
				 tags = {TData,TClose,TError}},
		 Protos,
		 Timeout) ->
    lager:debug("accept_probe_ssl protos=~w\n", [Protos]),
    setopts(X, [{active,once}]),
    receive
	{TData, S, Data} ->
	    lager:debug("Accept data=~w\n", [Data]),
	    case request_type(Data) of
		ssl ->
		    lager:debug("request type: ssl\n",[]),
		    ok = M:unrecv(S, Data),
		    lager:debug("~w:unrecv(~w, ~w)\n", [M,S,Data]),
		    %% insert ssl after transport
		    Protos1 = X#xylan_socket.protocol--([probe_ssl|Protos]),
		    Protos2 = Protos1 ++ [ssl|Protos],
		    accept_upgrade(X#xylan_socket{protocol=Protos2},
				   [ssl|Protos],Timeout);
		_ -> %% not ssl
		    lager:debug("request type: NOT ssl\n",[]),
		    ok = M:unrecv(S, Data),
		    lager:debug("~w:unrecv(~w, ~w)\n", [M,S,Data]),
		    accept_upgrade(X,Protos,Timeout)
	    end;
	{TClose, S} ->
	    lager:debug("closed\n", []),
	    {error, closed};
	{TError, S, Error} ->
	    lager:warning("error ~w\n", [Error]),
	    Error
    end.

ssl_accept(Socket, Options, Timeout) ->    
    case ssl:ssl_accept(Socket, Options, Timeout) of
	{error, ssl_not_started} ->
	    ssl:start(),
	    ssl:ssl_accept(Socket, Options, Timeout);
	Result ->
	    Result
    end.


request_type(<<"GET", _/binary>>) ->    http;
request_type(<<"POST", _/binary>>) ->    http;
request_type(<<"OPTIONS", _/binary>>) ->  http;
request_type(<<"TRACE", _/binary>>) ->    http;
request_type(<<1:1,_Len:15,1:8,_Version:16, _/binary>>) ->
    ssl;
request_type(<<ContentType:8, _Version:16, _Length:16, _/binary>>) ->
    if ContentType == 22 ->  %% HANDSHAKE
	    ssl;
       true ->
	    undefined
    end;
request_type(_) ->
    undefined.
    
%%
%% xylan_socket wrapper for socket operations
%%
close(#xylan_socket { mdata = M, socket = S}) ->
    M:close(S).

shutdown(#xylan_socket { mdata = M, socket = S}, How) ->
    M:shutdown(S, How).
    
send(#xylan_socket { mdata = M,socket = S } = X, Data) ->
    try M:send(S, Data)
    catch
	error:_ ->
	    shutdown(X, write)
    end.

recv(HSocket, Size) ->
    recv(HSocket, Size, infinity).

recv(#xylan_socket { mdata = M, socket = S } = X, Size, Timeout) ->
    try M:recv(S, Size, Timeout)
    catch
	error:E ->
	    shutdown(X, write),
	    erlang:error(E)
    end.

setopts(#xylan_socket { mctl = M, socket = S}, Opts) ->
    M:setopts(S, Opts).

getopts(#xylan_socket { mctl = M, socket = S}, Opts) ->
    M:getopts(S, Opts).

controlling_process(#xylan_socket { mdata = M, socket = S}, NewOwner) ->
    M:controlling_process(S, NewOwner).

sockname(#xylan_socket { mctl = M, socket = S}) ->
    M:sockname(S).

peername(#xylan_socket { mctl = M, socket = S}) ->
    M:peername(S).

stats() ->
    inet:stats().

getstat(#xylan_socket { transport = Socket}, Stats) ->
    inet:getstat(Socket, Stats).

pair() ->
    pair(inet).
pair(Family) ->  %% inet|inet6
    {ok,L} = gen_tcp:listen(0, [{active,false}]),
    {ok,{IP,Port}} = inet:sockname(L),
    {ok,S1} = gen_tcp:connect(IP, Port, [Family,{active,false}]),
    {ok,S2} = gen_tcp:accept(L),
    gen_tcp:close(L),
    X1 = #xylan_socket{socket=S1,
		     mdata = gen_tcp,
		     mctl  = inet,
		     protocol=[tcp],
		     opts=[],
		     tags={tcp,tcp_closed,tcp_error}},
    X2 = #xylan_socket{socket=S2,
		     mdata = gen_tcp,
		     mctl  = inet,
		     protocol=[tcp],
		     opts=[],
		     tags={tcp,tcp_closed,tcp_error}},
    {ok,{X1,X2}}.

tags(#xylan_socket { tags=Tags}) ->
    Tags.

socket(#xylan_socket { socket=Socket }) ->
    Socket.

%% Utils
tcp_listen_options() ->
    [ifaddr, ip, port, fd, inet, inet6,
     tos, priority, reuseaddr, keepalive, linger, sndbuf, recbuf, nodelay,
     header, active, packet, buffer, mode, deliver, backlog,
     exit_on_close, high_watermark, low_watermark, send_timeout,
     send_timeout_close, delay_send, packet_size, raw].

tcp_connect_options() ->
    [ifaddr, ip, port, fd, inet, inet6,
     tos, priority, reuseaddr, keepalive, linger, sndbuf, recbuf, nodelay,
     header, active, packet, packet_size, buffer, mode, deliver,
     exit_on_close, high_watermark, low_watermark, send_timeout,
     send_timeout_close, delay_send,raw].


ssl_listen_opts() ->
    [versions, verify, verify_fun, 
     fail_if_no_peer_cert, verify_client_once,
     depth, cert, certfile, key, keyfile, 
     password, cacerts, cacertfile, dh, dhfile, cihpers,
     %% deprecated soon 
     ssl_imp,   %% always new!
     %% server
     verify_client_once,
     reuse_session, reuse_sessions,
     secure_renegotiate, renegotiate_at,
     debug, hibernate_after, erl_dist ].

ssl_connect_opts() ->
    [versions, verify, verify_fun, 
     fail_if_no_peer_cert,
     depth, cert, certfile, key, keyfile, 
     password, cacerts, cacertfile, dh, dhfile, cihpers,
     debug].


split_options(Keys, Opts) ->
    split_options(Keys, Opts, [], []).

split_options(Keys, [{Key,Value}|KVs], List1, List2) ->
    case lists:member(Key, Keys) of
	true -> split_options(Keys, KVs, [{Key,Value}|List1], List2);
	false -> split_options(Keys, KVs, List1, [{Key,Value}|List2])
    end;
split_options(Keys, [Key|KVs], List1, List2) ->
    case lists:member(Key, Keys) of
	true -> split_options(Keys, KVs, [Key|List1], List2);
	false -> split_options(Keys, KVs, List1, [Key|List2])
    end;
split_options(_Keys, [], List1, List2) ->
    {lists:reverse(List1), lists:reverse(List2)}.
