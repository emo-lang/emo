# The `net` Package

The standard library's socket package: TCP, UDP, Unix-domain sockets, DNS,
and TLS. It is a thin, readable layer of Emo source over the runtime's
network builtins — every function here is one call to a builtin, and the
semantics (timeouts, EOF, errors) are the runtime's. The package is
**ocaml- and c-only**: its manifest declares `targets = ["ocaml", "c"]`, and
dependency resolution refuses it on every other target.

Networking is **direct style**: a blocking call reads like any other
function call, and the scheduler parks the process while the socket is
busy. There is no `async`/`await` and no callback registration. Every
failure — a refused connection, an unresolvable name, an exceeded deadline,
a closed socket — raises an ordinary Emo exception whose message names the
peer, the operation, and the reason.

## Using the package

```emo
require "net"
```

The `require` pairs strictly with the manifest — `net` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    net = "0.1.0"
  }
}
```

## Functions

```emo
net.resolve(host)                                   // Array[String]
net.connect(host, port, timeout)                    // TcpConn
net.listen(host, port)                              // TcpListener
net.connect_unix(path, timeout)                     // TcpConn
net.listen_unix(path)                               // TcpListener
net.tls_connect(host, port, timeout)                // TcpConn
net.tls_connect_insecure(host, port, timeout)       // TcpConn
net.listen_tls(host, port, cert_path, key_path)     // TcpListener
net.udp_bind(host, port)                            // UdpSocket
```

- `net.resolve(host)` resolves a name to its IP addresses as strings, and
  raises `` cannot resolve host `...` `` when DNS yields nothing. Numeric
  addresses resolve to themselves.
- `net.connect(host, port, timeout)` resolves the host and connects,
  returning a `TcpConn`. `timeout` is in seconds; `0.0` waits indefinitely.
  A refused connection raises `connection refused to host:port`.
- `net.listen(host, port)` binds and listens, returning a `TcpListener`.
  Port `0` asks the kernel for a free port; read it back with
  `listener.port()`.
- `net.connect_unix(path, timeout)` and `net.listen_unix(path)` are the
  Unix-domain pair; a Unix listener has no port.
- `net.tls_connect` connects with TLS and **verifies the peer certificate
  against the system trust store** — a self-signed certificate fails the
  handshake, closed. `net.tls_connect_insecure` skips verification; it is
  the explicit, visibly dangerous opt-out, meant for tests and
  self-signed development setups.
- `net.listen_tls(host, port, cert_path, key_path)` serves TLS from a PEM
  certificate/key pair; unloadable certificates raise a precise error
  (`` cannot load the TLS certificate for ... ``).
- `net.udp_bind(host, port)` binds a datagram socket; port `0` picks a free
  one.

## Connections: `TcpConn`

```emo
conn.read_line()          // String — one line, without the terminator
conn.read_exactly(n)      // String — exactly n bytes
conn.read_all()           // String — everything until the peer closes
conn.write(data)          // TcpConn — returns itself, so writes chain
conn.close()              // TcpConn
conn.set_timeout(seconds) // TcpConn — bounds the operations that follow
```

- **EOF is never a silent partial result.** `read_line` strips the `\n`
  (and a `\r` before it); a clean close at a line boundary returns `""`,
  but a close **mid-line is an error**
  (`the connection to ... closed mid-line`). `read_exactly(n)` raises when
  the peer closes early (`closed after M of N bytes`). `read_all` is the
  one read that treats EOF as normal: it delivers everything that arrived,
  empty included.
- `write(data)` writes the whole string (bytes, not characters — Emo
  strings are byte strings) and returns the connection, so
  `conn.write(a).write(b)` chains. A graceful `close()` delivers pending
  writes first.
- `set_timeout(seconds)` sets a **per-operation** deadline for the reads
  and writes that follow: the budget is computed when each operation
  starts, and a multi-step read honors one budget. `0.0` — the default —
  means no timeout; a negative value is an error. An exceeded deadline
  raises `timed out ...`.

## Listeners: `TcpListener`

```emo
listener.accept()           // TcpConn — the next connection
listener.port()             // Int64 — the bound port
listener.close()            // TcpListener
listener.set_timeout(seconds)
```

`accept()` parks until a connection arrives. `port()` on a **Unix-domain
listener is an error** (`a unix-domain listener (...) has no port`) — it
has no port to report. `set_timeout` bounds `accept()` the same way
connection timeouts bound reads.

## Datagrams: `UdpSocket`

```emo
socket.send_to(host, port, data)  // UdpSocket — returns itself
socket.recv_from()                // (String, String, Int64) — data, host, port
socket.port()                     // Int64
socket.close()                    // UdpSocket
socket.set_timeout(seconds)
```

`recv_from()` waits for one datagram and returns it as a
`(data, host, port)` tuple — destructure it with `case`. `send_to`
resolves the host by name on every call.

## Examples

A TCP echo round-trip in one program — the server runs in its own process
(`do`), the client talks to it:

```emo
require "net"

def echo_once(listener TcpListener) Int64 {
  const conn = listener.accept()
  conn.write("echo: " + conn.read_line() + "\n")
  conn.close()
  return 0
}

const listener = net.listen("127.0.0.1", 0)
do echo_once(listener)

const conn = net.connect("127.0.0.1", listener.port(), 5.0)
conn.set_timeout(5.0)
conn.write("hello\n")
println(conn.read_line())  // echo: hello
conn.close()
```

UDP, both ends on loopback:

```emo
require "net"

const a = net.udp_bind("127.0.0.1", 0)
const b = net.udp_bind("127.0.0.1", 0)

a.send_to("127.0.0.1", b.port(), "ping")
case b.recv_from() {
  (data, host, port) -> {
    println(data + " from " + host + ":" + port.to_string())
  }
}
b.close()
a.close()
```

TLS against a self-signed certificate (the development setup — production
clients use `net.tls_connect`, which verifies):

```emo
require "net"

def serve(listener TcpListener) Int64 {
  const conn = listener.accept()
  conn.write("secure: " + conn.read_line() + "\n")
  conn.close()
  return 0
}

const listener = net.listen_tls("127.0.0.1", 0, "tls-cert.pem", "tls-key.pem")
do serve(listener)

const conn = net.tls_connect_insecure("localhost", listener.port(), 5.0)
conn.write("hello\n")
println(conn.read_line())  // secure: hello
conn.close()
```

## Limitations

- **OCaml and c targets only** — `targets = ["ocaml", "c"]`; wasm, TypeScript, and
  BEAM builds are refused at resolution time.
- **DNS is forward-only and runs inline in the scheduler loop** —
  `getaddrinfo` blocks the loop for its duration; there is no reverse
  lookup.
- **UDP is unconnected send/receive only** — no `connect`ed datagrams, no
  multicast, no broadcast helpers.
- **No raw sockets, no socket options** beyond what the operations above
  expose.
