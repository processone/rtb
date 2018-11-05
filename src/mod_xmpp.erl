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
-module(mod_xmpp).
-compile([{parse_transform, lager_transform}]).
-behaviour(xmpp_stream_out).
-behaviour(rtb).

%% rtb API
-export([load/0, start/4, options/0, prep_option/2, metrics/0]).
%% xmpp_stream_out callbacks
-export([tls_options/1, tls_required/1, tls_verify/1, tls_enabled/1]).
-export([sasl_mechanisms/1, handle_stream_end/2, resolve/2,
	 connect_options/3, connect_timeout/1, handle_timeout/1]).
-export([handle_stream_established/1, handle_packet/2,
	 handle_authenticated_features/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
%% IQ callbacks
-export([disco_info_callback/3,
	 disco_items_callback/3,
	 carbons_set_callback/3,
	 blocklist_get_callback/3,
	 roster_get_callback/3,
	 private_get_callback/3,
	 mam_prefs_set_callback/3,
	 mam_query_callback/3,
	 proxy65_get_callback/3,
	 proxy65_set_callback/6,
	 proxy65_activate_callback/4,
	 upload_request_callback/4]).
%% Scheduled actions
-export([send_message/1, send_presence/1, disconnect/1, upload_file/1,
	 proxy65_send_file/1]).

-include("rtb.hrl").
-include("xmpp.hrl").

-type state() :: #{}.
-type seconds() :: non_neg_integer().
-type milli_seconds() :: non_neg_integer().
-type jid_pattern() :: {rtb:pattern(), binary(), rtb:pattern()}.

%%%===================================================================
%%% API
%%%===================================================================
load() ->
    try
	{ok, _} = application:ensure_all_started(ssl),
	{ok, _} = application:ensure_all_started(xmpp),
	ok
    catch _:{badmatch, {error, _} = Err} ->
	    Err
    end.

start(I, Opts, Servers, JustStarted) ->
    {_, S, _} = rtb_config:get_option(jid),
    xmpp_stream_out:start(
      ?MODULE, [S, S, {I, Opts, Servers, JustStarted}], []).

options() ->
    [{sasl_mechanisms, [<<"PLAIN">>]},
     {negotiation_timeout, 100},
     {connect_timeout, 100},
     {message_body_size, 100},
     {message_to, undefined},
     {reconnect_interval, 60},
     {message_interval, 600},
     {presence_interval, 600},
     {disconnect_interval, 600},
     {proxy65_interval, 600},
     {proxy65_size, 10485760},
     {http_upload_interval, 600},
     {http_upload_size, undefined},
     {starttls, true},
     {csi, true},
     {sm, true},
     {mam, true},
     {carbons, true},
     {blocklist, true},
     {roster, true},
     {rosterver, true},
     {private, true},
     %% Required options
     jid,
     password].

metrics() ->
    lists:filter(
      fun(#metric{name = Name}) ->
              if Name == 'roster-get-rtt' -> rtb_config:get_option(roster);
                 Name == 'carbons-enable-rtt' -> rtb_config:get_option(carbons);
                 Name == 'mam-prefs-set-rtt';
                 Name == 'mam-query-rtt' -> rtb_config:get_option(mam);
                 Name == 'private-get-rtt' -> rtb_config:get_option(private);
                 Name == 'block-list-get-rtt' -> rtb_config:get_option(blocklist);
                 Name == 'proxy65-activate-rtt';
                 Name == 'proxy65-get-rtt';
                 Name == 'proxy65-set-rtt' ->
                      rtb_config:get_option(proxy65_interval) /= false;
                 Name == 'upload-request-rtt' ->
                      rtb_config:get_option(http_upload_interval) /= false;
                 true ->
                      true
              end
      end, [#metric{name = sessions, call = fun rtb_sm:size/0},
            #metric{name = errors},
            #metric{name = 'message-out'},
            #metric{name = 'message-in'},
            #metric{name = 'presence-out'},
            #metric{name = 'presence-in'},
            #metric{name = 'iq-out'},
            #metric{name = 'iq-in'},
            #metric{name = 'roster-get-rtt', type = hist},
            #metric{name = 'carbons-enable-rtt', type = hist},
            #metric{name = 'disco-info-rtt', type = hist},
            #metric{name = 'disco-items-rtt', type = hist},
            #metric{name = 'mam-prefs-set-rtt', type = hist},
            #metric{name = 'mam-query-rtt', type = hist},
            #metric{name = 'private-get-rtt', type = hist},
            #metric{name = 'block-list-get-rtt', type = hist},
            #metric{name = 'proxy65-activate-rtt', type = hist},
            #metric{name = 'proxy65-get-rtt', type = hist},
            #metric{name = 'proxy65-set-rtt', type = hist},
            #metric{name = 'upload-request-rtt', type = hist}]).

prep_option(jid, J) when is_binary(J) ->
    xmpp:set_config([{debug, rtb_config:get_option(debug)}]),
    {jid, prep_jid(J)};
prep_option(password, P) when is_binary(P) ->
    {password, rtb:make_pattern(P)};
prep_option(sasl_mechanisms, Ms) when is_list(Ms) ->
    {sasl_mechanisms,
     [list_to_binary(string:to_upper(binary_to_list(M))) || M <- Ms]};
prep_option(message_body_size, I) when is_integer(I), I>=0 ->
    Data = list_to_binary(lists:duplicate(I, $x)),
    {message_body, Data};
prep_option(message_to, J) when is_binary(J) ->
    {message_to, prep_jid(J)};
prep_option(message_to, undefined) ->
    {message_to, undefined};
prep_option(http_upload_size, undefined) ->
    {http_upload_size, undefined};
prep_option(starttls, Bool) ->
    case rtb_config:to_bool(Bool) of
	true ->
	    case rtb_config:get_option(certfile) of
		undefined ->
		    rtb:halt("Option 'starttls' is set to 'true' "
			     "by option 'certfile' is not set", []);
		_ ->
		    {starttls, true}
	    end;
	false ->
	    {starttls, false}
    end;
prep_option(Opt, Bool) when Opt == csi; Opt == rosterver; Opt == sm;
			    Opt == mam; Opt == carbons; Opt == blocklist;
			    Opt == roster; Opt == private ->
    {Opt, rtb_config:to_bool(Bool)};
prep_option(Opt, I) when is_integer(I) andalso I>0 andalso
			 (Opt == negotiation_timeout orelse
			  Opt == connect_timeout orelse
			  Opt == http_upload_size orelse
			  Opt == message_interval orelse
			  Opt == presence_interval orelse
			  Opt == disconnect_interval orelse
			  Opt == http_upload_interval orelse
			  Opt == proxy65_interval orelse
			  Opt == reconnect_interval orelse
			  Opt == http_upload_size orelse
			  Opt == proxy65_size) ->
    {Opt, I};
prep_option(Opt, Val) when Opt == message_interval;
			   Opt == presence_interval;
			   Opt == disconnect_interval;
			   Opt == reconnect_interval;
			   Opt == proxy65_interval;
			   Opt == http_upload_interval ->
    case rtb_config:to_bool(Val) of
	false -> {Opt, false}
    end.

%%%===================================================================
%%% API
%%%===================================================================
stop(Ref) ->
    xmpp_stream_out:stop(Ref).

tls_options(#{certfile := CertFile}) ->
    [{certfile, CertFile}].

tls_required(_) ->
    rtb_config:get_option(starttls).

tls_enabled(_) ->
    rtb_config:get_option(starttls).

tls_verify(_) ->
    false.

sasl_mechanisms(_) ->
    rtb_config:get_option(sasl_mechanisms).

resolve(_, #{conn_addrs := Addrs}) ->
    Addrs.

connect_options(_, Opts, #{conn_options := Opts1}) ->
    Opts1 ++ Opts.

connect_timeout(_) ->
    timer:seconds(rtb_config:get_option(connect_timeout)).

%%%===================================================================
%%% xmpp_stream_out callbacks
%%%===================================================================
init([State, {I, Opts, Servers, JustStarted}]) ->
    JID = make_jid(rtb_config:get_option(jid), I),
    Password = rtb:replace(rtb_config:get_option(password), I),
    process_flag(trap_exit, true),
    CertFile = rtb_config:get_option(certfile),
    NegTimeout = rtb_config:get_option(negotiation_timeout),
    rtb_pool:register(self(), I),
    State1 = State#{user => JID#jid.user,
		    server => JID#jid.lserver,
		    resource => JID#jid.lresource,
		    password => Password,
		    jid => JID,
		    conn_id => I,
		    conn_options => Opts,
		    conn_addrs => Servers,
		    xmlns => ?NS_CLIENT,
		    iq_requests => #{},
		    start_time => current_time(),
		    just_started => JustStarted,
		    csi_state => active,
		    action => connect,
		    certfile => CertFile},
    xmpp_stream_out:connect(self()),
    State2 = xmpp_stream_out:set_timeout(State1, timer:seconds(NegTimeout)),
    {ok, State2}.

handle_authenticated_features(Features, State) ->
    case missing_stream_features(State, Features) of
	[] ->
	    PrevID = maps:get(mgmt_id, State, undefined),
	    StanzasIn = maps:get(mgmt_stanzas_in, State, undefined),
	    if PrevID /= undefined andalso StanzasIn /= undefined ->
		    send_pkt(State#{stream_features => Features},
			     #sm_resume{xmlns = ?NS_STREAM_MGMT_3,
					previd = PrevID,
					h = StanzasIn});
	       true ->
		    xmpp_stream_out:bind(State, Features)
	    end;
	MissingFeatures ->
	    Server = maps:get(server, State),
	    fail_missing_features(State, jid:make(Server), MissingFeatures)
    end.

handle_stream_established(#{mgmt_id := _, mgmt_stanzas_in := _} = State) ->
    session_established(State);
handle_stream_established(#{start_time := StartTime} = State) ->
    Delay = current_time() - StartTime,
    NegTimeout = rtb_config:get_option(negotiation_timeout),
    Timeout = lists:max([Delay, timer:seconds(NegTimeout)]),
    State1 = xmpp_stream_out:set_timeout(State, Timeout),
    case rtb_config:get_option(sm) of
	true ->
	    send_pkt(State1, #sm_enable{xmlns = ?NS_STREAM_MGMT_3,
					resume = true});
	false ->
	    send_iq_requests(State1)
    end.

handle_timeout(#{action := reconnect} = State) ->
    NegTimeout = rtb_config:get_option(negotiation_timeout),
    xmpp_stream_out:connect(self()),
    xmpp_stream_out:set_timeout(
      State#{action => connect,
	     start_time => current_time()},
      timer:seconds(NegTimeout));
handle_timeout(#{lang := Lang} = State) ->
    Txt = <<"Stream negotiation timeout">>,
    send_pkt(State, xmpp:serr_connection_timeout(Txt, Lang)).

handle_packet(Pkt, State) when ?is_stanza(Pkt) ->
    State1 = try maps:get(mgmt_stanzas_in, State) of
		 H -> State#{mgmt_stanzas_in => H+1}
	     catch _:{badkey, _} -> State
	     end,
    case Pkt of
	#iq{} ->
	    rtb_stats:incr('iq-in'),
	    handle_iq(Pkt, State1);
	#message{} ->
	    rtb_stats:incr('message-in'),
	    handle_message(Pkt, State1);
	#presence{} ->
	    rtb_stats:incr('presence-in'),
	    handle_presence(Pkt, State1)
    end;
handle_packet(#sm_r{}, #{mgmt_stanzas_in := H} = State) ->
    send_pkt(State, #sm_a{h = H, xmlns = ?NS_STREAM_MGMT_3});
handle_packet(#sm_enabled{max = Max, id = ID}, #{action := connect} = State) ->
    case {ID, Max} of
	{undefined, _} ->
	    Txt = io_lib:format(
		    "~s doesn't support stream resumption",
		    [maps:get(server, State)]),
	    fail(State, Txt);
	{_, undefined} ->
	    Txt = io_lib:format(
		    "~s doesn't report max resumption timeout",
		    [maps:get(server, State)]),
	    fail(State, Txt);
	_ ->
	    State1 = State#{mgmt_timeout => Max, mgmt_id => ID,
			    mgmt_stanzas_in => 0},
            send_iq_requests(State1)
    end;
handle_packet(#sm_resumed{}, State) ->
    State1 = maps:remove(stream_features, State),
    xmpp_stream_out:establish(State1#{mgmt_resumed => true});
handle_packet(#sm_failed{} = Err, #{stream_features := Features} = State) ->
    Txt = <<"Resumption failed: ", (format_error(Err))/binary>>,
    incr_error(Txt),
    State1 = reset_state(State),
    xmpp_stream_out:bind(State1, Features);
handle_packet(#sm_failed{} = Err, State) ->
    Err = io_lib:format("Failed to enable stream management; "
			"peer responded with error: ~s",
			[format_error(Err)]),
    fail(State, Err);
handle_packet(_, State) ->
    State.

handle_stream_end(Reason, #{just_started := true} = State) ->
    Err = maps:get(stop_reason, State, Reason),
    rtb:halt(format_error(Err), []);
handle_stream_end(Reason, State) ->
    case rtb_config:get_option(reconnect_interval) of
	false ->
	    State1 = case maps:is_key(stop_reason, State) of
			 true -> State;
			 false -> State#{stop_reason => Reason}
		     end,
	    stop(State1);
	Timeout ->
	    {Err, State1} = case maps:take(stop_reason, State) of
				error -> {Reason, State};
				Other -> Other
			    end,
            incr_error(Err),
	    lager:debug("~s terminated: ~s; reconnecting...",
			[format_me(State1), format_error(Err)]),
	    State2 = reset_state(State1),
	    reconnect_after(State2, Timeout)
    end.

handle_call(_Request, _From, State) ->
    State.

handle_cast(Msg, State) ->
    lager:warning("Unexpected cast: ~p", [Msg]),
    State.

handle_info({timeout, TRef, {Interval, Fun}}, State) ->
    case maps:take(Fun, State) of
	{TRef, State1} ->
	    State2 = ?MODULE:Fun(State1),
	    schedule(State2, Interval, Fun, false);
	{_, State1} ->
	    State1;
	error ->
	    State
    end;
handle_info({download_file, URL, Size}, #{conn_options := ConnOpts} = State) ->
    Timeout = timer:seconds(rtb_config:get_option(connect_timeout)),
    case mod_xmpp_http:download(URL, Size, ConnOpts, Timeout) of
	ok ->
	    State;
	{error, Reason} ->
	    fail(State, mod_xmpp_http:format_error(Reason))
    end;
handle_info({proxy65_result, _, Result}, State) ->
    case Result of
	ok -> State;
	{error, Reason} ->
	    fail(State, mod_xmpp_proxy65:format_error(Reason))
    end;
handle_info(Info, State) ->
    lager:warning("Unexpected info: ~p", [Info]),
    State.

terminate(_Reason, #{conn_id := I, action := Action} = State) ->
    unregister(I, Action),
    try maps:get(stop_reason, State) of
	Reason ->
            incr_error(Reason),
	    lager:debug("~s terminated: ~s",
			[format_me(State), format_error(Reason)])
    catch _:{badkey, _} ->
	    ok
    end,
    State.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Stanza handlers
%%%===================================================================
handle_iq(#iq{type = T, id = ID} = IQ,
	  #{iq_requests := Reqs, action := Action} = State)
  when T == result; T == error ->
    case maps:take(ID, Reqs) of
	{{Callback, SendTime}, Reqs1} ->
	    State1 = State#{iq_requests => Reqs1},
	    RTT = current_time() - SendTime,
	    State2 = case Callback of
			 {Mod, Fun, Args} ->
			     apply(Mod, Fun, [State1, IQ, RTT|Args]);
			 Fun ->
			     ?MODULE:Fun(State1, IQ, RTT)
		     end,
	    case maps:size(Reqs1) of
		0 when Action /= send ->
		    case missing_services(State2) of
			[] ->
			    State3 = session_established(State2),
			    send_presence(State3);
			Features ->
			    From = jid:make(maps:get(server, State2)),
			    fail_missing_features(State2, From, Features)
		    end;
		_ ->
		    State2
	    end;
	error ->
	    lager:debug("Stray IQ response:~n~s~n** State: ~p",
			[xmpp:pp(IQ), State]),
	    State
    end;
handle_iq(#iq{type = set, from = From, lang = Lang} = IQ,
	  #{conn_options := ConnOpts, jid := JID} = State) ->
    try xmpp:try_subtag(IQ, #bytestreams{}) of
	#bytestreams{sid = SID, hosts = StreamHosts} ->
	    StreamHost = pick_random(StreamHosts),
	    #streamhost{host = Host, jid = Service, port = Port} = StreamHost,
	    Timeout = timer:seconds(rtb_config:get_option(connect_timeout)),
	    Hash = p1_sha:sha([SID, jid:encode(From), jid:encode(JID)]),
	    {Size, _} = string:to_integer(SID),
	    case mod_xmpp_proxy65:recv(
		   Host, Port, Hash, Size, ConnOpts, Timeout) of
		{ok, _} ->
		    Res = #bytestreams{sid = SID, used = Service},
		    send_pkt(State, xmpp:make_iq_result(IQ, Res));
		{error, Reason} ->
		    Txt = list_to_binary(mod_xmpp_proxy65:format_error(Reason)),
		    Err = xmpp:err_internal_server_error(Txt, Lang),
		    send_pkt(State, xmpp:make_error(IQ, Err)),
		    fail(State, mod_xmpp_proxy65:format_error(Reason))
	    end;
	false ->
	    send_iq_error(State, IQ)
    catch _:{xmpp_codec, Why} ->
	    Txt = xmpp:io_format_error(Why),
	    send_pkt(State, xmpp:serr_invalid_xml(Txt, Lang))
    end;
handle_iq(#iq{type = get, from = From, to = To, id = ID,
              sub_els = [#xmlel{name = <<"ping">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:ping">>}], children = []}]},
             State) ->

    send_pkt(State, #iq{id = ID, from = To, to = From, type = result});
handle_iq(IQ, State) ->
    send_iq_error(State, IQ).

handle_message(_, State) ->
    State.

handle_presence(_, State) ->
    State.

%%%===================================================================
%%% IQ callbacks
%%%===================================================================
disco_info_callback(#{lang := Lang, server := Server} = State,
		    #iq{type = result, from = From} = IQRes, RTT) ->
    rtb_stats:incr({'disco-info-rtt', RTT}),
    try xmpp:try_subtag(IQRes, #disco_info{}) of
	#disco_info{features = Fs} = Info ->
	    case From#jid.lserver of
		Server ->
		    case missing_disco_features(State, From, Fs) of
			[] -> State;
			Features ->
			    fail_missing_features(State, From, Features)
		    end;
		_ ->
		    process_service_info(State, From, Info)
	    end;
	false ->
	    Txt = io_lib:format("Invalid disco#info response from ~s: "
				"<query/> element is not found",
				[jid:encode(From)]),
	    fail(State, Txt)
    catch _:{xmpp_codec, Why} ->
	    Txt = xmpp:io_format_error(Why),
	    send_pkt(State, xmpp:serr_invalid_xml(Txt, Lang))
    end;
disco_info_callback(State, IQ, RTT) ->
    rtb_stats:incr({'disco-info-rtt', RTT}),
    case xmpp:get_error(IQ) of
	#stanza_error{reason = R} when R == 'service-unavailable';
				       R == 'feature-not-implemented' ->
	    State;
	_ ->
	    fail_iq_error(State, IQ, "Failed to request disco#info from ~s")
    end.

disco_items_callback(#{lang := Lang} = State,
		     #iq{type = result, from = From} = IQRes, RTT) ->
    rtb_stats:incr({'disco-items-rtt', RTT}),
    try xmpp:try_subtag(IQRes, #disco_items{}) of
	#disco_items{items = Items} ->
	    lists:foldl(
	      fun(#disco_item{jid = J}, StateAcc) ->
		      IQ = #iq{type = get, to = J,
			       sub_els = [#disco_info{}]},
		      send_iq(StateAcc, IQ, disco_info_callback)
	      end, State, Items);
	false ->
	    Txt = io_lib:format("Invalid disco#items response from ~s: "
				"<query/> element is not found",
				[jid:encode(From)]),
	    fail(State, Txt)
    catch _:{xmpp_codec, Why} ->
	    Txt = xmpp:io_format_error(Why),
	    send_pkt(State, xmpp:serr_invalid_xml(Txt, Lang))
    end;
disco_items_callback(State, IQ, RTT) ->
    rtb_stats:incr({'disco-items-rtt', RTT}),
    case xmpp:get_error(IQ) of
	#stanza_error{reason = R} when R == 'service-unavailable';
				       R == 'feature-not-implemented' ->
	    State;
	_ ->
	    fail_iq_error(State, IQ, "Failed to request disco#items from ~s")
    end.

carbons_set_callback(State, #iq{type = result}, RTT) ->
    rtb_stats:incr({'carbons-enable-rtt', RTT}),
    State;
carbons_set_callback(State, IQ, RTT) ->
    rtb_stats:incr({'carbons-enable-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to enable carbons for ~s").

blocklist_get_callback(State, #iq{type = result}, RTT) ->
    rtb_stats:incr({'block-list-get-rtt', RTT}),
    State;
blocklist_get_callback(State, IQ, RTT) ->
    rtb_stats:incr({'block-list-get-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to request blocklist for ~s").

private_get_callback(State, #iq{type = result}, RTT) ->
    rtb_stats:incr({'private-get-rtt', RTT}),
    State;
private_get_callback(State, IQ, RTT) ->
    rtb_stats:incr({'private-get-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to get bookmarks from private storage for ~s").

roster_get_callback(State, #iq{type = result}, RTT) ->
    rtb_stats:incr({'roster-get-rtt', RTT}),
    State;
roster_get_callback(State, IQ, RTT) ->
    rtb_stats:incr({'roster-get-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to request roster for ~s").

mam_prefs_set_callback(State, #iq{type = result}, RTT) ->
    rtb_stats:incr({'mam-prefs-set-rtt', RTT}),
    State;
mam_prefs_set_callback(State, IQ, RTT) ->
    rtb_stats:incr({'mam-prefs-set-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to set MAM preferences for ~s").

mam_query_callback(State, #iq{type = result}, RTT) ->
    rtb_stats:incr({'mam-query-rtt', RTT}),
    State;
mam_query_callback(State, IQ, RTT) ->
    rtb_stats:incr({'mam-query-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to query MAM archive for ~s").

upload_request_callback(#{lang := Lang} = State,
			#iq{type = result, from = From} = IQRes, RTT, Size) ->
    rtb_stats:incr({'upload-request-rtt', RTT}),
    try xmpp:try_subtag(IQRes, #upload_slot_0{xmlns = ?NS_HTTP_UPLOAD_0}) of
	#upload_slot_0{get = GetURL, put = PutURL} ->
	    perform_http_upload(State, Size, GetURL, PutURL);
	false ->
	    Txt = io_lib:format("Invalid HTTP upload slot response from ~s: "
				"<slot/> element is not found",
				[jid:encode(From)]),
	    fail(State, Txt)
    catch _:{xmpp_codec, Why} ->
	    Txt = xmpp:io_format_error(Why),
	    send_pkt(State, xmpp:serr_invalid_xml(Txt, Lang))
    end;
upload_request_callback(State, IQ, RTT, _) ->
    rtb_stats:incr({'upload-request-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to request an HTTP Upload slot from ~s").

proxy65_get_callback(#{lang := Lang} = State,
		     #iq{type = result, from = From} = IQRes, RTT) ->
    rtb_stats:incr({'proxy65-get-rtt', RTT}),
    try xmpp:try_subtag(IQRes, #bytestreams{}) of
	#bytestreams{hosts = []} ->
	    Txt = io_lib:format("Invalid bytestreams response from ~s: "
				"<streamhost/> element is not found",
				[jid:encode(From)]),
	    fail(State, Txt);
	#bytestreams{hosts = StreamHosts} ->
	    Size = p1_rand:uniform(rtb_config:get_option(proxy65_size)),
	    SID = <<(integer_to_binary(Size))/binary, $-,
		    (p1_rand:get_string())/binary>>,
	    case rtb_sm:random() of
		{ok, {_, _, USR}} ->
		    IQ = #iq{type = set, to = jid:make(USR),
			     sub_els = [#bytestreams{sid = SID,
						     hosts = StreamHosts}]},
		    send_iq(State, IQ, {?MODULE, proxy65_set_callback,
					[Size, SID, StreamHosts]});
		_ ->
		    State
	    end;
	false ->
	    Txt = io_lib:format("Invalid bytestreams response from ~s: "
				"<query/> element is not found",
				[jid:encode(From)]),
	    fail(State, Txt)
    catch _:{xmpp_codec, Why} ->
	    Txt = xmpp:io_format_error(Why),
	    send_pkt(State, xmpp:serr_invalid_xml(Txt, Lang))
    end;
proxy65_get_callback(State, IQ, RTT) ->
    rtb_stats:incr({'proxy65-get-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to request proxy65 streamhosts from ~s").

proxy65_set_callback(#{jid := JID, conn_options := ConnOpts} = State,
		     #iq{type = result, from = From, lang = Lang} = IQRes,
		     RTT, Size, SID, StreamHosts) ->
    rtb_stats:incr({'proxy65-set-rtt', RTT}),
    try xmpp:try_subtag(IQRes, #bytestreams{}) of
	#bytestreams{sid = SID, used = Used} ->
	    Hash = p1_sha:sha([SID, jid:encode(JID), jid:encode(From)]),
	    Timeout = timer:seconds(rtb_config:get_option(connect_timeout)),
	    case lists:keyfind(Used, #streamhost.jid, StreamHosts) of
		#streamhost{host = Host, port = Port} ->
		    case mod_xmpp_proxy65:connect(
			   Host, Port, Hash, Size, ConnOpts, Timeout) of
			{ok, Pid} ->
			    IQ = #iq{type = set, to = Used,
				     sub_els = [#bytestreams{
						   sid = SID,
						   activate = From}]},
			    send_iq(State, IQ,
				    {?MODULE, proxy65_activate_callback, [Pid]});
			{error, Reason} ->
			    fail(State, mod_xmpp_proxy65:format_error(Reason))
		    end;
		false ->
		    Txt = io_lib:format("Invalid bytestreams response from ~s: "
					"unexpected used streamhost",
					[jid:encode(From)]),
		    fail(State, Txt)
	    end;
	#bytestreams{} ->
	    Txt = io_lib:format("Invalid bytestreams response from ~s: "
				"unexpected sid",
				[jid:encode(From)]),
	    fail(State, Txt);
	false ->
	    Txt = io_lib:format("Invalid bytestreams response from ~s: "
				"<query/> element is not found",
				[jid:encode(From)]),
	    fail(State, Txt)
    catch _:{xmpp_codec, Why} ->
	    Txt = xmpp:io_format_error(Why),
	    send_pkt(State, xmpp:serr_invalid_xml(Txt, Lang))
    end;
proxy65_set_callback(State, IQ, RTT, _, _, _) ->
    rtb_stats:incr({'proxy65-set-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to set proxy65 streamhosts to ~s").

proxy65_activate_callback(State, #iq{type = result}, RTT, StreamPid) ->
    rtb_stats:incr({'proxy65-activate-rtt', RTT}),
    mod_xmpp_proxy65:activate(StreamPid),
    State;
proxy65_activate_callback(State, IQ, RTT, _) ->
    rtb_stats:incr({'proxy65-activate-rtt', RTT}),
    fail_iq_error(State, IQ, "Failed to activate proxy65 bytestream at ~s").

%%%===================================================================
%%% Scheduled actions
%%%===================================================================
send_message(State) ->
    To = case rtb_config:get_option(message_to) of
	     undefined ->
		 I = rtb_pool:random(),
		 make_jid(rtb_config:get_option(jid), I);
	     Pattern ->
		 make_jid(Pattern, maps:get(conn_id, State))
	 end,
    Payload = rtb_config:get_option(message_body),
    Msg = #message{to = To, body = xmpp:mk_text(Payload),
		   id = <<"message">>, type = chat},
    State1 = become(active, State),
    State2 = send_pkt(State1, Msg),
    become(inactive, State2).

send_presence(State) ->
    case rtb_config:get_option(presence_interval) of
	false -> State;
	_ -> send_pkt(State, #presence{})
    end.

upload_file(#{http_upload := {JID, Max}} = State) ->
    Size = p1_rand:uniform(Max),
    Filename = p1_rand:get_string(),
    IQ = #iq{to = JID, type = get,
	     sub_els = [#upload_request_0{
			   filename = Filename,
			   size = Size,
			   xmlns = ?NS_HTTP_UPLOAD_0}]},
    send_iq(State, IQ, {?MODULE, upload_request_callback, [Size]}).

proxy65_send_file(#{proxy65 := JID} = State) ->
    IQ = #iq{to = JID, type = get, sub_els = [#bytestreams{}]},
    send_iq(State, IQ, proxy65_get_callback).

disconnect(#{mgmt_timeout := MgmtTimeout} = State) ->
    State1 = xmpp_stream_out:close(State),
    State2 = cancel_timers(State1),
    reconnect_after(State2, MgmtTimeout);
disconnect(#{lang := Lang} = State) ->
    Txt = <<"Scheduled disconnection">>,
    send_pkt(State, xmpp:serr_reset(Txt, Lang)).

%%%===================================================================
%%% Internal functions
%%%===================================================================
format_error(Pkt) when ?is_stanza(Pkt) ->
    format_stanza_error(xmpp:get_error(Pkt));
format_error(#sm_failed{reason = Reason, text = Text}) ->
    format_stanza_error(#stanza_error{reason = Reason, text = Text});
format_error(Txt) when is_binary(Txt) ->
    Txt;
format_error(Reason) ->
    xmpp_stream_out:format_error(Reason).

format_stanza_error(undefined) ->
    <<"unspecified reason">>;
format_stanza_error(#stanza_error{} = Err) ->
    xmpp:format_stanza_error(Err).

format_me(#{conn_id := I, ip := {IP, _}}) ->
    [inet:ntoa(IP), $#, integer_to_list(I)];
format_me(#{conn_id := I, conn_addrs := [{IP, _, _}|_]}) ->
    [IP, $#, integer_to_list(I)];
format_me(#{conn_id := I}) ->
    [$#, integer_to_list(I)].

new_id() ->
    p1_rand:get_string().

-spec random_interval(seconds()) -> milli_seconds().
random_interval(0) ->
    0;
random_interval(Seconds) ->
    p1_rand:uniform(timer:seconds(Seconds)).

-spec pick_random([T]) -> T.
pick_random([_|_] = List) ->
    Pos = p1_rand:uniform(length(List)),
    lists:nth(Pos, List).

set_to(#{jid := JID}, Pkt) ->
    case xmpp:get_to(Pkt) of
	undefined ->
	    xmpp:set_to(Pkt, jid:remove_resource(JID));
	_ ->
	    Pkt
    end.

send_iq_requests(State) ->
    lists:foldl(
      fun({IQ, Callback}, StateAcc) ->
              send_iq(StateAcc, IQ, Callback)
      end, State, list_iq_requests(State)).

list_iq_requests(#{server := Server}) ->
    ServerJID = jid:make(Server),
    lists:filter(
      fun({_, carbons_set_callback}) -> rtb_config:get_option(carbons);
	 ({_, blocklist_get_callback}) -> rtb_config:get_option(blocklist);
	 ({_, roster_get_callback}) -> rtb_config:get_option(roster);
	 ({_, private_get_callback}) -> rtb_config:get_option(private);
	 ({_, mam_prefs_set_callback}) -> rtb_config:get_option(mam);
	 ({_, mam_query_callback}) -> rtb_config:get_option(mam);
	 (_) -> true
      end,
      [{#iq{type = get, to = ServerJID, sub_els = [#disco_info{}]},
	disco_info_callback},
       {#iq{type = get, sub_els = [#disco_info{}]},
	disco_info_callback},
       {#iq{type = get, to = ServerJID, sub_els = [#disco_items{}]},
	disco_items_callback},
       {#iq{type = set, sub_els = [#carbons_enable{}]},
	carbons_set_callback},
       {#iq{type = get, sub_els = [#block_list{}]},
	blocklist_get_callback},
       {begin
	    Ver = case rtb_config:get_option(rosterver) of
		      true -> <<"">>;
		      false -> undefined
		  end,
	    #iq{type = get, sub_els = [#roster_query{ver = Ver}]}
	end, roster_get_callback},
       {#iq{type = get, sub_els = [#private{sub_els = [#bookmark_storage{}]}]},
	private_get_callback},
       {#iq{type = set, sub_els = [#mam_prefs{xmlns = ?NS_MAM_2,
					      default = always}]},
	mam_prefs_set_callback},
       {#iq{type = set, sub_els = [#mam_query{xmlns = ?NS_MAM_2,
					      rsm = #rsm_set{max = 50}}]},
	mam_query_callback}]).

send_pkt(State, Pkt) when ?is_stanza(Pkt) ->
    case Pkt of
	#iq{} -> rtb_stats:incr('iq-out');
	#message{} -> rtb_stats:incr('message-out');
	#presence{} -> rtb_stats:incr('presence-out')
    end,
    Pkt1 = case xmpp:get_id(Pkt) of
	       I when I /= undefined andalso I /= <<"">> ->
		   Pkt;
	       _ ->
		   xmpp:set_id(Pkt, new_id())
	   end,
    Pkt2 = set_to(State, Pkt1),
    xmpp_stream_out:send(State, Pkt2);
send_pkt(State, Pkt) ->
    xmpp_stream_out:send(State, Pkt).

send_iq(#{iq_requests := Reqs} = State, IQ, Callback) ->
    ID = new_id(),
    Reqs1 = maps:put(ID, {Callback, current_time()}, Reqs),
    State1 = State#{iq_requests => Reqs1},
    send_pkt(State1, xmpp:set_id(IQ, ID)).

send_iq_error(State, #iq{type = T, lang = Lang} = IQ) when T == get; T == set ->
    Txt = <<"Unsupported IQ request">>,
    lager:warning("~s:~n~s", [Txt, xmpp:pp(IQ)]),
    Err = xmpp:make_error(IQ, xmpp:err_feature_not_implemented(Txt, Lang)),
    send_pkt(State, Err);
send_iq_error(State, _) ->
    State.

reset_state(State) ->
    State1 = maps:filter(
	       fun(mgmt_stanzas_in, _) -> false;
		  (mgmt_id, _) -> false;
		  (mgmt_resumed, _) -> false;
		  (mgmt_timeout, _) -> false;
		  (http_upload, _) -> false;
		  (proxy65, _) -> false;
		  (stream_features, _) -> false;
		  (_, _) -> true
	       end, State),
    State2 = cancel_timers(State1),
    State2#{iq_requests => #{}}.

unregister(I, _Action) ->
    rtb_sm:unregister(I),
    rtb_pool:unregister(self()).

reconnect_after(#{action := Action, conn_id := I} = State, Timeout) ->
    unregister(I, Action),
    {Timeout1, Factor} = maps:get(reconnect_after, State,
				  {random_interval(Timeout), 1}),
    Factor1 = Factor*2,
    State1 = State#{action => reconnect,
		    csi_state => active,
		    reconnect_after => {Timeout1*Factor1, Factor1},
		    conn_addrs => rtb:random_server()},
    xmpp_stream_out:set_timeout(State1, Timeout1).

session_established(#{user := U, server := S,
		      resource := R, conn_id := I} = State) ->
    rtb_sm:register(I, self(), {U, S, R}),
    State1 = State#{action => send, just_started => false},
    State2 = maps:remove(reconnect_after, State1),
    State3 = xmpp_stream_out:set_timeout(State2, infinity),
    State4 = schedule_all_actions(State3),
    become(inactive, State4).

current_time() ->
    p1_time_compat:monotonic_time(milli_seconds).

-spec missing_stream_features(state(), [binary()]) -> [{binary(), atom()}].
missing_stream_features(#{just_started := true}, Features) ->
    RequiredFeatureTags = [{#feature_csi{}, csi},
			   {#rosterver_feature{}, rosterver},
			   {#feature_sm{xmlns = ?NS_STREAM_MGMT_3}, sm}],
    Missed = lists:filter(
	       fun({FeatureTag, Opt}) ->
		       rtb_config:get_option(Opt) /= false andalso
			   not xmpp:has_subtag(Features, FeatureTag)
	       end, RequiredFeatureTags),
    [{xmpp:get_ns(FeatureTag), Opt} || {FeatureTag, Opt} <- Missed];
missing_stream_features(_, _) ->
    [].

-spec missing_disco_features(state(), jid(), [binary()]) -> [{binary(), atom()}].
missing_disco_features(#{just_started := true}, From, AdvertisedFeatures) ->
    RequiredFeatures = case From of
			   #jid{luser = U} when U /= <<"">> ->
			       [{?NS_MAM_2, mam}];
			   _ ->
			       [{?NS_CARBONS_2, carbons},
				{?NS_BLOCKING, blocklist}]
		       end,
    lists:filter(
      fun({Feature, Opt}) ->
	      rtb_config:get_option(Opt) /= false andalso
		  not lists:member(Feature, AdvertisedFeatures)
      end, RequiredFeatures);
missing_disco_features(_, _, _) ->
    [].

-spec missing_services(state()) -> [{binary(), atom()}].
missing_services(State) ->
    Services = [{?NS_HTTP_UPLOAD_0, http_upload_interval, http_upload},
		{?NS_BYTESTREAMS, proxy65_interval, proxy65}],
    lists:flatmap(
      fun({NS, Opt, Key}) ->
	      case rtb_config:get_option(Opt) of
		  false -> [];
		  _ ->
		      case maps:is_key(Key, State) of
			  true -> [];
			  false -> [{NS, Opt}]
		      end
	      end
      end, Services).

-spec process_service_info(state(), jid(), disco_info()) -> state().
process_service_info(State, From, #disco_info{features = Fs} = Info) ->
    case lists:foldl(
	   fun(_, {error, _} = Err) ->
		   Err;
	      (F, StateAcc) ->
		   process_service_info(F, StateAcc, From, Info)
	   end, State, Fs) of
	{error, Txt} ->
	    fail(State, Txt);
	State1 ->
	    State1
    end.

-spec process_service_info(binary(), state(), jid(), disco_info()) ->
				  state() | {error, iolist()}.
process_service_info(?NS_HTTP_UPLOAD_0, State, From, Info) ->
    ConfigMax = rtb_config:get_option(http_upload_size),
    case lists:foldl(
	   fun(#xdata{type = result, fields = Fs1}, Acc) ->
		   Val = try http_upload:decode(Fs1) of
			     Opts ->
				 proplists:get_value('max-file-size', Opts)
			 catch _:{http_upload, {form_type_mismatch, _}} ->
				 undefined
			 end,
		   min(Val, Acc);
	      (_, Acc) ->
		   Acc
	   end, ConfigMax, Info#disco_info.xdata) of
	undefined ->
	    Txt = io_lib:format(
		    "~s doesn't report max file size for HTTP Upload "
		    "and http_upload_size is not defined in the "
		    "config", [jid:encode(From)]),
	    {error, Txt};
	Max ->
	    State#{http_upload => {From, Max}}
    end;
process_service_info(?NS_BYTESTREAMS, State, From, _Info) ->
    State#{proxy65 => From};
process_service_info(_, State, _, _) ->
    State.

%% Send client state indication if needed
-spec become(active | inactive, state()) -> state().
become(T1, #{csi_state := T2} = State) when T1 /= T2 ->
    case rtb_config:get_option(csi) of
	true ->
	    send_pkt(State#{csi_state => T1}, #csi{type = T1});
	false ->
	    State
    end;
become(_, State) ->
    State.

fail(#{action := Action} = State, Reason) ->
    Txt = iolist_to_binary(Reason),
    case Action of
	send ->
            incr_error(Txt),
	    State;
	_ ->
	    State1 = State#{stop_reason => Txt},
	    send_pkt(State1, xmpp:serr_policy_violation())
    end.

fail_missing_features(State, From, FeaturesWithOpts) ->
    FeatureList = rtb:format_list([F || {F, _} <- FeaturesWithOpts]),
    OptionList = rtb:format_list([O || {_, O} <- FeaturesWithOpts]),
    S = if length(FeaturesWithOpts) > 1 -> "s";
	   true -> ""
	end,
    Txt = io_lib:format("~s doesn't support required feature~s: ~s. "
			"Set option~s ~s to false in order to ignore this.",
			[jid:encode(From), S, FeatureList, S, OptionList]),
    fail(State, Txt).

fail_iq_error(State, #iq{type = error, from = From} = IQ, Format) ->
    BFrom = jid:remove_resource(From),
    FromS = case From#jid.luser of
		<<>> -> jid:encode(BFrom);
		_ ->
		    {U, _, _} = rtb_config:get_option(jid),
		    User = rtb:replace(U, <<"*">>),
		    jid:encode(BFrom#jid{user = User, luser = User})
	    end,
    Txt = io_lib:format(Format ++ ": ~s", [FromS, format_error(IQ)]),
    fail(State, Txt).

incr_error({stream, {out, #stream_error{reason = 'reset'}}}) ->
    ok;
incr_error(Err) ->
    rtb_stats:incr('errors'),
    rtb_stats:incr({'error-reason', format_error(Err)}).

schedule_all_actions(State) ->
    lists:foldl(
      fun({IntervalName, FunName}, StateAcc) ->
	      schedule(StateAcc, IntervalName, FunName, true)
      end, State,
      [{message_interval, send_message},
       {presence_interval, send_presence},
       {http_upload_interval, upload_file},
       {proxy65_interval, proxy65_send_file},
       {disconnect_interval, disconnect}]).

schedule(#{action := send} = State, IntervalName, FunName, Randomize) ->
    case rtb_config:get_option(IntervalName) of
	false ->
	    State;
	Interval ->
	    MSecs = case Randomize of
			true -> random_interval(Interval);
			false -> timer:seconds(Interval)
		    end,
	    TRef = erlang:start_timer(MSecs, self(), {IntervalName, FunName}),
	    State#{FunName => TRef}
    end;
schedule(State, _, _, _) ->
    State.

cancel_timers(State) ->
    maps:filter(
      fun(Key, TRef) when Key == send_message;
			  Key == send_presence;
			  Key == upload_file;
			  Key == proxy65_send_file;
			  Key == disconnect ->
	      rtb:cancel_timer(TRef),
	      false;
	 (_, _) ->
	      true
      end, State).

perform_http_upload(#{conn_options := ConnOpts} = State, Size, GetURL, PutURL) ->
    URL = binary_to_list(PutURL),
    Timeout = timer:seconds(rtb_config:get_option(connect_timeout)),
    case mod_xmpp_http:upload(URL, Size, ConnOpts, Timeout) of
	ok ->
	    notify_file_receiver(State, binary_to_list(GetURL), Size);
	{error, Reason} ->
	    fail(State, mod_xmpp_http:format_error(Reason))
    end.

-spec notify_file_receiver(state(), string(), non_neg_integer()) -> state().
notify_file_receiver(State, GetURL, Size) ->
    case rtb_sm:random() of
	{ok, {Pid, _, _}} ->
	    Pid ! {download_file, GetURL, Size};
	{error, _} ->
	    ok
    end,
    State.

-spec prep_jid(binary()) -> jid_pattern().
prep_jid(JID) ->
    case jid:decode(JID) of
	#jid{luser = U, lserver = Server, lresource = R} when U /= <<>> ->
	    User = rtb:make_pattern(U),
	    Resource = rtb:make_pattern(R),
	    {User, Server, Resource}
    end.

-spec make_jid(jid_pattern(), integer()) -> jid:jid().
make_jid({U, Server, R}, I) ->
    User = rtb:replace(U, I),
    Resource = case R of
		   <<>> -> <<"rtb">>;
		   _ -> rtb:replace(R, I)
	       end,
    jid:make(User, Server, Resource).
