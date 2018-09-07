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
-module(rtb_stats).
-compile([{parse_transform, lager_transform}]).
-behaviour(p1_server).

%% API
-export([start_link/0, incr/1, incr/2, decr/1, decr/2, lookup/1]).
-export([get_type/1, get_metrics/0, flush/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(INTERVAL, timer:seconds(1)).

-include("rtb.hrl").

-record(state, {mod  :: module(),
		time :: integer(),
                metrics :: map()}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    p1_server:start_link({local, ?MODULE}, ?MODULE, [], []).

incr(Metric) ->
    incr(Metric, 1).

incr(Metric, Incr) ->
    try ets:lookup_element(?MODULE, Metric, 2) of
	Counter -> oneup:inc2(Counter, Incr)
    catch _:badarg ->
	    Counter = oneup:new_counter(),
	    case ets:insert_new(?MODULE, {Metric, Counter}) of
		true ->
		    oneup:inc2(Counter, Incr);
		false ->
		    Counter2 = ets:lookup_element(?MODULE, Metric, 2),
		    oneup:inc2(Counter2, Incr)
	    end
    end.

decr(Metric) ->
    decr(Metric, 1).

decr(Metric, Decr) ->
    try ets:lookup_element(?MODULE, Metric, 2) of
	Counter -> oneup:inc2(Counter, -Decr)
    catch _:badarg ->
	    ok
    end.

lookup(Key) ->
    try ets:lookup_element(?MODULE, Key, 2) of
	Counter -> oneup:get(Counter)
    catch _:badarg ->
	    0
    end.

get_type(Metric) ->
    p1_server:call(?MODULE, {get_type, Metric}, infinity).

get_metrics() ->
    p1_server:call(?MODULE, get_metrics, infinity).

flush(Metric) ->
    p1_server:call(?MODULE, {flush, Metric}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    ets:new(?MODULE, [named_table, public,
		      {write_concurrency, true}]),
    Dir = rtb_config:get_option(stats_dir),
    Mod = rtb_config:get_option(module),
    case init_metrics(Mod, Dir) of
        {ok, Metrics} ->
            State = #state{mod = Mod, metrics = Metrics,
                           time = p1_time_compat:monotonic_time(seconds)},
            erlang:send_after(?INTERVAL, self(), log),
            lager:debug("Dumping statistics to ~s every ~B second(s)",
                        [Dir, ?INTERVAL div 1000]),
            {ok, State};
        error ->
            rtb:halt()
    end.

handle_call({flush, Name}, _From, State) ->
    case maps:get(Name, State#state.metrics, undefined) of
        {_, hist, _, File, Fd} ->
            case write_hist(Name, File, Fd) of
                ok -> ok;
                {error, File, Why} ->
                    lager:critical("Failed to write to ~s: ~s",
                                   [File, file:format_error(Why)])
            end;
        _ ->
            ok
    end,
    {reply, ok, State};
handle_call({get_type, Name}, _From, State) ->
    Type = case maps:get(Name, State#state.metrics, undefined) of
               undefined -> undefined;
               T -> element(2, T)
           end,
    {reply, Type, State};
handle_call(get_metrics, _From, State) ->
    Metrics = maps:to_list(State#state.metrics),
    Names = [Name || {Name, _} <- lists:keysort(2, Metrics)],
    {reply, Names, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(log, State) ->
    erlang:send_after(?INTERVAL, self(), log),
    case log(State) of
	ok -> ok;
	{error, File, Why} ->
	    lager:critical("Failed to write to ~s: ~s",
                           [File, file:format_error(Why)])
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
timestamp(TS) ->
    integer_to_list(p1_time_compat:monotonic_time(seconds) - TS).

write_row(TS, Int, File, Fd) ->
    Row = [timestamp(TS), " ", integer_to_list(Int), io_lib:nl()],
    case file:write(Fd, Row) of
        {error, Why} -> {error, File, Why};
        ok -> ok
    end.

write_hist(Name, File, Fd) ->
    {Hist, Sum} = lists:mapfoldl(
                    fun({{_, X}, Counter}, Acc) ->
			    Y = oneup:get(Counter),
                            {{X, Y}, Acc+Y}
                    end, 0, ets:match_object(?MODULE, {{Name, '_'}, '_'})),
    try
        {ok, _} = file:position(Fd, bof),
        case lists:foldl(
               fun({X, Y}, Acc) ->
                       Percent = Y*100/Sum,
                       if Percent >= 0.1 ->
                               Y1 = io_lib:format("~.2f", [Percent]),
                               Row = [integer_to_list(X), " ", Y1, io_lib:nl()],
                               ok = file:write(Fd, Row),
                               true;
                          true ->
                               Acc
                       end
               end, false, Hist) of
            true ->
                ok = file:truncate(Fd);
            false ->
                ok
        end
    catch _:{badmatch, {error, Why}} ->
            {error, File, Why}
    end.

log(#state{time = TS, metrics = Metrics}) ->
    maps:fold(
      fun(Name, Val, ok) ->
              log(TS, Name, Val);
         (_, _, Err) ->
              Err
      end, ok, Metrics).

log(TS, Name, {_, Type, Call, File, Fd}) when Type == gauge; Type == counter ->
    Val = case Call of
              undefined -> lookup(Name);
              _ -> Call()
          end,
    write_row(TS, Val, File, Fd);
log(TS, _Name, {_, rate, {Name, Call}, File, Fd}) ->
    New = case Call of
              undefined -> lookup(Name);
              _ -> Call()
          end,
    Old = put(Name, New),
    Val = case Old of
              undefined -> 0;
              _ -> abs(Old - New)
          end,
    write_row(TS, Val, File, Fd);
log(_, _, {_, _, _, _, _}) ->
    ok.

init_metrics(Mod, Dir) ->
    init_metrics(Mod:metrics(), Dir, 1, #{}).

init_metrics([Metric|Metrics], Dir, Pos, Acc) ->
    #metric{name = Name, type = Type, call = Call, rate = Rate} = Metric,
    File = filename:join(Dir, Name) ++ ".dat",
    case init_file(File) of
        {ok, Fd} ->
            Acc1 = maps:put(Name, {Pos, Type, Call, File, Fd}, Acc),
            if Rate andalso Type /= hist ->
                    RateName = list_to_atom(atom_to_list(Name) ++ "-rate"),
                    RateFile = filename:join(Dir, RateName) ++ ".dat",
                    case init_file(RateFile) of
                        {ok, RateFd} ->
                            Acc2 = maps:put(
                                     RateName,
                                     {Pos+1, rate, {Name, Call}, RateFile, RateFd},
                                     Acc1),
                            init_metrics(Metrics, Dir, Pos+2, Acc2);
                        error ->
                            error
                    end;
               true ->
                    init_metrics(Metrics, Dir, Pos+1, Acc1)
            end;
        error ->
            error
    end;
init_metrics([], _, _, Acc) ->
    {ok, Acc}.

init_file(File) ->
    case file:open(File, [write, raw]) of
        {ok, Fd} ->
            case file:write(Fd, ["0 0", io_lib:nl()]) of
                ok -> {ok, Fd};
                {error, Why} ->
                    lager:critical("Failed to write to ~s: ~s",
                                   [File, file:format_error(Why)]),
                    error
            end;
        {error, Why} ->
            lager:critical("Failed to open ~s for writing: ~s",
                           [File, file:format_error(Why)]),
            error
    end.
