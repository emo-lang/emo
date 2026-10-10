# Step 33 — The standard library: `bufio`

**Milestone:** M11 — The standard library · **Prereq:** step 32
(slog — the zero-compiler-change golden shape) · **Related:**
`stdlib/registry/{os,base64}` (the fd surface and the cross-module
shape), `docs/stdlib/bufio.md` · **Status:** done on
interpreter/ocaml/c; the package rides `os`, so wasm/beam/typescript
refuse it at resolution like `os` does (2026-10-09).

## Why this step exists

Buffered IO is the shape every real file and socket consumer reaches
for, and the first standard-library package that is *stateful* by
necessity — a buffer persists between calls — on a language whose
classes are immutable after construction. How Emo says "a buffered
reader" without fields that change is the design question this step
answers: the mutable state lives in `Box`es inside an ordinary class,
the abstraction lives in two one-method structural interfaces, and
end of stream — the control flow every caller needs — is a value,
because the language has no error channel yet.

## Goal

`require "bufio"` reads and writes through a fixed-size buffer:
`Reader` over any `ByteReader` (a `read(n) String` — fewer only at
end of stream, the empty string once exhausted), `Writer` over any
`ByteWriter` (a `write(data) Int64` — all bytes or raise). Adapters
cover the concrete streams: fd pairs through `os`, an in-memory pair
for pure use. Line reads, delimiter reads, peeking, discarding, and
one-level unreading sit on top. The shape follows Go's `bufio`; the
error model is Emo's — end of stream is the empty string, and a raise
is reserved for the caller's own mistakes.

## Design note

- **The state is Boxes in a plain class.** `Reader` holds its buffer,
  read cursor, source, and last-read byte in `Box`es; the class is
  immutable, the boxes are not. No package-level state, no globals,
  nothing to initialize.
- **Two interfaces, one method each.** Satisfaction is structural,
  so `Reader` is itself a `ByteReader` and readers stack; the
  small surface is also CHECK.md's own mitigation for accidental
  satisfaction.
- **EOF is the empty string.** The os convention carries through:
  loops end on `== ""`, and `read_line` keeps the terminator so an
  empty line never masquerades as the end of the stream.
- **The Writer never discards.** `reset` flushes first (Go's discards)
  — a strict package does not lose data by surprise; and `flush`
  before the stream ends is the caller's job, documented.

## What the step flushed out

Three latent c-backend bugs, all in the cross-module method-call
path, all caught by the demo's golden and fixed:

- **The name hijack was unsound.** A receiver the checker lost the
  type of (any cross-module value) dispatched builtin-owned method
  names (`read_line`, `trim`, `substring`, …) straight to the
  builtin — `b.read_line()` on a user class became
  `emo_net_read_line(unbox(b))`, a type-check crash at runtime. The
  dispatch now lives in the runtime (`emo_dynamic_builtin`): an
  instance answers through its vtable, a non-instance through the
  builtin that owns the name.
- **The receiver was evaluated up to three times.** The old arm list
  interpolated the receiver expression into the kind test and both
  arms; a side-effecting receiver (`pe.discard(2).to_string()`)
  executed three times. The runtime dispatch receives the value once.
- **Void method calls were dropped in statement position.** A `Void`
  method's value was rewritten to `(void)(0)` before the statement
  wrapper, deleting the call — and the side effect — entirely.

## Tasks

- [x] **T33.1** — The package: the two interfaces, the four
      adapters, `Reader` (read / read_byte / read_string / read_line
      / peek / discard / unread_byte / buffered / reset), `Writer`
      (write / write_byte / flush / buffered / available / reset),
      strict sizes and exact errors. (Done 2026-10-09.)
- [x] **T33.2** — The golden: `examples/bufio_demo` — in-memory
      streams, an 8-byte buffered file write that really flushes,
      read back through two stacked readers — on the bootstrap and c
      lists. (Done 2026-10-09.)
- [x] **T33.3** — The c-backend fixes: the runtime dispatch for
      untyped receivers (`emo_dynamic_builtin` + the builtin method
      table), the single evaluation of the receiver, and the Void
      statement-method emission. (Done 2026-10-09.)
- [x] **T33.4** — The docs: `docs/stdlib/bufio.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)
