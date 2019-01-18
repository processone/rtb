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
-module(mod_xmpp_proxy65).
-compile([{parse_transform, lager_transform}]).
-behaviour(gen_server).

%% API
-export([recv/6, connect/6, activate/1, format_error/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(BUF_SIZE, 65536).
%%-define(BUF_SIZE, 8192).
%% SOCKS5 stuff
-define(VERSION_5, 5).
-define(AUTH_ANONYMOUS, 0).
-define(CMD_CONNECT, 1).
-define(ATYP_DOMAINNAME, 3).
-define(SUCCESS, 0).

-type sockmod() :: gen_tcp | ssl.
-type socket() :: gen_tcp:socket() | ssl:sslsocket().
-type proxy65_error() :: {socks5, atom()} | {sockmod(), atom()} |
			 crashed | shutdown | init_timeout |
			 activation_timeout.

-record(state, {host    :: string(),
		port    :: inet:port_number(),
		hash    :: binary(),
		sockmod :: sockmod(),
		socket  :: socket(),
		opts    :: [gen_tcp:option()],
		timeout :: non_neg_integer(),
		size    :: non_neg_integer(),
		owner   :: pid(),
		action  :: send | recv}).

%%%===================================================================
%%% API
%%%===================================================================
recv(Host, Port, Hash, Size, ConnOpts, Timeout) ->
    start(recv, Host, Port, Hash, Size, ConnOpts, Timeout).

connect(Host, Port, Hash, Size, ConnOpts, Timeout) ->
    start(send, Host, Port, Hash, Size, ConnOpts, Timeout).

activate(Pid) ->
    gen_server:cast(Pid, activate).

-spec format_error(proxy65_error()) -> string().
format_error({socks5, unexpected_response}) ->
    "Proxy65 failure: unexpected SOCKS5 response";
format_error(crashed) ->
    "Proxy65 failure: connection has been crashed";
format_error(shutdown) ->
    "Proxy65 failure: the system is shutting down";
format_error(init_timeout) ->
    "Proxy65 failure: timed out during initialization";
format_error(activation_timeout) ->
    "Proxy65 failure: timed out waiting for activation";
format_error(Reason) ->
    "Proxy65 failure: " ++ format_socket_error(Reason).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Action, Owner, Host, Port, Hash, Size, ConnOpts, Timeout]) ->
    erlang:monitor(process, Owner),
    {ok, #state{host = Host, port = Port, hash = Hash,
		action = Action, size = Size, opts = ConnOpts,
		owner = Owner, timeout = Timeout}, Timeout}.

handle_call(connect, From, #state{host = Host, port = Port,
				  opts = ConnOpts, action = Action,
				  hash = Hash, timeout = Timeout,
				  size = Size} = State) ->
    case connect(Host, Port, Hash, ConnOpts, Timeout) of
	{ok, SockMod, Sock} ->
	    State1 = State#state{sockmod = SockMod, socket = Sock},
	    gen_server:reply(From, {ok, self()}),
	    case Action of
		recv ->
		    Result = recv(SockMod, Sock, Size, Timeout),
		    reply(State1, Result),
		    {stop, normal, State1};
		send ->
		    noreply(State1)
	    end;
	{error, _} = Err ->
	    {stop, normal, Err, State}
    end;
handle_call(Request, _From, State) ->
    lager:warning("Unexpected call: ~p", [Request]),
    noreply(State).

handle_cast(activate, #state{sockmod = SockMod, socket = Sock,
			     size = Size} = State) ->
    Chunk = p1_rand:bytes(?BUF_SIZE),
    Result = send(SockMod, Sock, Size, Chunk),
    reply(State, Result),
    {stop, normal, State};
handle_cast(Msg, State) ->
    lager:warning("Unexpected cast: ~p", [Msg]),
    noreply(State).

handle_info({'DOWN',  _,  _,  _,  _}, State) ->
    {stop, normal, State};
handle_info(timeout, State) ->
    Reason = case State#state.socket of
		 undefined -> init_timeout;
		 _ -> activation_timeout
	     end,
    reply(State, {error, Reason}),
    {stop, normal, State};
handle_info(Info, State) ->
    lager:warning("Unexpected info: ~p", [Info]),
    noreply(State).

terminate(normal, _) ->
    ok;
terminate(shutdown, State) ->
    reply(State, {error, shutdown});
terminate(_, State) ->
    reply(State, {error, crashed}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start(Action, Host, Port, Hash, Size, ConnOpts, Timeout) ->
    case gen_server:start(
	   ?MODULE,
	   [Action, self(), binary_to_list(Host), Port,
	    Hash, Size, ConnOpts, Timeout], []) of
	{ok, Pid} ->
	    gen_server:call(Pid, connect, 2*Timeout);
	{error, _} ->
	    {error, crashed}
    end.

-spec format_socket_error({sockmod(), atom()}) -> string().
format_socket_error({_, closed}) ->
    "connection closed";
format_socket_error({_, timeout}) ->
    inet:format_error(etimedout);
format_socket_error({ssl, Reason}) ->
    ssl:format_error(Reason);
format_socket_error({gen_tcp, Reason}) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" -> atom_to_list(Reason);
        Txt -> Txt
    end.

reply(#state{owner = Owner, action = Action}, Result) ->
    Owner ! {proxy65_result, Action, Result}.

noreply(#state{timeout = Timeout} = State) ->
    {noreply, State, Timeout}.

connect(Host, Port, Hash, ConnOpts, Timeout) ->
    Opts = opts(ConnOpts, Timeout),
    SockMod = gen_tcp,
    try
	{ok, Sock} = SockMod:connect(Host, Port, Opts, Timeout),
	Init = <<?VERSION_5, 1, ?AUTH_ANONYMOUS>>,
	InitAck = <<?VERSION_5, ?AUTH_ANONYMOUS>>,
	Req = <<?VERSION_5, ?CMD_CONNECT, 0,
		?ATYP_DOMAINNAME, 40, Hash:40/binary, 0, 0>>,
	Resp = <<?VERSION_5, ?SUCCESS, 0, ?ATYP_DOMAINNAME,
		 40, Hash:40/binary, 0, 0>>,
	ok = SockMod:send(Sock, Init),
	{ok, InitAck} = gen_tcp:recv(Sock, size(InitAck)),
	ok = gen_tcp:send(Sock, Req),
	{ok, Resp} = gen_tcp:recv(Sock, size(Resp)),
	{ok, SockMod, Sock}
    catch _:{badmatch, {error, Reason}} ->
	    {error, {SockMod, Reason}};
	  _:{badmatch, {ok, _}} ->
	    {error, {socks5, unexpected_response}}
    end.

send(_SockMod, _Sock, 0, _Chunk) ->
    ok;
send(SockMod, Sock, Size, Chunk) ->
    Data = if Size >= ?BUF_SIZE ->
		   Chunk;
	      true ->
		   binary:part(Chunk, 0, Size)
	   end,
    case SockMod:send(Sock, Data) of
	ok ->
	    NewSize = receive {'DOWN',  _,  _,  _,  _} -> 0
	     	      after 0 -> Size - min(Size, ?BUF_SIZE)
		      end,
	    send(SockMod, Sock, NewSize, Chunk);
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

recv(_SockMod, _Sock, 0, _Timeout) ->
    ok;
recv(SockMod, Sock, Size, Timeout) ->
    ChunkSize = min(Size, ?BUF_SIZE),
    case SockMod:recv(Sock, ChunkSize, Timeout) of
	{ok, Data} ->
	    NewSize = receive {'DOWN',  _,  _,  _,  _} -> 0
	     	      after 0 -> Size-size(Data)
		      end,
	    recv(SockMod, Sock, NewSize, Timeout);
	{error, Reason} ->
	    {error, {SockMod, Reason}}
    end.

opts(Opts, Timeout) ->
    [binary,
     {packet, 0},
     {send_timeout, Timeout},
     {send_timeout_close, true},
     {recbuf, ?BUF_SIZE},
     {sndbuf, ?BUF_SIZE},
     {active, false}|Opts].
