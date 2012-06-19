-module(socketio_manager).
-include_lib("../include/socketio.hrl").
-behaviour(gen_server).

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3,
         create_new_session/2, get_client_pid/1]).

-define(SERVER, ?MODULE).

-record(state, {
          sessions,
          event_manager,
          sup,
          server_module
         }).
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(ServerModule, Sup) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ServerModule, Sup], []).

create_new_session(ConnectionReference, Transport) ->
    gen_server:call(?MODULE, {session, generate, ConnectionReference, Transport}, infinity).

get_client_pid(SessionId) ->
    gen_server:call(?MODULE, {get_client_pid, SessionId}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([ServerModule, Sup]) ->
    Self = self(),
    process_flag(trap_exit, true),
    gen_server:cast(Self, acquire_event_manager),
    {ok, #state{
       sessions = ets:new(socketio_sessions,[public]),
       sup = Sup,
       server_module = ServerModule
      }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({get_client_pid, SessionId}, _From, #state{sessions = Sessions} = State) ->
    Reply = case ets:lookup(Sessions, SessionId) of
                [{SessionId, Pid}] ->
                    Pid;
                _ ->
                    undefined
            end,
    {reply, Reply, State};

handle_call({session, generate, ConnectionReference, Transport}, _From, #state{
                                                                   sup = Sup,
                                                                   sessions = Sessions,
                                                                   event_manager = EventManager,
                                                                   server_module = ServerModule
                                                                  } = State) ->
    UUID = binary_to_list(uuids:new()),
    {ok, Pid} = socketio_client:start(Sup, Transport, UUID, ServerModule, ConnectionReference),
    link(Pid),
    ets:insert(Sessions, [{UUID, Pid}, {Pid, UUID}]),
    gen_event:notify(EventManager, {client, Pid}),
    {reply, {UUID, Pid}, State};

%% Event management
handle_call(event_manager, _From, #state{ event_manager = EventMgr } = State) ->
    {reply, EventMgr, State}.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(acquire_event_manager, State) ->
    EventManager = socketio_listener:event_manager(listener(State)),
    {noreply, State#state{ event_manager = EventManager }};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, _}, #state{ event_manager = EventManager, sessions = Sessions } = State) ->
    case ets:lookup(Sessions, Pid) of
        [{Pid, UUID}] ->
            ets:delete(Sessions,UUID),
            ets:delete(Sessions,Pid),
            gen_event:notify(EventManager, {disconnect, Pid});
        _ ->
            ignore
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
listener(#state{ sup = Sup }) ->
    socketio_listener:server(Sup).
