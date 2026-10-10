# Step 12 — Networking Library

**Milestone:** M3 complete · **Prereq:** steps 01–11 · **Status:** done

## Goal

The README's unified asynchronous networking API in **direct style**: network
calls read as ordinary blocking calls, the scheduler (step 11) switches
processes underneath, and no `async` / `await` exists anywhere — function
coloring is structurally impossible.

## Scope

### In

- **Layering per the README** —
  - *Core library*: TCP sockets (connect, listen, accept, read, write),
    UDP, Unix-domain sockets. TLS starts as an OpenSSL binding on native.
  - *Standard library*: HTTP client and server on top of the socket layer.
- **Backend mapping** — native rides the step 11 scheduler (own effects
  runtime over io_uring / kqueue / IOCP, libuv fallback); every blocking
  socket call is a suspension point. The public API is one direct-style
  surface; no backend leaks through.
- **Process-per-connection server shape** — `accept` returns a socket; the
  idiomatic server starts a process per connection with
  `do handle(conn)` (library pattern built on step 11, shipped as
  standard-library helpers, not runtime).
- **HTTP** —
  - Client: `http.get(url)`-style verbs with headers/body, timeouts,
    redirects handled explicitly (strictness: no silent redirect chains).
  - Server: route table over the socket layer; a request handler is an
    ordinary Emo function; one process per connection.
- **Socket addresses & errors** — connection failures, DNS failures, and
    timeouts raise ordinary Emo exceptions (the README error model); no
  error codes, no nil returns.
- **Standard-library packaging** — these modules live as the official
  top-level stdlib packages (`http`, `net`), exercising the step 10 package
  machinery for real; they declare `targets = ["native"]` (today `["ocaml", "c"]`) and fail
  resolution elsewhere until their backends exist (honest target metadata).

### Out

- TLS beyond the OpenSSL binding (the pure-OCaml stack is a later
  alternative).
- WebSocket, HTTP/2+ (follow-ups on the same surface).
- Wasm / BEAM / TS backends for this API (step 14; WASI sockets / fetch
  there).

## Tasks

- [x] TCP socket surface on the scheduler; graceful close semantics.
- [x] UDP + Unix-domain sockets.
- [x] DNS resolution through the same suspension path.
- [x] OpenSSL TLS binding; certificate-verification errors surfaced as
      Emo exceptions.
- [x] HTTP client; HTTP server with process-per-connection helper.
- [x] Stdlib packaging with target metadata; fixture-based integration
      tests (loopback listeners, deterministic order).

## Acceptance

- An Emo HTTP server + client round-trip on localhost in one `emo run`
  program, written entirely in direct style — zero `async` tokens exist in
  the language to grep for.
- A timeout and a refused connection each raise a catchable Emo exception
  with a precise message (catch syntax availability per its `CHECK.md`
  state; at minimum, uncaught reporting is accurate).
- TLS handshake to a test certificate fails closed on verification error.
- **M3 exit criteria:** concurrent networked programs — the classic
  process-per-connection server — run in direct style with supervision
  available at library level.

## Close-out

- **Scheduler mapping** — networking rides the own effects runtime (the
  `emo run` scheduler). Socket effects park continuations on fd
  readiness and per-operation deadlines; the Eio bridge refuses them
  with E3013, per the plan's backend mapping (the own runtime is the
  native networking backend).
- **DNS** — resolution is its own effect (`net_resolve`), performed by
  `net.connect`, `net.tls_connect`, and UDP `send_to` before they
  connect; the driver resolves inline in its handler today.
- **TLS** — OpenSSL on the nonblocking fd: want_read / want_write park
  the handshake through the scheduler. Verification loads the default
  trust paths and fails closed; `net_tls_connect_insecure` is the
  explicit opt-out.
- **Stdlib delivery** — `net` and `http` ship as directory-registry
  packages under `stdlib/registry` (targets = ["native"] at the time; today `["ocaml", "c"]`); a project
  points `EMO_REGISTRY` at it and requires them like any package. The
  acceptance example is `examples/http_roundtrip` with its lockfile.
- **Language surface that landed with the library** — the `\r` escape,
  `Block` type-declaration vocabulary, lenient block-parameter type
  declarations
  (cross-module types narrowed to Unknown then; type names resolve
  program-wide since 2026-10-10 — CHECK.md, cross-module types),
  forward-reference checking in
  the checker, `String` methods (`length`, `substring`, `split`,
  `trim`, `lower`, `index_of`, `starts_with`, `to_int`), and
  `Array.append`.
- **HTTP posture** — one connection per exchange (`Connection: close`),
  redirects never followed, chunked responses refused, `Host` sent
  without the port.
- Exact stdlib names are in the README (Networking). Exception-catch
  syntax stays pending in `CHECK.md`; acceptance rests on uncaught
  reporting, per the design gate.
