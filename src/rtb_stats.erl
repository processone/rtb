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
-export([start_link/0, incr/1, decr/1, set/2, del/1, lookup/1, hist/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(INTERVAL, timer:seconds(5)).

-record(state, {mod  :: module(),
		fd   :: file:fd(),
		time :: integer(),
		path :: file:filename()}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    p1_server:start_link({local, ?MODULE}, ?MODULE, [], []).

incr(Counter) ->
    ets:update_counter(?MODULE, Counter, 1, {Counter, 0}).

decr(Counter) ->
    ets:update_counter(?MODULE, Counter, -1, {Counter, 0}).

set(Key, Val) ->
    ets:insert(?MODULE, {Key, Val}).

del(Key) ->
    ets:delete(?MODULE, Key).

lookup(Key) ->
    try ets:lookup_element(?MODULE, Key, 2)
    catch _:badarg -> 0
    end.

hist(Key) ->
    Objs = ets:match_object(?MODULE, {{Key, '_'}, '_'}),
    [{Name, Val} || {{_, Name}, Val} <- Objs].

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    ets:new(?MODULE, [named_table, public,
		      {write_concurrency, true}]),
    Path = rtb_config:get_option(stats_file),
    Mod = rtb_config:get_option(module),
    try
	lists:foreach(
	  fun({Counter, F}) ->
		  set(Counter, F(Counter))
	  end, Mod:stats()),
	ok = filelib:ensure_dir(Path),
	{ok, Fd} = file:open(Path, [write, raw]),
	ok = file:write(Fd, header(Mod)),
	State = #state{mod = Mod, fd = Fd, path = Path,
		       time = p1_time_compat:monotonic_time(seconds)},
	ok = log(State),
	erlang:send_after(?INTERVAL, self(), log),
	lager:info("Dumping statistics to ~s every ~B seconds",
		   [Path, ?INTERVAL div 1000]),
	{ok, State}
    catch _:{badmatch, {error, Why}} ->
	    lager:critical("Failed to read/write file ~s: ~s",
			   [Path, file:format_error(Why)]),
	    {stop, Why}
    end.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(log, State) ->
    erlang:send_after(?INTERVAL, self(), log),
    case log(State) of
	ok ->
	    {noreply, State};
	{error, Why} ->
	    rtb:halt("Failed to write to ~s: ~s",
		       [State#state.path, file:format_error(Why)])
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
fields(Mod) ->
    ["timestamp"|[atom_to_list(A) || {A, _} <- Mod:stats()]].

header(Mod) ->
    [string:join(["#"|fields(Mod)], " "), io_lib:nl()].

timestamp(TS) ->
    integer_to_list(p1_time_compat:monotonic_time(seconds) - TS).

format_row(TS, Row) ->
    [string:join(
       [timestamp(TS)|[integer_to_list(R) || R <- Row]], " "),
     io_lib:nl()].

log(#state{fd = Fd, mod = Mod, time = TS}) ->
    Row = lists:map(
	    fun({Counter, F}) -> F(Counter)
	    end, Mod:stats()),
    file:write(Fd, format_row(TS, Row)).
