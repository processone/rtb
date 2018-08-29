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
-module(rtb_http).
-compile([{parse_transform, lager_transform}]).

%% API
-export([start_link/0, docroot/0, do/1]).

-include_lib("inets/include/httpd.hrl").

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    Opts = httpd_options(),
    DocRoot = proplists:get_value(document_root, Opts),
    case create_index_html(DocRoot) of
	ok ->
            Port = proplists:get_value(port, Opts),
	    case inets:start(httpd, Opts) of
		{ok, Pid} ->
		    lager:info("Accepting HTTP connections on port ~B", [Port]),
		    {ok, Pid};
		{error, Why} ->
                    log_error(Why, Port),
                    Why
	    end;
	{error, _} ->
	    rtb:halt()
    end.

docroot() ->
    ServerRoot = rtb_config:get_option(www_dir),
    filename:join(ServerRoot, "data").

do(#mod{method = Method, data = Data}) ->
    if Method == "GET"; Method == "HEAD" ->
	    case lists:keyfind(real_name, 1, Data) of
		{real_name, {Path, _}} ->
		    Basename = filename:basename(Path, ".png"),
                    try list_to_existing_atom(Basename) of
                        Name ->
                            case rtb_stats:get_type(Name) of
                                undefined ->
                                    ok;
                                Type ->
                                    rtb_stats:flush(Name),
                                    rtb_plot:render(Name, Type)
                            end
		    catch _:badarg ->
			    ok
		    end;
		false ->
		    ok
	    end;
       true ->
	    ok
    end,
    {proceed, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
httpd_options() ->
    ServerRoot = rtb_config:get_option(www_dir),
    Port = rtb_config:get_option(www_port),
    Domain = rtb_config:get_option(www_domain),
    DocRoot = filename:join(ServerRoot, "data"),
    [{port, Port},
     {server_root, ServerRoot},
     {document_root, DocRoot},
     {mime_types, [{"html", "text/html"},
		   {"png", "image/png"}]},
     {directory_index, ["index.html"]},
     {modules, [mod_alias, ?MODULE, mod_get, mod_head]},
     {script_nocache, true},
     {server_name, Domain}].

create_index_html(DocRoot) ->
    Data = ["<!DOCTYPE html><html><body>",
	    lists:map(
	      fun(Name) ->
		      ["<img src='/", atom_to_list(Name), ".png?time=0'>"]
	      end, rtb_stats:get_metrics()),
            "<script>" ++ script() ++ "</script>",
	    "</body></html>"],
    File = filename:join(DocRoot, "index.html"),
    case filelib:ensure_dir(File) of
	ok ->
	    case file:write_file(File, Data) of
		ok ->
		    ok;
		{error, Why} = Err ->
		    lager:critical("Failed to write to ~s: ~s",
				   [File, file:format_error(Why)]),
		    Err
	    end;
	{error, Why} = Err ->
	    lager:critical("Failed to create directory ~s: ~s",
			   [DocRoot, file:format_error(Why)]),
	    Err
    end.

script() ->
    %% Reload all images every 5 seconds
    "setInterval(function() {
      var images = document.images;
      for (var i=0; i<images.length; i++) {
          images[i].src = images[i].src.replace(/\\btime=[^&]*/, 'time=' + new Date().getTime());
      }
     }, 5000);".

log_error({{shutdown, _} = Err, _}, Port) ->
    log_error(Err, Port);
log_error({shutdown, {failed_to_start_child, _, Err}}, Port) ->
    log_error(Err, Port);
log_error({listen, Why}, Port) ->
    rtb:halt("Failed to listen on port ~B: ~s", [Port, inet:format_error(Why)]);
log_error(_, Port) ->
    lager:critical("Failed to listen on port ~B: internal failure", [Port]).
