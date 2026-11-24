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
  `riscv64-elf-gcc` today, a `riscv64-emoos` sysroot and wrapper
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
- **Readable sources, writable destinations.** Every pointer argument
  lies inside one segment of the caller's own and carries the
  permission the access needs: a destination the gate writes into
  needs `W`, a source it lifts needs `R` only (T1.0). The image's own
  text and rodata therefore serve `write`; the C library bounces a
  buffer the gate cannot reach — the stack's — through its `.bss`
  copy, and the boot proof's `gate 500500 w0 r2` pins the rule.
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
- [x] **T0.4** — The dune smoke: the scratch tree carries `c/` and
  builds the C app before the kernel; the suite's gate grows the
  cross compiler's own probe.

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

### T0.4's record (2026-11-23)

The smoke leg's scratch tree now carries `c/` — the stub, `fork.s`,
the headers, `hello.c`, `chello.ld`, `build.sh` — `pipe.emo` and
`sig.emo`; `c/build.sh` builds `chello.elf` before the kernel's
`main.elf`, so the embedded C app is the one the door's tests expect.
The leg skips when `EMO_CC`'s compiler or the QEMU/binutils probe is
absent, the suite's own gate. The wallpaper generator's second output
(`--fixture`) lands outside the built trees: the project builds every
`.emo` it finds, the fixture needs the desktop's packages, and the
kernel's scratch stages none of them.

The leg's own run found three latent defects. T1.5's route bound was
open-ended (`op >= 40`), so the pipe check swallowed every later op —
the compositor's seat variants (`16 + 32*slot`) and the notification
family's (`27 + 32*slot`) went to the process service, which drops an
op it does not know; a client in the second seat parked forever, and
the counter's rise stopped at `comp 768 494`. The bound is the
family's own, 40..44. T1.4b2's fork cells (4024..4040) lay inside the
exec name buffer (4024..4048), so a plain exec's name copy left
`fork_use_cell` non-zero and the next exec was taken for a fork; the
desktop answered `bad argument`. The cells moved to 4048..4064,
between the name buffer and the screen pass's pair. The launcher's
hosted golden still catalogued four apps while T0.2 installs
`chello.elf` as the fifth; its whole-catalog panel folded to
`3690392675` where the corpus had `4244428722`. The fixture's catalog
gained the C app, its `launch`/`launchr` pins moved, and the shell
list's check grew the fifth image and its `-A7` window.

The metal run is green through both boots and the whole desktop
choreography; `frames 1918 1674` is the last line, the ledger the
earlier pin named. The `@emo_os` leg's own run builds the C app in
its scratch tree and passes.

### M1 — the POSIX substrate (the kernel and the library)

The layer every C program stands on. Tasks land only as their first
consumer asks, but the order is the dependency order.

- [x] **T1.0** — The gate's source rule: a readable segment serves
  every buffer the gate lifts — `write`'s bytes, a file's name, the
  exec's texts, a pipe's — and only a destination needs `W`. The boot
  proof and the golden re-pinned with it (`gate 500500 w0 r2`, the
  text segment answering instead of refusing), and the C library's
  write paths pass a segment's buffer straight through; the `.bss`
  bounce is the stack buffer's fallback.
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
- [x] **T1.2** — The C library's path layer: a root, relative and
  absolute paths, `.` and `..`, the process's `cwd`, `mkdir`/`rmdir`/
  `stat`/`rename`, `opendir`/`readdir`/`closedir` over the volume's
  flat names. A directory is the marker `dir/` and the names under its
  prefix; the 24-byte flat name bound is the cut, a longer path
  answering `ENAMETOOLONG`.
- [x] **T1.2k** — The service's real directory entries: a type word
  at the name entry's `+56` (0 file, 1 directory), `path_type`,
  `mkdir` and `rmdir` as verbs 42..44, and the C library switched to
  them. An implicit directory — names under a prefix — still answers
  as a directory, so the flat years' volumes keep working.
- [x] **T1.2d** — The desktop's typed listing: verb 45 `list_dir`
  carries the type byte, the icons and the folder view read it, and
  the prefix grouping retired from `desk_view_build`. The launcher's
  `.elf` catalog still reads the flat list. The golden's own run is
  the remaining pin; the boot's wallpaper and both write beats'
  frame digests matched by hand.
- [x] **T1.3** — Memory: `brk`/`sbrk` and anonymous private `mmap`/
  `munmap`/`mprotect` over the process's arena — the user run's
  sixteen 64 KiB blocks, 1 MiB. Verb 46 exposes the base/end as page
  numbers; the C library's bump allocator owns the break, and a write
  past the arena is the page fault it always was.
- [x] **T1.3k** — The allocator's reuse: `malloc`'s first-fit free
  list and `mmap`'s page free list — `free` and `munmap` hand blocks
  back, `malloc` and `mmap` reuse them, `realloc` copies; the 1 MiB
  arena is the bound.
- [x] **T1.3v** — The arena's growth past its 1 MiB run: verb 47
  `arena_grow(bytes)` takes whole 64 KiB blocks, maps them at the
  pages after the cell's end, and the growth list's rows go home at
  the death — the shim's fault and heap paths and the process
  service's normal exit. `arena_extend` in the library follows the
  answer.
- [x] **T1.4a** — `argv` at `exec`: verb 48 `exec_args(name, args)`
  stages the line's rest on the execargs page, the process service's
  exec pickup builds the child's first stack (argc, argv — the name
  then the words — the argv's NULL and the envp's NULL), the C crt0
  reads the args base from the cells page and hands `main` its
  `argc`/`argv`/`envp`, and the desktop's `exec` passes the line's
  rest. The envp is empty for now.
- [x] **T1.4b1** — The process and environment surface: `getpid`
  (verb 49), `setpgid`/`getpgid` (50/51, one group byte per pid on the
  growth page's tail, 0 the pid's own group), `getenv`/`setenv`/
  `unsetenv` with `environ` (the `main`'s envp scanned at first use),
  and the library's `wait4`/`waitpid` over verb 4 — the exit status
  `code << 8`. The any-child wait rode with T1.4b2; the environment
  at `exec` with T1.4b3.
- [x] **T1.4b2** — `fork` (verb 52): the process service copies the
  caller's image run, stack block, arena run and grown blocks, maps
  them at the caller's virtual bases in a fresh table, copies the
  private handoff page (the saved context and the parent's bases in
  its tail), and starts the child at the library's resume trampoline;
  the child returns from `fork` with 0, the parent with the child's
  pid. The wait's target and the exit's code moved to per-pid cells
  (the shared pair let a staged exit overwrite a wait's argument);
  verb 4 answers the child's pid above its code, and the any-child
  wait is an exit-table scan by parent cell or a parked wait answered
  by the first child's exit. The C library grows `fork` (the assembly
  context save), `exit`/`_exit`, and `wait4`'s packed answer.
- [x] **T1.4b3a** — Fork's descriptors: the library's fd table now
  carries the name, flags and offset beside `used`; a child's first
  access to an inherited fd reopens the name under its own pid and
  seeks to the copied offset (O_APPEND keeps the service's end, and
  O_CREAT/O_TRUNC are dropped). The description's offset diverges
  from the parent's — the documented approximation until the service
  owns shared descriptions.
- [x] **T1.4b3b** — `execve` (the in-place image replace): verb 54
  stages the name, the argv text and the envp text; the process
  service loads the new image on a fresh stack and arena, and the new
  runtime `user_replace(pid, entry, stack, arena, arena_end)` reaps the
  caller's old image, stack, arena and grown blocks, dresses the same
  slot with the new frame and calls the build hook — the same pid runs
  the new program, the parent/pgid cells stay, and the old fds are
  dropped (the library's own table is fresh — the record's gap).
  The C library's `execve`/`execv` flatten `argv[1..]`
  and `envp` into the door's space-separated texts (a word with a space
  is EINVAL); the new image's `argv[0]` is the file name, and its
  `envp` is the caller's. The library's fd table and cwd are fresh
  after the replace, and the old page table and private page leak —
  the follow-ups the record names.
- [x] **T1.5** — Pipes: `pipe`, `dup2`, blocking reads, EOF on the
  last writer's close. Verbs 55..60 (the bind, the read, the probe,
  the write, the dup and the close), the process service's second arm:
  the gate stages each request in the calling pid's record on
  `.emo_pipe`'s request page and routes it; the service owns every
  mutation, parks a reader on an empty ring a writer may still fill,
  parks a writer on a full ring, and wakes a peer from the close's
  last-holder counts — the last writer's close is EOF, the last
  reader's the broken pipe. The library's `pipe`/`dup`/`dup2` and its
  descriptor-kind cache (the probe once per fd) put the ends behind
  POSIX calls; the ends copy across `fork` and the low three across
  `execve`, so a shell's `cmd1 | cmd2` is two children and two `dup2`s.
- [x] **T1.6** — Signals: the basic set, dispositions, `kill`,
  `sigaction`/`sigprocmask`, the status encoding the shell reads.
  Verbs 61..65 (the kill, the disposition, the mask, the trampoline's
  return and the pending word), the gate's own — no service between.
  Eight signals with default/ignore/handler dispositions; the handler
  runs by rewriting the trap frame the resume restores, its return the
  trampoline page's `sig_return` ecall, which puts the interrupted
  frame and mask back. The defaults end the process (SIGCHLD's is to
  ignore), the wait's status word becomes POSIX's (`code << 8` for an
  exit, the signal's number for a signal death), and a child's exit
  raises SIGCHLD while a broken pipe raises SIGPIPE.

### T1.0's record (2026-11-23)

The gate's pointer rule splits in two: `check_read` beside
`check_write`, the same one-segment, overflow-safe range walk, asking
the segment's `R` bit instead of `W`. Every source the gate lifts
switched to it — verb 1's bytes, the filesystem verbs' names (6..9,
36, 42..45), the fd write's bytes (39), the pipe write's (58), the
exec doors' name and texts (24, 48, 54), the notification's title and
body (27) and the clipboard's write (34). Every destination kept
`check_write`: verb 7's and 38's read buffers, verb 8's and 45's
listing, the notification take's and the pipe read's buffers, the
clipboard's paste (35).

The C library's three write paths — console, file, pipe — now hand the
caller's pointer to the verb first and bounce only when the gate says
2 or 3: a source in the image's own text or rodata (a string literal)
rides straight through, a stack or heap buffer falls back to `.bss`
and is retried there. The file path keeps its lazy-adopt retry beside
the fallback; a refusal's answer is the whole of the failure, so the
retry is safe.

The boot proof's text-segment probe writes zero bytes now: the source
rule is the same check at any length, and a zero length keeps the
serial line clean of the entry's machine code. The line re-pinned from
`gate 500500 r3 r2` (the text segment refused, reason 3) to
`gate 500500 w0 r2` — the answer 0, the kernel's memory still reason
2 — and the golden's array and its key-feed sync moved with it;
`how-to-start-emoos.md` (EN + zh) names the new line.

The metal proof: `exec chello.elf hello world` answered every earlier
beat, the new `gate 500500 w0 r2` sat where the old refusal's line did,
and `chello.elf`'s `rodata ok` — a literal write — rode the direct
path. The golden's own run reached and passed the new line
(`gate 500500 w0 r2`, then `echo 88`), and failed later on a beat
unrelated to this change: the counter window's rise stalls after two
frames (`comp 768 494` never arrives). The same failure reproduces on
the tree before this change (stashed and re-run), so it is recorded as
pre-existing, not T1.0's.

Gaps: the gate still judges a buffer by the image's segments only, so
a stack or heap buffer is reason 2 and the library's bounce remains
their road — accepting the caller's own stack block and arena would
retire it wholly, a later task. A source in a segment without `R`
(an execute-only segment) is reason 3, as it should be.

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

### T1.2's record (2026-11-23)

The path layer is `c/emo_posix.c`'s: `resolve` canonicalizes a path
against the cwd (`.` skipped, `..` pops, a leading `/` starts at the
root) into the volume's flat name; `mkdir` writes the zero-length
marker `dir/`, `rmdir` requires it empty, `unlink` refuses it,
`rename` copies through the fd layer, `stat` probes the size with a
zero-cap read, and `opendir`/`readdir` parse the gate's newline list
into the immediate children (deduped, the marker skipped). The cut is
the 24-byte flat name and the marker directory; `T1.2k` takes real
entries into the service.

The metal proof: `chello.elf` (19,816 bytes) answered `stat ok`,
`read back: fd table on EmoOS`, `fd table cleaned`, `path ok`,
`dir listing ok`, `rename ok`, `vfs cleaned`; the volume was back to
its eight files after the run.

### T1.2k's record (2026-11-23)

The type word is `c_type` at the name entry's `+56` — 0 a file, 1 a
directory; the volumes before it carry zero there, the file it
always meant. The service answers `path_type` (verb 42: the type
entry, or an implicit directory's prefix), `mkdir` (43: the explicit
entry, the parent a directory, an existing name refused) and `rmdir`
(44: the type entry, empty, removed); `write_file` and `remove_file`
refuse a directory entry. The fd and path verbs share the request
slot and its `+88` marker, so the shim's routing stays the 6..9
family. The C library's existence checks now ask the service, and
`mkdir`/`rmdir` are the service's own.

The C app's `dir` is a real type entry; the implicit `a/one.txt`
names the shell and the desktop have always written keep working as
implicit directories. The desktop's prefix view is untouched — T1.2d
takes its own typed listing. The metal proof: `chello.elf` (19,840
bytes) answered `stat ok`, `read back: fd table on EmoOS`, `fd table
cleaned`, `path ok`, `dir listing ok`, `rename ok`, `vfs cleaned`.

### T1.2d's record (2026-11-23)

The service's typed listing is verb 45, `list_dir`: the named
directory's immediate children, each a type byte (0 file, 1
directory), a length byte and the name, deduped in the name table's
order, the implicit directories included. The desktop's
`desk_list_load` loads the launcher's flat list and the current
folder's typed list; `desk_view_build` parses the typed records (the
prefix grouping retired), `desk_icons_refresh` and `desk_icon_press`
reload the typed list when the view or folder moves, and the `.elf`
catalog still reads the flat list. The syscall package grew
`list_dir` in place; its five locks were re-pinned (`hello`,
`counter`, `files`, `editor`, `winbuf`).

The metal proof: the desktop's boot wrote `comp 0 0 884125748` (the
golden's wallpaper pin), `desktop icons 2` and `desktop apps 5`;
`write note.txt shell wrote this` answered `frame 624477878`, and
`write a/one.txt first inside` answered `frame 1586168726` — both
the golden's pins, the typed view's pixels identical to the prefix
view's. The folder screendump's own golden run remains the pin (not
run here).

### T1.3's record (2026-11-23)

The arena is the user run's sixteen 64 KiB blocks — 1 MiB, not the
64 KiB the first draft said — mapped at the physical identity by
`space.build`; the build writes the child's per-pid cell (the proc
page's second half, `0x8700d800`) with the base/end page numbers —
the build knows the child's pid, so no service copies it and no
shared cell races. Verb 46 `arena_info` answers the caller's cell.
The C library's `mem_init` decodes the page numbers;
`brk`/`sbrk`/`malloc`/`free`/`realloc`/`mmap`/`munmap`/`mprotect` live
on its bump allocator; in this cut `munmap` and `mprotect` were the
arena's no-ops (T1.3k makes `munmap` hand its pages back), and a
write past the end is the page fault it always was.

Found on the way: the first pack put the physical addresses in their
own halves — the arena's bit 31 made the ecall answer negative, the
shim read it as a route, and the compositor said `the verb is
nobody's (24)`. The pack is page numbers now (base in the high 20
bits, end in the low 20).

The metal proof: `chello.elf` (20,376 bytes) answered `heap ok` and
`mmap ok` after `stat ok`, `read back: fd table on EmoOS`, `fd table
cleaned`, `path ok`, `dir listing ok`, `rename ok`, `vfs cleaned`;
the debug run's arena base was `0x84550000` and `sbrk(0)` answered
it.

### T1.3k's record (2026-11-23)

The initial arena is 1 MiB (the user run's sixteen 64 KiB blocks);
the first draft's "64 KiB" was the run's per-block unit. The library's
allocator now has two first-fit free lists: malloc's 16-byte-header
blocks (`free` hands one back, `malloc` reuses it and splits the
remainder) and mmap's page blocks (`munmap` writes the node back,
`mmap` first-fits it), with `realloc` copying and freeing. The fixed
run is the bound; growing past it is T1.3v (frames, the page table's
new mappings, the death reclaim).

The metal proof: `chello.elf` (20,536 bytes) answered `heap ok`,
`mmap ok`, `reuse ok`, `mmap reuse ok`.

### T1.3v's record (2026-11-23)

The growth is `space.grow` behind verb 47: the bytes, the blocks the
frame allocator backs, the pages after the cell's end — each block at
its own physical identity, the virtual pages the suite's — and the
rows in the `.emo_grow` page at `0x8700f000` (200 `(pid, block)` rows,
the count at its head; T1.4a's execargs page is the page's tail). `space.grow_reap` gives a pid's rows home; the
shim's fault and heap paths call it after `emo_arena_reap`, and the
process service's exit calls it for the normal exit. The library's
`arena_extend` asks the verb, follows the answer's page into
`heap_end`, and `brk`/`sbrk`/`malloc`/`mmap` call it when the next
byte is past the end.

Found on the way: the grown blocks are not the initial run, so the
runtime's `emo_arena_reap` cannot see them; the rows and the two
extra reclaim sites are the task's substance.

The metal proof: `chello.elf` (24,752 bytes) answered `grow ok` after
the fd, VFS and reuse beats; the 3 MiB malloc's first and last bytes
held, and the frame ledger's held count was the same before and after
the growth (232, the rows went home at the exit).

### T1.4a's record (2026-11-23)

The args door is verb 48 `exec_args(name, nlen, args, alen)`: the
gate stages the name and the line's rest (at most 512 bytes) on the
execargs page, sets the use flag, and routes the process service's
exec op; the pickup reads the flag's raw cell, and the args' door
calls `transaction_args`; the plain door copies the name to the exec
page's buffer as before. `build_args` writes the child's first stack:
argc at the top, argv (the program's name, then the args' words split
at spaces), the argv's NULL, the envp's NULL, the strings — the sp is
the physical base; the C crt0 reads it from the cells page's
`0x87fff080`, moves the sp, and hands `main` its triple. The Emo
passes never read the args; their runtime overwrites the region.

Found on the way: the first execargs page at a fixed new address
(`0x87010000`, then `0x8700b100`) was not mapped in the process
service's table — the exec pickups' peek trapped in S-mode and the
machine said `the kernel took an unexpected trap`. The page that is
mapped is the grow list's (`0x8700f000`, the T1.3v work proved it);
the execargs moved to its tail and the grow list shrank 255 → 200
rows. Also found: the cross-module `exec.args_use()` call itself
trapped on this target, while `exec.args_name()` and kin answered
fine; the process service reads the use flag from the raw cell.

The metal proof: `exec chello.elf` answered `args none` (argc 1) and
`exec chello.elf hello world` answered `args ok` (argc 3, argv[1]
`hello`, argv[2] `world`); `chello.elf` is 24,856 bytes and the
whole C chain (fd, VFS, reuse, grow) stayed green. The desktop's
`exec` takes the line's rest as the args; the syscall package grew
`exec_args` in place and its five locks re-pinned.

### T1.4b1's record (2026-11-23)

The process surface: verb 49 `getpid`; verb 50 `setpgid(pid, pgid)`
(the target 0 the caller, the group 0 the target, the caller or its
child only, the parent cell the authority); verb 51 `getpgid(pid)`
(the same authority). The group cells are one byte per pid on the
growth page's tail (`0x8700f000 + 3784`, after the execargs; 256
bytes), 0 meaning the pid's own group. The library's environment is
`environ` (the crt0 hands it `main`'s envp; the first use scans it
into a 16×128 static table) behind `getenv`/`setenv`/`unsetenv`, and
`wait4`/`waitpid` ride verb 4, the status `(code & 0xff) << 8`;
the any-child wait (`pid <= 0`) answers `ENOSYS` until T1.4b2.

The metal proof: `chello.elf` (25,560 bytes) answered `proc ok` and
`env ok` after the fd, VFS, reuse, grow and args beats — the pid
queried, the group set and read back, `EMO=yes` set, read and
unset — with the machine's exit route clean.

### T1.4b2's record (2026-11-23)

fork is verb 52 `fork(ctx, entry)`: the gate judges the resume entry
against the caller's executable segments, stages the saved context and
entry on the exec page's tail, and routes the process service; the
pickup holds the execs' busy cell through the spawn. The clone copies
the parent's image record into a free record with a fresh run, copies
the private handoff page and writes the fork recipe (the saved
context, the parent's stack and arena bases, its pid, its packed arena
cell), and copies the stack block before the spawn — `user_spawn`
zeroes its synthetic frame at the block's bottom afterwards, so only
the dead bottom bytes give way. `space.build` maps the stack at the
parent's base with U and at its own identity without U (the kernel's
anchor frame), copies and maps the arena's run and every grown row at
the parent's virtual places, appends the child's grown rows, and
writes the child's arena cell as the parent's. The child starts at
`emo_fork_resume`, reloads gp, moves sp to the saved context, and
returns through fork's epilogue with a0 = 0.

The wait's target and the exit's code moved from the shared
`proc_arga`/`proc_argb` cells to per-pid cells on the new
`.emo_procargs` page (0x8700a000; 256 words each) — without it a
staged exit could overwrite a wait's target before the service read
it. Verb 4 now answers `(pid << 32) | code`; the Emo `syscall.wait`
stub strips the pid, and the C `wait4` returns the actual child (the
any-child wait knows it now). A parked wait consumes the exit directly
and the entry never enters the exit table; a wait that comes later
consumes the entry. The child inherits the parent's process group.

Found on the way: the first fork copied the stack inside the build,
after `user_spawn` had zeroed the synthetic trap frame at the block's
bottom — the copy clobbered the anchor and the child resumed with the
parent's registers (both processes printed the parent's line). The
copy now precedes the spawn. The other finding was the shared
wait/exit argument cells: the child's exit code landed in the wait's
target, and the wait answered the parent's pid as the code.

The metal proof: `chello.elf` (25,928 bytes) answered `fork ok` and
`wait ok` after the fd, VFS, heap, grow, args, proc and env beats —
the child exited 42 and the parent read it, then the any-child wait
reaped the second child's 7 — and the machine's exit route was clean.
The library's fd numbers copy with the image; T1.4b3a's lazy reopen
makes the filesystem service's per-pid handle follow on first use.
execve and the environment's handoff are T1.4b3b.

### T1.4b3a's record (2026-11-23)

The library's descriptor table grew the copied name (24 bytes), the
byte length, the open flags and the offset beside `used`. `open_name`
fills them; `read`/`write` advance the offset, `lseek` sets it.
A service answer of -4 on a used descriptor means this pid has no
handle — a fork's inherited fd — so the library reopens the stored
name under its own pid (O_CREAT and O_TRUNC dropped, O_APPEND left to
the service's end) and seeks to the copied offset. `close` on such a
descriptor is a success that only clears the child's copy. The offsets
diverge after the fork — the service's handle is not a shared
description yet, the documented approximation.

The metal proof: `chello.elf` (30,280 bytes, one image block) opened
`forkfd.txt`, wrote `fork fd`, sought to 0 and forked; the child read
`fork ` through the reopened descriptor, closed it and exited 0, the
parent reaped it and answered `fd fork ok` — after the fd, VFS, heap,
grow, args, proc, env, fork and wait beats, with the machine's exit
route clean.

### T1.4b3b's record (2026-11-23)

`execve(path, argv[], envp[])` is verb 54: the gate stages the name
and both texts (args at 512 bytes, env at 256 on the free tail at
0x8700b900, clear of the console's per-pid cells), the use flag names
the replace door, and the process service allocates the new stack and
arena and loads the image through `exec.transaction_replace` — the
loader's record, run and private page, the first stack carrying the
argv and envp pointers and strings. The runtime builtin `user_replace`
finds the caller's slot, marks it done and runs the death's reaps
(image hook, stack and arena, grown rows), empties the mailbox, dresses
the slot with the new stack and arena, builds the synthetic frame at
the new stack's bottom, calls the space build hook to consume the
staged record and install the new root, and queues the same pid. The
caller was parked in gate-wait; the service answers nothing.

The C library's `execve` copies the path (no path layer — the volume's
flat name), flattens `argv[1..]` and `envp` into the space-separated
wire texts (a word carrying a space is EINVAL; too long E2BIG), and
never returns on success. `argv[0]` is the name the kernel starts; the
envp is the caller's. `execv` passes `environ`.

The metal proof: `chello.elf` (30,752 bytes, one image block) forked a
child, the child execve'd the same file with argv `execchild <pid>`
and env `EMO_EXEC=1`; the new image checked `getpid()` against the
argv's pid and the env, answered `execve child ok` and exited 0; the
parent's `waitpid` answered `execve ok`. All earlier beats stayed
green and the machine's exit route was clean.

Gaps: the library's fd table and cwd start fresh in the new image and
the old handles are dropped (`fs.drop_pid`) — execution does not
preserve descriptors yet; the old page table and the private page leak
(the page tables' rule for the first, the exec's documented 4 KiB for
the second), an old arena pinned by queued messages is not freed, and
a message in the old mailbox is dropped without unpinning its sender.
The environment's wire text cannot carry a space inside a value.

### T1.5's record (2026-11-23)

The pipes are the process service's second arm, on their own six
pages (`.emo_pipe` at 0x87010000): the binding map (one byte per pid
and fd — 0 no pipe, 0x10|id a read end, 0x20|id a write end), the
per-pid request records the gate stages (op, fd, the second fd, the
buffer, the length, the caller's space word), and eight 1024-byte pipe
blocks (the two ends' counts, the ring's cursors, four parked readers,
four parked writers, 768 bytes of ring). The verbs are 55..60: the
bind, the read, the probe, the write, the dup and the close. The bind
and the probe answer inside the gate; the other four route to the
process service (ops 40..44, the family's `-(1000 + op)`), because
every one of them can wake a parked peer and only a service's context
may reply. The service is the one thread that mutates the tables — the
gate only stages — so no two clients touch a count at once.

A read of an empty ring parks its caller in gate-wait when a writer
still holds the end, and answers 0 when none does; a write past the
ring's room parks the writer, answers what the room took (POSIX's
partial write), and answers the broken pipe once no reader is left.
Every served request pumps the pipe's parked ends in bounded rounds,
because a read frees a writer's room and a write fills a reader's
ring. The counts follow the holders: `fork` copies every end to the
child's pid (one more holder, so the parent's close is not yet the
child's EOF), `execve` drops the fds 3..15 (the new image's fresh
library table cannot name them) and keeps 0..2 (a pipeline's
redirection), and the normal exit walks every end home. `dup2` moves
a pipe binding through the kernel; a file's name, flags and offset
through the library's own table; a console stream's number bestows
the console. `lseek`/`fstat` on a pipe answer `ESPIPE`/a zero size.

The library caches each descriptor's kind (0 unknown, console in/out,
file, pipe read/write, closed) and asks verb 57 once per fd when the
byte is unknown — so an exec'd image's first read or write of fd 0..2
finds the pipe its predecessor left.

Found on the way: the fork's child stack is mapped at its physical
identity for the trap anchor, and the parent's virtual arena range
(its run and the grown blocks past it, at the parent's addresses) can
cover the block the freelist would hand out — one page, two
translations, `space.map_page`'s loud end. The fix is `frames.take_outside`:
the child's stack is taken from outside the parent's virtual range.

The metal proof: `chello.elf` (40,208 bytes, one image block) answered
`pipe ok` (the child's line through the ring and the parent's EOF at
the last writer's close), `pipe dup ok` (the pipe's write end onto
fd 1, the console saved by `dup` and restored by `dup2`), `pipe exec
ok` (the child's fd 1 into a pipe, then `execve` — the low end
survives and the new image's `write(1)` lands in the ring),
`pipe big ok` (2,000 bytes past the 768-byte ring, both ends blocking
and keeping the stream's order) and `pipe epipe ok` (the last
reader's close is the writer's EPIPE), after every earlier beat. The
machine's exit route was clean.

Gaps: a process that dies by fault or by the heap's kill leaks its
pipe ends — the fault path runs inside the trap and cannot wake a
parked peer (its reply would set SIE mid-trap), so the drop waits for
T1.6's signals, which will own the death path's wake. A pipe keeps
eight blocks and four waiters an end; a fifth parked reader or writer
is the service's loud end. The `pipe`/`dup`/`dup2` ends are not
inherited as shared descriptions — the library's fd table owns them,
and a file descriptor's offset still diverges after `fork` (T1.4b3a's
approximation, unchanged).

### T1.6's record (2026-11-23)

The signals are the gate's own, on their own pages (`.emo_sig` at
0x87018000): one pending and one blocked word a pid, one disposition
word a pid and signal slot (0 default, 1 ignored, an address a
handler), one mark and one saved frame a process slot, and the two
cells the trap shim stages at every ecall (the frame's base and the
slot's index). The vocabulary is eight — SIGINT 2, SIGQUIT 3, SIGKILL
9, SIGUSR1 10, SIGSEGV 11, SIGPIPE 13, SIGTERM 15, SIGCHLD 17 — and
the mask's bits are the signal numbers themselves (bit 2 is SIGINT).
The verbs: 61 `kill(pid, sig)` (a process, a group, the caller's own
group; the authority the caller's body, its child, or a group it
carries; signal 0 the probe), 62 `sig_action(sig, disp)` (SIGKILL
refused; a handler must sit in one of the caller's executable
segments, the fork entry's check), 63 `sig_mask(how, set)` (block,
unblock, replace; SIGKILL's bit and the outsiders dropped), 64
`sig_return()`, 65 `sig_pending()`.

Delivery is the resume's: `emo_os_trap_resume` asks
`emo_os_sig_deliver` on every return into U-mode, before the anchor is
armed. The lowest unmasked signal whose disposition is a handler
copies the interrupted frame and its sp slot to the slot's record,
masks every signal, and rewrites the frame — `ra` to the trampoline
page at 0x87ffd000 (every user table maps it RX with U), `a0` to the
signal, `sepc` to the handler. The handler runs on the interrupted
stack and returns to the trampoline's `li a7, 64; ecall`; the gate's
verb 64 puts the saved frame and mask back and answers the shim's
special -105, which resumes the frame as it stands — no answer into
a0, no sepc bump. The trampoline's third word is an `ebreak`, the
loud end of a return no handler entered. A default disposition ends
the process: the shim's death path writes the signal as the exit's
status, posts the exit to the process service (the record, the
waiter, the parent's event, the pipe ends' walk), marks the slot done
and reaps it. SIGKILL's pending bit ignores the mask and a running
handler both — the machine's kill.

The status encoding moved to POSIX's: the gate's exit writes
`code << 8` into the per-pid cell, a signal death writes the signal's
number, the exit table and the wait answer the word whole, and the C
library returns it as the `wait` status (`WIFEXITED`/`WEXITSTATUS`/
`WIFSIGNALED`/`WTERMSIG`). The boot proof's `wait 7` shifts the code
out itself; the `syscall` package's comment says the status word and
its five locks re-pinned. A child's exit raises SIGCHLD for its
parent, and a broken pipe raises SIGPIPE beside the EPIPE answer. The
dispositions and the mask copy across `fork`; `execve` resets the
dispositions (their addresses belonged to the old image) and keeps the
mask.

Found on the way: the delivery's own call frames were written over the
frame it was about to resume — the typed defs' stack grew down from
`sp` into the anchor's words, and the corrupted sepc/frame hung the
machine silently. The hook now runs on its own 4 KiB stack
(`emo_os_sig_stack`), switching sp around the call. Also found: the
trampoline's instructions must be four bytes apart — the first write
stored each as a doubleword and the ebreak's neighbours read as
illegal instructions (`user fault ... cause 2 at 0x87ffd004`).

The metal proof: `chello.elf` (41,016 bytes, one image block) answered
`signal ok` (a SIGUSR1 handler run before the raise returned, SIGTERM
ignored, SIGKILL refused), `signal mask ok` (SIGUSR1 blocked, raised,
seen pending, delivered at the unblock), `signal kill ok` (a child's
default SIGTERM death read as `WIFSIGNALED`/`WTERMSIG`, the parent's
SIGCHLD handler run), and `pipe epipe ok` grew the blocked SIGPIPE's
pending check — after every earlier beat, `wait 7` included. The
machine's exit route was clean.

Gaps: a signal raised on a parked process waits for its park to
resolve — `kill` does not interrupt a blocked read (EINTR is the
follow-up), so a child asleep on the console is not reachable yet. A
handler runs with every signal masked: `sa_mask`, `sa_flags` and
nested handlers are the library's `sigaction` struct's to grow. The
vocabulary is eight — no SIGSTOP/SIGCONT/stop states, no job control
(T3's shell). The fault path still does not post a child's death to
the process service (the pre-existing gap the signal death's path does
not share).

### M2 — the C library (musl-derived)

- [x] **T2.1** — The syscall layer: musl's `arch/riscv64` stubs over
  the gate, one function per documented verb.
- [x] **T2.2** — `crt`, TLS, `malloc`, `stdio`, `string`, `errno`;
  static `hello`, `printf`, `malloc`, `getenv`.
- [x] **T2.3** — The sysroot and the compiler wrapper: `libc.a`, the
  headers, the link script; `riscv64-emoos-gcc`.
- [x] **T2.4** — The conformance probe: a small C suite pinning the
  calls the milestone carries, byte-identical on the metal and the
  host interpreter where both apply.

### T2.1's record (2026-11-24)

The C library's crossing is one file:
`c/musl-port/arch/riscv64/syscall_arch.h`, the musl 1.2.6
`arch/riscv64` stubs (MIT; the notice rides `c/musl-port/COPYRIGHT`) with the gate's verb in a7 and the six
words in a0..a5. `c/emo_syscall.c` carries the typed wrappers — one
per documented verb the library speaks (0..4, 6..9, 36..52, 54..65) —
and the generic `emo_syscall` entry; `c/emo_syscall.h` names the verb
numbers and the API. The desktop and notification families (10..35)
stay the Emo side's until a C program needs them, and verb 5 (the
allocator's death) stays the runtime's: the contract's "by need" cut.
`c/emo_posix.c` lost its last raw `emo_ecall` (the console read is
`emo_console_read`), so every gate call in the library crosses the one
stub file.

The metal proof: `chello.elf` (41,696 bytes) printed `syscall layer
ok` right after `rodata ok`, then every earlier T1 line through
`signal kill ok`; the machine exited clean. The C app builds in the
`@emo_os` scratch tree too (`c/emo_syscall.c` and the arch header ride
the file list), and the leg stayed green. The musl body — `crt`, TLS,
`malloc`, `stdio`, `string`, `errno` — is T2.2.

### T2.2's record (2026-11-24)

The musl body is in `projects/emo-os/c/musl-port/`. The port's crt
(`crt0.s`) takes the kernel's args page and stack, clears `.bss`, sets
`__environ`, and calls `__emo_tls_init`, `main`, `fflush(0)` and
`emo_exit`; `tls.c` puts one `struct pthread` in `.bss` with `tp`
above it (`TLS_ABOVE_TP`), `libc.threaded`/`need_locks` zeroed and an
empty `auxv`, so musl's `errno`, `__lockfile`'s tid and the locale
pointer have a block without a thread. `gate.c` is the gate side:
console `write`/`read`, `close`/`lseek` over the fd verbs, the arena's
`brk`/`__mmap`/`munmap`/`mprotect`/`madvise`/`mremap`, the lock
no-ops, and the `__syscall` seam the mallocng `glue.h` uses —
`SYS_brk` is the port's own number, so the kernel still sees only the
T2.1 verbs. `stdio.c` replaces musl's `writev`/`ioctl` writers with
the console `write` and makes the single-threaded locks no-ops.

The body itself is the vendored musl source: `mallocng` (over the
arena's `brk`/`mmap`), `printf`/`vfprintf`/`fflush`/`stdout`/`fwrite`
and the string, env, errno, locale and math pieces the link pulls.
`getenv`/`setenv`/`putenv`/`unsetenv` are musl's; the static hello
(`hello.c`) prints `hello from musl: musl body 42` and `getenv yes`.

The cuts: the crt/TLS are the port's static single-process block, not
musl's `__libc_start_main`/`__init_tls` (the kernel's start has no
auxv and no dynamic TLS); the user image lives past 2 GiB, where the
host libgcc's medlow quad objects cannot relocate, so `vfprintf`'s
quad helpers are stubs and `%f`/`%Lf` wait for a medany soft-float (the
integer and string formats are the proof); `munmap`/`madvise` are
no-ops and `mremap` copies, so a freed mapping leaks until a later
pass. The build is `c/musl-port/build.sh` (the manifest, not the whole
tree); `EMO_MUSL=1` makes `c/build.sh`/`start.sh` put the proof image in
the `chello.elf` slot, while the default stays the T1 program, and
`c/build.sh` rebuilds it after the proof.

The metal proof: `EMO_MUSL=1 start.sh --fresh`, then `exec chello.elf`,
printed `hello from musl: musl body 42` and `getenv yes`; the machine
exited clean and the proof image is 33,864 bytes.

### T2.3's record (2026-11-24)

`c/musl-port/build.sh` now leaves a sysroot: `sysroot/include` (musl's
headers, the arch and generic `bits`, the generated `alltypes.h` and
`syscall.h`), `sysroot/lib/libc.a` (the T2.2 body's objects, the gate
shims, the TLS and stdio pieces, and the T2.1 wrappers), `crt0.o`, and
`sysroot/lib/emo.ld` (the user image's link script, the C door's
`chello.ld`). `sysroot/bin/riscv64-emoos-gcc` is the template
`c/musl-port/riscv64-emoos-gcc.in`: `riscv64-elf-gcc` with
`-nostdinc -isystem <sysroot>/include`, `-nostdlib`, the link script,
the crt, `-lc` and `-lgcc`; `-c`/`-E`/`-S` skip the link pieces.
`-Wl,--gc-sections` drops the library's unused sections (the
`__towrite` exit hook would otherwise want `__stdio_exit`).

The static hello is built through the wrapper (`riscv64-emoos-gcc
hello.c -o muslhello.elf`) and still prints its two lines on the
metal; the proof image is 34,048 bytes. The sysroot and its archives
are generated and ignored; the template, the build script and the
tracker are the committed source. The wrapper's `-D_GNU_SOURCE` is the
default user surface; the T2.2 cuts (static single-process TLS, quad
stubs, `munmap`/`madvise` no-ops) stand. The conformance probe is T2.4.

### T2.4's record (2026-11-24)

The probe is `c/musl-port/conformance.c`: the same source compiled by
the host's `cc` and by the sysroot's `riscv64-emoos-gcc`. It pins the
milestone's portable surface — `printf`'s integer, string, width,
precision, flag and `long long` shapes; the `string` calls; `malloc`/
`realloc`/`free`'s alignment and copy; `getenv`/`setenv`/`unsetenv`;
and `errno` from a rejected `setenv`. The float formats stay out:
T2.2's quad helpers are stubs.

`c/musl-port/conformance.sh` runs the host leg, boots the metal leg
through `EMO_MUSL=1 EMO_PROG=conformance.c start.sh --fresh` and
`exec chello.elf`, strips the shell prompt and the boot's noise, and
diffs the marker-delimited outputs. The host leg is the host C
library, the C suite's reference — the Emo interpreter is not a C
runtime, so the "host interpreter" comparison is the host libc's; the
kernel's `parity_metal` is the Emo-interpreter twin. The outputs are
byte-identical (36 lines). The script rebuilds the T1 `chello.elf`
after the metal run.

Gaps: the probe carries no file/fd calls (the T1 C door's surface,
not the T2.2 body's), no `%f`/`%Lf` (the quad cut), and no
`pthread`/dynamic TLS (the single-threaded body).

### M3 — emosh as the default shell

- [x] **T3.1** — emosh builds against the sysroot. Every source edit
  forced by the port is listed; the goal is none.
- [x] **T3.2** — emosh becomes the boot foreground — the line
  editor, history and completion — replacing `hello/shell.emo` as
  the machine's shell.
- [x] **T3.3** — The console's handoff: the serial bytes on fd 0,
  writes on fd 1/2, `poweroff` as the exit route the boot still
  owns.
- [ ] **T3.4** — The desktop's `exec` hands `argv`/`envp` to the
  child; the launcher and the shell share one door.

### T3.1's record (2026-11-24)

The C target's compiler is `EMO_CC` now (the sysroot's
`riscv64-emoos-gcc`), and its objects carry function sections so the
cross link drops the runtime's unused POSIX surface. The build is
`EMO_CC=<sysroot>/bin/riscv64-emoos-gcc emo build main.emo --target c
-o emosh.elf`; the shell's Emo source needed no edits (the goal).

The sysroot's `libc.a` grew the T1 C door's gate layer under musl's
headers: fd/path/process/pipe/signal, `fork.s`, the T1 `open`/read/
write, and `posix_bridge.c` for musl's `DIR` over the T1 listing,
`execvp`, the termios/console pair, `calloc`/`exit`/`abort`,
`clock_gettime`, `fcntl`, and the compiler runtime's unused
network/ucontext surface stubbed. The T2.1 whole-file wrappers renamed
`emo_gate_file_*` (the compiler runtime owns `emo_file_*`), the errno
bridge points musl's `__errno_location`/`___errno_location` at the T1
global, and the musl stdio/stdlib/math pieces the link pulls
(`fprintf`, `snprintf`, `open_memstream`, `stderr`, `qsort`, ...) join
the archive. The archive is built fresh each run.

The shell links: 302,040 bytes, entry `0x87100000`, two `PT_LOAD`
segments in the image window. The T1 `chello.elf` still builds, and
the T2.4 conformance probe still answers host and metal byte-identical.
Gaps: the compiler runtime's Emo lightweight-process/ucontext and its
network methods are stubs on EmoOS (the shell uses the OS `fork`/
`exec`); the shell's boot foreground and console are T3.2/T3.3.

### T3.2's record (2026-11-24)

`EMO_SHELL=1` builds the shell's C image through the sysroot into
`emosh.elf`; `user.S` embeds it beside the C door's `chello.elf`, the
first boot installs it when the blob is not empty, and the root's shell
stage execs it in place through verb 54 — the door the C library's
`execve` rides. `EMO_SHELL=0` writes the zero-length placeholder, the
kernel skips the install, and the existing desktop golden keeps
`hello/shell.emo`.

Two fixes the metal run forced. Verb 54 refused the boot root with
`bad argument` because its `img_for` cell is zero: the root carries the
boot image, not an exec record, and the replace's reap reads exactly
that cell as a no-op before the new image's build writes the fresh
record — the record's presence is not the door's condition, so the
check is gone. The C runtime's root fiber never ran because EmoOS's
ucontext is the T3.1 stub: `swapcontext` answered ENOSYS and the
scheduler deadlocked with the root unfinished. The scheduler now runs
the root entry on the C entry's own stack when the switch fails; the
shell's jobs are OS processes, not fibers.

The metal boot: `emosh>` after `desk 0`, `echo hi` answers `hi`, `pwd`
answers `/`, the up-arrow replays the last line, Tab completes `ec` to
`echo`, and `exit` leaves through the kernel's exit route (the
DMA/frame account). The shell is `projects/emo-shell` compiled to C; no
shell source edit was needed for the boot. `ls` is not a builtin (the
builtins are cd/pwd/echo/exit/export/unset/true/false) — the M4 corpus
brings the utilities. Gaps: the console's ownership is T3.3; the
desktop's argv/envp is T3.4.

### T3.3's record (2026-11-24)

The console is the C door's three streams: fd 0 reads the serial byte
one at a time (`emo_console_read`, the T1 gate's read verb), fd 1 and
fd 2 write the console (`emo_write`), and the shell's prompt, error
lines and command output ride them — `echo hi`/`pwd` on fd 1, the
prompt and `poweroff`'s refusal on fd 2. The shell's `poweroff`
builtin joins the roster and stops the session with status 0; the
root's exit verb (pid 1, verb 0) is the boot's own route —
`route_poweroff`, the DMA/frame account, then the SBI poweroff. `exit`
reaches the same route.

The metal run typed `poweroff now` (the fd 2 refusal) and `poweroff`
(the machine's end): the kernel's account printed and QEMU exited on
the SBI call, no host signal. The console's handoff is the root's own
exec: the same pid keeps its three streams across `execve`, so the
prompt after `desk 0` is the serial the desktop's ride left.

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
