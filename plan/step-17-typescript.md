# Step 17 — TypeScript Target

**Milestone:** M4 · **Prereq:** steps 01–16 · **Status:** in progress

## Goal

`emo build --target typescript`: an Emo program compiles to TypeScript
that runs on Node with no extra toolchain. This is the compiler's second
backend and the first exercise of the multi-backend shape — target-aware
builds, target metadata honored by resolution, and a golden comparison
against the interpreter. It is deliberately the first target after native
because its toolchain risk is lowest and its decisions (value model,
concurrency mapping) are contained; Wasm then gets its own step with the
GC question as the only open front.

## Scope

### In

- **Target plumbing.** `--target` on `emo build` (native remains the
  default); step 11's resolution gate reads it; the target flows through
  to the backend choice.
- **Lowering from the IR.** The step 14 rule holds for every backend:
  the TypeScript emitter lowers from `Emo_ir`, not from the AST. The
  roadmap's earlier note ("the AST suffices") is superseded — the IR's
  resolved calls, explicit method tables, and module-qualified names are
  exactly what a text emitter wants, and one lowering rule keeps the
  backends honest.
- **The value model.** Tagged dynamic values, mirroring the interpreter:
  plain JS objects carrying a tag, numbers as JS numbers (with the
  2^53 integer-precision caveat recorded), classes as ES classes with a
  content-equality method, enums as frozen member objects. GC is the
  host's.
- **Concurrency as cooperative tasks.** A process is a task on the event
  loop: `do f(x)` starts an async task and yields a pid; `<-` appends to
  the pid's mailbox (a plain FIFO queue); `receive` suspends until a
  matching message arrives, scanning and requeueing like the native
  scheduler. Single-threaded, deterministic for the same programs the
  native scheduler is deterministic for. Workers (real parallelism) are
  explicitly out of scope for this step.
- **Direct style, absorbed in the emitter.** Every emitted function is
  `async`, every call `await`ed — the uniform mapping, no coloring
  analysis in v1. Blocking-looking calls (`read_line`, `receive`,
  timers) await promises wired to Node's APIs, so the Emo surface stays
  direct-style and the event loop lives entirely in the generated code.
  Tail-recursion through `await` unwinds the stack per hop (no native
  tail calls); deep non-IO recursion may be slow, and trampolining
  self-tail-calls is a recorded optimization, not a v1 gate.
- **The TS runtime library.** A small `emo_runtime.ts` emitted next to
  the program: value constructors and tags, the language's builtins
  (`print`), the runtime's methods (arithmetic, string/array), method
  dispatch, exception
  carrying, the task/mailbox machinery, and the promise wrappers for
  sockets and HTTP.
- **Examples subset green.** hello_world, fib, objects, language_tour,
  shop, pipeline, tcp_echo, http_roundtrip — each compiled to
  TypeScript, output byte-for-byte equal to `emo run`, checked in the
  test suite the way step 14's bootstrap does.
- **Stdlib metadata.** `net` and `http` gain `"typescript"` in
  `targets`; resolution refuses programs requiring packages that do not
  declare the target being built (already the rule; now exercised).

### Out

- Real parallelism (workers), colored-call inference, trampolining —
  recorded as follow-ups, not gates.
- Source maps, bundling, browser embedding (`fetch`/WebSocket bridging)
  — after the Node path is golden.
- `emo run --target typescript` (running without a build step) — the
  build command is the only surface this step adds.
- Self-hosting concerns, npm packaging of the runtime.

## Tasks

- [x] **T17.1** — Target plumbing and core emitter: `--target` through
      the CLI, project, and resolution gate; the IR → TypeScript
      emitter for the core subset (values, control flow, classes,
      interfaces, enums, exceptions, closures, modules); the tagged-value
      runtime; `emo build --target typescript` emits and runs under
      Node. Golden: hello_world, fib, objects.
- [ ] **T17.2** — Full core semantics: patterns and guards, tuples,
      arrays, Box, string interpolation, content equality, module
      references across files. Golden: language_tour, shop.
- [x] **T17.3** — Concurrency: tasks, mailboxes, selective receive,
      `self_pid`, `halt`. Golden: pipeline.
- [x] **T17.4** — Direct-style IO: sockets and HTTP over Node's APIs as
      awaited promises; stdlib target metadata gains `"typescript"`.
      Golden: tcp_echo, http_roundtrip. (Done 2026-10-12: the runtime
      carries the whole `net` surface over `node:net`/`node:dgram`/
      `node:tls`/`node:dns`, one persistent per-connection reader feeds
      the buffered reads, `E.builtin` dispatches the ten net builtins,
      and the root process finishing releases the live handles so the
      loop drains — the native rule that the root ending ends the
      program. `net` and `http` declare `"typescript"`; the `http`
      server block closed its connection twice, which the native
      scheduler hid and the TypeScript target surfaced — the block now
      returns the connection for `handle_connection` to close. The
      `c` target keeps TCP only.)
- [ ] **T17.5** — Bootstrap: the target-aware golden suite in CI (each
      example's TypeScript run matches the interpreter byte-for-byte),
      and the resolution gate test for packages that lack the target.

## Acceptance

- `emo build --target typescript main.emo` produces TypeScript that
  runs on Node; every example in the subset prints exactly what
  `emo run` prints (golden comparison in CI).
- A program requiring a package that does not declare
  `"typescript"` fails resolution before any emission.
- `dune test` green.

## Decisions settled here (the trail)

- **Lower from the IR, not the AST** — supersedes the roadmap note;
  rationale above (this file, Scope).
- **Uniform async mapping, no coloring analysis** (this file, Scope) —
  recorded as the v1 position; revisit only if the await tax shows up
  in a benchmark worth caring about.
- **Cooperative tasks, not workers** (this file, Scope) — processes are
  semantics first, parallelism later.
- **Networking over Node's modules, not a custom loop** (T17.4) — the
  runtime wraps `node:net`/`node:dgram`/`node:tls`/`node:dns`; the
  emitter already awaits every call, so the Emo surface stays direct
  style with no new language machinery. Errors unwrap to the target's
  message text (Node's TLS reason where OpenSSL's would appear on
  `ocaml`), and spawned processes end silently on an exception, as the
  native scheduler's event log does.
- Promoted from step 15 per its T15.1; the umbrella keeps the other
  targets' decisions.
