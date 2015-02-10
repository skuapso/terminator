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
  recv(Socket, Size, <<>>).

recv(Socket, Size, RecvData) ->
  {ok, TcpData} = gen_tcp:recv(Socket, Size),
  Data = <<RecvData/binary, TcpData/binary>>,
  Code = case erlang:decode_packet(http, Data, []) of
           {more, _} ->
             recv(Socket, Size, Data);
           {ok, {http_response, _, Code_, _}, _} ->
             Code_
         end,
  2 = Code div 100,
  {ok, integer_to_binary(Code)}.

setopts(Socket, [{path, Uri} | T]) ->
  hooks:set({?MODULE, path}, Uri),
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
  Path = hooks:get({?MODULE, path}),
  Headers = case hooks:get({?MODULE, headers}) of
              undefined -> <<>>;
              Headers_ -> Headers_
            end,
  Len = integer_to_binary(byte_size(JsonedPackets)),
  iolist_to_binary([
                    "POST ", Path, " HTTP/1.1\r\n",
                    "Connection: keep-alive\r\n",
                    "Content-Length: ", Len, "\r\n",
                    "Content-Type: application/json\r\n",
                    Headers,
                    "\r\n\r\n",
                    JsonedPackets
                   ]).

%%%===================================================================
%%% Internal functions
%%%===================================================================


%% vim: ft=erlang
