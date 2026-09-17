# Step 13 — Native Backend

**Milestone:** M4 · **Prereq:** steps 01–12 · **Status:** not started

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

- [ ] IR definition + checked-AST lowering.
- [ ] Stage A: OCaml emission, runtime linking, single-binary output.
- [ ] `emo build` with incremental caching.
- [ ] Benchmark set wired into CI (numbers recorded, not just pass/fail).
- [ ] Stage B: type-driven specialization passes (unboxing, direct
      dispatch) behind completeness checks from step 08 data.
- [ ] C FFI linking path once binding syntax is decided.
- [ ] Bootstrap test: the `examples/` suite as compiled binaries matches
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
