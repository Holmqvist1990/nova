%%%-------------------------------------------------------------------
%%% @author Niclas Axelsson <niclas@burbas.se>
%%% @copyright (C) 2020, Niclas Axelsson
%%% @doc
%%% Plugins can be run at two different times; either in the beginning or at
%% the end of a request. They can modify both the actual request or the nova-state.
%% A plugin is implemented with the <icode>nova_plugin</icode> behaviour
%%% and needs to implement three different functions: <icode>pre_request/2</icode>,
%% <icode>post_request/2</icode> and <icode>plugin_info/0</icode>.
%%%
%%%
%%% <code title="src/example_plugin.erl">
%%% -module(example_plugin).
%%% -behaviour(nova_plugin).
%%% -export([pre_request/2, post_request/2, plugin_info/0]).
%%%
%%% pre_request(Req, State) ->
%%%   Req0 = cowboy_req:set_resp_header(<<"x-nova-started">>, erlang:system_time(milli_seconds), Req),
%%%   {ok, Req0, State}.
%%%
%%% post_request(Req, State) ->
%%%   Started = cowboy_req:header(<<"x-nova-started">>, Req),
%%%   Now = erlang:system_time(milli_seconds),
%%%   ?INFO("Request ran for ~.B milliseconds", [Now-Started]),
%%%   {ok, Req, State}.
%%%
%%% plugin_info() ->
%%%   {<<"Execution time plugin">>, <<"1.0.0">>, <<"Niclas Axelsson <niclas@burbas.se>">>,
%%     <<"Example plugin for nova">>}.
%%% </code>
%%%
%%%
%%% To register the plugin above you have to call
%%  <icode>nova_plugin:register_plugin(RequestType, http, example_plugin).</icode> in order
%%% to run it. <icode>RequestType</icode> can either be <icode>pre_request</icode> or
%%  <icode>post_request</icode>.
%%% @end
%%% Created : 12 Feb 2020 by Niclas Axelsson <niclas@burbas.se>
%%%-------------------------------------------------------------------
-module(nova_plugin).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         register_plugin/2,
         register_plugin/3,
         register_plugin/4,
         unregister_plugin/1,
         get_all_plugins/0,
         get_plugins/1
        ]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/2
        ]).

-include_lib("nova/include/nova.hrl").

-type request_type() :: pre_http_request | post_http_request.
-export_type([request_type/0]).

-define(REQUEST_TYPE(Type), Type == pre_http_request orelse Type == post_http_request).

%% Define the callback functions for plugins
-callback pre_request(State :: nova_http_handler:nova_http_state(), Options :: map()) ->
    {ok, State0 :: nova_http_handler:nova_http_state()} |
    {break, State0 :: nova_http_handler:nova_http_state()} |
    {stop, State0 :: nova_http_handler:nova_http_state()} |
    {error, Reason :: term()}.
-callback post_request(State :: nova_http_handler:nova_http_state(), Options :: map()) ->
    {ok, State0 :: nova_http_handler:nova_http_state()} |
    {break, State0 :: nova_http_handler:nova_http_state()} |
    {stop, State0 :: nova_http_handler:nova_http_state()} |
    {error, Reason :: term()}.
-callback plugin_info() -> {Title :: binary(), Version :: binary(), Author :: binary(), Description :: binary(),
                            Options :: [{Key :: atom(), OptionDescription :: binary()}]}.

-define(SERVER, ?MODULE).

-define(NOVA_PLUGIN_TABLE, nova_plugin_table).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @hidden
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
                      {error, Error :: {already_started, pid()}} |
                      {error, Error :: term()} |
                      ignore.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%%--------------------------------------------------------------------
%% @doc
%% Register a plugin. This operation is asyncronous so the atom
%% <icode>ok</icode> will always be returned. If an error occurs it will
%% be stated in the logs.
%% @end
%%--------------------------------------------------------------------
-spec register_plugin(RequestType :: request_type(), Module :: atom()) -> ok.
register_plugin(RequestType, Module) ->
    register_plugin(RequestType, Module, #{}).

register_plugin(RequestType, Module, Options) ->
    register_plugin(RequestType, Module, Options, 50).

register_plugin(RequestType, Module, Options, Priority) when ?REQUEST_TYPE(RequestType) ->
    gen_server:cast(?SERVER, {register_plugin, RequestType, Module, Options, Priority}).

%%--------------------------------------------------------------------
%% @doc
%% Unregisters a plugin with a given <icode>Id</icode>. The id can be retrieved
%% by calling either <icode>get_all_plugins/0</icode> or <icode>get_plugins/2</icode>
%% to find the specific plugin.
%% @end
%%--------------------------------------------------------------------
-spec unregister_plugin(Id :: binary()) -> ok.
unregister_plugin(Id) ->
    gen_server:call(?SERVER, {unregister_plugin, Id}).

%%--------------------------------------------------------------------
%% @doc
%% Returns all registered plugins.
%% @end
%%--------------------------------------------------------------------
-spec get_all_plugins() -> {ok, map()}.
get_all_plugins() ->
    gen_server:call(?SERVER, get_all_plugins).

%%--------------------------------------------------------------------
%% @doc
%% Get all plugins that is associated with a specific <icode>RequestType</icode>.
%% Will return {ok, <icode>[{Priority :: integer(), Payload :: #{id => binary(),
%% module => atom(), options => map()}]</icode>}.
%% @end
%%--------------------------------------------------------------------
-spec get_plugins(RequestType :: request_type()) ->
                         {ok, [{Priority :: integer(), Payload :: #{id => integer(),
                                                                    module => atom(),
                                                                    options => map()}}]}.
get_plugins(RequestType) when ?REQUEST_TYPE(RequestType) ->
    gen_server:call(?SERVER, {get_plugins, RequestType}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
                              {ok, State :: term(), Timeout :: timeout()} |
                              {ok, State :: term(), hibernate} |
                              {stop, Reason :: term()} |
                              ignore.
init(_Args) ->
    process_flag(trap_exit, true),
    ets:new(?NOVA_PLUGIN_TABLE, [named_table, bag, protected]),
    Plugins = application:get_env(nova, plugins, []),
    lists:foreach(fun({ReqType, Module}) -> register_plugin(ReqType, Module);
                     ({ReqType, Module, Options}) -> register_plugin(ReqType, Module, Options);
                     ({ReqType, Module, Options, Priority}) -> register_plugin(ReqType, Module, Options, Priority)
                  end, Plugins),
    {ok, #{pre_plugins => [],
           post_plugins => []}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
                         {reply, Reply :: term(), NewState :: term()} |
                         {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
                         {reply, Reply :: term(), NewState :: term(), hibernate} |
                         {noreply, NewState :: term()} |
                         {noreply, NewState :: term(), Timeout :: timeout()} |
                         {noreply, NewState :: term(), hibernate} |
                         {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
                         {stop, Reason :: term(), NewState :: term()}.
handle_call({get_plugins, RequestType}, _From, State) ->
    {reply, {ok, maps:get(RequestType, State, [])}, State};
handle_call(get_all_plugins, _From, State) ->
    {reply, {ok, State}, State};
handle_call({unregister_plugin, ID}, _From, State) ->
    ?DEBUG("Removing plugin with ID: ~s", [ID]),
    State0 = [ maps:filter(fun(_, #{id := X}) -> X /= ID end, maps:get(PluginType, State)) ||
                 PluginType <- maps:keys(State) ],
    {reply, ok, State0};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
                         {noreply, NewState :: term()} |
                         {noreply, NewState :: term(), Timeout :: timeout()} |
                         {noreply, NewState :: term(), hibernate} |
                         {stop, Reason :: term(), NewState :: term()}.
handle_cast({register_plugin, ReqType, Module, Options, Priority}, State) ->
    PluginId = uuid:uuid_to_string(uuid:get_v4()),
    ?DEBUG("Register plugin for request-type ~s with ID: ~s and options: ~p",
           [ReqType, PluginId, Options]),
    NewQueue =
        insert_into_queue(#{id => PluginId,
                            module => Module,
                            options => Options}, Priority, maps:get(ReqType, State, [])),
    {noreply, maps:put(ReqType, NewQueue, State)};
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
                         {noreply, NewState :: term()} |
                         {noreply, NewState :: term(), Timeout :: timeout()} |
                         {noreply, NewState :: term(), hibernate} |
                         {stop, Reason :: normal | term(), NewState :: term()}.
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
                                      {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

insert_into_queue(Item, Priority, []) ->
    [{Priority, Item}];
insert_into_queue(Item, Priority, [{CurrentPrio, _}=CurrentItem|Tl]) when Priority > CurrentPrio ->
    [CurrentItem|insert_into_queue(Item, Priority, Tl)];
insert_into_queue(Item, Priority, [{CurrentPrio, _}=CurrentItem|Tl]) when Priority == CurrentPrio orelse
                                                                          Priority < CurrentPrio ->
    [{Priority, Item}, CurrentItem|Tl].
