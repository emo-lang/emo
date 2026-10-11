# Step 22 — RISC-V Target (Freestanding RV64)

**Milestone:** M7 · **Prereq:** steps 01–13 (the specialization pass);
the step-14 RISC-V reference note is the design record ·
**Status:** T22.1–T22.2 done (2026-10-11 — the value model boots and
fib is golden; T22.3–T22.4 remain)

## Goal

`emo build --target riscv64`: an Emo program compiles to RV64 assembly
text, the GNU cross-binutils assemble and link it into a freestanding
ELF, and it boots under `qemu-system-riscv64 -machine virt`, printing
through the SBI console. The fifth backend and the first with no host
runtime — no OCaml, no WasmGC, no BEAM, no JS: the dynamic value gets a
memory layout of its own, and the allocator is ours. This is M1 of the
riscv64 roadmap in the step-14 note (backend + bare-metal boot); the
scheduler is the following step.

## Probed facts (binutils 2.45, QEMU 11.1.1, OpenSBI v1.8.1 — this host, 2026-10-05)

- **Boot profile A (the default chain), probed end to end.**
  `-machine virt -kernel elf` boots OpenSBI (fw_dynamic) at 0x80000000,
  which enters the payload at **0x80200000 in S-mode** with `a0` = hart
  id and `a1` = DTB pointer. A 20-instruction assembly probe printed
  "Hello from Emo probe" through the legacy console ecall and exited
  QEMU cleanly (exit code 0).
- **Legacy SBI ecalls from S-mode**: console putchar is `ecall` with
  `a7 = 1`, `a0` = byte; shutdown is `a7 = 8`. OpenSBI v1.8.1 lists
  `legacy` among the standard extensions; the console device is
  uart8250. A hand-written UART driver is a profile-B need (below), not
  an M1 need.
- **The assembler**: `.attribute arch, "rv64gc"` accepted;
  `-march=rv64gc -mabi=lp64d`; `la` relaxes to `auipc`+`addi`
  (PC-relative — the medany discipline; at 0x80200000 the medlow
  absolute window cannot reach our own symbols, so PC-relative is not a
  style choice); `tail` relaxes to a compressed `j` when in range;
  numeric local labels (`1f`/`2b`) work. Full binutils (as, ld,
  objdump, objcopy) and riscv64-elf-gdb are on PATH; `ld` takes a plain
  linker script.
- **psABI calling convention** (the contract for our own calls and for
  C interop alike): arguments `a0`–`a7` (return in `a0`), floats
  `fa0`–`fa7` under lp64d, callee-saved `s0`–`s11`/`fs0`–`fs11`,
  `ra` caller-saved, `sp` 16-byte aligned. The language has no varargs
  and no by-value aggregates, so the convention applies in its simple
  form.

## Scope

### In

- **The emission target: RV64 assembly text + GNU as/ld** (step 13's
  emit-and-delegate pattern; `erlc` is the BEAM precedent). One
  whole-program artifact — the native target's single `main.ml`, with
  the same mangled labels. Per-module ELF linking stays out.
- **Boot profile A** (decided — resolves the step-14 note's M1 line,
  which conflated the two profiles): OpenSBI-hosted S-mode at
  0x80200000; the entry stub sets `sp`, clears `.bss`, parks non-boot
  harts when `-smp > 1`; a generated linker script; `println` through
  the SBI console ecall.
- **The value model — the first target that owns its layout.** A
  dynamic value is one tagged machine word; heap blocks are 8-byte
  aligned and the 3 free pointer bits tag the kind: String, Tuple,
  Array, Box, Closure, Instance, enum pairs, and the numeric cells;
  Bool and Char are immediates. **`Int64`/`Float64` are boxed two-word
  cells in the dynamic world** — the decided wrap-around semantics need
  all 2⁶⁴ bit patterns, so the OCaml 63-bit shortcut is unavailable
  here (CHECK.md's open decision is scoped to the OCaml-hosted backend
  and unaffected). Specialized code (step 13's Stage B) keeps raw
  registers: `Int64` in a register, `Float64` in an f-register — the
  two-world structure the compiler already has.
- **The heap: a bump allocator** (GC deferred — the no-GC pluggable
  runtime configuration; tagging keeps a future precise collector
  possible without layout churn, since an immediate is never a valid
  pointer).
- **Calls and control flow on the psABI**: fixed arity; mid-body
  `return` compiles to a branch to the epilogue (the native target's
  `Return_signal` exception is an emission convenience, unnecessary in
  assembly); **guaranteed tail calls as `tail`/`jalr x0`** — constant
  stack for the receive-loop idiom; closures are heap records
  `[code pointer, captured values…]`, the record passed in a
  caller-saved temporary (provisional: `t0`); method dispatch through
  compile-time vtables (today's per-class method tables, static).
- **Core semantics for the golden tier**: wrap-around `Int64`
  arithmetic, `Float64` with the `%g` print rule (the BEAM/wasm-host
  precedent), strings as UTF-8 bytes + length, interpolation, tuples,
  arrays, Box, enums, patterns with guards, content equality,
  classes/instances/interfaces.
- **Honest refusals**: `spawn`/`send`/`receive` and `foreign def`
  refuse at emission time with a clear diagnostic — processes are the
  next step; `foreign def` on non-native targets is gated in CHECK.md
  before any FFI deepening. The resolution gate already admits
  `"riscv64"`; packages that do not declare it refuse as for every
  other target.
- **Runner**: `emo run --target riscv64` boots the ELF under
  `qemu-system-riscv64 -machine virt -nographic`. QEMU is the dev loop,
  not part of the target (step-14 note) — the same image runs on real
  RISC-V hardware.

### Out

- The cooperative process scheduler (roadmap M2) and everything past
  it: timer preemption (M3), multi-hart SMP (M4).
- Boot profile B (`-bios none`, M-mode, own 16550A UART driver,
  0x10000000 MMIO on `virt`) — for when the kernel owns the machine.
- GC beyond the bump allocator (mark-sweep/copying on the same
  layout); register allocation and peephole work (correctness first:
  every temporary gets a stack slot, like the wasm target's implicit
  stack machine); RV32.
- FFI beyond the ladder design recorded in the step-14 note; the
  CHECK.md loud-refusal gate for `foreign def` on wasm/BEAM lands
  before any FFI deepening, not here.
- The hosted de-risk shortcut (cross-built OCaml riscv64 Linux
  userland) — optional, its own track.

## Decisions settled in T22.1 (the trail)

- **The image: two read-only segments and one read-write, via a
  `PHDRS` block** — the flat one-segment layout earns an ld warning
  ("LOAD segment with RWX permissions"); the split gives the loader
  honest permissions and costs one small static script.
- **The goldens own two transport facts; the payload owns none.**
  OpenSBI's banner shares the serial stream (the payload's output
  starts after the banner's last `Boot HART` line), and the SBI
  console renders every newline as CRLF (the banner does the same).
  The golden strips the banner and normalizes CRLF to LF; the payload
  emits plain LF and the runner passes the stream through untouched.
- **The psABI discipline starts at the entry body**: `ra` is
  caller-saved, so any emitted function that calls and returns keeps
  a frame for its own return address — `emo_program`'s bare `ret`
  after a `call` was the first boot's infinite `ret`-to-self hang.

## Decisions settled in T22.2 (the trail)

- **The immediate layout: bit 0 set, kind in bits 3:1 (0 Bool,
  1 Char, 2 Enum), payloads above bit 3.** Bool's payload rides bit 4
  (`false` = 1, `true` = 17) — an earlier draft put it in bit 1, which
  made `true` decode as Char. Truthiness tests, `not`, and every
  comparison's boolean build key on bit 4.
- **Field access runs on the untagged pointer, everywhere.** Int64's
  tag is 0 and hides any slip (the fib bug that cost an afternoon);
  the Float64 paths, the closure record in t0, and the interpolation
  length reads all `andi -8` before touching fields.
- **Tail calls carry the caller's return address in ra**: `ld ra,
  0(sp)` before the frame release, because `tail`/`jr` never write ra —
  otherwise the deepest frame returns into the middle of the loop body
  and the recursion never terminates.
- **The pre-pass must score every construct the emitter can emit** —
  `expr_depth` missed `Builtin`'s arguments, so `println` of an
  interpolation wrote four slots past a frame sized for none. The
  frame layout (named slots, then depth-indexed temporaries) is only
  as sound as that count.
- The heap is 64 MiB of .bss beside the 1 MiB stack (both NOBITS);
  `count_down(1000000)`'s boxed arguments fit with room to spare.

## Tasks

- [x] **T22.1** — The backend skeleton: `--target riscv64` plumbing
      (emitter module; the CLI arm writing `main.s`, invoking
      `as`/`ld` with the generated linker script; `emo run` booting the
      ELF under QEMU); the entry stub, BSS clear, SBI console.
      Golden: hello_world (serial output byte-for-byte vs `emo run`).
- [x] **T22.2** — The value model and arithmetic: the tagged-word
      representation (numeric cells, Bool/Char immediates) and the
      bump allocator; wrap-around `Int64`/`Float64` arithmetic,
      comparisons, `if`, integer formatting (`INT64_MIN` correct);
      guaranteed tail calls as `tail`. Golden: fib.
- [ ] **T22.2** — The value model and arithmetic: the tagged-word
      representation (numeric cells, Bool/Char immediates) and the
      bump allocator; wrap-around `Int64`/`Float64` arithmetic,
      comparisons, `if`, integer formatting (signed, `INT64_MIN`
      correct); guaranteed tail calls as `tail`. Golden: fib.
- [ ] **T22.3** — Dynamic-world data structures: tuples, arrays, Box,
      enums, instances with vtable dispatch, closures and first-class
      functions; patterns with guards; interpolation with the `%g`
      float rule. Golden: objects, language_tour.
- [ ] **T22.4** — Bootstrap: the `riscv64_examples` CI group (QEMU +
      cross-binutils on the runner), the resolution-gate refusal test
      for packages lacking `"riscv64"`, the emission-time refusal
      diagnostics, close-out.

## Acceptance

- `emo build --target riscv64 main.emo` produces a freestanding ELF
  that boots under `qemu-system-riscv64 -machine virt`; every example
  in the core subset prints exactly what `emo run` prints (golden, in
  CI).
- A program using `spawn`/`send`/`receive` or `foreign def` refuses
  with a clear diagnostic; a package that does not declare `"riscv64"`
  fails resolution before any emission.
- `dune test` green.

## Decisions settled here (the trail)

- **Boot profile A for M1** (OpenSBI-hosted S-mode, 0x80200000) — the
  probed default chain, no UART driver in the loop; profile B
  (`-bios none`, M-mode) is the later kernel-ownership step. Fixes the
  step-14 note's M1 line, which mixed the two profiles.
- **Dynamic value = tagged word; `Int64`/`Float64` boxed two-word
  cells** — the wrap-around semantics forbid the 63-bit shortcut;
  NaN-boxing rejected (`Float64` must round-trip bit patterns, and a
  64-bit integer payload cannot share the word). The bump allocator's
  layout is GC-ready by tagging.
- **The psABI is Emo's internal convention** — fixed arity and no
  varargs make C-interop rungs 1–3 plain calls, and the guaranteed
  tail call a single pseudo-instruction.
- **Whole-program single artifact** — the native/wasm precedent;
  per-module ELF linking is a later, mechanical step.
- Scheduled from step 14 per its split-out task (2026-10-05).
