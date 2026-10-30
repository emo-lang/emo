# EmoOS

An operating system written in Emo — kernel, shell, and user programs in one language, from power-on to prompt. EmoOS is an xv6-class research and teaching system: complete enough to run real programs on real (or simulated) RISC-V hardware, small enough to read end to end. It is the proof of Emo's single-language closure, and the hardest stress test the language undergoes.

Status: pre-alpha. The kernel boots under QEMU, drives its own 16550A, and runs a user program in U-mode behind the ecall gate — spawn, wait, console I/O through two service processes, a misbehaving program killed alone, every process's allocations charged to its own arena quota, and every process's memory a block of the kernel's frame allocator, taken at the spawn and back in the pool at the death — a runaway burns its own quota alone while the processes around it keep spending theirs across its death; the kernel itself runs under Sv39 in the high half of the address space, on a page table it builds for itself in Emo before its first line, and every user process runs paged on its own table — the image's code and data, its own stack and arena, the kernel mapped without U — the context switch swapping `satp` at the scheduler's pick; every trap out of a pass crosses the trampoline — the entry frames at a kernel-chosen anchor instead of the pass's `sp`, swaps `satp` mid-transition, and runs the dispatch on the kernel's own table and stack; a page fault is a kill, not a question — the report names the address the walk refused, the offender dies alone, and nothing fills the page (demand paging is out of scope, by decision); the closure is pinned: a user store at a kernel address — mapped, without U — dies of the permission the walk refuses, the kernel's high-half address named in full, and at the machine's end the allocator still answers one whole contiguous 64 KiB block, one pattern word per frame reading back — the DMA buffer M6 will ask for; the block device runs — a virtio-blk driver written in Emo as a process, its virtqueue and buffers one allocator block, the modern layout negotiated over `peek`/`poke`; the filesystem runs on it — a service whose authoritative state is the disk (a superblock carrying the mount table, a name table, the data sectors) and whose memory is rebuilt from the disk at every start, whole files written through, read back, listed, and removed through the gate, and a supervisor that restarts the service when it dies — the files exactly what they were, because the disk is the authority; the firmware console keeps only poweroff. The tracker is [`docs/TASKS.md`](docs/TASKS.md).

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
- **The weak-isolation window was documented, not hidden — and is closed.** From the user profile's landing (T4.1) until SV39 (T6.2), user and kernel shared one flat physical map: U-mode could not execute privileged instructions — the ecall gate is the only sanctioned crossing — but its loads and stores reached kernel RAM, other processes' memory, and the devices. What defended the kernel while the window stood: the gate's supervisor checks on every pointer argument, the copy semantics, and per-process quotas. The full account of what stood and what closed it: [`docs/isolation.md`](docs/isolation.md).
- **SV39 (M5) buys:** per-process address spaces, wild writes killed by the MMU instead of absorbed by the kernel, hardware enforcement behind every service boundary, and one fixed load address for every user ELF.
- **The kernel lives in the high half.** Every kernel address is the physical one plus `0xffffffc000000000`; the kernel builds its own Sv39 table in Emo at boot — text RX, rodata R, the rest of the RAM RW, the two devices it drives, plus the supervisor's low window onto the RAM (no U) — and runs paged from before its first line, the lower half left whole for the user.
- **Every user process runs on its own page table.** Built at spawn (and at stage time for the boot pass): the image's segments with U (code RX, data RW — the passes of one image share its pages, the spawn semantics since the first user program), the process's own stack and arena blocks, the cells page, and the kernel's whole high half mapped without U — a trap finds the kernel's world on any table, and U-mode finds only its own. The context switch is the scheduler's pick: the incoming slot's space word through a resolve hook and the `satp` swap, fenced, before the incoming process's first load. The trap entry is the trampoline: a page every address space maps, `stvec`'s home — `sscratch` carries the pass's trap anchor while user code runs and the sentinel 0 while kernel code runs, so one swap chooses the path without spending a register; a user trap frames at the anchor (the block's bottom scratch — never at the pass's `sp`), the entry swaps `satp` through the same resolve/write pair, and the dispatch runs on the kernel's own table and stack until the resume restores the pass's table, its registers, and its own `sp` before the `sret` home. The layout: [`docs/sv39.md`](docs/sv39.md).
- **A kernel service keeps its authoritative state apart from its rebuildable state, and is restarted when it dies.** The filesystem is the first service with authoritative state and draws the line for real: the disk holds the superblock (the mount table in it), the name table, and the data sectors, and nothing else is authoritative; the service's memory — the copies, the free map, the request bookkeeping — is derived from the disk at every start and trusted from nothing else. Every change is written through inside the request that makes it, and a write's commit point is one sector write, after the bytes and before the old extent is freed. A kernel service dies alone in two ways — its arena exhausted (the kernel has no collector, so a long-lived service reaches that) or its own return — and both meet the same mechanism: the runtime's death hook posts the dead pid to a supervisor process, which refuses the clients the dead instance left parked, spawns the next instance into the same cache block, and parks its pid; a request made in the gap waits for the next instance instead of spinning. The design note: [`docs/fs.md`](docs/fs.md).

## Language primitives the kernel stands on

- **`Atomic` — Box's synchronized sibling — lives in `core`.** Sequential consistency only; no memory-order parameter. The first cut covers `Int64` and `Bool`: `load`, `store`, `exchange`, `compare_exchange` (returning `(Bool, Int64)`), the `fetch_*` family, and `fence()`. Atomics on non-scalars refuse. The design note: [`docs/atomics.md`](../../docs/atomics.md).
- **Per-target honesty.** The interpreter and the TypeScript / wasm targets run exact no-ops (cooperative single threads — sequential consistency holds vacuously); `c` lowers to `__atomic` builtins; `ocaml` uses its `Atomic` module with CAS-loop fallbacks for the bitwise ops; BEAM lowers to the runtime's `atomics` array — the full set, the bitwise `fetch_*` as compare-exchange loops; `riscv64` is the real one — `amoswap`, LR/SC, `fence`.
- **`peek8`/`poke8`/`peek64`/`poke64` are volatile by definition** — never elided, never reordered against each other. The byte lane rides `Byte` (unsigned, 0–255), the word lane `Int64`; `poke` answers nothing. `riscv64` admits them — the program owns the address space — and every hosted target refuses by name (E4028). The design note: [`docs/raw-memory.md`](../../docs/raw-memory.md).
- **riscv64 Stage B is a prerequisite, not an optimization.** In the dynamic value model every `Int64` is a boxed heap cell: one MMIO read allocates a cell that no collector will ever reclaim, so a polling loop exhausts the heap. Typed specialization keeps `Int64` in a register and boxes only at escape points (container elements, fields, closure captures, messages, dynamic-call boundaries).
- **ISR discipline: no allocation in an interrupt body.** Preallocated ring buffers in raw memory; an ISR acks, enqueues, and wakes — the drain is a process.

## The machine

- **Boot profile A, fixed for the roadmap.** OpenSBI enters the kernel in S-mode at `0x80200000` with the hart id and DTB; non-boot harts park. One hart; SMP is parked.
- **QEMU `virt` is the development loop;** the same image runs on real RISC-V hardware. `./run.sh` boots the image and greps the serial line.
- **The kernel owns its console.** The boot stub parks the Emo driver's putc in the runtime's one-word console hook, so every printed byte — `println`, a panic — rides the polled 16550A driver through `peek`/`poke`; SBI keeps only the poweroff ecall. The receive side is interrupt-driven: the PLIC lands the UART's line in the trap shim, which fills a preallocated ring and wakes the console process; readers block on ordinary mailboxes.
- **Dual-run development.** Hardware sits behind structural interfaces, so kernel services run under the hosted interpreter against fake devices — millisecond iteration, directly assertable — and under QEMU against real ones. The two runs must agree byte for byte.

## The project in the tree

- The kernel package is **`emo_os`** — a flat name (the package registry bans `emo`-prefixed names for third parties; the kernel never publishes), distinct from the hosted `os` package. The user-side syscall stub is its own package — **`syscall`**, in the bundled registry, the typed Emo surface over the raw ecall ([`docs/syscalls.md`](docs/syscalls.md)) — not `os`.
- EmoOS tracks its own work in [`docs/TASKS.md`](docs/TASKS.md); compiler-side tasks (atomics, Stage B, image packaging) are executed in the Emo tree and tracked there.

## Running it

```console
$ (cd hello && emo build main.emo --target riscv64 --profile user -o ../hello.elf)
$ emo build main.emo --target riscv64
$ ./run.sh
```

## Milestones

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 — Bare-metal bring-up | freestanding image boots, prints through the SBI console | complete |
| S1 — Memory primitives | atomics + volatile `peek`/`poke` + `fence`, all targets | complete |
| S2 — riscv64 Stage B | typed calling convention, escape-point boxing | complete |
| M2 — Cooperative kernel | processes on metal, scheduler, interrupt-driven UART | complete |
| M3 — User mode | U-mode, ecall gate, user ELF, syscall stubs | complete |
| M4 — Process memory | arenas, quotas, reclaim on death, frame allocator | complete |
| M5 — SV39 | per-process address spaces, trampoline, fault-to-kill | complete |
| M6 — FS, shell, EmoUI | virtio-blk service, shell REPL, console UI | — |

Per-task checklists live in [`docs/TASKS.md`](docs/TASKS.md).

## Related documents

- [`docs/sv39.md`](docs/sv39.md) — the kernel's high-half layout: the two halves, the kernel's table, the two aliases, the boot.
- [`docs/fs.md`](docs/fs.md) — the filesystem service: the authoritative-versus-rebuildable split, the disk's layout, the commit points, the restart.
- [`docs/atomics.md`](../../docs/atomics.md) — the atomic memory model: sequential consistency only, the op set, the per-target matrix, the data-race semantics.
- [`docs/rtos-assessment.md`](../../docs/rtos-assessment.md) — the real-time boundary, in the Emo tree.
- [`docs/xv6.md`](../../docs/xv6.md) — the xv6-class feasibility assessment: what Emo replaces, what stays assembly.
- [`docs/runtime-and-freestanding.md`](../../docs/runtime-and-freestanding.md) — what a freestanding target owns.
