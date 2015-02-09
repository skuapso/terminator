-module(terminator).

-behaviour(application).
-behaviour(supervisor).

%% API
-export([start_link/1]).
-export([listen/1]).
-export([accept/2]).
-export([add_uin/2]).
-export([add_terminal/4]).
-export([terminal_command/4]).
-export([delete_terminal/3]).

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

listen(X) ->
  listen(X, []).

listen({Type, Module, Port}, Opts) ->
  listen({Type, Module, Port, Opts});
listen({Type, Module, Port, LOpts}, CommOpts) ->
  Opts = LOpts ++ CommOpts,
  Ip = proplists:get_value(ip, Opts, {0, 0, 0, 0}),
  listen({Type, Module, Port, Ip, proplists:delete(ip, Opts)}, []);
listen(Opts, _) when tuple_size(Opts) =:= 5 ->
  Terminator = terminator(element(1, Opts)),
  supervisor:start_child(?MODULE, listener(Terminator, Opts)).

accept(Socket, Module) ->
  terminal:accept(Socket, Module).

start_link(Opts) ->
  Reply = supervisor:start_link({local, ?MODULE}, ?MODULE, Opts),
  Listen = misc:get_env(?MODULE, listen, Opts),
  CommonOpts = misc:get_env(?MODULE, options, Opts),
  lists:map(fun(X) ->
        listen(X, CommonOpts)
    end, Listen),
  Reply.

start() ->
  application:start(?MODULE).

start(_StartType, StartArgs) ->
  start_link(StartArgs).

stop(_State) ->
  ok.

add_terminal(Pid, Terminal, _Socket, _Timeout) ->
  case ets:match(?MODULE, {'$1', Terminal}) of
    [] -> ok;
    L -> lists:map(fun(X) ->
            '_info'("duplicate for ~p, old pid is ~p", [Terminal, X]),
            exit(X, kill)
        end, lists:delete(Pid, lists:flatten(L)))
  end,
  ets:insert(?MODULE, {Pid, Terminal}),
  ok.

terminal_command(_Pid, Terminal, _RawData, _Timeout) ->
  case hooks:run(get, [terminal, command, Terminal]) of
    [] -> ok;
    [{Recipient, {CommandId, Command, _SendType}} | _] ->
      '_debug'("setting exec to command ~w", [CommandId]),
%      hooks:run({Recipient, set}, [terminal, command_exec, {Terminal, CommandId}]),
      {ok, {Recipient, {command, {CommandId, Command}}}}
  end.

delete_terminal(Pid, _Reason, _Timeout) ->
  ets:delete(?MODULE, Pid),
  ok.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
init(Opts) ->
  ets:new(?MODULE, [set, public, named_table]),
  Weight = misc:get_env(?MODULE, weight, Opts),
  hooks:install({terminal, connected}, Weight, {?MODULE, add_terminal}),
  hooks:install({terminal, raw_data}, Weight, {?MODULE, terminal_command}),
  hooks:install({terminal, disconnected}, Weight, {?MODULE, delete_terminal}),
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
listener(Module, {_Type, _HandlerModule, Port, Ip, _} = Opts) ->
  {
    {Module, Port, Ip},
    {Module, start_link, [Opts]},
    transient,
    2000,
    worker,
    [Module]
  }.

terminator(tcp) -> tcp_terminator.
