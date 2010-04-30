%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(delegate).
-define(DELEGATE_PROCESS_COUNT_MULTIPLIER, 2).

-behaviour(gen_server2).

-export([start_link/1, invoke_no_result/2, invoke/2, process_count/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start_link/1 :: (non_neg_integer()) -> {'ok', pid()}).
-spec(invoke_no_result/2 :: (pid() | [pid()], fun((pid()) -> any())) -> 'ok').
-spec(invoke/2 :: (pid() | [pid()], fun((pid()) -> A)) -> A).

-spec(process_count/0 :: () -> non_neg_integer()).

-endif.

%%----------------------------------------------------------------------------

start_link(Hash) ->
    gen_server2:start_link({local, server(Hash)},
                           ?MODULE, [], []).

invoke(Pid, FPid) when is_pid(Pid) ->
    [{Status, Res, _}] = invoke_per_node([{node(Pid), [Pid]}], FPid),
    {Status, Res};

invoke(Pids, FPid) when is_list(Pids) ->
    invoke_per_node(split_delegate_per_node(Pids), FPid).

invoke_no_result(Pid, FPid) when is_pid(Pid) ->
    invoke_no_result_per_node([{node(Pid), [Pid]}], FPid),
    ok;

invoke_no_result(Pids, FPid) when is_list(Pids) ->
    invoke_no_result_per_node(split_delegate_per_node(Pids),  FPid),
    ok.

%%----------------------------------------------------------------------------

internal_call(Node, Thunk) when is_atom(Node) ->
    gen_server2:call({remote_server(Node), Node}, {thunk, Thunk}, infinity).

internal_cast(Node, Thunk) when is_atom(Node) ->
    gen_server2:cast({remote_server(Node), Node}, {thunk, Thunk}).

split_delegate_per_node(Pids) ->
    orddict:to_list(
      lists:foldl(
        fun (Pid, D) ->
                orddict:update(node(Pid),
                               fun (Pids1) -> [Pid | Pids1] end,
                               [Pid], D)
        end,
        orddict:new(), Pids)).

invoke_per_node([{Node, Pids}], FPid) when Node == node() ->
    local_delegate(Pids, FPid);
invoke_per_node(NodePids, FPid) ->
    lists:append(delegate_per_node(NodePids, FPid, fun internal_call/2)).

invoke_no_result_per_node([{Node, Pids}], FPid) when Node == node() ->
    % This is not actually async! However, in practice FPid will always be
    % something that does a gen_server:cast or similar, so I don't think
    % it's a problem unless someone misuses this function. Making this
    % *actually* async would be painful as we can't spawn at this point or we
    % break effect ordering.
    local_delegate(Pids, FPid);
invoke_no_result_per_node(NodePids, FPid) ->
    delegate_per_node(NodePids, FPid, fun internal_cast/2),
    ok.

local_delegate(Pids, FPid) ->
    [safe_invoke(FPid, Pid) || Pid <- Pids].

delegate_per_node(NodePids, FPid, DelegateFun) ->
    Self = self(),
    [gen_server2:cast(local_server(Node), {thunk, fun() ->
        Self ! {result, DelegateFun(Node,
                                    fun() -> local_delegate(Pids, FPid) end)}
    end}) || {Node, Pids} <- NodePids],
    gather_results([], length(NodePids)).

gather_results(ResultsAcc, 0) ->
    ResultsAcc;
gather_results(ResultsAcc, ToGo) ->
    receive
        {result, Result} -> gather_results([Result | ResultsAcc], ToGo - 1)
    end.

local_server(Node) ->
    case get({delegate_local_server_name, Node}) of
        undefined ->
            Name = server(erlang:phash2(Node, process_count())),
            put({delegate_local_server_name, Node}, Name),
            Name;
        Name -> Name
    end.

remote_server(Node) ->
    case get({delegate_remote_server_name, Node}) of
        undefined ->
            case rpc:call(Node, delegate, process_count, []) of
                {badrpc, _} ->
                    delegate_process_1; % Have to return something, if we're
                                        % just casting then we don't want to
                                        % blow up
                Count ->
                    Name = server(erlang:phash2(self(), Count)),
                    put({delegate_remote_server_name, Node}, Name),
                    Name
            end;
        Name -> Name
    end.

server(Hash) ->
    list_to_atom("delegate_process_" ++ integer_to_list(Hash)).

safe_invoke(FPid, Pid) ->
    % We need the catch here for the local case. In the remote case there will
    % already have been a catch in handle_ca{ll,st} below, but that's OK, catch
    % is idempotent.
    case catch FPid(Pid) of
        {'EXIT', Reason} ->
            {error, {'EXIT', Reason}, Pid};
        Result ->
            {ok, Result, Pid}
    end.

process_count() ->
    ?DELEGATE_PROCESS_COUNT_MULTIPLIER * erlang:system_info(schedulers).

%%--------------------------------------------------------------------

init([]) ->
    {ok, no_state}.

handle_call({thunk, Thunk}, _From, State) ->
   {reply, catch Thunk(), State}.

handle_cast({thunk, Thunk}, State) ->
    catch Thunk(),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
