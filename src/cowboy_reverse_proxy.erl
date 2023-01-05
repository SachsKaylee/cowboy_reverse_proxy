%%%-------------------------------------------------------------------
%%% @author patrick.sachs
%%% @copyright (C) 2020, Patrick Sachs
%%% @doc
%%% A reverse proxy for cowboy using the erlang httpc client. Usage example:
%%% 
%%% {"/[...]", cowboy_reverse_proxy, [
%%%   {host, "example.com"}, 
%%%   {protocol, "https"}
%%% ]}
%%% 
%%% Please refer to the source code file for a more in depth documentation 
%%% of all available options.
%%% @end
%%% Created : 20. Oct 2020 19:58
%%%-------------------------------------------------------------------
%%% Available proplist options for the cowboy handler are:
%%% 
%%%   - host (required): The host to proxy to. If a non default port is 
%%%     required add the port to this value. (e.g. "sahnee.dev:444")
%%% 
%%%   - protocol (default "http"): The protocol to proxy. Can technically 
%%%     be any string but only "http" and "https" are officially supported.
%%% 
%%%   - change_host (default: false): Should the "host" header be changed 
%%%     to the value specified in the host option. This can be useful 
%%%     for bypassing cross origin checks by pretending that the frontend 
%%%     of the server you are proxying to made the request.
%%% 
%%%   - modify_path (default: identity/1): An arity 1 function that gets
%%%     passed the path of every request as a charlist which can modify it. 
%%%     Useful if the proxy path is not the same as the one being proxied to.
%%% 
%%%   - disable_proxy_headers (default: false): Disables all x-proxy headers 
%%%     sent by this proxy. You want to set this for security hardening.
%%% 
%%%   - use_forwarded_for (default: false): Adds or updates the "x-forwarded-for"
%%%     header with the peer IP of the client the request is proxied for. Use
%%%     this to "play nice" and tell the servers you are proxying on whose 
%%%     behalf your request was made.
%%% 
%%% Advanced options:
%%% 
%%%   - body_opts (default: #{}): A map of options passed to the
%%%     cowboy_req:read_body/3 function:
%%%     https://ninenines.eu/docs/en/cowboy/2.8/manual/cowboy_req.read_body/
%%% 
%%%   - http_opts (default: []): A list of options passed to "HTTPOptions" 
%%%     parameter of the httpc:request/4 function:
%%%     https://erlang.org/doc/man/httpc.html#request-5
%%% 
%%%   - misc_opts (default: []): A list of options passed to "Options" 
%%%     parameter of the httpc:request/4 function:
%%%     https://erlang.org/doc/man/httpc.html#request-5
%%%-------------------------------------------------------------------
-module(cowboy_reverse_proxy).
-author("patrick.sachs").
-include_lib("kernel/include/logger.hrl").
-export([init/2]).
-define(FORWARD_HEADER, "x-forwarded-for").

%%%-------------------------------------------------------------------
%%% COWBOY
%%%-------------------------------------------------------------------
%%% The cowboy behaviour & entrypoint of the module.

init(Req0, State) ->
  Method = method(Req0),
  {Req1, Request} = request(Req0, State),
  HTTPOptions = opts_http_opts(State),
  Options = opts_misc_opts(State),
  ?LOG_INFO("Proxy request: ~p ~s", [Method, element(1, Request)]),
  %% TODO: Use request/5 if state has a profile parameter
  case httpc:request(Method, Request, HTTPOptions, Options) of
    % We got a response from the remote server!
    {ok, Resp = {{_RespVersion, RespStatus, RespReason}, _RespHeaders, RespBody}} ->
      ?LOG_INFO("Proxy response: ~p ~s", [RespStatus, RespReason]),
      OkReq1 = cowboy_req:reply(RespStatus, response_headers(Resp, State), RespBody, Req1),
      {ok, OkReq1, State};
    % Proxy error (not error on remote server, actual e.g. network error)
    Error ->
      ?LOG_ERROR("Proxy error: ~p", [Error]),
      ErrReq1 = cowboy_req:reply(502, #{"content-type" => "text/plain"}, dump(Error), Req1),
      {ok, ErrReq1, State}
  end.

%%%-------------------------------------------------------------------
%%% RESPONSE
%%%-------------------------------------------------------------------
%%% Functions for sending the server response back to the client.

%% Builds the response headers from the remote servers response.
response_headers({{RespVersion, RespStatus, RespReason}, RespHeaders, _RespBody}, Opts) ->
  List = case opts_disable_proxy_headers(Opts) of
    true -> 
      tuple_list_to_binary(RespHeaders);
    false ->
      [
        {<<"x-proxy-http-version">>, RespVersion},
        {<<"x-proxy-status">>, to_string(RespStatus)},
        {<<"x-proxy-reason">>, to_string(RespReason)}
        | tuple_list_to_binary(RespHeaders)
      ]
  end,
  maps:from_list(List).

%%%-------------------------------------------------------------------
%%% REQUEST
%%%-------------------------------------------------------------------
%%% Functions for making the request to the back end server.

%% Creates the request.
request(Req, Opts) ->
  RequestURL = request_url(Req, Opts),
  RequestHeaders = request_headers(Req, Opts),
  case cowboy_req:has_body(Req) of
    true ->
      ContentType = to_string(cowboy_req:header("content-type", Req, "")),
      {BodyReq, Body} = request_body(Req, Opts),
      {BodyReq, {RequestURL, RequestHeaders, ContentType, Body}};
    false ->
      {Req, {RequestURL, RequestHeaders}}
  end.

%% Creates the request URL.
request_url(Req, Opts) ->
  Path = cowboy_req:path(Req),
  ModifyFun = opts_modify_path(Opts),
  OrigPath = case cowboy_req:qs(Req) of
    <<>> -> Path;
    Qs -> [Path, $?, Qs]
  end,
  NewPath = ModifyFun(to_string(OrigPath)),
  to_string([opts_protocol(Opts), "://", opts_host(Opts), NewPath]).

%% Creates the request headers.
request_headers(Req, Opts) ->
  % Client headers
  Headers = [
    {string:to_lower(to_string(Key)), to_string(Value)} 
    || {Key, Value} <- maps:to_list(cowboy_req:headers(Req))
  ],
  % Replace the host?
  HostHeaders = case opts_change_host(Opts) of
    true -> lists:keystore("host", 1, Headers, {"host", opts_host(Opts)});
    false -> Headers
  end,
  % Add the peer IP to x-forwarded-for?
  case opts_use_forwarded_for(Opts) of
    true ->
      {PeerAddress, _PeerPort} = cowboy_req:peer(Req),
      PeerAddressString = inet:ntoa(PeerAddress),
      case lists:keyfind(?FORWARD_HEADER, 1, HostHeaders) of
        false -> 
          [{?FORWARD_HEADER, PeerAddressString} | HostHeaders];
        {?FORWARD_HEADER, XForwardedFor} ->
          lists:keyreplace(?FORWARD_HEADER, 1, HostHeaders, 
          {?FORWARD_HEADER, to_string([PeerAddressString, ", ", XForwardedFor])})
      end;
    false -> HostHeaders
  end.

%% Reads the request body.
request_body(Req, Opts) ->
  request_body(Req, Opts, <<>>).
request_body(Req, Opts, Acc) ->
  case cowboy_req:read_body(Req, opts_body_opts(Opts)) of
    {ok, Data, NewReq} -> {NewReq, <<Acc/binary, Data/binary>>};
    {more, Data, NewReq} -> request_body(NewReq, Opts, <<Acc/binary, Data/binary>>)
  end.

%%%-------------------------------------------------------------------
%%% OPTIONS
%%%-------------------------------------------------------------------
%%% Functions for reading options. Use this as a reference for all available options.
%%% See the top of this source file for documentation on the available options.

opts_protocol(Opts) -> proplists:get_value(protocol, Opts, "http").
opts_host(Opts) -> proplists:get_value(host, Opts).
opts_change_host(Opts) -> proplists:get_bool(change_host, Opts).
opts_use_forwarded_for(Opts) -> proplists:get_bool(use_forwarded_for, Opts).
opts_disable_proxy_headers(Opts) -> proplists:get_bool(disable_proxy_headers, Opts).
opts_modify_path(Opts) -> proplists:get_value(modify_path, Opts, fun identity/1).
opts_body_opts(Opts) -> proplists:get_value(body_opts, Opts, #{}).
opts_http_opts(Opts) -> proplists:get_value(http_opts, Opts, []).
opts_misc_opts(Opts) -> proplists:get_value(misc_opts, Opts, []).

%%%-------------------------------------------------------------------
%%% HELPER
%%%-------------------------------------------------------------------
%%% Utility functions.

%% The identity of a value.
identity(Value) -> Value.

%% Translate method names between formats.
method(<<"HEAD">>) -> head;
method(<<"GET">>) -> get;
method(<<"PUT">>) -> put;
method(<<"POST">>) -> post;
method(<<"TRACE">>) -> trace;
method(<<"OPTIONS">>) -> options;
method(<<"DELETE">>) -> delete;
method(<<"PATCH">>) -> patch;
method(Req) when is_map(Req) -> method(cowboy_req:method(Req));
method(M) -> error({unsupported_method, M}).

%% Any string to a list to characters.
to_string(Int) when is_integer(Int) -> integer_to_list(Int);
to_string(Binary) when is_binary(Binary) -> binary_to_list(Binary);
to_string(List) -> binary_to_list(iolist_to_binary(List)).

%% Any string to a binary
to_binary(Binary) when is_binary(Binary) -> Binary;
to_binary(List) -> iolist_to_binary(List).

%% Converts all keys in to binary
tuple_list_to_binary(List) ->
  [{to_binary(Key), to_binary(Value)} || {Key, Value} <- List].

%% Dumps any term into a string representation.
dump(Term) ->
  to_string(io_lib:format("~p", [Term])).
