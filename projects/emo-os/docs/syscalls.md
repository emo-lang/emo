# The ecall gate — the user/kernel ABI

The contract between a user image and the EmoOS kernel: what crosses
the privilege boundary, how it is spelled in registers, and what the
supervisor checks before it acts. Fixed as of T4.2 (2026-10-27); the
verb set grows with the services, but the numbering, the marshaling,
and the answer convention do not move.

Chinese translation: [`syscalls.zh-CN.md`](syscalls.zh-CN.md).

## The crossing

A user program issues the machine's `ecall`. On the Emo side that is
the raw builtin `ecall(verb, r0, r1, r2, r3, r4, r5)` — `riscv64`
alone admits it, the rest of the raw-machine family's admission rule
(E4028 elsewhere) — which lowers to the instruction with the verb in
`a7` and the six words in `a0`..`a5`.

The trap lands in the kernel's shim, which marshals the verb and the
six words into the gate's dispatcher (`gate.dispatch`, ordinary typed
Emo running inside the trap on the caller's own stack — it allocates
nothing) and srets home with the answer in `a0`. Everything else about
the caller's register file round-trips untouched.

## The answer

One register, `a0`:

- **`a0 >= 0` — answered.** The payload: for `write`, the number of
  bytes taken.
- **`a0 < 0` — refused.** The reason is `-a0`:

| Reason | Meaning |
| --- | --- |
| 1 | the verb is not in the gate's set |
| 2 | a pointer argument lies outside the caller's memory |
| 3 | a pointer argument's memory does not carry the permission the access needs |
| 4 | a non-pointer argument is out of range |
| 5 | the kernel is out of a resource (`spawn` with no free block left for the new process's stack and arena) |

A refusal is an answer, not a fault: the caller's registers are intact
and execution resumes after the `ecall`. What a program does with a
refusal is the program's business; the gate's business is that nothing
undocumented ever acts.

## The verbs

| Verb | Spelling | Answer |
| --- | --- | --- |
| 0 | `exit(code)` | never returns — the root's exit ends the machine (the SBI poweroff); a spawned process's exit answers its parent's `wait` |
| 1 | `write(buf, len)` | the `len` bytes at `buf` ride the kernel's console; answers `len` — `len` beyond the gate's staging capacity (2048 bytes) is reason 4 |
| 2 | `read()` | the next console byte, blocking until one exists; answers it (0–255) |
| 3 | `spawn()` | a new process enters this image's top level on a fresh stack; answers the child's pid number |
| 4 | `wait(pid)` | the exit code of the child with that pid number, blocking until it exits |
| 5 | *(the allocator's)* | never returns for the caller — the arena exhaustion report |

Verb 5 (T5.1) is not a service request but the user image's allocator
speaking: when the running pass's own arena — the 64 KiB block the
kernel's spawn took from its frame allocator (T5.3) — is full, the user
image's `emo_alloc` says verb 5 instead of failing the machine. The gate
answers it with the caller's death: the loud report (`user heap <pid>
gone`) printed by the supervisor on the offender's own stack, the
slot ending done, and the machine continuing without the process —
the fault route's reclamation, reached through the gate instead of a
trap. Nothing stops a program from saying verb 5 of itself, and the
answer is the same: the program wanted out. The root riding verb 5
ends the machine, as its exit does.

Verb 0 never returns, so it has no returning handler to marshal: the
trap entry takes it before the dispatcher. The verbs the services own
(1 and 2 to the console service, 0, 3 and 4 to the process service)
ride the gate's routing — the request reaches its service, the caller
parks, and the service's answer lands in the parked frame as if
the `ecall` had answered directly. The exit is the routing's one
exception: its transaction is the caller's own death, so the caller's
slot ends done instead of parked — a send to the exited pid drops, and
the exit table's entry is the only thing left of the process.
(The language's `halt` builtin is
the kernel profile's own shutdown ecall — on a user image it reaches
the gate as verb 8 and is refused like any other verb not in the set.)

## The user surface

User code does not spell the raw ecall. The `syscall` package — its
own package, distinct from the hosted `os` — is the gate's user side: the
typed Emo surface, and the only thing user code sees of the boundary.
It admits the `riscv64` target alone; the raw `ecall` lives in its five
bodies and nowhere else a user program writes.

- `syscall.exit(code)` — the exit verb; never returns. The root's exit
  ends the machine; a spawned process's exit answers its parent's
  `wait`.
- `syscall.write(buf, len)` — the write verb, answering
  `(R.ok, the byte count)` or `(R.error, why)` by the error
  convention — the gate's refusal reasons as the message that names
  them (`"outside the caller's memory"`, `"not writable"`,
  `"bad argument"`, `"the kernel is out of a resource"`,
  `"unknown verb"`).
- `syscall.read()` — the next console byte, blocking until one exists.
- `syscall.spawn()` — a new process enters this image's top level on a
  fresh stack, answering `(R.ok, the child's pid number)`; the child
  knows it is the child by what the image's own memory holds (the
  spawned pass re-enters the program sharing the image), and the pair
  coordinates through raw cells or the console.
- `syscall.wait(pid)` — the exit of the child with that pid number,
  blocking until it happens, answering `(R.ok, the exit code)`.

Programs pin it like any package (`deps { "syscall" = "0.1.0" }`) and
resolve it from the bundled registry. The kernel profile refuses it
along with the rest of the standard library — the kernel builds on
`core` alone and never requires its own userland; the user profile is
an ordinary program, and the packages' own target declarations govern
what it may require.

## The supervisor checks

Every pointer argument is checked before the gate acts, against the
segment table the loader parked when it staged this image (each
`PT_LOAD`'s range and ELF `p_flags`): the whole range
`[buf, buf + len)` must lie inside **one** segment — a call that spans
segments is refused, not split — and that segment must carry the
permission the access needs (`write` needs `W`). The range check is
written overflow-safe (`len > end - buf`, never `buf + len > end`), a
zero length inside a writable segment answers 0, and the
range-versus-permission distinction is honest: a range that some
segment covers but no writable segment covers is reason 3, a range
nothing covers is reason 2. A write longer than the gate's staging
page carries (2048 bytes) is reason 4 before anything is copied.

Since SV39's per-process tables (T6.2) the check and the use are one
trap: the write's bytes are copied into the kernel's staging page by
the same trap that checked the range — the gate reads the caller's
memory exactly once, through the caller's own table with SUM — and the
console service prints from that copy on the kernel's own table, which
maps none of the caller's memory. Before the per-process tables the
service read the caller's buffer directly through the window's alias;
the copy-in at the gate is the honest form the tables make necessary
(and closes the read-after-check race the direct read carried).

The checks remain the supervisor's word on top of the mapping — a
refusal is an answer, not a fault — and the mapping is the hardware's:
since T6.2 a pass's own table maps its image's segments with U and
nothing else, so a wild pointer that slipped every check would still
be the hardware's page fault, not a landing.

## The fixed addresses

The kernel-side layout the loader and the gate share (the kernel's
`link.ld` gives the `.emo_user` section its page):

| Address | Contents |
| --- | --- |
| `0x87002000` | the embedded user image's start (the boot stub parks it) |
| `0x87002008` | its end |
| `0x87002010` | the staged entry (0 = nothing staged) |
| `0x87002018` | the segment count |
| `0x87002020` | the segment table: eight slots of (start, end, flags), 24 bytes each |

The frame allocator's page (T5.3, `.emo_frames`, a page above) is the
kernel's own — its freelist head, the free and total block counts, the
region's bounds, the take and give tallies, and the claimed bitmap —
written by `frames.emo` alone; the account the machine prints as its
last line (`frames <taken> <given>`) reads the two tallies.

| Address | Contents |
| --- | --- |
| `0x87003000` | the freelist head (a free block's base; 0 = the region is spent) |
| `0x87003008` | free blocks |
| `0x87003010` | blocks the region holds |
| `0x87003018` | the region's base (the image's end, rounded up to a block) |
| `0x87003020` | the region's end (`0x87000000`, the tick ring's page) |
| `0x87003028` | blocks taken so far |
| `0x87003030` | blocks given back so far |
| `0x87003040` | the claimed bitmap: one bit per block, eight words |

The user side of the page (T5.1) sits in the user profile's own cell
page at the top of RAM — three words the user stub parks and the
kernel's trap shim reads and writes at every U-mode boundary crossing,
so the user image's own allocator charges whichever pass is running:

| Address | Contents |
| --- | --- |
| `0x87fff000` | the user image's `emo_program` entry (the process service starts spawned passes here) |
| `0x87fff008` | the address of the user image's arena cursor (its root slot's word) |
| `0x87fff010` | the address of its arena end |

The user window is `[0x87100000, 0x88000000)`; the user profile links
at its base.
