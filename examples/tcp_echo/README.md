# TCP echo

One program, both ends of the wire: a server process echoing lines over
a TCP connection on loopback, and a client chatting with it.

```console
EMO_REGISTRY=<repo>/stdlib/registry emo run main.emo
```

What to notice:

- **Direct-style networking.** `net.listen`, `net.connect`,
  `conn.read_line()`, `conn.write(...)` read like blocking IO — the
  scheduler switches processes underneath, and no function is colored
  async. The server is a plain recursive function sitting in `accept`.
- **The standard library is Emo source.** `require "net"` resolves the
  `net` package through the registry (`EMO_REGISTRY` points at
  `stdlib/registry`); open `net.emo` and the whole socket surface is
  there to read.
- **Port 0 asks the kernel for a free port.** `listener.port()` reports
  what the kernel chose, so every run is self-contained.
- **Processes and sockets compose.** The server runs in its own process
  (spawned with `do`) and reports back on the client's pid when the
  connection closes politely; `set_timeout(5.0)` bounds every operation
  that follows.

The golden output is in `expected.txt`.
