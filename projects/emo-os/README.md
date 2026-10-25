# EmoOS

An operating system written in Emo — kernel, shell, and user programs in one language, from power-on to prompt. EmoOS is an xv6-class research and teaching system: complete enough to run real programs on real (or simulated) RISC-V hardware, small enough to read end to end. It is the proof of Emo's single-language closure, and the hardest stress test the language undergoes.

Status: pre-alpha. Bare-metal bring-up is complete — the freestanding `riscv64` image boots under QEMU and prints through the firmware console. The tracker is [`docs/TASKS.md`](docs/TASKS.md).

Chinese translation: [`README.zh-CN.md`](README.zh-CN.md).

## Position

- **xv6-class — not FreeRTOS-class, not production.** Soft real-time, cooperative-first. Hard real time and functional-safety certification are out of scope; the boundary is analyzed in the Emo tree's [`docs/rtos-assessment.md`](../../docs/rtos-assessment.md).
- **The point is closure.** One compiler emits the kernel image and the user programs; the shell and the console UI are Emo with EmoUI. No second language crosses the privilege boundary.

## Architecture — the structured microkernel

EmoOS is a microkernel in the QNX lineage: process boundaries exist exactly where fault isolation pays for them.

- **Processes:** device drivers, the filesystem, the network stack, the shell, and user programs — big, crash-prone, third-party-shaped code.
- **Not processes:** the scheduler, trap dispatch, the allocators, syscall dispatch — small, trusted core code, called directly. Processifying it would pay the message toll and buy no isolation.
- **Boundaries are retractable.** Before SV39 everything shares one address space; when a measured service-to-service path runs too hot, it merges back into one process. The everything-is-IPC shape is a bug, not a feature — and the classic microkernel diseases have standing answers here: IPC is a function call plus a copy in one address space, accounting is exact by construction, and priority flows through the scheduler that delivers every message.
- **Resource accounting.** Memory is attributed per process by construction; the copy into a mailbox is charged to the sender's quota, the copy into the receiver's heap to the receiver; CPU is accounted per process. A runaway process exhausts its own quota — loudly, and alone.
- **Priority donation at send.** A process's effective priority is the maximum of its own and the priorities of the processes waiting on it. Synchronous kernel calls carry timeouts; the scheduler holds the wait graph and detects cycles.
- **Crash-restart discipline.** Every service separates authoritative state from rebuildable state: a restarted filesystem service rebuilds its cache from disk; the mount table must survive. Restart is only safe when what is lost is declared.

## Memory model

- **Each process owns an arena heap.** Termination reclaims the whole heap in O(1); messages are copied across heaps. Value semantics allocate freely because reclamation is scoped and certain.
- **No GC in the kernel — decided.** Reclamation is process death plus bounded caches; long-lived services keep bounded working sets. A collector would make preemption harder, not easier.
- **Physical memory is raw.** Frames, page tables, and device buffers are managed through `Int64` addresses, `peek`/`poke`, and bit masks — the untyped-memory discipline, accepted and confined.

## Isolation route

- **Privilege first, address space later.** User programs enter U-mode behind the ecall gate before paging exists; SV39 closes the window afterwards.
- **The weak-isolation window is documented, not hidden.** Before SV39, U-mode cannot execute privileged instructions, but its loads and stores reach kernel RAM and MMIO. The pre-SV39 defenses are the copy semantics and the supervisor's own argument checks.
- **SV39 (M5) buys:** per-process address spaces, wild writes killed by the MMU instead of absorbed by the kernel, hardware enforcement behind every service boundary, and one fixed load address for every user ELF.

## Language primitives the kernel stands on

- **`Atomic` — Box's synchronized sibling — lives in `core`.** Sequential consistency only; no memory-order parameter. The first cut covers `Int64` and `Bool`: `load`, `store`, `exchange`, `compare_exchange` (returning `(Bool, Int64)`), the `fetch_*` family, and `fence()`. Atomics on non-scalars refuse. The design note: [`docs/atomics.md`](../../docs/atomics.md).
- **Per-target honesty.** The interpreter and the TypeScript / wasm targets run exact no-ops (cooperative single threads — sequential consistency holds vacuously); `c` lowers to `__atomic` builtins; `ocaml` uses its `Atomic` module with CAS-loop fallbacks for the bitwise ops; BEAM lowers to the runtime's `atomics` array — the full set, the bitwise `fetch_*` as compare-exchange loops; `riscv64` is the real one — `amoswap`, LR/SC, `fence`.
- **`peek8`/`poke8`/`peek64`/`poke64` are volatile by definition** — never elided, never reordered against each other. The byte lane rides `Byte` (unsigned, 0–255), the word lane `Int64`; `poke` answers nothing. `riscv64` admits them — the program owns the address space — and every hosted target refuses by name (E4028). The design note: [`docs/raw-memory.md`](../../docs/raw-memory.md).
- **riscv64 Stage B is a prerequisite, not an optimization.** In the dynamic value model every `Int64` is a boxed heap cell: one MMIO read allocates a cell that no collector will ever reclaim, so a polling loop exhausts the heap. Typed specialization keeps `Int64` in a register and boxes only at escape points (container elements, fields, closure captures, messages, dynamic-call boundaries).
- **ISR discipline: no allocation in an interrupt body.** Preallocated ring buffers in raw memory; an ISR acks, enqueues, and wakes — the drain is a process.

## The machine

- **Boot profile A, fixed for the roadmap.** OpenSBI enters the kernel in S-mode at `0x80200000` with the hart id and DTB; non-boot harts park. One hart; SMP is parked.
- **QEMU `virt` is the development loop;** the same image runs on real RISC-V hardware. `./run.sh` boots the image and greps the serial line.
- **Dual-run development.** Hardware sits behind structural interfaces, so kernel services run under the hosted interpreter against fake devices — millisecond iteration, directly assertable — and under QEMU against real ones. The two runs must agree byte for byte.

## The project in the tree

- The kernel package is **`emo_os`** — a flat name (the package registry bans `emo`-prefixed names for third parties; the kernel never publishes), distinct from the hosted `os` package. The user-side syscall stub is its own package, not `os`.
- EmoOS tracks its own work in [`docs/TASKS.md`](docs/TASKS.md); compiler-side tasks (atomics, Stage B, image packaging) are executed in the Emo tree and tracked there.

## Running it

```console
$ emo build main.emo --target riscv64
$ ./run.sh
```

## Milestones

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 — Bare-metal bring-up | freestanding image boots, prints through the SBI console | complete |
| S1 — Memory primitives | atomics + volatile `peek`/`poke` + `fence`, all targets | complete |
| S2 — riscv64 Stage B | typed calling convention, escape-point boxing | — |
| M2 — Cooperative kernel | processes on metal, scheduler, interrupt-driven UART | — |
| M3 — User mode | U-mode, ecall gate, user ELF, syscall stubs | — |
| M4 — Process memory | arenas, quotas, reclaim on death, frame allocator | — |
| M5 — SV39 | per-process address spaces, trampoline, fault-to-kill | — |
| M6 — FS, shell, EmoUI | virtio-blk service, shell REPL, console UI | — |

Per-task checklists live in [`docs/TASKS.md`](docs/TASKS.md).

## Related documents

- [`docs/atomics.md`](../../docs/atomics.md) — the atomic memory model: sequential consistency only, the op set, the per-target matrix, the data-race semantics.
- [`docs/rtos-assessment.md`](../../docs/rtos-assessment.md) — the real-time boundary, in the Emo tree.
- [`docs/xv6.md`](../../docs/xv6.md) — the xv6-class feasibility assessment: what Emo replaces, what stays assembly.
- [`docs/runtime-and-freestanding.md`](../../docs/runtime-and-freestanding.md) — what a freestanding target owns.
