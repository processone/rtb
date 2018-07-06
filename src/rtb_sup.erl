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
-module(rtb_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).
%% Supervisor callbacks
-export([init/1]).

-define(SHUTDOWN_TIMEOUT, timer:seconds(1)).

%%===================================================================
%% API functions
%%===================================================================
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%===================================================================
%% Supervisor callbacks
%%===================================================================
init([]) ->
    Pool = lists:map(
	     fun(I) ->
		     Name = pool_name(I),
		     worker(Name, rtb_pool, [Name, I])
	     end, lists:seq(1, cores())),
    {ok, {{one_for_all, 10, 1},
	  [worker(rtb_config),
	   worker(rtb_sm),
	   worker(rtb_stats),
	   worker(rtb_http)|Pool]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
pool_name(I) ->
    list_to_atom("rtb_pool_" ++ integer_to_list(I)).

worker(Mod) ->
    worker(Mod, Mod).

worker(Name, Mod) ->
    worker(Name, Mod, []).

worker(Name, Mod, Args) ->
    {Name, {Mod, start_link, Args}, permanent, ?SHUTDOWN_TIMEOUT, worker, [Mod]}.

cores() ->
    erlang:system_info(logical_processors).
