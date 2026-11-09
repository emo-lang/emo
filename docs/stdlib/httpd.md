# The `httpd` Package

The standard library's HTTP server, written in pure Emo on top of the
`net` package: one process per connection, a request arriving as a value
and the handler answering with one. Direct style throughout — the
connection's machinery (keep-alive, bodies, limits, timeouts, graceful
shutdown) is the package's own, not every program's accept loop. The
client half of the wire is the [`http`](stdlib/http.md) package. The
package declares the `ocaml`, `c`, and `typescript` targets
(`targets = ["ocaml", "c", "typescript"]`); dependency resolution
refuses it on every other target. HTTPS rides `net`'s TLS on every one
of them — the listener decides the scheme.

## Using the package

```emo
require "httpd"
```

`require "httpd"` needs `"httpd" = "0.1.0"` in the manifest's `deps`
block; the `net` package it builds on comes through `httpd`'s own
manifest. The package declares the `ocaml`, `c`, and `typescript`
targets.

## Serving

The simplest server is `httpd.serve` with the handler as an attached
block — a `(Request) Response`:

```emo
require "httpd"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8902)

const server = httpd.serve(listener) -> (req httpd.Request) {
  println(req.method + " " + req.path)
  return httpd.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

`serve` answers a `Server` handle at once — the accept loop runs in its
own process; `server.wait()` is what blocks:

```emo
class Server {
  def stop() (R, Server)   // close the listener; live connections finish
  def wait() Server        // join the drain: every in-flight request done
}
```

`server.stop()` closes the listener and lets the live connections run to
their end; `server.wait()` returns once the last one finishes (kept-alive
idle connections end through their idle timeout — a server with no
timeouts set waits on one the same as on a live request). Run `wait()`
directly as the program's main work, or serve and let the program's own
logic carry on — which is how a client and a server live in one program:

```emo
require "httpd"
require "http"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 0)

const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(201, [], req.method + " " + req.path + " " + req.body)
}

case http.request("POST", "http://127.0.0.1:" + listener.port().to_string() + "/items", [("Content-Type", "text/plain")], "payload", 5.0) {
  (R.error, why) -> { println("request failed: ${why}") }
  (R.ok, resp)   -> {
    println(resp.status) // 201
    println(resp.body)   // POST /items payload
  }
}

const (R.ok, _) = server.stop()
server.wait()
```

The same server over TLS — the handler is unchanged; only the listener
and the client's trust store differ:

```emo
const (R.ok, listener) = net.listen_tls("127.0.0.1", 0, "tls-cert.pem", "tls-key.pem")

const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [], "hello over https\n")
}
```

`examples/https_roundtrip` is this program with its certificate pair
checked in.

## The request and the response

Every handler receives one whole `Request`:

```emo
class Request {
  // fields: method String, target String, path String, query Map[String, String],
  //         proto String, headers Array[(String, String)], body String,
  //         params Map[String, String]
  def header(name String) String            // case-insensitive; "" when absent
  def header_all(name String) Array[String] // every value, wire order
}
```

- `path` is the request-target's path as it arrived (raw — the router
  matches raw); `query` maps each key to its first occurrence's decoded
  value (`+` read as a space); `params` is the router's wildcard
  captures (`""` when the request did not come through a router).
- `body` is read by the request's framing: `Content-Length`, or chunked
  transfer encoding decoded in full — `100 Continue` is answered first
  when the peer sends `Expect: 100-continue`.
- Header names arrive canonicalized (`content-type` reads back as
  `Content-Type`); lookups are case-insensitive through the one
  spelling.

The handler answers with a `Response` value — status, headers, and body
visible in one place, and the wire carries `Content-Length` derived from
the body (the handler's own `Content-Length` header stands):

```emo
def response(status Int64, headers Array[(String, String)], body String) Response
def error(status Int64, message String) Response   // plain text body as given
```

A `HEAD` request receives the response's headers and none of its body;
`204` and `304` carry neither body nor a length. Keep-alive is the
default: HTTP/1.1 connections hold across requests until the peer sends
`Connection: close`, and an HTTP/1.0 peer holds only when it asks for
`keep-alive`.

## Routing

`httpd.router()` builds a route table, one registration at a time —
each call answers a new `Router`, so the registrations chain through
local rebinding:

```emo
def build_routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/hello/{name}", greet)        // GET /hello/ada → params["name"] = "ada"
  r = r.post("/users", create_user)        // POST /users
  r = r.put("/users/{id}", update_user)
  r = r.delete("/users/{id}", delete_user)
  r = r.handle("/static/", serve_static)   // every method, the subtree below
  r = r.get("/files/{path...}", files)     // the rest of the path in one capture
  return r
}

const server = httpd.serve_routes(listener, routes)
```

- `handle(pattern, handler)` is the general form — the pattern carries
  its own method (`"GET /users/{id}"`) or none; the method-scoped
  helpers take the bare path.
- `{name}` captures one segment; `{name...}` captures the remainder of
  the path `/`-joined (empty when nothing remains). Captures decode
  under the path's convention — `%XX` yes, `+` stays a plus — and land
  in `req.params`.
- A trailing slash marks a subtree: `/static/` answers `/static/` and
  everything below it.
- The most specific pattern wins: a literal outranks a wildcard, a
  wildcard outranks the rest, and a longer pattern wins past a shared
  prefix. `/users/admin` beats `/users/{id}`.
- A request matching a pattern's shape but not its method answers `405`
  with the methods that would match; a request for `/static` when only
  `/static/` is registered answers `301` to `/static/`; a path carrying
  `//`, `.`, or `..` answers `301` to its cleaned spelling (the query
  string rides along); nothing matching answers `404 page not found`.
- Patterns parse once, at registration. A malformed pattern — a brace
  that does not close, an empty name, a rest that is not last — raises,
  and so does a second registration of one shape with overlapping
  methods.

## Options

`httpd.server_options()` starts at the defaults and every `with_*`
answers a new value — timeouts in seconds, `0.0` leaving an operation
unbounded:

```emo
const options = httpd.server_options()
  .with_read_timeout(5.0)        // per-request read deadline
  .with_idle_timeout(30.0)       // deadline between requests on a kept-alive connection
  .with_max_header_bytes(16384)  // the header block's budget (default 1 MiB) — over answers 431
  .with_max_body_bytes(1048576)  // the body's budget (default unbounded) — over answers 413
  .with_date(-> () { return date_string() })  // the injected clock

const server = httpd.serve_with(listener, handler, options)
```

`with_date` is the one way a response gains a `Date` header: the
language has no clock (the stance `slog` records), so default output is
byte-deterministic, and a caller with a clock stamps every response the
block's string. A handler's own `Date` header stands over the injected
one.

## Strictness on the wire

The peer's malformed bytes are expected data — they come back as a
plain-text 400 (or 431/413 for the budgets) and the connection closes:
a request line that is not three parts, a version that is not
HTTP/1.1 or HTTP/1.0, a header name that is not a token (`Host : h`
refuses the space before the colon), a missing `Host` on HTTP/1.1, a
`Content-Length` that is not a count, `Content-Length` beside
`Transfer-Encoding`, chunk framing that breaks, an escape decoding
outside printable ASCII (named with its byte). A programmer's mistake —
a bad pattern, a conflicting registration — is the raise half of the
split.

## Limitations

- **Three targets.** The package declares `targets = ["ocaml", "c", "typescript"]`;
  resolution refuses it for wasm, BEAM, and riscv64 builds — the same
  coverage `net` declares. On `c`, UDP and Unix-domain sockets stay
  refused (inherited from `net`).
- **Whole-buffered responses.** A handler answers with one `Response`
  value, so the wire always knows the length; streaming responses
  (SSE, large files) are the named follow-up, arriving as a separate
  writer-shaped form.
- **HTTP/1.1 only.** No HTTP/2, no WebSocket, no response chunking, no
  compression, no host-based patterns — each a named follow-up at most.
- **No `Date` unless injected** — see `with_date`; the language has no
  clock primitive.
- **Percent-decoding is printable-ASCII only.** An escape decoding
  outside 0x20–0x7E is refused with the byte named; byte-exact query
  and path values wait on a public Bytes bridge.
