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
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%
-module(rabbit_clean_shutdown).

-behaviour(gen_server).

-export([recover/0,
         start_link/0,
         store_recovery_terms/2,
         detect_clean_shutdown/1,
         read_recovery_terms/1,
         remove_recovery_terms/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-ifdef(use_specs).

-spec(recover() -> 'ok').
-spec(start_link() -> rabbit_types:ok_pid_or_error()).
-spec(store_recovery_terms(
        Name  :: rabbit_misc:resource_name(),
        Terms :: term()) -> rabbit_types:ok_or_error(term())).
-spec(detect_clean_shutdown(
        rabbit_misc:resource_name()) ->
             boolean() | rabbit_types:error(term())).
-spec(read_recovery_terms(
        rabbit_misc:resource_name()) ->
             rabbit_types:ok_or_error2(term(), not_found)).

-endif. % use_specs

-include("rabbit.hrl").
-define(CLEAN_FILENAME, "clean.dot").

recover() ->
    {ok, _Child} = supervisor:start_child(rabbit_sup,
                                          {?MODULE, {?MODULE, start_link, []},
                                          permanent, ?MAX_WAIT, worker,
                                          [?MODULE]}),
    ok.

start_link() ->
    gen_server:start_link(?MODULE, [], []).

store_recovery_terms(Name, Terms) ->
    dets:insert(?MODULE, {Name, Terms}).

detect_clean_shutdown(Name) ->
    dets:member(?MODULE, Name).

read_recovery_terms(Name) ->
    case dets:lookup(?MODULE, Name) of
        [Terms] -> {ok, Terms};
        _       -> {error, not_found}
    end.

remove_recovery_terms(Name) ->
    dets:delete(?MODULE, Name).

init(_) ->
    File = filename:join([rabbit_mnesia:dir(), "queues", ?CLEAN_FILENAME]),
    {ok, _} = dets:open_file(?MODULE, [{file, File},
                                       {ram_file, true},
                                       {auto_save, infinity}]),
    {ok, undefined}.

handle_call(ready, _, State) ->
    {reply, ok, State};
handle_call(Msg, _, State) ->
    {stop, {unexpected_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok = dets:sync(?MODULE).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

