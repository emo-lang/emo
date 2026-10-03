# Step 16 — Wasm Target (WasmGC)

**Milestone:** M4 · **Prereq:** steps 01–13 · **Status:** in progress

## Goal

`emo build --target wasm`: an Emo program compiles to a WebAssembly
module that runs on any WasmGC host — Node first, standalone runtimes
(wasmtime) as they are installed. This is the compiler's third backend
and the first non-OCaml emission target: the output is a binary `.wasm`
(the runnable) plus a `.wat` sibling (the readable form, in the spirit
of step 13's debuggable generated code), both produced by the compiler
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
- **Lowering from the IR** — the step 13/15 rule; the same mangled
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
  the resolution gate reads the target (finishing the T15.1 remainder):
  a program requiring a package that does not declare `"wasm"` fails
  resolution before any emission — the standard library packages
  (net/http) declare only `native`, so IO programs refuse honestly
  until the WASI audit lands.
- **Examples subset green.** hello_world, fib, objects, language_tour,
  shop — byte-for-byte against the interpreter, in CI.

### Out

- Processes and message passing on Wasm (the cooperative scheduler
  needs a driver story — host timers vs. a module-level loop; its own
  task after the core is golden).
- Networking (WASI sockets audit; stdlib metadata for `wasm` comes with
  it, not before).
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
- [ ] **T16.4** — Concurrency: a cooperative driver for
      `do` / `<-` / `receive` inside the module, host-timer imports
      for preemption points. Golden: pipeline. (Gated on T16.2.)
- [ ] **T16.5** — The WASI and IO audit: what `net`/`http` can mean
      under WASI, stdlib metadata for `"wasm"`, and the io goldens
      (tcp_echo, http_roundtrip) where the host supports it.

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
- Promoted from step 14 per its T14.1 (2026-10-02, second target).
