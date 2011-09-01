%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_amqqueue_process).
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-behaviour(gen_server2).

-define(UNSENT_MESSAGE_LIMIT,          100).
-define(SYNC_INTERVAL,                 25). %% milliseconds
-define(RAM_DURATION_UPDATE_INTERVAL,  5000).

-define(BASE_MESSAGE_PROPERTIES,
        #message_properties{expiry = undefined, needs_confirming = false}).

-export([start_link/1, info_keys/0]).

-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2, handle_pre_hibernate/1, prioritise_call/3,
         prioritise_cast/2, prioritise_info/2, format_message_queue/2]).

-export([init_with_backing_queue_state/7]).

-import(rabbit_misc, [serial_add/2, serial_diff/2]).

%% We need queue-like active consumers, but random access for
%% updating credit. This introduces an additional lookup step.

%% - update credit (channel has to know how to access queue)
%% - check credit on consumer when
%% - remove ctag version of procedures from limiter

%% In general the only invariant we maintain is that the blocked
%% consumer queue will contain only blocked consumers; the active
%% queue may also contain blocked consumers, which will be moved the
%% next time a delivery is attempted.

%% Queue's state
-record(q, {q,
            exclusive_consumer,
            has_had_consumers,
            backing_queue,
            backing_queue_state,
            active_consumers,
            blocked_consumers,
            credit_map,
            expires,
            sync_timer_ref,
            rate_timer_ref,
            expiry_timer_ref,
            stats_timer,
            msg_id_to_channel,
            ttl,
            ttl_timer_ref
           }).

-record(consumer, {tag, ack_required}).

-record(credit, {count = 0, credit = 0, drain = false}).

%% These are held in our process dictionary
-record(cr, {consumer_count,
             ch_pid,
             limiter,
             monitor_ref,
             acktags,
             is_limit_active,
             unsent_message_count}).

-define(STATISTICS_KEYS,
        [pid,
         exclusive_consumer_pid,
         exclusive_consumer_tag,
         messages_ready,
         messages_unacknowledged,
         messages,
         consumers,
         memory,
         slave_pids,
         backing_queue_status
        ]).

-define(CREATION_EVENT_KEYS,
        [pid,
         name,
         durable,
         auto_delete,
         arguments,
         owner_pid,
         slave_pids,
         synchronised_slave_pids
        ]).

-define(INFO_KEYS,
        ?CREATION_EVENT_KEYS ++ ?STATISTICS_KEYS -- [pid, slave_pids]).

%%----------------------------------------------------------------------------

start_link(Q) -> gen_server2:start_link(?MODULE, Q, []).

info_keys() -> ?INFO_KEYS.

%%----------------------------------------------------------------------------

init(Q) ->
    ?LOGDEBUG("Queue starting - ~p~n", [Q]),
    process_flag(trap_exit, true),

    {ok, #q{q                   = Q#amqqueue{pid = self()},
            exclusive_consumer  = none,
            has_had_consumers   = false,
            backing_queue       = backing_queue_module(Q),
            backing_queue_state = undefined,
            active_consumers    = queue:new(),
            blocked_consumers   = queue:new(),
            credit_map          = orddict:new(),
            expires             = undefined,
            sync_timer_ref      = undefined,
            rate_timer_ref      = undefined,
            expiry_timer_ref    = undefined,
            ttl                 = undefined,
            stats_timer         = rabbit_event:init_stats_timer(),
            msg_id_to_channel   = dict:new()}, hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

init_with_backing_queue_state(Q = #amqqueue{exclusive_owner = Owner}, BQ, BQS,
                              RateTRef, AckTags, Deliveries, MTC) ->
    ?LOGDEBUG("Queue starting - ~p~n", [Q]),
    case Owner of
        none -> ok;
        _    -> erlang:monitor(process, Owner)
    end,
    State = requeue_and_run(
              AckTags,
              process_args(
                #q{q                   = Q,
                   exclusive_consumer  = none,
                   has_had_consumers   = false,
                   backing_queue       = BQ,
                   backing_queue_state = BQS,
                   active_consumers    = queue:new(),
                   blocked_consumers   = queue:new(),
                   credit_map          = orddict:new(),
                   expires             = undefined,
                   sync_timer_ref      = undefined,
                   rate_timer_ref      = RateTRef,
                   expiry_timer_ref    = undefined,
                   ttl                 = undefined,
                   stats_timer         = rabbit_event:init_stats_timer(),
                   msg_id_to_channel   = MTC})),
    lists:foldl(
      fun (Delivery, StateN) -> deliver_or_enqueue(Delivery, StateN) end,
      State, Deliveries).

terminate(shutdown = R,      State = #q{backing_queue = BQ}) ->
    terminate_shutdown(fun (BQS) -> BQ:terminate(R, BQS) end, State);
terminate({shutdown, _} = R, State = #q{backing_queue = BQ}) ->
    terminate_shutdown(fun (BQS) -> BQ:terminate(R, BQS) end, State);
terminate(Reason,            State = #q{q             = #amqqueue{name = QName},
                                        backing_queue = BQ}) ->
    %% FIXME: How do we cancel active subscriptions?
    terminate_shutdown(fun (BQS) ->
                               rabbit_event:notify(
                                 queue_deleted, [{pid,  self()},
                                                 {name, QName}]),
                               BQS1 = BQ:delete_and_terminate(Reason, BQS),
                               %% don't care if the internal delete
                               %% doesn't return 'ok'.
                               rabbit_amqqueue:internal_delete(qname(State)),
                               BQS1
                       end, State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

declare(Recover, From,
        State = #q{q = Q, backing_queue = BQ, backing_queue_state = undefined,
                   stats_timer = StatsTimer}) ->
    case rabbit_amqqueue:internal_declare(Q, Recover) of
        not_found -> {stop, normal, not_found, State};
        Q         -> gen_server2:reply(From, {new, Q}),
                     ok = file_handle_cache:register_callback(
                            rabbit_amqqueue, set_maximum_since_use,
                            [self()]),
                     ok = rabbit_memory_monitor:register(
                            self(), {rabbit_amqqueue,
                                     set_ram_duration_target, [self()]}),
                     BQS = bq_init(BQ, Q, Recover),
                     State1 = process_args(State#q{backing_queue_state = BQS}),
                     rabbit_event:notify(queue_created,
                                         infos(?CREATION_EVENT_KEYS, State1)),
                     rabbit_event:if_enabled(StatsTimer,
                                             fun() -> emit_stats(State1) end),
                     noreply(State1);
        Q1        -> {stop, normal, {existing, Q1}, State}
    end.

bq_init(BQ, Q, Recover) ->
    Self = self(),
    BQ:init(Q, Recover,
            fun (Mod, Fun) ->
                    rabbit_amqqueue:run_backing_queue(Self, Mod, Fun)
            end).

process_args(State = #q{q = #amqqueue{arguments = Arguments}}) ->
    lists:foldl(fun({Arg, Fun}, State1) ->
                        case rabbit_misc:table_lookup(Arguments, Arg) of
                            {_Type, Val} -> Fun(Val, State1);
                            undefined    -> State1
                        end
                end, State, [{<<"x-expires">>,     fun init_expires/2},
                             {<<"x-message-ttl">>, fun init_ttl/2}]).

init_expires(Expires, State) -> ensure_expiry_timer(State#q{expires = Expires}).

init_ttl(TTL, State) -> drop_expired_messages(State#q{ttl = TTL}).

terminate_shutdown(Fun, State) ->
    State1 = #q{backing_queue_state = BQS} =
        stop_sync_timer(stop_rate_timer(State)),
    case BQS of
        undefined -> State1;
        _         -> ok = rabbit_memory_monitor:deregister(self()),
                     [emit_consumer_deleted(Ch, CTag)
                      || {Ch, CTag, _} <- consumers(State1)],
                     State1#q{backing_queue_state = Fun(BQS)}
    end.

reply(Reply, NewState) ->
    assert_invariant(NewState),
    {NewState1, Timeout} = next_state(NewState),
    {reply, Reply, NewState1, Timeout}.

noreply(NewState) ->
    assert_invariant(NewState),
    {NewState1, Timeout} = next_state(NewState),
    {noreply, NewState1, Timeout}.

next_state(State = #q{backing_queue = BQ, backing_queue_state = BQS}) ->
    {MsgIds, BQS1} = BQ:drain_confirmed(BQS),
    State1 = ensure_stats_timer(
               ensure_rate_timer(
                 confirm_messages(MsgIds, State#q{
                                            backing_queue_state = BQS1}))),
    case BQ:needs_timeout(BQS1) of
        false -> {stop_sync_timer(State1),   hibernate};
        idle  -> {stop_sync_timer(State1),   0        };
        timed -> {ensure_sync_timer(State1), 0        }
    end.

backing_queue_module(#amqqueue{arguments = Args}) ->
    case rabbit_misc:table_lookup(Args, <<"x-ha-policy">>) of
        undefined -> {ok, BQM} = application:get_env(backing_queue_module),
                     BQM;
        _Policy   -> rabbit_mirror_queue_master
    end.

ensure_sync_timer(State = #q{sync_timer_ref = undefined}) ->
    TRef = erlang:send_after(?SYNC_INTERVAL, self(), sync_timeout),
    State#q{sync_timer_ref = TRef};
ensure_sync_timer(State) ->
    State.

stop_sync_timer(State = #q{sync_timer_ref = undefined}) ->
    State;
stop_sync_timer(State = #q{sync_timer_ref = TRef}) ->
    erlang:cancel_timer(TRef),
    State#q{sync_timer_ref = undefined}.

ensure_rate_timer(State = #q{rate_timer_ref = undefined}) ->
    TRef = erlang:send_after(
             ?RAM_DURATION_UPDATE_INTERVAL, self(), update_ram_duration),
    State#q{rate_timer_ref = TRef};
ensure_rate_timer(State = #q{rate_timer_ref = just_measured}) ->
    State#q{rate_timer_ref = undefined};
ensure_rate_timer(State) ->
    State.

stop_rate_timer(State = #q{rate_timer_ref = undefined}) ->
    State;
stop_rate_timer(State = #q{rate_timer_ref = just_measured}) ->
    State#q{rate_timer_ref = undefined};
stop_rate_timer(State = #q{rate_timer_ref = TRef}) ->
    erlang:cancel_timer(TRef),
    State#q{rate_timer_ref = undefined}.

stop_expiry_timer(State = #q{expiry_timer_ref = undefined}) ->
    State;
stop_expiry_timer(State = #q{expiry_timer_ref = TRef}) ->
    erlang:cancel_timer(TRef),
    State#q{expiry_timer_ref = undefined}.

%% We wish to expire only when there are no consumers *and* the expiry
%% hasn't been refreshed (by queue.declare or basic.get) for the
%% configured period.
ensure_expiry_timer(State = #q{expires = undefined}) ->
    State;
ensure_expiry_timer(State = #q{expires = Expires}) ->
    case is_unused(State) of
        true ->
            NewState = stop_expiry_timer(State),
            TRef = erlang:send_after(Expires, self(), maybe_expire),
            NewState#q{expiry_timer_ref = TRef};
        false ->
            State
    end.

ensure_stats_timer(State = #q{stats_timer = StatsTimer,
                              q = #amqqueue{pid = QPid}}) ->
    State#q{stats_timer = rabbit_event:ensure_stats_timer(
                            StatsTimer, QPid, emit_stats)}.

assert_invariant(#q{active_consumers = AC,
                    backing_queue = BQ, backing_queue_state = BQS}) ->
    true = (queue:is_empty(AC) orelse BQ:is_empty(BQS)).

lookup_ch(ChPid) ->
    case get({ch, ChPid}) of
        undefined -> not_found;
        C         -> C
    end.

ch_record(ChPid) ->
    Key = {ch, ChPid},
    case get(Key) of
        undefined -> MonitorRef = erlang:monitor(process, ChPid),
                     C = #cr{consumer_count       = 0,
                             ch_pid               = ChPid,
                             monitor_ref          = MonitorRef,
                             acktags              = sets:new(),
                             is_limit_active      = false,
                             limiter              = rabbit_limiter:make_token(),
                             unsent_message_count = 0},
                     put(Key, C),
                     C;
        C = #cr{} -> C
    end.

store_ch_record(C = #cr{ch_pid = ChPid}) ->
    put({ch, ChPid}, C).

maybe_store_ch_record(C = #cr{consumer_count       = ConsumerCount,
                              acktags              = ChAckTags,
                              unsent_message_count = UnsentMessageCount}) ->
    case {sets:size(ChAckTags), ConsumerCount, UnsentMessageCount} of
        {0, 0, 0} -> ok = erase_ch_record(C),
                     false;
        _         -> store_ch_record(C),
                     true
    end.

erase_ch_record(#cr{ch_pid      = ChPid,
                    limiter     = Limiter,
                    monitor_ref = MonitorRef}) ->
    ok = rabbit_limiter:unregister(Limiter, self()),
    erlang:demonitor(MonitorRef),
    erase({ch, ChPid}),
    ok.

all_ch_record() -> [C || {{ch, _}, C} <- get()].

is_ch_blocked(#cr{unsent_message_count = Count, is_limit_active = Limited}) ->
    Limited orelse Count >= ?UNSENT_MESSAGE_LIMIT.

ch_record_state_transition(OldCR, NewCR) ->
    case {is_ch_blocked(OldCR), is_ch_blocked(NewCR)} of
        {true, false} -> unblock;
        {false, true} -> block;
        {_, _}        -> ok
    end.

consumer_credit(CTag, Map) ->
    case orddict:find(CTag, Map) of
        error ->
            unlimited;
        {ok, CreditRec} ->
            CreditRec
    end.

erase_credit(CTag, Map) ->
    orddict:erase(CTag, Map).

%% NB assumes nothing can become unlimited
store_credit(_, unlimited, Map) ->
    Map;
store_credit(CTag, CreditRec, Map) ->
    orddict:store(CTag, CreditRec, Map).

credit_left(#credit{ credit = 0 }) ->
    false;
credit_left(_) ->
    true.

in_drain_mode(#credit{ drain = true }) ->
    true;
in_drain_mode(_) ->
    false.

decr_credit(unlimited, _) ->
    unlimited;
decr_credit(#credit{ credit = Credit, count = Count, drain = Drain }, Available) ->
    {NewCredit, NewCount} =
        case {Credit, Available, Drain} of
            {1, _, _}    -> {0, serial_add(Count, 1)};
            {_, 1, true} ->
                %% Drain, and just the message we're about to send
                %% left, so advance til credit = 0
                NewCount0 = serial_add(Count, Credit),
                {0, NewCount0};
            {_, _, _}    -> {Credit - 1, serial_add(Count, 1)}
        end,
    #credit{ credit = NewCredit, count = NewCount, drain = Drain }.

%% Assert the credit state.  The count may not match ours, in which
%% case we must rebase the credit.
%% TODO Edge case: if the queue has nothing in it, and drain is set,
%% we want to send a basic.credit back.
reset_credit(CTag, Credit0, Count0, Drain, EchoTo,
             State = #q{credit_map = CreditMap,
                        active_consumers = Active,
                        blocked_consumers = Blocked,
                        backing_queue = BQ,
                        backing_queue_state = BQS}) ->
    CreditRec = consumer_credit(CTag, CreditMap),
    {NewMap, NewRec} =
        case {CreditRec, Credit0} of
            {#credit{count = LocalCount}, _} ->
                %% Our credit may have been reduced while
                %% messages are in flight, so we bottom out at 0.
                Credit = erlang:max(0, serial_diff(
                                         serial_add(Count0, Credit0),
                                         LocalCount)),
                NC = #credit{count = LocalCount,
                             credit = Credit,
                             drain = Drain},
                {store_credit(CTag, NC, CreditMap), NC};
            {unlimited, Credit0} ->
                NC = #credit{count = Count0,
                             credit = Credit0,
                             drain = Drain},
                {store_credit(CTag, NC, CreditMap), NC}
        end,
    {NewActive, NewBlocked} =
        case {credit_left(CreditRec), credit_left(NewRec)} of
            {false, true} ->
                %% We may have put this consumer on the blocked queue. Try
                %% to move it back.
                case split_consumer(CTag, Blocked) of
                    {none, Blocked} ->
                        {Active, Blocked};
                    {Consumer, Blocked1} ->
                        {queue:in(Consumer, Active), Blocked1}
                end;
            {_, _} ->
                {Active, Blocked}
        end,
    case EchoTo of
        undefined ->
            ok;
        ChPid ->
            Available = BQ:len(BQS),
            #credit{ count = Count1, credit = Credit1, drain = Drain1} = NewRec,
            rabbit_channel:send_credit(ChPid, CTag, Count1, Credit1, Available, Drain1)
    end,
    run_message_queue(State#q{credit_map = NewMap,
            active_consumers = NewActive,
            blocked_consumers = NewBlocked}).

deliver_msgs_to_consumers(Funs = {PredFun, DeliverFun}, FunAcc,
                          State = #q{q = #amqqueue{name = QName},
                                     active_consumers = ActiveConsumers,
                                     blocked_consumers = BlockedConsumers,
                                     credit_map = CreditMap,
                                     backing_queue = BQ,
                                     backing_queue_state = BQS}) ->
    case queue:out(ActiveConsumers) of
        {{value, QEntry = {ChPid, #consumer{tag = ConsumerTag,
                                            ack_required = AckRequired}}},
         ActiveConsumersTail} ->
            C = #cr{limiter              = Limiter,
                    unsent_message_count = Count,
                    acktags = ChAckTags} = ch_record(ChPid),
            IsMsgReady = PredFun(FunAcc, State),
            Credit = consumer_credit(ConsumerTag, CreditMap),
            case (IsMsgReady andalso
                  credit_left(Credit) andalso
                  rabbit_limiter:can_send(Limiter, self(), AckRequired)) of
                true ->
                    {{Message, IsDelivered, AckTag}, FunAcc1, State1} =
                        DeliverFun(AckRequired, FunAcc, State),
                    rabbit_channel:deliver(
                      ChPid, ConsumerTag, AckRequired,
                      {QName, self(), AckTag, IsDelivered, Message}),
                    ChAckTags1 =
                        case AckRequired of
                            true  -> sets:add_element(AckTag, ChAckTags);
                            false -> ChAckTags
                        end,
                    NewC = C#cr{unsent_message_count = Count + 1,
                                acktags = ChAckTags1},
                    true = maybe_store_ch_record(NewC),
                    Available = BQ:len(BQS),
                    NewCreditRec = decr_credit(Credit, Available),
                    case in_drain_mode(NewCreditRec) andalso
                        not credit_left(NewCreditRec) of
                        true ->
                            #credit{ count = NewCount } = NewCreditRec,
                            rabbit_channel:send_credit(
                              ChPid, ConsumerTag, NewCount,
                              0, Available - 1, true);
                        _ -> ok
                    end,
                    {NewActiveConsumers, NewBlockedConsumers} =
                        case ch_record_state_transition(C, NewC) of
                            ok ->
                                case credit_left(NewCreditRec) of
                                    true ->
                                        {queue:in(QEntry, ActiveConsumersTail),
                                         BlockedConsumers};
                                    false ->
                                        {ActiveConsumersTail,
                                         queue:in(QEntry, BlockedConsumers)}
                                end;
                            block ->
                                {ActiveConsumers1, BlockedConsumers1} =
                                    move_consumers(ChPid,
                                                   ActiveConsumersTail,
                                                   BlockedConsumers),
                                {ActiveConsumers1,
                                 queue:in(QEntry, BlockedConsumers1)}
                        end,
                    State2 = State1#q{
                               active_consumers = NewActiveConsumers,
                               blocked_consumers = NewBlockedConsumers,
                               credit_map = store_credit(ConsumerTag,
                                                         NewCreditRec,
                                                         CreditMap)},
                    deliver_msgs_to_consumers(Funs, FunAcc1, State2);
                %% IsMsgReady then we've hit the limiter or there's no
                %% credit
                false when IsMsgReady ->
                    {NewActiveConsumers, NewBlockedConsumers} =
                        case credit_left(Credit) of
                            true ->
                                true = maybe_store_ch_record(
                                         C#cr{is_limit_active = true}),
                                move_consumers(ChPid,
                                               ActiveConsumers,
                                               BlockedConsumers);
                            false ->
                                {ActiveConsumersTail,
                                 queue:in(QEntry, BlockedConsumers)}
                        end,
                    deliver_msgs_to_consumers(
                      Funs, FunAcc,
                      State#q{active_consumers = NewActiveConsumers,
                              blocked_consumers = NewBlockedConsumers});
                false ->
                    %% no message was ready, so we don't need to block anyone
                    {FunAcc, State}
            end;
        {empty, _} ->
            {FunAcc, State}
    end.

deliver_from_queue_pred(IsEmpty, _State) -> not IsEmpty.

deliver_from_queue_deliver(AckRequired, false, State) ->
    {{Message, IsDelivered, AckTag, Remaining}, State1} =
        fetch(AckRequired, State),
    {{Message, IsDelivered, AckTag}, 0 == Remaining, State1}.

confirm_messages([], State) ->
    State;
confirm_messages(MsgIds, State = #q{msg_id_to_channel = MTC}) ->
    {CMs, MTC1} = lists:foldl(
                    fun(MsgId, {CMs, MTC0}) ->
                            case dict:find(MsgId, MTC0) of
                                {ok, {ChPid, MsgSeqNo}} ->
                                    {gb_trees_cons(ChPid, MsgSeqNo, CMs),
                                     dict:erase(MsgId, MTC0)};
                                _ ->
                                    {CMs, MTC0}
                            end
                    end, {gb_trees:empty(), MTC}, MsgIds),
    gb_trees_foreach(fun rabbit_channel:confirm/2, CMs),
    State#q{msg_id_to_channel = MTC1}.

gb_trees_foreach(_, none) ->
    ok;
gb_trees_foreach(Fun, {Key, Val, It}) ->
    Fun(Key, Val),
    gb_trees_foreach(Fun, gb_trees:next(It));
gb_trees_foreach(Fun, Tree) ->
    gb_trees_foreach(Fun, gb_trees:next(gb_trees:iterator(Tree))).

gb_trees_cons(Key, Value, Tree) ->
    case gb_trees:lookup(Key, Tree) of
        {value, Values} -> gb_trees:update(Key, [Value | Values], Tree);
        none            -> gb_trees:insert(Key, [Value], Tree)
    end.

should_confirm_message(#delivery{msg_seq_no = undefined}, _State) ->
    never;
should_confirm_message(#delivery{sender     = ChPid,
                                 msg_seq_no = MsgSeqNo,
                                 message    = #basic_message {
                                   is_persistent = true,
                                   id            = MsgId}},
                       #q{q = #amqqueue{durable = true}}) ->
    {eventually, ChPid, MsgSeqNo, MsgId};
should_confirm_message(_Delivery, _State) ->
    immediately.

needs_confirming({eventually, _, _, _}) -> true;
needs_confirming(_)                     -> false.

maybe_record_confirm_message({eventually, ChPid, MsgSeqNo, MsgId},
                             State = #q{msg_id_to_channel = MTC}) ->
    State#q{msg_id_to_channel = dict:store(MsgId, {ChPid, MsgSeqNo}, MTC)};
maybe_record_confirm_message(_Confirm, State) ->
    State.

run_message_queue(State) ->
    Funs = {fun deliver_from_queue_pred/2,
            fun deliver_from_queue_deliver/3},
    State1 = #q{backing_queue = BQ, backing_queue_state = BQS} =
        drop_expired_messages(State),
    IsEmpty = BQ:is_empty(BQS),
    {_IsEmpty1, State2} = deliver_msgs_to_consumers(Funs, IsEmpty, State1),
    State2.

attempt_delivery(Delivery = #delivery{sender     = ChPid,
                                      message    = Message,
                                      msg_seq_no = MsgSeqNo},
                 State = #q{backing_queue = BQ, backing_queue_state = BQS}) ->
    Confirm = should_confirm_message(Delivery, State),
    case Confirm of
        immediately -> rabbit_channel:confirm(ChPid, [MsgSeqNo]);
        _           -> ok
    end,
    case BQ:is_duplicate(Message, BQS) of
        {false, BQS1} ->
            PredFun = fun (IsEmpty, _State) -> not IsEmpty end,
            DeliverFun =
                fun (AckRequired, false,
                     State1 = #q{backing_queue_state = BQS2}) ->
                        %% we don't need an expiry here because
                        %% messages are not being enqueued, so we use
                        %% an empty message_properties.
                        {AckTag, BQS3} =
                            BQ:publish_delivered(
                              AckRequired, Message,
                              (?BASE_MESSAGE_PROPERTIES)#message_properties{
                                needs_confirming = needs_confirming(Confirm)},
                              ChPid, BQS2),
                        {{Message, false, AckTag}, true,
                         State1#q{backing_queue_state = BQS3}}
                end,
            {Delivered, State2} =
                deliver_msgs_to_consumers({ PredFun, DeliverFun }, false,
                                          State#q{backing_queue_state = BQS1}),
            {Delivered, Confirm, State2};
        {Duplicate, BQS1} ->
            %% if the message has previously been seen by the BQ then
            %% it must have been seen under the same circumstances as
            %% now: i.e. if it is now a deliver_immediately then it
            %% must have been before.
            Delivered = case Duplicate of
                            published -> true;
                            discarded -> false
                        end,
            {Delivered, Confirm, State#q{backing_queue_state = BQS1}}
    end.

deliver_or_enqueue(Delivery = #delivery{message = Message,
                                        sender  = ChPid}, State) ->
    {Delivered, Confirm, State1} = attempt_delivery(Delivery, State),
    State2 = #q{backing_queue = BQ, backing_queue_state = BQS} =
        maybe_record_confirm_message(Confirm, State1),
    case Delivered of
        true  -> State2;
        false -> BQS1 =
                     BQ:publish(Message,
                                (message_properties(State)) #message_properties{
                                  needs_confirming = needs_confirming(Confirm)},
                                ChPid, BQS),
                 ensure_ttl_timer(State2#q{backing_queue_state = BQS1})
    end.

requeue_and_run(AckTags, State = #q{backing_queue = BQ, ttl=TTL}) ->
    run_backing_queue(
      BQ, fun (M, BQS) ->
                  {_MsgIds, BQS1} =
                      M:requeue(AckTags, reset_msg_expiry_fun(TTL), BQS),
                  BQS1
          end, State).

fetch(AckRequired, State = #q{backing_queue_state = BQS,
                              backing_queue       = BQ}) ->
    {Result, BQS1} = BQ:fetch(AckRequired, BQS),
    {Result, State#q{backing_queue_state = BQS1}}.

with_consumer(ChPid, Consumer, Queue) -> queue:in({ChPid, Consumer}, Queue).

without_consumer(ChPid, ConsumerTag, Queue) ->
    queue:filter(fun ({CP, #consumer{tag = CT}}) ->
                         (CP /= ChPid) or (CT /= ConsumerTag)
                 end, Queue).

split_consumer(ConsumerTag, Queue) ->
    {MaybeConsumer, Remainder} =
        lists:partition(fun({_Ch, #consumer{tag = CT}}) ->
                                CT == ConsumerTag
                        end, queue:to_list(Queue)),
    case MaybeConsumer of
        [] ->
            {none, Queue};
        [Consumer] ->
            {Consumer, queue:from_list(Remainder)}
    end.

remove_consumers(ChPid, Queue, CreditMap) ->
    {Kept, Removed} = split_by_channel(ChPid, Queue),
    NewCreditMap = lists:foldl(fun({Ch, #consumer{tag = CTag}}, Map) ->
                                       emit_consumer_deleted(Ch, CTag),
                                       erase_credit(CTag, Map)
                               end, CreditMap, queue:to_list(Removed)),
    {Kept, NewCreditMap}.

move_consumers(ChPid, From, To) ->
    {Kept, Removed} = split_by_channel(ChPid, From),
    {Kept, queue:join(To, Removed)}.

split_by_channel(ChPid, Queue) ->
    {Kept, Removed} = lists:partition(fun ({CP, _}) -> CP /= ChPid end,
                                      queue:to_list(Queue)),
    {queue:from_list(Kept), queue:from_list(Removed)}.

possibly_unblock(State, ChPid, Update) ->
    case lookup_ch(ChPid) of
        not_found ->
            State;
        C ->
            NewC = Update(C),
            maybe_store_ch_record(NewC),
            case ch_record_state_transition(C, NewC) of
                ok      -> State;
                unblock -> {NewBlockedConsumers, NewActiveConsumers} =
                               move_consumers(ChPid,
                                              State#q.blocked_consumers,
                                              State#q.active_consumers),
                           run_message_queue(
                             State#q{active_consumers = NewActiveConsumers,
                                     blocked_consumers = NewBlockedConsumers})
            end
    end.

should_auto_delete(#q{q = #amqqueue{auto_delete = false}}) -> false;
should_auto_delete(#q{has_had_consumers = false}) -> false;
should_auto_delete(State) -> is_unused(State).

handle_ch_down(DownPid, State = #q{exclusive_consumer = Holder,
                                   credit_map = CreditMap }) ->
    case lookup_ch(DownPid) of
        not_found ->
            {ok, State};
        C = #cr{ch_pid = ChPid, acktags = ChAckTags} ->
            ok = erase_ch_record(C),
            {ActiveConsumers, CreditMap1} =
                remove_consumers(ChPid, State#q.active_consumers, CreditMap),
            {BlockedConsumers, CreditMap2} =
                remove_consumers(ChPid, State#q.blocked_consumers, CreditMap1),
            State1 = State#q{
                       exclusive_consumer = case Holder of
                                                {ChPid, _} -> none;
                                                Other      -> Other
                                            end,
                       active_consumers = ActiveConsumers,
                       blocked_consumers = BlockedConsumers,
                       credit_map = CreditMap2},
            case should_auto_delete(State1) of
                true  -> {stop, State1};
                false -> {ok, requeue_and_run(sets:to_list(ChAckTags),
                                              ensure_expiry_timer(State1))}
            end
    end.

cancel_holder(ChPid, ConsumerTag, {ChPid, ConsumerTag}) ->
    none;
cancel_holder(_ChPid, _ConsumerTag, Holder) ->
    Holder.

check_exclusive_access({_ChPid, _ConsumerTag}, _ExclusiveConsume, _State) ->
    in_use;
check_exclusive_access(none, false, _State) ->
    ok;
check_exclusive_access(none, true, State) ->
    case is_unused(State) of
        true  -> ok;
        false -> in_use
    end.

is_unused(State) -> queue:is_empty(State#q.active_consumers) andalso
                        queue:is_empty(State#q.blocked_consumers).

maybe_send_reply(_ChPid, undefined) -> ok;
maybe_send_reply(ChPid, Msg) -> ok = rabbit_channel:send_command(ChPid, Msg).

qname(#q{q = #amqqueue{name = QName}}) -> QName.

backing_queue_timeout(State = #q{backing_queue = BQ}) ->
    run_backing_queue(BQ, fun (M, BQS) -> M:timeout(BQS) end, State).

run_backing_queue(Mod, Fun, State = #q{backing_queue = BQ,
                                       backing_queue_state = BQS}) ->
    run_message_queue(State#q{backing_queue_state = BQ:invoke(Mod, Fun, BQS)}).

subtract_acks(A, B) when is_list(B) ->
    lists:foldl(fun sets:del_element/2, A, B).

discard_delivery(#delivery{sender = ChPid,
                           message = Message},
                 State = #q{backing_queue = BQ,
                            backing_queue_state = BQS}) ->
    State#q{backing_queue_state = BQ:discard(Message, ChPid, BQS)}.

reset_msg_expiry_fun(TTL) ->
    fun(MsgProps) ->
            MsgProps#message_properties{expiry = calculate_msg_expiry(TTL)}
    end.

message_properties(#q{ttl=TTL}) ->
    #message_properties{expiry = calculate_msg_expiry(TTL)}.

calculate_msg_expiry(undefined) -> undefined;
calculate_msg_expiry(TTL)       -> now_micros() + (TTL * 1000).

drop_expired_messages(State = #q{ttl = undefined}) ->
    State;
drop_expired_messages(State = #q{backing_queue_state = BQS,
                                 backing_queue = BQ}) ->
    Now = now_micros(),
    BQS1 = BQ:dropwhile(
             fun (#message_properties{expiry = Expiry}) -> Now > Expiry end,
             BQS),
    ensure_ttl_timer(State#q{backing_queue_state = BQS1}).

ensure_ttl_timer(State = #q{backing_queue       = BQ,
                            backing_queue_state = BQS,
                            ttl                 = TTL,
                            ttl_timer_ref       = undefined})
  when TTL =/= undefined ->
    case BQ:is_empty(BQS) of
        true  -> State;
        false -> TRef = erlang:send_after(TTL, self(), drop_expired),
                 State#q{ttl_timer_ref = TRef}
    end;
ensure_ttl_timer(State) ->
    State.

now_micros() -> timer:now_diff(now(), {0,0,0}).

infos(Items, State) ->
    {Prefix, Items1} =
        case lists:member(synchronised_slave_pids, Items) of
            true  -> Prefix1 = slaves_status(State),
                     case lists:member(slave_pids, Items) of
                         true  -> {Prefix1, Items -- [slave_pids]};
                         false -> {proplists:delete(slave_pids, Prefix1), Items}
                     end;
            false -> {[], Items}
        end,
    Prefix ++ [{Item, i(Item, State)}
               || Item <- (Items1 -- [synchronised_slave_pids])].

slaves_status(#q{q = #amqqueue{name = Name}}) ->
    {ok, #amqqueue{mirror_nodes = MNodes, slave_pids = SPids}} =
        rabbit_amqqueue:lookup(Name),
    case MNodes of
        undefined ->
            [{slave_pids, ''}, {synchronised_slave_pids, ''}];
        _ ->
            {Results, _Bad} =
                delegate:invoke(
                  SPids, fun (Pid) -> rabbit_mirror_queue_slave:info(Pid) end),
            {SPids1, SSPids} =
                lists:foldl(
                  fun ({Pid, Infos}, {SPidsN, SSPidsN}) ->
                          {[Pid | SPidsN],
                           case proplists:get_bool(is_synchronised, Infos) of
                               true  -> [Pid | SSPidsN];
                               false -> SSPidsN
                           end}
                  end, {[], []}, Results),
            [{slave_pids, SPids1}, {synchronised_slave_pids, SSPids}]
    end.

i(name,        #q{q = #amqqueue{name        = Name}})       -> Name;
i(durable,     #q{q = #amqqueue{durable     = Durable}})    -> Durable;
i(auto_delete, #q{q = #amqqueue{auto_delete = AutoDelete}}) -> AutoDelete;
i(arguments,   #q{q = #amqqueue{arguments   = Arguments}})  -> Arguments;
i(pid, _) ->
    self();
i(owner_pid, #q{q = #amqqueue{exclusive_owner = none}}) ->
    '';
i(owner_pid, #q{q = #amqqueue{exclusive_owner = ExclusiveOwner}}) ->
    ExclusiveOwner;
i(exclusive_consumer_pid, #q{exclusive_consumer = none}) ->
    '';
i(exclusive_consumer_pid, #q{exclusive_consumer = {ChPid, _ConsumerTag}}) ->
    ChPid;
i(exclusive_consumer_tag, #q{exclusive_consumer = none}) ->
    '';
i(exclusive_consumer_tag, #q{exclusive_consumer = {_ChPid, ConsumerTag}}) ->
    ConsumerTag;
i(messages_ready, #q{backing_queue_state = BQS, backing_queue = BQ}) ->
    BQ:len(BQS);
i(messages_unacknowledged, _) ->
    lists:sum([sets:size(C#cr.acktags) || C <- all_ch_record()]);
i(messages, State) ->
    lists:sum([i(Item, State) || Item <- [messages_ready,
                                          messages_unacknowledged]]);
i(consumers, State) ->
    queue:len(State#q.active_consumers) + queue:len(State#q.blocked_consumers);
i(memory, _) ->
    {memory, M} = process_info(self(), memory),
    M;
i(slave_pids, #q{q = #amqqueue{name = Name}}) ->
    {ok, #amqqueue{mirror_nodes = MNodes,
                   slave_pids = SPids}} = rabbit_amqqueue:lookup(Name),
    case MNodes of
        undefined -> [];
        _         -> SPids
    end;
i(backing_queue_status, #q{backing_queue_state = BQS, backing_queue = BQ}) ->
    BQ:status(BQS);
i(Item, _) ->
    throw({bad_argument, Item}).

consumers(#q{active_consumers = ActiveConsumers,
             blocked_consumers = BlockedConsumers}) ->
    rabbit_misc:queue_fold(
      fun ({ChPid, #consumer{tag = ConsumerTag,
                             ack_required = AckRequired}}, Acc) ->
              [{ChPid, ConsumerTag, AckRequired} | Acc]
      end, [], queue:join(ActiveConsumers, BlockedConsumers)).

emit_stats(State) ->
    emit_stats(State, []).

emit_stats(State, Extra) ->
    rabbit_event:notify(queue_stats, Extra ++ infos(?STATISTICS_KEYS, State)).

emit_consumer_created(ChPid, ConsumerTag, Exclusive, AckRequired) ->
    rabbit_event:notify(consumer_created,
                        [{consumer_tag, ConsumerTag},
                         {exclusive,    Exclusive},
                         {ack_required, AckRequired},
                         {channel,      ChPid},
                         {queue,        self()}]).

emit_consumer_deleted(ChPid, ConsumerTag) ->
    rabbit_event:notify(consumer_deleted,
                        [{consumer_tag, ConsumerTag},
                         {channel,      ChPid},
                         {queue,        self()}]).

%%----------------------------------------------------------------------------

prioritise_call(Msg, _From, _State) ->
    case Msg of
        info                                 -> 9;
        {info, _Items}                       -> 9;
        consumers                            -> 9;
        {basic_consume, _, _, _, _, _, _}    -> 7;
        {basic_cancel, _, _, _}              -> 7;
        stat                                 -> 7;
        _                                    -> 0
    end.

prioritise_cast(Msg, _State) ->
    case Msg of
        delete_immediately                   -> 8;
        {set_ram_duration_target, _Duration} -> 8;
        {set_maximum_since_use, _Age}        -> 8;
        {ack, _AckTags, _ChPid}              -> 7;
        {reject, _AckTags, _Requeue, _ChPid} -> 7;
        {notify_sent, _ChPid}                -> 7;
        {unblock, _ChPid}                    -> 7;
        {run_backing_queue, _Mod, _Fun}      -> 6;
        _                                    -> 0
    end.

prioritise_info(Msg, #q{q = #amqqueue{exclusive_owner = DownPid}}) ->
    case Msg of
        {'DOWN', _, process, DownPid, _}     -> 8;
        update_ram_duration                  -> 8;
        maybe_expire                         -> 8;
        drop_expired                         -> 8;
        emit_stats                           -> 7;
        sync_timeout                         -> 6;
        _                                    -> 0
    end.

handle_call({init, Recover}, From,
            State = #q{q = #amqqueue{exclusive_owner = none}}) ->
    declare(Recover, From, State);

handle_call({init, Recover}, From,
            State = #q{q = #amqqueue{exclusive_owner = Owner}}) ->
    case rabbit_misc:is_process_alive(Owner) of
        true  -> erlang:monitor(process, Owner),
                 declare(Recover, From, State);
        false -> #q{backing_queue = BQ, backing_queue_state = undefined,
                    q = #amqqueue{name = QName} = Q} = State,
                 gen_server2:reply(From, not_found),
                 case Recover of
                     true -> ok;
                     _    -> rabbit_log:warning(
                               "Queue ~p exclusive owner went away~n", [QName])
                 end,
                 BQS = bq_init(BQ, Q, Recover),
                 %% Rely on terminate to delete the queue.
                 {stop, normal, State#q{backing_queue_state = BQS}}
    end;

handle_call(info, _From, State) ->
    reply(infos(?INFO_KEYS, State), State);

handle_call({info, Items}, _From, State) ->
    try
        reply({ok, infos(Items, State)}, State)
    catch Error -> reply({error, Error}, State)
    end;

handle_call(consumers, _From, State) ->
    reply(consumers(State), State);

handle_call({deliver_immediately, Delivery}, _From, State) ->
    %% Synchronous, "immediate" delivery mode
    %%
    %% FIXME: Is this correct semantics?
    %%
    %% I'm worried in particular about the case where an exchange has
    %% two queues against a particular routing key, and a message is
    %% sent in immediate mode through the binding. In non-immediate
    %% mode, both queues get the message, saving it for later if
    %% there's noone ready to receive it just now. In immediate mode,
    %% should both queues still get the message, somehow, or should
    %% just all ready-to-consume queues get the message, with unready
    %% queues discarding the message?
    %%
    {Delivered, Confirm, State1} = attempt_delivery(Delivery, State),
    reply(Delivered, case Delivered of
                         true  -> maybe_record_confirm_message(Confirm, State1);
                         false -> discard_delivery(Delivery, State1)
                     end);

handle_call({deliver, Delivery}, From, State) ->
    %% Synchronous, "mandatory" delivery mode. Reply asap.
    gen_server2:reply(From, true),
    noreply(deliver_or_enqueue(Delivery, State));

handle_call({notify_down, ChPid}, _From, State) ->
    %% we want to do this synchronously, so that auto_deleted queues
    %% are no longer visible by the time we send a response to the
    %% client.  The queue is ultimately deleted in terminate/2; if we
    %% return stop with a reply, terminate/2 will be called by
    %% gen_server2 *before* the reply is sent.
    case handle_ch_down(ChPid, State) of
        {ok, NewState}   -> reply(ok, NewState);
        {stop, NewState} -> {stop, normal, ok, NewState}
    end;

handle_call({basic_get, ChPid, NoAck}, _From,
            State = #q{q = #amqqueue{name = QName}}) ->
    AckRequired = not NoAck,
    State1 = ensure_expiry_timer(State),
    case fetch(AckRequired, drop_expired_messages(State1)) of
        {empty, State2} ->
            reply(empty, State2);
        {{Message, IsDelivered, AckTag, Remaining}, State2} ->
            State3 =
                case AckRequired of
                    true  -> C = #cr{acktags = ChAckTags} = ch_record(ChPid),
                             true = maybe_store_ch_record(
                                      C#cr{acktags =
                                               sets:add_element(AckTag,
                                                                ChAckTags)}),
                             State2;
                    false -> State2
                end,
            Msg = {QName, self(), AckTag, IsDelivered, Message},
            reply({ok, Remaining, Msg}, State3)
    end;

handle_call({basic_consume, NoAck, ChPid, Limiter,
             ConsumerTag, ExclusiveConsume, OkMsg},
            _From, State = #q{exclusive_consumer = ExistingHolder}) ->
    case check_exclusive_access(ExistingHolder, ExclusiveConsume,
                                State) of
        in_use ->
            reply({error, exclusive_consume_unavailable}, State);
        ok ->
            C = #cr{consumer_count = ConsumerCount} = ch_record(ChPid),
            Consumer = #consumer{tag = ConsumerTag,
                                 ack_required = not NoAck},
            true = maybe_store_ch_record(
                     C#cr{consumer_count = ConsumerCount +1,
                          limiter        = Limiter}),
            ok = case ConsumerCount of
                     0 -> rabbit_limiter:register(Limiter, self());
                     _ -> ok
                 end,
            ExclusiveConsumer = if ExclusiveConsume -> {ChPid, ConsumerTag};
                                   true             -> ExistingHolder
                                end,
            State1 = State#q{has_had_consumers = true,
                             exclusive_consumer = ExclusiveConsumer},
            ok = maybe_send_reply(ChPid, OkMsg),
            State2 =
                case is_ch_blocked(C) of
                    true  -> State1#q{
                               blocked_consumers =
                                   with_consumer(ChPid, Consumer,
                                                State1#q.blocked_consumers)};
                    false -> run_message_queue(
                               State1#q{
                                 active_consumers =
                                     with_consumer(ChPid, Consumer,
                                                  State1#q.active_consumers)})
                end,
            emit_consumer_created(ChPid, ConsumerTag, ExclusiveConsume,
                                  not NoAck),
            reply(ok, State2)
    end;

handle_call({basic_cancel, ChPid, ConsumerTag, OkMsg}, _From,
            State = #q{exclusive_consumer = Holder, credit_map = CreditMap }) ->
    case lookup_ch(ChPid) of
        not_found ->
            ok = maybe_send_reply(ChPid, OkMsg),
            reply(ok, State);
        C = #cr{consumer_count = ConsumerCount,
                limiter        = Limiter} ->
            C1 = C#cr{consumer_count = ConsumerCount -1},
            maybe_store_ch_record(
              case ConsumerCount of
                  1 -> ok = rabbit_limiter:unregister(Limiter, self()),
                       C1#cr{limiter = rabbit_limiter:make_token()};
                  _ -> C1
              end),
            emit_consumer_deleted(ChPid, ConsumerTag),
            ok = maybe_send_reply(ChPid, OkMsg),
            NewState =
                State#q{exclusive_consumer = cancel_holder(ChPid,
                                                           ConsumerTag,
                                                           Holder),
                        active_consumers = without_consumer(
                                             ChPid, ConsumerTag,
                                             State#q.active_consumers),
                        blocked_consumers = without_consumer(
                                              ChPid, ConsumerTag,
                                              State#q.blocked_consumers),
                        credit_map = erase_credit(ConsumerTag, CreditMap)},
            case should_auto_delete(NewState) of
                false -> reply(ok, ensure_expiry_timer(NewState));
                true  -> {stop, normal, ok, NewState}
            end
    end;

handle_call(stat, _From, State) ->
    State1 = #q{backing_queue = BQ, backing_queue_state = BQS,
                active_consumers = ActiveConsumers} =
        drop_expired_messages(ensure_expiry_timer(State)),
    reply({ok, BQ:len(BQS), queue:len(ActiveConsumers)}, State1);

handle_call({delete, IfUnused, IfEmpty}, _From,
            State = #q{backing_queue_state = BQS, backing_queue = BQ}) ->
    IsEmpty = BQ:is_empty(BQS),
    IsUnused = is_unused(State),
    if
        IfEmpty and not(IsEmpty) ->
            reply({error, not_empty}, State);
        IfUnused and not(IsUnused) ->
            reply({error, in_use}, State);
        true ->
            {stop, normal, {ok, BQ:len(BQS)}, State}
    end;

handle_call(purge, _From, State = #q{backing_queue = BQ,
                                     backing_queue_state = BQS}) ->
    {Count, BQS1} = BQ:purge(BQS),
    reply({ok, Count}, State#q{backing_queue_state = BQS1});

handle_call({requeue, AckTags, ChPid}, From, State) ->
    gen_server2:reply(From, ok),
    case lookup_ch(ChPid) of
        not_found ->
            noreply(State);
        C = #cr{acktags = ChAckTags} ->
            ChAckTags1 = subtract_acks(ChAckTags, AckTags),
            maybe_store_ch_record(C#cr{acktags = ChAckTags1}),
            noreply(requeue_and_run(AckTags, State))
    end.

handle_cast({run_backing_queue, Mod, Fun}, State) ->
    noreply(run_backing_queue(Mod, Fun, State));

handle_cast({deliver, Delivery}, State) ->
    %% Asynchronous, non-"mandatory", non-"immediate" deliver mode.
    noreply(deliver_or_enqueue(Delivery, State));

handle_cast({ack, AckTags, ChPid},
            State = #q{backing_queue = BQ, backing_queue_state = BQS}) ->
    case lookup_ch(ChPid) of
        not_found ->
            noreply(State);
        C = #cr{acktags = ChAckTags} ->
            maybe_store_ch_record(C#cr{acktags = subtract_acks(
                                                   ChAckTags, AckTags)}),
            {_Guids, BQS1} = BQ:ack(AckTags, BQS),
            noreply(State#q{backing_queue_state = BQS1})
    end;

handle_cast({reject, AckTags, Requeue, ChPid},
            State = #q{backing_queue       = BQ,
                       backing_queue_state = BQS}) ->
    case lookup_ch(ChPid) of
        not_found ->
            noreply(State);
        C = #cr{acktags = ChAckTags} ->
            ChAckTags1 = subtract_acks(ChAckTags, AckTags),
            maybe_store_ch_record(C#cr{acktags = ChAckTags1}),
            noreply(case Requeue of
                        true  -> requeue_and_run(AckTags, State);
                        false -> {_Guids, BQS1} = BQ:ack(AckTags, BQS),
                                 State#q{backing_queue_state = BQS1}
                    end)
    end;

handle_cast(delete_immediately, State) ->
    {stop, normal, State};

handle_cast({unblock, ChPid}, State) ->
    noreply(
      possibly_unblock(State, ChPid,
                       fun (C) -> C#cr{is_limit_active = false} end));

handle_cast({notify_sent, ChPid}, State) ->
    noreply(
      possibly_unblock(State, ChPid,
                       fun (C = #cr{unsent_message_count = Count}) ->
                               C#cr{unsent_message_count = Count - 1}
                       end));

handle_cast({limit, ChPid, Limiter}, State) ->
    noreply(
      possibly_unblock(
        State, ChPid,
        fun (C = #cr{consumer_count  = ConsumerCount,
                     limiter         = OldLimiter,
                     is_limit_active = OldLimited}) ->
                case (ConsumerCount =/= 0 andalso
                      not rabbit_limiter:is_enabled(OldLimiter)) of
                    true  -> ok = rabbit_limiter:register(Limiter, self());
                    false -> ok
                end,
                Limited = OldLimited andalso rabbit_limiter:is_enabled(Limiter)
                    andalso rabbit_limiter:is_blocked(Limiter),
                C#cr{limiter = Limiter, is_limit_active = Limited}
        end));

handle_cast({set_credit, CTag, Credit, Count, Drain, EchoTo}, State) ->
    noreply(reset_credit(CTag, Credit, Count, Drain, EchoTo, State));

handle_cast({flush, ChPid}, State) ->
    ok = rabbit_channel:flushed(ChPid, self()),
    noreply(State);

handle_cast({set_ram_duration_target, Duration},
            State = #q{backing_queue = BQ, backing_queue_state = BQS}) ->
    BQS1 = BQ:set_ram_duration_target(Duration, BQS),
    noreply(State#q{backing_queue_state = BQS1});

handle_cast({set_maximum_since_use, Age}, State) ->
    ok = file_handle_cache:set_maximum_since_use(Age),
    noreply(State);

handle_cast(force_event_refresh, State = #q{exclusive_consumer = Exclusive}) ->
    rabbit_event:notify(queue_created, infos(?CREATION_EVENT_KEYS, State)),
    case Exclusive of
        none       -> [emit_consumer_created(Ch, CTag, false, AckRequired) ||
                          {Ch, CTag, AckRequired} <- consumers(State)];
        {Ch, CTag} -> [{Ch, CTag, AckRequired}] = consumers(State),
                      emit_consumer_created(Ch, CTag, true, AckRequired)
    end,
    noreply(State).

handle_info(maybe_expire, State) ->
    case is_unused(State) of
        true  -> ?LOGDEBUG("Queue lease expired for ~p~n", [State#q.q]),
                 {stop, normal, State};
        false -> noreply(ensure_expiry_timer(State))
    end;

handle_info(drop_expired, State) ->
    noreply(drop_expired_messages(State#q{ttl_timer_ref = undefined}));

handle_info(emit_stats, State = #q{stats_timer = StatsTimer}) ->
    %% Do not invoke noreply as it would see no timer and create a new one.
    emit_stats(State),
    State1 = State#q{stats_timer = rabbit_event:reset_stats_timer(StatsTimer)},
    assert_invariant(State1),
    {noreply, State1, hibernate};

handle_info({'DOWN', _MonitorRef, process, DownPid, _Reason},
            State = #q{q = #amqqueue{exclusive_owner = DownPid}}) ->
    %% Exclusively owned queues must disappear with their owner.  In
    %% the case of clean shutdown we delete the queue synchronously in
    %% the reader - although not required by the spec this seems to
    %% match what people expect (see bug 21824). However we need this
    %% monitor-and-async- delete in case the connection goes away
    %% unexpectedly.
    {stop, normal, State};
handle_info({'DOWN', _MonitorRef, process, DownPid, _Reason}, State) ->
    case handle_ch_down(DownPid, State) of
        {ok, NewState}   -> noreply(NewState);
        {stop, NewState} -> {stop, normal, NewState}
    end;

handle_info(update_ram_duration, State = #q{backing_queue = BQ,
                                            backing_queue_state = BQS}) ->
    {RamDuration, BQS1} = BQ:ram_duration(BQS),
    DesiredDuration =
        rabbit_memory_monitor:report_ram_duration(self(), RamDuration),
    BQS2 = BQ:set_ram_duration_target(DesiredDuration, BQS1),
    noreply(State#q{rate_timer_ref = just_measured,
                    backing_queue_state = BQS2});

handle_info(sync_timeout, State) ->
    noreply(backing_queue_timeout(State#q{sync_timer_ref = undefined}));

handle_info(timeout, State) ->
    noreply(backing_queue_timeout(State));

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};

handle_info(Info, State) ->
    ?LOGDEBUG("Info in queue: ~p~n", [Info]),
    {stop, {unhandled_info, Info}, State}.

handle_pre_hibernate(State = #q{backing_queue_state = undefined}) ->
    {hibernate, State};
handle_pre_hibernate(State = #q{backing_queue = BQ,
                                backing_queue_state = BQS,
                                stats_timer = StatsTimer}) ->
    {RamDuration, BQS1} = BQ:ram_duration(BQS),
    DesiredDuration =
        rabbit_memory_monitor:report_ram_duration(self(), RamDuration),
    BQS2 = BQ:set_ram_duration_target(DesiredDuration, BQS1),
    BQS3 = BQ:handle_pre_hibernate(BQS2),
    rabbit_event:if_enabled(
      StatsTimer,
      fun () -> emit_stats(State, [{idle_since, now()}]) end),
    State1 = State#q{stats_timer = rabbit_event:stop_stats_timer(StatsTimer),
                     backing_queue_state = BQS3},
    {hibernate, stop_rate_timer(State1)}.

format_message_queue(Opt, MQ) -> rabbit_misc:format_message_queue(Opt, MQ).
