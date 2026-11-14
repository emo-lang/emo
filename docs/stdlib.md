# The Standard Library

The standard library is a set of packages the compiler ships with:
they live in the bundled registry and resolve like any other
dependency — every one is versioned, and every one is pinned in the
manifest's `deps` block. Using one is that pin plus `require`:

```emo
// package.emo
deps {
  "json" = "0.1.0"
}
```

```emo
require "json"
```

A `require` the manifest does not pin is a compile error (E5006) whose
message names the line to add; the packages the required one depends
on come through its own manifest. A package whose `targets` do not
include the build's target is refused at resolution time — the format
packages run everywhere, the systems packages declare a Unix-shaped
host, and the network packages declare `ocaml`, `c`, and
`typescript`.

The REPL is the one require without a manifest: a session pins
nothing, so a stdlib name resolves straight from the bundled registry
(`require "math"`, then `math.pow(2.0, 10.0)` answers). A scoped name
or a name the standard library does not carry refuses there (E5015)
with the project path — registry packages stay a manifest's business.

Two conventions hold across every package:

- **Expected failures are values; violations raise.** A call that can
  fail for data reasons returns `(R.ok, value)` or `(R.error, reason)`
  — the reason a String that begins with the package name and a colon
  (`json: expected array element at byte 3`, `os: open_write
  notes.txt: Permission denied`; `file` errors surface as `os:`
  because the shared os runtime performs the syscall). No error codes,
  no nil. A raise is reserved for contract violations: `Exception` is
  the one exception class, its optional `data` Map carries
  machine-readable context instead of message concatenation, and a
  raise ends the process. End of stream is not an error: the empty
  string ends a stream.
- **Pure Emo where the language suffices.** The format packages and
  the codec are written in Emo over the shared runtimes, so every
  target they declare answers byte-for-byte identically. `os` and
  `file` dispatch to the runtime's implementations, backed by POSIX, and
  only they are native-only; `net` and `http` dispatch to runtime
  implementations too — POSIX-backed on `ocaml` and `c`, Node-backed on
  `typescript`.

The packages:

| Package | What it gives you | Targets |
|---|---|---|
| [`file`](#the-file-package) | whole-file read and write | `ocaml`, `c`, `wasm` |
| [`os`](#the-os-package) | processes, pipes, descriptor plumbing, environment, signals, raw fd IO, directories | `ocaml`, `c`, `wasm` (fd/directory half) |
| [`bufio`](#the-bufio-package) | buffered readers and writers over any stream | `ocaml`, `c`, `wasm` |
| [`net`](#the-net-package) | TCP, UDP, Unix-domain sockets, DNS, TLS | `ocaml`, `c`, `typescript` |
| [`http`](#the-http-package) | HTTP client | `ocaml`, `c`, `typescript` |
| [`httpd`](#the-httpd-package) | HTTP server | `ocaml`, `c`, `typescript` |
| [`valkey`](#the-valkey-package) | Valkey client, RESP2 | `ocaml`, `c`, `typescript` |
| [`websocket`](#the-websocket-package) | WebSocket client and server halves, RFC 6455 | `ocaml`, `c`, `typescript` |
| [`playwright`](#the-playwright-package) | Playwright client, the driver's channel protocol over `run-server` | `ocaml`, `c`, `typescript` |
| [`json`](#the-json-package) | JSON decode and encode | all five |
| [`yaml`](#the-yaml-package) | YAML 1.2 (core schema) decode and encode | all five |
| [`xml`](#the-xml-package) | XML decode and encode | all five |
| [`dom`](#the-dom-package) | strict HTML parse and CSS-selector query | all five |
| [`template`](#the-template-package) | text with holes rendered from a json context, strict at every step | all five |
| [`base64`](#the-base64-package) | RFC 4648 base64 codec | all five |
| [`crypto`](#the-crypto-package) | SHA-2/SHA-3, HMAC, HKDF/PBKDF2, ChaCha20-Poly1305, AES-GCM, Ed25519, X25519 | all five |
| [`rand`](#the-rand-package) | OS entropy and a deterministic HMAC-DRBG stream | `ocaml`, `c`, `typescript`, `beam`, `wasm` |
| [`uuid`](#the-uuid-package) | RFC 9562 UUIDs: v4/v7/v3/v5, the strict text and byte forms | all five |
| [`csv`](#the-csv-package) | RFC 4180 CSV records, UTF-8 | all five |
| [`float`](#the-float-package) | exact binary64 and decimal-text conversion | all five |
| [`math`](#the-math-package) | float scalars, transcendentals, complex, FFT, BLAS1, dense solver | all five |
| [`fastmath`](#the-fastmath-package) | the host libm: `math`'s scalars at native speed | `ocaml`, `c` |
| [`quad`](#the-quad-package) | QUADPACK adaptive quadrature behind a scalar callback | `c` |
| [`plot`](#the-plot-package) | declarative 2D charts rendered to SVG | all five |
| [`slog`](#the-slog-package) | structured logging, logfmt or JSON | all five |
| [`sync`](#the-sync-package) | a wait group: let a process wait for N units of work | all five |
| [`time`](#the-time-package) | the wall clock, the monotonic clock, the calendar, and the timing family | `ocaml`, `c`, `typescript`, `wasm` (clock half), `beam` |
| [`sql`](#the-sql-package) | SQL text to an abstract syntax tree | all five |
| [`sqlite3`](#the-sqlite3-package) | SQLite: prepared statements, stepped rows | `c` |
| [`postgres`](#the-postgres-package) | PostgreSQL client over libpq: `$1` params, value errors | `c` |
| [`term`](#the-term-package) | terminal input: lines, raw mode, key events, size | `c` |
| [`wasm`](#the-wasm-package) | a WebAssembly runtime in Emo: decode, validate, execute, host imports | `ocaml`, `c` |

"all five" names the hosted targets those packages declare — `c`,
`ocaml`, `typescript`, `wasm`, and `beam`. It is the package's list, not
the language's: the interpreter evaluates a program without producing an
artifact, and the full build-target set — `c`, `ocaml`, `typescript`,
`browser`, `wasm`, `beam`, `riscv64` — is walked end to end in
[`docs/demo-targets.md`](demo-targets.md).

All packages are version 0.1.0. Each has a full API reference under
[`docs/stdlib/`](stdlib/) (Chinese translations under
[`docs/zh-CN/stdlib/`](zh-CN/stdlib/)), and every package a program
calls on its own has a runnable demo under `examples/`.

## The `file` package

Direct-style whole-file IO on the scheduler: read a file in one call,
write one in another. Paths are taken as given (relative paths
resolve against the process's working directory).

```emo
def read(path String) (R, String)
def write(path String, contents String) (R, Int64)
```

`read` answers the file's bytes, or `(R.error, reason)` when the file
is missing or unreadable. `write` creates or truncates, writes every
byte, and answers how many were written. For anything streamed,
buffered, or appended, use `os` and `bufio` underneath — `file` is the
one-shot shape.

```emo
require "file"

const (R.ok, n) = file.write("notes.txt", "hello from disk\n")
const (R.ok, text) = file.read("notes.txt")
println(text)
```

Reference: [`docs/stdlib/file.md`](stdlib/file.md) · Demo:
`examples/file_read`.

## The `os` package

The process-level surface: process ids, `fork`, `execv`, `execvp`,
`waitpid`, pipes, descriptor plumbing, the environment, the signals,
the working directory, directory listing, and raw (unbuffered,
fd-based) file IO — the machinery a systems program needs before it
can build anything else.

```emo
def getpid() Int64
def getppid() Int64
def fork() (R, Int64)
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void

def pipe() (R, (Int64, Int64))

def open_read(path String) (R, Int64)
def open_write(path String) (R, Int64)
def open_append(path String) (R, Int64)
def read(fd Int64, n Int64) (R, String)
def write(fd Int64, data String) (R, Int64)
def close(fd Int64) (R, Int64)

def list_dir(path String) (R, Array[String])
def mkdir(path String) (R, Int64)
def rmdir(path String) (R, Int64)
def unlink(path String) (R, Int64)
def rename(old_path String, new_path String) (R, Int64)
def getcwd() String
def chdir(path String) (R, Int64)
```

`fork()` answers `(R.ok, pid)` — the child sees `0`, the parent the
child's pid — and the child leaves through `_exit`. `waitpid(pid)`
answers `(pid, status)` with the kernel's raw 16-bit status word,
decoded by the `wait_exited` / `wait_exit_code` / `wait_signaled` /
`wait_signal` / `wait_stopped` / `wait_stop_signal` helpers.
`open_write` creates or truncates, `open_append` creates or appends;
`read` answers up to `n` bytes and the empty string at end of file.
`list_dir` answers byte-order sorted entry names without `.` and
`..`, the same order on both targets.

Targets: `["ocaml", "c"]`. Reference:
[`docs/stdlib/os.md`](stdlib/os.md) · Demo: `examples/os_demo`.

## The `bufio` package

Buffered IO: a fixed-size memory buffer in front of any byte stream,
so readers issue few large reads, writers coalesce small writes, and
both sides gain whole-line and up-to-a-delimiter reads. The shape
follows Go's `bufio`: a `Reader` and a `Writer` over two one-method
structural interfaces, adapters for the concrete streams, buffers the
caller sizes explicitly.

```emo
interface ByteReader {
  def read(n Int64) String
}

interface ByteWriter {
  def write(data String) Int64
}

def fd_reader(fd Int64) FdReader
def fd_writer(fd Int64) FdWriter
def bytes_reader(data String) BytesReader
def bytes_writer() BytesSink

def default_size() Int64          // 4096
def reader(src ByteReader) Reader
def reader_size(src ByteReader, size Int64) Reader
def writer(sink ByteWriter) Writer
def writer_size(sink ByteWriter, size Int64) Writer
```

Any class with a matching `read` or `write` satisfies the interface
by shape, so readers stack. The `Reader`:

```emo
r.read(n)            // up to n bytes; "" at end of stream
r.read_byte()        // one byte as a one-byte string
r.read_string(delim) // through the next one-byte delimiter, terminator included
r.read_line()        // read_string("\n") by another name
r.peek(n)            // n bytes without consuming; wider than the buffer raises
r.discard(n)         // skips up to n bytes, answers how many
r.unread_byte()      // pushes the last byte back, once
r.buffered()         // bytes ready in the buffer
r.reset(src)         // empty the buffer, continue on src
```

The `Writer`:

```emo
w.write(data)   // buffers, flushing as it fills; passes large writes through
w.write_byte(b) // one byte, as a one-byte string
w.flush()       // hand every buffered byte to the sink
w.buffered()    // bytes waiting for the next flush
w.available()   // room left before an automatic flush
w.reset(sink)   // flush, then start over on sink
```

End of stream is a value — the empty string — never an exception;
`read_line` keeps the terminator so an empty line stays
distinguishable from the end of the stream. A `Writer` must be
`flush`-ed before the stream ends: the tail in the buffer belongs to
the caller.

Targets: `["ocaml", "c"]` (it builds on `os`, which its own manifest
pins). Reference:
[`docs/stdlib/bufio.md`](stdlib/bufio.md) · Demo:
`examples/bufio_demo`.

## The `net` package

Sockets: TCP, UDP, Unix-domain sockets, DNS, and TLS — a thin,
readable layer of Emo source over the runtime's network implementation.
Direct style: a blocking call reads like any other function call, and
the scheduler parks the process while the socket is busy. Every
failure — refused connection, unresolvable name, exceeded deadline —
comes back as `(R.error, reason)`, the reason naming the peer, the
operation, and what went wrong.

```emo
def resolve(host String) (R, Array[String])
def connect(host String, port Int64, timeout Float64) (R, TcpConn)
def listen(host String, port Int64) (R, TcpListener)
def connect_unix(path String, timeout Float64) (R, TcpConn)
def listen_unix(path String) (R, TcpListener)
def tls_connect(host String, port Int64, timeout Float64) (R, TcpConn)
def tls_connect_insecure(host String, port Int64, timeout Float64) (R, TcpConn)
def listen_tls(host String, port Int64, cert_path String, key_path String) (R, TcpListener)
def udp_bind(host String, port Int64) (R, UdpSocket)
```

Timeouts are seconds; `0.0` waits indefinitely. `tls_connect` verifies
the peer certificate against the system trust store;
`tls_connect_insecure` is the explicit, visibly dangerous opt-out.

```emo
conn.read_line()          // (R, String) — one line, without the terminator
conn.read_exactly(n)      // (R, String) — exactly n bytes
conn.read_all()           // (R, String) — everything until the peer closes
conn.write(data)          // (R, TcpConn) — chain through the (R.ok, conn)
conn.close()              // (R, TcpConn)
conn.set_timeout(seconds) // TcpConn

listener.accept()         // (R, TcpConn) — parks until a connection arrives
listener.port()           // Int64 — the bound port
listener.close()          // (R, TcpListener)
listener.set_timeout(seconds)

socket.send_to(host, port, data) // (R, UdpSocket)
socket.recv_from()               // (R, (String, String, Int64)) — data, host, port
socket.port()                    // Int64
socket.close()                   // (R, UdpSocket)
socket.set_timeout(seconds)
```

EOF is never a silent partial result: `read_exactly` fails with its
reason when the peer closes early, a close mid-line is the error
tuple, and `read_all` is the one read that treats EOF as normal. A
Unix-domain listener has no port — `port()` on one is an error.

Targets: `["ocaml", "c", "typescript"]`. On `c` the package is TCP and
TLS; UDP, Unix-domain sockets, and `net.resolve` are refused at runtime
there. Reference:
[`docs/stdlib/net.md`](stdlib/net.md) · Demo: `examples/tcp_echo`.

## The `http` package

An HTTP client in pure Emo on top of `net`. Direct style throughout;
one connection per request, closed after the exchange; redirects are
never followed — a 3xx is a response like any other. Serving HTTP is
the `httpd` package's half of the wire.

```emo
def get(url String) (R, HttpResponse)
def post(url String, body String) (R, HttpResponse)
def put(url String, body String) (R, HttpResponse)
def delete(url String) (R, HttpResponse)
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) (R, HttpResponse)
def request_with(method String, url String, headers Array[(String, String)], body String, timeout Float64, tls_options net.TlsClientOptions) (R, HttpResponse)
```

The URL must carry an explicit `http://` or `https://` scheme;
`https` rides `net.tls_connect` — verification on. `request_with`
passes a per-connection TLS policy (`net.tls_client_options()`) to
`net.tls_connect_with`: a private trust store, a client certificate,
or a verification-name override. The response:

```emo
class HttpResponse {
  // fields: status Int64, headers Array[(String, String)], body String
  def header(name String) String   // case-insensitive; "" when absent
}
```

Targets: `["ocaml", "c", "typescript"]` (it builds on `net`, which its own
manifest pins). On `c` it inherits `net`'s coverage: TCP and TLS.
Reference:
[`docs/stdlib/http.md`](stdlib/http.md) · Demos:
`examples/http_roundtrip`, `examples/https_roundtrip`.

## The `httpd` package

An HTTP server in pure Emo on top of `net`: one process per connection,
a request arriving as a value and the handler answering with one —
keep-alive, chunked request bodies, `100-continue`, per-request
timeouts and size limits, and graceful shutdown all in the package, not
every program's accept loop. The client half is the `http` package.

```emo
const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [], "hello from emo\n")
}

server.stop()   // close the listener; live connections finish
server.wait()   // join the drain
```

`serve` (or `serve_with` with `server_options()` — read/idle timeouts,
header and body budgets over 431/413, an injected `Date` clock) answers
a `Server` handle at once; `wait()` blocks until the drain completes.
The handler receives one whole `Request` — `method`, `path`, `query`,
canonicalized `headers` (lookups case-insensitive), `body` by
`Content-Length` or chunked with `100-continue`, `params` — and answers
a `Response` value; the wire always carries `Content-Length` (derived,
or the handler's own), HEAD/204/304 lose their bodies, and keep-alive
holds until the peer says close.

Routing lives in `httpd.router()`, one registration at a time:

```emo
var r = httpd.router()
r = r.get("/hello/{name}", greet)      // req.params["name"], decoded
r = r.get("/files/{path...}", files)   // the rest of the path, one capture
r = r.handle("/static/", serve_static) // every method, the subtree below
const server = httpd.serve_routes(listener, r)
```

The most specific pattern wins (literal > wildcard > rest, longer past
a shared prefix); a shape matched with another method answers 405 with
`Allow`; `//`, `.`, and `..` answer 301 to the cleaned path. Patterns
parse at registration — malformed or conflicting ones raise. The peer's
malformed bytes are values (400/431/413 plain text, connection closed);
the package stays clock-free — a `Date` header needs a caller-chosen
zone, so responses carry none unless one is injected through
`with_date` (the `time` package's UTC clock answers the instrument).

Targets: `["ocaml", "c", "typescript"]`. Reference:
[`docs/stdlib/httpd.md`](stdlib/httpd.md) · Guide:
[`docs/httpd-guide.md`](httpd-guide.md) · Demos:
`examples/httpd_routes`, `examples/httpd_serve`, `examples/httpd_wire`,
`examples/httpd_parse`, `examples/https_roundtrip`.

## The `valkey` package

A Valkey client in pure Emo on top of `net`, speaking RESP2. Direct
style; one connection, one command, one reply — no pipelining, no
pooling, no reconnection to hide a dropped socket. Server error replies
are values: `(R.error, "valkey: " + the server's text)`. A missing key
is the null reply read through `is_null?()`, not an error.

```emo
valkey.connect(host, port, timeout)   // (R, Valkey) — and connect_unix,
                                      // connect_tls, connect_tls_insecure

v.get(key)                  // (R, Reply) — bulk, or the null reply
v.set(key, value)           // (R, String) — "OK"
v.incr(key)                 // (R, Int64)
v.hgetall(key)              // (R, Array[(String, String)])
v.lrange(key, start, stop)  // (R, Array[String])
v.smembers(key)             // (R, Array[String])
v.command(args)             // (R, Reply) — any command, its raw reply
```

Around forty-five typed doors cover the string, key, hash, list, and
set families plus `ping`/`echo`/`auth`/`select`; each decodes the shape
its command's contract names, and a server answering a different shape
is the error value. Replies are a `Reply` tree — one class per RESP2
kind (`rnull`, `rstring`, `rint`, `rarray`; the simple and bulk strings
one kind), the `as_*` accessors the caller's assertions, json's rule.
The timeout bounds each exchange; `0.0` waits indefinitely.

Targets: `["ocaml", "c", "typescript"]` (it builds on `net`, which its
own manifest pins). Reference:
[`docs/stdlib/valkey.md`](stdlib/valkey.md) · Demo:
`examples/valkey_demo`.

## The `websocket` package

The two WebSocket halves (RFC 6455) in pure Emo on `net`: `connect`
dials and verifies the handshake's accept, `accept` takes a
connection a client upgraded, and both meet on one `Websocket` whose
unit is one text message. Frames stay under this roof — masking by
role, pings answered with their own payload, a close answered, and a
fragmented message joined before `recv_message` answers it.

```emo
websocket.connect(host, port, path, timeout)  // (R, Websocket)
websocket.accept(conn)                        // (R, Websocket)
ws.send_text(data)    // (R, Websocket)
ws.recv_message()     // (R, String) — fragments joined, control frames handled
ws.close()            // (R, Websocket) — one close frame, then the socket
```

Targets: `["ocaml", "c", "typescript"]`. Reference:
[`docs/stdlib/websocket.md`](stdlib/websocket.md) · Demo:
`examples/websocket_demo`.

## The `playwright` package

A Playwright client in pure Emo: the driver's channel protocol spoken
to the official `playwright run-server` through the `websocket`
package. The run-server pre-launches the browser for the connection —
the client never launches — and the page's doors drive it. A refused
call is `(R.error, "playwright: " + the driver's text)`; the wire
never raises on driver data.

```emo
playwright.connect(host, port, timeout)  // (R, Playwright) — chromium
pw.browser()                             // Browser — the pre-launched one
browser.new_page()                       // (R, Page)
page.goto(url)                           // (R, PageResponse) — status and url
page.click(sel)                          // (R, Page) — fill, press likewise
page.text_content(sel)                   // (R, Text) — is_null?(), then as_string()
page.screenshot()                        // (R, Bytes) — a PNG
pw.close()                               // (R, Playwright)
```

Targets: `["ocaml", "c", "typescript"]`. Reference:
[`docs/stdlib/playwright.md`](stdlib/playwright.md) · Guide:
[`docs/playwright-get-started.md`](playwright-get-started.md) · Demo:
`examples/playwright_demo`.

## The `json` package

The JSON reader and writer: strict, byte-level RFC 8259 decode into a
`Json` value tree, and encode back — compact or pretty. A `Json` is
an interface over one class per JSON kind (`JsonNull`, `JsonBool`,
`JsonInt`, `JsonFloat`, `JsonString`, `JsonArray`, `JsonObject`),
discriminated by the `JsonKind` enum.

```emo
def decode(text String) Json
def encode(v Json) String
def encode_pretty(v Json) String   // two-space indentation
```

The scalar accessors live on the interface — the wrong kind raises;
arrays and objects are read through `is()` into the concrete class:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
def kind() JsonKind
def is_null?() Bool
```

`JsonArray` answers `items()` (`Array[Json]`); `JsonObject` answers
`entries()` (`Array[(String, Json)]`) and `get(key)` — duplicate keys
last-win, a missing key raises. Values are built with the factories,
keys and items as explicit arrays:

```emo
def null() Json
def bool(b Bool) Json
def int64(n Int64) Json
def float64(x Float64) Json
def string(s String) Json
def array(items Array[Json]) Json
def object(entries Array[(String, Json)]) Json
```

`decode` answers `(R.ok, doc)` or `(R.error, reason)` — the reason
carrying the byte offset on every malformation, nesting deeper than
512 included. Floats encode in the shortest round-trip form and stay
visibly floats (`1.0`, never `1`), so encode → decode → encode is the
identity, value and kind.

Targets: all five — byte-identical answers on every one. Reference:
[`docs/stdlib/json.md`](stdlib/json.md) · Demos: `examples/json_demo`,
`examples/json_edge`.

## The `yaml` package

The YAML reader and writer: YAML 1.2's core schema decoded into a
`Yaml` value tree that mirrors the json package's design, and encoded
back in block style. The packages are independent — requiring yaml
does not require json.

```emo
def decode(text String) (R, Yaml)
def encode(v Yaml) String
```

`Yaml` is an interface over `YamlNull`, `YamlBool`, `YamlInt`,
`YamlFloat`, `YamlString`, `YamlArray`, `YamlObject`, discriminated
by `YamlKind`, with the same accessors and the same factories as
json (`yaml.null()`, `yaml.bool(b)`, `yaml.int64(n)`,
`yaml.float64(x)`, `yaml.string(s)`, `yaml.array(items)`,
`yaml.object(entries)`); mapping keys are strings.

Decode covers block mappings and sequences (including the compact
`- key: value` form), flow collections, quoted scalars with the YAML
escape set, comments, `|`/`>` block scalars with chomping, and plain
scalars resolved per the core schema (`null`/`~`, booleans, decimal
and `0x`/`0o` integers, floats including `.inf`/`.nan`). Anchors and
aliases, tags, multi-document input, and tabs in indentation come
back as `(R.error, reason)` with the byte offset.

Targets: all five. Reference: [`docs/stdlib/yaml.md`](stdlib/yaml.md)
· Demos: `examples/yaml_demo`, `examples/yaml_edge`.

## The `xml` package

The XML reader and writer: well-formed XML decoded into a `Xml`
value tree and encoded back. XML is all text — nothing is coerced to
numbers or booleans, and all text children are kept, so
`encode(decode(x))` reproduces the tree.

```emo
def decode(text String) (R, Xml)
def encode(v Xml) String
```

`Xml` is an interface over `XmlElement` and `XmlText`, discriminated
by `XmlKind`:

```emo
def kind() XmlKind
def is_text?() Bool
def as_text() String      // text nodes; an element refuses
```

The containers live on `XmlElement`, read through `is()`:
`name()`, `attrs()`, `attr(name)` (raises on a missing attribute),
`children()` (all child nodes in document order), `get(name)` (the
first child element named so; raises when missing), and `text()`
(all text in the subtree). Values are built with the factories:

```emo
def element(name String, attrs Array[(String, String)], children Array[Xml]) Xml
def text(s String) Xml
```

Decode checks well-formedness strictly — elements nest and close in
order, attributes are unique with quoted values, exactly one root —
and skips the declaration, comments, processing instructions, and a
DOCTYPE without an internal subset; CDATA decodes as raw text; the
five predefined entities plus `&#ddd;` / `&#xhh;` references decode
everywhere. Every failure comes back as `(R.error, reason)` with the
byte offset.

Targets: all five. Reference: [`docs/stdlib/xml.md`](stdlib/xml.md)
· Demos: `examples/xml_demo`, `examples/xml_edge`.

## The `dom` package

The read-only DOM: strict HTML parsed into a `Node` tree, queried
with CSS selectors — goquery's shape, pure Emo over the shared
runtimes. Parsing is the xml.decode direction: malformed input
answers `(R.error, reason)` with the byte position, never a repaired
tree, and there is no `html`/`head`/`body` synthesis — the tree
mirrors the source, so fragments parse into what they name.

```emo
dom.parse(text)               // (R, Document) — strict
dom.encode(n Node) String     // canonical HTML back out

doc.find(sel)                 // (R, Selection) — every matching element
sel.find(sel)                 // (R, Selection) — descendants
sel.eq(i) / first() / last() / slice(start, end)
sel.attr(name)                // (R, String) — attr_or for the default
sel.text() / html() / outer_html()
sel.children() / parent() / parents() / closest(sel)
sel.next_all() / prev_all() / siblings()
sel.filter(sel) / not(sel) / has(sel) / is?(sel)
sel.each(f Block)             // the trailing block walks the selection
```

Selectors carry types, `*`, classes, ids, attribute tests (`[href]`,
`=`, `^=`, `$=`, `*=`, `~=`, `|=`), the four combinators, comma
groups, the structural pseudo-classes (`:first-child`,
`:nth-child(an+b)`, `:not(...)`, `:empty`, `:root`, ...), and
goquery's `:contains`. Pseudo-elements and unknown pseudo-classes
answer as selector errors — `find` never silently matches nothing.
`script`/`style` hold raw text, `title`/`textarea` character
references only; tag and attribute names fold to lowercase.

Targets: all five. Reference: [`docs/stdlib/dom.md`](stdlib/dom.md)
· Demos: `examples/dom_demo`, `examples/dom_edge`.

## The `template` package

A text template engine in pure Emo: text with holes rendered from a
`json` context — Go `text/template`'s mechanism, Emo's own surface.
Strict at every step: parsing refuses malformed actions with the byte
position (the `dom.parse` direction), rendering refuses what has no
text — a missing key, a wrong kind, an out-of-bounds index, a null
hole, a container hole — never silent empty output. The context is the
json tree, so `json.decode` renders directly and numbers render
through the `float` package's exact-decimal text, byte-identical by
construction.

```emo
template.render(text, ctx)          // (R, String) — one-shot
template.new()                      // an empty Set
set.with(name, text)                // (R, Set) — parse a named template
set.render(name, ctx)               // (R, String) — render one member
```

Actions: `{{ user.name }}` holes with bare dotted paths
(`users[0].name`, `m["a b"]`), filter pipelines (`{{ name | upper }}` —
upper/lower/trim/length/join/default/escape_html, fixed and
ASCII-safe), `{{ if }}`/`{{ else if }}`/`{{ else }}`/`{{ end }}` with
"not the zero value" truthiness, `{{ for x in e }}` over arrays and
objects with `{{ else }}`, `{{ template "name" e? }}` includes
(bindings never cross the edge; the depth cap names the chain), and
`{{- ` / ` -}}` trim markers with `{{! ... }}` comments. There is no
arithmetic and no comparison — the template renders, the program
computes.

Targets: all five. Reference:
[`docs/stdlib/template.md`](stdlib/template.md) · Demos:
`examples/template_demo`, `examples/template_edge`.

## The `base64` package

The RFC 4648 base64 codec: bytes in, padded base64 text out, and
back — pure Emo over the shared runtimes, so every target answers
with the same bytes.

```emo
def encode(data String) String
def decode(text String) (R, String)
```

`encode` always emits the standard alphabet with `=` padding.
`decode` accepts exactly what the encoder produces: the standard
alphabet only, padding only in the final quantum, and the padding
bits the RFC requires to be zero really must be zero — `QR==` is a
mistake, not a synonym of `QQ==`. No whitespace tolerance and no
line-wrap acceptance; every rejection comes back as
`(R.error, reason)` with the offending byte offset.

Targets: all five. Reference:
[`docs/stdlib/base64.md`](stdlib/base64.md) · Demo:
`examples/base64_demo`.

## The `crypto` package

The primitives layer: hashes, MACs, key derivation, AEAD ciphers, a
signature scheme, and a key agreement — pure Emo over `Int64` and
`Bytes`, so every target answers the same bytes, and every golden is
a diff against the RFC and NIST vectors and — wherever Go's standard
library carries the primitive — against Go's own answers.
A root module and eight submodules, called by their qualified names:

```emo
def constant_time_compare(a Bytes, b Bytes) Bool
def hex_encode(data Bytes) String
def hex_decode(text String) (R, Bytes)

// crypto.sha2:   sha256, sha224, sha512, sha384, sha512_224, sha512_256,
//                and the streaming Digest and Wide classes
// crypto.sha3:   sha3_224, sha3_256, sha3_384, sha3_512, shake128, shake256
// crypto.hash:   interface Hash; hmac_<alg>(key, data)
// crypto.kdf:    hkdf_<alg>(ikm, salt, info, length), hkdf_<alg>_expand,
//                pbkdf2_<alg>(password, salt, iterations, length)
// crypto.cipher: chacha20, poly1305, chacha20_poly1305_seal/open,
//                aes_encrypt_block/decrypt_block, aes_ctr,
//                aes_cbc_encrypt/decrypt, aes_gcm_seal/open
// crypto.sign:   ed25519_public(seed), ed25519_sign(seed, message),
//                ed25519_verify(public, message, signature)
// crypto.ecdh:   x25519(scalar, point), x25519_public(scalar)
// crypto.legacy: sha1, md5
```

Bytes in, Bytes out; text stays text at the hex codec only. The error
split is the library's: a wrong length or count raises, and a data
reason is a value — a tag that does not verify is
`(R.error, "crypto: authentication failed")` whatever the forgery, a
bad signature is `false`, an all-zero shared secret is
`(R.error, "crypto: x25519 low-order point")`. Constant time is a
source-level discipline — no secret-dependent branch or index, AES's
S-box lookup the documented exception — and the reference states per
target what that discipline becomes, which is a guarantee on none of
them. SHA-1 and MD5 sit behind `crypto.legacy`, broken for every
security purpose and present for existing data.

Targets: all five. Reference:
[`docs/stdlib/crypto.md`](stdlib/crypto.md) · Demos:
`examples/crypto_hash`, `examples/crypto_aead`,
`examples/crypto_sign`, `examples/crypto_ecdh`, and the c-only
`examples/crypto_hash_million`, `examples/crypto_kdf`,
`examples/crypto_sign_sweep`, `examples/crypto_ecdh_iterated`.

## The `rand` package

Entropy, and a reproducible stream: the operating system's random
bytes for keys and seeds, and SP 800-90A's HMAC-DRBG (SHA-256) in its
one-shot shape for everything that must answer the same bytes every
time.

```emo
def bytes(n Int64) (R, Bytes)
def drbg_sha256(seed Bytes, length Int64) Bytes
```

`bytes` answers `(R.ok, bytes)` from `/dev/urandom`, `getentropy`,
Node's `crypto.randomBytes`, or `crypto:strong_rand_bytes` by target,
and `(R.error, "rand: …")` when the source refuses; a negative count
raises. `drbg_sha256` answers `length` bytes that depend on the seed
alone, the same on every target forever — the generator for fixtures
and test keys, not a source of secrets.

Targets: `ocaml`, `c`, `typescript`, `beam` — the wasm host supplies
no entropy, so the manifest refuses it rather than failing at run
time. Reference: [`docs/stdlib/rand.md`](stdlib/rand.md) · Demo:
`examples/rand_demo`.

## The `uuid` package

The RFC 9562 identifier as one immutable 16-byte value: the versions
as named doors, and the text and byte forms as strict conversions.
Pure Emo over `crypto` and `rand`, so every target answers
byte-for-byte.

```emo
def nil() Uuid
def max() Uuid
def from_bytes(data Bytes) (R, Uuid)
def parse(text String) (R, Uuid)
def v4() (R, Uuid)
def v7(now_ms Int64) (R, Uuid)
def v3(namespace Uuid, name String) Uuid
def v5(namespace Uuid, name String) Uuid
def ns_dns() Uuid
def ns_url() Uuid
def ns_oid() Uuid
def ns_x500() Uuid
```

The `Uuid` value renders itself — `to_string` is the protocol method,
`println(id)` prints the lowercase hex-and-dash form — and answers
`to_bytes`, `version`, `variant`, `is_nil?`, `is_max?`, and the RFC's
big-endian `compare`. `parse` takes exactly the canonical 36-character
form, hex case-insensitive, and every rejection names the first
offending byte; a wrong `from_bytes` length is refused the same way.
`v4` draws 122 random bits from the operating system's entropy;
`v7(now_ms)` takes the Unix time in milliseconds from the caller's
own clock (`time.now()`) over 74 random bits, raising on a
negative or 48-bit-overflowing timestamp; `v3` and `v5` are the
deterministic name-based doors over `crypto.legacy`'s digests, the
four IANA namespace IDs beside them as `ns_dns`/`ns_url`/`ns_oid`/
`ns_x500`, any `Uuid` a custom namespace. v1/v2/v6 and a v8
constructor are out, named in the reference.

Targets: all five. Reference: [`docs/stdlib/uuid.md`](stdlib/uuid.md)
· Demo: `examples/uuid_demo`.

## The `csv` package

The CSV reader and writer: RFC 4180 records as arrays of string
fields, UTF-8 only. Decode is strict about quoting, record endings,
and UTF-8; encode writes the RFC's canonical form, so
`decode(encode(rows))` is `rows`. Pure Emo, so all five targets answer
byte-for-byte.

```emo
def decode(text String) (R, Array[Array[String]])
def encode(rows Array[Array[String]]) String
def decode_delimited(text String, delimiter String) (R, Array[Array[String]])
def encode_delimited(rows Array[Array[String]], delimiter String) String
```

A document is records of string fields — no header is imposed; the
first record is a header only if the caller reads it as one. A record
ends at CRLF, LF, or a lone CR (a final one opens no empty record); a
quoted field holds delimiters and line breaks; a leading BOM is
removed; and every byte must be valid UTF-8. A one-byte delimiter
(TSV, semicolons) is the `_delimited` pair. Malformed input is
`(R.error, reason)` with the byte offset; a bad delimiter and a
zero-field record raise.

Targets: all five. Reference: [`docs/stdlib/csv.md`](stdlib/csv.md) ·
Demos: `examples/csv_demo`, `examples/csv_edge`.

## The `float` package

Exact conversion between binary64 and decimal text: a decimal literal
becomes the nearest bits, and a `Float64` becomes the shortest text
that reads back to it. Both directions are `Int64` arithmetic in the
package's `internal` subtree, so all five targets answer byte-for-byte;
`json`, `sql` and `yaml` all read and write numbers through it.

```emo
def parse_exact(neg Bool, digits Bytes, n Int64, e10 Int64) Int64
def parse_decimal(src Bytes, ii Int64, il Int64, fl Int64, e10 Int64, neg Bool) (R, Float64)
def finite_bits(bits Int64) Bool
def to_text(x Float64) String
```

`parse_decimal` is the checked constructor the format packages read
literals through: it turns a literal's digit runs and exponent into the
nearest binary64 and refuses a magnitude binary64 cannot hold.
`parse_exact` is the raw primitive beneath it, rounding once (nearest,
ties to even — the answer `strtod` gives) and answering the infinity
pattern for a value past binary64's range; `finite_bits` says whether a
pattern is a value at all. `to_text` prints the shortest round-tripping
text and raises on a non-finite value, which has no decimal text.

Targets: all five. Reference:
[`docs/stdlib/float.md`](stdlib/float.md).

## The `math` package

The float functions the rest of the standard library builds on: the
scalars, the powers of two, the transcendentals, the error function and
its complement, the gamma pair, the complex arithmetic, the radix-2
FFT, the BLAS1 kernels, and the dense solver. Pure Emo over the scalar
operations all five targets share, with fixed-order series and their
coefficients written into the source, so each answers byte-for-byte.

```emo
const e = 2.718281828459045
const pi = 3.141592653589793

def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def hypot(a Float64, b Float64) Float64
def pow2(n Int64) Float64
def exp(x Float64) Float64
def exp2(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def log2(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
def sin(x Float64) Float64
def cos(x Float64) Float64
def tan(x Float64) Float64
def atan(x Float64) Float64
def atan2(y Float64, x Float64) Float64
def asin(x Float64) Float64
def acos(x Float64) Float64
def sinh(x Float64) Float64
def cosh(x Float64) Float64
def tanh(x Float64) Float64
def erf(x Float64) Float64
def erfc(x Float64) Float64
def tgamma(x Float64) Float64
def lgamma(x Float64) Float64
def complex_add(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_div(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_abs(z (Float64, Float64)) Float64
def fft(v Array[Float64]) Array[Float64]
def ifft(v Array[Float64]) Array[Float64]
def dot(x Array[Float64], y Array[Float64]) Float64
def lu(a Array[Float64], n Int64) (Array[Float64], Array[Int64])
def solve(a Array[Float64], n Int64, b Array[Float64]) Array[Float64]
```

`exp` range-reduces to `2^k * exp(r)` with a short Taylor series; `log`
uses `log(x) = e*ln2 + log(m)` with the atanh series; `tgamma` and
`lgamma` run the Lanczos approximation with its fixed coefficient set,
folding the negative half-line through the reflection formula. A
complex value is an interleaved `(re, im)` pair; a matrix is a flat
row-major array with its dimension spelled out. Out-of-domain
arguments are contract violations, not values — a non-positive
`log`, the trigonometric reduction bound, the gamma poles (the
non-positive integers), `tgamma` past `x ≈ 171.62`, a singular `lu` —
they raise, because the beam target's Erlang floats cannot represent
NaN or infinity at all, so returning one is not an option. The
ELEFUNT-derived battery in `examples/math_elefunt` prints each
function's maximum and rms loss in bits against a fixed identity
sample; the golden's `expected.txt` is the accuracy record. The whole
package is pure: the host's faster tier lives in the separate
`fastmath` package.

Targets: all five. Reference: [`docs/stdlib/math.md`](stdlib/math.md) ·
Demos: `examples/math_demo`, `examples/math_special`,
`examples/math_elefunt`.

## The `fastmath` package

The host's math functions, bound directly to the platform `libm`: the
same scalar surface as `math` at the host library's speed. Each call is
a plain per-call `libm` binding — no reassociation, no relaxation — but
the bits follow the host and are not byte-identical across platforms,
and there are no domain guards: an out-of-range argument returns
whatever the host returns, not a raise.

Targets: `ocaml` and `c` (a `require` elsewhere fails E5007 at load;
under the interpreter a call raises E3009). Reference:
[`docs/stdlib/fastmath.md`](stdlib/fastmath.md) ·
Demos: `examples/fastmath_demo`, `examples/fastmath_elefunt`.

## The `quad` package

QUADPACK's adaptive quadrature, vendored from netlib (f2c-translated
into the package tree, `d1mach` as literals, no libf2c) behind the one
shape today's FFI admits — a scalar callback:

```emo
interface Integrand {
  def at(x Float64) Float64
}

enum InfiniteRange { from_bound, to_bound, whole_line }

def integrate(f Integrand, a Float64, b Float64, epsabs Float64,
  epsrel Float64) (R, (Float64, Float64))
def integrate_infinite(f Integrand, range InfiniteRange, bound Float64,
  epsabs Float64, epsrel Float64) (R, (Float64, Float64))
```

A class with an `at` method integrates directly, any state riding the
callback. `integrate` runs `dqags`'s globally adaptive 21-point
Gauss–Kronrod rule with the ε-algorithm over a finite range;
`integrate_infinite` runs the transformed 15-point rule over the three
infinite ranges the enum names. Success answers `(R.ok, (value,
abserr))`; every QUADPACK failure code answers `(R.error, reason)` in
netlib's own wording — a convergence failure is a value, not a
violation, and the whole mapping is in
[`docs/stdlib/quad.md`](stdlib/quad.md).

Targets: `c` (a `require` elsewhere fails E5007 at load; under the
interpreter a call raises E3009). Reference:
[`docs/stdlib/quad.md`](stdlib/quad.md) ·
Demo: `examples/quad_demo`.

## The `plot` package

The declarative 2D charting package: a figure is a value — a `Figure`
holding `Axes`, each holding marks — and one call renders it to SVG.
Pure Emo, so all five targets answer byte-for-byte.

```emo
def figure() Figure
def axes() Axes
def svg(fig Figure) String

def with_title(t String) Figure
def with_size(w Float64, h Float64) Figure
def with_axes(a Array[Axes]) Figure

def with_x_label(s String) Axes
def with_y_label(s String) Axes
def with_marks(m Array[Mark]) Axes
```

The `plot.mark` submodule carries the marks — bar, line, scatter,
area, hist, band, box, violin, strip, point, and heatmap — each
refined through its style value. Colors are `(Int64, Int64, Int64)`
sRGB triples, 0–255 per channel. Every label is an SVG `<text>`
element, so the package carries no font engine.

`svg` returns the document; writing it to a file is the caller's step,
since the package runs on all five targets while file IO is native-only.
The same figure also renders as terminal text and as a PNG file.

Targets: all five. Fourteen dataset charts over a validating `Table` —
relational, distribution, categorical, and matrix — with log scales,
fixed domains, legends, faceting, themes, and hand-built marks.
Reference: [`docs/stdlib/plot.md`](stdlib/plot.md) · Guide:
[`docs/plot-guide.md`](plot-guide.md) · Demo: `examples/plot_demo`.

## The `slog` package

The structured logger: one line per record, logfmt or JSON, filtered
by a minimum level. A logger is an opaque handle — an ordinary
value — carrying its name, level, and format; nothing to configure
behind the scenes, nothing to tear down, no global state.

```emo
def level_debug() Int64
def level_info() Int64
def level_warn() Int64
def level_error() Int64

def format_logfmt() Int64
def format_json() Int64

def new(name String, min Int64, format Int64) String
def child(handle String, name String) String
def enabled(handle String, level Int64) Bool

def debug(handle String, msg String, attrs Map[String, String])
def info(handle String, msg String, attrs Map[String, String])
def warn(handle String, msg String, attrs Map[String, String])
def error(handle String, msg String, attrs Map[String, String])
def emit(handle String, level Int64, msg String, attrs Map[String, String])
```

Levels are ordered, `debug < info < warn < error`; a record below the
minimum prints nothing, and `enabled` answers the same question
before the caller builds the record. `child` nests its name under the
parent's (`web` + `db` is `web.db`) and inherits level and format.
Records go to stdout with no timestamp — a caller with a time in hand
passes it as an ordinary attribute.

```emo
require "slog"

const log = slog.new("web", slog.level_info(), slog.format_logfmt())
slog.info(log, "listening", {"addr": "127.0.0.1:8080"})
// level=info logger=web msg=listening addr=127.0.0.1:8080

const cache = slog.child(log, "cache")
slog.warn(cache, "slow query", {"ms": "412"})
// level=warn logger=web.cache msg="slow query" ms=412
```

Attrs are a `Map[String, String]`; keys are ASCII letters, digits,
`_`, `.`, `-` only, and every call validates its handle and keys
before filtering — a bad key is a mistake even when the record would
not have printed.

Targets: all five. Reference:
[`docs/stdlib/slog.md`](stdlib/slog.md) · Demo: `examples/slog_demo`.

## The `sync` package

The coordination package: a wait group — a one-shot countdown that
lets a process wait for N units of work. Pure Emo over the process
primitives — a wait group is a process holding a count, `done` is one
message, `wait` is another — so it runs on every target with identical
observable behavior. It guards nothing: Emo has no shared memory to
guard (messages are snapshot copies), which is why the package has no
mutex — a wait group only counts.

```emo
class WaitGroup {
  def init(n Int64)
  def done() Void
  def wait() Void
  def stop() Void
}
```

`WaitGroup.new(n)` starts a countdown of `n` units and answers the
group's handle; `done` announces one finished unit; `wait` blocks until
the count drains and answers immediately once it has; `stop` ends the
counter process. Several processes may `wait` on one group, and each is
woken. The count is set once and only goes down: a wait group is
single-use. A `done` past the count raises at its caller rather than
vanishing; a `wait` parked when `stop` lands raises instead of hanging.

```emo
require "sync"

const wg = sync.WaitGroup.new(3)  // three units of work ahead
do worker(wg)                // ... each ends with wg.done()
do worker(wg)
do worker(wg)
wg.wait()                    // returns with the third done
wg.stop()
```

Every wait-group message on the wire is a tuple tagged `"sync"` — the
package name — so the group's traffic never collides with an
application's own messages.

Targets: `["ocaml", "c", "typescript", "wasm", "beam"]`. Reference:
[`docs/stdlib/sync.md`](stdlib/sync.md) · Demo:
`examples/sync_demo`.

## The `time` package

The clock: `time.now()` reads the OS's wall clock (a `Time` of UTC
epoch milliseconds), `time.mono()` reads the monotonic clock
(nanoseconds — the elapsed-time instrument), and the calendar fields,
formatting, and differences are pure Emo over the reading, byte-identical
wherever a golden can pin them. The timing family speaks seconds, like
`net`'s timeouts: `time.sleep(0.25)` parks the process;
`time.after(0.5) { ... }` runs the block once, its own process; and
`time.tick(3) { ... }` is the calling process's heartbeat — every three
seconds, forever, the block's own `halt()` the stop.

```emo
require "time"

const t = time.now()
println(t.format_iso())                  // 2026-11-13T08:30:15.123Z
println(t.format("Www, DD Mmm YYYY"))    // Fri, 13 Nov 2026
println(t.format_http())                 // Fri, 13 Nov 2026 08:30:15 GMT
println(t.weekday())                     // 5 — Friday

const later = time.of(year: 2026, month: 11, day: 15, hour: 8, minute: 30, second: 15, ms: 123)
println(time.days_between(t, later))     // 2
println(time.hours_between(t, later))    // 48

const start = time.mono()
time.sleep(0.25)
println(time.mono() > start)             // true
```

Formatting is a strict token layout, not Go's reference time — nine
tokens (`YYYY MM DD hh mm ss mmm Mmm Www`), everything else literal,
a token letter that opens no complete token raises naming the byte —
and the calendar is UTC always, so a layout's output rides a golden.
Intervals truncate to whole milliseconds (the honest floor) and refuse
the rest: a negative or non-finite interval and anything past the
1e9-second ceiling raise.

Targets: `["ocaml", "c", "typescript", "wasm", "beam"]` — the clock
half runs on wasm through two host imports, and the timing half raises
at the call there (the wasm driver is synchronous inside one host
call); `riscv64` and `browser` stay undeclared. Reference:
[`docs/stdlib/time.md`](stdlib/time.md) · Demo:
`examples/time_demo`.

## The `sql` package

The SQL parser: SQL text in, an abstract syntax tree out. Pure Emo
over the shared runtimes — a parsed tree is one class per grammar node
(`Select`/`CreateTable`/`Insert`/`Update`/`Delete` statements, `Expr`
expressions, `TableRef` table references),
each answering `to_string()` with the canonical rendering.

```emo
def parse(text String) (R, Stmt)
def split(text String) (R, Array[String])
```

`SELECT` end to end — distinct select lists, joins with `ON`/`USING`,
`WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, `OFFSET` — and the
full expression grammar underneath: literals, parameters (`?`, `?NNN`),
qualified columns, calls, `CAST`, `CASE`, `EXISTS`, subqueries, and the
operator tower with standard precedence. Beside `SELECT`, `CREATE
TABLE` (the v0 types, `NOT NULL`, `PRIMARY KEY`), multi-row `INSERT ...
VALUES`, `UPDATE ... SET ... [WHERE]`, `DELETE FROM ... [WHERE]`, and
`BEGIN`/`COMMIT`/`ROLLBACK` parse and render canonically, with the
`STORE = COLUMN` storage tail on `CREATE TABLE`; `split` cuts a
multi-statement string at the lexer's own semicolons. Malformed input is the value
`(R.error, reason)`, the reason stating what failed at what byte
offset; nothing raises, no error codes, no nil.

```emo
require "sql"

const (R.ok, stmt) = sql.parse("SELECT * FROM users WHERE id = ?1")
println(stmt.to_string())   // SELECT * FROM users WHERE id = ?1
```

Targets: `["ocaml", "c", "typescript", "wasm", "beam"]`. Reference:
[`docs/stdlib/sql.md`](stdlib/sql.md) · Demos: `examples/sql_demo`,
`examples/sql_edge`.

## The `postgres` package

The PostgreSQL client: a direct-style binding over libpq, PostgreSQL's
own C library. A `Conn` is one server connection; statements run
through `PQexecParams` with `$1`-style parameters supplied as `Param`
values, and a query answers a `Rows` read by `(row, column)` with
typed, checked accessors. The calls are `foreign def`s against a C
shim the package carries, and the manifest's `pkg_config` field
resolves libpq — pkg-config answers the shim's include path and the
link's `-lpq`. Expected failures are values, the `net` shape: a server
that is down and a constraint the data broke both answer
`(R.error, reason)` carrying the server's message and SQLSTATE.

```emo
def connect(options ConnOptions) (R, Conn)
def connect_info(info String) (R, Conn)
def options() ConnOptions
def text(v String) Param
def i64(v Int64) Param
def f64(v Float64) Param
def bool(v Bool) Param
def none() Param

class Conn {
  def exec(sql String, params Array[Param]) (R, Int64)
  def query(sql String, params Array[Param]) (R, Rows)
  def close() Void
}

class Rows {
  def count() Int64
  def columns() Int64
  def name(c Int64) String
  def index_of(wanted String) Int64
  def text(r Int64, c Int64) String
  def i64(r Int64, c Int64) Int64
  def f64(r Int64, c Int64) Float64
  def bool(r Int64, c Int64) Bool
  def is_null(r Int64, c Int64) Bool
  def finish() Void
}
```

```emo
const (R.ok, rows) = conn.query(
  "select id, name from users where age > $1", [postgres.i64(30)])
var r = 0
while r < rows.count() {
  println("row ${rows.i64(r, 0)}: ${rows.text(r, 1)}")
  r = r + 1
}
rows.finish()
```

Targets: `["c"]` — the calls are foreign defs, which the interpreter
refuses (E3009), and libpq must resolve through pkg-config at build
time. Reference: [`docs/stdlib/postgres.md`](stdlib/postgres.md) ·
Demo: `examples/postgres_demo`.

## The `sqlite3` package

The database package: a direct-style binding over SQLite's prepared
statement API. A `Database` is an open connection; a `Statement` is one
compiled SQL text, stepped row by row with typed column reads. It is
the standard library's first native-binding package: the calls are
`foreign def`s against a C shim the package carries, and the manifest's
`link` field names the system sqlite3 library — consuming it is plain
`require`, no `--cclib`.

```emo
def open(path String) Database

class Database {
  def exec(sql String) Void
  def prepare(sql String) Statement
  def last_insert_rowid() Int64
  def changes() Int64
  def close() Void
}

class Statement {
  def bind_int(i Int64, v Int64) Void
  def bind_float(i Int64, v Float64) Void
  def bind_text(i Int64, v String) Void
  def bind_null(i Int64) Void
  def step() Bool
  def reset() Void
  def finalize() Void
  def column_count() Int64
  def column_name(i Int64) String
  def column_int(i Int64) Int64
  def column_float(i Int64) Float64
  def column_text(i Int64) String
  def column_is_null(i Int64) Bool
}
```

Every failing call raises an ordinary Emo exception whose message names
the operation and carries SQLite's own error text; reaching the end of
a statement's rows is a value (`step()` answering `false`), not a
failure. Bind indices are 1-based — they name the `?NNN` parameters in
the SQL text; column indices are 0-based. A NULL column reads as `""`,
with `column_is_null` telling the two apart. Strings cross the C
boundary NUL-terminated, so a String carrying an embedded NUL truncates
there; blobs wait on `Bytes` crossing the FFI.

Targets: `["c"]` — the calls are foreign defs, which the interpreter
refuses (E3009), so `emo run` cannot execute a program that touches the
package; build it with `emo build`. Reference:
[`docs/stdlib/sqlite3.md`](stdlib/sqlite3.md) · Demo:
`examples/sqlite3_demo`.

## The `term` package

Terminal input on stdin: lines, raw mode, decoded key events, and the
terminal's size. It is the standard library's other native-binding
package — the calls are `foreign def`s against a C shim the package
carries — and consuming it is plain `require`.

```emo
def is_tty() Bool
def size() (R, (Int64, Int64))
def read_line() (R, String)
def enable_raw() (R, Int64)
def restore() (R, Int64)
def read_key() (R, (Key, Int64))
```

`read_line` keeps its terminator, like `bufio`, so a blank line and the
end of the input are different answers. `enable_raw` turns off
canonical processing, echo, and keyboard signals; `restore` puts the
saved setting back, and the process's exit path restores it too.
`read_key` answers a `Key` member and a code — a Unicode scalar value
for `Key.char`, `0`–`26` for `Key.ctrl` — decoding the sequences behind
the arrows, Home/End, Insert/Delete, Page Up/Page Down, F1–F12,
Shift-Tab, and Alt+key. Ctrl-C is a key event while raw mode is on, not
a signal.

Targets: `["c"]` — the calls are foreign defs, which the interpreter
refuses (E3009), so `emo run` cannot execute a program that touches the
package; build it with `emo build`. Reference:
[`docs/stdlib/term.md`](stdlib/term.md) · Demo: `examples/term_demo`.

## The `wasm` package

A WebAssembly runtime written in Emo — decoder, validator, and
interpreter, the way wazero is a runtime written in Go. The bar is the
official spec suite and the bar is met: every binary `assert_malformed`
and `assert_invalid` case rejected in the right phase, every
`assert_return` bit-exact across the vendored run corpus.

```emo
wasm.load(data Bytes)                     // (R, Int64) — the module handle
wasm.instantiate(module, imports)         // (R, Int64) — the host table rides here
wasm.call(inst, "fac", [wasm.i64(10)])    // (R, Array[(Int64, Int64)])
wasm.read_memory(inst, ptr, len)          // (R, Bytes)
```

A wasm value rides the runtime's `(kind, bits)` pair — the
constructors (`i32`/`i64`/`f32`/`f64`) build one, the accessors
(`as_i32` and friends) read one back, and the encoding is pinned in the
reference. The host table is `(module, name, fn)` triples whose
closures serve function imports — arguments in, one value out —
resolving ahead of the register namespace and the built-in `spectest`
host, and refusing an entry that names no import (a caller's typo,
surfaced, not carried).

Targets: `["ocaml", "c"]`. Reference:
[`docs/stdlib/wasm.md`](stdlib/wasm.md) · Demo: `examples/wasm_demo`.
