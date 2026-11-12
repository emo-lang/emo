# Emo on microcontrollers (ESP32) — an assessment

Written 2026-11-12. A technical feasibility assessment, not decided
design. Numbers marked **measured** come from this repository's sources
of that date (host: Apple Silicon, `cc -O2`); everything on the
ESP32 side of the table is extrapolation and is labeled as such. The
RTOS-flavored sibling of this note is
[rtos-assessment.md](rtos-assessment.md); the freestanding execution
model Path B rests on is [runtime-and-freestanding.md](runtime-and-freestanding.md).

The question: can Emo programs run on microcontrollers — concretely the
ESP32 family — and what would that cost and deliver?

## The verdict

Feasible, but not a run-it-today situation. The **c target is the
shortest path** onto an ESP32 and needs one bounded porting effort
(four blockers, weeks not months). Performance is comfortable for
control-plane work and tight for data-plane work. **Memory is the real
constraint; code size is not.** Two side paths exist — the freestanding
riscv64 backend on a 64-bit RISC-V MCU, and the beam target over
AtomVM — and one path is a dead end: wasm.

## What was measured

Host build, arm64, `cc -O2`, 2026-11-12:

| what | measured | note |
| --- | --- | --- |
| runtime text, the whole `emo_c_runtime.c` | **64,790 B** | one translation unit; scheduler, fibers, net, os, strings, maps included |
| hello world generated body | **114 B** | `examples/hello_world/.emo-build/main.c` |
| 10M-iteration loop generated body | **128 B** | `benchmarks/plain_loop/.emo-build/main.c` |
| boxed `Int64` cell | 24 B + malloc overhead | `[rc][header][payload]`, one `malloc` per cell (step 49) |
| fiber stack | **8 MiB constant** | `emo_spawn_process` matches the hosted OS default |
| bump-arena chunk floor | 64 KiB | `emo_alloc`; chunks are never reclaimed (see below) |

Program code is negligible next to the runtime; a hello world ships the
64 KB runtime plus libc pieces — a 100–200 KB flash budget, comfortable
on a 4 MB part and inside S3's dual-OTA layout.

The performance premise was verified in the generated code, not
inferred: **typed hot loops lower to unboxed native `int64_t` locals in
a label-and-jump loop — zero allocation per iteration**
(`benchmarks/plain_loop/.emo-build/main.c`). The benchmark table of
2026-11-09 (`benchmarks/results.md`) was re-verified for the loop row
on 2026-11-12 (0.03 s user time, matching the recorded 27 ms).

## Path A — the c target on ESP32 (shortest; recommended)

`emo build --target c` emits one `main.c` beside a copy of
`emo_c_runtime.c` and links with the system `cc`. The generated C is
plain and portable; four blockers stand between it and an ESP-IDF
build, each located in the source:

1. **The LP64 assumption.** `emo_value` is one `uintptr_t` — that part
   survives 32 bits, since immediates (Bool/Char/Byte) fit the tag
   scheme in 32 bits. What does not: `emo_unbox_i64` reads a *single*
   payload word for the whole `Int64`, and `emo_cell`'s refcount is an
   `int64_t` — a 32-bit build truncates boxed scalars. The fix is
   contained in the runtime file: widen payload slots to 8 bytes
   (a uniform slot on both sides of the boundary), tens of sites;
   generated code is untouched, because typed positions only cross into
   the dynamic world through the box/unbox calls.
2. **The fiber stack constant.** Every Emo process gets an 8 MiB
   malloc'd stack — sensible on a hosted OS, fatal on a 520 KB part.
   It must become a configurable size (the 16–64 KiB class), with the
   recursion-depth consequence stated loudly, as the current comment
   already does.
3. **ucontext.** Xtensa ships no `makecontext`/`swapcontext`; the fiber
   switch must be hand-written (callee-saved registers, `sp`, `pc`,
   FPU optional — on the order of a hundred lines of assembly per ISA;
   RV32 can vendor libucontext instead). The friendly part: the
   scheduler is **purely cooperative** — the runtime contains no
   pthreads, no timers, no signal-driven preemption anywhere — so
   nothing fights the RTOS for the CPU.
4. **The POSIX surface.** `poll`, sockets, `dirent`, stdio map onto
   ESP-IDF (LWIP + newlib + VFS). `fork`/`exec`/signals/environ do not
   exist there — but the runtime already carries the honest degradation
   door, `emo_unsupported()`, and the os module's failures are values
   (`(R.ok, ...)` / `(R.error, reason)`), so unsupported syscalls can
   answer as data instead of breaking the build. TLS rides OpenSSL on
   the hosted profile; on ESP32 defer it (mbedTLS later, or build
   without it).

A fifth item is forced by memory, not the toolchain: **the bump arena
never reclaims**. `emo_alloc`'s chunks are never freed and
`emo_arena_bytes` only grows; typed render loops stay flat because step
49 made cells individually malloc'd, but the native transient paths —
FFI cstr copies, os read buffers, `map_keys`/`map_values` arrays,
printf rendering — consume arena permanently per call. On hosted 64-bit
that is tolerable; on a 320–512 KB SRAM part a long-running service
leaks until it dies. The chunk floor (64 KiB) also needs to shrink.
This one deserves recording on the hosted track too: it is a standing
hazard for long-running hosted services, not only an MCU port item.

## Path B — the riscv64 backend on an RV64 MCU (the most "Emo" route)

The riscv64 target is already a bare-metal design: one freestanding
static ELF, a bump allocator over a fixed `.bss` region, **no malloc,
no libc, no POSIX**, 64-bit tagged words native on RV64. The only
distance to an MCU is the boot profile: it currently assumes an OpenSBI
S-mode entry with the SBI ecall console (`qemu-system-riscv64 -machine
virt`). A second boot profile — M-mode entry, UART MMIO console, a
linker script for the part — lands it on a real chip. The nearest part
is the Kendryte K210 (dual RV64 @ 400 MHz, 8 MB SRAM, no S-mode, so the
kernel line's satp-based EmoOS profile would not run there — a bare
user-profile runtime would).

ESP32 cannot take this path at all: C3, C6, and P4 are RV32, and the
64-bit tagged-word model wants 64-bit words — an RV32 port is a backend
rewrite (values in register pairs), not a port. Not recommended.

## Path C — wasm on a microcontroller (a dead end)

The wasm target emits **WasmGC** (`anyref`, per-class struct types,
`ref.test`/`ref.cast`). The wasm engines that actually run on MCUs
(Wasm3, WAMR) implement core wasm only; none supports the GC proposal.
Making the wasm path work there would mean a second, linear-memory
lowering of the whole value model — more work than Path A with nothing
extra to show. Not recommended.

## Path D — beam over AtomVM (zero runtime work; one open question)

AtomVM runs a BEAM subset on ESP32 officially. Emo's beam target emits
Core Erlang for `erlc`, so the pipeline shape matches, and the
send/receive/Pid process model lands in AtomVM's sweet spot. The open
question is coverage: the emitter's grammar facts are pinned to the OTP
29 reader, while AtomVM's supported OTP/BIF surface is narrower and
older. The probe is cheap — AtomVM also runs on the host — and should
be spent before committing to Path A or D.

## Performance

**Measured** (`benchmarks/results.md`, recorded 2026-11-09; loop row
re-verified 2026-11-12), on Apple Silicon at `cc -O2` speed:

| workload | measured, host | measured, c target |
| --- | --- | --- |
| 10M-iteration loop | 27–37 ms | 27 ms |
| fib(30) | 18 ms (specialized) / 29 ms (unspecialized) | 26 ms |
| bytes get × 20M | 1138 ms (dynamic) | 138 ms |
| fib(30), interpreter (`emo run`) | 980 ms | — |

**Extrapolated to ESP32-S3 @ 240 MHz** (in-order Xtensa LX7; scaled by
clock and a 2–3× IPC factor; medium confidence — no xtensa toolchain or
board was used):

| workload | extrapolated |
| --- | --- |
| 10M-iteration loop | ~0.4–0.8 s |
| fib(30) | ~0.2–0.5 s |
| fib(30), interpreter path | ~5–10 s (configuration/glue only) |

Timing character: cooperative scheduling plus per-cell reference
counting means **no collector pauses** and statement-level jitter —
compatible with soft-real-time task logic. Hard µs-class ISR work stays
in C; Emo sits above it (tasks, state machines, protocols).

## Which chip maps to which path

| part | shape | viable route |
| --- | --- | --- |
| ESP32 / S2 / S3 | Xtensa LX6/LX7, 1–2 cores, 320–512 KB SRAM (+PSRAM on S3), FPU on S3 | Path A, after the port |
| ESP32-C3 / C6 | RV32IM(C) @ 160 MHz, 400–512 KB SRAM, no FPU, no native atomics (64-bit atomics emulate over locks) | Path A, after the port |
| ESP32-P4 | RV32 ×2 @ 400 MHz, 768 KB SRAM (+PSRAM), FPU, no radio | the most attractive ESP32 part once the 32-bit work lands |
| K210 (contrast) | RV64 ×2 @ 400 MHz, 8 MB SRAM, M-mode only | Path B — the existing backend, smallest effort |

## The porting checklist (Path A, in order)

1. Widen cell payload slots for 32-bit (the LP64 fix, contained in
   `emo_c_runtime.c`).
2. Make the fiber stack size configurable; hand-write the Xtensa
   context switch (or vendor libucontext for the RV32 parts).
3. Shrink the arena chunk floor and add chunk reclamation.
4. Map the os/net surface onto ESP-IDF (LWIP `poll`, VFS stdio),
   degrade the rest through `emo_unsupported` / `(R.error, reason)`.
5. Give the CLI a `--cc`/sysroot passthrough (today it hardcodes the
   system `cc`; the two files in `.emo-build/` also compile by hand).
6. An `app_main` shim in place of `main()`.
7. Later: `rand` onto the hardware RNG (`esp_random` — strictly better
   than `getentropy`), TLS onto mbedTLS.

## Recommendation

1. For the "Emo on ESP32" story: **ESP32-S3 + Path A**. First
   milestone: hello world, two cooperating processes, and a UART line.
2. For the smallest effort inside the EmoOS narrative: **K210 + a Path
   B boot profile** — same code lineage as the OS work, no malloc, a
   fixed heap.
3. Spend half a day on the **AtomVM probe** before committing; it is
   the cheapest information in this space.
4. C3/C6/P4 all wait on the 32-bit work; P4 is the prize afterwards.
5. Fix arena reclamation on the hosted track first regardless of which
   path wins — it is both a porting prerequisite and a standing
   long-running-service hazard.

## Verification note

Everything on the "measured" rows was produced by compiling this
repository's runtime and generated programs with the host `cc` on
2026-11-12. No ESP32 or RV64 MCU toolchain and no board were used;
every ESP32-side number here is extrapolation, and the first on-board
run rewrites those rows.
