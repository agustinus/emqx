%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_sys_mon).

-behavior(gen_server).

-include("logger.hrl").
-include("types.hrl").

-export([start_link/1]).

%% compress unused warning
-export([procinfo/1]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-type(option() :: {long_gc, false | pos_integer()}
                | {long_schedule, false | pos_integer()}
                | {large_heap, pos_integer()}
                | {busy_port, boolean()}
                | {busy_dist_port, boolean()}).

-define(SYSMON, ?MODULE).

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

%% @doc Start system monitor
-spec(start_link(list(option())) -> startlink_ret()).
start_link(Opts) ->
    gen_server:start_link({local, ?SYSMON}, ?MODULE, [Opts], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([Opts]) ->
    erlang:system_monitor(self(), parse_opt(Opts)),
    emqx_logger:set_proc_metadata(#{sysmon => true}),
    {ok, start_timer(#{timer => undefined, events => []})}.

start_timer(State) ->
    State#{timer := emqx_misc:start_timer(timer:seconds(2), reset)}.

parse_opt(Opts) ->
    parse_opt(Opts, []).
parse_opt([], Acc) ->
    Acc;
parse_opt([{long_gc, false}|Opts], Acc) ->
    parse_opt(Opts, Acc);
parse_opt([{long_gc, Ms}|Opts], Acc) when is_integer(Ms) ->
    parse_opt(Opts, [{long_gc, Ms}|Acc]);
parse_opt([{long_schedule, false}|Opts], Acc) ->
    parse_opt(Opts, Acc);
parse_opt([{long_schedule, Ms}|Opts], Acc) when is_integer(Ms) ->
    parse_opt(Opts, [{long_schedule, Ms}|Acc]);
parse_opt([{large_heap, Size}|Opts], Acc) when is_integer(Size) ->
    parse_opt(Opts, [{large_heap, Size}|Acc]);
parse_opt([{busy_port, true}|Opts], Acc) ->
    parse_opt(Opts, [busy_port|Acc]);
parse_opt([{busy_port, false}|Opts], Acc) ->
    parse_opt(Opts, Acc);
parse_opt([{busy_dist_port, true}|Opts], Acc) ->
    parse_opt(Opts, [busy_dist_port|Acc]);
parse_opt([{busy_dist_port, false}|Opts], Acc) ->
    parse_opt(Opts, Acc);
parse_opt([_Opt|Opts], Acc) ->
    parse_opt(Opts, Acc).

handle_call(Req, _From, State) ->
    ?LOG(error, "[SYSMON] Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?LOG(error, "[SYSMON] Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({monitor, Pid, long_gc, Info}, State) ->
    suppress({long_gc, Pid},
             fun() ->
                 WarnMsg = io_lib:format("long_gc warning: pid = ~p, info: ~p", [Pid, Info]),
                 ?LOG(warning, "[SYSMON] ~s~n~p", [WarnMsg, procinfo(Pid)]),
                 safe_publish(long_gc, WarnMsg)
             end, State);

handle_info({monitor, Pid, long_schedule, Info}, State) when is_pid(Pid) ->
    suppress({long_schedule, Pid},
             fun() ->
                 WarnMsg = io_lib:format("long_schedule warning: pid = ~p, info: ~p", [Pid, Info]),
                 ?LOG(warning, "[SYSMON] ~s~n~p", [WarnMsg, procinfo(Pid)]),
                 safe_publish(long_schedule, WarnMsg)
             end, State);

handle_info({monitor, Port, long_schedule, Info}, State) when is_port(Port) ->
    suppress({long_schedule, Port},
             fun() ->
                 WarnMsg = io_lib:format("long_schedule warning: port = ~p, info: ~p", [Port, Info]),
                 ?LOG(warning, "[SYSMON] ~s~n~p", [WarnMsg, erlang:port_info(Port)]),
                 safe_publish(long_schedule, WarnMsg)
             end, State);

handle_info({monitor, Pid, large_heap, Info}, State) ->
    suppress({large_heap, Pid},
             fun() ->
                 WarnMsg = io_lib:format("large_heap warning: pid = ~p, info: ~p", [Pid, Info]),
                 ?LOG(warning, "[SYSMON] ~s~n~p", [WarnMsg, procinfo(Pid)]),
                 safe_publish(large_heap, WarnMsg)
             end, State);

handle_info({monitor, SusPid, busy_port, Port}, State) ->
    suppress({busy_port, Port},
             fun() ->
                 WarnMsg = io_lib:format("busy_port warning: suspid = ~p, port = ~p", [SusPid, Port]),
                 ?LOG(warning, "[SYSMON] ~s~n~p~n~p", [WarnMsg, procinfo(SusPid), erlang:port_info(Port)]),
                 safe_publish(busy_port, WarnMsg)
             end, State);

handle_info({monitor, SusPid, busy_dist_port, Port}, State) ->
    suppress({busy_dist_port, Port},
             fun() ->
                 WarnMsg = io_lib:format("busy_dist_port warning: suspid = ~p, port = ~p", [SusPid, Port]),
                 ?LOG(warning, "[SYSMON] ~s~n~p~n~p", [WarnMsg, procinfo(SusPid), erlang:port_info(Port)]),
                 safe_publish(busy_dist_port, WarnMsg)
             end, State);

handle_info({timeout, _Ref, reset}, State) ->
    {noreply, State#{events := []}, hibernate};

handle_info(Info, State) ->
    ?LOG(error, "[SYSMON] Unexpected Info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #{timer := TRef}) ->
    emqx_misc:cancel_timer(TRef).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

suppress(Key, SuccFun, State = #{events := Events}) ->
    case lists:member(Key, Events) of
        true  -> {noreply, State};
        false -> SuccFun(),
                 {noreply, State#{events := [Key|Events]}}
    end.

procinfo(Pid) ->
    case {emqx_vm:get_process_info(Pid), emqx_vm:get_process_gc(Pid)} of
        {undefined, _} -> undefined;
        {_, undefined} -> undefined;
        {Info, GcInfo} -> Info ++ GcInfo
    end.

safe_publish(Event, WarnMsg) ->
    Topic = emqx_topic:systop(lists:concat(['sysmon/', Event])),
    emqx_broker:safe_publish(sysmon_msg(Topic, iolist_to_binary(WarnMsg))).

sysmon_msg(Topic, Payload) ->
    Msg = emqx_message:make(?SYSMON, Topic, Payload),
    emqx_message:set_flag(sys, Msg).

