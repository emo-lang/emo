# The `wayland` Package

The Wayland client protocol in pure Emo over the `net` surface's Unix
socket: a program connects to the compositor, binds the globals it
names, shares pixels through `wl_shm`, and answers the events the
compositor sends — the codec, the interface tables, and the state
machine living in the package, not in every program's socket loop.
This is the gate the noctalia track opens onto the real Wayland world:
the first frame an Emo program has ever put on a real compositor went
through this package.

## Using the package

```emo
require "wayland"
require "net"
require "os"

case net.connect_unix(path, 5.0) {
  (R.error, why) -> { println(why) }
  (R.ok, raw) -> {
    const c = wayland.conn_of(raw)
    case wayland.handshake(c) {
      (R.error, why) -> { println(why) }
      (R.ok, globals) -> { /* globals.find("wl_compositor") ... */ }
    }
  }
}
```

`wayland.connect(path, timeout)` wraps the same dance around a socket
it opens itself; `conn_of` wraps a socket already open (the shape a
test double starts from). The package declares `c` alone: the Unix
socket, the fd passage, and the shm tier are the c target's runtime,
and every other target refuses the package at resolution (the sqlite3
precedent).

## The wire

The codec is the protocol's own grammar, stated where it is used: the
8-byte header (object id, opcode, size — little-endian), the argument
encodings (int32, uint32, fixed 24.8, string with its NUL and the pad
to 4, new_id, array), and the fd's rule, graded against a real
compositor: **an fd takes no word in the argument stream** — it rides
the socket out of band (SCM_RIGHTS), queued in the order the grammar
names it, and `Args.fd` claims it from that queue. The builder is
strict about the wire's own rules: a value outside its word, a size
past the u16, a second fd, a second fd claim with none arriving — each
raises, because each is a mistake the wire would answer with garbage.

`Message` builds a request or an event; `finish` patches the size word
and answers the bytes with the fd beside them. `Args` decodes a frame
in the order the interface's grammar names its arguments; `Side` is
one end of a socket — every read through recvmsg (a read that dropped
ancillary data would be the silent loss), the framing owned once, the
client and a test double sharing it.

## The tables

The interfaces a client speaks, with the opcode numbers stated at
their call sites: `wl_display`, `wl_registry`, `wl_callback`; the
`wl_compositor`/`wl_surface` pair a window's tree grows from; `wl_shm`
and its pool and buffer; and the `xdg-shell` family (`xdg_wm_base`,
`xdg_surface`, `xdg_toplevel`) — the configure-before-commit
discipline made structural in `wait_configure`, whose signature names
what it consumes (the toplevel's own configures set aside, the ping
answered with the pong, the serial handed back as the ack's and the
commit's license).

The tables are hand-written — no XML is parsed at runtime — and the
smoke leg is where a real compositor grades them: sway caught two
wrong opcodes and a missing request (`create_positioner` at 1,
`get_xdg_surface` at 2; `ack_configure` at 4; the wl_surface family
one higher than a first reading guesses, `destroy` at 0) by naming
the misdispatch in its error events.

## Strictness on the wire

The transport's truths answer `(R.error, reason)` with reasons
prefixed `wayland:`: a short read, a peer gone mid-frame, a size word
smaller than the header, a display error event (its message carried
through). A frame that lies about its own argument lengths is protocol
corruption and raises loudly — a silent shift by four bytes is the one
failure a wire must never dress up.

## Painting

The pool's client-side life is `os_shm_open` (a private file at a
path, unlinked at birth — seekable and mappable on macOS and Linux
alike; macOS's POSIX shm objects refuse read and pwrite outright),
`os_ftruncate`, and `os_pwrite` — pixels through pwrite, the
compositor mmaps, and no mmap exists at the Emo surface. The paint
sequence the demo drives is the milestone's own ladder: handshake,
binds at the advertised versions, surface, xdg surface, toplevel,
title, the empty commit, the configure wait, the ack, the pool
painted one pwrite a row, attach, damage, the second commit.

## Limitations

- **One target.** `c` alone; the interpreter's fd-passage stubs (the
  OCaml runtime's Unix module carries no sendmsg) are the named
  follow-up.
- **One fd a message.** The protocols this package speaks carry
  exactly one; a protocol needing two grows the shape then.
- **Input is not here yet.** `wl_seat`, `wl_pointer`, `wl_keyboard`
  — and the keymap fd their events carry — are the next tables, not
  these.
- **Hand-written tables.** The opcodes live at their call sites and
  the compositor grades them; no XML is parsed at runtime.

Demos: `examples/wayland_wire` (the codec against hand-computed
fixtures), `examples/wayland_handshake` (a mock compositor over a real
Unix socket, byte-exact), `examples/wayland_paint` (the first frame —
run by `devtools/wayland-smoke.sh`, the Docker leg that compiles the
demo's C and runs it under headless sway, grim the eye).
