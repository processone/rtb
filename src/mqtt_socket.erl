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
-module(mqtt_socket).
-compile([{parse_transform, lager_transform}]).

%% API
-export([lookup/2, connect/3, send/2, recv/2, activate/1, close/1]).
-export([format_error/1]).

-include("rtb.hrl").
-include_lib("kernel/include/inet.hrl").

-define(TCP_SEND_TIMEOUT, timer:seconds(15)).
-define(DNS_TIMEOUT, timer:seconds(5)).

-type socket_error_reason() :: closed | timeout | inet:posix().
-type error_reason() :: {socket, socket_error_reason()} |
			{dns, inet:posix() | inet_res:res_error()} |
			{tls, inet:posix() | atom() | binary()}.
-type socket() :: {websocket, pid()} |
		  {fast_tls, fast_tls:tls_socket()} |
		  {gen_tcp, gen_tcp:socket()}.
-export_type([error_reason/0, socket/0]).

%%%===================================================================
%%% API
%%%===================================================================
connect(Addrs, Opts, Time) ->
    Timeout = max(0, Time - current_time()) div length(Addrs),
    connect(Addrs, Opts, Timeout, {error, {dns, nxdomain}}).

connect([{EndPoint, Family}|Addrs], Opts, Timeout, _Err) ->
    case do_connect(EndPoint, Family, Opts, Timeout) of
	{ok, Sock} ->
	    {ok, Sock};
	{error, _} = Err ->
	    connect(Addrs, Opts, Timeout, Err)
    end;
connect([], _, _, Err) ->
    Err.

do_connect(#endpoint{transport = Type, address = Addr,
		  port = Port, host = Host, path = Path},
	_Family, Opts, Timeout) when Type == ws; Type == wss ->
    lager:debug("Connecting to ~s://~s:~B~s",
                [Type, inet_parse:ntoa(Addr), Port, Path]),
    Opts1 = case Type of
		wss -> [{certfile, rtb_config:get_option(certfile)}|Opts];
		ws -> Opts
	    end,
    case gun:open(Addr, Port, #{transport => transport(Type),
				transport_opts => Opts1,
				retry => 0}) of
	{ok, ConnPid} ->
	    case gun:await_up(ConnPid, Timeout) of
		{ok, _} ->
		    StreamRef = gun:ws_upgrade(
				  ConnPid, Path,
				  [{<<"host">>, Host}],
				  #{protocols => [{<<"mqtt">>, gun_ws_h}]}),
		    receive
			{gun_upgrade, ConnPid, StreamRef, _, _} ->
			    {ok, {websocket, ConnPid}};
			{gun_response, ConnPid, StreamRef, _, Status, _} ->
			    lager:debug("HTTP Upgrade failed with status: ~B",
					[Status]),
			    {error, {socket, eproto}};
			{gun_error, ConnPid, StreamRef, Reason} ->
			    lager:debug("HTTP Upgrade failed with reason: ~p",
					[Reason]),
			    {error, {socket, closed}}
		    after Timeout ->
			    {error, {socket, etimedout}}
		    end;
		{error, Why} ->
		    {error, {socket, prep_error(Why)}}
	    end;
	{error, Why} ->
	    lager:error("Failed to initialize HTTP connection: ~p", [Why]),
	    {error, internal_server_error}
    end;
do_connect(#endpoint{address = Addr, transport = Type, port = Port},
	Family, Opts, Timeout) ->
    lager:debug("Connecting to ~s://~s:~B",
                [Type, inet_parse:ntoa(Addr), Port]),
    case gen_tcp:connect(Addr, Port, sockopts(Family, Opts), Timeout) of
	{ok, Sock} when Type == tls ->
	    CertFile = {certfile, rtb_config:get_option(certfile)},
	    case fast_tls:tcp_to_tls(Sock, [connect, CertFile]) of
		{ok, Sock1} ->
		    {ok, {fast_tls, Sock1}};
		{error, Why} ->
		    {error, {tls, Why}}
	    end;
	{ok, Sock} when Type == tcp ->
	    {ok, {gen_tcp, Sock}};
	{error, Why} ->
	    {error, {socket, Why}}
    end.

send(Socket, Data) ->
    Ret = case Socket of
	      {websocket, ConnPid} ->
		  gun:ws_send(ConnPid, {binary, Data});
	      {SockMod, Sock} ->
		  SockMod:send(Sock, Data)
	  end,
    check_sock_result(Socket, Ret).

recv({fast_tls, Sock}, Data) when Data /= <<>> ->
    case fast_tls:recv_data(Sock, Data) of
	{ok, _} = OK -> OK;
	{error, Reason} when is_atom(Reason) -> {error, {socket, Reason}};
	{error, _} = Err -> Err
    end;
recv(_, Data) ->
    {ok, Data}.

activate(Socket) ->
    Ret = case Socket of
	      {websocket, _} ->
		  ok;
	      {gen_tcp, Sock} ->
		  inet:setopts(Sock, [{active, once}]);
	      {SockMod, Sock} ->
		  SockMod:setopts(Sock, [{active, once}])
	  end,
    check_sock_result(Socket, Ret).

close({websocket, ConnPid}) ->
    gun:close(ConnPid);
close({SockMod, Sock}) ->
    SockMod:close(Sock).

format_error({dns, Reason}) ->
    format("DNS lookup failed: ~s", [format_inet_error(Reason)]);
format_error({tls, Reason}) ->
    format("TLS failed: ~s", [format_tls_error(Reason)]);
format_error({socket, Reason}) ->
    format("Connection failed: ~s", [format_inet_error(Reason)]).

lookup(Addrs, Time) ->
    Addrs1 = lists:flatmap(
	       fun(#endpoint{address = Addr} = EndPoint) when is_tuple(Addr) ->
		       [{EndPoint, get_addr_type(Addr)}];
		  (EndPoint) ->
		       [{EndPoint, inet6}, {EndPoint, inet}]
	       end, Addrs),
    do_lookup(Addrs1, Time, [], nxdomain).

do_lookup([{#endpoint{address = IP}, _} = Addr|Addrs], Time, Res, Err) when is_tuple(IP) ->
    do_lookup(Addrs, Time, [Addr|Res], Err);
do_lookup([{#endpoint{address = Host} = EndPoint, Family}|Addrs], Time, Res, Err) ->
    Timeout = min(?DNS_TIMEOUT, max(0, Time - current_time())),
    case inet:gethostbyname(Host, Family, Timeout) of
        {ok, HostEntry} ->
            Addrs1 = host_entry_to_addrs(HostEntry),
            Addrs2 = [{EndPoint#endpoint{address = Addr}, Family} || Addr <- Addrs1],
            do_lookup(Addrs, Time, Addrs2 ++ Res, Err);
        {error, Why} ->
            do_lookup(Addrs, Time, Res, Why)
    end;
do_lookup([], _Timeout, [], Err) ->
    {error, {dns, Err}};
do_lookup([], _Timeout, Res, _Err) ->
    {ok, Res}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec check_sock_result(socket(), ok | {error, inet:posix()}) -> ok.
check_sock_result(_, ok) ->
    ok;
check_sock_result({_, Sock}, {error, Why}) ->
    self() ! {tcp_closed, Sock},
    lager:debug("MQTT socket error: ~p", [format_inet_error(Why)]).

host_entry_to_addrs(#hostent{h_addr_list = AddrList}) ->
    lists:filter(
      fun(Addr) ->
              try get_addr_type(Addr) of
                  _ -> true
              catch _:badarg ->
                      false
              end
      end, AddrList).

get_addr_type({_, _, _, _}) -> inet;
get_addr_type({_, _, _, _, _, _, _, _}) -> inet6;
get_addr_type(_) -> erlang:error(badarg).

current_time() ->
    p1_time_compat:monotonic_time(milli_seconds).

transport(ws) -> tcp;
transport(wss) -> tls.

sockopts(Family, Opts) ->
    [{active, once},
     {packet, raw},
     {send_timeout, ?TCP_SEND_TIMEOUT},
     {send_timeout_close, true},
     binary, Family|Opts].

prep_error({shutdown, Reason}) ->
    Reason;
prep_error(Reason) ->
    Reason.

format_inet_error(closed) ->
    "connection closed";
format_inet_error(timeout) ->
    format_inet_error(etimedout);
format_inet_error(Reason) when is_atom(Reason) ->
    case inet:format_error(Reason) of
	"unknown POSIX error" -> atom_to_list(Reason);
	Txt -> Txt
    end;
format_inet_error(Reason) ->
    lists:flatten(io_lib:format("unexpected error: ~p", [Reason])).

format_tls_error(no_cerfile) ->
    "certificate not found";
format_tls_error(Reason) when is_atom(Reason) ->
    format_inet_error(Reason);
format_tls_error(Reason) ->
    Reason.

-spec format(io:format(), list()) -> string().
format(Fmt, Args) ->
    lists:flatten(io_lib:format(Fmt, Args)).
