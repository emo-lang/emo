# Step 24 — C target (emit C)

**Milestone:** M8 — the self-contained hosted backend (step 23's assessment, scheduled) · **Prereq:** steps 01–13 (the IR and the
specialization data) · **Related:**
`plan/step-23-hosted-native-ffi.md` (the design record this step
schedules — the assessment holds; this file only adds what execution
needs), `plan/step-22-riscv64.md` (the tagged-word value model),
`docs/native-backend.md` (the emit-and-delegate precedent) ·
**Status:** in progress — T24.1–T24.10 done

## Why this step exists

`docs/native-backend.md` is explicit that the shipped native target
emits OCaml source and links the OCaml runtime. That bought a fast
path to a working backend, and it is the ceiling on numeric code and
C interop: the FFI round trip costs ~43 ns all-in (the boxed calling
convention around the call, not the call), only `Float64`/`String`/
`Bool` cross the boundary (E4200 otherwise), a function that calls a
`foreign def` is excluded from specialization and drags its callers
with it, and the `try … with Native_return` return convention
defeats tail calls — the specialized build is ~4x slower than its
own unspecialized build on the language's only loop idiom. The
numbers are in `benchmarks/results.md` and
`docs/industrial-software.md`.

Step 23 assessed the self-contained hosted backend and recommended
its route — **emit C** — without scheduling it. This step schedules
it: the settled route is followed as written, and what execution
needs beyond the assessment (a golden progression, a task split
sized for spare sittings, and the decisions that must close before
the emitter exists) lives here.

## Goal

`emo build --target c` emits C source, compiles it with the system
`cc`, and links a standalone binary that loads no OCaml runtime: an
Emo runtime written in C (allocator, strings, dynamic values,
scheduler) plus libc. The hosted substrate may assume an OS, libc,
and a system linker; the difference from step 22 is the substrate,
not the value model. `foreign def` maps directly onto the C ABI —
the generated-wrapper mechanism of the OCaml backend disappears.

The OCaml-emitting backend is untouched until this one covers the
golden subset; `c` is a separate `--target` value coexisting with
it. Per the backend-naming decision (`CHECK.md`), `c` is reserved
and enters `known_targets` only once its first golden lands
(T24.1).

## Decisions settled here (before T24.1)

- **Tail-call lowering — settled: the trampoline / block loop.**
  Every self- or mutually-tail call lowers to a parameter rebind
  and a jump to the function head; `return` is a branch to the
  epilogue, never a raised signal. Step 23 marks this the fork in
  the road that must be chosen before the emitter is written; it
  is also the fix for the current backend's ~4x loop regression.
- **Wrap-around `Int64` — settled: unsigned arithmetic.** Emit
  `uint64_t` operations and cast back; `-fwrapv` is the documented
  fallback, not the plan.
- **Reclamation — still open; bump/arena is the provisional
  profile.** The specialized numeric tier needs no management
  (stack and unboxed values), so the first tiers land before the
  decision does. Settle reference counting vs bounded arenas in
  `CHECK.md` before any long-running dynamic program ships — this
  gates T24.5.
- **HPC surface — out of scope.** The mutable typed buffer, the
  data-parallel construct, and the ecosystem rungs remain the gate
  *beyond* this backend (`CHECK.md`); step 24's acceptance does
  not wait on them.

## Tasks

- [x] **T24.1** — Design-gate closure and the backend skeleton:
      record the settlements above in `CHECK.md`; the emitter
      module in `src/emo_codegen` plus the `--target c` CLI arm
      (emit `main.c` + runtime sources, invoke `cc`, single
      binary); entry stub, hosted startup, `println` over stdio.
      `"c"` enters `known_targets` here, with the resolution-gate
      refusal test for packages lacking it. Golden: hello_world,
      byte-for-byte vs `emo run`.
- [x] **T24.2** — Tail calls and the integer core: the trampoline
      (self- and mutual-tail calls; `return` as
      branch-to-epilogue); wrap-around `Int64` on `uint64_t`;
      comparisons, `if`, integer formatting with `INT64_MIN`
      correct. Goldens: fib; the 1M-deep `count_down` stays flat
      on the C stack; the `loops_tail` number lands in
      `benchmarks/results.md`. (Done 2026-10-06: 4 ms against the
      OCaml backend's 1910 ms specialized build; examples/fib's own
      golden waits on closures — T24.5 — the c_integer fixture covers
      the core; the span-type-table fix this needed is recorded in
      docs/TASKS.md.)
- [x] **T24.3** — The scalar runtime: length-prefixed strings
      (NUL-terminated only at the FFI boundary), the `%g` float
      printing rule, `Bool`/`Char`, interpolation, scalar content
      equality. Goldens: numerics, if_expr. (Done 2026-10-06: if_expr
      is the first full-example golden; numerics waits on foreign defs
      (T24.8) and tuples (T24.4) — the c_scalar fixture cross-checks
      the printing rules against the interpreter's rendering. The
      string-layout and runtime-in-C decisions are in CHECK.md.)
- [x] **T24.4** — The dynamic value model: step 22's tagged word —
      8-byte-aligned heap cells, 3 low tag bits, `Int64`/
      `Float64` as boxed two-word cells (no NaN-boxing), `Bool`/
      `Char` immediates; the bump/arena allocator (provisional
      profile); tuples, value-semantic arrays, `Box`. Golden:
      objects. (Done 2026-10-06: one `emo_value` word — low bits
      000/001/011 for pointer/Bool/Char, kinds in the cell header —
      bump allocation, regime conversion bridging native and dynamic
      code, runtime dispatch for dynamic `+`/comparisons/equality.
      The objects golden waits on classes — T24.5; the c_dynamic
      fixture cross-checks against the interpreter's rendering.)
- [x] **T24.5** — Classes, enums, interfaces, closures: instances
      with compile-time vtables, enum singletons, structural
      `is()`, first-class functions, patterns with guards. The
      reclamation decision lands in `CHECK.md` before this task
      merges. Golden: language_tour. (Done 2026-10-06: language_tour
      and objects both full-example goldens; the reclamation
      decision — refcounting for identity objects, arena for
      value-semantic data — is recorded in CHECK.md, with the
      retain/release emitter work scheduled before T24.9.)
- [x] **T24.6** — Modules and exceptions: multi-file module
      references, `raise`, uncaught-exception exit codes.
      `begin`/`catch`/`ensure` is settled surface but
      unscheduled — out of scope here. Goldens: shop,
      function_group (free via IR lowering; claim the golden).
      (Done 2026-10-06: both claimed; the cross-module call regime
      and the IR's alias/thunk handling needed fixing, recorded in
      docs/TASKS.md.)
- [x] **T24.7** — The systems-layer surface: `Bytes`
      (bounds-checked, little-endian accessors), the bitwise
      operators, `Byte`, `Int64`/`Float64` bit-casts. Goldens:
      bit_ops, bytes, fixed_width.
- [x] **T24.8** — C FFI rungs 1–3 on the direct C ABI — no wrapper
      generator. Scalars (`Float64`/`String`/`Bool`), width types
      as they land (`Int64`/`Int32`/`Float64`/`Float32` →
      `int64_t`/`int32_t`/`double`/`float`), opaque handles with
      explicit close plus copied buffers; borrow-for-the-call is
      the documented contract of the later BLAS rung. The
      check-time capability table flips `c` to honoring
      `foreign def`. Goldens: a libm `sqrt` fixture and a tiny
      C-library opaque-handle fixture under `test/`.
- [x] **T24.9** — Processes and the cooperative scheduler:
      `do` / `<-` / `receive`, mailboxes, selective receive,
      `self_pid`, `halt`; single-threaded cooperative loop;
      execution traces diffed against `emo_sched_det`. Goldens:
      pipeline, showcase.
- [x] **T24.10** — Hosted IO and stdlib metadata: `file.read` /
      `file.write`, TCP/UDP sockets, the HTTP client/server over
      the hosted OS; stdlib packages gain `"c"` in their
      `targets`. Goldens: file_read, tcp_echo, http_roundtrip.
- [ ] **T24.11** — Bootstrap, benchmarks, and close-out: the
      `c_examples` CI group (cc is preinstalled on the Linux and
      macOS runners); the specialization passes (unboxing, direct
      dispatch) behind the IR's Stage B checks, with `restrict`
      on emitted hot loops; `benchmarks/results.md` gains the `c`
      column (loops_tail, fib, bytes_scan, json_parse, ffi_call,
      http_echo) against the OCaml backend; the `native` →
      `ocaml` rename (`CHECK.md`) lands here or in its own step
      immediately after; close-out records the decisions.

## Acceptance

- `emo build --target c` produces a working binary through the
  system `cc`, with no OCaml toolchain involved.
- The golden subset — hello_world, fib, objects, language_tour,
  shop, pipeline, function_group, bit_ops, bytes, fixed_width,
  file_read — prints byte-for-byte what `emo run` prints, in CI.
- `foreign def` crosses the C ABI on this target (scalars, width
  types, opaque handles); the target-capability table says so.
- A package whose `targets` exclude `"c"` fails at resolution.
- `dune test` green; `benchmarks/results.md` records the `c`
  numbers.

## Open design items

- ~~String layout at the FFI boundary~~ — settled at T24.3 (CHECK.md):
  `emo_str {len, bytes}`, NUL only when crossing.
- ~~The runtime written in C vs Emo's specialized subset~~ — settled
  at T24.3 (CHECK.md): C.
- Whether `Int32`/`Float32` have landed in the language by T24.8;
  rung 2 rides their schedule.
- Whether the `native` → `ocaml` rename rides T24.11 or splits
  into its own step (`CHECK.md` allows either).

## Close-out

Recorded when the acceptance above is met.
