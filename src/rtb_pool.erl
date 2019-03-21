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
-module(rtb_pool).
-compile([{parse_transform, lager_transform},
	  {no_auto_import, [register/2, unregister/1]}]).
-behaviour(p1_server).

%% API
-export([start_link/2, register/2, unregister/1, lookup/1, random/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type addr_list() :: [inet:ip_address()].

-record(state, {module       :: module(),
		capacity     :: pos_integer(),
		interval     :: pos_integer(),
		name         :: pos_integer(),
		bind_addrs   :: {addr_list(), addr_list()},
		server_addrs :: {addr_list(), addr_list()}}).

%%%===================================================================
%%% API
%%%===================================================================
start_link(Name, I) ->
    p1_server:start_link({local, Name}, ?MODULE, [I], []).

register(Pid, I) ->
    ets:insert(?MODULE, {Pid, I}).

unregister(Pid) ->
    try ets:delete(?MODULE, Pid)
    catch _:badarg -> true
    end.

lookup(Pid) ->
    try ets:lookup_element(?MODULE, Pid, 2) of
	I -> {ok, I}
    catch _:badarg ->
	    {error, notfound}
    end.

random() ->
    Capacity = rtb_config:get_option(capacity),
    p1_rand:uniform(Capacity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([I]) ->
    process_flag(trap_exit, true),
    catch ets:new(?MODULE, [named_table, public,
			    {write_concurrency, true}]),
    Mod = rtb_config:get_option(module),
    Interval = rtb_config:get_option(interval),
    Capacity = rtb_config:get_option(capacity),
    BindAddrs = rtb_config:get_option(bind),
    Servers = shuffle(rtb_config:get_option(servers)),
    if I == 1 ->
	    self() ! boot;
       true ->
	    ok
    end,
    {ok, #state{module = Mod,
		name = I,
		capacity = Capacity,
		interval = Interval,
		bind_addrs = {BindAddrs, BindAddrs},
		server_addrs = {Servers, Servers}}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(boot, State) ->
    wait_for_startup(),
    handle_info(connect, State);
handle_info(connect, #state{module = Mod,
			    interval = Interval,
			    bind_addrs = BindAddrs,
			    server_addrs = ServerAddrs,
			    capacity = Capacity} = State) ->
    I = ets:update_counter(?MODULE, iteration, 1, {iteration, 0}),
    if I =< Capacity ->
	    erlang:send_after(Interval, self(), connect),
	    {Opts, BindAddrs1} = connect_options(BindAddrs),
	    {Addrs, ServerAddrs1} = server_addrs(ServerAddrs),
	    case Mod:start(I, Opts, Addrs, I == 1) of
		{ok, _Pid} ->
		    {noreply, State#state{bind_addrs = BindAddrs1,
					  server_addrs = ServerAddrs1}};
		Err ->
		    rtb:halt("Failed to start C2S process: ~p", [Err])
	    end;
       true ->
	    {noreply, State}
    end;
handle_info(Info, State) ->
    lager:warning("Got unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec wait_for_startup() -> ok.
wait_for_startup() ->
    [_|_] = supervisor:which_children(rtb_sup),
    ok.

connect_options({[], []}) ->
    {[], {[], []}};
connect_options({[], BindAddrs}) ->
    connect_options({BindAddrs, BindAddrs});
connect_options({[H|T], BindAddrs}) ->
    {[{ip, H}], {T, BindAddrs}}.

server_addrs({[], []}) ->
    {[], {[], []}};
server_addrs({[], ServerAddrs}) ->
    server_addrs({ServerAddrs, ServerAddrs});
server_addrs({[H|T], ServerAddrs}) ->
    {[H], {T, ServerAddrs}}.

shuffle(L) ->
    shuffle(L, []).

shuffle([], Acc) ->
    Acc;
shuffle(L, Acc) ->
    {H, T} = take(L),
    shuffle(T, [H|Acc]).

take(L) when L /= [] ->
    N = p1_rand:uniform(1, length(L)),
    take(L, 1, N, []).

take([H|T], N, N, Acc) ->
    {H, lists:reverse(Acc) ++ T};
take([H|T], M, N, Acc) ->
    take(T, M+1, N, [H|Acc]).
