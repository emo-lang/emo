# Step 16 — Wasm Target (WasmGC)

**Milestone:** M4 · **Prereq:** steps 01–15 · **Status:** complete

## Goal

`emo build --target wasm`: an Emo program compiles to a WebAssembly
module that runs on any WasmGC host — Node first, standalone runtimes
(wasmtime) as they are installed. This is the compiler's third backend
and the first non-OCaml emission target: the output is a binary `.wasm`
(the runnable) plus a `.wat` sibling (the readable form, in the spirit
of step 14's debuggable generated code), both produced by the compiler
itself with no external toolchain.

## Scope

### In

- **The GC decision: WasmGC.** Emo values are GC-allocated WasmGC
  structs and arrays; the host's collector is the collector. No custom
  heap, no shadow stack. The runtime type (RTT) of each struct is the
  value's tag: dynamic dispatch and `case` tests compile to
  `ref.test`/`ref.cast`, not to tag fields.
- **The value model.** One dynamic value = an `anyref` into a small
  struct hierarchy: Int boxes an i64 (the interpreter's integer range,
  wrap-around included); Float boxes an f64; Bool a flag struct; String
  a UTF-8 byte array (byte-length semantics, matching the interpreter);
  Tuple an array-of-values field; Array a mutable array-of-values; Box
  a mutable value field; Enum two interned-name indices; instances one
  struct per class with the fields in declaration order; exceptions a
  message struct raised through a Wasm exception tag.
- **Lowering from the IR** — the step 14/15 rule; the same mangled
  names, the same dynamic semantics, and the specialization story stays
  out (dynamic form only, like the TypeScript target's first pass).
- **Emission.** The backend lowers the IR to a WAT-shaped intermediate
  and serializes it twice: a text printer (`.wat`) and a binary encoder
  (`.wasm`, LEB128 + sections written directly). No wabt, no external
  assembler; any mismatch between the two serializations is a test
  failure.
- **Host boundary.** `print` (and later IO) is a host import; the
  golden harness runs the module under Node's WasmGC. Uncaught
  exceptions surface through the module's exception tag and are
  rendered by the host wrapper with the interpreter's message.
- **Target plumbing, completed.** `--target wasm` through the CLI, and
  the resolution gate reads the target (finishing the T17.1 remainder):
  a program requiring a package that does not declare `"wasm"` fails
  resolution before any emission — the standard library packages
  (net/http) declare three other targets, so IO programs refuse honestly;
  T16.5's audit confirmed they stay refused.
- **Examples subset green.** hello_world, fib, objects, language_tour,
  shop — byte-for-byte against the interpreter, in CI.

### Out

- Processes and message passing on Wasm (the cooperative scheduler
  needs a driver story — host timers vs. a module-level loop; its own
  task after the core is golden).
- Networking (WASI sockets audit — closed by T16.5 in favor of refusing:
  no socket path reaches the core-module host boundary; stdlib metadata
  for `wasm` covers the pure packages only).
- Specialization/unboxing (i31 fast paths for ints, unboxed f64
  registers in fully-typed functions) — recorded, not gated.
- Browser embedding, JS string builtins, WASI CLI args/env.

## Tasks

- [x] **T16.1** — The backend skeleton: `--target wasm` plumbing
      (including the resolution gate reading the target); the WAT
      intermediate; the binary encoder; the value model and runtime
      helpers emitted into the module. Golden: hello_world, fib,
      objects (under Node).
- [x] **T16.2** — Full core semantics: patterns and guards, tuples,
      arrays, Box, interpolation, content equality, interface
      narrowing, multi-file module references. Golden: language_tour,
      shop.
- [x] **T16.3** — Bootstrap: the target-aware golden suite in CI for
      the wasm subset, plus the resolution-gate refusal test for
      packages lacking `"wasm"`.
- [x] **T16.4** — Concurrency: a cooperative driver for
      `do` / `<-` / `receive` inside the module, host-timer imports
      for preemption points. Golden: pipeline. (Gated on T16.2.)
- [x] **T16.5** — The WASI and IO audit: what `net`/`http` can mean
      under WASI, stdlib metadata for `"wasm"`, and the io goldens
      (tcp_echo, http_roundtrip) where the host supports it. (Done
      2026-10-17: the host supports neither — see the trail. `net` and
      `http` stay undeclared for `wasm`; resolution refuses them before
      emission. The pure stdlib packages already declare `"wasm"` and
      run in the golden group; a resolution test now pins both sides.)

## Acceptance

- `emo build --target wasm main.emo` produces a `.wasm` (plus its
  `.wat` sibling) that runs on Node's WasmGC; every example in the
  core subset prints exactly what `emo run` prints (golden in CI).
- A program requiring a package that does not declare `"wasm"` fails
  resolution before any emission.
- `dune test` green.

## Decisions settled here (the trail)

- **GC = WasmGC, structs/arrays with RTT dispatch** — the user's call
  when scheduling the target; it removes the custom-GC branch (and its
  prototyping cost) entirely. The wasm struct hierarchy and the RTT
  dispatch rule are this file's Scope.
- **Int boxes an i64** — full interpreter range over i31 speed;
  unboxing is a recorded specialization follow-up.
- **Binary + text emission from one intermediate** — no external
  assembler; the two serializations are cross-checked by the golden
  tests.
- **Node is the reference host**; wasmtime follows when installed.
- **No WASI socket path; `net`/`http` stay refused** (T16.5, the
  audit). Node's `node:wasi` implements `wasi_snapshot_preview1`, whose
  socket calls are not usable — probing `sock_accept` after
  `WASI.start` crashed the Node process; wasmtime 49 answers the same
  legacy call with `notsock`, because the working socket surface is
  WASI preview2's `wasi:sockets`, which is component-model/WIT shaped
  and unreachable from the core WasmGC module this backend emits. An
  off-the-shelf WASI host also cannot supply the module's three `emo`
  imports (`println`, `abort`, `float_str`). So `tcp_echo` and
  `http_roundtrip` have no host on the reference toolchain and no io
  goldens are added; both packages stay out of `targets` and
  resolution refuses them before emission. Revisit when the Node host
  gains wasm sockets or the backend grows a preview2/component
  lowering plus a host shim.
- **The `wasm` stdlib set is the pure one** (T16.5). `json`, `yaml`,
  `xml`, `csv`, `base64`, `float`, `math`, `plot`, `sql`, and `sync`
  declare `"wasm"` and run in the golden group; `slog` waits on `Map`,
  `os`/`bufio`/`file` on process and file IO, `sqlite3` on FFI, and
  `net`/`http` on sockets. Nothing is declared optimistically.
- Promoted from step 15 per its T15.1 (2026-10-02, second target).
