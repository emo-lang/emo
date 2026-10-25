# EmoOS — Development Tasks

The standalone tracker for the EmoOS project (the kernel package `emo_os`
under `projects/emo-os/`). EmoOS is its own project: it does **not** write
into the Emo compiler's `docs/TASKS.md`. Compiler-side work (atomics,
Stage B, image packaging) is executed in the Emo tree on feature branches
with its own ground rules, but every task is tracked here.

## How to use this file

- **Numbering:** `T<step>.<n>` — the step numbers are EmoOS steps
  (this file), unrelated to the compiler's `plan/step-NN` numbering.
- **Working in spare time:** tasks within a step are ordered; any prefix of
  completed tasks leaves the tree in a consistent state. A step boundary is
  the checkpoint: the kernel boots, the goldens are green, and — for the
  compiler-side steps — `dune test` is green.
- **Ground rules:**
  - Never start the next step on a red build.
  - Strictness first: reject early with a clear diagnostic. No auto-fixing,
    no implicit additions, no silent fallbacks.
  - Milestone aliases (`M1`, `S1`, `S2`, `M2`…`M6`) match the README's
    milestone table; the mapping is listed below.
  - Check items off here as you go, and refresh the README's milestone
    table when a step completes.

## Milestones

| Milestone | Steps | Exit criteria | Status |
| --- | --- | --- | --- |
| M1 — Bare-metal bring-up | 0 | The freestanding image boots under QEMU and prints through the SBI console; the `run.sh` smoke is green. | complete |
| S1 — Memory primitives | 1 | Atomics + volatile `peek`/`poke` + `fence()` on every target that admits them, loud refusals elsewhere, goldens green. | next |
| S2 — riscv64 Stage B | 2 | Typed bodies keep `Int64` in registers; boxing only at escape points; an MMIO read allocates nothing; every existing riscv64 golden byte-identical. | — |
| M2 — Cooperative kernel | 3 | `spawn`/`send`/`receive` on metal, the round-robin scheduler, the interrupt-driven UART console, and the dual-run parity harness. | — |
| M3 — User mode | 4 | U-mode user ELFs behind the ecall gate, the syscall stub package, a user program runs — and fails alone. | — |
| M4 — Process memory | 5 | Per-process arenas with quotas, reclaim on death, the physical frame allocator. | — |
| M5 — SV39 | 6 | Per-process address spaces, the trampoline, a page fault kills only the offender. | — |
| M6 — FS, shell, EmoUI | 7 | The virtio-blk filesystem service, the shell REPL, the EmoUI console — the single-language closure demo. | — |

## Step 0 — Bare-metal bring-up (M1)

Recorded post hoc — the work predates this tracker; the artifacts are in
the tree.

- [x] **T0.1** — The freestanding `riscv64` image: the tagged value model, the bump allocator over `.bss`, the SBI legacy console ecalls (a7 = 1 print, a7 = 8 poweroff), boot profile A (OpenSBI enters `emo_start` in S-mode at `0x80200000`; non-boot harts park), the generated linker script, wrap-around `Int64` arithmetic, strings, tuples, boxes, closures, content equality.
- [x] **T0.2** — The QEMU smoke: `run.sh` boots the ELF under `qemu-system-riscv64 -machine virt`, waits for the payload's serial line, and fails loudly otherwise.

## Step 1 — Memory primitives (S1)

Pure compiler work; no OS code. Design settles before any emitter moves.

- [x] **T1.1** — The atomic memory-model design note in the Emo tree (`docs/atomics.md` + `docs/zh-CN/` mirror): sequential consistency only, the op set, `Atomic` as Box's synchronized sibling in `core`, the `Int64`/`Bool` scope, `compare_exchange` returning `(Bool, Int64)`, the per-target support matrix, and the data-race semantics (unsynchronized cross-context sharing of a Box field is undefined).
- [x] **T1.2** — `CHECK.md` decisions recorded: the atomic semantics; `peek`/`poke` defined as volatile (never elided, never reordered against each other); `fence()`.
- [x] **T1.3** — The language surface: `Atomic` in `core` with the op set and `fence()`; the checker accepts `Int64`/`Bool` payloads and refuses everything else by name; parser/checker tests.
- [ ] **T1.4** — Hosted targets: the interpreter (exact no-op), `c` (`__atomic` builtins), `ocaml` (the `Atomic` module; CAS-loop fallbacks for `fetch_and`/`fetch_or`/`fetch_xor`).
- [ ] **T1.5** — Managed targets: `ts` and `wasm` as exact no-ops under the cooperative scheduler; `beam` via the runtime's `atomics` array (the full set; the bitwise `fetch_*` as compare-exchange loops — `docs/atomics.md` supersedes the earlier `counters` line).
- [ ] **T1.6** — `riscv64`: `amoswap` / LR-SC / `fence` full set as runtime helpers in the generated image.
- [ ] **T1.7** — Goldens: one cross-target corpus answered byte-for-byte on every target that admits the ops; refusal goldens for BEAM's CAS and every non-scalar payload; a riscv64 golden under QEMU.

## Step 2 — riscv64 Stage B (S2)

Why this is its own step: in the dynamic value model one MMIO read
allocates a boxed `Int64` that nothing ever reclaims — a polling loop
exhausts the heap. Unboxing is a prerequisite of the kernel primitives.

- [ ] **T2.1** — The typed calling convention: a fully typed signature gets raw-register params and results (`Int64` in a register, `Float64` in an f-register); boxing adapters at typed↔dynamic call boundaries.
- [ ] **T2.2** — Escape-point boxing: locals and arithmetic stay unboxed; a value boxes only where it escapes (container element, field, closure capture, message, dynamic-call boundary).
- [ ] **T2.3** — `peek`/`poke` lowered to unboxed raw `Int64` — an MMIO read allocates nothing — with the volatile ordering preserved through emission.
- [ ] **T2.4** — Re-verification: every existing riscv64 golden byte-identical; a before/after instruction count for a hot-loop corpus (`count_down`-style) recorded in the step trail.

## Step 3 — The cooperative kernel (M2)

- [ ] **T3.1** — Package-carried native sources for `riscv64`: per-package `.S` sources compiled into the image; the freestanding runtime (boot stub + linker script) becomes a package-provided component — a kernel package owns its image — while the default runtime stays for ordinary programs.
- [ ] **T3.2** — The `emo_os` package: `package.emo` renamed from `emo/os` to `emo_os` (deps syntax verified); the kernel-only `core` layering enforced — stdlib requires refuse on the kernel target.
- [ ] **T3.3** — Processes on metal: `spawn`/`send`/`receive` unblocked on `riscv64` — green threads on the boot hart, the context switch as the callee-saved swap plus `sp` in the `.S` shim, per-process stacks, copy-on-send mailbox semantics matching the hosted `emo_sched` reference.
- [ ] **T3.4** — The scheduler: round-robin first, with the priority and quota fields present; send-time priority donation wired behind the fields (dormant until priorities are settable); the wait graph held by the scheduler.
- [ ] **T3.5** — The UART driver, polling: the 16550A at `0x10000000` on `virt` through `peek`/`poke`; `println` leaves the SBI console; SBI stays for poweroff.
- [ ] **T3.6** — Traps and the tick: the `stvec` entry shim, `sstatus`/`sepc` save-restore, `sstc` `stimecmp` (SBI `set_timer` fallback) driving the tick; the ISR discipline enforced — no allocation in an ISR body, preallocated ring, ack + enqueue + wake.
- [ ] **T3.7** — The interrupt-driven console: the input ring drained by a console process; reader processes block on the ring.
- [ ] **T3.8** — The dual-run parity harness: kernel-service logic runs under the hosted interpreter against fake devices and under QEMU against real ones; outputs asserted byte-identical; the QEMU smoke wired into `dune test`/CI.

## Step 4 — User mode (M3)

- [ ] **T4.1** — The user ELF profile: a second riscv64 image shape (U-mode entry, own stack, no runtime CSRs); the kernel loads it and enters via `sret`.
- [ ] **T4.2** — The syscall gate: ecall dispatch in the kernel; the ABI (numbers, register marshaling, error convention) fixed and documented; supervisor checks on every pointer argument (range and permission).
- [ ] **T4.3** — The syscall stub package: user-side stubs over the raw ecall — its own package, distinct from the hosted `os` package; the typed Emo surface is the only thing user code sees.
- [ ] **T4.4** — Kernel services as processes: the console service (read/write) and the process service (spawn/exit/wait) answering the gate.
- [ ] **T4.5** — The weak-isolation window, documented: what U-mode can and cannot reach pre-SV39, in the README and the kernel's docs.
- [ ] **T4.6** — Goldens: a user program prints through the gate; a misbehaving program's loud failure kills only itself.

## Step 5 — Process memory (M4)

- [ ] **T5.1** — Per-process arenas: a bump heap per process with the quota enforced at `emo_alloc`; exhaustion is loud and confined.
- [ ] **T5.2** — Reclaim on death: exit returns the arena to the frame pool; message copies charged — copy-in to the sender's quota, copy-out to the receiver's heap.
- [ ] **T5.3** — The physical frame allocator: a raw-memory freelist backing arenas, stacks, and (later) page tables; bounded caches for long-lived services.
- [ ] **T5.4** — Accounting goldens: a runaway process exhausts its own quota alone; the survivors continue.

## Step 6 — Address isolation (M5) — SV39

- [ ] **T6.1** — Sv39 machinery in Emo: page-table structures on raw memory (the untyped-memory discipline), `satp` and `sfence.vma` shims, the kernel's high-half layout.
- [ ] **T6.2** — Per-process address spaces: user page tables (code RX, data RW, stack, kernel pages without U) built at spawn; context switch = `satp` swap + `sfence`.
- [ ] **T6.3** — The trampoline: trap entry through the user-mapped trampoline page, `satp` swapped in transition, `sret` home.
- [ ] **T6.4** — Page faults: the offending process is killed loudly; the kernel survives. Demand paging stays out of scope.
- [ ] **T6.5** — Isolation goldens: a user store to a kernel address faults and dies alone; DMA buffers stay physically contiguous through the allocator.

## Step 7 — Filesystem, shell, EmoUI (M6)

- [ ] **T7.1** — The virtio-blk driver as a process: virtqueues over `peek`/`poke`, DMA-coherent buffer discipline.
- [ ] **T7.2** — The filesystem service: the authoritative-versus-rebuildable state split and the crash-restart semantics settled in their own design note first, then implemented (cache rebuilt from disk; the mount table durable).
- [ ] **T7.3** — The shell: a REPL process over the console and filesystem services; the command set settled in the shell design note.
- [ ] **T7.4** — EmoUI on EmoOS: the console renderer driven by the kernel's console path — kernel + shell + UI in one language, the closure demo.
- [ ] **T7.5** — Close-out: the full-boot golden (power on → shell prompt → a user program runs → a filesystem roundtrip), the milestone table refreshed, the README brought to post-M6 truth.
