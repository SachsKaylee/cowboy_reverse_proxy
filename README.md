# cowboy_reverse_proxy

A reverse proxy for cowboy using the erlang httpc client. 

## Usage example:

```erl
{"/proxy/[...]", cowboy_reverse_proxy, [
  {host, "example.com"}, 
  {protocol, "https"}
]}
```

This proxies all incoming requests under `/proxy` to `https://example.com/proxy`. The path is being kept.

## Options

Available proplist options for the cowboy handler are:

  - `host` *(required)*: The host to proxy to. If a non default port is 
    required add the port to this value. (e.g. `"sahnee.dev:444"`)

  - `protocol` *(default: `"http"`)*: The procol to proxy. Can technically 
    be any string but only `"http"` and `"https"` is officially supported.

  - `change_host` *(default: `false`)*: Should the "host" header be changed 
    to the value specified in the "host" option. This can be useful 
    for bypassing cross origin checks by pretending that the frontend 
    of the server you are proxying to made the request.

  - `modify_path` *(default: `identity/1`)*: An arity 1 function that gets
    passed the path of every request as a charlist which can modify it. 
    Useful if the proxy path is not the same as the one being proxied to.

  - `disable_proxy_headers` *(default: `false`)*: Disables all x-proxy headers 
    sent by this proxy. You want to set this for security hardening.

  - `use_forwarded_for` *(default: `false`)*: Adds or updates the `"x-forwarded-for"`
    header with the peer IP of the client the request is proxied for. Use
    this to "play nice" and tell the servers you are proxying on whose 
    behalf your request was made.

Advanced options:

  - `body_opts` *(default: `#{}`)*: A map of options passed to the
    `cowboy_req:read_body/3` function:
    https://ninenines.eu/docs/en/cowboy/2.8/manual/cowboy_req.read_body/

  - `http_opts` *(default: `[]`)*: A list of options passed to `"HTTPOptions"` 
    parameter of the `httpc:request/4` function:
    https://erlang.org/doc/man/httpc.html#request-5

  - `misc_opts` *(default: `[]`)*: A list of options passed to `"Options"` 
    parameter of the `httpc:request/4` function:
    https://erlang.org/doc/man/httpc.html#request-5

## Build

```bash
$ rebar3 compile
```
