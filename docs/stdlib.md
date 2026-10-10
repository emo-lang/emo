# The Standard Library

The standard library is a set of packages the compiler ships with:
they live in the bundled registry, resolve like any other dependency,
and are pinned in `package.emo` like any other dependency. Using one
is `require`:

```emo
require "json"
```

with `json = "0.1.0"` (the exact version) under `deps` in the
manifest. A `require` without the matching pin is a compile error, and
a package whose `targets` do not include the build's target is
refused at resolution time — the format packages run everywhere, the
systems and network packages declare the targets with a Unix-shaped
host.

Two conventions hold across every package:

- **Errors are exceptions.** Every failing call raises an ordinary
  Emo exception whose message states exactly what failed — no error
  codes, no nil. The message always begins with the name of the
  package that raises it and a colon — `json: expected array element
  at byte 3`, `os: open_write notes.txt: Permission denied` — so an
  uncaught exception names its source (`file` errors surface as `os:`
  because the shared os runtime performs the syscall); structured
  context (offsets, paths, URLs) goes into the exception's optional
  `data` Map rather than being concatenated into the message. End of
  stream is not an error: the empty string ends a stream.
- **Pure Emo where the language suffices.** The format packages and
  the codec are written in Emo over the shared runtimes, so every
  target they declare answers byte-for-byte identically. Only `os`
  (and the packages that build on it) dispatch to runtime built-ins
  backed by POSIX, and only they are native-only.

The packages:

| Package | What it gives you | Targets |
|---|---|---|
| [`file`](#the-file-package) | whole-file read and write | `ocaml`, `c` |
| [`os`](#the-os-package) | processes, pipes, raw fd IO, directories | `ocaml`, `c` |
| [`bufio`](#the-bufio-package) | buffered readers and writers over any stream | `ocaml`, `c` |
| [`net`](#the-net-package) | TCP, UDP, Unix-domain sockets, DNS, TLS | `ocaml`, `c` |
| [`http`](#the-http-package) | HTTP client and server | `ocaml`, `c` |
| [`json`](#the-json-package) | JSON decode and encode | all five |
| [`yaml`](#the-yaml-package) | YAML 1.2 (core schema) decode and encode | all five |
| [`xml`](#the-xml-package) | XML decode and encode | all five |
| [`base64`](#the-base64-package) | RFC 4648 base64 codec | all five |
| [`slog`](#the-slog-package) | structured logging, logfmt or JSON | `ocaml`, `c`, `typescript` |
| [`sync`](#the-sync-package) | a wait group: let a process wait for N units of work | all five |

All packages are version 0.1.0. Each has a full API reference under
[`docs/stdlib/`](stdlib/) (Chinese translations under
[`docs/zh-CN/stdlib/`](zh-CN/stdlib/)) and a runnable demo under
`examples/`.

## The `file` package

Direct-style whole-file IO on the scheduler: read a file in one call,
write one in another. Paths are taken as given (relative paths
resolve against the process's working directory).

```emo
def read(path String) String
def write(path String, contents String) Int64
```

`read` answers the file's bytes; a missing or unreadable file raises.
`write` creates or truncates, writes every byte, and answers how many
were written. For anything streamed, buffered, or appended, use `os`
and `bufio` underneath — `file` is the one-shot shape.

```emo
require "file"

file.write("notes.txt", "hello from disk\n")
println(file.read("notes.txt"))
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
def fork() Int64
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void

def pipe() (Int64, Int64)

def open_read(path String) Int64
def open_write(path String) Int64
def open_append(path String) Int64
def read(fd Int64, n Int64) String
def write(fd Int64, data String) Int64
def close(fd Int64) Int64

def list_dir(path String) Array[String]
def mkdir(path String) Int64
def rmdir(path String) Int64
def unlink(path String) Int64
def rename(old_path String, new_path String) Int64
def getcwd() String
def chdir(path String) Int64
```

`fork()` returns twice — `0` in the child, the child's pid in the
parent — and the child leaves through `_exit`. `waitpid(pid)` answers
`(pid, status)` with the kernel's raw 16-bit status word, decoded by
the `wait_exited` / `wait_exit_code` / `wait_signaled` /
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

Targets: `["ocaml", "c"]` (it builds on `os`, which the manifest
pins alongside it). Reference:
[`docs/stdlib/bufio.md`](stdlib/bufio.md) · Demo:
`examples/bufio_demo`.

## The `net` package

Sockets: TCP, UDP, Unix-domain sockets, DNS, and TLS — a thin,
readable layer of Emo source over the runtime's network builtins.
Direct style: a blocking call reads like any other function call, and
the scheduler parks the process while the socket is busy. Every
failure — refused connection, unresolvable name, exceeded deadline —
raises with the peer, the operation, and the reason.

```emo
def resolve(host String) Array[String]
def connect(host String, port Int64, timeout Float64) TcpConn
def listen(host String, port Int64) TcpListener
def connect_unix(path String, timeout Float64) TcpConn
def listen_unix(path String) TcpListener
def tls_connect(host String, port Int64, timeout Float64) TcpConn
def tls_connect_insecure(host String, port Int64, timeout Float64) TcpConn
def listen_tls(host String, port Int64, cert_path String, key_path String) TcpListener
def udp_bind(host String, port Int64) UdpSocket
```

Timeouts are seconds; `0.0` waits indefinitely. `tls_connect` verifies
the peer certificate against the system trust store;
`tls_connect_insecure` is the explicit, visibly dangerous opt-out.

```emo
conn.read_line()          // String — one line, without the terminator
conn.read_exactly(n)      // String — exactly n bytes
conn.read_all()           // String — everything until the peer closes
conn.write(data)          // TcpConn — returns itself, so writes chain
conn.close()              // TcpConn
conn.set_timeout(seconds) // TcpConn

listener.accept()         // TcpConn — parks until a connection arrives
listener.port()           // Int64 — the bound port
listener.close()          // TcpListener
listener.set_timeout(seconds)

socket.send_to(host, port, data) // UdpSocket — returns itself
socket.recv_from()               // (String, String, Int64) — data, host, port
socket.port()                    // Int64
socket.close()                   // UdpSocket
socket.set_timeout(seconds)
```

EOF is never a silent partial result: `read_exactly` raises when the
peer closes early, a close mid-line is an error, and `read_all` is
the one read that treats EOF as normal. A Unix-domain listener has no
port — `port()` on one is an error.

Targets: `["ocaml", "c"]`. Reference:
[`docs/stdlib/net.md`](stdlib/net.md) · Demo: `examples/tcp_echo`.

## The `http` package

An HTTP client and server in pure Emo on top of `net`. Direct style
throughout; one connection per request, closed after the exchange;
redirects are never followed — a 3xx is a response like any other.

```emo
def get(url String) HttpResponse
def post(url String, body String) HttpResponse
def put(url String, body String) HttpResponse
def delete(url String) HttpResponse
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) HttpResponse
```

The URL must carry an explicit `http://` or `https://` scheme;
`https` rides `net.tls_connect` — verification on. The response:

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
`serve_requests`.

```emo
require "http"
require "net"

const listener = net.listen("127.0.0.1", 8902)

http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

Targets: `["ocaml", "c"]` (it pins `net` alongside it). Reference:
[`docs/stdlib/http.md`](stdlib/http.md) · Demo:
`examples/http_roundtrip`.

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

Decode raises with the byte offset on every malformation; nesting
deeper than 512 raises rather than betting the stack. Floats encode
in the shortest round-trip form and stay visibly floats (`1.0`, never
`1`), so encode → decode → encode is the identity, value and kind.

Targets: all five — byte-identical answers on every one. Reference:
[`docs/stdlib/json.md`](stdlib/json.md) · Demos: `examples/json_demo`,
`examples/json_edge`.

## The `yaml` package

The YAML reader and writer: YAML 1.2's core schema decoded into a
`Yaml` value tree that mirrors the json package's design, and encoded
back in block style. The packages are independent — requiring yaml
does not require json.

```emo
def decode(text String) Yaml
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
aliases, tags, multi-document input, and tabs in indentation raise
with the byte offset.

Targets: all five. Reference: [`docs/stdlib/yaml.md`](stdlib/yaml.md)
· Demos: `examples/yaml_demo`, `examples/yaml_edge`.

## The `xml` package

The XML reader and writer: well-formed XML decoded into a `Xml`
value tree and encoded back. XML is all text — nothing is coerced to
numbers or booleans, and all text children are kept, so
`encode(decode(x))` reproduces the tree.

```emo
def decode(text String) Xml
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
everywhere. Every failure raises with the byte offset.

Targets: all five. Reference: [`docs/stdlib/xml.md`](stdlib/xml.md)
· Demos: `examples/xml_demo`, `examples/xml_edge`.

## The `base64` package

The RFC 4648 base64 codec: bytes in, padded base64 text out, and
back — pure Emo over the shared runtimes, so every target answers
with the same bytes.

```emo
def encode(data String) String
def decode(text String) String
```

`encode` always emits the standard alphabet with `=` padding.
`decode` accepts exactly what the encoder produces: the standard
alphabet only, padding only in the final quantum, and the padding
bits the RFC requires to be zero really must be zero — `QR==` is a
mistake, not a synonym of `QQ==`. No whitespace tolerance and no
line-wrap acceptance; every rejection raises with the offending byte
offset.

Targets: all five. Reference:
[`docs/stdlib/base64.md`](stdlib/base64.md) · Demo:
`examples/base64_demo`.

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
def wait_group(n Int64) Pid
def done(wg Pid) Void
def wait(wg Pid) Void
def stop(wg Pid) Void
```

`wait_group` starts a countdown of `n` units and answers the group's
pid; `done` announces one finished unit; `wait` blocks until the count
drains and answers immediately once it has; `stop` ends the counter
process. Several processes may `wait` on one group, and each is woken.
The count is set once and only goes down: a wait group is single-use.
A `done` past the count raises at its caller rather than vanishing; a
`wait` parked when `stop` lands raises instead of hanging.

```emo
require "sync"

const wg = sync.wait_group(3)  // three units of work ahead
do worker(wg)                  // ... each ends with sync.done(wg)
do worker(wg)
do worker(wg)
sync.wait(wg)                  // returns with the third done
sync.stop(wg)
```

Every wait-group message on the wire is a tuple tagged `"sync"` — the
package name — so the group's traffic never collides with an
application's own messages.

Targets: `["ocaml", "c", "typescript", "wasm", "beam"]`. Reference:
[`docs/stdlib/sync.md`](stdlib/sync.md) · Demo:
`examples/sync_demo`.
