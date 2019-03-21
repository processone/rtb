%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2002-2019 ProcessOne, SARL. All Rights Reserved.
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
-module(rtb_sm).
-compile([{parse_transform, lager_transform},
	  {no_auto_import, [register/2, unregister/1]}]).
-behaviour(p1_server).

%% API
-export([start_link/0, register/3, unregister/1,
	 lookup/1, random/0, size/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(I, Pid, Val) ->
    ets:insert(?MODULE, {I, {Pid, Val}}).

unregister(I) ->
    try ets:delete(?MODULE, I)
    catch _:badarg -> true
    end.

lookup(I) ->
    try ets:lookup_element(?MODULE, I, 2) of
	{Pid, Val} -> {ok, {Pid, I, Val}}
    catch _:badarg ->
	    {error, notfound}
    end.

random() ->
    case {ets:first(?MODULE), ets:last(?MODULE)} of
	{From, To} when is_integer(From), is_integer(To) ->
	    Rnd = p1_rand:uniform(From, To),
	    Next = case ets:next(?MODULE, Rnd) of
		       '$end_of_table' -> From;
		       K -> K
		   end,
	    case lookup(Next) of
		{ok, Val} -> {ok, Val};
		{error, notfound} -> random()
	    end;
	_ ->
	    {error, empty}
    end.

size() ->
    ets:info(?MODULE, size).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    process_flag(trap_exit, true),
    ets:new(?MODULE, [named_table, public,
		      {read_concurrency, true},
		      ordered_set]),
    {ok, #state{}}.

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
