# The `http` Package

The standard library's HTTP client and server, written in pure Emo on top of
the `net` package. Direct style throughout: a request reads like any other
function call, and the scheduler parks the process underneath while the
socket is busy. The package declares the `ocaml`, `c`, and `typescript`
targets (`targets = ["ocaml", "c", "typescript"]`); dependency resolution
refuses it on every other target. On `c` it inherits `net`'s TCP-only
coverage; `https` in particular needs TLS, which `c` refuses.

## Using the package

```emo
require "http"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "http"` needs `"http" = "0.1.0"` in
the manifest's `deps` block; the `net` package it builds on comes
through `http`'s own manifest. The package declares the `ocaml`, `c`,
and `typescript` targets.

## Client

The verb helpers cover the common cases; the general form takes every knob
explicitly:

```emo
http.get(url)                                // GET, no body
http.post(url, body)                         // POST with a body
http.put(url, body)                          // PUT with a body
http.delete(url)                             // DELETE, no body
http.request(method, url, headers, body, timeout)
```

`http.request`'s full signature:

```emo
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) (R, HttpResponse)
```

- `headers` is an array of `(name, value)` tuples, appended after the
  built-in `Host`, `Content-Length`, and `Connection: close` lines.
- `timeout` is in seconds and is passed to `net.connect` /
  `net.tls_connect`; `0.0` (what the verb helpers use) waits indefinitely.
- The URL must carry an explicit `http://` or `https://` scheme;
  anything else is the error tuple, as is every transport failure the
  `net` package reports — match the pair, don't assume the response.
  `https://` URLs go through `net.tls_connect` — TLS with
  certificate verification on, per the `net` package's default. Default
  ports are 80 and 443; `host:port` overrides them.

Every success answers `(R.ok, resp)` with an `HttpResponse`:

```emo
class HttpResponse {
  // fields: status Int64, headers Array[(String, String)], body String
  def header(name String) String   // case-insensitive lookup; "" when absent
}
```

```emo
require "http"

case http.get("http://127.0.0.1:8901/hello.txt") {
  (R.error, why) -> { println("request failed: ${why}") }
  (R.ok, resp)   -> {
    println(resp.status)                 // 200
    println(resp.header("content-type")) // text/plain
    println(resp.body)
  }
}
```

Redirects are never followed: a 3xx is a response like any other, and
following it (reading `resp.header("location")` and issuing the next
request) is the caller's explicit, visible move.

Each request opens one connection and closes it after the exchange — the
client always sends `Connection: close`, so there is no pooling to reason
about.

## Server

Two helpers, both built on a `TcpListener` from `net.listen(host, port)`:

- `http.serve(listener) -> (conn TcpConn) { ... }` — the
  process-per-connection helper. Every accepted connection runs its own
  process, and the handler gets the raw connection: reading the request and
  writing the response bytes are the handler's job. The connection is
  closed when the handler returns.
- `http.serve_requests(listener) -> (req HttpRequest) { ... }` — the
  request-level server. Each connection's request is parsed into an
  `HttpRequest`, handed to the handler, and the handler's `HttpResponse` is
  written back; the connection closes after each exchange.

Most handlers want `serve_requests`. The request value:

```emo
class HttpRequest {
  // fields: method String, path String, headers Array[(String, String)], body String
  def header(name String) String   // case-insensitive lookup; "" when absent
}
```

`body` is read according to the request's `Content-Length`; a request
without one gets `""`.

Responses are built with the `http.response` factory:

```emo
def response(status Int64, headers Array[(String, String)], body String) HttpResponse
```

The server writes `Content-Length` from the body and a reason phrase for
the common statuses (200, 201, 204, 400, 404, 500).

A complete server:

```emo
require "http"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8902)
println("listening on http://127.0.0.1:8902")

http.serve_requests(listener) -> (req HttpRequest) {
  println(req.method + " " + req.path)
  return http.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

Both serve helpers loop forever; run one directly as the program's main
work, or under `do` to keep the current process free — which is also how a
client and a server live in one program:

```emo
require "http"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 0)

do http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(201, [], req.method + " " + req.path + " " + req.body)
}

case http.request("POST", "http://127.0.0.1:" + listener.port().to_string() + "/items", [("Content-Type", "text/plain")], "payload", 5.0) {
  (R.error, why) -> { println("request failed: ${why}") }
  (R.ok, resp)   -> {
    println(resp.status) // 201
    println(resp.body)   // POST /items payload
  }
}
```

## Limitations

- **Three targets.** The package declares `targets = ["ocaml", "c", "typescript"]`;
  resolution refuses it for wasm, BEAM, and riscv64 builds. On `c` it is
  TCP-only, inherited from `net`.
- **No connection pooling.** One TCP connection per request, closed after
  the exchange.
- **No redirect following.** 3xx responses are returned as-is.
- **HTTP/1.1, `Content-Length` bodies.** Requests and responses without a
  `Content-Length` header read the body as the connection's remaining bytes
  (client) or as empty (server); chunked transfer encoding is not
  implemented.
- **No header continuation, trailers, or compression** — headers are read
  as flat `Name: value` lines.
