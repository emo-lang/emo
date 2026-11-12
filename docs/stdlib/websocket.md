# The `websocket` package

The two WebSocket halves (RFC 6455) in pure Emo on top of `net`: the
client dials with `connect`, the server takes an accepted connection
with `accept`, and both sides meet on one `Websocket` whose unit of
exchange is one text message. Frames are the transport's business and
stay under this roof — the client masks what she sends and refuses
masked frames on the way in, the server mirrors both rules, pings are
answered with their own payload, unsolicited pongs are skipped, a
close frame is answered and ends the message stream, and a message the
peer fragmented across frames is joined before `recv_message` answers.

Targets: `["ocaml", "c", "typescript"]` (it builds on `net`, `base64`,
`crypto` for the handshake's SHA-1, and `rand` for the frame masks).
Reference: [`docs/stdlib/websocket.md`](stdlib/websocket.md) · Demo:
`examples/websocket_demo`.

## Using the package

`require "websocket"`, with the package and its transitive deps pinned
in your manifest:

```emo
deps {
  "net" = "0.1.0"
  "websocket" = "0.1.0"
}
```

## Dialling and taking

```emo
websocket.connect(host, port, path, timeout)          // (R, Websocket) — verifies the accept
websocket.connect_insecure(host, port, path, timeout) // (R, Websocket) — skips that one check
websocket.accept(conn)                                // (R, Websocket) — the server's door
```

`connect` dials over TCP, sends the upgrade, and verifies the accept
header against the key it sent — the only proof the peer speaks this
protocol. The path must start with `/` (a caller's mistake otherwise,
and it raises). `connect_insecure` is the same dial with that one
check skipped, named for the peers whose accept does not derive from
the client's key at all — playwright's `run-server` ships an accept
its own client never validates — tls_connect_insecure's rule: the
name says what is not checked. `accept` reads the upgrade request and refuses it
unless it asks for the upgrade, names version 13, and carries the key;
then it answers `101` and hands back the server's side. The timeout
bounds the connect and each later exchange (net's per-operation
deadline); `0.0` waits indefinitely.

## The message surface

```emo
ws.send_text(data)     // (R, Websocket) — one text message out
ws.recv_message()      // (R, String) — the next message in, fragments joined
ws.set_timeout(seconds) // per-operation deadline from here on
ws.close()             // (R, Websocket) — one close frame, then the socket
```

`recv_message` handles the control frames it meets along the way: a
ping is answered with its own payload, an unsolicited pong is skipped,
and a close frame is answered, the socket closed, and the end named in
the reason. After the peer's close has been read, `close` answers with
the socket's own refusal — the same end, read twice. Binary frames are
refused: every protocol this package serves speaks text.

## Errors

The standard library's three-way split. A refused handshake, a bare
frame where a masked one was required, an exceeded deadline, a peer
gone — each is the value `(R.error, reason)` with the reason stating
exactly what failed, under the `websocket:` prefix for the reasons the
package finds itself and the net reasons for the transport's own. A
caller's mistake — a path without the leading `/` — raises.

## Example

One program, both halves, on loopback — the shape
`examples/websocket_demo` pins byte for byte:

```emo
const (R.ok, listener) = net.listen("127.0.0.1", 0)
do echo_serve(listener)                  // accept, then echo until the peer closes

case websocket.connect("127.0.0.1", listener.port(), "/", 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, ws)     -> {
    case ws.send_text("hello 回环") {
      (R.error, why) -> { println("send failed: ${why}") }
      (R.ok, _)      -> {
        case ws.recv_message() {
          (R.error, why) -> { println("recv failed: ${why}") }
          (R.ok, back)   -> { println(back) }
        }
      }
    }
  }
}
```

## Limitations

- Three targets: the same gate `net` rides (WASI preview1 has no
  sockets). On `typescript` the sockets are Node's; the frame paths
  are the same Emo code on every target, byte for byte.
- Text frames only. A binary frame is refused by name.
- No extensions, no permessage-deflate, no subprotocols.
- A peer that fragments a message into more than 4096 pieces is
  refused rather than ridden.
- The handshake walks at most 200 header lines in either direction.
