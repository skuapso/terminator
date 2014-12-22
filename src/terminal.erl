%%%-------------------------------------------------------------------
%%% @author Ilya Ashchepkov
%%% @copyright 2014 NskAvd
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(terminal).

-behaviour(gen_server).

-export([behaviour_info/1]).
%% API
-export([accept/2]).
-export([set/3]).
-export([set/4]).
-export([state/2]).
-export([socket/1]).
-export([sockopts/1]).
-export([terminal/1]).
-export([uin/1]).
-export([answer/1]).
-export([timeout/1]).
-export([active/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {state = #{},
                uin,
                socket,
                module,
                answer,
                active = false,
                timeout = 30000,
                sockopts = #{active => true,
                             mode => binary,
                             buffer => 65535},
                in = 65535,
                out = 1400,
                close = false,
                incomplete = <<>>}).

-define(socket(T, Sock, Socket),
        element(1, Socket) =:= T
        andalso element(2, Socket) =:= Sock
       ).

-include_lib("logger/include/log.hrl").
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
behaviour_info(callbacks) ->
  [
   {init, 2},
   {uin, 2},
   {parse, 2},
   {answer, 1},
   {handle_hooks, 4},
   {handle_info, 2}
  ].

accept(Socket, Module) ->
  {ok, Pid} = Reply = gen_server:start_link(?MODULE, {Socket, Module}, []),
  set_control(Socket, Pid),
  Reply.

socket(#state{socket = Socket}) -> Socket.

sockopts(#state{sockopts = SockOpts}) -> SockOpts.

terminal(#state{module = Module, uin = Uin}) -> {Module, Uin}.

uin(#state{uin = Uin}) -> Uin.

timeout(#state{timeout = Timeout}) -> Timeout.

state(#state{state = IState}, Module) ->
  maps:get(Module, IState, #{}).

answer(#state{answer = Answer}) -> Answer.
active(#state{active = Active}) -> Active.

set(State = #state{state = IState}, Module, Key, Val) ->
  MState = maps:get(Module, IState, #{}),
  NewMState = maps:put(Key, Val, MState),
  NewIState = maps:put(Module, NewMState, IState),
  State#state{state = NewIState}.

set(State = #state{state = IState}, {module, Module}, MState) when is_map(IState) ->
  NewIState = maps:put(Module, MState, IState),
  State#state{state = NewIState};
set(State = #state{}, answer, Answer) -> State#state{answer = Answer};
set(State = #state{}, socket, Socket) -> State#state{socket = Socket};
set(State = #state{}, close,  Close)  -> State#state{close  = Close};
set(State = #state{}, uin,    Uin)    -> State#state{uin    = Uin};
set(State = #state{}, sockopts, Opts) -> State#state{sockopts = Opts};
set(State = #state{}, timeout,Timeout)-> State#state{timeout= Timeout};
set(State = #state{}, active, Active) -> State#state{active = Active};
set(State = #state{}, module, Module) -> State#state{module = Module};
set(State = #state{}, out,    Out)    -> State#state{out    = Out};
set(State = #state{}, in,     In)     -> State#state{in     = In}.

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
init(Opts) ->
  '_trace'("init"),
  process_flag(trap_exit, true),
  {ok, Opts, 30000}.

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
handle_call(_Request, _From, State) ->
  '_warning'("unhandled call ~w from ~w", [_Request, _From]),
  return(State).

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
handle_cast(accept, {Socket, {Module, Opts}}) ->
  '_trace'("accepting socket"),
  {ok, State} = Module:init(Opts, #state{socket = Socket, module = Module}),
  set_socket_opts(Socket, State),
  return(State);
handle_cast(_Msg, State) ->
  '_warning'("unhandled cast ~w", [_Msg]),
  return(State).

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
handle_info({T, Sock, SockData} = Msg, #state{socket = Socket,
                                        uin = undefined,
                                        module = Module,
                                        incomplete = Incomplete} = State)
  when ?socket(T, Sock, Socket) ->
  '_trace'("getting uin"),
  {Data, State1} = merge_data(SockData, Incomplete, State),
  NewState = case Module:uin(Data, State1) of
            {incomplete, #state{} = State2} ->
              handle_incomplete(Data, State2);
            {ok, Uin, #state{} = State2} ->
              set_uin(Uin, Msg, State2);
            incomplete ->
              handle_incomplete(Data, State1);
            {ok, Uin} ->
              set_uin(Uin, Msg, State1)
          end,
  return(NewState);
handle_info({T, Sock, SockData}, #state{socket = Socket,
                                        module = Module,
                                        incomplete = Incomplete} = State)
  when ?socket(T, Sock, Socket) ->
  '_trace'("parsing data"),
  {Data, State1} = merge_data(SockData, Incomplete, State),
  NewState = case catch Module:parse(Data, State1) of
            {incomplete, #state{} = State2} ->
              handle_incomplete(Data, State2);

            {ok, Packets, #state{} = State2} ->
              handle_parsed(Data, Packets, State2);

            {ok, RawParsed, Packets, #state{} = State2} ->
              handle_parsed(RawParsed, Packets, State2);

            {ok, RawParsed, Packets, Incomplete, #state{} = State2} ->
              handle_parsed(RawParsed, Packets, handle_incomplete(Incomplete, State2));

            incomplete ->
              handle_incomplete(Data, State1);

            {ok, Packets} ->
              handle_parsed(Data, Packets, State1);

            {ok, RawParsed, Packets} ->
              handle_parsed(RawParsed, Packets, State1);

            {ok, RawParsed, Packets, Incomplete} ->
              handle_parsed(RawParsed, Packets, handle_incomplete(Incomplete, State1));

            {'EXIT', Reason} ->
              exit({broken, Data, Reason})
          end,
  return(NewState);
handle_info({T, Sock, SockData}, #state{socket = Socket,
                                          incomplete = Incomplete} = State)
  when ?socket(T, Sock, Socket) ->
  '_warning'("recv buffer overflow"),
  return(State#state{incomplete = <<Incomplete/binary, SockData/binary>>, close = overflow});
handle_info({tcp_closed, Sock}, #state{socket = Socket} = State)
  when ?socket(tcp, Sock, Socket) ->
  '_trace'("socket closed"),
  return(State#state{close = normal});
handle_info(timeout, State) ->
  '_trace'("timeout"),
  return(State#state{close = normal});
handle_info(Info, #state{module = Module} = State) ->
  NewState = case Module:handle_info(Info, State) of
               {ok, State1} -> State1
             end,
  return(NewState).

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
terminate({broken, Data, _Reason}, State) ->
  terminate({broken, Data}, State);
terminate(Reason, State) ->
  '_debug'("connection closed"),
  run_hook(connection_closed, [Reason], State),
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
  '_notice'("code change from ~w with extra ~w", [_OldVsn, _Extra]),
  {ok, State, timeout(State)}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
merge_data(SockData, Incomplete, #state{in = In} = State) ->
  case is_binary(SockData) of
    true when byte_size(Incomplete) + byte_size(SockData) > In ->
      {<<>>, State#state{close = overflow}};
    true ->
      {<<Incomplete/binary, SockData/binary>>, State};
    false ->
      {SockData, State}
  end.

set_control({tcp, Socket}, Pid) ->
  gen_tcp:controlling_process(Socket, Pid),
  gen_server:cast(Pid, accept).

set_socket_opts({tcp, Socket}, #state{sockopts = Opts}) ->
  inet:setopts(Socket, maps:to_list(Opts));
set_socket_opts(_Socket, #state{module = Module} = State) ->
  Module:setopts(State).

send(Data, #state{socket = {tcp, Socket}} = State) when Data =/= <<>> ->
  Result = gen_tcp:send(Socket, Data),
  {Result, State};
send(<<>>, #state{socket = {tcp, _Socket}} = State) ->
  {ok, State};
send(Data, #state{module = Module} = State) ->
  Module:send(Data, State).

handle_parsed(<<>>, [Packet | Packets], State) ->
  '_trace'("packet ~w", [Packet]),
  State1 = run_hook(terminal_packet, [terminal(State), Packet], State),
  handle_parsed(<<>>, Packets, State1);

handle_parsed(RawData, Packets, State)
  when
    RawData =/= <<>>
    andalso is_binary(RawData) ->
  '_trace'("raw ~w", [RawData]),
  State1 = run_hook(terminal_raw_data, [terminal(State), RawData], State),
  '_trace'("handling packets ~w", [Packets]),
  handle_parsed(<<>>, Packets, State1);

handle_parsed(RawData, Packets, #state{module = Module} = State)
  when RawData =/= <<>> ->
  '_trace'("getting binary data representation"),
  case Module:to_binary(raw, RawData) of
    {ok, Data} -> handle_parsed(Data, Packets, State)
  end;

handle_parsed(<<>>, [], State) ->
  handle_answer(State).

handle_answer(#state{answer = {AnsModule, Answer}, module = Module, active = false} = State)
  when
    is_binary(Answer)
    orelse (AnsModule =:= Module)
    ->
  BinAnswer = case is_binary(Answer) of
                true -> Answer;
                false -> Module:to_binary(answer, Answer)
              end,
  State1 = run_hook(terminal_answer, [terminal(State), AnsModule, BinAnswer], State),
  {ok, State2} = send(Answer, State1),
  '_debug'("state after send ~w", [State2]),
  State2#state{answer = undefined};

handle_answer(#state{module = Module, answer = PrevAnswer} = State) ->
  '_debug'("getting answer from ~w, state ~w, prev answer is ~w", [Module, State, PrevAnswer]),
  Answer = case Module:answer(State) of
              {ok, A} -> {ok, A, State};
              A -> A
            end,
  {ok, Answer1, State1} = case Answer of
                           {ok, A1, State_} when is_binary(A1) ->
                             {ok, {Module, A1}, State_};
                           A1 -> A1
                         end,
  handle_answer(State1#state{answer = Answer1, active = false}).

handle_incomplete(Data, State) ->
  '_debug'("incomplete ~w", [Data]),
  State#state{incomplete = Data}.

set_uin(Uin, Data, #state{socket = Socket, module = Module} = State) ->
  '_debug'("got uin ~w", [Uin]),
  State1 = State#state{uin = Uin},
  State2 = run_hook(connection_accepted, [Module, element(2, Socket)], State1),
  State3 = run_hook(terminal_uin, [terminal(State1)], State2),
  '_trace'("handling data with state ~p", [State3]),
  case handle_info(Data, State3) of
    {noreply, NewState, _} -> NewState;
    {stop, _, NewState} -> NewState
  end.

run_hook(Hook, Data, #state{module = Module} = State) ->
  HooksData = hooks:run(Hook, Data, timeout(State)),
  {HooksData1, State1} = handle_hooks(Hook, HooksData, State),
  '_trace'("handling hooks for ~p in ~p", [Hook, Module]),
  case Module:handle_hooks(Hook, Data, HooksData1, State1) of
    ok -> State1;
    {ok, State2} -> State2
  end.

handle_hooks(terminal_raw_data, HooksData, State) when is_list(HooksData) ->
  case list_div(fun({_, {answer, _}}) -> true; (_) -> false end, HooksData) of
    {[], HooksData1} -> {HooksData1, State};
    {[{Module, {answer, Answer}} | _], HooksData1} ->
      {HooksData1, State#state{answer = {Module, Answer}}}
  end;
handle_hooks(_Hook, Answers, State) ->
  {Answers, State}.

list_div(Fun, List) ->
  list_div(Fun, List, [], []).

list_div(Fun, [E | List], Matched, NotMatched) ->
  case Fun(E) of
    true -> list_div(Fun, List, [E | Matched], NotMatched);
    false ->list_div(Fun, List, Matched, [E | NotMatched])
  end;
list_div(_, [], Matched, NotMatched) ->
  {lists:reverse(Matched), lists:reverse(NotMatched)}.

return(#state{close = false} = State) ->
  '_trace'("new state ~p", [State]),
  {noreply, State, timeout(State)};
return(#state{close = Reason} = State) when Reason =/= false ->
  '_trace'("stop request"),
  {stop, Reason, State};
return(Reply) ->
  '_warning'("self reply ~p", [Reply]),
  Reply.

%% vim: ft=erlang
