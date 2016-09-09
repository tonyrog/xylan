%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2014, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    xylan sockets
%%% @end
%%% Created : 17 Jan 2015 by Tony Rogvall <tony@rogvall.se>

-ifndef(_XYLAN_SOCKET_HRL_).
-define(_XYLAN_SOCKET_HRL_, true).

-record(xylan_socket,
	{
	  mdata,        %% data module  (e.g gen_tcp, ssl ...)
	  mctl,         %% control module  (e.g inet, ssl ...)
	  protocol=[],  %% [tcp|ssl|http] 
	  version,      %% Http version in use (1.0/keep-alive or 1.1)
	  transport,    %% ::port()  - transport socket
	  socket,       %% ::port() || Pid/Port/SSL/ etc
	  active=false, %% ::boolean() is active
	  mode=list,    %% :: list|binary 
	  packet=0,     %% packet mode
	  opts = [],    %% extra options
	  tags = {data,close,error}   %% data tags used
	}).

-type xylan_socket() :: #xylan_socket{}.

-endif.
