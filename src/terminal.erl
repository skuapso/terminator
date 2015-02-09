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
-export([command/1]).
-export([commands/1]).
-export([sockopts/1]).
-export([terminal/1]).
-export([uin/1]).
-export([answer/1]).
-export([timeout/1]).
-export([active/1]).
-export([proxy/1]).

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
                commands = [],
                proxy,
                incomplete = <<>>}).

-define(is_socket(T, Sock, Socket),
        element(1, Socket) =:= T
        andalso element(2, Socket) =:= Sock
       ).

-define(is_answer(T),
        is_tuple(T)
        andalso tuple_size(T) =:= 2
        andalso is_atom(element(1, T))
        andalso is_binary(element(2, T))
       ).
-define(internal_proto(T),
        T =:= tcp orelse T =:= unauthorized
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
   {handle_info, 2},
   {connect, 3},
   {send, 2},
   {recv, 2},
   {setopts, 2}
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

command({_Recipient, {_Id, Cmd}}) -> Cmd.

commands(#state{commands = Commands}) -> Commands.

state(#state{state = IState}, Module) ->
  maps:get(Module, IState, #{}).

answer(#state{answer = Answer}) -> Answer.

active(#state{active = Active}) -> Active.

proxy(#state{proxy = Proxy}) -> Proxy.

set(State = #state{state = IState}, Module, Key, Val) ->
  MState = maps:get(Module, IState, #{}),
  NewMState = maps:put(Key, Val, MState),
  NewIState = maps:put(Module, NewMState, IState),
  State#state{state = NewIState}.

set(State = #state{state = IState}, {module, Module}, MState) when is_map(IState) ->
  NewIState = maps:put(Module, MState, IState),
  State#state{state = NewIState};
set(State = #state{}, answer, Answer) -> State#state{answer = Answer};
set(State = #state{}, commands, Cmds) -> State#state{commands=Cmds};
set(State = #state{}, socket, Socket) -> State#state{socket = Socket};
set(State = #state{}, close,  Close)  -> State#state{close  = Close};
set(State = #state{}, uin,    Uin)    -> State#state{uin    = Uin};
set(State = #state{}, sockopts, Opts) -> State#state{sockopts = Opts};
set(State = #state{}, proxy, Proxy)   -> State#state{proxy  = Proxy};
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
  {ok, Unparsed, State} = parse_opts(Opts, [], #state{socket = Socket, module = Module}),
  {ok, #state{sockopts = SockOpts} = State1} = Module:init(Unparsed, State),
  setopts(Socket, SockOpts),
  return(State1);
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
  when ?is_socket(T, Sock, Socket) ->
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
  when ?is_socket(T, Sock, Socket) ->
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
  when ?is_socket(T, Sock, Socket) ->
  '_warning'("recv buffer overflow"),
  return(State#state{incomplete = <<Incomplete/binary, SockData/binary>>, close = overflow});
handle_info({tcp_closed, Sock}, #state{socket = Socket} = State)
  when ?is_socket(tcp, Sock, Socket) ->
  '_trace'("socket closed"),
  return(State#state{close = normal});
handle_info({tcp_closed, Sock}, #state{proxy = Proxy} = State)
  when ?is_socket(tcp, Sock, Proxy) ->
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
terminate(Reason, _State) ->
  '_warning'(Reason =/= normal, "connection closed ~p", [Reason], debug),
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
  return(State).

%%%===================================================================
%%% Internal functions
%%%===================================================================
parse_opts([{proxy, Proxy} | Opts], Unparsed, State) ->
  parse_opts(Opts, Unparsed, State#state{proxy = Proxy});
parse_opts([Opt | Opts], Unparsed, State) ->
  parse_opts(Opts, [Opt | Unparsed], State);
parse_opts([], Unparsed, State) ->
  {ok, lists:reverse(Unparsed), State}.

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

setopts(Socket, Opts) when is_map(Opts) ->
  setopts(Socket, maps:to_list(Opts));
setopts({Proto, Socket}, Opts) when ?internal_proto(Proto) ->
  inet:setopts(Socket, Opts);
setopts({Module, Socket}, Opts) ->
  Module:setopts(Socket, Opts).

send({Proto, Socket}, Data) when ?internal_proto(Proto) ->
  gen_tcp:send(Socket, Data);
send({Module, Socket}, Data) ->
  Module:send(Socket, Data).

handle_parsed(<<>>, [Packet | Packets], State) ->
  '_trace'("packet ~w", [Packet]),
  State1 = run_hook(packet, [terminal(State), Packet], State),
  handle_parsed(<<>>, Packets, State1);

handle_parsed(RawData, Packets, #state{proxy = Proxy, socket = Socket} = State)
  when
    RawData =/= <<>>
    andalso is_binary(RawData) ->
  '_trace'("raw ~w", [RawData]),
  %% logicaly sending to proxy should be in handle_hooks/4
  %% but we need RawData and Packets which is unavailable in handle_hooks/4
  %% also proxy should answer before any hook
  ProxyData = case Proxy =/= undefined of
                true
                  when element(1, Proxy) =:= element(1, Socket)
                       orelse element(1, Proxy) =:= unauthorized
                       ->
                  RawData;
                true ->
                  Module = element(1, Proxy),
                  Repacked_ = [Module:pack(X) || X <- Packets],
                  Repacked = [X || {ok, X} <- Repacked_],
                  Module:prepare(terminal(State), Repacked);
                 _ ->
                    <<>>
               end,
  HooksData = case ProxyData of
                <<>> -> [];
                _ ->
                   {ok, Answer} = proxy_send(Proxy, ProxyData),
                   case element(1, Proxy) =:= unauthorized of
                     true ->
                       [];
                     false when element(1, Proxy) =/= element(1, Socket) ->
                       [];
                     false -> [{proxy, {answer, Answer}}]
                   end
              end,
  State1 = run_hook(raw_data, [terminal(State), RawData], HooksData, State),
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

handle_answer(#state{answer = {AnsModule, Answer},
                     module = Module,
                     socket = Socket,
                     active = false,
                     commands = []} = State)
  when
    is_binary(Answer)
    orelse (AnsModule =:= Module)
    ->
  {ok, BinAnswer} = case is_binary(Answer) of
                      true -> {ok, Answer};
                      false -> Module:to_binary(answer, Answer)
                    end,
  State1 = run_hook(answer, [terminal(State), AnsModule, BinAnswer], State),
  ok = send(Socket, Answer),
  State1#state{answer = undefined};

handle_answer(#state{module = Module, answer = PrevAnswer, commands = Cmds} = State) ->
  '_debug'("getting answer from ~w, state ~w, prev answer is ~w", [Module, State, PrevAnswer]),
  {ok, Answer, NewState} = case Module:answer(State) of
                             {ok, A}
                               when not (?is_answer(A))->
                               {ok, {Module, A}, State};
                             {ok, A, #state{} = NState} when not (?is_answer(A)) ->
                               {ok, {Module, A}, NState};
                             {ok, A} ->
                               {ok, A, State};
                             A ->
                               A
                           end,
  '_debug'("answer is ~p", [Answer]),
  #state{commands = NewCmds} = NewState,
  RunnedCmds = Cmds -- NewCmds,
  [hooks:run({Rec, set}, [terminal, command_exec, {terminal(NewState), Id}], timeout(NewState)) ||
   {Rec, {Id, _Cmd}} <- RunnedCmds],
  handle_answer(NewState#state{answer = Answer, active = false}).

handle_incomplete(Data, State) ->
  '_debug'("incomplete ~w", [Data]),
  State#state{incomplete = Data}.

set_uin(Uin, Data, #state{socket = {_, Socket}} = State) ->
  '_debug'("got uin ~w", [Uin]),
  State1 = State#state{uin = Uin},
  hooks:final({terminal, disconnected}),
  State2 = run_hook(connected, [terminal(State1), Socket], State1),
  '_trace'("handling data with state ~p", [State2]),
  case handle_info(Data, State2) of
    {noreply, NewState, _} -> NewState;
    {stop, _, NewState} -> NewState
  end.

run_hook(Hook, Data, State) ->
  run_hook(Hook, Data, [], State).

run_hook(Hook, Data, HooksData, #state{module = Module} = State) ->
  HooksData1 = hooks:run({?MODULE, Hook}, Data, timeout(State)),
  HooksData2 = HooksData ++ HooksData1,
  {HooksData3, State1} = handle_hooks([proxy, commands, answer], Hook, HooksData2, State),
  '_trace'("handling hooks for ~p in ~p", [Hook, Module]),
  case Module:handle_hooks(Hook, Data, HooksData3, State1) of
    ok -> State1;
    {ok, State2} -> State2
  end.

handle_hooks([answer | T], Hook, HooksData, State)
  when Hook =:= raw_data ->
  Splitted = list_split(fun({_, {answer, _}}) -> true; (_) -> false end, HooksData),
  {Unhandled, NewState} = case Splitted of
                            {[], HooksData1} -> {HooksData1, State};
                            {[{Module, {answer, Answer}} | _], HooksData1} ->
                              {HooksData1, State#state{answer = {Module, Answer}}}
                          end,
  handle_hooks(T, Hook, Unhandled, NewState);

handle_hooks([proxy | T], Hook, HooksData, #state{proxy = Proxy, socket = Socket} = State)
  when Hook =:= connected andalso Proxy =/= undefined->
  {ok, NewState} = connect(State),
  #state{proxy = ProxySocket} = NewState,
  ProxyProto = element(1, ProxySocket),
  case ProxyProto =:= unauthorized orelse ProxyProto =:= element(1, Socket) of
    true ->
      % in this case terminal will send authorization info
      % and we will send it in handle_parsed/3
      ok;
    false ->
      AuthData = case catch ProxyProto:auth(terminal(NewState)) of
                   {'EXIT', _} -> <<>>;
                   AuthData_ -> AuthData_
                 end,
      proxy_send(ProxySocket, AuthData),
      ok
  end,
  handle_hooks(T, Hook, HooksData, NewState#state{proxy = ProxySocket});

handle_hooks([commands | T], Hook, HooksData, #state{commands = Cmds} = State) ->
  {CmdAnsw, Unhandled} = list_split(fun({_, {command, _}}) -> true; (_) -> false end, HooksData),
  NewCmds = [{Recipient, Cmd} || {Recipient, {command, Cmd}} <- CmdAnsw],
  NewState = State#state{commands = Cmds ++ NewCmds},
  handle_hooks(T, Hook, Unhandled, NewState);

handle_hooks([_ | T], Hook, Answers, State) ->
  handle_hooks(T, Hook, Answers, State);

handle_hooks([], _Hook, Answers, State) ->
  {Answers, State}.

list_split(Fun, List) ->
  list_split(Fun, List, [], []).

list_split(Fun, [E | List], Matched, NotMatched) ->
  case Fun(E) of
    true -> list_split(Fun, List, [E | Matched], NotMatched);
    false ->list_split(Fun, List, Matched, [E | NotMatched])
  end;
list_split(_, [], Matched, NotMatched) ->
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

connect(#state{proxy = Proxy, socket = Socket, sockopts = SockOpts} = State) ->
  {Proto, Host, Port, Opts} = case Proxy of
                                {Proto1, {Host1, Port1}} ->
                                  {Proto1, Host1, Port1, []};
                                {Host1, Port1} ->
                                  {element(1, Socket), Host1, Port1, []};
                                {Proto1, {Host1, Port1}, Opts1} ->
                                  {Proto1, Host1, Port1, Opts1};
                                {Proto1, Host1, Port1} when is_atom(Proto1) ->
                                  {Proto1, Host1, Port1, []};
                                {Host1, Port1, Opts1} ->
                                  {element(1, Socket), Host1, Port1, Opts1};
                                _ -> Proxy
                              end,
  Proto2 = case Proto of
             json -> sk_json;
             _ -> Proto
           end,
  connect(Proto2, Host, Port, SockOpts, Opts, State).

connect(Proto, Host, Port, SockOpts, Opts, State) ->
  {ok, Socket} = case ?internal_proto(Proto) of
                   true ->
                     gen_tcp:connect(Host, Port, maps:to_list(SockOpts));
                   false ->
                     Proto:connect(Host, Port, maps:to_list(SockOpts))
                 end,
  setopts({Proto, Socket}, Opts),
  {ok, State#state{proxy = {Proto, Socket}}}.

recv({Proto, Socket}) when ?internal_proto(Proto) ->
  gen_tcp:recv(Socket, 0);
recv({Module, Socket}) ->
  Module:recv(Socket, 0).

proxy_send(_, <<>>) ->
  {ok, <<>>};
proxy_send(Proxy, Data) ->
  setopts(Proxy, #{active => false}),
  send(Proxy, Data),
  {ok, Answer} = recv(Proxy),
  setopts(Proxy, #{active => true}),
  {ok, Answer}.

%% vim: ft=erlang
