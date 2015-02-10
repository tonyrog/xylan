%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2015, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @author Malotte Westma Lonne <malotte@malotte.net>
%%% @copyright (C) 2014, Tony Rogvall
%%% @doc
%%%    Proxy wedding ssh with host menu.
%%%
%%% Created : Jan 2015 by Malotte W Lonne
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_ssh_menu).
-behaviour(ssh_daemon_channel).

-include_lib("lager/include/log.hrl").
-include_lib("ssh/include/ssh.hrl").

%% ssh_channel callbacks
-export([init/1, 
	 handle_ssh_msg/2, 
	 handle_msg/2, 
	 terminate/2]).

%% loopdata
-record(loopdata, {
	  clients,
	  host,
	  up,             %% Keep track of sides up
	  us_channel,     %% User side
	  us_conref,      %% User side
	  cs_channel,     %% Client side
	  cs_conref,      %% Cient side
	  pty,
	  buf = []
	 }).


%%====================================================================
%% ssh_channel callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, LD} 
%%                        
%% Description: Initiates the CLI
%%--------------------------------------------------------------------
init([]) ->
    %% User side is up
    {ok, #loopdata{up = 1}}.

%%--------------------------------------------------------------------
%% Function: handle_ssh_msg(Args) -> {ok, LD} | {stop, Channel, LD}
%%                        
%% Description: Handles channel messages received on the ssh-connection.
%%--------------------------------------------------------------------
handle_ssh_msg({ssh_cm, ConRef, 
		{pty, Channel, WantReply, 
		 {TermName, Width, Height, PixWidth, PixHeight, Opts}}} = _Msg, 
	       #loopdata{host = undefined} = LD0) ->
    ?debug("handle_ssh_msg: ~p", [_Msg]),
    LD = LD0#loopdata{pty = #ssh_pty{term = TermName,
				     width =  Width,
				     height = Height,
				     pixel_width = PixWidth,
				     pixel_height = PixHeight,
				     modes = Opts}},
    ssh_connection:reply_request(ConRef, WantReply, success, Channel),
    {ok, LD};

handle_ssh_msg({ssh_cm, ConRef, 
		{pty, Channel, WantReply, 
		 {TermName, Width, Height, PixWidth, PixHeight, Opts}}} = _Msg, 
	       LD0) ->
    ?debug("handle_ssh_msg: ~p", [_Msg]),
    LD = LD0#loopdata{pty = #ssh_pty{term = TermName,
				     width =  Width,
				     height = Height,
				     pixel_width = PixWidth,
				     pixel_height = PixHeight,
				     modes = Opts}},
    ssh_connection:reply_request(ConRef, WantReply, success, Channel),
    %% Send on to client side ??
    {ok, LD};

handle_ssh_msg({ssh_cm, ConRef, 
		{env, Channel, WantReply, _Var, _Value}} = _Msg, 
	       LD) ->
    ?debug("handle_ssh_msg: ~p", [_Msg]),
    ssh_connection:reply_request(ConRef, WantReply, failure, Channel),
    {ok, LD};

handle_ssh_msg({ssh_cm, ConRef, {shell, Channel, WantReply}} = _Msg, LD) ->
    ?debug("handle_ssh_msg: ~p", [_Msg]),
    Clients = menu(Channel, ConRef),
    ssh_connection:reply_request(ConRef, WantReply, success, Channel),
    {ok, LD#loopdata{us_channel = Channel,
		     us_conref = ConRef,
		     clients = Clients}};

handle_ssh_msg({ssh_cm, USConRef, {data, USChannel, _Type, Data}} = _Msg, 
	       #loopdata{host = undefined, buf = Buf, clients = Clients} = LD) ->
    %% Before a client side has been set up data is used to
    %% get a host name.
    ?debug("handle_ssh_msg: ~p", [_Msg]),
    List = binary_to_list(Data),
    ?debug("handle_ssh_msg: data ~p", [List]),
    case detect_host(lists:append(Buf, List), 
		     Clients, USChannel, USConRef) of 
	{exit, _} ->
	    {stop, USChannel, LD};
	{undefined, NewBuf} ->
	    {ok, LD#loopdata{buf = NewBuf}};
	{Host, NewBuf} ->
	    {CSConRef, CSChannel} = connect(Host, LD),
	    {ok, LD#loopdata{buf = NewBuf, 
			     host = Host, 
			     cs_conref = CSConRef, 
			     cs_channel = CSChannel,
			     up = 2}}
    end;

handle_ssh_msg({ssh_cm, USConRef, {data, USChannel, _Type, Data}}, 
	       #loopdata{buf = "",  %% No old data
			 us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel} = LD) ->
    ?debug("handle_ssh_msg: data from user side ~p", [Data]),
    %% Send on to client side
    send(Data, CSChannel, CSConRef),
    {ok, LD};

handle_ssh_msg({ssh_cm, USConRef, {data, USChannel, _Type, Data}}, 
	       #loopdata{buf = Buf, 
			 us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel} = LD) ->
    ?debug("handle_ssh_msg: data from user side ~p", [Data]),
    %% Old data first
    send(Buf, CSChannel, CSConRef),
    %% Send on to client side
    send(Data, CSChannel, CSConRef),
    {ok, LD#loopdata{buf = []}};

handle_ssh_msg({ssh_cm, CSConRef, {data, CSChannel, _Type, Data}}, 
	       #loopdata{us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel} = LD) ->
    ?debug("handle_ssh_msg: data from client side ~p", [Data]),
    %% Send on to user side
    send(Data, USChannel, USConRef),
    {ok, LD};

handle_ssh_msg({ssh_cm, USConRef, 
		{window_change, 
		 USChannel, Width, Height, PixWidth, PixHeight}} = _Msg, 
	       #loopdata{us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel} = LD0) ->
    ?debug("handle_ssh_msg: window_change from user side ~p", [_Msg]),
    %% Send on to client side ??
    LD = LD0#loopdata{pty = #ssh_pty{width =  Width,
				     height = Height,
				     pixel_width = PixWidth,
				     pixel_height = PixHeight}},
    {ok, LD};

handle_ssh_msg({ssh_cm, _ConRef, {eof, _Channel}}, LD) ->
    ?debug("handle_ssh_msg: eof", []),
    {ok, LD};

handle_ssh_msg({ssh_cm, _ConRef, {closed, Channel}}, 
	       #loopdata{us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel,
			 up = 1} = LD) ->
    ?debug("handle_ssh_msg: last side closed", []),
    ssh_connection:close(USConRef, USChannel),
    ssh_connection:close(CSConRef, CSChannel),
    %%ssh:close(USConRef),
    ssh:close(CSConRef),
    {stop, Channel, LD};

handle_ssh_msg({ssh_cm, CSConRef, {closed, CSChannel}},
	       #loopdata{us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel,
			 clients = Clients} = LD) ->
    ?debug("handle_ssh_msg: client side closed", []),
    %%ssh_connection:send_eof(USConRef, USChannel),
    ?debug("pid: ~p", [self()]),
    ssh_connection:close(USConRef, USChannel),
    %%list_clients(Clients, USChannel, USConRef),
    {ok, LD#loopdata {up = 1, host = undefined}};

handle_ssh_msg({ssh_cm, USConRef, {closed, USChannel}},
	       #loopdata{us_conref = USConRef, us_channel = USChannel,
			 cs_conref = CSConRef, cs_channel = CSChannel} = LD) ->
    ?debug("handle_ssh_msg: user side closed", []),
    %%ssh_connection:send_eof(CSConRef, CSChannel),
    ssh_connection:close(CSConRef, CSChannel),
    {ok, LD#loopdata {up = 1}};

handle_ssh_msg({ssh_cm, _, {signal, _, _}}, LD) ->
    %% Ignore signals according to RFC 4254 section 6.9.
    ?debug("handle_ssh_msg: signal", []),
    {ok, LD};

handle_ssh_msg({ssh_cm, _, {exit_signal, Channel, _, Error, _}}, LD) ->
    Report = io_lib:format("Connection closed by peer ~n Error ~p~n",
			   [Error]),
    error_logger:error_report(Report),
    {stop, Channel,  LD};

handle_ssh_msg({ssh_cm, _, {exit_status, Channel, 0}}, LD) ->
    ?debug("handle_ssh_msg: exit_status 0", []),
    {stop, Channel, LD};

handle_ssh_msg({ssh_cm, _, {exit_status, Channel, Status}}, LD) ->
    
    Report = io_lib:format("Connection closed by peer ~n Status ~p~n",
			   [Status]),
    error_logger:error_report(Report),
    {stop, Channel, LD};

handle_ssh_msg(_Msg, LD) ->
    ?debug("handle_ssh_msg: unknown msg ~p", [_Msg]),
    {ok, LD}.

%%--------------------------------------------------------------------
%% Function: handle_msg(Args) -> {ok, LD} | {stop, Channel, LD}
%%                        
%% Description: Handles other channel messages.
%%--------------------------------------------------------------------
handle_msg({ssh_channel_up, _Channel, _ConRef} = _Msg, LD) ->
    ?debug("handle_msg: ~p", [_Msg]),
    handle_channel_up(),
    {ok, LD};

handle_msg(xylan_dummy_up = _Msg, LD) ->
    ?debug("handle_msg: ~p", [_Msg]),
    {ok, LD};

handle_msg(_Msg, LD) ->
    ?debug("handle_msg: unknown msg ~p", [_Msg]),
    {ok, LD}.


%%--------------------------------------------------------------------
%% Function: terminate(Reason, LD) -> void()
%% Description: Called when the channel process is trminated
%%--------------------------------------------------------------------
terminate(_Reason, _LD) ->
   ?debug("terminate: ~p", [_Reason]),
    ok.



%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
menu(Channel, ConRef) ->
    %% Read clients from config
    application:load(xylan), %% Remove later ??
    case application:get_env(xylan, clients) of
	{ok, ClientConfig} when is_list(ClientConfig) -> 
	    Clients = [Name || {Name, _Config} <- ClientConfig],
	    NumClients = lists:zip(lists:seq(length(Clients), 1, -1), Clients),
	    list_clients(NumClients, Channel, ConRef),
	    NumClients;
	_ ->
	    ?debug("menu: no clients found,", []),
	    []
    end.
	

list_clients(Clients, Channel, ConRef) ->
    ?debug("list_clients: ~p,", [Clients]),
    Msg = [lists:foldl(
	     fun({Num, Client}, Acc) ->
		     [io_lib:format("~p - ~s\r\n", [Num, Client]) | Acc]
	     end, [], Clients) | 
	   io_lib:format("0 - exit\r\nSelect client>\r\n",[])],
    ssh_connection:send(ConRef, Channel, 0, Msg).
   
complete_row(Buf) ->
    ?debug("complete row: buffer ~s,", [Buf]),
    case string:chr(Buf,$\r) of
	0 -> 
	    {undefined, Buf};
	Pos ->
	    case lists:split(Pos - 1, Buf) of
		{Host, [$\r]} ->
		    ?debug("complete row: host ~s.", [Host]),
		    {Host, []};
		{Host, [$\r, Rest]} ->
		    ?debug("complete row: host ~s.", [Host]),
		    {Host, Rest}
	    end
    end.
	
detect_host(Buf, Clients, Channel, ConRef) ->
    case complete_row(Buf) of
	{undefined, _NewBuf} = Reply ->
	    Reply;
	{"exit", _NewBuf} ->
	    {exit, []};
	{Row, NewBuf} ->
	    try list_to_integer(Row) of
		0 ->
		    {exit, []};
		Num ->
		    %% User entered a n umber
		    case lists:keyfind(Num, 1, Clients) of
			{Num, Host} -> 
			    {Host, NewBuf};
			false -> 
			    list_clients(Clients, Channel, ConRef),
			    {undefined, NewBuf}
		    end
	    catch 
		error:_Reason ->
		    %% User entered a name
		    case lists:keyfind(Row, 2, Clients) of
			{_Num, Host} -> 
			    {Host, NewBuf};
			false -> 
			    list_clients(Clients, Channel, ConRef),
			    {undefined, NewBuf}
		    end
	    end
    end.

connect(Host, 
	#loopdata{us_conref = USConRef, us_channel = USChannel, pty = Pty}) ->
    ssh_connection:send(USConRef, USChannel, 0, 
			io_lib:format("~s choosen\r\n",[Host])),
    {ok, CSConRef} = ssh:connect(Host, 8383, 
				 [{silently_accept_hosts, true},
				  {user, "malotte"},
				  {password, "hej"}]),
    {ok, CSChannel} = 
	ssh_connection:session_channel(CSConRef, infinity),

    ok = ssh_connection:shell(CSConRef, CSChannel),
    success = ssh_connection:ptty_alloc(CSConRef, CSChannel, 
					[{term, Pty#ssh_pty.term},
					 {width, Pty#ssh_pty.width},
					 {height, Pty#ssh_pty.height},
					 {pixel_width, Pty#ssh_pty.pixel_width},
					 {pixel_height, Pty#ssh_pty.pixel_height},
					 {pty_opts, Pty#ssh_pty.modes}], 
					infinity),
    {CSConRef, CSChannel}.


send(Buf, Channel, ConRef) when is_binary(Buf)->	  
    ssh_connection:send(ConRef, Channel, 0, Buf);
send(Buf, Channel, ConRef) ->	  
    ssh_connection:send(ConRef, Channel, 0, list_to_binary(Buf)).


%% We replace the channels connection manager to avoid
%% it absorbing closed messages
handle_channel_up() ->
    {ok, _Pid} = xylan_dummy_cm:start_link(self()).

		  
