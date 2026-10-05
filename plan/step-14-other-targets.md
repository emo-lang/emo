# Step 14 — Other Targets: Wasm, TypeScript, BEAM, RISC-V Bare Metal

**Milestone:** M4 roadmap · **Prereq:** steps 01–13 (per target, below) ·
**Status:** not started

## Goal

The remaining README compilation targets, each a sub-project with its own
prerequisites and risk profile. Unlike steps 01–13 these are **roadmap
entries, not execution-ready plans** — each gets its own detailed step file
when scheduled, following the same format. Order within the step is by
recommended priority.

## WebAssembly (recommended first)

- **Strategy:** compile the step 13 IR to Wasm; start with WASI
  (command-line programs, filesystem, sockets via WASI where available),
  browser embedding (`fetch` / WebSocket bridging) after.
- **Key decisions:** WasmGC vs a custom GC for Emo values (WasmGC aligns
  with every-value-carries-a-tag only partially — struct-of-payload designs
  need care); module loading under the WASI sandbox.
- **Prereq:** IR from step 13; stdlib target metadata extended with
  `"wasm"`.
- **Risk:** GC strategy is the whole game; prototype both before choosing.

## TypeScript

- **Strategy:** transpile the checked AST to TypeScript; gradual types map
  naturally (Emo annotations → TS types, `Unknown` → `any`-free escape
  hatches to be defined). The runtime value tags become a thin TS runtime
  library.
- **Key decisions:** the direct-style problem — step 12's blocking calls
  must map onto the event loop (Promise-returning internals with an
  ergonomic surface); how processes map to workers or cooperative tasks.
- **Prereq:** step 08 (checker feeds annotations); no IR dependency — the
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
  snapshots already match BEAM copying.
- **Prereq:** steps 08 and 11 (semantics frozen); stdlib surface audit for
  BEAM-unsupported operations.
- **Risk:** low semantically, moderate in tooling (rebar/OTP integration,
  releases).

## Bare metal — `riscv64` (last)

- **Strategy:** freestanding RISC-V images, per the EmoOS ambition: no
  OS, no libc, pluggable runtime (allocator, GC, scheduler as
  replaceable components). The target is named for the ISA —
  `riscv64` — and QEMU is its default runner (the no-hardware dev
  loop), not part of the target; the same image runs on real hardware
  (decided 2026-10-05, replacing the earlier `qemu` target name).
- **Layering:** the `core` library layer (integers, strings, tuples,
  control flow — zero runtime dependencies) is the only surface available
  to kernel code; the standard library requires the full runtime. This
  split is a *library-architecture* task that should actually be pulled
  earlier if EmoOS work starts — flagged in `plan/README.md` reviews.
- **Explicit memory primitives** (`peek` / `poke` and friends) as
  visibly-named core-library functions — dangerous reads dangerous.
- **Int width is target-independent:** `Int64` is 64-bit two's
  complement with wrap-around on every target, and integer types are
  width-explicit (`docs/int-width.md`), so a future `riscv32` is a
  pure codegen problem — register-pair arithmetic, the same technique
  as the native backend's 64-bit route; there `Int32` is the
  register-width fast path and `Int64` the emulated one. Narrowing
  `Int64` on RV32 is off the table.
- **Prereq:** step 13 Stage B (specialized, lean codegen); a custom or
  minimal GC story; linker scripts.
- **Risk:** highest of the four; also the most speculative until an EmoOS
  effort exists.

## Tasks (this file's scope)

- [x] When a target is scheduled, split it into `step-NN-<target>.md` with
      the full standard format (goal / scope / tasks / acceptance) and
      update `plan/README.md`'s status table.
- [ ] Record here which key decision each target settled and where
      (README / CHECK.md / docs) — keep the trail.

## Promotion trail

- **TypeScript → `plan/step-15-typescript.md`** (scheduled 2026-10-02,
  first target). Its key decisions are settled in that file's
  "Decisions settled here": lowering from the IR (superseding this
  file's earlier "the AST suffices" note), uniform async mapping, and
  cooperative tasks.
- **Wasm → `plan/step-16-wasm.md`** (scheduled 2026-10-02, second
  target). The GC question is settled: **WasmGC** — structs and arrays
  with RTT dispatch, no custom heap. The i31-vs-i64 and unboxing
  details are that file's recorded follow-ups. BEAM is next in the
  recommended order; the bare-metal `riscv64` target stays last.

## Acceptance

- Each promoted target ships with: a compiling toolchain path
  (`emo build --target <t>`), its `examples/` subset green, and target
  metadata honored by step 10's resolution gate.

## Open design items

- None block this file; every target's key decisions are listed above and
  gate their own promotion to a full step.
