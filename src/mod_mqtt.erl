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
-module(mod_mqtt).
-compile([{parse_transform, lager_transform}]).
-behaviour(p1_fsm).
-behaviour(rtb).

%% API
-export([load/0, start/4, options/0, prep_option/2, stats/0]).
%% p1_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
	 terminate/3, code_change/4]).
%% p1_fsm state names
-export([connecting/2, connecting/3,
	 waiting_for_connack/2, waiting_for_connack/3,
	 session_established/2, session_established/3,
	 disconnected/2, disconnected/3]).
%% Scheduled actions
-export([disconnect/2, publish/2]).

-include("mod_mqtt.hrl").
-include_lib("kernel/include/inet.hrl").

-record(state, {version          :: mqtt_version(),
                username         :: binary(),
		password         :: binary(),
		timeout          :: infinity | integer(),
                keep_alive       :: seconds(),
		client_id        :: binary(),
		socket           :: undefined | {sockmod(), socket()},
		codec            :: mod_mqtt_codec:state(),
		pingreq          :: undefined | pingreq(),
		clean_session    :: boolean(),
		id = 0           :: non_neg_integer(),
		in_flight        :: undefined | in_flight_packet(),
		conn_id          :: integer(),
		conn_opts        :: [gen_tcp:option()],
		conn_addrs       :: [{server(), inet:port_number(), boolean()}],
		stop_reason      :: undefined | error_reason(),
		just_started     :: boolean(),
                subscribed       :: boolean(),
		reconnect_after  :: undefined | {integer(), integer()},
		disconnect_timer :: undefined | reference(),
		publish_timer    :: undefined | reference(),
		acks = #{}       :: map(),
		queue            :: p1_queue:queue()}).

-type state() :: #state{}.
-type server() :: inet:hostname() | inet:ip_address().
-type sockmod() :: gen_tcp | fast_tls.
-type socket() :: inet:socket() | fast_tls:tls_socket().
-type seconds() :: non_neg_integer().
-type milli_seconds() :: non_neg_integer().
-type in_flight_packet() :: subscribe() | unsubscribe() | publish() | pubrel().
-type socket_error_reason() :: closed | timeout | inet:posix().
-type error_reason() :: {disconnected, reason_code(), binary()} |
                        {auth, reason_code(), binary()} |
			{socket, socket_error_reason()} |
			{dns, inet:posix() | inet_res:res_error()} |
			{codec, mod_mqtt_codec:error_reason()} |
			{unexpected_packet, atom()} |
			{tls, inet:posix() | atom() | binary()} |
			internal_server_error | timeout | ping_timeout |
			queue_full | disconnected | shutdown |
                        subscribe_failure.

-define(DNS_TIMEOUT, timer:seconds(5)).
-define(TCP_SEND_TIMEOUT, timer:seconds(15)).

%%%===================================================================
%%% API
%%%===================================================================
load() ->
    case application:ensure_all_started(fast_tls) of
	{ok, _} ->
            ets:new(rtb_tracker, [named_table, public]),
            ok;
	Err ->
            Err
    end.

start(I, Opts, Servers, JustStarted) ->
    p1_fsm:start(?MODULE, [I, Opts, Servers, JustStarted], []).

options() ->
    [{keep_alive, 60},
     {disconnect_interval, 600},
     {reconnect_interval, 60},
     {publish_interval, 600},
     {username, <<>>},
     {password, <<>>},
     {will, []},
     {publish, []},
     {subscribe, []},
     {clean_session, false},
     {protocol_version, 4},
     {track_publish_delivery, false},
     %% Required options
     servers,
     client_id].

prep_option(client_id, <<_, _/binary>> = Val) ->
    {client_id, rtb:make_pattern(Val)};
prep_option(username, Val) when is_binary(Val) ->
    {username, rtb:make_pattern(Val)};
prep_option(password, Val) when is_binary(Val) ->
    {password, rtb:make_pattern(Val)};
prep_option(servers, Val) ->
    rtb_config:prep_option(servers, Val);
prep_option(clean_session, Val) ->
    {clean_session, rtb_config:to_bool(Val)};
prep_option(will, L) ->
    {will, lists:map(fun prep_publish_opt/1, L)};
prep_option(publish, L) ->
    {publish, lists:map(fun prep_publish_opt/1, L)};
prep_option(subscribe, L) ->
    {subscribe,
     lists:map(
       fun({TF, QoS}) ->
	       try {rtb:make_pattern(mod_mqtt_codec:topic_filter(TF)),
		    mod_mqtt_codec:qos(QoS)}
	       catch _:{_, bad_qos} ->
		       rtb_config:fail_bad_val("QoS", QoS);
		     _:_ ->
		       rtb_config:fail_bad_val("topic filter", TF)
	       end
       end, L)};
prep_option(Opt, I) when is_integer(I) andalso I>0 andalso
			 (Opt == reconnect_interval orelse
			  Opt == disconnect_interval orelse
			  Opt == publish_interval orelse
			  Opt == keep_alive) ->
    {Opt, I};
prep_option(Opt, Val) when Opt == reconnect_interval;
			   Opt == disconnect_interval;
			   Opt == publish_interval ->
    case rtb_config:to_bool(Val) of
	false -> {Opt, false}
    end;
prep_option(protocol_version, V) when V=:=4; V==5 ->
    {protocol_version, trunc(V)};
prep_option(protocol_version, V) ->
    Parts = [binary_to_integer(Part)
             || Part <- binary:split(V, <<".">>, [global])],
    case Parts of
        [3,1,1] -> {protocol_version, 4};
        [5,0,0] -> {protocol_version, 5}
    end;
prep_option(track_publish_delivery, Val) ->
    {track_publish_delivery,
     case rtb_config:to_bool(Val) of
         true ->
             case rtb_config:get_option(protocol_version) of
                 5 -> true;
                 _ ->
                     lager:critical("Option 'track_publish_delivery' is only "
                                    "available for MQTT 5.0: you should've "
                                    "set 'protocol_version: 5'"),
                     erlang:error(badarg)
             end;
         false ->
             false
     end}.

stats() ->
    [{'sessions', fun(_) -> rtb_sm:size() end},
     {'connections', fun rtb_stats:lookup/1},
     {'publish-in', fun rtb_stats:lookup/1},
     {'publish-out', fun rtb_stats:lookup/1},
     {'publish-loss', fun(_) -> ets:info(rtb_tracker, size) end},
     {'errors', fun rtb_stats:lookup/1}].

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================
init([I, Opts, Servers, JustStarted]) ->
    {User, ClientID, Password} = make_login(I, true),
    KeepAlive = rtb_config:get_option(keep_alive),
    Timeout = timer:seconds(KeepAlive),
    ReconnectAfter = case rtb_config:get_option(reconnect_interval) of
			 false -> undefined;
			 Secs -> {random_interval(Secs), 1}
		     end,
    CleanSession = rtb_config:get_option(clean_session),
    Version = rtb_config:get_option(protocol_version),
    State = #state{version = Version,
                   username = User,
		   client_id = ClientID,
		   password = Password,
		   conn_id = I,
		   conn_opts = Opts,
		   conn_addrs = Servers,
		   reconnect_after = ReconnectAfter,
		   clean_session = CleanSession,
		   just_started = JustStarted,
                   keep_alive = KeepAlive,
                   subscribed = false,
		   id = p1_rand:uniform(65535),
		   queue = p1_queue:new(ram, 100),
		   codec = mod_mqtt_codec:new(infinity, Version),
		   timeout = current_time() + Timeout},
    p1_fsm:send_event(self(), connect),
    {ok, connecting, State, Timeout}.

connecting(connect, State) ->
    case connect(State) of
	{ok, State1} ->
            rtb_stats:incr('connections'),
            SessionExpiry = get_session_expiry(State1),
	    Pkt = #connect{
                     proto_level = State1#state.version,
                     keep_alive = rtb_config:get_option(keep_alive),
                     will = make_publish(will, State1),
                     clean_session = State1#state.clean_session,
                     client_id = State1#state.client_id,
                     username = State1#state.username,
                     password = State1#state.password,
                     properties = #{session_expiry_interval => SessionExpiry,
                                    request_response_information => true}},
	    case send(connecting, State1, Pkt) of
		{ok, State2} ->
		    next_state(waiting_for_connack, State2);
		{error, State2, Reason} ->
		    stop(connecting, State2, Reason)
	    end;
	{error, Reason} ->
	    stop(connecting, State, Reason)
    end;
connecting(timeout, State) ->
    stop(connecting, State, timeout);
connecting(Event, State) ->
    handle_event(Event, connecting, State).

connecting(Event, From, State) ->
    handle_sync_event(Event, From, connecting, State).

waiting_for_connack(timeout, State) ->
    stop(waiting_for_connack, State, timeout);
waiting_for_connack(Event, State) ->
    handle_event(Event, waiting_for_connack, State).

waiting_for_connack(Event, From, State) ->
    handle_sync_event(Event, From, waiting_for_connack, State).

session_established(timeout, #state{pingreq = undefined} = State) ->
    Ping = attach_timestamp(#pingreq{}),
    case send(session_established, State, Ping) of
	{ok, State1} ->
	    State2 = State1#state{pingreq = Ping},
	    next_state(session_established, State2);
	{error, State1, Reason} ->
	    stop(session_established, State1, Reason)
    end;
session_established(timeout, State) ->
    stop(session_established, State, ping_timeout);
session_established(Event, State) ->
    handle_event(Event, session_established, State).

session_established(Event, From, State) ->
    handle_sync_event(Event, From, session_established, State).

disconnected(timeout, State) ->
    State1 = State#state{stop_reason = undefined},
    State2 = reset_keep_alive(State1),
    connecting(connect, State2);
disconnected(Event, State) ->
    handle_event(Event, disconnected, State).

disconnected(Event, From, State) ->
    handle_sync_event(Event, From, disconnected, State).

handle_event(Event, StateName, State) ->
    lager:warning("Unexpected event in state ~s: ~p", [StateName, Event]),
    next_state(StateName, State).

handle_sync_event(Event, From, StateName, State) ->
    lager:warning("Unexpected call from ~p in state ~s: ~p",
		  [From, StateName, Event]),
    next_state(StateName, State).

handle_info({tcp, TCPSock, TCPData}, StateName,
	    #state{codec = Codec, socket = {_, _} = Socket} = State) ->
    case recv_data(Socket, TCPData) of
	{ok, Data} ->
	    case mod_mqtt_codec:decode(Codec, Data) of
		{ok, Pkt, Codec1} ->
		    lager:debug("Got MQTT packet:~n~s", [pp(Pkt)]),
		    State1 = State#state{codec = Codec1},
		    case handle_packet(Pkt, StateName, State1) of
			{ok, State2} ->
			    handle_info({tcp, TCPSock, <<>>},
					session_established, State2);
			{error, State2, Reason} ->
			    stop(StateName, State2, Reason)
		    end;
		{more, Codec1} ->
		    State1 = State#state{codec = Codec1},
		    activate(State1),
		    next_state(StateName, State1);
		{error, Why} ->
		    stop(StateName, State, {codec, Why})
	    end;
	{error, Why} ->
	    stop(StateName, State, Why)
    end;
handle_info({tcp, _, _}, StateName, State) ->
    next_state(StateName, State);
handle_info({tcp_closed, _Sock}, StateName, State) ->
    stop(StateName, State, {socket, closed});
handle_info({tcp_error, _Sock, Reason}, StateName, State) ->
    stop(StateName, State, {socket, Reason});
handle_info({timeout, Ref, {Action, _, Pos} = Msg}, StateName, State)
  when element(Pos, State) == Ref ->
    State1 = setelement(Pos, State, undefined),
    case ?MODULE:Action(StateName, State1) of
	{ok, State2} ->
	    State3 = schedule(Msg, State2, false),
	    next_state(StateName, State3);
	{error, State2, Reason} ->
	    stop(StateName, State2, Reason)
    end;
handle_info({timeout, _, {_, _, _}}, StateName, State) ->
    %% Late arrival of a cancelled timer
    next_state(StateName, State);
handle_info({Ref, badarg}, StateName, State) when is_reference(Ref) ->
    %% TODO: figure out from where this message comes from
    next_state(StateName, State);
handle_info(Info, StateName, State) ->
    lager:warning("Unexpected info:~n~p~n** in state ~s:~n~s",
		  [Info, StateName, pp(State)]),
    next_state(StateName, State).

handle_packet(#disconnect{} = Pkt, _StateName,
              #state{version = ?MQTT_VERSION_5} = State) ->
    Reason = maps:get(reason_string, Pkt#disconnect.properties, <<>>),
    {error, State, {disconnected, Pkt#disconnect.code, Reason}};
handle_packet(#connack{} = Pkt, waiting_for_connack, State) ->
    case Pkt#connack.code of
	success ->
            CleanSession = rtb_config:get_option(clean_session),
            KeepAlive = maps:get(server_keep_alive, Pkt#connack.properties,
                                 rtb_config:get_option(keep_alive)),
	    State1 = State#state{clean_session = CleanSession,
                                 keep_alive = KeepAlive},
            State2 = case Pkt#connack.session_present of
                         false ->
                             Q = p1_queue:clear(State1#state.queue),
                             State1#state{queue = Q,
                                          acks = #{},
                                          subscribed = false,
                                          in_flight = undefined};
                         true ->
                             State1
                     end,
            subscribe(State2);
	Code ->
            Reason = maps:get(reason_string, Pkt#connack.properties, <<>>),
	    {error, State, {auth, Code, Reason}}
    end;
handle_packet(Pkt, StateName, State) when StateName /= session_established ->
    handle_unexpected_packet(Pkt, StateName, State);
handle_packet(#suback{id = ID, codes = Codes} = Pkt, StateName,
	      #state{in_flight = #subscribe{id = ID} = Sub} = State) ->
    rtb_stats:incr({'subscribe-rtt', calc_rtt(Sub)}),
    State1 = State#state{in_flight = undefined},
    case [QoS || {_, #sub_opts{qos = QoS}} <- Sub#subscribe.filters] of
        Codes ->
            State2 = case State1#state.subscribed of
                         true -> State1;
                         false -> register_session(State1)
                     end,
            resend(State2#state{subscribed = true});
        _ ->
            handle_error_packet(Pkt, StateName, State1)
    end;
handle_packet(#suback{} = Pkt, StateName, State) ->
    handle_ignored_packet(Pkt, StateName, State);
handle_packet(#unsuback{id = ID, codes = Codes} = Pkt, StateName,
	      #state{in_flight = #unsubscribe{id = ID} = UnSub} = State) ->
    rtb_stats:incr({'unsubscribe-rtt', calc_rtt(UnSub)}),
    State1 = State#state{in_flight = undefined},
    case lists:any(fun mod_mqtt_codec:is_error_code/1, Codes) of
        true -> handle_error_packet(Pkt, StateName, State1);
        false -> resend(State1)
    end;
handle_packet(#unsuback{} = Pkt, StateName, State) ->
    handle_ignored_packet(Pkt, StateName, State);
handle_packet(#puback{id = ID, code = Code} = Pkt, StateName,
	      #state{in_flight = #publish{id = ID, qos = 1} = Pub} = State) ->
    rtb_stats:incr({'publish-rtt', calc_rtt(Pub)}),
    State1 = State#state{in_flight = undefined},
    case mod_mqtt_codec:is_error_code(Code) of
        true -> handle_error_packet(Pkt, StateName, State1);
        false -> resend(State1)
    end;
handle_packet(#puback{} = Pkt, StateName, State) ->
    handle_ignored_packet(Pkt, StateName, State);
handle_packet(#pubrec{id = ID, code = Code} = Pkt, StateName,
	      #state{in_flight = #publish{id = ID, qos = 2} = Pub} = State) ->
    case mod_mqtt_codec:is_error_code(Code) of
        true ->
            rtb_stats:incr({'publish-rtt', calc_rtt(Pub)}),
            State1 = State#state{in_flight = undefined},
            handle_error_packet(Pkt, StateName, State1);
        false ->
            Pubrel = #pubrel{id = ID, meta = Pub#publish.meta},
            State1 = State#state{in_flight = Pubrel},
            send(StateName, State1, Pubrel)
    end;
handle_packet(#pubrec{id = ID}, StateName, State) ->
    lager:warning("Got unexpected PUBREC with id=~B, "
                  "sending PUBREL with error reason code", [ID]),
    Pubrel = #pubrel{id = ID, code = 'packet-identifier-not-found'},
    send(StateName, State, Pubrel);
handle_packet(#pubcomp{id = ID, code = Code} = Pkt, StateName,
              #state{in_flight = #pubrel{id = ID} = Pubrel} = State) ->
    rtb_stats:incr({'publish-rtt', calc_rtt(Pubrel)}),
    State1 = State#state{in_flight = undefined},
    case mod_mqtt_codec:is_error_code(Code) of
        true -> handle_error_packet(Pkt, StateName, State1);
        false -> resend(State1)
    end;
handle_packet(#pubcomp{} = Pkt, StateName, State) ->
    handle_ignored_packet(Pkt, StateName, State);
handle_packet(#publish{qos = 0} = Pkt, _StateName, State) ->
    rtb_stats:incr('publish-in'),
    stop_tracking(Pkt),
    {ok, State};
handle_packet(#publish{qos = 1, id = ID} = Pkt, StateName, State) ->
    rtb_stats:incr('publish-in'),
    stop_tracking(Pkt),
    send(StateName, State, #puback{id = ID});
handle_packet(#publish{qos = 2, id = ID} = Pkt, StateName, State) ->
    State1 = case maps:is_key(ID, State#state.acks) of
		 true -> State;
		 false ->
		     rtb_stats:incr('publish-in'),
                     stop_tracking(Pkt),
		     Acks = maps:put(ID, true, State#state.acks),
		     State#state{acks = Acks}
	     end,
    send(StateName, State1, #pubrec{id = ID});
handle_packet(#pubrel{id = ID}, StateName, State) ->
    case maps:take(ID, State#state.acks) of
        {_, Acks} ->
            State1 = State#state{acks = Acks},
            send(StateName, State1, #pubcomp{id = ID});
        error ->
            lager:warning("Got unexpected PUBREL with id=~B, "
                          "sending PUBCOMP with error reason code", [ID]),
            Pubcomp = #pubcomp{id = ID, code = 'packet-identifier-not-found'},
            send(StateName, State, Pubcomp)
    end;
handle_packet(#pingresp{}, _StateName,
              #state{pingreq = #pingreq{} = Ping} = State) ->
    rtb_stats:incr({'ping-rtt', calc_rtt(Ping)}),
    {ok, State#state{pingreq = undefined}};
handle_packet(Pkt, StateName, State) ->
    handle_unexpected_packet(Pkt, StateName, State).

handle_unexpected_packet(Pkt, StateName, State) ->
    lager:warning("Unexpected packet:~n~s~n** in state ~s:~n~s",
		  [pp(Pkt), StateName, pp(State)]),
    {error, State, {unexpected_packet, element(1, Pkt)}}.

handle_error_packet(Pkt, StateName, State) ->
    lager:warning("Got packet with error code(s):~n~s~n** in state ~s:~n~s",
		  [pp(Pkt), StateName, pp(State)]),
    case Pkt of
        #suback{} ->
            {error, State, subscribe_failure};
        _ ->
            {ok, State}
    end.

handle_ignored_packet(Pkt, StateName, State) ->
    lager:warning("Ignoring unexpected packet:~n~s~n** in state ~s:~n~s",
                  [pp(Pkt), StateName, pp(State)]),
    {ok, State}.

terminate(Reason, _StateName, State) ->
    rtb_sm:unregister(State#state.conn_id),
    Why = case Reason of
	      shutdown -> shutdown;
	      normal -> State#state.stop_reason;
	      _ -> internal_server_error
	  end,
    close_socket(State#state.socket, Why),
    lager:debug("Connection #~B closed: ~s",
                [State#state.conn_id, format_error(Why)]).

code_change(_OldVsn, StateName, State, _Extra) ->
    {_, StateName1, State1, Timeout} = next_state(StateName, State),
    {ok, StateName1, State1, Timeout}.

%%%===================================================================
%%% Internal functions: scheduled actions
%%%===================================================================
disconnect(_StateName, State) ->
    {error, State, disconnected}.

publish(StateName, State) ->
    case make_publish(publish, State) of
	#publish{} = Pkt ->
	    send(StateName, State, Pkt);
	undefined ->
	    {ok, State}
    end.

%%%===================================================================
%%% Internal functions: misc
%%%===================================================================
next_state(StateName, #state{timeout = infinity} = State) ->
    {next_state, StateName, State, infinity};
next_state(StateName, #state{timeout = Time} = State) ->
    Timeout = max(0, Time - current_time()),
    {next_state, StateName, State, Timeout}.

stop(_StateName, #state{just_started = true}, Reason) ->
    rtb:halt("~s", [format_error(Reason)]);
stop(StateName, #state{reconnect_after = undefined} = State, Reason) ->
    unregister_session(StateName, State, Reason),
    {stop, normal, State#state{stop_reason = Reason}};
stop(disconnected, State, _Reason) ->
    next_state(disconnected, State);
stop(StateName, State, Reason) ->
    lager:debug("Session #~B closed: ~s",
		[State#state.conn_id, format_error(Reason)]),
    unregister_session(StateName, State, Reason),
    State1 = close_socket(State, Reason),
    {Timeout, Factor} = State1#state.reconnect_after,
    rtb:cancel_timer(State1#state.disconnect_timer),
    State2 = State1#state{disconnect_timer = undefined,
                          conn_addrs = rtb:random_server(),
                          pingreq = undefined,
                          stop_reason = Reason,
                          codec = mod_mqtt_codec:renew(State1#state.codec),
                          reconnect_after = {Timeout, Factor*2}},
    State3 = set_timeout(State2, Timeout*Factor),
    next_state(disconnected, State3).

register_session(State) ->
    ReconnectAfter = case State#state.reconnect_after of
                         {Timeout, _} -> {Timeout, 1};
                         undefined -> undefined
                     end,
    State1 = schedule_all_actions(State),
    rtb_sm:register(State1#state.conn_id, self(),
		    {State1#state.username,
		     State1#state.client_id}),
    State1#state{just_started = false,
                 reconnect_after = ReconnectAfter}.

unregister_session(StateName, _State, Reason) ->
    case Reason of
	disconnected ->
	    ok;
	_ ->
	    rtb_stats:incr('errors'),
	    rtb_stats:incr({'error-reason', {Reason, StateName}})
    end.

subscribe(#state{subscribed = true} = State) ->
    State1 = register_session(State),
    resend(State1);
subscribe(State) ->
    case make_subscribe(State) of
        undefined ->
            State1 = register_session(State#state{subscribed = true}),
            resend(State1);
        Pkt ->
            case State#state.in_flight of
                #subscribe{} ->
                    resend(State);
                undefined ->
                    send(session_established, State, Pkt)
            end
    end.

send(StateName, State, Pkt) when is_record(Pkt, subscribe) orelse
				 is_record(Pkt, unsubscribe) orelse
				 is_record(Pkt, publish) ->
    ID = next_id(State#state.id),
    Pkt1 = set_id(Pkt, ID),
    case StateName == session_established andalso
	 State#state.in_flight == undefined andalso
	 p1_queue:is_empty(State#state.queue) of
	true ->
	    InFlight = case Pkt1 of
                           #publish{qos = 0} -> undefined;
                           _ -> attach_timestamp(Pkt1)
                       end,
	    State1 = State#state{id = ID, in_flight = InFlight},
	    {ok, send(State1, Pkt1)};
	false ->
	    try p1_queue:in(Pkt1, State#state.queue) of
		Q ->
		    State1 = State#state{id = ID, queue = Q},
		    {ok, State1}
	    catch error:full ->
		    Q = p1_queue:clear(State#state.queue),
		    State1 = State#state{queue = Q},
		    {error, State1, queue_full}
	    end
    end;
send(_StateName, State, Pkt) ->
    {ok, send(State, Pkt)}.

resend(#state{in_flight = undefined} = State) ->
    case p1_queue:out(State#state.queue) of
	{{value, #publish{qos = 0} = Pkt}, Q} ->
	    State1 = send(State#state{queue = Q}, Pkt),
	    resend(State1);
	{{value, Pkt}, Q} ->
            InFlight = attach_timestamp(Pkt),
	    State1 = State#state{in_flight = InFlight, queue = Q},
	    {ok, send(State1, Pkt)};
	{empty, _} ->
	    {ok, State}
    end;
resend(#state{in_flight = Pkt} = State) ->
    {ok, send(State, set_dup_flag(Pkt))}.

send(#state{socket = {SockMod, Sock} = Socket} = State, Pkt) ->
    Pkt1 = case Pkt of
               #publish{dup = false} ->
                   rtb_stats:incr('publish-out'),
                   start_tracking(Pkt);
               _ ->
                   Pkt
           end,
    lager:debug("Send MQTT packet:~n~s", [pp(Pkt1)]),
    Data = mod_mqtt_codec:encode(State#state.version, Pkt1),
    Res = SockMod:send(Sock, Data),
    check_sock_result(Socket, Res),
    reset_keep_alive(State);
send(State, _) ->
    State.

-spec start_tracking(publish()) -> publish().
start_tracking(Pkt) ->
    case rtb_config:get_option(track_publish_delivery) of
        false -> Pkt;
        true ->
            ID = p1_time_compat:unique_integer([positive]),
            Props = #{user_property => [{<<"id">>, integer_to_binary(ID)}]},
            ets:insert(rtb_tracker, {ID, Pkt#publish.topic}),
            Pkt#publish{properties = Props}
    end.

-spec stop_tracking(publish()) -> boolean().
stop_tracking(#publish{properties = #{user_property := Props}}) ->
    ID = binary_to_integer(proplists:get_value(<<"id">>, Props)),
    ets:delete(rtb_tracker, ID);
stop_tracking(_) ->
    false.

activate(#state{socket = {SockMod, Sock} = Socket}) ->
    Res = case SockMod of
	      gen_tcp -> inet:setopts(Sock, [{active, once}]);
	      _ -> SockMod:setopts(Sock, [{active, once}])
	  end,
    check_sock_result(Socket, Res);
activate(_State) ->
    ok.

-spec close_socket(state(), error_reason()) -> state().
close_socket(#state{socket = {SockMod, Sock}} = State, Err) ->
    rtb_stats:decr('connections'),
    State1 = case Err of
                 {Tag, _} when Tag == socket; Tag == dns; Tag == tls ->
                     State;
                 {Tag, _, _} when Tag == auth; Tag == disconnected ->
                     State;
                 _ ->
                     Code = disconnect_reason_code(Err),
                     Reason = format_error(Err),
                     Props = #{reason_string => list_to_binary(Reason)},
                     Props1 = case Err of
                                  shutdown ->
                                      Props#{session_expiry_interval => 0};
                                  _ ->
                                      Props
                              end,
                     Pkt = #disconnect{code = Code, properties = Props1},
                     send(State, Pkt)
             end,
    SockMod:close(Sock),
    State1#state{socket = undefined};
close_socket(State, _) ->
    State.

-spec check_sock_result(socket(), ok | {error, inet:posix()}) -> ok.
check_sock_result(_, ok) ->
    ok;
check_sock_result({_, Sock}, {error, Why}) ->
    self() ! {tcp_closed, Sock},
    lager:debug("MQTT socket error: ~p", [format_inet_error(Why)]).

-spec recv_data(socket(), binary()) -> {ok, binary()} | {error, error_reason()}.
recv_data({fast_tls, Sock}, Data) when Data /= <<>> ->
    case fast_tls:recv_data(Sock, Data) of
	{ok, _} = OK -> OK;
	{error, Reason} when is_atom(Reason) -> {error, {socket, Reason}};
	{error, _} = Err -> Err
    end;
recv_data(_, Data) ->
    {ok, Data}.

-spec make_login(integer(), boolean()) -> {binary(), binary()} |
					  {binary(), binary(), binary()}.
make_login(I, WithPassword) ->
    User = rtb:replace(rtb_config:get_option(username), I),
    ClientID = rtb:replace(rtb_config:get_option(client_id), I),
    if WithPassword ->
	    Password = rtb:replace(rtb_config:get_option(password), I),
	    {User, ClientID, Password};
       true ->
	    {User, ClientID}
    end.

-spec make_publish(will | publish, state()) -> undefined | publish().
make_publish(Opt, State) ->
    Args = rtb_config:get_option(Opt),
    case proplists:get_value(#publish.topic, Args) of
	undefined ->
	    undefined;
	T ->
	    T1 = rtb:replace(T, State#state.conn_id),
	    Pkt = lists:foldl(
		    fun({#publish.payload, I}, Pkt) when is_integer(I) ->
			    Data = p1_rand:bytes(I),
			    Pkt#publish{payload = Data};
		       ({#publish.payload, Data}, Pkt) ->
			    Data1 = rtb:replace(Data, State#state.conn_id),
			    Pkt#publish{payload = Data1};
		       ({Pos, Val}, Pkt) ->
			    setelement(Pos, Pkt, Val)
		    end, #publish{payload = <<>>}, Args),
            Pkt#publish{topic = T1}
    end.

-spec make_subscribe(state()) -> undefined | subscribe().
make_subscribe(State) ->
    case rtb_config:get_option(subscribe) of
	[_|_] = TFs ->
	    I = State#state.conn_id,
	    TFs1 = [{rtb:replace(TF, I), #sub_opts{qos = QoS}}
                    || {TF, QoS} <- TFs],
	    #subscribe{filters = TFs1};
	[] ->
	    undefined
    end.

reset_keep_alive(#state{keep_alive = KeepAlive} = State) ->
    case KeepAlive of
        0 -> set_timeout(State, infinity);
        _ -> set_timeout(State, timer:seconds(KeepAlive))
    end.

set_timeout(State, infinity) ->
    State#state{timeout = infinity};
set_timeout(State, Timeout) ->
    State#state{timeout = current_time() + Timeout}.

-spec current_time() -> integer().
current_time() ->
    p1_time_compat:monotonic_time(milli_seconds).

-spec next_id(non_neg_integer()) -> non_neg_integer().
next_id(ID) ->
    (ID rem 65535) + 1.

-spec set_id(mqtt_packet(), pos_integer()) -> mqtt_packet().
set_id(Pkt, ID) ->
    case element(2, Pkt) of
	undefined -> setelement(2, Pkt, ID);
	_ -> Pkt
    end.

-spec set_dup_flag(in_flight_packet()) -> in_flight_packet().
set_dup_flag(#publish{} = Pkt) ->
    Pkt#publish{dup = true};
set_dup_flag(Pkt) ->
    Pkt.

-spec attach_timestamp(mqtt_packet()) -> mqtt_packet().
attach_timestamp(Pkt) ->
    Pos = case Pkt of
              #publish{} -> #publish.meta;
              #subscribe{} -> #subscribe.meta;
              #unsubscribe{} -> #unsubscribe.meta;
              #pingreq{} -> #pingreq.meta
          end,
    Meta = element(Pos, Pkt),
    Meta1 = maps:put(timestamp, current_time(), Meta),
    setelement(Pos, Pkt, Meta1).

-spec calc_rtt(mqtt_packet()) -> mqtt_packet().
calc_rtt(Pkt) ->
    Meta = case Pkt of
               #publish{meta = M} -> M;
               #pubrel{meta = M} -> M;
               #subscribe{meta = M} -> M;
               #unsubscribe{meta = M} -> M;
               #pingreq{meta = M} -> M
           end,
    current_time() - maps:get(timestamp, Meta).

-spec get_session_expiry(state()) -> seconds().
get_session_expiry(State) ->
    case rtb_config:get_option(reconnect_interval) of
        false -> 0;
        _ when State#state.clean_session -> 0;
        Secs -> Secs*2
    end.

-spec random_interval(seconds()) -> milli_seconds().
random_interval(0) ->
    0;
random_interval(Seconds) ->
    p1_rand:uniform(timer:seconds(Seconds)).

-spec prep_publish_opt({binary(), term()}) -> {atom, term()}.
prep_publish_opt({K, V}) ->
    case erlang:binary_to_atom(K, latin1) of
	qos when is_integer(V), V>=0, V<3 ->
	    {#publish.qos, V};
	retain ->
	    try {#publish.retain, rtb_config:to_bool(V)}
	    catch _:_ -> rtb_config:fail_opt_val(retain, V)
	    end;
	topic when is_binary(V) ->
	    try {#publish.topic,
                 rtb:make_pattern(mod_mqtt_codec:topic(V))}
	    catch _:_ -> rtb_config:fail_opt_val(topic, V)
	    end;
	message when is_integer(V), V>= 0 ->
	    {#publish.payload, V};
	message when is_binary(V) ->
	    try {#publish.payload, rtb:make_pattern(V)}
	    catch _:_ -> rtb_config:fail_opt_val(message, V)
	    end;
	O when O == qos; O == topic; O == message ->
	    rtb_config:fail_opt_val(O, V);
	O ->
	    rtb_config:fail_unknown_opt(O)
    end.

start_timer(Action, Opt, Pos, Randomize) ->
    case rtb_config:get_option(Opt) of
	false ->
	    undefined;
	Seconds ->
	    MSecs = if Randomize -> random_interval(Seconds);
		       true -> timer:seconds(Seconds)
		    end,
	    erlang:start_timer(MSecs, self(), {Action, Opt, Pos})
    end.

schedule_all_actions(State) ->
    lists:foldl(fun schedule/2, State,
		[{disconnect, disconnect_interval, #state.disconnect_timer},
		 {publish, publish_interval, #state.publish_timer}]).

schedule(Op, State) ->
    schedule(Op, State, true).

schedule({Action, Opt, Pos}, State, Randomize) ->
    case element(Pos, State) of
	undefined ->
	    setelement(Pos, State, start_timer(Action, Opt, Pos, Randomize));
	_ ->
	    State
    end.

%%%===================================================================
%%% Formatters
%%%===================================================================
-spec pp(any()) -> iolist().
pp(Term) ->
    io_lib_pretty:print(Term, fun pp/2).

-spec pp(atom(), non_neg_integer()) -> [atom()] | no.
pp(state, N) ->
    case record_info(size, state)-1 of
	N -> record_info(fields, state);
	_ -> no
    end;
pp(Rec, Size) ->
    mod_mqtt_codec:pp(Rec, Size).

-spec format_inet_error(socket_error_reason()) -> string().
format_inet_error(closed) ->
    "connection closed";
format_inet_error(timeout) ->
    format_inet_error(etimedout);
format_inet_error(Reason) ->
    case inet:format_error(Reason) of
	"unknown POSIX error" -> atom_to_list(Reason);
	Txt -> Txt
    end.

-spec format_tls_error(atom() | binary()) -> string() | binary().
format_tls_error(no_cerfile) ->
    "certificate not found";
format_tls_error(Reason) when is_atom(Reason) ->
    format_inet_error(Reason);
format_tls_error(Reason) ->
    Reason.

-spec format(io:format(), list()) -> string().
format(Fmt, Args) ->
    lists:flatten(io_lib:format(Fmt, Args)).

-spec format_error(error_reason()) -> string().
format_error(disconnected) ->
    "Scheduled disconnection";
format_error(queue_full) ->
    "Message queue is overloaded";
format_error(internal_server_error) ->
    "Internal server error";
format_error(timeout) ->
    "Connection timed out";
format_error(ping_timeout) ->
    "Ping timeout";
format_error(shutdown) ->
    "Benchmark shutting down";
format_error(subscribe_failure) ->
    "SUBSCRIBE request has failed";
format_error({unexpected_packet, Name}) ->
    format("Unexpected ~s packet", [string:to_upper(atom_to_list(Name))]);
format_error({tls, Reason}) ->
    format("TLS failed: ~s", [format_tls_error(Reason)]);
format_error({dns, Reason}) ->
    format("DNS lookup failed: ~s", [format_inet_error(Reason)]);
format_error({socket, A}) ->
    format("Connection failed: ~s", [format_inet_error(A)]);
format_error({auth, Code, <<>>}) ->
    format("Authentication failure: ~s",
           [mod_mqtt_codec:format_reason_code(Code)]);
format_error({auth, Code, Reason}) ->
    format("Authentication failure: ~s (~s)", [Reason, Code]);
format_error({disconnected, Code, <<>>}) ->
    format("Disconnected by peer: ~s",
           [mod_mqtt_codec:format_reason_code(Code)]);
format_error({disconnected, Code, Reason}) ->
    format("Disconnected by peer: ~s (~s)", [Reason, Code]);
format_error({codec, CodecError}) ->
    mod_mqtt_codec:format_error(CodecError);
format_error(A) when is_atom(A) ->
    atom_to_list(A);
format_error(Reason) ->
    format("Unrecognized error: ~w", [Reason]).

-spec disconnect_reason_code(error_reason()) -> reason_code().
disconnect_reason_code(disconnected) -> 'normal-disconnection';
disconnect_reason_code(queue_full) -> 'quota-exceeded';
disconnect_reason_code(internal_server_error) -> 'implementation-specific-error';
disconnect_reason_code(timeout) -> 'maximum-connect-time';
disconnect_reason_code(ping_timeout) -> 'keep-alive-timeout';
disconnect_reason_code(shutdown) -> 'server-shutting-down';
disconnect_reason_code({unexpected_packet, _}) -> 'protocol-error';
disconnect_reason_code({codec, Err}) -> mod_mqtt_codec:error_reason_code(Err);
disconnect_reason_code(_) -> 'unspecified-error'.

%%%===================================================================
%%% Connecting stuff
%%%===================================================================
connect(#state{conn_addrs = Addrs, conn_opts = Opts,
	       timeout = Time} = State) ->
    case lookup(Addrs, Time) of
	{ok, Addrs1} ->
	    case connect(Addrs1, Opts, Time) of
		{ok, Sock} ->
		    {ok, State#state{socket = Sock}};
		Why ->
		    {error, Why}
	    end;
	Why ->
	    {error, {dns, Why}}
    end.

lookup(Addrs, Time) ->
    Addrs1 = lists:flatmap(
	       fun({Addr, Port, TLS}) when is_tuple(Addr) ->
		       [{Addr, Port, TLS, get_addr_type(Addr)}];
		  ({Host, Port, TLS}) ->
		       [{Host, Port, TLS, inet6},
			{Host, Port, TLS, inet}]
	       end, Addrs),
    do_lookup(Addrs1, Time, [], nxdomain).

do_lookup([{IP, _, _, _} = Addr|Addrs], Time, Res, Err) when is_tuple(IP) ->
    do_lookup(Addrs, Time, [Addr|Res], Err);
do_lookup([{Host, Port, TLS, Family}|Addrs], Time, Res, Err) ->
    Timeout = min(?DNS_TIMEOUT, max(0, Time - current_time())),
    case inet:gethostbyname(Host, Family, Timeout) of
        {ok, HostEntry} ->
            Addrs1 = host_entry_to_addrs(HostEntry),
            Addrs2 = [{Addr, Port, TLS, Family} || Addr <- Addrs1],
            do_lookup(Addrs, Time, Addrs2 ++ Res, Err);
        {error, Why} ->
            do_lookup(Addrs, Time, Res, Why)
    end;
do_lookup([], _Timeout, [], Err) ->
    Err;
do_lookup([], _Timeout, Res, _Err) ->
    {ok, Res}.

connect(Addrs, Opts, Time) ->
    Timeout = max(0, Time - current_time()) div length(Addrs),
    do_connect(Addrs, Opts, Timeout, {dns, nxdomain}).

do_connect([{Addr, Port, TLS, Family}|Addrs], Opts, Timeout, _Err) ->
    lager:debug("Connecting to ~s:~B (tls = ~p)",
                [inet_parse:ntoa(Addr), Port, TLS]),
    case gen_tcp:connect(Addr, Port, sockopts(Family, Opts), Timeout) of
        {ok, Sock} ->
	    case TLS of
		true ->
		    CertFile = {certfile, rtb_config:get_option(certfile)},
		    case fast_tls:tcp_to_tls(Sock, [connect, CertFile]) of
			{ok, Sock1} ->
			    {ok, {fast_tls, Sock1}};
			{error, Why} ->
			    do_connect(Addrs, Opts, Timeout, {tls, Why})
		    end;
		false ->
		    {ok, {gen_tcp, Sock}}
	    end;
        {error, Why} ->
            do_connect(Addrs, Opts, Timeout, {socket, Why})
    end;
do_connect([], _, _, Err) ->
    Err.

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

sockopts(Family, Opts) ->
    [{active, once},
     {packet, raw},
     {send_timeout, ?TCP_SEND_TIMEOUT},
     {send_timeout_close, true},
     binary, Family|Opts].
