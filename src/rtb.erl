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
-module(rtb).
-compile([{parse_transform, lager_transform},
	  {no_auto_import, [halt/0]}]).
-behaviour(application).

%% Application callbacks
-export([start/0, start/2, stop/0, stop/1, halt/0, halt/2]).
%% Miscellaneous API
-export([random_server/0, format_list/1]).

-callback load() -> ok | {error, any()}.
-callback start(pos_integer(), jid:jid(), binary(),
		[gen_tcp:option()],
		[{inet:hostname(), inet:port_number(), tcp | tls}],
		boolean()) ->
    {ok, pid()} | {error, any()} | ignore.
-callback options() -> [{atom(), any()} | atom()].
-callback prep_option(atom(), any()) -> {atom(), any()}.
-callback stats() -> [{atom(), integer()}].

%%%===================================================================
%%% Application callbacks
%%%===================================================================
start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    application:stop(?MODULE).

start(_StartType, _StartArgs) ->
    case rtb_sup:start_link() of
	{ok, SupPid} ->
	    case rtb_watchdog:start() of
		{ok, _} ->
		    {ok, SupPid};
		_Err ->
		    halt()
	    end;
	_Err ->
	    halt()
    end.

stop(_State) ->
    ok.

%%%===================================================================
%%% Miscellaneous functions
%%%===================================================================
halt() ->
    application:stop(sasl),
    application:stop(lager),
    halt(0).

halt(Fmt, Args) ->
    Txt = io_lib:format(Fmt, Args),
    lager:critical("Benchmark failure: ~s", [Txt]),
    halt().

random_server() ->
    Addrs = rtb_config:get_option(servers),
    case length(Addrs) of
	Len when Len >= 2 ->
	    Addr = lists:nth(p1_rand:uniform(1, Len), Addrs),
	    [Addr];
	_ ->
	    Addrs
    end.

-spec format_list([iodata() | atom()]) -> binary().
format_list([]) ->
    <<>>;
format_list(L) ->
    [H|T] = lists:map(
	      fun(A) when is_atom(A) ->
		      atom_to_binary(A, latin1);
		 (B) ->
		      iolist_to_binary(B)
	      end, L),
    <<H/binary, (format_tail(T))/binary>>.

%%%===================================================================
%%% Internal functions
%%%===================================================================
format_tail([]) ->
    <<>>;
format_tail([S]) ->
    <<" and ", S/binary>>;
format_tail([H|T]) ->
    <<", ", H/binary, (format_tail(T))/binary>>.
