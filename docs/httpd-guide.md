# The Web-Server Guide

Building HTTP servers with the `httpd` package — from a ten-line hello
world to a JSON API with state, middleware, and a graceful shutdown.
The guide is a ladder: every section is a working program, and each one
adds one idea. Every program here ran byte-identically on the
interpreter and the `c` and `typescript` targets before it was written
down; the transcripts are real output.

For the concise reference, see [`docs/stdlib/httpd.md`](stdlib/httpd.md);
for the wire the server rides, [`docs/stdlib/net.md`](stdlib/net.md);
for the client half, [`docs/stdlib/http.md`](stdlib/http.md). The
runnable examples live beside the compiler: `examples/httpd_routes`,
`examples/httpd_serve`, `examples/httpd_wire`, `examples/https_roundtrip`.

## The model

One sentence: **a request arrives as a value, your handler answers
with one, and the connection's machinery is the package's own.**

- The server accepts connections in its own process and runs **one
  process per connection**. Your handler runs inside that connection's
  process — blocking reads inside it park only that connection, and
  every other connection keeps serving. This is why the code below has
  no event loop, no callbacks, and nothing async-shaped: the scheduler
  switches processes underneath while the code reads like blocking
  calls.
- Keep-alive, request bodies (both `Content-Length` and chunked),
  limits, timeouts, and the graceful shutdown are the package's work,
  not yours.
- A handler is any function from `httpd.Request` to
  `httpd.Response` — a plain `def`, a block, or a wrapped chain of
  them. Middleware is composition, because a handler is just a value.
- The error split is the standard library's: the peer's malformed
  bytes come back as plain-text 400-family answers; a programmer's
  mistake (a bad route pattern, a conflicting registration) raises.

## Setup

A program is a directory with a `package.emo` manifest; `emo` never
looks above it. `httpd` needs no dependencies of its own, but the
program that opens its listener with `net.listen` pins `net` beside it:

```emo
package {
  name = "hello"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript"]

  deps {
    "httpd" = "0.1.0"
    "net" = "0.1.0"
  }
}
```

The three targets are the ones `net` itself declares — wasm, BEAM, and
riscv64 builds refuse the package at resolution time. The standard
library ships inside the compiler; the first build writes
`package.lock` beside the manifest, which belongs in version control.

## The smallest server

```emo
require "httpd"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
println("listening on http://127.0.0.1:8080")

const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [("Content-Type", "text/plain; charset=utf-8")], "Hello, world!\n")
}

server.wait()
```

Run it from the project root and knock on it:

```console
$ emo run main.emo        # or: emo build main.emo && ./main
listening on http://127.0.0.1:8080
```

```console
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: 14

Hello, world!
```

Four shapes to notice, because every later section builds on them:

- **`net.listen(host, port)`** answers `(R.ok, listener)` or
  `(R.error, reason)`. Port `0` asks the kernel for a free port (read
  it back with `listener.port()`) — the examples the compiler ships
  use it so their golden output never pins a port number. A port your
  process cannot bind is the error tuple: the plain destructuring
  above turns one into a runtime error ending the program, which is
  the honest answer for a server that cannot start. If you would
  rather print and exit cleanly, match it in a `case`.
- **The trailing block** — `httpd.serve(listener) -> (req) { ... }` —
  is the handler: Emo's one notation for "pass a function last". It
  must touch the call, exactly like the parentheses.
- **`httpd.serve` answers a `Server` handle at once** — the accept
  loop already runs in its own process. `server.wait()` is what
  blocks: it returns only when the drain finishes (see [Stopping a
  server](#stopping-a-server)). A program whose root process ends
  takes the whole program with it, so a server program either parks in
  `wait()` or carries on with its own logic — both are shown below.
- **`httpd.response(status, headers, body)`** is a plain value: status
  as an `Int64`, headers as an array of `(name, value)` tuples in wire
  order, body as a `String`. The wire carries a derived
  `Content-Length` (your own `Content-Length` header would stand), a
  `HEAD` request receives the headers with no body, and `204`/`304`
  carry neither body nor length.

The server speaks HTTP/1.1 with keep-alive by default: curl reused one
connection for all three requests here without either side doing
anything.

## The request, inspected

Every handler receives one whole `Request`. The fields:

| field | what it is |
| --- | --- |
| `method` | `"GET"`, `"POST"`, ... — the request line's own spelling |
| `target` | the request-target as it arrived, path and `?query` |
| `path` | the target's path half, raw — the router matches it raw |
| `query` | `Map[String, String]`: first occurrence wins, `+` reads as a space, `%XX` decoded |
| `proto` | `"HTTP/1.1"` or `"HTTP/1.0"` |
| `headers` | `Array[(String, String)]`, wire order, names canonicalized (`content-type` reads back `Content-Type`) |
| `body` | the whole body, framed by `Content-Length` or chunked — `100 Continue` answered first when the peer waits |
| `params` | the router's wildcard captures (an empty map when the request did not come through a router) |

plus two lookups: `req.header(name)` answers the first value
case-insensitively (`""` when absent), `req.header_all(name)` answers
every value in wire order.

```emo
require "httpd"
require "net"

// The query value under `key`, or `fallback` when the request has none.
def query_or(req httpd.Request, key String, fallback String) String {
  if req.query.has(key) {
    return req.query.get(key)
  }
  return fallback
}

def inspect(req httpd.Request) httpd.Response {
  var out = "method: " + req.method + "\n"
  out = out + "target: " + req.target + "\n"
  out = out + "path:   " + req.path + "\n"
  out = out + "proto:  " + req.proto + "\n"
  out = out + "name:   " + query_or(req, "name", "(none)") + "\n"
  out = out + "agent:  " + req.header("user-agent") + "\n"
  out = out + "tags:   " + req.header_all("x-tag").length().to_string() + "\n"
  out = out + "body:   " + req.body + "\n"
  for var i = 0; i < req.headers.length(); i = i + 1 {
    const pair = req.headers[i]
    out = out + "header: " + pair[0] + " = " + pair[1] + "\n"
  }
  return httpd.response(200, [("Content-Type", "text/plain; charset=utf-8")], out)
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener, inspect)
server.wait()
```

A handler given a name (`inspect`, not a trailing block) reads the
same at the call site — `httpd.serve(listener, inspect)` — and can be
unit-tested without a socket.

```console
$ curl -s "http://127.0.0.1:8080/greet?name=Ada+Lovelace" -H "X-Tag: a" -H "X-Tag: b" -d "hi there"
method: POST
target: /greet?name=Ada+Lovelace
path:   /greet
proto:  HTTP/1.1
name:   Ada Lovelace
agent:  curl/8.7.1
tags:   2
body:   hi there
header: Host = 127.0.0.1:8080
header: User-Agent = curl/8.7.1
header: Accept = */*
header: X-Tag = a
header: X-Tag = b
header: Content-Length = 8
header: Content-Type = application/x-www-form-urlencoded
```

The query discipline is printable-ASCII-only, on purpose: an escape
decoding outside `0x20–0x7E` is refused with the byte named, so text
that would silently mojibake never lands in a handler —

```console
$ curl -s -i "http://127.0.0.1:8080/greet?name=%E4%B8%AD"
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
Content-Length: 85
Connection: close

httpd: bad request: the escape at byte 0 decodes to byte 228, outside printable ASCII
```

Byte-exact query values wait on the standard library's named
follow-up, a public `Bytes` bridge.

## Answers: status, headers, bodies

`httpd.response(status, headers, body)` puts all three in one place;
`httpd.error(status, message)` is the plain-text shortcut — the
message as it stands is the body, the content type set at write time.

```emo
require "httpd"
require "net"

const home_page = "<!doctype html>\n<title>Emo</title>\n<h1>Hello from Emo</h1>\n"

def site(req httpd.Request) httpd.Response {
  if req.path == "/" {
    return httpd.response(200, [("Content-Type", "text/html; charset=utf-8")], home_page)
  }
  if req.path == "/old-home" {
    return httpd.response(301, [("Location", "/")], "")
  }
  if req.path == "/health" {
    return httpd.response(204, [], "")
  }
  if req.path == "/login" {
    return httpd.response(200, [("Set-Cookie", "session=abc123; HttpOnly; Path=/"), ("Set-Cookie", "theme=dark; Path=/")], "signed in\n")
  }
  return httpd.error(404, "nothing at " + req.path + "\n")
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener, site)
server.wait()
```

```console
$ curl -i http://127.0.0.1:8080/old-home
HTTP/1.1 301 Moved Permanently
Location: /
Content-Length: 0

$ curl -i http://127.0.0.1:8080/health
HTTP/1.1 204 No Content

$ curl -i http://127.0.0.1:8080/login
HTTP/1.1 200 OK
Set-Cookie: session=abc123; HttpOnly; Path=/
Set-Cookie: theme=dark; Path=/
Content-Length: 10

signed in

$ curl -i http://127.0.0.1:8080/nope
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
Content-Length: 17

nothing at /nope
```

Repeated headers are repeated headers — give the array two
`Set-Cookie` tuples and the wire carries two lines. The server owns
`Connection`, `Content-Length` (unless you set it), and, when a clock
is injected, `Date`; a handler's entries with those names stand or
fall as the reference describes.

This `if`-chain routing is honest and fine for a handful of paths —
the next section is what to reach for when the paths grow.

## Routing

`httpd.router()` builds a route table one registration at a time, and
`httpd.serve_routes` puts the table in the handler's seat. Each
registration answers a new `Router` — the table is an immutable value
— and a line cannot begin with `.`, so the builders chain through
local rebinding inside a def:

```emo
require "httpd"
require "net"

def home(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "home\n")
}

def list_users(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "all users\n")
}

def create_user(req httpd.Request) httpd.Response {
  return httpd.response(201, [("Location", "/users/7")], "created\n")
}

def me(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "the signed-in user\n")
}

def show_user(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "user " + req.params.get("id") + "\n")
}

def docs_page(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "docs [" + req.params.get("page") + "]\n")
}

def assets(req httpd.Request) httpd.Response {
  return httpd.response(200, [], req.method + " " + req.path + "\n")
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", home)
  r = r.get("/users", list_users)
  r = r.post("/users", create_user)
  r = r.get("/users/me", me)
  r = r.get("/users/{id}", show_user)
  r = r.get("/docs/{page...}", docs_page)
  r = r.handle("/assets/", assets)
  return r
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes(listener, routes())
server.wait()
```

The pattern forms:

- `r.get(path, handler)` / `post` / `put` / `delete` — the
  method-scoped helpers, bare path.
- `r.handle(pattern, handler)` — the general form: the pattern carries
  its own method (`"GET /users/{id}"`) or none, answering every
  method.
- `{name}` captures one segment into `req.params`; `{name...}`
  captures the rest of the path `/`-joined (empty when nothing
  remains). Captures decode per segment under the path's convention —
  `%XX` yes, `+` stays a plus — so an encoded slash stays one capture
  inside a single segment.
- A trailing slash marks a subtree: `/assets/` answers `/assets/` and
  everything below. `/` alone is the exact root — `home` above answers
  the bare `/` and nothing else.

The dispatch, walked live against the table above:

```console
$ curl http://127.0.0.1:8080/
HTTP/1.1 200 OK

home
$ curl -X POST http://127.0.0.1:8080/users
HTTP/1.1 201 Created
Location: /users/7

created
$ curl http://127.0.0.1:8080/users/me
HTTP/1.1 200 OK

the signed-in user
$ curl http://127.0.0.1:8080/users/42
HTTP/1.1 200 OK

user 42
$ curl http://127.0.0.1:8080/docs/guide/routing
HTTP/1.1 200 OK

docs [guide/routing]
$ curl http://127.0.0.1:8080/docs
HTTP/1.1 200 OK

docs []
```

The shapes the router answers for you, each one a class of mistakes
the table refuses to let through:

```console
$ curl -X DELETE http://127.0.0.1:8080/users
HTTP/1.1 405 Method Not Allowed
Allow: GET, POST

$ curl -i http://127.0.0.1:8080/assets
HTTP/1.1 301 Moved Permanently
Location: /assets/

$ curl "http://127.0.0.1:8080/users//42?tab=posts"
HTTP/1.1 301 Moved Permanently
Location: /users/42?tab=posts

$ curl http://127.0.0.1:8080/users/42/
HTTP/1.1 404 Not Found

404 page not found
```

- **405 carries `Allow`** — the methods that would have matched the
  path, deduped.
- **The slash redirect** — `/assets` 301s to the registered
  `/assets/`; the query string rides along.
- **The cleanup redirect** — a path carrying `//`, `.`, or `..`
  answers 301 to its cleaned spelling (`..` climbs, stopping at the
  root). Your handlers never see an unclean path.
- **An exact pattern's trailing slash is part of the address** —
  `/users/42/` is not `/users/42` and answers 404.
- **The most specific pattern wins**: a literal outranks a wildcard, a
  wildcard outranks a rest, and past a shared prefix the longer
  pattern wins — which is why `/users/me` answers `me` and
  `/users/42` answers `show_user`. `GET` patterns answer `HEAD` too;
  the body stripping is the response writer's half.
- A malformed pattern or a conflicting registration (same shape,
  overlapping methods — `/users/{id}` against `/users/{name}`) raises
  at registration, before the server ever accepts a request.

One caution worth its own paragraph, because no router can lift it
for you: **the cleanup is textual, not semantic**. `/users/../admin`
arrives at the dispatcher as a 301 to `/admin` — but
`/users/%2e%2e/admin` arrives **decoded** as the capture `"../admin"`
and hands it to your handler as data. The router matches raw paths and
decodes captures honestly; it does not know that your capture will
later be used as a file name. Any handler that turns a capture into a
file-system path must refuse `..` segments itself — see [Serving
files](#serving-files) for the guard.

## Middleware

A handler is a value from `Request` to `Response`, so a middleware is
a function that takes one and answers a new one. No framework word
exists in the package — composition is the whole mechanism:

```emo
require "httpd"
require "net"

// ---- middleware: each takes a handler and answers a handler ----

def logged(next Block) Block {
  return -> (req httpd.Request) {
    const resp = next(req)
    println(req.method + " " + req.target + " " + resp.status.to_string())
    return resp
  }
}

def secure_headers(next Block) Block {
  return -> (req httpd.Request) {
    const resp = next(req)
    const headers = resp.headers.append(("X-Content-Type-Options", "nosniff")).append(("X-Frame-Options", "DENY"))
    return httpd.response(resp.status, headers, resp.body)
  }
}

def require_token(token String, next Block) Block {
  return -> (req httpd.Request) {
    if req.header("Authorization") != "Bearer " + token {
      return httpd.response(401, [("WWW-Authenticate", "Bearer")], "unauthorized\n")
    }
    return next(req)
  }
}

// ---- the app ----

def home(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "welcome\n")
}

def stats(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "42 requests served\n")
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", home)
  r = r.get("/admin/stats", require_token("s3cret", stats))
  return r
}

// The router as a plain handler, so middleware can wrap the whole table.
def app() Block {
  const table = routes()
  const dispatch = -> (req httpd.Request) {
    return httpd.router_dispatch(table, req)
  }
  return logged(secure_headers(dispatch))
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener, app())
server.wait()
```

`httpd.router_dispatch(table, req)` is the call `serve_routes` makes
inside — exposed so a program that wants middleware *around the whole
table* (logging every request, security headers on every answer) can
wrap it, while `require_token` stays per-route because it reads the
matched route's world.

```console
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Length: 8

welcome
$ curl -i http://127.0.0.1:8080/admin/stats
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Length: 13

unauthorized
$ curl -i -H "Authorization: Bearer s3cret" http://127.0.0.1:8080/admin/stats
HTTP/1.1 200 OK
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Length: 19

42 requests served
```

with the log line each request earned on the server's stdout:

```text
GET / 200
GET /admin/stats 401
GET /admin/stats 200
GET /missing 404
```

Two language notes this section leans on:

- A `Block`-typed value held in a class field or a `const` **calls
  after it is bound to a local**: `next(req)` here works because
  `next` is the def's parameter. `self.handler(req)` on a field is a
  `NoMethodError`; `const f = self.handler; f(req)` is the spelling.
- The parameters a wrapped block declares are checked like any other —
  `-> (req httpd.Request) { ... }` answering an `httpd.Response`
  satisfies the handler seat wherever a handler is expected.

## State: the counter, owned by a process

Handlers are functions; where does state live? The Emo answer is the
concurrency answer: **a process owns it, and handlers talk to it**.
`do call()` starts a process and answers its pid; `pid <- msg` sends;
`receive { ... }` takes one message matching a branch. A counter is
the smallest stateful service there is:

```emo
require "httpd"
require "net"

// The counter process owns the number. It handles one message at a
// time, in arrival order, so two requests can never race on it.
def counter(n Int64) Int64 {
  receive {
    ("next", from) then {
      from <- ("count", n + 1)
      return counter(n + 1)
    }
  }
}

// Runs in the connection's process: ask, then wait for the answer.
def next_visit(visits Pid) Int64 {
  visits <- ("next", self_pid())
  receive {
    ("count", n) then { return n }
  }
}

const visits = do counter(0)

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [], "you are visitor #" + next_visit(visits).to_string() + "\n")
}
server.wait()
```

Twenty parallel requests, then one more — every visitor gets a
distinct number, in arrival order, with no lock anywhere in sight:

```console
$ for i in $(seq 1 20); do curl -s http://127.0.0.1:8080/ & done | sort -t'#' -k2 -n | tr '\n' ' '
you are visitor #7 you are visitor #8 ... you are visitor #26
$ curl -s http://127.0.0.1:8080/
you are visitor #27
```

The discipline that makes this safe is the same one `httpd` itself
uses for its drain counter: **one process owns the mutable state, and
every other process asks it**. Messages arrive as snapshot copies
(mutation never crosses a process boundary), and the owner handles one
message at a time — so "check then act" inside the owner is atomic by
construction, not by discipline.

Two `receive` facts the handler above relies on:

- Branches may bind: `("count", n) -> ...` takes the tuple apart in
  the pattern. Non-matching messages stay queued — a mailbox is
  selective.
- A `receive` whose branch returns a value **returns it from the
  enclosing def** (`next_visit` is an `Int64` function); the value
  rides the same channel an ordinary `return` uses.

## A JSON API: state, parsing, and tests together

The sections so far assemble into this: a notes API with a
process-owned store, JSON bodies in and out, ids in paths, and tests
that never open a socket. Two files — `app.emo` holds everything a
test wants; `main.emo` is the five-line shell that serves it.

```emo
// app.emo
require "httpd"
require "json"

// ---- the store: one process owns every note ----

// Every request gets exactly one reply, tagged "notes" so it never
// mixes with other traffic in the asking process's mailbox. An answer
// that can fail travels as the usual (R.ok, value) / (R.error, reason).
def notes_store(notes Map[Int64, String], next_id Int64) Int64 {
  receive {
    ("notes", "add", text, from) then {
      notes.set(next_id, text)
      from <- ("notes", "added", next_id)
      return notes_store(notes, next_id + 1)
    }
    ("notes", "get", id, from) then {
      if notes.has(id) {
        from <- ("notes", "got", (R.ok, notes.get(id)))
      } else {
        from <- ("notes", "got", (R.error, "no note " + id.to_string()))
      }
      return notes_store(notes, next_id)
    }
    ("notes", "delete", id, from) then {
      if notes.has(id) {
        notes.remove(id)
        from <- ("notes", "deleted", (R.ok, id))
      } else {
        from <- ("notes", "deleted", (R.error, "no note " + id.to_string()))
      }
      return notes_store(notes, next_id)
    }
    ("notes", "list", from) then {
      from <- ("notes", "all", notes)
      return notes_store(notes, next_id)
    }
  }
}

def add_note(store Pid, text String) Int64 {
  store <- ("notes", "add", text, self_pid())
  receive {
    ("notes", "added", id) then { return id }
  }
}

def find_note(store Pid, id Int64) (R, String) {
  store <- ("notes", "get", id, self_pid())
  receive {
    ("notes", "got", answer) then { return answer }
  }
}

def delete_note(store Pid, id Int64) (R, Int64) {
  store <- ("notes", "delete", id, self_pid())
  receive {
    ("notes", "deleted", answer) then { return answer }
  }
}

def all_notes(store Pid) Map[Int64, String] {
  store <- ("notes", "list", self_pid())
  receive {
    ("notes", "all", notes) then { return notes }
  }
}

// ---- JSON in and out ----

def note_json(id Int64, text String) json.Json {
  return json.object([("id", json.int64(id)), ("text", json.string(text))])
}

def json_response(status Int64, doc json.Json) httpd.Response {
  return httpd.response(status, [("Content-Type", "application/json")], json.encode(doc) + "\n")
}

def json_error(status Int64, message String) httpd.Response {
  return json_response(status, json.object([("error", json.string(message))]))
}

def has_key(entries Array[(String, json.Json)], key String) Bool {
  for var i = 0; i < entries.length(); i = i + 1 {
    if entries[i][0] == key {
      return true
    }
  }
  return false
}

// The body's `text` field, or the reason the body is not a note.
def text_field(body String) (R, String) {
  case json.decode(body) {
    (R.error, why) then { return (R.error, why) }
    (R.ok, doc) then {
      if doc.is(json.JsonObject) {
        if !has_key(doc.entries(), "text") {
          return (R.error, "the object needs a \"text\" field")
        }
        const text = doc.get("text")
        if text.kind() != json.JsonKind.jstring {
          return (R.error, "\"text\" must be a string")
        }
        return (R.ok, text.as_string())
      }
      return (R.error, "the body must be a JSON object")
    }
  }
}

// A note id from the path: digits only, at most 18 of them.
def parse_id(s String) (R, Int64) {
  if s == "" || s.length() > 18 {
    return (R.error, "not an id")
  }
  for var i = 0; i < s.length(); i = i + 1 {
    if "0123456789".index_of(s.substring(i, 1)) < 0 {
      return (R.error, "not an id")
    }
  }
  return (R.ok, s.to_int64())
}

// ---- handlers ----

def list_notes(store Pid, req httpd.Request) httpd.Response {
  const notes = all_notes(store)
  const ids = notes.keys()
  var items = []
  for var i = 0; i < ids.length(); i = i + 1 {
    items = items.append(note_json(ids[i], notes.get(ids[i])))
  }
  return json_response(200, json.array(items))
}

def create_note(store Pid, req httpd.Request) httpd.Response {
  case text_field(req.body) {
    (R.error, why) then { return json_error(400, why) }
    (R.ok, text) then {
      const id = add_note(store, text)
      const headers = [("Content-Type", "application/json"), ("Location", "/notes/" + id.to_string())]
      return httpd.response(201, headers, json.encode(note_json(id, text)) + "\n")
    }
  }
}

def show_note(store Pid, req httpd.Request) httpd.Response {
  case parse_id(req.params.get("id")) {
    (R.error, _) then { return json_error(404, "no such note") }
    (R.ok, id) then {
      case find_note(store, id) {
        (R.error, why) then { return json_error(404, why) }
        (R.ok, text) then { return json_response(200, note_json(id, text)) }
      }
    }
  }
}

def remove_note(store Pid, req httpd.Request) httpd.Response {
  case parse_id(req.params.get("id")) {
    (R.error, _) then { return json_error(404, "no such note") }
    (R.ok, id) then {
      case delete_note(store, id) {
        (R.error, why) then { return json_error(404, why) }
        (R.ok, _) then { return httpd.response(204, [], "") }
      }
    }
  }
}

// ---- the table ----

def routes(store Pid) httpd.Router {
  var r = httpd.router()
  r = r.get("/notes", -> (req httpd.Request) { return list_notes(store, req) })
  r = r.post("/notes", -> (req httpd.Request) { return create_note(store, req) })
  r = r.get("/notes/{id}", -> (req httpd.Request) { return show_note(store, req) })
  r = r.delete("/notes/{id}", -> (req httpd.Request) { return remove_note(store, req) })
  return r
}

def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(10.0)
  o = o.with_idle_timeout(30.0)
  o = o.with_max_body_bytes(65536)
  return o
}
```

```emo
// main.emo
require "httpd"
require "net"

const store = do app.notes_store(Map.new(), 1)

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes_with(listener, app.routes(store), app.options())
println("notes API on http://127.0.0.1:8080")
server.wait()
```

The walk — happy paths, then every refusal the handlers were written
to answer:

```console
$ curl -i -X POST -d '{"text":"buy milk"}' http://127.0.0.1:8080/notes
HTTP/1.1 201 Created
Content-Type: application/json
Location: /notes/1
Content-Length: 27

{"id":1,"text":"buy milk"}
$ curl -X POST -d '{"text":"call Ada"}' http://127.0.0.1:8080/notes
{"id":2,"text":"call Ada"}
$ curl http://127.0.0.1:8080/notes
[{"id":1,"text":"buy milk"},{"id":2,"text":"call Ada"}]
$ curl http://127.0.0.1:8080/notes/2
{"id":2,"text":"call Ada"}
$ curl -i http://127.0.0.1:8080/notes/9
HTTP/1.1 404 Not Found
Content-Type: application/json
Content-Length: 22

{"error":"no note 9"}
$ curl -i http://127.0.0.1:8080/notes/abc
HTTP/1.1 404 Not Found
Content-Type: application/json
Content-Length: 25

{"error":"no such note"}
$ curl -i -X POST -d '{"text": 5}' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"\"text\" must be a string"}
$ curl -i -X POST -d '{oops' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"json: expected object key at byte 1"}
$ curl -i -X POST -d '[1,2]' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"the body must be a JSON object"}
$ curl -i -X POST -d '{"title":"x"}' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"the object needs a \"text\" field"}
$ curl -i -X DELETE http://127.0.0.1:8080/notes/1
HTTP/1.1 204 No Content
$ curl -i -X DELETE http://127.0.0.1:8080/notes/1
HTTP/1.1 404 Not Found
{"error":"no note 1"}
$ curl http://127.0.0.1:8080/notes
[{"id":2,"text":"call Ada"}]
```

The patterns this program adds to the shelf:

- **Errors travel as the values they are.** The store's replies carry
  `(R.ok, ...)` / `(R.error, ...)` inside the message, and the
  caller's `receive` hands the tuple straight to its own `case` — one
  convention from store to socket.
- **`json.decode` is the boundary; after it, accessors raise.** A
  malformed body is expected data (the error tuple, answered 400); a
  body that decodes but is not shaped like a note is the handler's
  `case` to answer; a wrong-kind accessor after a checked `kind()`
  would be a bug and raises. `doc.is(json.JsonObject)` narrows so
  `entries()` and `get` are honest calls.
- **Route registration closes over the store's pid**, so every
  handler asks the same owner; `routes(store)` builds a fresh table
  per store, which is exactly what a test wants.
- **`serve_routes_with`** is the options-taking form — timeouts and
  the body budget from [Tuning](#tuning-limits-and-timeouts) below.

### Testing it

`emo test` discovers every `def test_*` under `test/`. The unit tests
drive the router with a request built the way the server builds one —
`httpd.parse_head` is the pure parser the connection loop feeds — and
the last test rides the wire end to end:

```emo
// test/app_test.emo
require "http"
require "httpd"
require "net"

// A request exactly as the server would build it from these bytes.
def request(method String, target String, body String) httpd.Request {
  const (R.ok, req) = httpd.parse_head(method + " " + target + " HTTP/1.1\r\nHost: test\r\n\r\n")
  return req.with_body(body)
}

// Each test gets a fresh store, so no test sees another's notes.
def fresh_routes() httpd.Router {
  return app.routes(do app.notes_store(Map.new(), 1))
}

def test_create_then_show() {
  const routes = fresh_routes()
  const created = httpd.router_dispatch(routes, request("POST", "/notes", "{\"text\":\"buy milk\"}"))
  expect_equal(201, created.status)
  const shown = httpd.router_dispatch(routes, request("GET", "/notes/1", ""))
  expect_equal(200, shown.status)
  expect_equal("{\"id\":1,\"text\":\"buy milk\"}\n", shown.body)
}

def test_bad_json_is_400() {
  const resp = httpd.router_dispatch(fresh_routes(), request("POST", "/notes", "{oops"))
  expect_equal(400, resp.status)
}

def test_unknown_id_is_404() {
  const resp = httpd.router_dispatch(fresh_routes(), request("GET", "/notes/99", ""))
  expect_equal(404, resp.status)
}

def test_over_the_wire() {
  const (R.ok, listener) = net.listen("127.0.0.1", 0)
  const server = httpd.serve_routes(listener, fresh_routes())
  const base = "http://127.0.0.1:" + listener.port().to_string()
  const (R.ok, resp) = http.post(base + "/notes", "{\"text\":\"over the wire\"}")
  expect_equal(201, resp.status)
  expect_equal("/notes/1", resp.header("Location"))
  const (R.ok, _) = server.stop()
  server.wait()
}
```

```console
$ emo test
ok test.app_test.test_bad_json_is_400
ok test.app_test.test_create_then_show
ok test.app_test.test_over_the_wire
ok test.app_test.test_unknown_id_is_404
4 tests, 4 passed
```

Port `0` in the wire test is the whole trick: the kernel hands the
test a free port, `listener.port()` reads it back, and no test ever
races another for a fixed one.

## Forms and HTML

Browsers POST forms as
`application/x-www-form-urlencoded` — the same spelling a query
string uses, so `httpd.parse_query(text)` (the package's pure query
parser, the one `parse_head` itself calls) reads a body as fields.
Text that will ride back inside HTML is escaped first:

```emo
require "httpd"
require "net"

const form_page = "<!doctype html>\n<form method=\"post\" action=\"/hello\">\n  <input name=\"name\">\n  <button>Greet me</button>\n</form>\n"

// Text from a user is escaped before it goes into HTML.
def html_escape(s String) String {
  var out = ""
  for var i = 0; i < s.length(); i = i + 1 {
    const ch = s.substring(i, 1)
    if ch == "&" {
      out = out + "&amp;"
      continue
    }
    if ch == "<" {
      out = out + "&lt;"
      continue
    }
    if ch == ">" {
      out = out + "&gt;"
      continue
    }
    if ch == "\"" {
      out = out + "&quot;"
      continue
    }
    if ch == "'" {
      out = out + "&#39;"
      continue
    }
    out = out + ch
  }
  return out
}

def show_form(req httpd.Request) httpd.Response {
  return httpd.response(200, [("Content-Type", "text/html; charset=utf-8")], form_page)
}

def greet(req httpd.Request) httpd.Response {
  case httpd.parse_query(req.body) {
    (R.error, why) then { return httpd.error(400, why + "\n") }
    (R.ok, fields) then {
      if !fields.has("name") || fields.get("name") == "" {
        return httpd.error(400, "the form needs a name\n")
      }
      const page = "<!doctype html>\n<p>Hello, " + html_escape(fields.get("name")) + "!</p>\n"
      return httpd.response(200, [("Content-Type", "text/html; charset=utf-8")], page)
    }
  }
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", show_form)
  r = r.post("/hello", greet)
  return r
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes(listener, routes())
server.wait()
```

```console
$ curl -d "name=Ada+%3Cscript%3E" http://127.0.0.1:8080/hello
<!doctype html>
<p>Hello, Ada &lt;script&gt;!</p>
$ curl -i -d "nick=x" http://127.0.0.1:8080/hello
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
Content-Length: 22

the form needs a name
```

`Ada +<script>` arrives, decodes, gets escaped, and rides back inert —
the escape happens at the one place user text meets markup, which is
the only place it can be trusted to happen every time. (For whole
server-rendered pages there is the `emo/ui_ssr` pairing —
`examples/ssr_page` — where the tree is built from components and the
escaping is the renderer's.)

## Serving files

The rest wildcard plus `file.read` is a static handler — with the one
guard the router cannot make for you: **a capture is data, and before
it becomes a path it must be refused segments that climb**. Decoded
`..` inside a capture (`/static/%2e%2e/secret.txt`) is text your
handler receives; refusing dot-prefixed segments turns the whole
family away, `.` and `..` and hidden files with them:

```emo
require "file"
require "httpd"
require "net"

def ends_with(s String, suffix String) Bool {
  if s.length() < suffix.length() {
    return false
  }
  return s.substring(s.length() - suffix.length(), suffix.length()) == suffix
}

def content_type(path String) String {
  if ends_with(path, ".html") {
    return "text/html; charset=utf-8"
  }
  if ends_with(path, ".css") {
    return "text/css; charset=utf-8"
  }
  if ends_with(path, ".js") {
    return "text/javascript; charset=utf-8"
  }
  if ends_with(path, ".png") {
    return "image/png"
  }
  return "application/octet-stream"
}

// Only plain segments reach the file system: no empty segment, and none
// that starts with a dot — that refuses `.`, `..`, and hidden files.
def safe_relative(path String) Bool {
  if path == "" {
    return false
  }
  const segments = path.split("/")
  for var i = 0; i < segments.length(); i = i + 1 {
    if segments[i] == "" || segments[i].starts_with(".") {
      return false
    }
  }
  return true
}

def static_file(req httpd.Request) httpd.Response {
  const rel = req.params.get("path")
  if !safe_relative(rel) {
    return httpd.error(404, "404 page not found\n")
  }
  case file.read("public/" + rel) {
    (R.error, _) then { return httpd.error(404, "404 page not found\n") }
    (R.ok, data) then { return httpd.response(200, [("Content-Type", content_type(rel))], data) }
  }
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/static/{path...}", static_file)
  return r
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes(listener, routes())
server.wait()
```

With `public/index.html`, `public/css/site.css`, `public/logo.png`,
`public/.hidden`, and `secret.txt` beside the project root:

```console
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/css/site.css | head -5
HTTP/1.1 200 OK
Content-Type: text/css; charset=utf-8
Content-Length: 20

h1 { color: teal; }
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/%2e%2e/secret.txt | head -1
HTTP/1.1 404 Not Found
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/..%2fsecret.txt | head -1
HTTP/1.1 404 Not Found
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/.hidden | head -1
HTTP/1.1 404 Not Found
```

The PNG rides through as bytes (`curl -o` compared it byte-identical
against the original). Two limits to name honestly, both the package's
documented shape: `file` reads the whole file in one call, so this
handler is for assets, not for videos — a streaming response writer is
the named follow-up; and `file` declares `["ocaml", "c", "wasm"]`, so
a project with this handler pins `targets` that intersect it (the
`typescript` target refuses the `file` package at resolution).

## Tuning: limits and timeouts

`httpd.server_options()` starts at the defaults; every `with_*`
answers a new value. Defaults: no timeouts (`0.0` — unbounded), a
1 MiB header budget, an unbounded body.

```emo
require "httpd"
require "net"

def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(2.0)
  o = o.with_idle_timeout(5.0)
  o = o.with_max_header_bytes(256)
  o = o.with_max_body_bytes(16)
  return o
}

def echo(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "got " + req.body.length().to_string() + " bytes\n")
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_with(listener, echo, options())
server.wait()
```

The four knobs, each walked against this server:

```console
$ curl -d "small" http://127.0.0.1:8080/
got 5 bytes
$ curl -i -d "this body is longer than sixteen bytes" http://127.0.0.1:8080/ | head -1
HTTP/1.1 413 Content Too Large
$ curl -i -H "X-Big: <300 bytes>" http://127.0.0.1:8080/ | head -1
HTTP/1.1 431 Request Header Fields Too Large
```

- **`with_read_timeout(s)`** bounds each read the connection performs
  — one request's head and body. A client that sends half a head and
  stalls gets its connection closed (after 2.0s here, with 0 bytes of
  answer — the read never finished).
- **`with_idle_timeout(s)`** bounds the *gap* between requests on a
  kept-alive connection. The budget is per operation: a client that
  dribbles one header line every 1.5s finishes under a 2.0s read
  timeout — the answer arrives after 6.0s of dribbling, not refused at
  some total deadline. An idle kept-alive connection is closed by its
  idle timeout (after 5.0s here).
- **`with_max_header_bytes(n)`** — over the budget is 431, and the
  connection closes.
- **`with_max_body_bytes(n)`** — over the budget is 413, before a byte
  of the body is read past the limit. Chunked bodies are counted as
  they arrive, so a chunked client cannot promise small and deliver
  large.

Timeouts are seconds (`Float64`); `0.0` leaves an operation unbounded.
A server with no timeouts set still works — an idle kept-alive
connection just never ends on its own, which [stopping a
server](#stopping-a-server) turns into.

## Stopping a server

`server.stop()` closes the listener; `server.wait()` returns when the
last live connection finishes. The graceful shape: a route that mails
the main process, the main process parks in `receive`, and the
program ends only when the drain says so.

```emo
require "httpd"
require "net"

def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(10.0)
  o = o.with_idle_timeout(5.0)
  return o
}

// Tell the main process to stop the server.
def request_shutdown(main_pid Pid) {
  main_pid <- "shutdown"
}

// The app is built with the main process's pid, so the shutdown route
// can reach it.
def app(main_pid Pid) Block {
  return -> (req httpd.Request) {
    if req.method == "POST" && req.path == "/admin/shutdown" {
      request_shutdown(main_pid)
      return httpd.response(202, [], "shutting down\n")
    }
    return httpd.response(200, [], "hello\n")
  }
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_with(listener, app(self_pid()), options())
println("listening on http://127.0.0.1:8080")

receive {
  "shutdown" then { println("shutdown requested, draining") }
}
const (R.ok, _) = server.stop()
server.wait()
println("drained, bye")
```

```console
$ curl -i -X POST http://127.0.0.1:8080/admin/shutdown
HTTP/1.1 202 Accepted
Content-Length: 14

shutting down
```

and the program's own output, ~0.05s after the request:

```text
listening on http://127.0.0.1:8080
shutdown requested, draining
drained, bye
```

The `send` from inside the handler goes to a def-typed parameter, so
every target compiles it. What `wait()` waits *for* is one `done` per
connection: in-flight requests run to their answers, and an idle
kept-alive connection ends through its idle timeout — with
`with_idle_timeout(5.0)` above, a server with one idle browser tab
drains in 5s after the stop; with no timeouts set it would wait on
that tab forever, which is why a server meant to be stopped sets an
idle timeout.

## HTTPS

The handler never changes — TLS is the listener's property. Generate a
certificate pair, hand the PEM files to `net.listen_tls`, and the same
`httpd.serve` serves `https://`:

```console
$ openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
    -days 365 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

```emo
require "httpd"
require "net"

const (R.ok, listener) = net.listen_tls("127.0.0.1", 8443, "cert.pem", "key.pem")
const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [("Content-Type", "text/plain; charset=utf-8")], "hello over https\n")
}
server.wait()
```

```console
$ curl --cacert cert.pem https://localhost:8443/
hello over https
```

Real deployments borrow two things instead of a self-signed pair: a
certificate from a public CA (curl then needs no `--cacert`), and
`net.listen_tls_with` with `net.tls_server_options()` when clients
must present certificates — mutual TLS is the listener's policy, not
the server's. A client that fails the handshake — an untrusted
certificate, a plain-HTTP request on the TLS port — is dropped at the
door and the next connection is served as if nothing happened;
`examples/https_roundtrip` pins exactly that walk. On the `c` target,
linking TLS is the machine's OpenSSL: if the linker cannot find it,
`emo doctor` says so and the fix is `--cclib=-L<dir>` pointing at the
Homebrew or system OpenSSL library directory (headers are never
needed).

## The wire's strictness, seen from a handler

Everything in this guide assumed well-formed requests, and the server
answered malformed ones before your handler ever ran. The refusal
family, in one place:

| peer behavior | answer |
| --- | --- |
| a request line that is not `method SP target SP version` | 400, the line quoted |
| a version that is neither HTTP/1.1 nor HTTP/1.0 | 400 |
| a header name that is not a token (`Host : h` — the space rides the name) | 400 |
| an HTTP/1.1 request with no `Host` | 400 |
| a `Content-Length` that is not a count, or beside `Transfer-Encoding` | 400 |
| chunk framing that breaks (a non-hex size, a chunk without its CRLF) | 400 |
| an escape decoding outside printable ASCII, query or capture | 400, the byte named |
| the header block over `with_max_header_bytes` | 431 |
| the body over `with_max_body_bytes` | 413 |

Every one closes the connection after answering — a request the server
refused is not one it keeps talking on. `examples/httpd_wire` walks
this table on raw sockets, byte-identically on all three targets. Your
handler's own contract is the mirror: raise for broken assertions
about your own program, answer 4xx for broken assertions about the
request, and never raise for data — a raise ends the connection's
process mid-conversation, with no answer on the wire at all.

## Deployment notes

- **Bind `127.0.0.1` behind a proxy, or `0.0.0.0` in the open.** The
  listener takes any host spelling `net` does. A reverse proxy in
  front (nginx, caddy) buys you the production TLS pair, the public
  port, and log capture; the app then serves plain HTTP on loopback
  and needs no certificate plumbing at all.
- **Whole-buffered responses.** A handler answers one `Response`
  value and the wire knows the length — great for APIs and pages,
  wrong for streaming (SSE, large media), which waits on the named
  response-writer form. An in-memory file, likewise: `file.read` gives
  the whole asset to one `String`.
- **No `Date` by default.** The package stays clock-free and the wire
  byte-deterministic unless you inject one through
  `options().with_date(-> () { return date_string() })` — the block's
  string stamps every response that did not set its own
  (`time.now().format_http()` is the reading). Caches treat a missing
  `Date` as unknown age, which is fine behind a proxy that adds its
  own.
- **Logging is `println`** or the `slog` package's structured records
  — a middleware like `logged` above is the natural place, one line
  per request, and it runs in the connection's process so it never
  blocks another connection.
- **Signals are not wired.** There is no `SIGTERM` handler to install;
  stop the server the way [Stopping a server](#stopping-a-server)
  shows — a supervisor's stop becomes that route (or the process ends
  and the kernel closes the sockets, which is the abrupt but honest
  fallback).
- **One process per connection** also bounds you: thousands of
  concurrently parked connections are thousands of scheduler
  processes. It is the same accounting a thread-per-connection server
  makes, with cheaper parking — measure with `benchmarks/http_echo`
  before betting on numbers.

## Where to go from here

- `examples/httpd_parse` — the pure parser, fourteen fixtures, for
  testing request handling without sockets.
- `examples/httpd_wire` — keep-alive, chunked + `100 Continue`, HEAD,
  204, and the whole refusal family on raw connections.
- `examples/httpd_serve`, `examples/httpd_routes` — the acceptance
  walks this guide's examples shadow.
- `examples/https_roundtrip` — TLS end to end, the bad-client probe
  included.
- [`docs/stdlib/httpd.md`](stdlib/httpd.md) — the reference: every
  signature, the options, the strictness, the limits.
- [`docs/stdlib/http.md`](stdlib/http.md) — the client half, for the
  test that rides the wire and for service-to-service calls.
