# EmoOS and the Linux ecosystem — the task tracker

Opened 2026-11-23. This tracker is the ecosystem programme's own:
EmoOS as a target for Linux open-source software. The kernel's
history stays in [`TASKS.md`](TASKS.md); this file records only this
track.

Chinese translation: [`EmoOS.TASKS.zh-CN.md`](EmoOS.TASKS.zh-CN.md).

## The decision

**Plan B — the source port.** Linux software is rebuilt for EmoOS
against an EmoOS C library; there is no Linux syscall ABI and no
prebuilt-binary compatibility. Plan A — the Linux personality that
loads Linux ELFs and answers the Linux syscall numbers — is out of
scope by decision. The gate's own verbs stay the ABI; the C library
is the one layer that speaks them, and the ecosystem arrives by
recompilation, not by emulation.

The reason is the one the OS was built on: EmoOS owns a narrow,
explicit boundary. A Linux personality would replace that boundary
with a second, much larger one (fds, `fork`, COW, signals, TLS,
dynamic linking) and the microkernel's isolation story would be the
first casualty. A libc port keeps one ABI and grows it by need.

## The contract

- **Toolchain.** A cross compiler on the host at first (stage 1):
  `riscv64-elf-gcc` today, a `riscv64-emos` sysroot and wrapper
  later. Self-hosted compilation is a late milestone, not a
  prerequisite.
- **Load.** C user programs link at the same window the Emo user
  image uses, `0x87100000` … `0x88000000`, as `PT_LOAD` segments
  with an entry inside the window. The kernel's exec loader already
  enforces exactly this (`exec.emo`'s `measure`).
- **BSS.** The exec loader copies a segment's file bytes and leaves
  the tail zeroed by the allocator run; the program's `crt0` clears
  `__bss_start` … `__bss_end` itself, the Emo entry stub's own
  discipline.
- **Writable staging.** Gate verb 1 (`write`) requires the source
  segment to be writable — the boot proof's `gate 500500 r3 r2`
  pins it. A C `write` therefore copies through a writable bounce
  buffer; a later task may teach the gate a readable-source rule,
  but not before the proof and the golden are re-pinned.
- **No libc assumptions.** Every syscall the library speaks is
  implemented by the kernel and documented in
  [`syscalls.md`](syscalls.md) as it lands; the library never
  fabricates a success.
- **By need.** The syscall set grows when a program needs a call,
  not from a Linux table copied whole. The package list in M4 is the
  test: it names what the system must actually run.

## Milestones

### M0 — the C door (in progress)

The smallest vertical slice: a C program, the cross compiler, the
existing exec loader, the machine's console. It proves the
toolchain contract before any libc work.

- [x] **T0.1** — The C skeleton: `c/crt0.s`, `c/emo_syscall.h`,
  `c/hello.c`, `c/chello.ld`, `c/build.sh` (the stub is `.s`, not
  `.S`: the Emo package tree assembles every `.S` it finds); the ELF's
  shape checked against `exec.emo`'s `measure` (entry and segments in
  the window, `PT_LOAD` only, `memsz ≥ filesz`).
- [x] **T0.2** — The build chain: `start.sh` builds `chello.elf`
  before the kernel; `user.S` embeds it, `runtime.S` parks its
  bounds, `main.emo` installs it on the volume as `chello.elf`, and
  the installer's line joins the golden's list.
- [x] **T0.3** — The metal proof: `exec chello.elf` from the
  desktop prints the line and exits 0; the exit event drains
  silently (a foreign image has no launcher slot).
- [ ] **T0.4** — The dune smoke: the scratch tree carries `c/` and
  builds the C app before the kernel; the suite's gate grows the
  cross compiler's own probe. (The code is wired; the `@emo_os`
  leg's own run is the remaining pin.)

### M0's record (2026-11-23)

The first image is `chello.elf`: 9,288 bytes, entry `0x87100000`,
two `PT_LOAD` segments (text RX at `0x87100000`, data RW at
`0x87101000`), the message in `.data` because the gate's write verb
copies from a writable segment. The metal proof: `exec chello.elf`
at the desktop printed `hello from C on EmoOS` and the prompt
returned; the first boot's wire said `installed chello.elf 9288`.
Two collisions were found and fixed on the way: the Emo package tree
assembles every `.S` under `projects/emo-os`, so the C stub is
`crt0.s`; and the tree carries one `link.ld` by base name, so the C
script is `c/chello.ld`. The golden installs the image and its file
counts moved with it (the first boot's restart mounts 7, the second
boot's mounts 8, `fs ls 8`); the exec beat waits for a golden run
that re-pins the frame ledger.

### T1.1's record (2026-11-23)

The C library's fd table is `c/emo_posix.c`: 16 descriptors, 8 file
slots of 2048 bytes, fd 0 on verb 2, fd 1/2 on verb 1 (a writable
bounce), file reads loaded at open through verb 7, writes buffered
and committed at close through verb 6, `unlink` on verb 9. `errno`
maps the gate's reasons (6→ENOENT, 3→EACCES, 2→EFAULT, 5→ENOSPC,
4→EINVAL). The metal proof: `chello.elf` (10,384 bytes) opened
`fd.txt`, wrote, closed, reopened, `fstat` answered `stat ok`, the
read answered `read back: fd table on EmoOS`, and `unlink` answered
`fd table cleaned`; the volume carried no `fd.txt` afterwards. The
cut is the library's: the offset and the buffer are per process,
writes replace the file at close, and files fit 2048 bytes.
`T1.1k` takes the table into the filesystem service for partial I/O
and larger files.

### T1.1k's record (2026-11-23)

The filesystem service owns the open-file table now: a page of its
own (`link.ld`'s `.emo_vfs` at `0x8700e000`), thirty-two 96-byte
handles keyed by `(pid, fd)` — the flag word, the offset and size,
the name. The gate grew verbs 36..41 (`fd_open`, `fd_close`,
`fd_read`, `fd_write`, `fd_lseek`, `fd_fstat`); they ride the
filesystem's existing 6..9 route family with the slot's `+88` marker
naming the fd table, so the shim's routing did not grow. The service
merges the old sectors under a partial write sector by sector and
commits the name table after the bytes — the whole-file write's
order, at an offset. `O_APPEND` starts at the size; `O_CREAT` and
`O_TRUNC` are the empty write; a restart drops the table (`abandon`
calls `handles_clear`). The C library shrank to the fd numbers and
the writable bounces.

Found on the way: the gate's buffer checks cover the image's
segments, not the process's stack, so the library reads into a
`.bss` bounce and copies out — the console path's own reason, now
stated rather than stumbled on.

The metal proof: `chello.elf` (10,336 bytes) answered `stat ok`,
`read back: fd table on EmoOS`, `fd table cleaned`; the fresh boot
said `installed chello.elf 10336`, `fs gen 2 files 7`, `fs ls 8`.

### M1 — the POSIX substrate (the kernel and the library)

The layer every C program stands on. Tasks land only as their first
consumer asks, but the order is the dependency order.

- [ ] **T1.0** — The gate's write rule: a readable source segment
  should serve `write`, retiring the libc's bounce copy. The boot
  proof and the golden re-pin with it — `gate 500500 r3 r2`'s first
  refusal no longer names the text segment, which becomes a success.
- [x] **T1.1** — The fd table in the C library: 0/1/2 on the
  console; `open`/`close`/`read`/`write`/`lseek`/`fstat` on named
  files over the gate's whole-file verbs; a per-process table, the
  offset and buffer the library's, writes buffered and committed at
  close. The cut is stated: files fit the gate's 2048-byte staging,
  and a descriptor opened for writing replaces the file.
- [x] **T1.1k** — The filesystem service's open-file table: handles
  keyed by pid, the offset and the size owned by the service, partial
  reads and writes, append, files past the gate's 2048 bytes; the
  handle area on its own page and the restart's `abandon` clearing
  it.
- [ ] **T1.2** — The VFS: a root, directories, path lookup, `cwd`,
  `mkdir`/`unlink`/`rename`; the volume's flat names grow the
  directory form, the golden's listing re-pinned.
- [ ] **T1.3** — Memory: `brk` and anonymous private `mmap`/`munmap`/
  `mprotect` over the process arena; a fault past the mapping is the
  kill it is today.
- [ ] **T1.4** — Process: `argv`/`envp` at `exec`, `fork` (copy the
  address space; COW is a later optimization), `execve`, `wait4`
  status words, process groups.
- [ ] **T1.5** — Pipes: `pipe`, `dup2`, blocking reads, EOF on the
  last writer's close.
- [ ] **T1.6** — Signals: the basic set, dispositions, `kill`,
  `sigaction`/`sigprocmask`, the status encoding the shell reads.

### M2 — the C library (musl-derived)

- [ ] **T2.1** — The syscall layer: musl's `arch/riscv64` stubs over
  the gate, one function per documented verb.
- [ ] **T2.2** — `crt`, TLS, `malloc`, `stdio`, `string`, `errno`;
  static `hello`, `printf`, `malloc`, `getenv`.
- [ ] **T2.3** — The sysroot and the compiler wrapper: `libc.a`, the
  headers, the link script; `riscv64-emos-gcc`.
- [ ] **T2.4** — The conformance probe: a small C suite pinning the
  calls the milestone carries, byte-identical on the metal and the
  host interpreter where both apply.

### M3 — emosh as the default shell

- [ ] **T3.1** — emosh builds against the sysroot. Every source edit
  forced by the port is listed; the goal is none.
- [ ] **T3.2** — emosh becomes the boot foreground — the line
  editor, history and completion — replacing `hello/shell.emo` as
  the machine's shell.
- [ ] **T3.3** — The console's handoff: the serial bytes on fd 0,
  writes on fd 1/2, `poweroff` as the exit route the boot still
  owns.
- [ ] **T3.4** — The desktop's `exec` hands `argv`/`envp` to the
  child; the launcher and the shell share one door.

### M4 — the ecosystem

- [ ] **T4.1** — busybox or dash: the first real POSIX program, the
  shell's own acceptance.
- [ ] **T4.2** — The core utilities: a first corpus (file, text,
  process), each pinned by a golden.
- [ ] **T4.3** — Build systems: `make`, then autotools/CMake and
  `pkg-config`, so a Linux tarball's own build runs.
- [ ] **T4.4** — The package corpus and its CI: what builds, what
  runs, what each needs; the list is the tracker's honest answer.
- [ ] **T4.5** — Self-hosted compilation: GCC/Clang and the tools on
  EmoOS itself. Last, because it needs everything above.

## The bounds

- No Linux syscall ABI, no Linux ELF compatibility, no prebuilt
  binaries, no glibc.
- No dynamic linking until a static corpus earns it; musl static is
  the first contract.
- The microkernel stays a microkernel: the C library is a user
  process's library, not a second kernel.
- Every addition is a task here before it is code, and every task
  names its consumer.
