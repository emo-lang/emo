# Step 13 — Native Backend

**Milestone:** M4 · **Prereq:** steps 01–12 · **Status:** done

## Goal

`emo build` targeting native: a standalone executable with the performance
story the README promises — type information feeding specialization
(unboxed representations, direct dispatch). This step introduces the
compiler's first machine-targeting backend and, with it, a mid-level IR that
step 14's other targets will share.

## Scope

### In

- **Backend strategy, staged** (decision point, recommendation below) —
  - **Stage A: compile to OCaml.** Lower the checked AST to OCaml source
    (or a directly-linked OCaml module tree), compile with the OCaml
    toolchain, link the runtime (scheduler, builtins). This reuses OCaml's
    optimizer, GC, and platform support, and lands a real backend fast.
  - **Stage B: specialization.** Where the step 08 checker has complete
    type knowledge for a module, specialize: unbox primitives, direct
    (non-duck) method dispatch, eliminate runtime tag checks. Mixed
    modules keep dynamic semantics at their `Unknown` regions — gradual
    typing pays off mechanically here.
  - Recommendation: A then B. A pure from-scratch codegen detour is not
    warranted before the language has users.
- **Mid-level IR** — a small, typed IR between the checked AST and every
  backend (this one and step 14's): modules of named functions over typed
  values, closures, tagged-dynamic fallbacks. Adding a backend means
  lowering from the IR, never from the AST again.
- **`emo build`** — resolves (step 10), checks, lowers, compiles, links;
  output is a single executable. Build-as-install ergonomics: building an
  executable from a package is just `emo build`, no separate install step.
  Incremental: content-hash caching per module/IR-unit across builds.
- **C FFI** — link Emo binaries against C libraries through OCaml's
  first-class FFI; the binding-surface syntax is a design item (below) and
  must be settled before shipping any FFI.
- **Runtime linkage** — the step 11/12 scheduler and net stack link into
  produced binaries; programs using them carry the runtime, everything
  else stays lean.
- **Benchmarks** — a `benchmarks/` set (fib, process ping-pong, HTTP
  echo, JSON-ish parse) guarding Stage B's specialization claims with
  numbers, tracked from the first working build.

### Out

- Self-hosting (explicitly not a goal — the compiler stays OCaml).
- Other targets (step 14), debug builds / DWARF (later hardening).
- The bare-metal target (step 14).

## Tasks

- [x] IR definition + checked-AST lowering.
- [x] Stage A: OCaml emission, runtime linking, single-binary output.
- [x] `emo build` with incremental caching.
- [x] Benchmark set wired into CI (numbers recorded, not just pass/fail).
- [x] Stage B: type-driven specialization passes (unboxing, direct
      dispatch) behind completeness checks from step 08 data.
- [x] C FFI linking path once binding syntax is decided.
- [x] Bootstrap test: the `examples/` suite as compiled binaries matches
      interpreter output byte-for-byte.

## Acceptance

- Every `examples/*.emo` compiles to a native binary producing identical
  output to `emo run` (golden comparison in CI).
- Specialized numeric code (fully annotated) shows measurably better
  benchmark numbers than the unspecialized build — the README's
  type-feeds-performance claim demonstrated, not asserted.
- A process-per-connection HTTP server built with `emo build` sustains a
  load test on the native scheduler.
- `dune test` green; `benchmarks/` results recorded.

## Open design items

- **C FFI binding-surface syntax is undecided and missing from `CHECK.md`**
  — add and settle it before the FFI task starts.
- Stage A's OCaml emission (source vs constructed module trees) is an
  implementation choice; pick one, document the tradeoff in `docs/`.

## Close-out

Both open design items settled:

- **C FFI binding surface** — `foreign def name(params) Ret = "c_symbol"`,
  registered in `CHECK.md` and the README (Native Builds). Only
  `Float`/`String`/`Bool` marshal (E4200 refuses the rest); bindings
  compile to generated C wrappers (`.emo-build/ffi_stubs.c`) rather than
  raw OCaml externals, which would pass boxed `value`s and collide with
  primitives the OCaml compiler inlines (`sqrt` on ARM64 macOS). The
  interpreter refuses foreign defs with E3009.
- **Stage A emission** — OCaml source text, tradeoff documented in
  `docs/native-backend.md` (stable toolchain contract, readable
  generated code, unchanged optimizer; the IR is the layer backends
  share).

Notes:

- T13.5's specialization landed with the T13.1/T13.2 commits: the
  completeness fixed point lives in the checker/`Emo_ir.specialize`, and
  the T13.2 emitter carries the specialized/dynamic split with dynamic
  wrappers.
- The build cache keys on the emitted source, the runtime libraries'
  sizes, the specialize flag, and `--cclib` flags — any change
  invalidates the cached binary.
- Bootstrap: all five examples (fib, hello_world, objects, shop,
  http_roundtrip) build through `emo build` and match `emo run`
  byte-for-byte; the suite exposed and fixed two emitter bugs (case
  tuple bindings all read position 0; wildcard matches carried a
  redundant catchall).
- Benchmarks recorded in `benchmarks/results.md`: fib(30) 345ms
  unspecialized vs 212ms specialized (~1.6x), ping-pong 40k msgs
  2440ms, JSON-ish scan 57ms, HTTP echo 112 req/s.
- Error excerpts from eval-stage diagnostics now read the span's file,
  so runtime errors render real source lines.
