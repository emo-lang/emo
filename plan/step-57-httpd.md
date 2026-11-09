# Step 57 — The httpd package (the server half of HTTP)

**Milestone:** M23 · **Prereq:** steps 13, 26–27, 28–30 · **Status:** done 2026-11-09

## Why this step exists

The `http` package carries both halves of HTTP, and its server half is
a demonstration, not a server: one request per connection, no
keep-alive, no chunked request bodies, no routing, no timeouts, no
size limits, no graceful shutdown, a five-status reason table. A
language that wants to serve HTTP needs the connection machinery and
the routing to live in one place with one shape, not in every
program's accept loop. This step moves the server half out of `http`
into a dedicated `httpd` package and grows it to a real HTTP/1.1
server, with Go's `net/http` server as the mechanism survey — the
process-per-connection model Emo already runs, pattern routing, per-
request timeouts, size limits, graceful shutdown — while the surface
stays Emo's own: a request arrives as a value and the handler answers
with one.

## Decisions settled here (the trail)

- **httpd owns the server half; `http` returns to client-only.** The
  old `serve`/`serve_requests`/`read_request`/`write_response` are
  deleted in the same step and every caller migrates (the
  `http_echo` bench, `http_roundtrip`, `https_roundtrip`,
  `ssr_page`). The stdlib is pre-1.0; two server APIs is not a
  transition to manage but a mistake to avoid.
- **The handler answers with a `Response` value, not a streaming
  writer.** Go's `ResponseWriter` buys streaming at the price of a
  whole class of status-ordering mistakes (write-after-header,
  forgotten WriteHeader). A returned value puts status, headers, and
  body visibly in one place, and the v1 surface always knows the
  body's length — every response carries `Content-Length`. Streaming
  (SSE, large files) is the named follow-up; its trigger is real code
  that needs it, and it arrives as a writer-shaped handler form, not
  as a mutation of this one.
- **Two serve forms, not one unified Handler interface.** Go's
  "everything is a Handler" is the interface-centric shape of one
  language; Emo's direct server is a block (`serve`'s trailing block)
  and its router is a value (`serve_routes`). Two honest entry names
  beat a unifying abstraction the checker cannot yet express (a
  `Block` is not a class, so a structural interface cannot cover both
  shapes).
- **Routing ports Go 1.22's ServeMux mechanisms onto pattern
  strings.** `"GET /users/{id}"` (method + single-segment wildcard),
  `"/files/{path...}"` (rest wildcard), a trailing `/` as a subtree,
  longest/most-specific pattern wins, a path matched by two
  different methods answers 405 with `Allow`, and `..`/`//` cleanup
  answers 301. Patterns parse at registration; a bad pattern or a
  conflicting one is the programmer's contract and raises. Host-based
  patterns stay out (named follow-up).
- **Strictness on the wire.** A malformed request line, a
  non-token header name (which refuses the space-before-colon
  smuggling shape), a missing Host on HTTP/1.1, conflicting
  Content-Length values, or Content-Length beside Transfer-Encoding
  answer 400 and close. An oversized header block answers 431, an
  oversized body 413. The peer's bytes are expected data — they come
  back as values; only the programmer's own mistakes raise.
- **Percent-decoding is honest about the String boundary.** A String
  cannot carry raw bytes on every target (typescript's strings are
  UTF-8 text — the crypto package's carrier rule), so escapes decode
  only into printable ASCII (0x20–0x7E, a range every target carries
  identically) and an escape decoding anywhere else is a 400 naming
  the byte. No silent mojibake. Byte-exact query values are the
  named follow-up, waiting on a public Bytes↔String bridge.
- **No Date header unless a clock is injected.** The language has no
  clock primitive (the stance `slog` records), so responses carry no
  Date by default and default output stays byte-deterministic;
  `server_options().with_date(fn)` lets a caller with a clock stamp
  every response. The true follow-up is a clock primitive as its own
  language step — slog and httpd would both grow with it.
- **Pure Emo over `net` — zero runtime wiring.** No new primitive, so
  none of the seven compiler touchpoints move; the package declares
  the three targets `net` declares (`ocaml`, `c`, `typescript`) and
  wasm/beam stay undeclared with `net` (no sockets in the wasm host).
  TLS arrives through `net.listen_tls` unchanged.
- **Reasons begin `httpd:`** per the house convention; parse reasons
  are always the 400 family, so the server needs no status beside the
  reason string.

## Tasks

- [x] **T57.1** — The package skeleton and the pure parser: `Request`
      and `Response` as values, `response`/`error` constructors,
      `parse_head` — request line (three parts, token method,
      HTTP/1.x only), header lines (token names canonicalized to the
      one spelling lookups answer, strict colon placement), origin-
      form request-target split into raw path + query map (first
      occurrence wins, pairs without `=` refused, the Host rule for
      HTTP/1.1), percent-decoding under the printable-ASCII
      discipline. The `httpd_parse` example walks fixture heads —
      parsed fields and refusals — byte-identical on the three
      hosted targets.
- [x] **T57.2** — The connection half: reading the head block off a
      conn under the 431 limit, bodies by Content-Length or chunked
      under the 413 limit, `100 Continue` for `Expect:
      100-continue`, response writing (status line, reason phrases,
      `Content-Length` always, HEAD/204/304 body stripping,
      keep-alive negotiation), the keep-alive loop one process per
      connection, per-request timeouts, `serve`/`serve_routes` with
      the `Server` handle (`stop` graceful, `wait` join),
      `server_options` with the with_* builders, and the roundtrip
      and wire-shape goldens (keep-alive double request, chunked
      body, 431, 413, HEAD, injected Date).
- [x] **T57.3** — The Router: pattern parsing at registration
      (raise on bad or conflicting), method-scoped and method-less
      patterns, `{name}` and `{path...}` wildcards feeding
      `req.params`, subtree prefixes, most-specific precedence, 405
      with `Allow`, 301 path cleanup, and the routing goldens.
- [x] **T57.4** — The migration and the docs: `http` loses its
      server half, the bench and examples move to httpd,
      `docs/stdlib/httpd.md` and the zh-CN mirror, the
      `docs/stdlib.md` index rows both languages, and the networking
      intro's pointer.
