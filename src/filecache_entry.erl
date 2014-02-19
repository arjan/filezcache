%% @author Marc Worrell
%% @copyright 2013-2014 Marc Worrell

%% Copyright 2013-2014 Marc Worrell
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


%% TODO:
%% - timeout on idle state for invalidation-check and/or hibernate
%% - timeout on streaming state
%% - optional: monitor streamer -> if down then terminate this entry
%% - optional: inform readers/waiters of termination

-module(filecache_entry).

-include_lib("kernel/include/file.hrl").

-behaviour(gen_fsm).

% api
-export([
        start_link/2,
        fetch/1,
        fetch_file/1,
        store/2,
        repop/5,
        append_stream/2,
        finish_stream/1,
        delete/1,
        gc/1,

        stream_fun/3,
        stream_chunks_fun/3,
        stream_fun/1
        ]).

% gen_fsm
-export([init/1, handle_sync_event/4, handle_event/3, handle_info/3, terminate/3, code_change/4]).

% states
-export([
    wait_for_data/2,
    wait_for_data/3,
    streaming/2,
    streaming/3,
    idle/3
    ]).

% For testing
-export([ 
    filename/1
    ]).

-record(state, {
        key,
        filename,
        fd,
        size,
        checksum,
        checksum_context,
        writer,
        readers = [],
        waiters = []}).

%% API

start_link(Key, Writer) ->
    gen_fsm:start_link(?MODULE, [Key, Writer], []).

fetch(Pid) ->
    try
        gen_fsm:sync_send_event(Pid, fetch)
    catch
        exit:{noproc, _} ->
            {error, not_found}
    end.

fetch_file(Pid) ->
    try
        gen_fsm:sync_send_event(Pid, fetch_file)
    catch
        exit:{noproc, _} ->
            {error, not_found}
    end.

-spec store(pid(), {stream_start, pid()}|{data, binary()}|{file, file:filename()}) -> ok.
store(Pid, Value) ->
    gen_fsm:send_event(Pid, Value).

repop(Pid, Key, Filename, Size, Checksum) ->
    gen_fsm:send_event(Pid, {repop, Key, Filename, Size, Checksum}).

append_stream(Pid, Data) ->
    gen_fsm:send_event(Pid, {stream_append, self(), Data}).

finish_stream(Pid) ->
    gen_fsm:send_event(Pid, {stream_finish, self()}).

delete(Pid) ->
    gen_fsm:send_all_state_event(Pid, delete).

gc(Pid) ->
    gen_fsm:send_all_state_event(Pid, gc).

%% gen_server callbacks

init([Key, Writer]) ->
    Filename = filename(Key),
    State =  #state{key = Key,
                    filename = Filename,
                    fd = undefined,
                    size = 0,
                    checksum = 0,
                    checksum_context = undefined, 
                    writer = Writer,
                    readers = [],
                    waiters = []},
    {ok, wait_for_data, State}.

%% Wait till all data is received and stored in the cache file.

wait_for_data({data, Data}, #state{readers=Readers, waiters=Waiters, filename=Filename} = State) when is_binary(Data) ->
    send_readers(Readers, {data, Data}),
    Size = size(Data),
    ok = file:write_file(Filename, Data),
    send_filename(Waiters, Size, Filename),
    State1 = State#state{checksum=crypto:sha(Data), 
                         size=Size,
                         readers=[]},
    log_ready(State1),
    {next_state, idle, State1};
wait_for_data({file, Filename}, #state{filename=Filename} = State) ->
    State1 = send_file_state(set_file_state(Filename, State)),
    log_ready(State1),
    {next_state, idle, State1};
wait_for_data({file, File}, #state{filename=Filename} = State) ->
    ok = file:copy(File, Filename),
    State1 = send_file_state(set_file_state(Filename, State)),
    log_ready(State1),
    {next_state, idle, State1};
wait_for_data({tmpfile, TmpFile}, #state{filename=Filename} = State) ->
    ok = file:rename(TmpFile, Filename),
    State1 = send_file_state(set_file_state(Filename, State)),
    log_ready(State1),
    {next_state, idle, State1};
wait_for_data({stream_start, Streamer}, #state{writer=Streamer, filename=Filename} = State) ->
    {ok, FD} = file:open(Filename, [write,binary]),
    {next_state, streaming, State#state{fd=FD, size=0, checksum_context=crypto:hash_init(sha)}};
wait_for_data({repop, Key, Filename, Size, Checksum}, State) ->
    State1 = State#state{
        key=Key,
        filename=Filename,
        size=Size,
        checksum=Checksum
    },
    log_ready(State1),
    {next_state, idle, State1}.

wait_for_data(fetch, From, #state{readers=Readers} = State) ->
    Reply = reply_partial_data(State),
    {reply, Reply, wait_for_data, State#state{readers=[From|Readers]}};
wait_for_data(fetch_file, From, #state{waiters=Waiters} = State) ->
    {next_state, wait_for_data, State#state{waiters=[From|Waiters]}}.

%% Receive data from a stream

streaming({stream_append, Streamer, Data}, #state{writer=Streamer, fd=FD, readers=Readers, size=Size, checksum_context=Ctx} = State) ->
    send_readers(Readers, {stream, Data}),
    ok = file:write(FD, Data),
    Ctx1 = crypto:hash_update(Ctx, Data), 
    {next_state, streaming, State#state{checksum_context=Ctx1, size=Size+size(Data)}};
streaming({stream_finish, Streamer}, #state{writer=Streamer, fd=FD, readers=Readers, waiters=Waiters, checksum_context=Ctx} = State) ->
    ok = file:close(FD),
    send_readers(Readers, {stream, done}),
    send_filename(Waiters, State#state.size, State#state.filename),
    State1 = State#state{checksum_context=undefined, fd=undefined, checksum=crypto:hash_final(Ctx), readers=[], waiters=[]},
    log_ready(State1),
    {next_state, idle, State1}.

streaming(fetch, From, #state{readers=Readers} = State) ->
    Reply = reply_partial_data(State),
    {reply, Reply, streaming, State#state{readers=[From|Readers]}};
streaming(fetch_file, From, #state{waiters=Waiters} = State) ->
    {next_state, streaming, State#state{waiters=[From|Waiters]}}.

%% idle - handle all cache requests
idle(fetch, _From, #state{filename=Filename, size=Size} = State) ->
    filecache_entry_manager:log_access(self()),
    {reply, {ok, {filename, Size, Filename}}, idle, State};
idle(fetch_file, _From, #state{filename=Filename, size=Size} = State) ->
    filecache_entry_manager:log_access(self()),
    {reply, {ok, {filename, Size, Filename}}, idle, State}.


%% All state events: 'gc'

handle_event(gc, wait_for_data, State) ->
    {next_state, wait_for_data, State};
handle_event(gc, streaming, State) ->
    {next_state, streaming, State};
handle_event(gs, StateName, State) ->
    handle_event(delete, StateName, State);

%% All state events: 'delete'

handle_event(delete, StateName, #state{fd=FD} = State) when FD =/= undefined ->
    _ = file:close(FD),
    handle_event(delete, StateName, State#state{fd=FD});
handle_event(delete, _StateName, #state{fd=undefined, filename=Filename} = State) ->
    _ = file:delete(Filename),
    {stop, normal, State};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%% Note: DO NOT reply to unexpected calls. Let the call-maker crash!
handle_sync_event(_Event, _From, StateName, State) ->
    {next_state, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


%%% Support functions

log_ready(#state{key=Key, filename=Filename, size=Size, checksum=Checksum}) ->
    filecache_entry_manager:log_ready(self(), Key, Filename, Size, Checksum).


set_file_state(Filename, State) ->
    {ok, FInfo} = file:file_info(Filename),
    State#state{filename=Filename, size=FInfo#file_info.size, checksum=filecache:checksum(Filename)}.

send_file_state(#state{readers=Readers, waiters=Waiters, filename=Filename, size=Size} = State) ->
    send_filename(Readers, Size, Filename),
    send_filename(Waiters, Size, Filename),
    State#state{readers=[], waiters=[]}.


filename(Key) ->
    HashS = encode(crypto:sha256(term_to_binary(Key)), 36),
    filename:join([filecache:data_dir(), HashS]).

encode(Data, Base) when is_binary(Data) ->
    encode(binary_to_list(Data), Base);
encode(Data, Base) when is_list(Data) ->
    F = fun(C) ->
        case erlang:integer_to_list(C, Base) of
            [C1, C2] -> [C1, C2];
            [C1]     -> [$0, C1]
        end
    end,
    lists:flatten([F(I) || I <- Data]).


send_readers(Pids, Msg) ->
    lists:map(fun(Pid) -> Pid ! {filecache, Msg, self()} end, Pids).

send_filename(Pids, Size, Filename) ->
    lists:map(fun(Pid) -> Pid ! {filecache, {file, Size, Filename}, self()} end, Pids).


%% @doc We didn't receive all data yet, reply with the data received till now and 
%%      stream copies of all data received later to the caller.
reply_partial_data(#state{size=0}) ->
    Self = self(),
    {ok, {stream, fun() -> ?MODULE:stream_fun(Self) end}};
reply_partial_data(#state{filename=Filename, size=Size}) ->
    Self = self(),
    {ok, {stream, fun() -> ?MODULE:stream_fun(Filename, Size, Self) end}}.


-define(CHUNK_SIZE, 65536).

%% @doc First stream the on-disk data, then append the received {stream, ...} messages
stream_fun(Filename, Size, EntryPid) ->
    {ok, FD} = file:open(Filename, [read,binary]),
    stream_chunks_fun(FD, Size, EntryPid).

stream_chunks_fun(FD, 0, EntryPid) ->
    _ = file:close(FD),
    stream_fun(EntryPid);
stream_chunks_fun(FD, Size, EntryPid) ->
    ChunkSize = erlang:min(Size, ?CHUNK_SIZE),
    {ok, Data} = file:read(FD, ChunkSize),
    {Data, fun() -> ?MODULE:stream_chunks_fun(FD, Size - ChunkSize, EntryPid) end}.

stream_fun(EntryPid) ->
    receive
        {filecache, {data, Data}, EntryPid} ->
            {Data, done};
        {filecache, {file, _Size, _Filename} = File, EntryPid} ->
            {File, done};
        {filecache, {stream, done}, EntryPid} ->
            {<<>>, done};
        {filecache, {stream, Data}, EntryPid} ->
            {Data, fun() -> ?MODULE:stream_fun(EntryPid) end}
    end.