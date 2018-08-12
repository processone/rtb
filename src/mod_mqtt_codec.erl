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
-module(mod_mqtt_codec).

%% API
-export([new/1, renew/1, decode/2, encode/1, pp/1, pp/2, format_error/1]).
%% Validators
-export([topic/1, topic_filter/1, qos/1]).

-include("mod_mqtt.hrl").

-record(codec_state, {type       :: undefined | non_neg_integer(),
		      flags      :: undefined | non_neg_integer(),
		      size       :: undefined | non_neg_integer(),
		      max_size   :: pos_integer() | infinity,
		      buf = <<>> :: binary()}).

-type error_reason() :: connack_code() |
			bad_payload_size |
			{payload_too_big, integer()} |
			{bad_packet_type, char()} |
			{bad_packet, atom()} |
			{bad_connack_code, char()} |
			bad_will_topic_or_message |
			bad_connect_username_or_password |
			bad_publish_id_or_payload |
			{bad_topic_filters, atom()} |
			{bad_qos, char()} |
			bad_topic | bad_topic_filter | bad_utf8_string |
			{unsupported_protocol_name, binary(), binary()} |
			{{bad_flag, atom()}, char(), char()} |
			{{bad_flags, atom()}, char(), char()}.

-opaque state() :: #codec_state{}.
-export_type([state/0, error_reason/0]).

%%%===================================================================
%%% API
%%%===================================================================
-spec new(pos_integer() | infinity) -> state().
new(MaxSize) ->
    #codec_state{max_size = MaxSize}.

-spec renew(state()) -> state().
renew(#codec_state{max_size = MaxSize}) ->
    #codec_state{max_size = MaxSize}.

-spec decode(state(), binary()) -> {ok, mqtt_packet(), state()} |
				   {more, state()} |
				   {error, error_reason()}.
decode(#codec_state{size = undefined, buf = Buf} = State, Data) ->
    Buf1 = <<Buf/binary, Data/binary>>,
    case Buf1 of
	<<Type:4, Flags:4, Data1/binary>> ->
	    try
		case decode_len(Data1) of
		    {Len, _} when Len >= State#codec_state.max_size ->
			err({payload_too_big, State#codec_state.max_size});
		    {Len, Data2} when size(Data2) >= Len ->
			<<Payload:Len/binary, Data3/binary>> = Data2,
			Pkt = decode_pkt(Type, Flags, Payload),
			{ok, Pkt, State#codec_state{buf = Data3}};
		    {Len, Data2} ->
			{more, State#codec_state{type = Type,
						 flags = Flags,
						 size = Len,
						 buf = Data2}};
		    more ->
			{more, State#codec_state{buf = Buf1}}
		end
	    catch _:{?MODULE, Why} ->
		    {error, Why}
	    end;
	<<>> ->
	    {more, State}
    end;
decode(#codec_state{size = Len, buf = Buf,
		    type = Type, flags = Flags} = State, Data) ->
    Buf1 = <<Buf/binary, Data/binary>>,
    if size(Buf1) >= Len ->
	    <<Payload:Len/binary, Data1/binary>> = Buf1,
	    try
		Pkt = decode_pkt(Type, Flags, Payload),
		{ok, Pkt, State#codec_state{type = undefined,
					    flags = undefined,
					    size = undefined,
					    buf = Data1}}
	    catch _:{?MODULE, Why} ->
		    {error, Why}
	    end;
       true ->
	    {more, State#codec_state{buf = Buf1}}
    end.

-spec encode(mqtt_packet()) -> binary().
encode(#connect{will = Will, clean_session = CleanSession,
		keep_alive = KeepAlive, client_id = ClientID,
		username = Username, password = Password}) ->
    UserFlag = Username /= <<>>,
    PassFlag = UserFlag andalso Password /= <<>>,
    WillFlag = is_record(Will, publish),
    WillRetain = WillFlag andalso Will#publish.retain,
    WillQoS = if WillFlag -> Will#publish.qos;
		 true -> 0
	      end,
    Header = <<4:16, "MQTT", 4, (enc_bool(UserFlag)):1,
	       (enc_bool(PassFlag)):1, (enc_bool(WillRetain)):1,
	       WillQoS:2, (enc_bool(WillFlag)):1,
	       (enc_bool(CleanSession)):1, 0:1,
	       KeepAlive:16, (size(ClientID)):16, ClientID/binary>>,
    EncWill = encode_will(Will),
    EncUserPass = encode_user_pass(Username, Password),
    Payload = encode_payload([Header, EncWill, EncUserPass]),
    <<1:4, 0:4, Payload/binary>>;
encode(#connack{session_present = SP, code = Code}) ->
    <<2:4, 0:4, 2, 0:7, (enc_bool(SP)):1, (encode_connack_code(Code))>>;
encode(#publish{qos = QoS, retain = Retain, dup = Dup,
		topic = Topic, id = ID, payload = Payload}) ->
    Data1 = <<(size(Topic)):16, Topic/binary>>,
    Data2 = case QoS of
		0 -> Payload;
		_ -> <<ID:16, Payload/binary>>
	    end,
    Data3 = encode_payload(<<Data1/binary, Data2/binary>>),
    <<3:4, (enc_bool(Dup)):1, QoS:2, (enc_bool(Retain)):1, Data3/binary>>;
encode(#puback{id = ID}) when ID>0 ->
    <<4:4, 0:4, 2, ID:16>>;
encode(#pubrec{id = ID}) when ID>0 ->
    <<5:4, 0:4, 2, ID:16>>;
encode(#pubrel{id = ID}) when ID>0 ->
    <<6:4, 2:4, 2, ID:16>>;
encode(#pubcomp{id = ID}) when ID>0 ->
    <<7:4, 0:4, 2, ID:16>>;
encode(#subscribe{id = ID, topic_filters = [_|_] = Filters}) when ID>0 ->
    EncFilters = [<<(size(Filter)):16, Filter/binary, QoS>> ||
		     {Filter, QoS} <- Filters],
    Payload = encode_payload([<<ID:16>>|EncFilters]),
    <<8:4, 2:4, Payload/binary>>;
encode(#suback{id = ID, codes = Codes}) ->
    Payload = encode_payload([<<ID:16>>, Codes]),
    <<9:4, 0:4, Payload/binary>>;
encode(#unsubscribe{id = ID, topic_filters = [_|_] = Filters}) when ID>0 ->
    EncFilters = [<<(size(Filter)):16, Filter/binary>> || Filter <- Filters],
    Payload = encode_payload([<<ID:16>>|EncFilters]),
    <<10:4, 2:4, Payload/binary>>;
encode(#unsuback{id = ID}) when ID>0 ->
    <<11:4, 0:4, 2, ID:16>>;
encode(#pingreq{}) ->
    <<12:4, 0:4, 0>>;
encode(#pingresp{}) ->
    <<13:4, 0:4, 0>>;
encode(#disconnect{}) ->
    <<14:4, 0:4, 0>>.

-spec pp(any()) -> iolist().
pp(Term) ->
    io_lib_pretty:print(Term, fun pp/2).

-spec format_error(error_reason()) -> string().
format_error(accepted) ->
    "authentication accepted";
format_error(unacceptable_protocol_version) ->
    "unacceptable protocol version";
format_error(identifier_rejected) ->
    "client identifier rejected";
format_error(server_unavailable) ->
    "server unavailable";
format_error(bad_username_or_password) ->
    "bad username or password";
format_error(not_authorized) ->
    "not authorized";
format_error({payload_too_big, Max}) ->
    format("payload exceeds ~B bytes", [Max]);
format_error(bad_payload_size) ->
    "payload size is out of boundaries";
format_error({bad_packet_type, Type}) ->
    format("unexpected packet type: ~B", [Type]);
format_error({bad_packet, Name}) ->
    format("malformed ~s packet", [string:to_upper(atom_to_list(Name))]);
format_error({bad_connack_code, Code}) ->
    format("unexpected CONNACK code: ~B", [Code]);
format_error(bad_will_topic_or_message) ->
    "malformed Will Topic or Will Message";
format_error(bad_connect_username_or_password) ->
    "malformed username or password of CONNECT packet";
format_error(bad_publish_id_or_payload) ->
    "malformed id or payload of PUBLISH packet";
format_error({bad_topic_filters, Name}) ->
    format("malformed topic filters of ~s packet",
	   [string:to_upper(atom_to_list(Name))]);
format_error({bad_qos, Q}) ->
    format("malformed QoS value: ~p (expected: 0..2)", [Q]);
format_error(bad_topic) ->
    "unacceptable topic";
format_error(bad_topic_filter) ->
    "unacceptable topic filter";
format_error(bad_utf8_string) ->
    "unacceptable UTF-8 string";
format_error({unsupported_protocol_name, Got, Expected}) ->
    format_got_expected("unsupported protocol name", Got, Expected);
format_error({{bad_flag, Name}, Got, Expected}) ->
    Txt = "unexpected " ++ atom_to_list(Name) ++ " flag",
    format_got_expected(Txt, Got, Expected);
format_error({{bad_flags, Name}, Got, Expected}) ->
    Txt = "unexpected " ++ string:to_upper(atom_to_list(Name)) ++ " flags",
    format_got_expected(Txt, Got, Expected);
format_error(Reason) ->
    format("Unexpected error: ~w", [Reason]).

%%%===================================================================
%%% Decoder
%%%===================================================================
-spec decode_len(binary()) -> {non_neg_integer(), binary()}.
decode_len(Data) ->
    decode_len(Data, 0, 1).

-spec decode_len(binary(), non_neg_integer(), pos_integer()) ->
			{non_neg_integer(), binary()}.
decode_len(<<C, Data/binary>>, Val, Mult) ->
    NewVal = Val + (C band 127) * Mult,
    NewMult = Mult*128,
    if NewMult > 268435456 ->
	    err(bad_payload_size);
       (C band 128) == 0 ->
	    {NewVal, Data};
       true ->
	    decode_len(Data, NewVal, NewMult)
    end;
decode_len(_, _, _) ->
    more.

-spec decode_pkt(non_neg_integer(), non_neg_integer(), binary()) -> mqtt_packet().
decode_pkt(Type, Flags, Data) ->
    case Type of
	1 -> decode_connect(Flags, Data);
	2 -> decode_connack(Flags, Data);
	3 -> decode_publish(Flags, Data);
	4 -> decode_puback(Flags, Data);
	5 -> decode_pubrec(Flags, Data);
	6 -> decode_pubrel(Flags, Data);
	7 -> decode_pubcomp(Flags, Data);
	8 -> decode_subscribe(Flags, Data);
	9 -> decode_suback(Flags, Data);
	10 -> decode_unsubscribe(Flags, Data);
	11 -> decode_unsuback(Flags, Data);
	12 -> decode_pingreq(Flags, Data);
	13 -> decode_pingresp(Flags, Data);
	14 -> decode_disconnect(Flags, Data);
	_ -> err({bad_packet_type, Type})
    end.

-spec decode_connect(non_neg_integer(), binary()) -> connect().
decode_connect(Flags, <<ProtoLen:16, Proto:ProtoLen/binary, Data/binary>>) ->
    assert(Flags, 0, {bad_flags, connect}),
    assert(utf8(Proto), <<"MQTT">>, unsupported_protocol_name),
    case Data of
	<<ProtoLevel, UserFlag:1, PassFlag:1, WillRetain:1,
	  WillQoS:2, WillFlag:1, CleanSession:1,
	  Reserved:1, KeepAlive:16,
	  ClientIDLen:16, ClientID:ClientIDLen/binary,
	  Data1/binary>> ->
	    assert(Reserved, 0, {bad_flag, reserved}),
	    {Will, Data2} = decode_will(WillFlag, WillRetain, WillQoS, Data1),
	    {Username, Password} = decode_user_pass(UserFlag, PassFlag, Data2),
	    #connect{proto_level = ProtoLevel,
		     will = Will,
		     clean_session = dec_bool(CleanSession),
		     keep_alive = KeepAlive,
		     client_id = utf8(ClientID),
		     username = utf8(Username),
		     password = Password};
	_ ->
	    err({bad_packet, connect})
    end;
decode_connect(_, _) ->
    err({bad_packet, connect}).

-spec decode_connack(non_neg_integer(), binary()) -> connack().
decode_connack(Flags, <<0:7, SessionPresent:1, Code>>) ->
    assert(Flags, 0, {bad_flags, connack}),
    #connack{session_present = dec_bool(SessionPresent),
	     code = decode_connack_code(Code)};
decode_connack(_, _) ->
    err({bad_packet, connack}).

-spec decode_publish(non_neg_integer(), binary()) -> publish().
decode_publish(Flags, <<TLen:16, Topic:TLen/binary, Data/binary>>) ->
    Retain = Flags band 1,
    QoS = qos((Flags bsr 1) band 3),
    DUP = Flags band 8,
    {ID, Payload} = decode_id_payload(QoS, Data),
    #publish{dup = dec_bool(DUP),
	     qos = QoS,
	     retain = dec_bool(Retain),
	     topic = topic(Topic),
	     id = ID,
	     payload = Payload};
decode_publish(_, _) ->
    err({bad_packet, publish}).

-spec decode_puback(non_neg_integer(), binary()) -> puback().
decode_puback(Flags, <<ID:16>>) when ID>0 ->
    assert(Flags, 0, {bad_flags, puback}),
    #puback{id = ID};
decode_puback(_, _) ->
    err({bad_packet, puback}).

-spec decode_pubrec(non_neg_integer(), binary()) -> pubrec().
decode_pubrec(Flags, <<ID:16>>) when ID>0 ->
    assert(Flags, 0, {bad_flags, pubrec}),
    #pubrec{id = ID};
decode_pubrec(_, _) ->
    err({bad_packet, pubrec}).

-spec decode_pubrel(non_neg_integer(), binary()) -> pubrel().
decode_pubrel(Flags, <<ID:16>>) when ID>0 ->
    assert(Flags, 2, {bad_flags, pubrel}),
    #pubrel{id = ID};
decode_pubrel(_, _) ->
    err({bad_packet, pubrel}).

-spec decode_pubcomp(non_neg_integer(), binary()) -> pubcomp().
decode_pubcomp(Flags, <<ID:16>>) when ID>0 ->
    assert(Flags, 0, {bad_flags, pubcomp}),
    #pubcomp{id = ID};
decode_pubcomp(_, _) ->
    err({bad_packet, pubcomp}).

-spec decode_subscribe(non_neg_integer(), binary()) -> subscribe().
decode_subscribe(Flags, <<ID:16, Payload/binary>>) when ID>0 ->
    assert(Flags, 2, {bad_flags, subscribe}),
    Topics = decode_subscribe_topics(Payload),
    #subscribe{id = ID, topic_filters = Topics};
decode_subscribe(_, _) ->
    err({bad_packet, subscribe}).

-spec decode_suback(non_neg_integer(), binary()) -> suback().
decode_suback(Flags, <<ID:16, Data/binary>>) when ID>0 ->
    assert(Flags, 0, {bad_flags, suback}),
    #suback{id = ID,
	    codes = decode_suback_codes(Data)};
decode_suback(_, _) ->
    err({bad_packet, suback}).

-spec decode_unsubscribe(non_neg_integer(), binary()) -> unsubscribe().
decode_unsubscribe(Flags, <<ID:16, Data/binary>>) when ID>0 ->
    assert(Flags, 2, {bad_flags, subscribe}),
    Topics = decode_unsubscribe_topics(Data),
    #unsubscribe{id = ID, topic_filters = Topics};
decode_unsubscribe(_, _) ->
    err({bad_packet, unsubscribe}).

-spec decode_unsuback(non_neg_integer(), binary()) -> unsuback().
decode_unsuback(Flags, <<ID:16>>) when ID>0 ->    
    assert(Flags, 0, {bad_flags, unsuback}),
    #unsuback{id = ID};
decode_unsuback(_, _) -> 
    err({bad_packet, unsuback}).

-spec decode_pingreq(non_neg_integer(), binary()) -> pingreq().
decode_pingreq(Flags, <<>>) ->
    assert(Flags, 0, {bad_flags, pingreq}),
    #pingreq{};
decode_pingreq(_, _) ->
    err({bad_packet, pingreq}).

-spec decode_pingresp(non_neg_integer(), binary()) -> pingresp().
decode_pingresp(Flags, <<>>) ->
    assert(Flags, 0, {bad_flags, pingresp}),
    #pingresp{};
decode_pingresp(_, _) ->
    err({bad_packet, pingresp}).

-spec decode_disconnect(non_neg_integer(), binary()) -> disconnect().
decode_disconnect(Flags, <<>>) ->
    assert(Flags, 0, {bad_flags, disconnect}),
    #disconnect{};
decode_disconnect(_, _) ->
    err({bad_packet, disconnect}).

-spec decode_will(0|1, 0|1, qos(), binary()) ->
			 {undefined | publish(), binary()}.
decode_will(0, WillRetain, WillQoS, Data) ->
    assert(WillRetain, 0, {bad_flag, will_retain}),
    assert(WillQoS, 0, {bad_flag, will_qos}),
    {undefined, Data};
decode_will(1, WillRetain, WillQoS,
	    <<TLen:16, Topic:TLen/binary,
	      MLen:16, Message:MLen/binary,
	      Data/binary>>) ->
    {#publish{retain = dec_bool(WillRetain),
	      qos = qos(WillQoS),
	      topic = topic(Topic),
	      payload = Message},
     Data};
decode_will(_, _, _, _) ->
    err(bad_will_topic_or_message).

-spec decode_user_pass(non_neg_integer(), non_neg_integer(),
		       binary()) -> {binary(), binary()}.
decode_user_pass(1, 0, <<Len:16, User:Len/binary>>) ->
    {utf8(User), <<>>};
decode_user_pass(1, 1, <<ULen:16, User:ULen/binary,
			 PLen:16, Pass:PLen/binary>>) ->
    {utf8(User), Pass};
decode_user_pass(0, Flag, <<>>) ->
    assert(Flag, 0, {bad_flag, password}),
    {<<>>, <<>>};
decode_user_pass(_, _, _) ->
    err(bad_connect_username_or_password).

-spec decode_connack_code(char()) -> connack_code().
decode_connack_code(0) -> accepted;
decode_connack_code(1) -> unacceptable_protocol_version;
decode_connack_code(2) -> identifier_rejected;
decode_connack_code(3) -> server_unavailable;
decode_connack_code(4) -> bad_username_or_password;
decode_connack_code(5) -> not_authorized;
decode_connack_code(Code) -> err({bad_connack_code, Code}).

-spec decode_id_payload(non_neg_integer(), binary()) ->
			       {undefined | non_neg_integer(), binary()}.
decode_id_payload(0, Payload) ->
    {undefined, Payload};
decode_id_payload(_, <<ID:16, Payload/binary>>) when ID>0 ->
    {ID, Payload};
decode_id_payload(_, _) ->
    err(bad_publish_id_or_payload).

-spec decode_subscribe_topics(binary()) -> [{binary(), non_neg_integer()}].
decode_subscribe_topics(<<Len:16, Topic:Len/binary, 0:6, QoS:2, Tail/binary>>) ->
    [{topic_filter(Topic), qos(QoS)}|decode_subscribe_topics(Tail)];
decode_subscribe_topics(<<>>) ->
    [];
decode_subscribe_topics(_) ->
    err({bad_topic_filters, subscribe}).

-spec decode_unsubscribe_topics(binary()) -> [binary()].
decode_unsubscribe_topics(<<Len:16, Str:Len/binary, Tail/binary>>) ->
    [topic_filter(Str)|decode_unsubscribe_topics(Tail)];
decode_unsubscribe_topics(<<>>) ->
    [];
decode_unsubscribe_topics(_) ->
    err({bad_topic_filters, unsubscribe}).

-spec decode_suback_codes(binary()) -> [fail | qos()].
decode_suback_codes(<<16#80, Data/binary>>) ->
    [fail|decode_suback_codes(Data)];
decode_suback_codes(<<QoS, Data/binary>>) ->
    [qos(QoS)|decode_suback_codes(Data)];
decode_suback_codes(<<>>) ->
    [].

%%%===================================================================
%%% Encoder
%%%===================================================================
-spec encode_payload(iodata()) -> binary().
encode_payload(IOData) ->
    Data = iolist_to_binary(IOData),
    Len = encode_len(size(Data)),
    <<Len/binary, Data/binary>>.

-spec encode_len(non_neg_integer()) -> binary().
encode_len(X) when X < 128 ->
    <<0:1, X:7>>;
encode_len(X) when X < 268435456 ->
    <<1:1, (X rem 128):7, (encode_len(X div 128))/binary>>.

-spec encode_connack_code(connack_code()) -> non_neg_integer().
encode_connack_code(accepted) -> 0;
encode_connack_code(unacceptable_protocol_version) -> 1;
encode_connack_code(identifier_rejected) -> 2;
encode_connack_code(server_unavailable) -> 3;
encode_connack_code(bad_username_or_password) -> 4;
encode_connack_code(not_authorized) -> 5.

-spec encode_user_pass(binary(), binary()) -> binary().
encode_user_pass(User, Pass) when User /= <<>> andalso Pass /= <<>> ->
    <<(size(User)):16, User/binary, (size(Pass)):16, Pass/binary>>;
encode_user_pass(User, _) when User /= <<>> ->
    <<(size(User)):16, User/binary>>;
encode_user_pass(_, _) ->
    <<>>.

-spec encode_will(undefined | publish()) -> binary().
encode_will(#publish{topic = Topic, payload = Payload}) ->
    <<(size(Topic)):16, Topic/binary,
      (size(Payload)):16, Payload/binary>>;
encode_will(undefined) ->
    <<>>.

%%%===================================================================
%%% Pretty printer
%%%===================================================================
-spec pp(atom(), non_neg_integer()) -> [atom()] | no.
pp(codec_state, 5) -> record_info(fields, codec_state);
pp(connect, 7) -> record_info(fields, connect);
pp(connack, 2) -> record_info(fields, connack);
pp(publish, 7) -> record_info(fields, publish);
pp(puback, 1) -> record_info(fields, puback);
pp(pubrec, 1) -> record_info(fields, pubrec);
pp(pubrel, 1) -> record_info(fields, pubrel);
pp(pubcomp, 1) -> record_info(fields, pubcomp);
pp(subscribe, 2) -> record_info(fields, subscribe);
pp(suback, 2) -> record_info(fields, suback);
pp(unsubscribe, 2) -> record_info(fields, unsubscribe);
pp(unsuback, 1) -> record_info(fields, unsuback);
pp(pingreq, 0) -> record_info(fields, pingreq);
pp(pingresp, 0) -> record_info(fields, pingresp);
pp(disconnect, 0) -> record_info(fields, disconnect);
pp(_, _) -> no.

%%%===================================================================
%%% Validators
%%%===================================================================
-spec assert(T, any(), atom()) -> T.
assert(Got, Got, _) ->
    Got;
assert(Got, Expected, Reason) ->
    err({Reason, Got, Expected}).

-spec qos(qos()) -> qos().
qos(QoS) when is_integer(QoS), QoS>=0, QoS<3 ->
    QoS;
qos(QoS) ->
    err({bad_qos, QoS}).

-spec topic(binary()) -> binary().
topic(<<>>) ->
    err(bad_topic);
topic(Bin) when is_binary(Bin) ->
    ok = check_topic(Bin),
    ok = check_utf8(Bin),
    Bin;
topic(_) ->
    err(bad_topic).

-spec topic_filter(binary()) -> binary().
topic_filter(<<>>) ->
    err(bad_topic_filter);
topic_filter(Bin) when is_binary(Bin) ->
    ok = check_topic_filter(Bin, $/),
    ok = check_utf8(Bin),
    Bin;
topic_filter(_) ->
    err(bad_topic_filter).

-spec utf8(binary()) -> binary().
utf8(Bin) ->
    ok = check_utf8(Bin),
    ok = check_zero(Bin),
    Bin.

-spec check_topic(binary()) -> ok.
check_topic(<<H, _/binary>>) when H == $#; H == $+; H == 0 ->
    err(bad_topic);
check_topic(<<_, T/binary>>) ->
    check_topic(T);
check_topic(<<>>) ->
    ok.

-spec check_topic_filter(binary(), char()) -> ok.
check_topic_filter(<<>>, _) ->
    ok;
check_topic_filter(_, $#) ->
    err(bad_topic_filter);
check_topic_filter(<<$#, _/binary>>, C) when C /= $/ ->
    err(bad_topic_filter);
check_topic_filter(<<$+, _/binary>>, C) when C /= $/ ->
    err(bad_topic_filter);
check_topic_filter(<<C, _/binary>>, $+) when C /= $/ ->
    err(bad_topic_filter);
check_topic_filter(<<0, _/binary>>, _) ->
    err(bad_topic_filter);
check_topic_filter(<<H, T/binary>>, _) ->
    check_topic_filter(T, H).

-spec check_utf8(binary()) -> ok.
check_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
	UTF8Str when is_binary(UTF8Str) ->
	    ok;
	_ ->
	    err(bad_utf8_string)
    end.

-spec check_zero(binary()) -> ok.
check_zero(<<0, _/binary>>) ->
    err(bad_utf8_string);
check_zero(<<_, T/binary>>) ->
    check_zero(T);
check_zero(<<>>) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec dec_bool(non_neg_integer()) -> boolean().
dec_bool(0) -> false;
dec_bool(_) -> true.

-spec enc_bool(boolean()) -> 0..1.
enc_bool(true) -> 1;
enc_bool(false) -> 0.

-spec err(any()) -> no_return().
err(Reason) ->
    erlang:error({?MODULE, Reason}).

-spec format(io:format(), list()) -> string().
format(Fmt, Args) ->
    lists:flatten(io_lib:format(Fmt, Args)).

format_got_expected(Txt, Got, Expected) when is_integer(Got) ->
    format("~s: ~B (expected: ~B)", [Txt, Got, Expected]);
format_got_expected(Txt, Got, Expected) ->
    format("~s: '~s' (expected: '~s')", [Txt, Got, Expected]).
