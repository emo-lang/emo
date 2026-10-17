# Step 15 — Other Targets: Wasm, TypeScript, BEAM, RISC-V Bare Metal

**Milestone:** M4 roadmap · **Prereq:** steps 01–14 (per target, below) ·
**Status:** complete (2026-10-17 — all four targets promoted to steps
16–19, their decision trails recorded, and step 16's WASI/IO audit
closed with an honest refusal)

## Goal

The remaining README compilation targets, each a sub-project with its own
prerequisites and risk profile. This file began as the roadmap entry —
not an execution-ready plan — for all four, with the recommendation to
schedule each as its own detailed step file in the same format. That
split has happened: Wasm is step 16, TypeScript step 17, BEAM step 18,
and riscv64 step 19. The notes below stay as the design record for the
questions the roadmap posed, and the promotion trail at the end records
where each was settled.

## WebAssembly

- **Strategy:** compile the step 14 IR to Wasm; start with WASI
  (command-line programs, filesystem, sockets via WASI where available),
  browser embedding (`fetch` / WebSocket bridging) after.
- **Key decisions:** WasmGC vs a custom GC for Emo values (WasmGC aligns
  with every-value-carries-a-tag only partially — struct-of-payload designs
  need care); module loading under the WASI sandbox. *Settled: WasmGC,
  no custom heap; T16.5's WASI/IO audit closed the remaining question in
  favor of refusing network packages — see the promotion trail.*
- **Prereq:** IR from step 14; stdlib target metadata extended with
  `"wasm"`.
- **Risk:** GC strategy is the whole game; prototype both before choosing.

## TypeScript

- **Strategy:** transpile the checked AST to TypeScript; gradual types map
  naturally (Emo type declarations → TS types, `Unknown` → `any`-free
  escape hatches to be defined). The runtime value tags become a thin TS
  runtime library.
- **Key decisions:** the direct-style problem — step 13's blocking calls
  must map onto the event loop (Promise-returning internals with an
  ergonomic surface); how processes map to workers or cooperative tasks.
  *Settled: lowering from the IR, a uniform async mapping, and
  cooperative tasks (step 17) — see the promotion trail.*
- **Prereq:** step 09 (checker feeds type declarations); no IR dependency — the
  AST suffices, or reuse IR if it simplifies.
- **Risk:** function coloring leaks backwards from TS's ecosystem; keep
  the Emo surface direct-style and absorb the mapping in the emitted code.

## BEAM

- **Strategy:** lower to BEAM core Erlang; process/mailbox semantics map
  natively (the design was chosen for this). Types are compile-time only —
  full erasure at runtime.
- **Key decisions:** value semantics for classes vs Erlang maps;
  exceptions → errors; tail calls are native; the mutable cell →
  process-dictionary-free design (an ordinary process-held state pattern),
  snapshots already match BEAM copying. *Settled in step 18's Scope and
  "Decisions settled here": instances are tagged maps, and Box is a
  holding process.*
- **Prereq:** steps 09 and 11 (semantics frozen); stdlib surface audit for
  BEAM-unsupported operations.
- **Risk:** low semantically, moderate in tooling (rebar/OTP integration,
  releases).

## Bare metal — `riscv64` (last)

- **Strategy:** freestanding RISC-V images: no
  OS, no libc, pluggable runtime (allocator, GC, scheduler as
  replaceable components). The target is named for the ISA —
  `riscv64` — and QEMU is its default runner (the no-hardware dev
  loop), not part of the target; the same image runs on real hardware
  (decided 2026-10-05, replacing the earlier `qemu` target name).
- **Layering:** the `core` library layer (integers, strings, tuples,
  control flow — zero runtime dependencies) is the only surface available
  to kernel code; the standard library requires the full runtime. This
  split is a *library-architecture* task that should actually be pulled
  earlier — flagged in `plan/README.md` reviews.
- **Explicit memory primitives** (`peek` / `poke` and friends) as
  visibly-named core-library functions — dangerous reads dangerous.
- **Numeric width is target-independent:** `Int64` is 64-bit two's
  complement with wrap-around on every target, and numeric types are
  width-explicit (`docs/numeric-width.md`), so a future `riscv32` is a
  pure codegen problem — register-pair arithmetic, the same technique
  as the native backend's 64-bit route; there `Int32` is the
  register-width fast path and `Int64` the emulated one. Narrowing
  `Int64` on RV32 is off the table.
- **Prereq:** step 14 Stage B (specialized, lean codegen); a custom or
  minimal GC story; linker scripts.
- **Risk:** highest of the four; also the most speculative.

## RISC-V reference note (recorded 2026-10-05)

Everything decided or assessed about the `riscv64` target so far, kept
in one place so the future implementation step starts from here instead
of re-deriving it.

### Target identity and current state

- Named for the ISA (`riscv64`); QEMU is the default runner (the
  no-hardware dev loop), not part of the target — the same image runs
  on real RISC-V hardware (decided 2026-10-05, replacing the earlier
  `qemu` name).
- At assessment time (2026-10-05) it was declaration-only: `known_targets`
  in `emo_pkg.ml` admitted `"riscv64"` for manifest resolution, with no
  backend. The backend landed in step 19 (2026-10-11); `riscv32` does
  not exist and is not scheduled — it follows `riscv64` only when real
  hardware demands it.
- Freestanding contract: no OS, no libc, no default runtime; allocator,
  GC, and scheduler are replaceable components; `core` is the only
  library layer available to kernel code; `peek`/`poke` are the
  explicitly dangerous memory primitives.

### Numeric width (full rationale in `docs/numeric-width.md`)

- Numeric types are width-explicit: `Int64`/`Int32`, `Float64`/
  `Float32`; the defaults are `Int64` and `Float64`; there are no
  width-less `Int`/`Float` spellings and no aliases; integer/float
  literals without type declarations default to the 64-bit type (decided
  2026-10-05).
- `Int64` semantics are target-independent: 64-bit two's complement,
  wrap-around modulo 2⁶⁴. On RV64 an `Int64` is one register. A future
  RV32 implements the same semantics with register pairs (carry-chain
  add/sub, hi/lo mul/div — the textbook `long long` technique, ~2–4×
  arithmetic cost, 8 bytes per value). Narrowing `Int` on RV32 is off
  the table — that would be a different language.
- On RV32 the roles invert: `Int32` is the register-width fast path
  and `Int64` the emulated one — semantics unchanged, performance
  characteristics differ by target. This is why `Int32` is the RV32
  hot-loop escape hatch.
- `Float64` needs no fix: IEEE 754 binary64 on every target today
  (OCaml `float`, Wasm `f64`, Erlang float, JS `number`). `Float32`
  (binary32, per-operation rounding — correctly rounded via a binary64
  ALU) joins later for C `float` FFI, device registers, and memory
  bandwidth.
- Settled (2026-10-11, `CHECK.md` "Numeric width"): the native
  backend's route to 64-bit integer arithmetic on OCaml's 63-bit `int`
  is boxed `Int64` — already the shipped route. The unboxed two-word
  hi/lo emulation was not taken; its RV32 motivation is moot now that
  the freestanding target is `riscv64` with native 64-bit registers, and
  the `c` target answers the performance question.
- FFI relevance: the width types are the landing types `foreign def`
  needs on bare metal (`int64_t`/`int32_t`/`double`/`float`); today
  only `Float`/`String`/`Bool` cross (E4200 otherwise).

### Dynamic value representation (study, 2026-10-05)

- The freestanding target is the first that must lay the dynamic value
  out itself — every shipped target delegates it (OCaml variant,
  WasmGC structs, BEAM tuples, JS objects). The scheme, settled in
  `plan/step-19-riscv64.md`: one tagged machine word per value; heap
  blocks 8-byte aligned with the 3 free pointer bits as the kind tag;
  Bool and Char immediate.
- **`Int64`/`Float64` are boxed two-word cells in the dynamic world** —
  the decided wrap-around semantics need all 2⁶⁴ bit patterns, so a
  tagged immediate cannot exist and the OCaml 63-bit shortcut is
  unavailable here. The CHECK.md open decision (boxed `Int64` vs hi/lo
  emulation) is scoped to the OCaml-hosted native backend and
  unaffected.
- NaN-boxing rejected: `Float64` must round-trip bit patterns (the
  `Bytes`/`Float` bit-casts), and a 64-bit integer payload cannot share
  the word with a tag.
- GC-readiness is free under tagging — an immediate is never a valid
  pointer, so a future precise collector scans stacks and heap without
  a layout change; the bump allocator stays until then.

### Boot profiles (probed, 2026-10-05)

Two ways to run under QEMU `virt`; the milestones table below had
conflated them before this split, settled in `plan/step-19-riscv64.md`:

- **Profile A — OpenSBI-hosted (the M1 profile).** The default
  `-kernel` chain: OpenSBI at 0x80000000 enters the payload at
  **0x80200000** in S-mode (`a0` hart id, `a1` DTB pointer). Console =
  the legacy SBI ecall (`a7=1` putchar), clean exit = `a7=8`; probed
  end to end against binutils 2.45 / QEMU 11.1.1 / OpenSBI v1.8.1. No
  UART driver needed.
- **Profile B — `-bios none` true bare metal.** The image itself at
  0x80000000, M-mode, every hart entering there: own 16550A UART driver
  (MMIO at 0x10000000 on `virt`), own timer access. For when the kernel
  owns the machine — not an M1 need.

### Process scheduler on QEMU riscv64 (assessment)

Question assessed: how hard is an Emo process scheduler on RISC-V under
QEMU? The split: **the scheduler itself is the easy ~15–20%** — the
semantics were settled in step 12 and already implemented three times
(interpreter runtime, Wasm driver loop, BEAM processes) with golden
tests; the hard part is the substrate beneath it (the codegen backend
plus the freestanding runtime).

Favorable factors, specific to Emo:

- The deterministic scheduler (`emo_sched_det`) lets the bare-metal
  scheduler be validated by comparing execution traces against the
  deterministic model on the host — before anything runs under QEMU.
- Emo does not promise preemption: cooperative-first scheduling
  (switching only at send/receive) skips trap handlers and timer
  plumbing entirely at first.
- Message passing copies (snapshot semantics) — processes share no
  mutable state, so the scheduler loop is single-hart, single-threaded,
  lock-free, no atomics.
- The RISC-V context switch is textbook: swap `sp`, `ra`, and the
  callee-saved `s0–s11` — roughly 30 instructions of assembly.

Mechanism/policy split — the key architecture decision:

- The context-switch thunk (stack swap) is below Emo's abstraction
  level (`peek`/`poke` cannot reach register sets): hand-written
  assembly, kept minimal.
- Scheduling policy (run queues, round-robin, priorities,
  wake-on-send, mailbox queues) is plain Emo code running on the
  substrate — the first customer of the "scheduler as a replaceable
  component" promise. Develop the policy in Emo on hosted targets
  against the deterministic scheduler, then deploy the same policy
  onto bare metal.

Milestones:

| Milestone | Content | Difficulty |
| --- | --- | --- |
| M1 | riscv64 backend (emit assembly text for cross-binutils, mirroring step 14's emit-and-delegate pattern), boot stub under profile A (OpenSBI-hosted S-mode at 0x80200000: set stack, clear BSS, park non-boot harts), SBI console for `println`, "Hello, world" under `qemu-system-riscv64` | high — the dominant cost of the whole effort |
| M2 | cooperative scheduler: ≥2 processes, send/receive, round-robin, no preemption | moderate-low |
| M3 | timer preemption: `stvec` trap handler, SBI `set_timer`, time slices | moderate — optional; semantics do not require it |
| M4 | multi-hart SMP (per-hart run queues, IPIs, LR/SC atomics) | high — defer indefinitely |

QEMU specifics that lower the bar: the `virt` board's memory layout is
fixed (no device-tree parsing needed for the first cut); OpenSBI
firmware provides the console ecall, so no UART driver is required to
get `println`; `-bios none` is available for true bare metal later;
`-s -S` plus remote gdb (riscv64-elf-gdb) gives a real debugger from
day one; start with `-smp 1`.

De-risking shortcut — a hosted intermediate milestone: cross-compile
the existing native-backend product (OCaml 5 supports riscv64 native
code) with a riscv64 Linux toolchain and run Emo processes on QEMU
riscv64 **Linux userland** first. The scheduler runs unchanged on
RISC-V at a fraction of the bare-metal cost, and it separates "is the
codegen right" from "is the freestanding substrate complete".

Substrate checklist (what M2's scheduler sits on): entry stub; SBI
console ecall for `println`; bump allocator (GC deferred — the no-GC
pluggable-runtime configuration also removes the scan-process-stacks
problem); per-process fixed-size stacks with canaries (no guard pages
in the first cut); the context-switch thunk; run queue, mailbox queues,
pid allocation, halt/exit handling. Order-of-magnitude estimate: the
scheduler policy in Emo is a few hundred lines; the asm mechanism ~100
lines; the backend + substrate is the multi-week dominant cost.

### C interop on bare metal (assessment)

How deep can the C FFI go — a ladder, each rung its own decision:

1. Scalar leaf calls — today's surface (`foreign def name(params) Ret =
   "c_symbol"`, generated C wrappers, `Float`/`String`/`Bool` only,
   E4200 otherwise). Enough for libm-level calls.
2. Width types crossing — `Int64`/`Int32`/`Float64`/`Float32` land on
   `int64_t`/`int32_t`/`double`/`float`; the C-stub wrapper mechanism
   already exists; blocked only on the width rename landing.
3. Opaque handles + copied buffers — externally-owned pointers as
   opaque, explicitly-closed values outside the GC; structured data by
   explicit copy. Covers most real C libraries without struct-layout
   knowledge.
4. Structs and callbacks — struct-by-value needs platform-ABI layout
   knowledge (or generated `offsetof` accessor thunks so the C compiler
   owns the layout); callbacks need the Emo calling convention exposed
   as C function pointers with a re-entrant runtime. Expensive.
5. Header ingestion (libclang bindgen) — tooling investment; only when
   a concrete library demands it.

On bare metal the shape changes: no hosted libc, no dlopen — C interop
becomes freestanding C sources compiled into the image and linked by
Emo's linker script, with the RISC-V psABI calling convention as the
contract. The firmware/driver boundary is mostly not C calls at all:
SBI via `ecall`, MMIO via `peek`/`poke`. The no-GC kernel runtime
configuration makes the ownership boundary tractable. Zeroth fix before
any deepening: non-native targets must not silently miscompile
`foreign def` (tracked in `CHECK.md`).

Strategic framing: in the single-language-closure philosophy, C interop
is a bridge, not a foundation — the kernel is Emo; C is the door to
what already exists (firmware, driver code, legacy libraries).

## Tasks (this file's scope)

- [x] When a target is scheduled, split it into `step-NN-<target>.md` with
      the full standard format (goal / scope / tasks / acceptance) and
      update `plan/README.md`'s status table. (riscv64 →
      `plan/step-19-riscv64.md`, 2026-10-05.)
- [x] Record here which key decision each target settled and where
      (README / CHECK.md / docs) — keep the trail. (Done 2026-10-17:
      four entries in the promotion trail below, one per target, each
      pointing at its step file's decisions and at the cross-cutting
      `README.md` / `CHECK.md` / `docs/` records.)

## Promotion trail

Every target this file scheduled now has its own step file, and every
step file carries a "Decisions settled here (the trail)" section. This
section records, per target, the decisions that closed the roadmap
questions above and where each one lives. Cross-cutting decisions that
belong to the language rather than one backend stay in `CHECK.md` /
`docs/` and are linked from the entries.

- **TypeScript → `plan/step-17-typescript.md`** (scheduled 2026-10-02,
  first target; step 17 complete). That file's "Decisions settled
  here" records: lowering from the IR, not the AST (superseding this
  file's earlier "the AST suffices" note); the uniform
  `async`/`await` mapping with no coloring analysis; cooperative tasks
  rather than workers; and networking over Node's
  `net`/`dgram`/`tls`/`dns` modules. The value model (tagged JS
  objects; JS numbers with the 2^53 integer-precision caveat) and the
  direct-style/event-loop mapping are in its Scope. Target naming and
  the resolution gate are the `CHECK.md` "Backend naming" entry; the
  manifest `targets` gate itself is T17.5's refusing/accepting tests.
- **Wasm → `plan/step-16-wasm.md`** (scheduled 2026-10-02, second
  target). That file's "Decisions settled here" records: GC =
  **WasmGC** — Emo values are WasmGC structs and arrays with RTT
  dispatch, no custom heap and no shadow stack (this closes the
  roadmap's "prototype both" question); Int boxes an i64 rather than
  i31; binary `.wasm` and text `.wat` are serialized from one
  intermediate with no external assembler; Node is the reference host.
  The WASI/IO audit (T16.5) closed in favor of refusing: Node's
  preview1 WASI has no usable socket calls and preview2's sockets are
  component-model-shaped, so `net`/`http` stay undeclared and no io
  goldens are possible on the reference host.
- **BEAM → `plan/step-18-beam.md`** (scheduled after TypeScript and
  Wasm, the recommended order; step 18 complete). Its decisions are
  recorded in Scope, closing the roadmap questions directly: emission
  as Core Erlang text assembled by the pinned OTP's `erlc`, not direct
  `.beam`; one BEAM module per program with mangled atoms; Int as a
  masked wrap-around i64; String as a UTF-8 binary (data never in
  atoms); Array as a tagged immutable list; enums as
  `{emo_enum, Name, Member}`; instances as
  `{emo_inst, Class, #{field => Value}}`, so map equality is already
  Emo's content equality (the "class value semantics vs Erlang maps"
  question); Box as a holding process; `==` anchored to tagged
  structural equality; processes mapped onto
  `spawn`/`!`/selective receive/exit. net/http and `foreign def` are
  explicitly out, each pending its own decision. Cross-target value
  rules — error handling, type layering, numeric width — are the
  corresponding `CHECK.md` entries.
- **riscv64 → `plan/step-19-riscv64.md`** (scheduled 2026-10-05,
  last; step 19 complete with the `%g` follow-up recorded). Its
  "Decisions settled here" plus the T19.1–T19.3 trails record: boot
  profile A (OpenSBI-hosted S-mode at 0x80200000, no UART driver;
  profile B is the later kernel-ownership step — this fixes the M1
  line above); dynamic values as tagged words with boxed
  `Int64`/`Float64` two-word cells (NaN-boxing rejected); four-bit tags
  with 16-byte alignment and field access on the untagged pointer; a
  bump heap that is GC-ready by construction; the psABI as Emo's
  internal convention; a whole-program single artifact. The target's
  identity (`riscv64`, QEMU as default runner not part of the target)
  and the target-independent numeric-width rule are recorded in
  `README.md` and `docs/numeric-width.md`; the emission-time capability
  refusals are in `CHECK.md` ("Type layering", "`foreign def` on
  non-native targets").

## Acceptance

- Each promoted target ships with: a compiling toolchain path
  (`emo build --target <t>`), its `examples/` subset green, and target
  metadata honored by step 11's resolution gate.

## Open design items

- None. All four targets are promoted to their own steps and their key
  decisions are recorded in the promotion trail above. The one open
  follow-up is the riscv64 `%g` float to-string recorded in
  `plan/step-19-riscv64.md`'s close-out; step 16's WASI/IO audit closed
  with the refusal recorded in that step.
