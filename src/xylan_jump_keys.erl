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
%%% @doc
%%%    Key callback for the ssh jump server: host keys from system_dir,
%%%    user keys per user from the xylan config (not a shared
%%%    authorized_keys file).
%%% @end
%%%-------------------------------------------------------------------
-module(xylan_jump_keys).

-behaviour(ssh_server_key_api).

-export([host_key/2, is_auth_key/3]).

host_key(Algorithm, Options) ->
    ssh_file:host_key(Algorithm, Options).

is_auth_key(PublicKey, User, Options) ->
    Private = proplists:get_value(key_cb_private, Options, []),
    Users = proplists:get_value(users, Private, #{}),
    case maps:find(User, Users) of
	{ok, #{ keys := Keys }} -> lists:member(PublicKey, Keys);
	error -> false
    end.
