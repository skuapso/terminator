%%%-------------------------------------------------------------------
%%% @author il
%%% @copyright (C) 2012, il
%%% @doc
%%%
%%% @end
%%% Created : 2012-02-15 17:18:05.797380
%%%-------------------------------------------------------------------
-module(tcp_terminator).

-behaviour(gen_server).

%% API
-export([
    start_link/1
  ]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]).

-record(state, {socket, module, options = []}).

-include_lib("logger/include/log.hrl").

-define(TCP_OPTIONS, [binary, {active, once}, {reuseaddr, true}]).
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {'_err'or, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Opts) ->
  gen_server:start_link(?MODULE, Opts, []).

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
init({tcp, Module, Port, Ip, Opts}) ->
  '_notice'("listening ~w ~w ~w", [Ip, Port, {Module, Opts}]),
  process_flag(trap_exit, true),
  {ok, Socket} = gen_tcp:listen(Port, [{ip, Ip} | ?TCP_OPTIONS]),
  {ok, _Ref} = prim_inet:async_accept(Socket, -1),
  {ok, #state{socket = Socket, module = Module, options = Opts}}.

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
handle_call(Request, From, State) ->
  '_warning'("unhandled call ~w from ~w", [Request, From]),
  Reply = ok,
  {reply, Reply, State}.

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
handle_cast(Msg, State) ->
  '_warning'("unhandled cast ~w", [Msg]),
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
handle_info({inet_async, ListenSocket, _Ref, {ok, ClientSocket}},
            #state{socket = ListenSocket,
                   options = Opts,
                   module = Module} = S) ->
  '_trace'("new connection"),
  inet_db:register_socket(ClientSocket, inet_tcp),
  '_debug'("socket '_info': ~w", [inet_db:lookup_socket(ClientSocket)]),
  {ok, _Pid} = terminator:accept({tcp, ClientSocket}, {Module, Opts}),
  {ok, _NewRef} = prim_inet:async_accept(ListenSocket, -1),
  {noreply, S};
handle_info({'EXIT', _Pid, Reason}, S) ->
  '_debug'("connection closed ~w", [Reason]),
  {noreply, S};
handle_info(Info, State) ->
  '_warning'("unhandled '_info' ~w", [Info]),
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
