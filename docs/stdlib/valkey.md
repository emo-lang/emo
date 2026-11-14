# The `valkey` Package

The standard library's Valkey client, written in pure Emo on top of the
[`net`](stdlib/net.md) package. Direct style throughout: a command reads
like any other function call, and the scheduler parks the process while
the socket is busy. The wire is RESP2 — every request is the array of
bulk strings the protocol names, every reply is one of the reply kinds
the protocol answers with. The package declares the `ocaml`, `c`, and
`typescript` targets (`targets = ["ocaml", "c", "typescript"]`);
dependency resolution refuses it on every other target.

One connection, one command, one reply. The client writes the request
and reads the one reply the command names — no pipelining, no pooling,
no reconnection to hide a dropped socket. What the server says comes
back as values, and what the wire breaks comes back as values too.

## Using the package

```emo
require "valkey"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "valkey"` needs `"valkey" = "0.1.0"`
in the manifest's `deps` block; the `net` package it builds on comes
through `valkey`'s own manifest. The package declares the `ocaml`, `c`,
and `typescript` targets.

## Connecting

```emo
valkey.connect(host, port, timeout)                    // (R, Valkey)
valkey.connect_unix(path, timeout)                     // (R, Valkey)
valkey.connect_tls(host, port, timeout)                // (R, Valkey)
valkey.connect_tls_insecure(host, port, timeout)       // (R, Valkey)
```

- `connect` dials TCP and answers the `Valkey` handle; `connect_unix`
  dials a Unix-domain socket (a server started with
  `unixsocket /path`).
- `connect_tls` rides `net.tls_connect` — certificate verification
  against the system trust store, on. `connect_tls_insecure` is the
  explicit, visibly dangerous opt-out for self-signed setups, the
  same door `net` names.
- `timeout` is in seconds and bounds **each exchange**: the write and
  the reads that follow each get the budget (`net`'s per-operation
  deadline), so a command's worst case is a small multiple of the
  value. `0.0` waits indefinitely; a negative value is the error
  tuple before any socket opens.

Every failure — refused connection, unresolvable name, TLS refusal —
is the error tuple carrying `net`'s own reason.

## Commands

The typed doors, one method per command. Each answers `(R, …)`: the
value the command's contract names, the null reply where the answer
can be absence, or the error tuple. Command names ride uppercase
(`GET`), so the wire shows the protocol's own spelling:

```emo
// connection
v.ping()                          // (R, String) — "PONG", or the echo
v.echo(msg)                       // (R, String)
v.auth(password)                  // (R, String) — "OK"
v.select(db)                      // (R, String) — "OK"
v.command(args)                   // (R, Reply) — any command, raw reply
v.set_timeout(seconds)            // Void — bounds the exchanges that follow
v.close()                         // (R, Valkey)

// strings
v.get(key)                        // (R, Reply) — bulk, or the null reply
v.set(key, value)                 // (R, String) — "OK"
v.set_ex(key, value, seconds)     // (R, String) — "OK", the EX form
v.setnx(key, value)               // (R, Bool)
v.mset(pairs)                     // (R, String) — pairs Array[(String, String)]
v.mget(keys)                      // (R, Array[Reply]) — nulls inside
v.append(key, value)              // (R, Int64) — the new byte length
v.strlen(key)                     // (R, Int64) — the byte length
v.getrange(key, start, stop)      // (R, String)
v.incr(key)                       // (R, Int64)
v.decr(key)                       // (R, Int64)
v.incr_by(key, n)                 // (R, Int64)
v.decr_by(key, n)                 // (R, Int64)

// keys
v.del(keys)                       // (R, Int64) — how many were removed
v.exists(keys)                    // (R, Int64) — how many are present
v.keys(pattern)                   // (R, Array[String])
v.type(key)                       // (R, String) — "string", "none", …
v.rename(key, new_key)            // (R, String) — "OK"
v.expire(key, seconds)            // (R, Bool)
v.ttl(key)                        // (R, Int64) — seconds, -1, or -2
v.persist(key)                    // (R, Bool)
v.dbsize()                        // (R, Int64)

// hashes
v.hset(key, field, value)         // (R, Int64) — 1 new, 0 replaced
v.hget(key, field)                // (R, Reply) — bulk, or the null reply
v.hdel(key, fields)               // (R, Int64)
v.hexists(key, field)             // (R, Bool)
v.hlen(key)                       // (R, Int64)
v.hkeys(key)                      // (R, Array[String])
v.hvals(key)                      // (R, Array[String])
v.hgetall(key)                    // (R, Array[(String, String)])

// lists
v.lpush(key, values)              // (R, Int64) — the new length
v.rpush(key, values)              // (R, Int64)
v.lpop(key)                       // (R, Reply) — head, or the null reply
v.rpop(key)                       // (R, Reply) — tail, or the null reply
v.lrange(key, start, stop)        // (R, Array[String])
v.llen(key)                       // (R, Int64)
v.lindex(key, index)              // (R, Reply) — or the null reply
v.lset(key, index, value)         // (R, String) — "OK"

// sets
v.sadd(key, members)              // (R, Int64) — how many were added
v.srem(key, members)              // (R, Int64) — how many were removed
v.smembers(key)                   // (R, Array[String])
v.sismember(key, member)          // (R, Bool)
v.scard(key)                      // (R, Int64)
```

A missing key is not an error. The doors that can answer nothing —
`get`, `hget`, `lpop`, `rpop`, `lindex`, and `mget`'s elements —
return the reply tree, and absence reads through `is_null?()`. A
server error reply (`-WRONGTYPE …`, `-ERR …`) is the error tuple,
`"valkey: "` in front of the server's text, the error code riding
inside the reason where a match can find it.

## Replies: the `Reply` tree

`v.command(args)` and the absence-carrying doors answer a `Reply` —
an interface over one class per RESP2 kind a client can receive. The
simple and the bulk string are one kind: the distinction the wire
draws is not one a caller needs.

```emo
enum ReplyKind { rnull, rstring, rint, rarray }

interface Reply {
  def kind() ReplyKind
  def is_null?() Bool
  def as_string() String          // rstring only; the wrong kind raises
  def as_int() Int64              // rint only
  def as_array() Array[Reply]     // rarray only
}
```

`kind()` and `is_null?()` discriminate without guessing; the `as_*`
accessors are the caller's assertions — `get(key).as_string()` is
correct code only when the key holds a string — and a failed
assertion raises, json's rule. Containers narrow through `is()` into
the concrete classes (`valkey.ReplyArray`), where `as_array()` lists
the elements and the fields ride along.

```emo
case v.command(["OBJECT", "ENCODING", "greeting"]) {
  (R.error, why)      then { println("refused: ${why}") }
  (R.ok, reply)       then {
    if reply.is_null?() {
      println("nothing there")
    } else {
      println(reply.as_string())   // embstr
    }
  }
}
```

## Errors

The split is the standard library's own. Expected failures are
values; violations raise:

- **The server refuses a command** — `-WRONGTYPE`, `-ERR unknown
  command`, `-ERR wrong number of arguments`, `-MOVED`, anything the
  peer answers with `-` — is `(R.error, "valkey: " + the server's
  text)`.
- **The wire breaks** — refused connection, a deadline exceeded, the
  server closing mid-reply, a reply the protocol cannot parse (an
  unknown type byte, a malformed count, a bulk without its
  terminator) — is the error tuple, `valkey:`-prefixed for what the
  client itself finds wrong and `net`'s own reason for what the
  transport reports.
- **The caller breaks the contract** — `v.command([])`, `v.del([])`,
  a negative `timeout` at `set_timeout` — raises. These are the
  caller's bugs, deterministic and local, not the wire's data.

## Example

The `valkey_demo` example runs the whole surface against a miniature
RESP2 server riding in the same program — the client half of the wire
talking to the file's own server half, no external process needed:

```emo
require "valkey"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 0)
// ... a server process accepts on the listener ...

case valkey.connect("127.0.0.1", listener.port(), 5.0) {
  (R.error, why) then { println("connect failed") }
  (R.ok, v)      then {
    case v.ping() {
      (R.error, why) then { println("ping failed: ${why}") }
      (R.ok, pong)   then { println(pong) }        // PONG
    }
    case v.set("greeting", "hola") {
      (R.error, why) then { println("set failed: ${why}") }
      (R.ok, ok)     then { println(ok) }          // OK
    }
    case v.get("greeting") {
      (R.error, why) then { println("get failed: ${why}") }
      (R.ok, reply)  then { println(reply.as_string()) }   // hola
    }
    v.close()
  }
}
```

## Limitations

- **Three targets.** The package declares `targets = ["ocaml", "c",
  "typescript"]`; resolution refuses it for wasm, BEAM, and riscv64
  builds. On `c`, UDP and Unix-domain sockets stay refused (inherited
  from `net`), and names resolve to IPv4 addresses only.
- **RESP2.** The client speaks the protocol Valkey answers without a
  `HELLO` upgrade: no boolean, double, verbatim, map, set, or push
  replies arrive, and none of the doors would read them. RESP3's
  extras wait for a door that needs them.
- **One command, one reply.** No pipelining, no transactions
  (`MULTI`/`EXEC` rides `command` one line at a time), no pub/sub and
  no blocking commands as typed doors — `command(args)` sends any of
  them, but a reply that never comes answers the error tuple when
  the timeout does.
- **No reconnection, no pooling.** One connection per handle, closed
  when `close()` says so; a dropped socket is the error tuple, and
  reconnecting is the caller's visible move.
- **Deep arrays recurse per nesting level**, the same shape the `http`
  package's header walk takes — a reply nested thousands of levels
  deep is hostile input no ordinary server sends.
- **Replies ride as Strings.** On `ocaml` and `c` a String is a byte
  string, so bulk payloads of any bytes come through exactly. On
  `typescript` a String is a JS string — the same carrier limitation
  the crypto package documented before its Bytes migration — so a
  bulk payload that is not valid UTF-8 decodes lossily there. Keys
  and values a program holds as text are exact on all three targets;
  the request side's lengths are computed through `to_bytes()` (the
  UTF-8 codec), so a multi-byte argument's bulk length is the wire's
  own on every target.
