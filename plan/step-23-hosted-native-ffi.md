# Step 23 — Self-contained hosted native backend (no OCaml runtime), and deep C FFI

**Milestone:** M4 follow-on · **Prereq:** step 13 (the IR and
specialization); the dynamic-value study in step 22 · **Related:**
`plan/step-14-other-targets.md` (the C-interop ladder),
`plan/step-22-riscv64.md` (the first self-contained value model),
`docs/industrial-software.md` (the performance probe) ·
**Status:** assessment — not scheduled

## Why this file exists

`docs/native-backend.md` is explicit that the shipped native target emits
OCaml source and links the OCaml runtime. That choice bought a fast path to
a working backend, and it is also the ceiling on what the native target can
ever do for numeric code and C interop. `plan/step-22-riscv64.md` is the
first design in the repo that owns its runtime instead: a tagged-word value,
a bump allocator, the psABI as Emo's own calling convention, and a
C-interop ladder.

This file records the same design applied to a **hosted** target — x86-64 /
arm64 with libc present — whose point is the thing the current backend
cannot do: unboxed numeric code with a direct C ABI. It exists to give the
idea a name, a scope, and a list of decisions, so that if it is ever
scheduled it starts from here rather than re-deriving it. It is an
assessment, not an execution plan: nothing here is decided design, and the
open items live in `CHECK.md`.

## The measured case

`docs/industrial-software.md` ("A performance probe") and `benchmarks/`
record the current native backend against C and plain OCaml. The relevant
findings, all reproducible via `benchmarks/run.sh`:

- The FFI round trip is cheap (~43 ns all-in for a `sqrt` call versus
  ~4.5 ns in C); the boxed Emo calling convention around it is the cost.
- No data can cross the boundary: `Float64`/`String`/`Bool` only (E4200),
  `Int64` refused, no pointers, arrays, structs, or callbacks. `String` is
  a NUL-terminated `char *`, so it cannot even carry a binary payload.
- A function that calls a `foreign def` is excluded from specialization and
  drags its callers into the dynamic world.
- The specialized emitter's `try ... with Native_return` return convention
  defeats tail-call optimization, making the specialized build ~4x slower
  than its own unspecialized build for the language's only loop idiom and
  overflowing the stack at 100M depth.

A self-contained backend removes all four by construction: the C ABI is
Emo's calling convention, so no wrapper and no boxing; a `return` is a
branch to the epilogue, so tail calls survive; width types and pointers
land on their C shapes.

## Goal (if scheduled)

`emo build --target <host-native>` produces a standalone binary that links
no OCaml runtime: Emo's own runtime (allocator, strings, dynamic values,
scheduler) plus `libc`, with `foreign def` mapping directly onto the C ABI.
The target is hosted, so unlike step 22 it may assume an OS, libc, and a
system linker; the difference from step 22 is the substrate, not the value
model.

## What is already in place

The workspace is unusually well set up for this, which is why the difficulty
is engineering rather than research:

- **Front end is target-independent.** Lexer, parser, checker
  (`src/emo_check`) need no change.
- **`Emo_ir` is the shared lowering target.** `emo_wasm.ml` (~3.6k lines),
  `emo_beam.ml` (~1.6k), and `emo_ts.ml` (~0.6k) all lower from it, not from
  the AST. A new backend is a new emitter, not a new compiler.
- **Semantics are pinned by golden tests.** Every example's compiled output
  must match `emo run` byte-for-byte (step 13's acceptance). The new backend
  has a referee; `%g` float printing, content equality, interpolation, and
  the rest have prior art in the wasm and BEAM backends.
- **A dynamic value model is already designed** (step 22): one tagged word;
  8-byte-aligned heap cells with 3 low bits as the kind tag; `Int64`/
  `Float64` as boxed two-word cells in the dynamic world; NaN-boxing
  rejected so bit-casts round-trip.
- **A C-interop ladder is already written** (step 14 note): scalars → width
  types → opaque handles and copied buffers → structs and callbacks →
  header ingestion.
- **The scheduler has a reference model.** `emo_sched_det.ml` is the
  deterministic scheduler the bare-metal and hosted targets can be diffed
  against.
- **A precedent for "emit and delegate."** The native backend emits OCaml;
  the BEAM backend emits Core Erlang; riscv64 emits assembly for GNU
  binutils. Emitting C for a hosted target is the same pattern with a
  shorter distance to the C ABI.

## Difficulty by layer

Order-of-magnitude only; the anchors are the shipped backends' sizes.

| Layer | Difficulty | Notes |
| --- | --- | --- |
| IR → target emitter | moderate | Mechanical but verbose: the dynamic world is tag checks and boxed runtime calls; the specialized world needs unboxed paths. `emo_wasm.ml` is the precedent. |
| Target choice (C / LLVM IR / assembly) — recommended: emit C | decision | Determines the tail-call strategy, the SIMD ceiling, and the toolchain dependency. See "The codegen route" below. |
| C runtime (string, Bytes, tuple, instance + vtable, enum, exceptions, printing) | moderate–high | Must match existing semantics exactly; large but well-specified by the goldens. |
| Reclamation without a tracing GC | **high** | The crux; see below. |
| C FFI rungs 1–3 | low | Owning the ABI makes scalars, width types, and opaque handles + copied buffers nearly direct. |
| C FFI rung 4 (struct by value, callbacks) | high | Platform layout knowledge and a re-entrant runtime. |
| Exceptions | low | Branch-to-epilogue for `return`; a catch form is still open in `CHECK.md`. |
| Processes and scheduler | moderate | Cooperative-first, copied messages, a textbook context switch; step 14 rates the policy "easy 15–20%" and the substrate the cost. |
| `Int64` semantics | **easier than today** | A hosted backend uses `int64_t` directly, which retires the OCaml 63-bit deviation (`CHECK.md`) rather than working around it. |

A whole emitter is roughly 0.6k–3.6k lines of OCaml; a hosted Emo runtime is
roughly 2k–4k lines of C. That puts a first working tier in the
person-weeks-to-months range, not years.

## The three hard problems

### 1. Reclamation without a tracing GC

This is the only genuinely theoretical difficulty, and it is a design
problem more than a coding problem. With no collector, memory is reclaimed
by one of a few known schemes:

- **Arena / bump, program lifetime** — simplest to build (step 22's M1),
  but it leaks unboundedly. Viable for one-shot compute or bounded programs,
  not for long-lived services.
- **Reference counting** (the Swift / Objective-C lineage) — no tracing, so
  no stop-the-world; deterministic. It fits Emo unusually well, because
  Emo's value semantics (immutable arrays, instances copied on assignment)
  mean shared mutable aliasing is rare and reference cycles are rare. The
  pressure points are `Box`, mutually referencing instances, and mailbox
  queues. On more than one hart the counts need to be atomic.
- **Explicit regions** — clean semantics, but it adds to the language
  surface.

The constraint that makes this hard is deliberate: Emo's type system has no
ownership, lifetime, or linearity annotations, and the project's philosophy
excludes the Rust-shaped mechanisms that would supply them. So without a
language-surface addition, the dynamic world's only fully general no-GC
option is reference counting; the alternative is to bound programs to
arenas. For the **specialized numeric tier** the problem does not exist at
all — stack and unboxed values need no management — which is precisely the
tier HPC cares about. The difficulty is confined to the dynamic, escaping,
and message-passing paths.

### 2. Guaranteed tail calls through the codegen route

Emo has no loop keyword; iteration is tail recursion, and tail calls are
guaranteed (README, Concurrency). C does not guarantee tail-call
optimization. A backend that emits C must therefore preserve them itself,
by one of:

- a **trampoline / block-loop lowering** in the emitter: a self- or
  mutually-tail call becomes a parameter rebind and a jump to the function
  head;
- **LLVM `musttail`**, at the cost of an LLVM dependency;
- **direct assembly** with a tail pseudo-instruction (step 22's route).

This is a fork in the road that must be chosen before the emitter is
written, because it constrains the IR lowering. It is also the fix for the
current backend's worst performance bug: with `return` as a branch to the
epilogue rather than a raised local exception, the loop benchmark that is
today ~4x slower specialized than unspecialized stops being an outlier.

### 3. What "seamless" means for C FFI

Owning the ABI makes the *mechanism* easy: `foreign def` maps to the
platform calling convention, scalars and pointers pass directly, and the
generated C wrapper of the current backend disappears. The cost is in the
boundaries:

- **Lifetime and ownership.** With no collector, values do not move, which
  helps; but the compiler has no way to know how long C will hold a pointer.
  The tractable answer is agreement, not inference: externally owned
  pointers are opaque handles closed explicitly (ladder rung 3).
- **Callbacks.** A C library that calls back into Emo (a solver, an
  iterator, an event loop) needs Emo's calling convention exposed as a C
  function pointer and a **re-entrant** runtime — which interacts with the
  cooperative scheduler if one is present.
- **Struct by value.** Either the emitter knows each platform's layout
  (brittle) or it generates `offsetof` accessor thunks so the C compiler
  owns the layout (ladder rung 4).
- **The HPC entry point.** Handing a `Float64` block to BLAS needs a
  mutable, address-stable, typed buffer. No such type exists today; this is
  a language-surface gap, not a backend gap (see below).

## What Emo's semantics help and hurt

**Help:**

- Value semantics and immutable sharing suit reference counting and reduce
  cycles.
- Guaranteed tail calls and no loop keyword keep control flow simple.
- Structural interfaces with compile-time vtables (step 22) remove runtime
  method lookup — the current backend's string-keyed `Hashtbl` dispatch
  goes away.
- Fixed arity, no varargs, no by-value aggregates make the psABI
  convention its simple form (step 22's note).
- Width-explicit numerics land directly on C types.
- Cooperative, copy-message concurrency on one hart is lock-free and
  atomic-free.

**Hurt:**

- Gradual typing keeps a dynamic layer that needs a runtime and a
  reclamation scheme.
- Immutable arrays and copy-on-assignment are safe but force a copy at
  gigabyte scale unless a new mutable buffer type exists.
- No ownership or region annotations (by philosophy) leave no-GC
  reclamation to reference counting or bounded arenas.
- Exceptions, processes, and closures all escape and therefore allocate.

## HPC is more than a backend: Go as a reference sample

Go is the closest real-world control for this file's premises: a
garbage-collected language with its own native backend (the default
`cmd/compile` does not use LLVM), a concurrent non-generational
non-moving collector, and a C FFI (`cgo`). It is not an HPC language. The
reason is instructive, because it is not the collector.

- **GC is not the decisive factor.** HPC hot loops do not allocate, so the
  collector does not run there; numeric writes are not pointer writes, so
  the write barrier is not paid. What remains is memory headroom (~2x by
  default), mark work that scales with the heap, and pause jitter —
  matters of latency and predictability, not throughput. No-GC is a good
  argument for a control plane or bare metal, not for a fast kernel.
- **The decisive factors are four, in priority order:**
  1. **Vectorization / SIMD.** Go does not autovectorize; SIMD exists
     only via hand-written assembly or `cgo`. This is the bulk of the gap
     to C/Fortran — roughly 1.5–3x on plain loops, far more where SIMD
     dominates. A backend that does not vectorize leaves HPC performance
     on the table however clean its scalar code is.
  2. **Data-parallel primitives.** An OpenMP-style parallel loop with
     reductions, plus thread affinity and NUMA control, has no
     language-level equivalent in Go (`goroutine` plus `WaitGroup` is not
     a substitute). Emo has none today either.
  3. **Zero-copy FFI buffer passing.** `cgo` can lend a slice pointer to C
     for the duration of a call, provided C does not retain it and the
     memory holds no Go pointers — enough for `cblas_dgemm(&a[0], …)`,
     amortizing the call cost over a whole kernel.
  4. **Ecosystem.** BLAS/LAPACK/FFTW/MPI/CUDA bindings; thin in Go, empty
     in Emo.
- **Consequence for the codegen route.** The four factors argue for
  emitting C over hand-written assembly: the vectorizer is the point.
  Assembly stays the right choice only for the freestanding `riscv64`
  target, where SIMD throughput is not the goal. The route is settled in
  the next section: emit C, not LLVM.
- **A lesson for the FFI ladder.** The `cgo` model adds a rung between
  step 14's "copied buffers" and "opaque handles": **borrow for the
  call** — C receives a pointer valid only until it returns. It is
  zero-copy, safe under a non-moving layout, and the natural default for
  a `Buffer[Float64]` handed to BLAS.
- **Recalibration.** A self-contained backend removes three ceilings
  (boxing, the wrapper FFI, and the OCaml backend's lack of
  vectorization) but is necessary and not sufficient. No GC is a
  predictability and bare-metal argument, not an HPC entry ticket.

## The codegen route: emit C, not LLVM

The route is the decision everything else hangs on, and the
recommendation is **emit C** — with LLVM ruled out and assembly confined
to the freestanding target.

The reasoning is partly the project's own. `docs/native-backend.md` chose
to emit OCaml *source* rather than construct compiler-libs trees because
source text is one stable contract, the generated file is readable and
debuggable, and the host optimizer still applies. The same argument holds
verbatim with "C" in place of "OCaml". LLVM inverts it:

- **A C++ dependency with an unstable API.** LLVM's C++ interface changes
  between releases; binding it turns every upgrade into a backend
  migration — the exact cost emitting source was chosen to avoid.
- **Opaque generated code.** The semantics disappear into a toolchain no
  one on the project can read, against the "code a user can open"
  standard.
- **Heavy, and its headline features are unneeded here.** GC statepoints
  (the plan is no tracing GC), a JIT (the plan is ahead-of-time), and many
  targets (Emo has a handful) are all moot.
- **No new dependency.** `emo build` already invokes `cc` for the FFI
  stubs; emitting C reuses it. LLVM would be the new dependency.

What emitting C buys:

- **The vectorizer.** GCC/Clang autovectorization is the SIMD engine the
  OCaml backend never had — a small team inherits it instead of owning
  one.
- **Parallelism for free.** `#pragma omp simd` and `#pragma omp parallel
  for` can be emitted directly, at the cost of an optional OpenMP runtime.
- **A trivial FFI surface.** The output is already C: `foreign def` is a
  declaration and a call, and a `Buffer[Float64]` is a `double *`, so the
  FFI data channel closes as a side effect.
- **Debuggability.** Readable C, gdb, and perf.
- **A second life as the portable backend.** The same C compiles to wasm
  (`clang --target=wasm32`) or bare metal (`riscv64-elf-gcc -ffreestanding
  -nostdlib` plus a startup stub), which may cut into how much of step
  22's assembly backend must be hand-written.

The cost is four things the emitter must own:

1. **Tail calls.** C does not guarantee TCO; the emitter lowers self- and
   mutual-tail calls to a parameter rebind and a jump to the function head
   (a trampoline / block loop).
2. **Wrap-around `Int64`.** Signed overflow is undefined in C; emit
   `uint64_t` arithmetic with casts back, or compile with `-fwrapv`.
3. **Aliasing for the vectorizer.** Copy-on-write and immutable arrays
   make aliasing hard for the compiler to disprove; the emitter marks
   `restrict`, keeps inner loops simple, and uses `omp simd` where it
   matters.
4. **The dynamic layer.** Tagged unions and `retain`/`release` reference
   counting in C; exceptions via `setjmp`/`longjmp` or a branch to the
   epilogue.

Alternatives considered, and why not:

| Route | Optimization / SIMD | New dependency | Readability | Tail calls | wasm / bare-metal reuse | HPC fit |
| --- | --- | --- | --- | --- | --- | --- |
| **emit C** | GCC/Clang optimizer + autovectorization; OpenMP available | none (`cc` already needed) | high | emitter trampoline | high | **good** |
| LLVM IR | strongest | LLVM (C++, heavy, unstable API) | low | `musttail` | medium | good |
| direct assembly | whatever is written; no vectorizer by default | binutils | medium | native | target-specific | poor |
| QBE | basic; no vectorization | QBE (small, C) | high | basic | medium | poor |
| libgccjit | GCC optimizer + vectorization | libgccjit (heavy, ties GCC) | medium | — | low | good but heavy |
| Cranelift | moderate | Rust ecosystem | medium | — | medium | moderate |

QBE is simple but does not vectorize, which removes the point; libgccjit
vectorizes but makes GCC a heavy runtime dependency; direct assembly owns
register allocation and still has no vectorizer. None beats emitting C for
this design.

## What HPC still needs beyond the backend

The backend removes three ceilings — no boxing or tags for specialized
code, a direct C ABI for BLAS/LAPACK/FFTW, and (via the C route)
auto-vectorization that the OCaml backend never had. Against the
four gates above it is necessary but not sufficient. Two language-surface
pieces remain, both prerequisites for a BLAS-shaped workload:

1. **A mutable, address-stable, typed buffer** (`Buffer[Float64]` or
   equivalent), handed to C under the borrow-for-the-call lifetime above.
2. **A parallel construct** for shared-memory compute, with reductions;
   today concurrency is actor/message-passing over effects, with no
   parallel loop.

Without these, the backend alone gets scalar leaf calls and single-threaded
kernels. No-GC is a latency and bare-metal argument, not a substitute for
either.

## A recommended sequencing (if scheduled)

1. **Specialized subset only, emitting C**: stack allocation, unboxed
   numeric code, a bump/arena allocator, no dynamic objects. This is
   enough for HPC kernels and is the cheapest path to the C ABI.
2. **Static C runtime**: string, Bytes, tuple, instance + vtable, enum,
   exceptions, printing; reference counting for the dynamic layer.
3. **C FFI rungs 1–3** fall out of the ABI.
4. **Scheduler**, diffed against `emo_sched_det`.
5. Optimization: register allocation, inlining, SIMD.

## Decisions that must settle before implementation

Registered in `CHECK.md`:

1. **Codegen route** — recommended: emit C, with LLVM ruled out and
   assembly confined to the freestanding target (see "The codegen route"
   above). Emitting C makes the C ABI the FFI surface, reuses the existing
   `cc` dependency, and yields the GCC/Clang vectorizer and OpenMP pragmas.
   The emitter must own tail-call lowering, wrap-around `Int64`, aliasing
   for the vectorizer, and the dynamic layer.
2. **Reclamation model** for the dynamic world — reference counting versus
   bounded arenas with explicit leakage, and whether either implies a
   language-surface addition. This is the decision that keeps "no GC" from
   becoming "leaks on long-running programs".
3. **HPC surface** — the mutable typed buffer (zero-copy, borrow for the
   call), the parallel construct, and the vectorization the codegen route
   must deliver. These are the HPC gates in priority order, ecosystem
   aside; backend work without them cannot reach library-scale numerics.

## Open design items

- Whether the dynamic value layout for a hosted target matches step 22's
  tagged word exactly (pointer tagging on hosted x86-64/arm64 is fine) or
  differs from the freestanding one.
- Whether the runtime is written in C (portable, links libc directly) or in
  Emo's own specialized subset (bootstrapping pressure, single-language
  closure). Step 14's strategic framing — "C interop is a bridge, not a
  foundation" — argues for C for the runtime and Emo for the policy above
  it.
- How `foreign def` availability is declared per target, given the open
  `CHECK.md` item that non-native targets must not silently miscompile it.

## Promotion trail

Recorded 2026-10-06 as an assessment, not a scheduled step. If scheduled it
follows step 14's promotion rule: split into a full `step-NN` with the
standard goal / scope / tasks / acceptance format, update `plan/README.md`'s
status table, and settle the three decisions above in `CHECK.md` first.
