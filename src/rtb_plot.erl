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
-module(rtb_plot).
-compile([{parse_transform, lager_transform}]).

%% API
-export([render/2]).

%%%===================================================================
%%% API
%%%===================================================================
-spec render(atom(), atom()) -> ok.
render(Name, Type) ->
    OutDir = rtb_http:docroot(),
    StatsDir = rtb_config:get_option(stats_dir),
    DataFile = filename:join(StatsDir, Name) ++ ".dat",
    do_render(atom_to_list(Name), DataFile, OutDir, Type).

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_render(Name, DataFile, Dir, Type) ->
    OutFile = filename:join(Dir, Name ++ ".png"),
    Gnuplot = rtb_config:get_option(gnuplot),
    Cmds = ["set title '" ++ Name ++ "'"] ++
            xlabel(Type) ++ ylabel(Type) ++
           ["set grid",
            "set boxwidth 0.9",
	    "set style " ++ style(Type),
	    "set terminal png small size 400,300",
	    "set output '" ++ OutFile ++ "'",
	    "plot '" ++ DataFile ++ "' using 1:2 with " ++ with(Type) ++ " notitle"],
    Ret = os:cmd(Gnuplot ++ " -e \"" ++ string:join(Cmds, "; ") ++ "\""),
    check_ret(Name, Ret).

style(hist) -> "fill solid 0.5";
style(_) -> "line 1 linecolor rgb '#0060ad' linetype 1".

with(hist) -> "boxes";
with(_) -> "lines linestyle 1".

ylabel(hist) -> ["set ylabel '%' rotate by 0"];
ylabel(rate) -> ["set ylabel 'number/sec'"];
ylabel(_) -> ["set ylabel 'number'"].

xlabel(hist) -> ["set xlabel 'round trip time (milliseconds)'"];
xlabel(_) -> ["set xlabel 'benchmark duration (seconds)'"].

check_ret(_, "") -> ok;
check_ret(_, "Warning:" ++ _) -> ok;
check_ret(Name, Err) ->
    lager:error("Failed to render '~s' graph:~n~s", [Name, Err]).
