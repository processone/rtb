%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2002-2018 ProcessOne, SARL. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%%-------------------------------------------------------------------
-module(rtb_config).
-compile([{parse_transform, lager_transform}]).
-behaviour(gen_server).

%% API
-export([start_link/0, get_option/1]).
-export([options/0, prep_option/2]).
-export([to_bool/1]).
-export([fail_opt_val/2, fail_bad_val/2, fail_unknown_opt/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_option(Opt) ->
    ets:lookup_element(?MODULE, Opt, 2).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    ets:new(?MODULE, [named_table, public, {read_concurrency, true}]),
    case load_config() of
	ok ->
	    case check_limits() of
		ok ->
		    {ok, #state{}};
		{error, _Reason} ->
		    rtb:halt()
	    end;
	{error, _Reason} ->
            rtb:halt()
    end.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
load_config() ->
    case get_config_path() of
	{ok, Path} ->
	    lager:info("Loading configuration from ~s", [Path]),
	    case parse_yaml(Path) of
		{ok, Terms} ->
		    Cfg = parse_dict(Terms),
		    do_load_config(Cfg);
		{error, Reason} ->
		    lager:error("Failed to read configuration from ~s: ~s",
				[Path, fast_yaml:format_error(Reason)]),
		    {error, Reason}
	    end;
	{error, _} = Err ->
	    Err
    end.

do_load_config(Terms) ->
    case lists:keyfind(scenario, 1, Terms) of
	{_, Scenario} ->
	    try prep_option(scenario, Scenario) of
		{module, Module} ->
		    case Module:load() of
			ok ->
			    Defined = get_defined(Module),
			    NewTerms = merge_defaults(Terms, Defined, []),
			    load_terms(NewTerms);
			Err ->
			    lager:error("Failed to load scenario due to "
					"internal error: ~p", [Err]),
			    {error, load_failed}
		    end
	    catch _:_ ->
		    fail_opt_val(scenario, Scenario)
	    end;
	false ->
	    rtb:halt("Missing required option: scenario", [])
    end.

-spec parse_yaml(file:filename()) -> {ok, term()} | {error, fast_yaml:yaml_error()}.
parse_yaml(Path) ->
    case fast_yaml:decode_from_file(Path) of
	{ok, [Document|_]} ->
	    {ok, Document};
	Other ->
	    Other
    end.

parse_dict(Terms) ->
    lists:map(
      fun({Opt, Val}) ->
	      try {binary_to_atom(Opt, latin1), Val}
	      catch _:badarg ->
		      rtb:halt(
			"Invalid configuration option: ~s",
			[format_val(Opt)])
	      end
      end, Terms).

load_terms(Terms) ->
    lists:foreach(
      fun({Opt, Val, Mod}) ->
	      lager:debug("Processing option ~s: ~p", [Opt, Val]),
	      try Mod:prep_option(Opt, Val) of
		  {NewOpt, NewVal} ->
		      ets:insert(?MODULE, {NewOpt, NewVal})
	      catch _:_ ->
		      fail_opt_val(Opt, Val)
	      end
      end, Terms).

merge_defaults([{Opt, Val}|Defined], Predefined, Acc) ->
    case lists:keyfind(Opt, 1, Predefined) of
	false ->
	    rtb:halt("Unknown option: ~s", [Opt]);
	T ->
	    case lists:member(Opt, Acc) of
		true ->
		    rtb:halt("Multiple definitions of option: ~s", [Opt]);
		false ->
		    Mod = lists:last(tuple_to_list(T)),
		    Predefined1 = lists:keyreplace(
				    Opt, 1, Predefined, {Opt, Val, Mod}),
		    merge_defaults(Defined, Predefined1, [Opt|Acc])
	    end
    end;
merge_defaults([], Result, _) ->
    case lists:partition(fun(T) -> tuple_size(T) == 2 end, Result) of
	{[_|_] = Required, _} ->
	    rtb:halt("Missing required option(s): ~s",
		     [rtb:format_list([O || {O, _} <- Required])]);
	{[], _} ->
	    Result
    end.

get_defined(Mod) ->
    Globals = options(),
    Locals = Mod:options(),
    {NewLocals, NewGlobals} =
	lists:foldl(
	  fun(Opt, {L, G}) when is_atom(Opt) ->
		  case lists:keytake(Opt, 1, G) of
		      {value, _, G1} -> {L -- [Opt], [Opt|G1]};
		      false -> {L, G}
		  end;
	     (_, Acc) ->
		  Acc
	  end, {Locals, Globals}, Locals),
    lists:keysort(1, lists:map(
		       fun({Opt, Val}) -> {Opt, Val, ?MODULE};
			  (Opt) -> {Opt, ?MODULE}
		       end, NewGlobals)) ++
    lists:keysort(1, lists:map(
		       fun({Opt, Val}) -> {Opt, Val, Mod};
			  (Opt) -> {Opt, Mod}
		       end, NewLocals)).

get_config_path() ->
    case application:get_env(rtb, config) of
	{ok, Path} ->
	    try {ok, iolist_to_binary(Path)}
	    catch _:_ ->
		    lager:error("Invalid value of "
				"application option 'config': ~p",
				[Path]),
		    {error, einval}
	    end;
	undefined ->
	    lager:error("Application option 'config' is not set", []),
	    {error, enoent}
    end.

-spec ulimit_open_files() -> non_neg_integer() | unlimited | unknown.
ulimit_open_files() ->
    Output = os:cmd("ulimit -n"),
    case string:to_integer(Output) of
	{error, _} ->
	    case Output of
		"unlimited" ++ _ ->
		    unlimited;
		_ ->
		    unknown
	    end;
	{N, _} when is_integer(N) ->
	    N
    end.

-spec sysctl(string()) -> non_neg_integer() | unknown.
sysctl(Val) ->
    Output = os:cmd("/sbin/sysctl -n " ++ Val),
    case string:to_integer(Output) of
	{error, _} ->
	    unknown;
	{N, _} when is_integer(N) ->
	    N
    end.

check_files_limit(Capacity) ->
    ULimitFiles = ulimit_open_files(),
    SysFileMax = sysctl("fs.file-max"),
    SysNrOpen = sysctl("fs.nr_open"),
    lager:info("Maximum available files from ulimit: ~p", [ULimitFiles]),
    lager:info("Maximum available files from fs.file-max: ~p", [SysFileMax]),
    lager:info("Maximum available files from fs.nr_open: ~p", [SysNrOpen]),
    Limit = lists:min([ULimitFiles, SysFileMax, SysNrOpen]),
    if Capacity > Limit ->
	    lager:critical("Available file descriptors are not enough "
			   "to run ~B connections", [Capacity]),
	    {error, system_limit};
       true ->
	    ok
    end.

check_process_limit(Capacity) ->
    Limit = erlang:system_info(process_limit),
    lager:info("Maximum available Erlang processes: ~p", [Limit]),
    if Capacity > Limit ->
	    lager:critical("Available processes limit is not enough "
			   "to run ~B connections: you should increase value of "
			  "+P emulator flag, see erl(1) manpage for details",
			   [Capacity]),
	    {error, system_limit};
       true ->
	    ok
    end.

check_port_limit(Capacity) ->
    Limit = erlang:system_info(port_limit),
    lager:info("Maximum available Erlang ports: ~p", [Limit]),
    if Capacity > Limit ->
	    lager:critical("Available ports limit is not enough "
			   "to run ~B connections: you should increase value of "
			   "+Q emulator flag, see erl(1) manpage for details",
			   [Capacity]),
	    {error, system_limit};
       true ->
	    ok
    end.

check_limits() ->
    Capacity = get_option(capacity),
    try
	ok = check_files_limit(Capacity),
	ok = check_process_limit(Capacity),
	ok = check_port_limit(Capacity)
    catch _:{badmatch, {error, _} = Err} ->
	    Err
    end.

-spec to_bool(integer() | binary() | boolean()) -> boolean().
to_bool(1) -> true;
to_bool(0) -> false;
to_bool(false) -> false;
to_bool(true) -> true;
to_bool(S) when is_binary(S) ->
    case string:to_lower(binary_to_list(S)) of
	"true" -> true;
	"false" -> false
    end.

format_val(I) when is_integer(I) ->
    integer_to_list(I);
format_val(S) when is_binary(S) ->
    S;	    
format_val(YAML) ->
    try [io_lib:nl(), fast_yaml:encode(YAML)]
    catch _:_ -> io_lib:format("~p", [YAML])
    end.

fail_opt_val(Opt, Val) ->
    rtb:halt("Option '~s' has invalid value: ~s",
	     [Opt, format_val(Val)]).

fail_bad_val(What, Val) ->
    rtb:halt("Invalid ~s: ~s", [What, format_val(Val)]).

fail_unknown_opt(Opt) ->
    rtb:halt("Unknown option: ~s", [Opt]).

prep_servers([Server|Servers]) ->
    case http_uri:parse(Server) of
	{ok, {Type, _, HostBin, Port, _, _}}
	  when Port > 0 andalso Port < 65536
	       andalso (Type == tls orelse Type == tcp) ->
	    Host = binary_to_list(HostBin),
	    Addr = case inet:parse_address(Host) of
		       {ok, IP} -> IP;
		       {error, _} -> Host
		   end,
	    case Type of
		tls ->
		    case get_option(certfile) of
			undefined ->
			    rtb:halt("Option 'certfile' is not set "
				     "but it is assumed by URI ~s",
				     [Server]);
			_ ->
			    ok
		    end;
		_ ->
		    ok
	    end,
	    [{Addr, Port, Type == tls}|prep_servers(Servers)]
    end;
prep_servers([]) ->
    [].

prep_addresses([IP|IPs], Avail) ->
    case inet:parse_address(binary_to_list(IP)) of
	{ok, Addr} ->
	    case lists:member(Addr, Avail) of
		true ->
		    [Addr|prep_addresses(IPs, Avail)];
		false ->
		    lager:warning("Interface address ~s is not available",
				  [IP]),
		    prep_addresses(IPs, Avail)
	    end;
	{error, _} ->
	    rtb:halt("Not a valid IP address: ~s", [format_val(IP)])
    end;
prep_addresses([], _) ->
    [].

getifaddrs() ->
    case inet:getifaddrs() of
	{ok, IFList} ->
	    lists:flatmap(
	      fun({_, Opts}) ->
		      [Addr || {addr, Addr} <- Opts]
	      end, IFList);
	{error, Reason} ->
	    rtb:halt("Failed to get interface addresses: ~s",
		       [inet:format_error(Reason)])
    end.

scenario_to_module(M) when is_atom(M) ->
    list_to_atom("mod_" ++ atom_to_list(M));
scenario_to_module(M) ->
    erlang:binary_to_atom(<<"mod_", M/binary>>, latin1).

prep_option(scenario, Scenario) ->
    Module = scenario_to_module(Scenario),
    case code:ensure_loaded(Module) of
	{module, _} ->
	    {module, Module};
	{error, _} ->
	    rtb:halt("Unknown scenario: ~s; check if ~s exists",
		       [Scenario, filename:join(code:lib_dir(rtb),
						Module) ++ ".beam"])
    end;
prep_option(interval, 0) ->
    lager:warning("The benchmark is in the avalanche mode"),
    {interval, 0};
prep_option(interval, I) when is_integer(I), I>0 ->
    lager:info("Arrival rate is ~.1f conn/sec", [1000/I]),
    {interval, I};
prep_option(capacity, C) when is_integer(C), C>0 ->
    lager:info("Capacity is ~B sessions", [C]),
    {capacity, C};
prep_option(servers, List) ->
    {servers, prep_servers(List)};
prep_option(bind, List) ->
    AvailAddrs = getifaddrs(),
    {bind, prep_addresses(List, AvailAddrs)};
prep_option(stats_dir, Path) ->
    Dir = binary_to_list(Path),
    case filelib:ensure_dir(filename:join(Dir, "foo")) of
        ok ->
            {stats_dir, Dir};
        {error, Why} ->
	    lager:error("Failed to create directory ~s: ~s",
			[Dir, file:format_error(Why)]),
	    erlang:error(badarg)
    end;
prep_option(oom_killer, B) ->
    {oom_killer, to_bool(B)};
prep_option(oom_watermark, I) when is_integer(I), I>0, I<100 ->
    {oom_watermark, I};
prep_option(www_dir, Dir) ->
    Path = binary_to_list(Dir),
    case filelib:ensure_dir(filename:join(Path, "foo")) of
	ok ->
	    {www_dir, Path};
	{error, Why} ->
	    lager:error("Failed to create directory ~s: ~s",
			[Path, file:format_error(Why)]),
	    erlang:error(badarg)
    end;
prep_option(www_port, P) when is_integer(P), P>0, P<65536 ->
    {www_port, P};
prep_option(www_domain, <<_, _/binary>> = D) ->
    {www_domain, binary_to_list(D)};
prep_option(www_refresh, I) when is_integer(I), I>=0 ->
    {www_refresh, I};
prep_option(gnuplot, undefined) ->
    Exec = case os:find_executable("gnuplot") of
               false -> "gnuplot";
               Path -> Path
           end,
    prep_option(gnuplot, iolist_to_binary(Exec));
prep_option(gnuplot, Exec) ->
    Path = binary_to_list(Exec),
    case string:strip(os:cmd(Path ++ " --version"), right, $\n) of
	"gnuplot " ++ Version ->
	    lager:info("Found ~s ~s", [Path, Version]),
	    {gnuplot, Path};
	_ ->
            lager:critical("Gnuplot was not found", []),
            erlang:error(badarg)
    end;
prep_option(certfile, undefined) ->
    {certfile, undefined};
prep_option(certfile, CertFile) ->
    Path = binary_to_list(CertFile),
    case file:open(Path, [read]) of
	{ok, Fd} ->
	    file:close(Fd),
	    {certfile, Path};
	{error, Reason} ->
	    lager:critical("Failed to read ~s: ~s",
			   [Path, file:format_error(Reason)]),
	    erlang:error(badarg)
    end;
prep_option(debug, Debug) ->
    case to_bool(Debug) of
        false ->
            {debug, false};
        true ->
            rtb:set_debug(),
            {debug, true}
    end.

options() ->
    [{bind, []},
     {servers, []},
     {certfile, undefined},
     {stats_dir, <<"stats">>},
     {oom_killer, true},
     {oom_watermark, 80},
     {www_dir, <<"www">>},
     {www_port, 8080},
     {www_domain, <<"localhost">>},
     {www_refresh, 1},
     {gnuplot, undefined},
     {debug, false},
     %% Required options
     scenario,
     interval,
     capacity].
