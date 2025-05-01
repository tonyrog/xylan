%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    "YANG" validation
%%% @end
%%% Created : 20 Feb 2025 by Tony Rogvall <tony@rogvall.se>

-module(xylan_yang).

-export([validate_flags/2]).

%%
%% Library function for option validation:
%% Spec is internal YANG format.
%% return ok | {error, Reason}
%% Reason:
%%   [ {mandatory,Key} |
%%     {unknown,Key} |
%%     {missing_sys_config,{Key,Value}} |
%%     {range,{Key,Range}} |
%%     {badarg,Key} ]
%%
validate_flags(Options, Spec) ->
    case validate_flags_(Options, Spec, []) of
	ok ->
	    validate_spec_(Spec, Options, []);
	{error,Error} ->
	    validate_spec_(Spec, Options, Error)
    end.

validate_spec_([{leaf,Key,As}|Spec],Options,Error) ->
    case lists:keymember(Key,1,Options) of
	false ->
	    case lists:keyfind(mandatory,1,As) of
		false ->
		    validate_spec_(Spec, Options, Error);
		{mandatory,false,_} ->
		    validate_spec_(Spec, Options, Error);
		{mandatory,true,_} ->
		    validate_spec_(Spec, Options, [{mandatory,Key}|Error])
	    end;
	_ ->
	    validate_spec_(Spec, Options, Error)
    end;
validate_spec_([_|Spec],Options, Error) -> %% fixme: check container
    validate_spec_(Spec, Options, Error);
validate_spec_([], _Options, []) ->
    ok;
validate_spec_([], _Options, Error) ->
    {error,Error}.


validate_flags_([Option|Options], Spec, Error) ->
    case validate_flag(Option, Spec) of
	ok -> validate_flags_(Options, Spec, Error);
	{ok,Spec1} -> validate_flags_(Options, Spec++Spec1, Error);
	E -> validate_flags_(Options, Spec, [E|Error])
    end;
validate_flags_([], _Spec, []) ->
    ok;
validate_flags_([], _Spec, Error) ->
    {error, Error}.

validate_flag({Key,Value}, Spec) ->
    io:format("Validate: ~p = ~p (spec = ~1000p)\n", [Key, Value, Spec]),
    case lists:keyfind(Key, 2, Spec) of
	{leaf, Key, Stmts } ->
	    validate_leaf(Key, Value, Stmts);
	{'leaf-list', Key, Stmts } ->
	    validate_leaf(Key, Value, Stmts);
	{container, Key, Stmts} ->
	    validate_flags(Value, Stmts);
	{list, Key, Stmts} ->
	    validate_list(Key, Value, Stmts);
	{choice, Key, Stmts} ->
	    validate_choice(Key, Value, Stmts);
	false ->
	    {unknown,Key}
    end;
validate_flag(_Value, _Spec) ->
    {error,badarg}.


validate_choice(Key, Value, Stmts) ->
    io:format("choice ~p = ~p (~1000p)\n", [Key,Value,Stmts]),
    case Value of
	false -> {error,{Key,badarg}};
	{Case,CaseValue} ->
	    case lists:keyfind(Case,2,Stmts) of
		{'case',_,CaseStmts} ->
		    case lists:keyfind(Case, 2, CaseStmts) of
			false -> {error,{Key,{missing_choice,Case}}};
			{leaf,Case,Stmts1} ->
			    validate_leaf(Case, CaseValue, Stmts1);
			{_,_,Stmts1} ->
			    validate_flags(CaseValue, Stmts1)
		    end;
		false ->
		    {error, {Key,nochice}}
	    end
    end.

validate_leaf(Key, Value, Stmts) ->
    case lists:keyfind(type, 1, Stmts) of
	false ->
	    {missing_type, Key};
	{type, Type, Tas} ->
	    case validate_value(Value, Type, Tas) of
		ok -> ok;
		Error -> {error, {Key,Error}}
	    end
    end.

validate_list(_Key, Value, Stmts) ->
    case lists:keytake(key, 1, Stmts) of
	false ->
	    {error, {missing,key}};
	{value,{key,ListKey,_},Stmts1} ->
	    case lists:keyfind(ListKey, 2, Stmts1) of
		{leaf, ListKey, _} ->
		    validate_flags(Value, Stmts1);
		{container, ListKey, Stmts2} ->
		    lists:foldl(
		      fun({K,V}, Acc) when K =:= ListKey ->
			      case validate_flags(V, Stmts2)of
				  ok -> ok;
				  E -> [E | Acc]
			      end
		      end, [], Value);
		{choice, ListKey, Stmts2} ->
		    lists:foldl(
		      fun(V, Acc) ->
			      case validate_choice(ListKey, V, Stmts2) of
				  ok -> ok;
				  E -> [E | Acc]
			      end
		      end, [], Value);
		_W ->
		    %% io:format("~p\n", [W]),
		    {error, {missing,ListKey}}
	    end
    end.

-define(r(Min,Max), {range,[{(Min),(Max)}],[]}).

validate_value(Value, boolean, Tas) ->
    if is_boolean(Value) -> restrict_value(Value, boolean, Tas);
       is_atom(Value) -> badarg;
       true ->
	    {range,[true,false]}
    end;
validate_value(Value, uint8, Tas) ->
    validate_uint(Value, uint8, [?r(0,16#ff)|Tas]);
validate_value(Value, uint16, Tas) ->
    validate_uint(Value, uint16, [?r(0,16#ffff)|Tas]);
validate_value(Value, uint32, Tas) ->
    validate_uint(Value, uint32, [?r(0,16#ffffffff)|Tas]);
validate_value(Value, uint64, Tas) ->
    validate_uint(Value, uint64, [?r(0,16#ffffffffffffffff)|Tas]);
validate_value(Value, int8, Tas) ->
    validate_int(Value,int8,[?r(-16#80,16#7f)|Tas]);
validate_value(Value, int16, Tas) ->
    validate_int(Value,int16,[?r(-16#8000,16#7fff)|Tas]);
validate_value(Value, int32, Tas) ->
    validate_int(Value,int32,[?r(-16#80000000,16#7fffffff)|Tas]);
validate_value(Value, int64, Tas) ->
    validate_int(Value,int64,
		   [?r(-16#8000000000000000,16#7fffffffffffffff)|Tas]);
validate_value(Value, decimal64, Tas) ->
    if is_float(Value) ->
	    restrict_value(Value, decimal64, Tas);
       %% maybe accept integer encoding here as well?
       true ->
	    badarg
    end;
validate_value(Value, enumeration, Tas) ->
    if is_atom(Value) ->
	    validate_enum(Value, Tas);
       true ->
	    Es = [E || {enum,E,_} <- Tas],
	    {enumeration, Es}
    end;
validate_value(Value, bits, Tas) ->
    if is_atom(Value) -> validate_bit(Value, Tas);
       Value =:= [] -> ok;
       is_list(Value) ->
	    case lists:all(fun(V) -> validate_bit(V, Tas) =:= ok end, Value) of
		true -> ok;
		false -> error_bits(Tas)
	    end;
       true -> error_bits(Tas)
    end;
validate_value(Value, string, Tas) ->
    case is_atom(Value) orelse is_string(Value) of
	true ->  restrict_value(Value, string, Tas);
	false -> badarg
    end;
validate_value(Value, binary, Tas) ->
    case is_iolist(Value) of
	true -> restrict_value(Value, binary, Tas);
	false -> badarg
    end;
validate_value(Value, union, Tas) ->
    case lists:any(fun({type,Type,Tas1}) ->
			   case validate_value(Value, Type, Tas1) of
			       ok -> true;
			       _ -> false
			   end;
		      (_) -> false
		   end, Tas) of
	true -> ok;
	false -> badarg
    end;
validate_value(Value, anyxml, _Tas) ->
    if is_list(Value) ->
	    ok;
       true -> badarg
    end;
validate_value(_Value, 'hex:rfc822', _Tas) ->  %% fixme!
    %% validate email address
    ok;
validate_value(Value, 'yang:ip-address', _Tas) when is_tuple(Value)->
    case inet:ntoa(Value) of
	Address when is_list(Address) -> ok;
	{error, einval} -> badarg
    end;
validate_value(Value, 'yang:ip-address', _Tas) when is_list(Value)->
    case inet_parse:address(Value) of
	{ok, _Address} -> ok;
	{error, einval} -> badarg
    end;
validate_value(Value, 'yang:domain-name',_Tas) -> %% fixme!
    try inet_parse:domain(Value) of
	true -> ok;
	false -> badarg
    catch
	error:_ -> badarg
    end;
validate_value(Value, 'yang:port-number',_Tas) -> %% fixme!
    if is_integer(Value), Value >= 0, Value =< 65535 -> ok;
       true -> badarg
    end.

validate_uint(Value, Type, Tas) ->
    if is_integer(Value), Value >= 0 -> restrict_value(Value, Type, Tas);
       true -> badarg
    end.

validate_int(Value, Type, Tas) ->
    if is_integer(Value) -> restrict_value(Value, Type, Tas);
       true -> badarg
    end.

restrict_value(Value, Type,[{range,Range,_}|Opts]) ->
    case lists:any(fun({min,max}) -> true;
		      ({min,Max}) -> Value =< Max;
		      ({Min,max}) -> Value >= Min;
		      ({Min,Max}) -> (Value >= Min) andalso (Value =< Max);
		      (V) -> Value =:= V
		   end, Range) of
	true ->
	    restrict_value(Value, Type,Opts);
	false ->
	    {range,Range}
    end;
restrict_value(Value, Type, [{length,Range,_}|Opts]) ->
    Len = if Type =:= string -> length(Value);
	     Type =:= binary -> erlang:iolist_size(Value)
	  end,
    case lists:any(fun({min,max}) -> true;
		      ({min,Max}) -> Len =< Max;
		      ({Min,max}) -> Len >= Min;
		      ({Min,Max}) -> (Len >= Min) andalso (Len =< Max);
		      (L) -> Len =:= L
		   end, Range) of
	true ->
	    restrict_value(Value, Type, Opts);
	false ->
	    {length,Range}
    end;
restrict_value(Value, Type, [{pattern,RegExp,_}|Opts]) ->
    case xsdre:match(Value, RegExp) of
	true ->
	    restrict_value(Type, Value, Opts);
	false ->
	    {pattern, RegExp}
    end;
restrict_value(Value, Type, [{'fraction-digits',N,_}|Opts]) ->
    case is_float(Value) of
	true ->
	    restrict_value(Type, Value, Opts);
	false ->
	    {decimal64,N}
    end;
restrict_value( _Value, _Type, []) ->
    ok.

validate_enum(Value, [{enum,Name,_As}|List]) ->
    if Value =:= Name -> ok;
       true -> validate_enum(Value, List)
    end;
validate_enum(Value, [_|List]) ->
    validate_enum(Value, List);
validate_enum(_Value, []) ->
    badarg.

validate_bit(Value, [{bit,Name,_As}|List]) ->
    if Value =:= Name -> ok;
       true -> validate_bit(Value, List)
    end;
validate_bit(Value, [_|List]) ->
    validate_bit(Value, List);
validate_bit(_Value, []) ->
    badarg.

error_bits(Tas) ->
    {bits, [E || {bit,E,_} <- Tas]}.

is_string(Value) ->
    try unicode:characters_to_binary(Value) of
	Utf8 when is_binary(Utf8) -> true;
	{error,_,_} -> false
    catch
	error:_ -> false
    end.

is_iolist(Value) ->
    try (erlang:iolist_size(Value) >= 0) of
	Bool -> Bool
    catch
	error:_ -> false
    end.
