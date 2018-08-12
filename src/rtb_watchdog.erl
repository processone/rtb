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
-module(rtb_watchdog).
-behaviour(gen_event).

-author('alexey@process-one.net').
-author('ekhramtsov@process-one.net').

%% API
-export([start/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
	 handle_info/2, terminate/2, code_change/3]).

%% We don't use ejabberd logger because lager can be overloaded
%% too and alarm_handler may get stuck.
%%-include("logger.hrl").

-define(CHECK_INTERVAL, timer:seconds(30)).

-record(state, {tref :: reference(),
		mref :: reference()}).
-record(proc_stat, {qlen :: non_neg_integer(),
		    memory :: non_neg_integer(),
		    initial_call :: mfa(),
		    current_function :: mfa(),
		    ancestors :: [pid() | atom()],
		    application :: pid() | atom(),
		    name :: pid() | atom()}).
-type state() :: #state{}.
-type proc_stat() :: #proc_stat{}.

%%%===================================================================
%%% API
%%%===================================================================
-spec start() -> ok.
start() ->
    application:load(sasl),
    application:set_env(sasl, sasl_error_logger, false),
    application:start(sasl),
    gen_event:add_handler(alarm_handler, ?MODULE, []),
    gen_event:swap_handler(alarm_handler, {alarm_handler, swap}, {?MODULE, []}),
    application:load(os_mon),
    application:set_env(os_mon, start_cpu_sup, false),
    application:set_env(os_mon, start_os_sup, false),
    application:set_env(os_mon, start_memsup, true),
    application:set_env(os_mon, start_disksup, false),    
    case application:ensure_all_started(os_mon) of
	{ok, _} = OK ->
	    set_oom_watermark(),
	    OK;
	Err ->
	    Err
    end.

excluded_apps() ->
    [os_mon, mnesia, sasl, stdlib, kernel].

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([]) ->
    {ok, #state{}}.

handle_event({set_alarm, {system_memory_high_watermark, _}}, State) ->
    handle_overload(State),
    {ok, restart_timer(State)};
handle_event({clear_alarm, system_memory_high_watermark}, State) ->
    cancel_timer(State#state.tref),
    {ok, State#state{tref = undefined}};
handle_event({set_alarm, {process_memory_high_watermark, Pid}}, State) ->
    case proc_stat(Pid, get_app_pids()) of
	#proc_stat{name = Name} = ProcStat ->
	    error_logger:warning_msg(
	      "Process ~p consumes more than 5% of OS memory (~s)",
	      [Name, format_proc(ProcStat)]),
	    handle_overload(State),
	    {ok, State};
	_ ->
	    {ok, State}
    end;
handle_event({clear_alarm, process_memory_high_watermark}, State) ->
    {ok, State};
handle_event(Event, State) ->
    error_logger:warning_msg("unexpected event: ~p", [Event]),
    {ok, State}.

handle_call(_Request, State) ->
    {ok, {error, badarg}, State}.

handle_info({timeout, _TRef, handle_overload}, State) ->
    handle_overload(State),
    {ok, restart_timer(State)};
handle_info(Info, State) ->
    error_logger:warning_msg("unexpected info: ~p", [Info]),
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec handle_overload(state()) -> ok.
handle_overload(State) ->
    handle_overload(State, processes()).

-spec handle_overload(state(), [pid()]) -> ok.
handle_overload(_State, Procs) ->
    AppPids = get_app_pids(),
    {TotalMsgs, ProcsNum, Apps, Stats} = overloaded_procs(AppPids, Procs),
    if TotalMsgs >= 10000 ->
	    SortedStats = lists:reverse(lists:keysort(#proc_stat.qlen, Stats)),
	    error_logger:warning_msg(
	      "The system is overloaded with ~b messages "
	      "queued by ~b process(es) (~b%) "
	      "from the following applications: ~s; "
	      "the top processes are:~n~s",
	      [TotalMsgs, ProcsNum,
	       round(ProcsNum*100/length(Procs)),
	       format_apps(Apps),
	       format_top_procs(SortedStats)]),
	    kill(SortedStats, round(TotalMsgs/ProcsNum));
       true ->
	    ok
    end,
    lists:foreach(fun erlang:garbage_collect/1, Procs).

-spec get_app_pids() -> map().
get_app_pids() ->
    try application:info() of
	Info ->
	    case lists:keyfind(running, 1, Info) of
		{_, Apps} ->
		    lists:foldl(
		      fun({Name, Pid}, M) when is_pid(Pid) ->
			      maps:put(Pid, Name, M);
			 (_, M) ->
			      M
		      end, #{}, Apps);
		false ->
		    #{}
	    end
    catch _:_ ->
	    #{}
    end.

-spec overloaded_procs(map(), [pid()])
      -> {non_neg_integer(), non_neg_integer(), dict:dict(), [proc_stat()]}.
overloaded_procs(AppPids, AllProcs) ->
    lists:foldl(
      fun(Pid, {TotalMsgs, ProcsNum, Apps, Stats}) ->
	      case proc_stat(Pid, AppPids) of
		  #proc_stat{qlen = QLen, application = App} = Stat
		    when QLen > 0 ->
		      {TotalMsgs + QLen, ProcsNum + 1,
		       dict:update_counter(App, QLen, Apps),
		       [Stat|Stats]};
		  _ ->
		      {TotalMsgs, ProcsNum, Apps, Stats}
	      end
      end, {0, 0, dict:new(), []}, AllProcs).

-spec proc_stat(pid(), map()) -> proc_stat() | undefined.
proc_stat(Pid, AppPids) ->
    case process_info(Pid, [message_queue_len,
			    memory,
			    initial_call,
			    current_function,
			    dictionary,
			    group_leader,
			    registered_name]) of
	[{_, MsgLen}, {_, Mem}, {_, InitCall},
	 {_, CurrFun}, {_, Dict}, {_, GL}, {_, Name}] ->
	    IntLen = proplists:get_value('$internal_queue_len', Dict, 0),
	    TrueInitCall = proplists:get_value('$initial_call', Dict, InitCall),
	    Ancestors = proplists:get_value('$ancestors', Dict, []),
	    Len = IntLen + MsgLen,
	    App = maps:get(GL, AppPids, kernel),
	    RegName = case Name of
			  [] -> Pid;
			  _ -> Name
		      end,
	    #proc_stat{qlen = Len,
		       memory = Mem,
		       initial_call = TrueInitCall,
		       current_function = CurrFun,
		       ancestors = Ancestors,
		       application = App,
		       name = RegName};
	_ ->
	    undefined
    end.

-spec restart_timer(#state{}) -> #state{}.
restart_timer(State) ->
    cancel_timer(State#state.tref),
    TRef = erlang:start_timer(?CHECK_INTERVAL, self(), handle_overload),
    State#state{tref = TRef}.

-spec cancel_timer(reference()) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive {timeout, TRef, _} -> ok
            after 0 -> ok
            end;
        _ ->
            ok
    end.

-spec format_apps(dict:dict()) -> io:data().
format_apps(Apps) ->
    AppList = lists:reverse(lists:keysort(2, dict:to_list(Apps))),
    string:join(
      [io_lib:format("~p (~b msgs)", [App, Msgs]) || {App, Msgs} <- AppList],
      ", ").

-spec format_top_procs([proc_stat()]) -> io:data().
format_top_procs(Stats) ->
    Stats1 = lists:sublist(Stats, 5),
    string:join(
      lists:map(
	fun(#proc_stat{name = Name} = Stat) ->
		[io_lib:format("** ~w: ", [Name]), format_proc(Stat)]
	end,Stats1),
      io_lib:nl()).

-spec format_proc(proc_stat()) -> io:data().
format_proc(#proc_stat{qlen = Len, memory = Mem, initial_call = InitCall,
		       current_function = CurrFun, ancestors = Ancs,
		       application = App}) ->
    io_lib:format(
      "msgs = ~b, memory = ~b, initial_call = ~s, "
      "current_function = ~s, ancestors = ~w, application = ~w",
      [Len, Mem, format_mfa(InitCall), format_mfa(CurrFun), Ancs, App]).

-spec format_mfa(mfa()) -> io:data().
format_mfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    io_lib:format("~s:~s/~b", [M, F, A]);
format_mfa(WTF) ->
    io_lib:format("~w", [WTF]).

-spec kill([proc_stat()], non_neg_integer()) -> ok.
kill(Stats, Threshold) ->
    case rtb_config:get_option(oom_killer) of
	true ->
	    do_kill(Stats, Threshold);
	false ->
	    ok
    end.

-spec do_kill([proc_stat()], non_neg_integer()) -> ok.
do_kill(Stats, Threshold) ->
    Killed = lists:filtermap(
	       fun(#proc_stat{qlen = Len, name = Name, application = App})
		     when Len >= Threshold ->
		       case lists:member(App, excluded_apps()) of
			   true ->
			       error_logger:warning_msg(
				 "Unable to kill process ~p from whitelisted "
				 "application ~p", [Name, App]),
			       false;
			   false ->
			       case kill_proc(Name) of
				   false ->
				       false;
				   Pid ->
				       maybe_restart_app(App),
				       {true, Pid}
			       end
		       end;
		  (_) ->
		       false
	       end, Stats),
    TotalKilled = length(Killed),
    if TotalKilled > 0 ->
	    error_logger:error_msg(
	      "Killed ~b process(es) consuming more than ~b message(s) each",
	      [TotalKilled, Threshold]);
       true ->
	    ok
    end.

-spec kill_proc(pid() | atom()) -> false | pid().
kill_proc(undefined) ->
    false;
kill_proc(Name) when is_atom(Name) ->
    kill_proc(whereis(Name));
kill_proc(Pid) ->
    exit(Pid, kill),
    Pid.

-spec set_oom_watermark() -> ok.
set_oom_watermark() ->
    WaterMark = rtb_config:get_option(oom_watermark),
    memsup:set_sysmem_high_watermark(WaterMark/100).

-spec maybe_restart_app(atom()) -> any().
maybe_restart_app(lager) ->
    application:stop(lager),
    application:start(lager);
maybe_restart_app(_) ->
    ok.
