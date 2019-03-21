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
-module(mod_xmpp_http).
-compile([{parse_transform, lager_transform}]).

%% API
-export([upload/4, download/4, format_error/1]).

-define(BUF_SIZE, 65536).

-type upload_error() :: {gen_tcp, inet:posix()} | {ssl, term()} |
			{http, string()} | {bad_url, string()}.

%%%===================================================================
%%% API
%%%===================================================================
-spec upload(string(), non_neg_integer(), list(), non_neg_integer()) ->
		    {error, upload_error()}.
upload(URL, Size, ConnOpts, Timeout) ->
    case connect(URL, ConnOpts, Timeout) of
	{ok, SockMod, Sock, Host, Port, Path, Query} ->
	    Res = upload_file(SockMod, Sock, Host, Port, Path, Query, Size, Timeout),
	    SockMod:close(Sock),
	    Res;
	{error, _} = Err ->
	    Err
    end.

download(URL, Size, ConnOpts, Timeout) ->
    case connect(URL, ConnOpts, Timeout) of
	{ok, SockMod, Sock, Host, Port, Path, Query} ->
	    Res = download_file(SockMod, Sock, Host, Port, Path, Query, Size, Timeout),
	    SockMod:close(Sock),
	    Res;
	{error, _} = Err ->
	    Err
    end.

-spec format_error(upload_error()) -> string().
format_error({bad_url, URL}) ->
    "Failed to parse URL: " ++ URL;
format_error({http, Reason}) ->
    "HTTP failure: " ++ Reason;
format_error(Reason) ->
    "HTTP failure: " ++ do_format_error(Reason).

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec do_format_error(upload_error()) -> string().
do_format_error({_, closed}) ->
    "connection closed";
do_format_error({_, timeout}) ->
    inet:format_error(etimedout);
do_format_error({ssl, Reason}) ->
    ssl:format_error(Reason);
do_format_error({gen_tcp, Reason}) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" -> atom_to_list(Reason);
        Txt -> Txt
    end.

connect(URL, ConnOpts, Timeout) ->
    case http_uri:parse(URL) of
	{ok, {Scheme, _, Host, Port, Path, Query}}
	  when Scheme == http; Scheme == https ->
	    SockMod = sockmod(Scheme),
	    Opts = opts(ConnOpts, Timeout),
	    case SockMod:connect(Host, Port, Opts, Timeout) of
		{ok, Sock} ->
		    {ok, SockMod, Sock, Host, Port, Path, Query};
		{error, Reason} ->
		    {error, {SockMod, Reason}}
	    end;
	_ ->
	    {error, {bad_url, URL}}
    end.

upload_file(SockMod, Sock, Host, Port, Path, Query, Size, Timeout) ->
    Hdrs = io_lib:format(
	     "PUT ~s~s HTTP/1.1\r\n"
	     "Host: ~s:~B\r\n"
	     "Content-Type: image/png\r\n"
	     "Content-Length: ~B\r\n"
	     "Connection: keep-alive\r\n\r\n",
	     [Path, Query, Host, Port, Size]),
    case SockMod:send(Sock, Hdrs) of
	ok ->
	    Chunk = p1_rand:bytes(?BUF_SIZE),
	    case upload_data(SockMod, Sock, Size, Chunk) of
		ok ->
		    recv_headers(SockMod, Sock, undefined, Timeout);
		{error, _} = Err ->
		    Err
	    end;
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

upload_data(_SockMod, _Sock, 0, _Chunk) ->
    ok;
upload_data(SockMod, Sock, Size, Chunk) ->
    Data = if Size >= ?BUF_SIZE ->
		   Chunk;
	      true ->
		   binary:part(Chunk, 0, Size)
	   end,
    case SockMod:send(Sock, Data) of
	ok ->
	    NewSize = min(Size, ?BUF_SIZE),
	    upload_data(SockMod, Sock, Size-NewSize, Chunk);
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

download_file(SockMod, Sock, Host, Port, Path, Query, Size, Timeout) ->
    Hdrs = io_lib:format(
	     "GET ~s~s HTTP/1.1\r\n"
	     "Host: ~s:~B\r\n"
	     "Connection: keep-alive\r\n\r\n",
	     [Path, Query, Host, Port]),
    case SockMod:send(Sock, Hdrs) of
	ok ->
	    recv_headers(SockMod, Sock, Size, Timeout);
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

recv_body(_SockMod, _Sock, 0, _Timeout) ->
    ok;
recv_body(SockMod, Sock, Size, Timeout) ->
    ChunkSize = min(Size, ?BUF_SIZE),
    case SockMod:recv(Sock, ChunkSize, Timeout) of
	{ok, Data} ->
	    recv_body(SockMod, Sock, Size-size(Data), Timeout);
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

recv_headers(SockMod, Sock, Size, Timeout) ->
    case SockMod:recv(Sock, 0, Timeout) of
	{ok, {http_response, _, Code, String}} ->
	    if Code >= 200, Code < 300 ->
		    recv_headers(SockMod, Sock, Size, Timeout);
	       true ->
		    C = integer_to_binary(Code),
		    Reason = <<String/binary, " (", C/binary, $)>>,
		    {error, {http, binary_to_list(Reason)}}
	    end;
	{ok, {http_header, _, 'Content-Length', _, Len}} ->
	    case binary_to_integer(Len) of
	     	Size ->
		    recv_headers(SockMod, Sock, Size, Timeout);
		Size1 when Size == undefined ->
		    recv_headers(SockMod, Sock, Size1, Timeout);
		_ ->
		    Txt = "Unexpected Content-Length",
		    lager:warning("~s: ~s (should be: ~B)", [Txt, Len, Size]),
		    {error, {http, Txt}}
	    end;
	{ok, {http_header, _, _, _, _}} ->
	    recv_headers(SockMod, Sock, Size, Timeout);
	{ok, {http_error, String}} ->
	    {error, {http, binary_to_list(iolist_to_binary(String))}};
	{ok, http_eoh} ->
	    case setopts(SockMod, Sock, [{packet, 0}]) of
		ok ->
		    recv_body(SockMod, Sock, Size, Timeout);
		{error, Reason} ->
		    {error, {SockMod, Reason}}
	    end;
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

sockmod(http) -> gen_tcp;
sockmod(https) -> ssl.

setopts(gen_tcp, Sock, Opts) ->
    inet:setopts(Sock, Opts);
setopts(ssl, Sock, Opts) ->
    ssl:setopts(Sock, Opts).

opts(Opts, Timeout) ->
    [binary,
     {packet, http_bin},
     {send_timeout, Timeout},
     {send_timeout_close, true},
     {recbuf, ?BUF_SIZE},
     {sndbuf, ?BUF_SIZE},
     {active, false}|Opts].
