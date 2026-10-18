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
| [`file`](#the-file-package) | whole-file read and write | `ocaml`, `c` |
| [`os`](#the-os-package) | processes, pipes, raw fd IO, directories | `ocaml`, `c` |
| [`bufio`](#the-bufio-package) | buffered readers and writers over any stream | `ocaml`, `c` |
| [`net`](#the-net-package) | TCP, UDP, Unix-domain sockets, DNS, TLS | `ocaml`, `c`, `typescript` |
| [`http`](#the-http-package) | HTTP client and server | `ocaml`, `c`, `typescript` |
| [`json`](#the-json-package) | JSON decode and encode | all five |
| [`yaml`](#the-yaml-package) | YAML 1.2 (core schema) decode and encode | all five |
| [`xml`](#the-xml-package) | XML decode and encode | all five |
| [`base64`](#the-base64-package) | RFC 4648 base64 codec | all five |
| [`csv`](#the-csv-package) | RFC 4180 CSV records, UTF-8 | all five |
| [`float`](#the-float-package) | exact binary64 and decimal-text conversion | all five |
| [`math`](#the-math-package) | float scalars and elementary functions | all five |
| [`plot`](#the-plot-package) | declarative 2D charts rendered to SVG | all five |
| [`slog`](#the-slog-package) | structured logging, logfmt or JSON | `ocaml`, `c`, `typescript` |
| [`sync`](#the-sync-package) | a wait group: let a process wait for N units of work | all five |
| [`sql`](#the-sql-package) | SQL text to an abstract syntax tree | all five |
| [`term`](#the-term-package) | terminal input: lines, raw mode, key events, size | `c` |

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

The process-level surface: process ids, `fork`, `execv`, `waitpid`,
pipes, the working directory, directory listing, and raw (unbuffered,
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

An HTTP client and server in pure Emo on top of `net`. Direct style
throughout; one connection per request, closed after the exchange;
redirects are never followed — a 3xx is a response like any other.

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

The server side is two helpers, both taking the handler as an
attached block:

```emo
http.serve(listener) -> (conn TcpConn) { ... }
http.serve_requests(listener) -> (req HttpRequest) { ... }
def response(status Int64, headers Array[(String, String)], body String) HttpResponse
```

`serve` runs one process per connection and hands the handler the raw
connection; `serve_requests` parses each request into an `HttpRequest`
(`method`, `path`, `headers`, `body`, plus `header(name)`), writes the
handler's `HttpResponse` back, and closes. Most handlers want
`serve_requests`. The listener can come from `net.listen`, or from
`net.listen_tls`/`net.listen_tls_with` to serve the same handler over
HTTPS.

```emo
require "http"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8902)

http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

Targets: `["ocaml", "c", "typescript"]` (it builds on `net`, which its own
manifest pins). On `c` it inherits `net`'s coverage: TCP and TLS.
Reference:
[`docs/stdlib/http.md`](stdlib/http.md) · Demos:
`examples/http_roundtrip`, `examples/https_roundtrip`.

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

The elementary float functions: the scalars, `sqrt`, and the
transcendentals the rest of the standard library builds on. Pure Emo
over the scalar operations all five targets share, with fixed-order
series, so each answers byte-for-byte.

```emo
const e = 2.718281828459045
const pi = 3.141592653589793

def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def exp(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
```

`exp` range-reduces to `2^k * exp(r)` with a short Taylor series; `log`
uses `log(x) = e*ln2 + log(m)` with the atanh series. Out-of-domain
arguments are contract violations, not values — `log` of a non-positive
number and `exp`'s overflow raise, because the beam target's Erlang
floats cannot represent NaN or infinity at all, so returning one is not
an option. The opt-in native fast path lives under distinct `*_native`
names (`exp_native`, `log_native`, `log10_native`, `pow_native`) and is
pinned to `c`/`ocaml`; off those targets the definitions are inert and
only a call refuses, so the package still imports everywhere.

Targets: all five for the plain functions; the `*_native` functions run
on `c` and `ocaml`. Reference: [`docs/stdlib/math.md`](stdlib/math.md) ·
Demos: `examples/math_demo`, `examples/math_native`.

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

The `plot.mark` submodule carries the marks; T0 ships the bar mark,
`plot.mark.bar(labels, values)`, refined through `plot.mark.bar_style()`.
Colors
are `(Int64, Int64, Int64)` sRGB triples, 0–255 per channel. Every label
is an SVG `<text>` element, so the package carries no font engine.

`svg` returns the document; writing it to a file is the caller's step,
since the package runs on all five targets while file IO is native-only.

Targets: all five. T0 is the bar mark with linear axes and SVG output;
log scales, faceting, legends, and the other mark families are reserved.
Reference: [`docs/stdlib/plot.md`](stdlib/plot.md) · Demo:
`examples/plot_demo`.

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

Targets: `["ocaml", "c", "typescript"]`. Reference:
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

## The `sql` package

The SQL parser: SQL text in, an abstract syntax tree out. Pure Emo
over the shared runtimes — a parsed tree is one class per grammar node
(`Select` statements, `Expr` expressions, `TableRef` table references),
each answering `to_string()` with the canonical rendering.

```emo
def parse(text String) (R, Stmt)
```

`SELECT` end to end — distinct select lists, joins with `ON`/`USING`,
`WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, `OFFSET` — and the
full expression grammar underneath: literals, parameters (`?`, `?NNN`),
qualified columns, calls, `CAST`, `CASE`, `EXISTS`, subqueries, and the
operator tower with standard precedence. Malformed input is the value
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
