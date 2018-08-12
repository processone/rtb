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
-record(connect, {proto_level   = 4    :: non_neg_integer(),
		  will                 :: undefined | publish(),
		  clean_session = true :: boolean(),
		  keep_alive    = 0    :: non_neg_integer(),
		  client_id     = <<>> :: binary(),
		  username      = <<>> :: binary(),
		  password      = <<>> :: binary()}).
-record(connack, {session_present = false :: boolean(),
		  code = accepted :: connack_code()}).

-record(publish, {id :: undefined | non_neg_integer(),
		  dup = false :: boolean(),
		  qos = 0 :: qos(),
		  retain = false :: boolean(),
		  topic :: binary(),
		  payload :: binary(),
		  meta = #{} :: map()}).
-record(puback, {id :: non_neg_integer()}).
-record(pubrec, {id :: non_neg_integer()}).
-record(pubrel, {id :: non_neg_integer()}).
-record(pubcomp, {id :: non_neg_integer()}).

-record(subscribe, {id :: non_neg_integer(),
		    topic_filters :: [{binary(), non_neg_integer()}]}).
-record(suback, {id :: non_neg_integer(),
		 codes :: [fail | qos()]}).

-record(unsubscribe, {id :: non_neg_integer(),
		      topic_filters :: [binary()]}).
-record(unsuback, {id :: non_neg_integer()}).

-record(pingreq, {}).
-record(pingresp, {}).

-record(disconnect, {}).

-type qos() :: 0|1|2.

-type connack_code() :: accepted | unacceptable_protocol_version |
			identifier_rejected | server_unavailable |
			bad_username_or_password | not_authorized.

-type connect() :: #connect{}.
-type connack() :: #connack{}.
-type publish() :: #publish{}.
-type puback() :: #puback{}.
-type pubrel() :: #pubrel{}.
-type pubrec() :: #pubrec{}.
-type pubcomp() :: #pubcomp{}.
-type subscribe() :: #subscribe{}.
-type suback() :: #suback{}.
-type unsubscribe() :: #unsubscribe{}.
-type unsuback() :: #unsuback{}.
-type pingreq() :: #pingreq{}.
-type pingresp() :: #pingresp{}.
-type disconnect() :: #disconnect{}.

-type mqtt_packet() :: connect() | connack() | publish() | puback() |
		       pubrel() | pubrec() | pubcomp() | subscribe() |
		       suback() | unsubscribe() | unsuback() | pingreq() |
		       pingresp() | disconnect().
