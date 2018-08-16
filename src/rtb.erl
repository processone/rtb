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
-export([random_server/0, format_list/1, replace/2, cancel_timer/1,
	 make_pattern/1, set_debug/0]).

-callback load() -> ok | {error, any()}.
-callback start(pos_integer(),
		[gen_tcp:option()],
		[endpoint()],
		boolean()) ->
    {ok, pid()} | {error, any()} | ignore.
-callback options() -> [{atom(), any()} | atom()].
-callback prep_option(atom(), any()) -> {atom(), any()}.
-callback stats() -> [{atom(), integer()}].

-type server() :: inet:hostname() | inet:ip_address().
-type endpoint() :: {server(), inet:port_number(), boolean()}.
-opaque pattern() :: [char() | current | {random, pool | sm} |
		      {range, pos_integer(), pos_integer()}] |
		     binary().
-export_type([pattern/0]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================
start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    application:stop(?MODULE).

start(_StartType, _StartArgs) ->
    case start_apps() of
        ok ->
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
            end;
        Err ->
            Err
    end.

stop(_State) ->
    ok.

%%%===================================================================
%%% Miscellaneous functions
%%%===================================================================
start_apps() ->
    try
        LogRateLimit = 10000,
        ok = application:load(lager),
        application:set_env(lager, error_logger_hwm, LogRateLimit),
        application:set_env(
          lager, handlers,
          [{lager_console_backend, info},
           {lager_file_backend, [{file, "log/info.log"},
                                 {level, info}, {size, 0}]}]),
        application:set_env(lager, crash_log, "log/crash.log"),
        application:set_env(lager, crash_log_size, 0),
        {ok, _} = application:ensure_all_started(lager),
        lists:foreach(
          fun(Handler) ->
                  lager:set_loghwm(Handler, LogRateLimit)
          end, gen_event:which_handlers(lager_event)),
        lists:foreach(
          fun(App) ->
                  {ok, _} = application:ensure_all_started(App)
          end, [crypto, inets, p1_utils, fast_yaml])
    catch _:{badmatch, Reason} ->
            Reason
    end.

set_debug() ->
    lists:foreach(
      fun({lager_file_backend, _} = H) ->
              lager:set_loglevel(H, debug);
         (lager_console_backend = H) ->
              lager:set_loglevel(H, debug);
         (_) ->
              ok
      end, gen_event:which_handlers(lager_event)).

-spec halt() -> no_return().
halt() ->
    application:stop(sasl),
    application:stop(lager),
    halt(0).

-spec halt(io:format(), list()) -> no_return().
halt(Fmt, Args) ->
    Txt = io_lib:format(Fmt, Args),
    lager:critical("Benchmark failure: ~s", [Txt]),
    halt().

-spec random_server() -> [endpoint()].
random_server() ->
    Addrs = rtb_config:get_option(servers),
    case length(Addrs) of
	Len when Len >= 2 ->
	    Addr = lists:nth(p1_rand:uniform(1, Len), Addrs),
	    [Addr];
	_ ->
	    Addrs
    end.

-spec replace(pattern(), pos_integer() | iodata()) -> binary().
replace(Subj, _) when is_binary(Subj) ->
    Subj;
replace(Subj, I) when is_integer(I) ->
    replace(Subj, integer_to_list(I));
replace(Subj, Repl) ->
    iolist_to_binary(
      lists:map(
	fun(current) ->
		Repl;
	   ({random, unique}) ->
		integer_to_list(
		  p1_time_compat:unique_integer([positive]));
	   ({random, sm}) ->
		case rtb_sm:random() of
		    {ok, {_, I, _}} -> integer_to_list(I);
		    {error, _} -> Repl
		end;
	   ({range, From, To}) ->
		integer_to_list(p1_rand:uniform(From, To));
	   (Char) ->
		Char
	end, Subj)).

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

-spec cancel_timer(undefined | reference()) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    erlang:cancel_timer(TRef),
    receive {timeout, TRef, _} -> ok
    after 0 -> ok
    end.

-spec make_pattern(binary()) -> pattern().
make_pattern(S) ->
    Parts = case re:run(S, "\\[([0-9]+)..([0-9]+)\\]") of
		{match, [{Pos,Len},{F,FLen},{T,TLen}]} ->
		    Head = binary:part(S, {0,Pos}),
		    Tail = binary:part(S, {Pos+Len, size(S)-(Pos+Len)}),
		    From = binary_to_integer(binary:part(S, {F,FLen})),
		    To = binary_to_integer(binary:part(S, {T,TLen})),
		    if From < To ->
			    [Head, {range, From, To}, Tail];
		       From == To ->
			    [Head, integer_to_binary(From), Tail]
		    end;
		nomatch ->
		    [S]
	    end,
    Pattern = lists:flatmap(
		fun({_, _, _} = Range) ->
			[Range];
		   (Part) ->
			nomatch = binary:match(Part, <<$[>>),
			nomatch = binary:match(Part, <<$]>>),
			lists:map(
			  fun($%) -> current;
			     ($*) -> {random, unique};
			     ($?) -> {random, sm};
			     (C) -> C
			  end, binary_to_list(Part))
		end, Parts),
    try iolist_to_binary(Pattern)
    catch _:_ -> Pattern
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
format_tail([]) ->
    <<>>;
format_tail([S]) ->
    <<" and ", S/binary>>;
format_tail([H|T]) ->
    <<", ", H/binary, (format_tail(T))/binary>>.
