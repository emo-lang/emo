# Step 81 — WASI 0.3: Emo programs as standard command components

**Milestone:** M42 · **Prereq:** step 56 (the wasm target and its
canonical host), 77 (WASI preview1) · **Status:** in progress

The wasm target's artifact is a WasmGC module with eighteen `emo.*`
imports, and only the Node canonical host can supply them — wasmtime
compile-validates the shape but cannot execute it (the found-not-fixed
recorded at T56.9). WASI 0.3.0 released 2026-06-11: the component model
with native async, `wasi:io` gone, stdio flipped to guest-supplied
streams, `wasi:sockets` consolidated, wasmtime 46+ shipping it by
default. The track makes `emo build --target wasm --wasi` produce a
real WASI 0.3 command component — a component wrapping the WasmGC core
module — so wasmtime becomes the second execution engine and Emo
programs run on standard WASI runtimes.

The decided surface: a **new flag**, not a new target name. `known_targets`,
the manifests' `targets` arrays, and the lockfile discipline stay
untouched; the default `--target wasm` artifact and the Node host path
are unchanged. The consumer direction (the `wasm` package's interpreter
running foreign 0.3 components) stays out — it would need GC types,
reference types, and the async protocol in an interpreter that has
neither; nothing asks yet.

## Decisions settled by the probe

The probe campaign (2026-11-14, `devtools/wasi03-probe/`, the facts
table and evidence in its README) validated the four load-bearing
assumptions and pinned the encodings:

- **Sync ABI carries the whole component.** An async-typed export can
  be canon-lifted with the sync ABI — wit-component itself emits
  `run: async func() -> result` as `(canon lift ...)` with no async
  option, the async-ness riding the type — and every WASI import
  sync-lowers (blocking happens in the host). No waitable sets, no
  callback, no `task.return`; Emo's single-threaded synchronous model
  maps onto 0.3 without an event loop. The spec names this door
  explicitly: "traditional sync code can export async functions this
  way without any concurrency support".
- **The gate is honest.** The sync variants of the stream builtins
  (`stream.write`, `future.read`) sit behind wasmtime's
  `-W component-model-more-async-builtins=y` — the 🚝-gated extension,
  not yet in the standard's default set. The run path passes the flag;
  the pressure to drop it (by moving writes onto the async builtins +
  a waitable-set poll loop, or onto the standard async ABI) is
  recorded here rather than faked away.
- **The stdout protocol is pinned end to end** (probe README, facts
  6–8): `stream.new` answers one packed i64 (low 32 readable, high 32
  writable); the readable end transfers into `write-via-stream` and
  the host drains and drops it — the guest never drops it; sync
  `stream.write` completes only as the host consumes (a readerless
  write never returns, so the buffer-all-then-hand-off order is the
  only deadlock-free sync order); `stream.drop-writable` is the EOF;
  `future.drop-readable` is the guest's only cleanup.
- **The import shape is what `use` makes it.** `wasi:cli/types@0.3.0`
  is its own instance import (the `error-code` enum); `wasi:cli/stdout@0.3.0`
  aliases that outer type and re-exports it `(eq ...)`. A
  self-contained enum inside the stdout instance is rejected by
  wasmtime's world matching. Version strings pinned at `0.3.0` (the
  probe validated them; the main-branch package is `0.3.2`).
- **The memory cycle has a provider answer.** `canon lower` with a
  memory option needs the memory before the guest module exists, and
  the guest's memory is its own — so the guest *imports* its memory
  from a one-section provider core module instantiated first (the
  route wit-component's shim/fixup machinery avoids by indirection;
  the provider needs none of it).

## The component shape

```
(component
  (import "wasi:cli/types@0.3.0" (instance ...))      ; error-code
  (import "wasi:cli/stdout@0.3.0" (instance ...))     ; write-via-stream
  (import "wasi:cli/stderr@0.3.0" (instance ...))     ; write-via-stream
  (import "wasi:cli/exit@0.3.0" (instance ...))       ; exit, exit-with-code
  (core module $prov (memory ...))                    ; the memory provider
  (core instance $prov (instantiate $prov))
  (alias core export $prov "memory" (core memory $mem))
  (core func ... (canon lower ... (memory $mem)))     ; the lowered WASI funcs
  (core func ... (canon stream.new/stream.write/...)) ; the stream builtins
  (core instance $host (export ...))                  ; synthetic, feeds $main
  (core module $main ...)                             ; the Emo WasmGC module,
                                                      ; memory imported
  (core instance $main (instantiate $main (with ...)))
  (alias core export $main "run" (core func $run))
  (func $run (type (func async (result (result)))) (canon lift (core func $run)))
  (instance $run-i (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run-i))
)
```

## The syscall remap (--wasi mode)

| 18-import surface | WASI 0.3 destination |
| --- | --- |
| `println` | stdout buffered guest-side, flushed through the stream protocol at exit and before abort |
| `abort` | stderr through the stream protocol, then `exit-with-code(1)` |
| `float_str` | guest-side `%g` formatting (the host import is retired in this mode; the c runtime's rule ported into the wat-level runtime) |
| `fetch` | retired — the canonical ABI's retptr returns replace the two-phase stash |
| `file_read`/`file_write`, the `os` fd/directory half | `wasi:filesystem@0.3.0` preopens + types, the guest keeping the fd↔descriptor table |
| `rand_bytes` | `wasi:random@0.3.0` `get-random-bytes` (short returns looped) |
| `os_getcwd`/`os_chdir` | refuse by name — 0.3 has no cwd concept (the `environment` interface's `get-initial-cwd` is a hint, not a filesystem fact) |
| the `os` process half | unchanged — the run-time raise naming the capability |
| fd 0 reads | refuse this rung — `stdin.read-via-stream` returns a stream the sync guest can only consume through the gated builtins; the honest refusal names the door |

## Scope

### In

- `src/emo_codegen/emo_component.ml` — the component-level AST, the
  binary writer, and the component WAT printer (the `.wat` sibling
  convention carries over).
- `emo_wasm.ml` — the import table and the `Runtime_impl` lowering
  parameterized by the ABI mode; the guest-side `%g` runtime function;
  the buffered stdout/stderr channels.
- The CLI: `emo build --target wasm --wasi`, `emo run --target wasm
  --wasi` (wasmtime on PATH, exit 69 without it, the flag passed
  through), the `emo doctor` wasm line grown to report wasmtime.
- The goldens: a `wasm_wasi_examples` group mirroring
  `wasm_examples_tests` (skipping when wasmtime is absent), the
  supported subset of the 65 wasm goldens byte-identical with the
  Node/c targets, the known refusals pinned by name.
- `devtools/wasmtime-smoke.sh` grown with the component execution rung.
- Docs: the `--wasi` section in `docs/demo-targets.md` (EN + zh), the
  ledger updates (plan row, TASKS milestone M42 + step section,
  CHECK.md decision + trail).

### Out

- The consumer direction — the `wasm` package interpreter instantiating
  foreign 0.3 components (GC types, reference types, the async protocol:
  nothing asks).
- `wasi:sockets` / `wasi:http` — the wasm target has no network story;
  `net`/`http` already refuse at resolution.
- The async ABI (waitable sets, callbacks, stack switching) — the sync
  door carries the rung; recorded as the follow-up if a runtime's
  default-flag posture or concurrency earns it.
- `wasi:clocks` — the language has no clock primitive (the step-77
  stance unchanged).

## Tasks

- [x] **T81.1** — The probe campaign: the four load-bearing facts, the
      encodings, the stdout protocol, the exit channel
      (`devtools/wasi03-probe/`).
- [x] **T81.2** — The component encoder (`emo_component.ml`): the AST,
      the binary writer, the component WAT printer. Validated
      end-to-end: `emo run --target wasm --wasi` on hello_world prints
      the expected bytes under wasmtime 49 and exit codes propagate.
- [x] **T81.3** — The ABI mode in `emo_wasm.ml`: the remapped import
      table, the memory provider, the stdout/stderr stream cycles.
      The guest-side `%g` port ran the fixed-form path byte-identical
      with the node host over the whole float ladder before the
      wat-level exp-form bugs halted it (see the found-not-fixed
      below); this rung ships the honest refusal instead.
- [x] **T81.4** — The CLI flag surface (build/run/doctor).
- [ ] **T81.5** — The filesystem, random, and environment imports; the
      refusal pins.
- [ ] **T81.6** — The wasmtime-smoke execution rung, the docs, and the
      close-out.

## Found and fixed (the encoder's first landing)

- The bare WIT `result` is its own type definition; an inline
  `(result)` in a param slot silently shifts the inner type indices.
- `use` splits an interface into two instance imports; a
  self-contained enum inside the stdout instance fails wasmtime's
  world matching.
- `stream.new` answers one packed i64 (low 32 readable, high 32
  writable); the readable end transfers into `write-via-stream` and
  the host drops it — the guest never does.
- Sync `stream.write` completes only as the host consumes; the
  hand-off must precede the writes.
- The canon-lower cycle (the lowered functions write through the
  guest's memory) breaks with a one-section memory provider the guest
  imports, no shim/fixup needed.
- The canon `lower` takes the memory option only when the lowered
  function touches linear memory.
- Section 1 (the embedded core module) is a single module, no vector
  count; every other compound section's payload carries its count.
- Core inline exports carry plain names and the core ExternalKind
  byte; component-level inline exports carry name attributes and the
  component sort. Exports end with the ascribed-type byte (0x00).
- The canon-lift of an async-typed export carries no async option —
  wit-component's own encoding.

## Found, not fixed (this rung)

- **The guest-side `%g`'s exp form.** The port reached the fixed-form
  path byte-identical with the node host (the whole float ladder:
  1.5, 0.1, 123456.789, 0.0001, -42.75, 0.000123457 …) and then the
  exp-form's wat-level runs hit: the L-scan's exit boundary (the
  all-zero fraction), the `k` bookkeeping across the strip walks, and
  the operand-order traps around `local.set` scratch indices. The
  rung ships the honest refusal; the algorithm and the debug
  instruments (the n/p0/k probes through `int_str`) are the next
  pass's starting point. The refusals: the float render names the
  rung; the filesystem, random, cwd, and fd-0 doors name theirs.
- **The more-async-builtins gate.** The sync stream builtins ride
  wasmtime's `-W component-model-more-async-builtins=y` — the 🚝-gated
  extension. The run path passes the flag; dropping it means the
  async builtins and a waitable-set poll loop, the async ABI's
  territory.

## Acceptance

- `devtools/wasi03-probe/run.sh` green (stdout `hello`, exit 42).
- `emo run --target wasm --wasi examples/hello_world/main.emo` prints
  the expected bytes and exits 0 under wasmtime.
- The supported golden subset runs byte-identically under wasmtime;
  the Node path and the c targets regress nothing.
- `dune runtest` green, `@fmt` green.
