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
-module(rtb_plot).
-compile([{parse_transform, lager_transform}]).

%% API
-export([render/1]).

%%%===================================================================
%%% API
%%%===================================================================
render(Field) ->
    Mod = rtb_config:get_option(module),
    Path = rtb_config:get_option(stats_file),
    OutDir = rtb_http:docroot(),
    Fields = [atom_to_list(F) || {F, _} <- Mod:stats()],
    Position = position(Field, Fields),
    render(Field, Path, OutDir, Position),
    render_rate(Field, Path, OutDir, Position).

%%%===================================================================
%%% Internal functions
%%%===================================================================
render(Field, Path, Dir, N) ->
    OutFile = filename:join(Dir, Field ++ ".png"),
    Pos = integer_to_list(N),
    Gnuplot = rtb_config:get_option(gnuplot),
    Cmds = ["set title '" ++ Field ++ "'",
	    "set grid",
	    "set style line 1 linecolor rgb '#0060ad' linetype 1",
	    "set terminal png small size 400,300",
	    "set output '" ++ OutFile ++ "'",
	    "plot '" ++ Path ++ "' using 1:" ++ Pos ++
		" with lines linestyle 1 notitle"],
    os:cmd(Gnuplot ++ " -e \"" ++ string:join(Cmds, "; ") ++ "\""),
    ok.

render_rate(Field, Path, Dir, N) ->
    OutFile = filename:join(Dir, Field ++ "-rate.png"),
    Pos = integer_to_list(N),
    Gnuplot = rtb_config:get_option(gnuplot),
    Cmds = ["set title '" ++ Field ++ "-rate'",
	    "set grid",
            "delta_v(time, val) = (delta_val = (prev_val == 0) ? 0 : val - prev_val,"
            "                      delta_time = (prev_time == 0) ? 1: time - prev_time, "
            "                      delta = delta_val/delta_time, "
            "                      prev_time = time, prev_val = val, delta)",
            "prev_time = 0",
            "prev_val = 0",
	    "set style line 1 linecolor rgb '#0060ad' linetype 1",
	    "set terminal png small size 400,300",
	    "set output '" ++ OutFile ++ "'",
	    "plot '" ++ Path ++ "' using 1:(delta_v(\\$1, \\$" ++ Pos ++
		")) with lines linestyle 1 notitle"],
    os:cmd(Gnuplot ++ " -e \"" ++ string:join(Cmds, "; ") ++ "\""),
    ok.

position(X, L) ->
    position(X, L, 2).

position(X, [X|_], N) ->
    N;
position(X, [_|T], N) ->
    position(X, T, N+1).
