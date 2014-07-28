-module(terminator).

-behaviour(application).
-behaviour(supervisor).

%% API
-export([start_link/1]).
-export([listen/1]).
-export([accept/2]).
-export([add_uin/2]).
-export([add_terminal/3]).
-export([terminal_command/4]).
-export([delete_terminal/3]).
-export([init_terminator/2]).

-export([behaviour_info/1]).

%% Application callbacks
-export([start/0, start/2, stop/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("logger/include/log.hrl").
%% ===================================================================
%% API functions
%% ===================================================================
add_uin(Parsed, UIN) ->
  case proplists:get_value(navigation, Parsed, []) of
    [] ->
      Parsed;
    N ->
      [{navigation, [{uin, UIN} | N]} | proplists:delete(navigation, Parsed)]
  end.

behaviour_info(callbacks) ->
  [
    {accept, 1},
    {close, 1},
    {enter_loop, 1}
  ].

listen({Type, Module, Port}) ->
  listen({Type, Module, Port, {0, 0, 0, 0}});
listen({Type, _Module, _Port, _Ip} = Opts) ->
  Terminator = list_to_atom(atom_to_list(Type) ++ "_terminator"),
  supervisor:start_child(?MODULE, listener(Terminator, Opts)).

accept(Module, Socket) when is_port(Socket) ->
  trace("starting ~p terminator", [Module]),
  {ok, Pid} = Reply = proc_lib:start_link(?MODULE, init_terminator, [Module, Socket]),
  debug("accepted by ~w", [Pid]),
  trace("setting controlling process"),
  gen_tcp:controlling_process(Socket, Pid),
  trace("accepting ~p", [Pid]),
  Module:accept(Pid),
  Reply.

start_link(Opts) ->
  Reply = supervisor:start_link({local, ?MODULE}, ?MODULE, Opts),
  Listen = misc:get_env(?MODULE, listen, Opts),
  lists:map(fun(X) ->
        listen(X)
    end, Listen),
  Reply.

start() ->
  application:start(?MODULE).

start(_StartType, StartArgs) ->
  start_link(StartArgs).

stop(_State) ->
  ok.

add_terminal(Pid, Terminal, _Timeout) ->
  case ets:match(?MODULE, {'$1', Terminal}) of
    [] -> ok;
    L -> lists:map(fun(X) ->
            info("duplicate for ~p, old pid is ~p", [Terminal, X]),
            exit(X, kill)
        end, lists:delete(Pid, lists:flatten(L)))
  end,
  ets:insert(?MODULE, {Pid, Terminal}),
  ok.

terminal_command(_Pid, Terminal, _RawData, _Timeout) ->
%  Terminal = {Module, UIN},
  case hooks:run(get, [terminal, command, Terminal]) of
    [] -> ok;
    [{Recipient, {CommandId, Command, _SendType}} | _] ->
      hooks:run({Recipient, set}, [terminal, command_exec, {Terminal, CommandId}]),
      {ok, {command, {answer, Command}}}
  end.

delete_terminal(Pid, _Reason, _Timeout) ->
  ets:delete(?MODULE, Pid),
  ok.

init_terminator(Module, Socket) ->
  trace("init ~w", [Module]),
  proc_lib:init_ack({ok, self()}),
  hooks:run(connection_accepted, [Module, Socket], 10000),
  hooks:final(connection_closed),
  ets:insert(?MODULE, {self(), undefined}),
  process_flag(trap_exit, true),
  Module:enter_loop(Socket).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
init(Opts) ->
  ets:new(?MODULE, [set, public, named_table]),
  Weight = misc:get_env(?MODULE, weight, Opts),
  hooks:install(terminal_uin, Weight, {?MODULE, add_terminal}),
  hooks:install(terminal_raw_data, Weight, {?MODULE, terminal_command}),
  hooks:install(connection_closed, Weight, {?MODULE, delete_terminal}),
  {ok,
    {
      {one_for_one, 5, 10},
      [
      ]
    }
  }.

%% ===================================================================
%% Internal functions
%% ===================================================================
listener(Module, {_Type, _HandlerModule, Port, Ip} = Opts) ->
  {
    {Module, Port, Ip},
    {Module, start_link, [Opts]},
    transient,
    2000,
    worker,
    [Module]
  }.
