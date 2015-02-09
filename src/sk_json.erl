%%%-------------------------------------------------------------------
%%% @author Ilya Ashchepkov
%%% @copyright 2015 NskAvd
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(sk_json).

-export([connect/3]).
-export([send/2]).
-export([recv/2]).
-export([setopts/2]).
-export([auth/1]).
-export([pack/1]).
-export([prepare/2]).

connect(Host, Port, SockOpts) ->
  gen_tcp:connect(Host, Port, SockOpts).

send(Socket, Data) ->
  gen_tcp:send(Socket, Data).

recv(Socket, Size) ->
  gen_tcp:recv(Socket, Size).

setopts(Socket, [{uri, Uri} | T]) ->
  hooks:set({?MODULE, uri}, Uri),
  setopts(Socket, T);
setopts(Socket, [{headers, Headers} | T]) ->
  hooks:set({?MODULE, headers}, Headers),
  setopts(Socket, T);
setopts(Socket, [Opt | T]) ->
  inet:setopts(Socket, [Opt]),
  setopts(Socket, T);
setopts(_Socket, []) ->
  ok.

auth(_) ->
  <<>>.

pack(Packet) ->
  {ok, maps:without([raw], Packet)}.

prepare({Proto, Uin}, Packets) ->
  PacketsWithTerminal = [X#{proto => Proto, uin => Uin} || X <- Packets],
  JsonedPackets = misc:to_json(PacketsWithTerminal),
  Uri = hooks:get({?MODULE, uri}),
  Headers = case hooks:get({?MODULE, headers}) of
              undefined -> <<>>;
              Headers_ -> Headers_
            end,
  PostData = <<"packets=", JsonedPackets/binary>>,
  Len = integer_to_binary(byte_size(PostData)),
  iolist_to_binary([
                    "POST ", Uri, " HTTP/1.1\r\n",
                    "Connection: keep-alive\r\n",
                    "Content-Length: ", Len, "\r\n",
                    Headers,
                    "\r\n", PostData
                   ]).

%%%===================================================================
%%% Internal functions
%%%===================================================================


%% vim: ft=erlang
