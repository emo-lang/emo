# The `net` Package

The standard library's socket package: TCP, UDP, Unix-domain sockets, DNS,
and TLS. It is a thin, readable layer of Emo source over the runtime's
network builtins — every function here is one call to a builtin, and the
semantics (timeouts, EOF, errors) are the runtime's. The package declares
the `ocaml`, `c`, and `typescript` targets (`targets = ["ocaml", "c",
"typescript"]`); dependency resolution refuses it on every other target.
Coverage differs by target: `ocaml` and `typescript` implement the whole
surface, while `c` implements TCP only — UDP, Unix-domain sockets,
`net.resolve`, and TLS are refused at runtime there.

Networking is **direct style**: a blocking call reads like any other
function call, and the scheduler parks the process while the socket is
busy. There is no `async`/`await` and no callback registration. Every
failure — a refused connection, an unresolvable name, an exceeded
deadline, a closed socket — comes back as `(R.error, reason)`: the
reason a String naming the operation, the peer, and what went wrong.
Match it; don't let it crash the process.

## Using the package

```emo
require "net"
```

The standard library ships with the compiler: `require "net"` needs no
`package.emo` entry. The package declares the `ocaml`, `c`, and
`typescript` targets.

## Functions

```emo
net.resolve(host)                                   // (R, Array[String])
net.connect(host, port, timeout)                    // (R, TcpConn)
net.listen(host, port)                              // (R, TcpListener)
net.connect_unix(path, timeout)                     // (R, TcpConn)
net.listen_unix(path)                               // (R, TcpListener)
net.tls_connect(host, port, timeout)                // (R, TcpConn)
net.tls_connect_insecure(host, port, timeout)       // (R, TcpConn)
net.listen_tls(host, port, cert_path, key_path)     // (R, TcpListener)
net.udp_bind(host, port)                            // (R, UdpSocket)
```

- `net.resolve(host)` resolves a name to its IP addresses as strings;
  when DNS yields nothing the answer is the error tuple
  (``cannot resolve host `...` ``). Numeric addresses resolve to
  themselves.
- `net.connect(host, port, timeout)` resolves the host and connects,
  answering the `TcpConn`. `timeout` is in seconds; `0.0` waits
  indefinitely. A refused connection is the error tuple
  (`connection refused to host:port`).
- `net.listen(host, port)` binds and listens, answering a
  `TcpListener`. Port `0` asks the kernel for a free port; read it
  back with `listener.port()`.
- `net.connect_unix(path, timeout)` and `net.listen_unix(path)` are the
  Unix-domain pair; a Unix listener has no port.
- `net.tls_connect` connects with TLS and **verifies the peer certificate
  against the system trust store** — a self-signed certificate fails the
  handshake, as the error tuple. `net.tls_connect_insecure` skips
  verification; it is the explicit, visibly dangerous opt-out, meant
  for tests and self-signed development setups.
- `net.listen_tls(host, port, cert_path, key_path)` serves TLS from a PEM
  certificate/key pair; unloadable certificates fail with a precise
  reason (``cannot load the TLS certificate for ... ``).
- `net.udp_bind(host, port)` binds a datagram socket; port `0` picks a free
  one.

## Connections: `TcpConn`

```emo
conn.read_line()          // (R, String) — one line, without the terminator
conn.read_exactly(n)      // (R, String) — exactly n bytes
conn.read_all()           // (R, String) — everything until the peer closes
conn.write(data)          // (R, TcpConn) — chain through the (R.ok, conn)
conn.close()              // (R, TcpConn)
conn.set_timeout(seconds) // TcpConn — bounds the operations that follow
```

- **EOF is never a silent partial result.** `read_line` strips the `\n`
  (and a `\r` before it); a clean close at a line boundary returns
  `(R.ok, "")`, but a close **mid-line is the error tuple**
  (`the connection to ... closed mid-line`). `read_exactly(n)` fails
  with its reason when the peer closes early (`closed after M of N
  bytes`). `read_all` is the one read that treats EOF as normal: it
  delivers everything that arrived, empty included.
- `write(data)` writes the whole string (bytes, not characters — Emo
  strings are byte strings) and answers the connection, so writes
  chain through the destructured `(R.ok, conn)`. A graceful `close()`
  delivers pending writes first.
- `set_timeout(seconds)` sets a **per-operation** deadline for the reads
  and writes that follow: the budget is computed when each operation
  starts, and a multi-step read honors one budget. `0.0` — the default —
  means no timeout; a negative value is an error. An exceeded deadline
  is the error tuple (`timed out ...`).

## Listeners: `TcpListener`

```emo
listener.accept()           // (R, TcpConn) — the next connection
listener.port()             // Int64 — the bound port
listener.close()            // (R, TcpListener)
listener.set_timeout(seconds)
```

`accept()` parks until a connection arrives. `port()` on a **Unix-domain
listener is an error** (`a unix-domain listener (...) has no port`) — it
has no port to report. `set_timeout` bounds `accept()` the same way
connection timeouts bound reads.

## Datagrams: `UdpSocket`

```emo
socket.send_to(host, port, data)  // (R, UdpSocket)
socket.recv_from()                // (R, (String, String, Int64)) — data, host, port
socket.port()                     // Int64
socket.close()                    // (R, UdpSocket)
socket.set_timeout(seconds)
```

`recv_from()` waits for one datagram and answers it as
`(R.ok, (data, host, port))` — destructure it twice, the outer `case`
for the failure, the inner tuple for the payload. `send_to` resolves
the host by name on every call.

## Examples

A TCP echo round-trip in one program — the server runs in its own process
(`do`), the client talks to it. Failures destructure; the happy paths
ride `(R.ok, ...)`:

```emo
require "net"

def echo_once(listener TcpListener) Int64 {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("echo: ${line}\n")
          conn.close()
        }
      }
    }
  }
  return 0
}

const (R.ok, listener) = net.listen("127.0.0.1", 0)
do echo_once(listener)

case net.connect("127.0.0.1", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.set_timeout(5.0)
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }  // echo: hello
    }
    conn.close()
  }
}
```

UDP, both ends on loopback:

```emo
require "net"

const (R.ok, a) = net.udp_bind("127.0.0.1", 0)
const (R.ok, b) = net.udp_bind("127.0.0.1", 0)

a.send_to("127.0.0.1", b.port(), "ping")
case b.recv_from() {
  (R.error, why)       -> { println("recv failed: ${why}") }
  (R.ok, (data, host, port)) -> {
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
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      conn.write("secure: hello\n")
      conn.close()
    }
  }
  return 0
}

const (R.ok, listener) = net.listen_tls("127.0.0.1", 0, "tls-cert.pem", "tls-key.pem")
do serve(listener)

case net.tls_connect_insecure("localhost", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }  // secure: hello
    }
    conn.close()
  }
}
```

## Limitations

- **Three targets** — `targets = ["ocaml", "c", "typescript"]`; wasm, BEAM,
  and riscv64 builds are refused at resolution time. The `c` target
  implements TCP only; the other operations are refused at runtime there.
- **DNS is forward-only.** On `ocaml` it runs inline in the scheduler loop —
  `getaddrinfo` blocks the loop for its duration; on `typescript` Node's
  resolver runs on the event loop. There is no reverse lookup.
- **The TLS reason text is the library's** — OpenSSL's on `ocaml`, Node's on
  `typescript`; verification itself is on by default on both.
- **UDP is unconnected send/receive only** — no `connect`ed datagrams, no
  multicast, no broadcast helpers.
- **No raw sockets, no socket options** beyond what the operations above
  expose.
