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
| 5 | the kernel is out of a resource (`spawn` with no free block left for the new process's stack and arena; a filesystem verb with no request slot free, or no name-table entry or data run left) |
| 6 | no such file (the filesystem verbs, T7.2) |

A refusal is an answer, not a fault: the caller's registers are intact
and execution resumes after the `ecall`. What a program does with a
refusal is the program's business; the gate's business is that nothing
undocumented ever acts.

## The verbs

| Verb | Spelling | Answer |
| --- | --- | --- |
| 0 | `exit(code)` | never returns — the root's exit ends the machine (the SBI poweroff); a spawned process's exit answers its parent's `wait` |
| 1 | `write(buf, len)` | the `len` bytes at `buf` ride the kernel's console; answers `len` — `len` beyond the gate's staging capacity (2048 bytes) is reason 4 |
| 2 | `read()` | the next input byte, blocking until one exists; answers it (0–255) — the input service's (T8.3), the serial console's bytes |
| 3 | `spawn()` | a new process enters this image's top level on a fresh stack; answers the child's pid number |
| 4 | `wait(pid)` | the exit code of the child with that pid number, blocking until it exits |
| 5 | *(the allocator's)* | never returns for the caller — the arena exhaustion report |
| 6 | `file_write(name, name_len, buf, len)` | the file named by the `name_len` bytes at `name` becomes the `len` bytes at `buf` (at most 2048); answers `len` |
| 7 | `file_read(name, name_len, buf, cap)` | the file's bytes land at `buf`, at most `cap` of them; answers the file's size |
| 8 | `file_list(buf, cap)` | the names, each followed by a newline, land at `buf`; answers the bytes written |
| 9 | `file_remove(name, name_len)` | the file is gone; answers 0 |
| 10 | `present(grant, x, y, w, h)` | the buffer the grant names lands whole — the damage rect is what the device takes and what the scanout shows; answers 0 when the commit completed (T8.4, below) |
| 11 | `output_info(index)` | the index-th output's rectangle, packed; an index no output answers is reason 4 (T8.4, below) |
| 12 | `input_read()` | the next event of the machine's merged input stream, blocking until one exists; answers it packed (T8.3, below) |
| 13 | `win_new(w, h)` | a window buffer of the given size: a contiguous run of the allocator's blocks mapped into the caller's own table; answers the buffer's frame number and the grant id packed (T8.5, below) |
| 14 | `win_close(grant)` | the buffer's release: the run back to the allocator, the grant gone; answers 0 (T8.5, below) |

Verbs 10 to 16 are **reserved for the desktop segment** (the gate's
numbering rule holds: reserved numbers carry no meaning until their
verb lands, frozen from that day) — `present`, `output_info`,
`input_read`, `win_new`, `win_close`, `win_focus`, `win_move`, per
[`docs/desktop-abi.md`](desktop-abi.md). Verbs 10 to 14 have landed
(T8.3, T8.4, T8.5); 15 and 16 — `win_focus` and `win_move`, the
compositor's stack's verbs — stay reserved until the compositor's
mechanism (T8.6) gives them their substance.

Verbs 6 to 9 (T7.2) are the filesystem service's; the format, the
name rules (1 to 24 bytes, no NUL, no newline — reason 4 otherwise),
and the service's own state discipline are
[`docs/fs.md`](fs.md). Every pointer argument among them is checked
like `write`'s buffer and copied at the gate: the name and the write's
bytes land in one of four request slots on the filesystem's pages
inside the trap that checked them (a fifth caller while four are
parked is reason 5), and the slot's index rides the route, so the
service's request word names it (`slot << 36 | op << 32 | pid`). The
read's and the list's bytes land in the caller's buffer through the
supervisor's low window while the caller is parked.

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
(1 to the console service, 2 and 12 to the input service, 10, 11, 13
and 14 to the display service, 0, 3 and 4
to the process service, 6 to 9 to the filesystem service)
ride the gate's routing — the request reaches its service, the caller
parks, and the service's answer lands in the parked frame as if
the `ecall` had answered directly. The exit is the routing's one
exception: its transaction is the caller's own death, so the caller's
slot ends done instead of parked — a send to the exited pid drops, and
the exit table's entry is the only thing left of the process.
(The language's `halt` builtin is
the kernel profile's own shutdown ecall — on a user image it reaches
the gate as verb 8 — the filesystem's list since T7.2, which it
reaches with a zero buffer and a zero capacity, refused as a range
the caller's memory does not cover.)

Verbs 10 and 11 (T8.4) are the display's, and the authorization
table's first entry rides them. **Verb 10, `present(grant, x, y, w,
h)`**, commits the buffer the grant names: the damage rect is what
the device transfers and what the scanout shows, the transfer and the
flush both completing before the answer — a frame lands whole, or the
machine ends loudly, and the scanout shows the old frame until the
flush's own completion. The grant id 0 is the screen carve's — the
authorization table's first entry, the holder's pid the process
service parked the moment it handed the carve out; a caller that is
not the holder is reason 3 (the slots are never reused, so a dead
holder's pid can never match a new caller). A grant id the table does
not hold is reason 4 — the window grants are T8.5's. An empty rect,
or one outside the display, is reason 4: the sanity is the gate's,
the bounds the display service's to judge against the mode.
**Verb 11, `output_info(index)`**, is the outputs list's verb — the
protocol's second seam: the list is not a constant, and the index is
the enumeration's shape. The answer packs the output's rectangle (the
width in bits 32..63, the height in bits 0..31); an index no output
answers is reason 4. One display is the first answer, not the only
shape.

Verbs 13 and 14 (T8.5) are the window buffer's lifecycle. **Verb 13,
`win_new(w, h)`**, hands the caller its own display memory: a
contiguous run of the allocator's blocks (`frames.take_run` — the
run's base is block-aligned and its blocks consecutive, the range a
device and a compositor can name), mapped into the **caller's own
table** at the identity of the run's physical addresses, RW with U —
the mapping into a table a `satp` already names is the live-table's
own act, the new entries whole words and the `sfence` (the raw family's
address-translation fence, `docs/raw-memory.md`) after them. The
grant — the row the kernel's authorization table gains (id, owner,
base, extent) — is the capability the buffer is named by ever after:
`present` and `win_close` take the id, never an address. The answer
packs the buffer's frame number (the byte address this program paints,
shifted left by 12 at the client — the frame number keeps the word's
sign bit true) above the grant id. A size past a window's bound (four
megapixels) is reason 4; a run or a table row the machine cannot back
is reason 5. **Verb 14, `win_close(grant)`**, is the release: the run
back to the allocator block by block, the row to the table. The gate
checks the caller against the row's owner (reason 3) and the id
against the table (reason 4) before anything moves. A window whose
owner dies without a close leaks its run until the compositor's
reclamation (T8.6) — the stated bound, M9's killed-and-restarted
acceptance is where the death-side reclamation earns its place. A
window's `present` (verb 10, the grant id nonzero) is checked against
the row — the owner and the damage rect within the buffer's extent —
and commits by the row's ready flag and the recorded rect, the
compositor's tick (T8.6) being the reader.

Verb 12 (T8.3, `input_read`) is the machine's input beyond the serial:
the next event of the input service's merged stream, blocking until
one exists. The answer packs the event into one word — the type in
bits 48..63, the code in bits 32..47, the value in bits 0..31 — the
virtio-input device's own event types riding verbatim (0 the
separator, 1 a key, 2 a relative move, 3 an absolute one) and one
machine type beside them: 0x454D ("EM") is the serial console's byte,
the byte in the value, the code 0. The stream merges the device's
events with the serial's bytes in the one order the two sources can
name without a clock — the bytes first, then the device's — and the
machine's standing discipline holds: one reader at a time (the
service's mailbox is the wait queue; a read parks the caller and the
service until the stream has something). The device half is wired:
the eventq's completion rides the PLIC (the input service's driver
parks its transport's IRQ number in the shim's cell), so the device's
events wake the machine the serial's bytes do; an event the sixteen
pre-posted buffers cannot hold at the moment it fires is the one
event the service loses.

## The user surface

User code does not spell the raw ecall. The `syscall` package — its
own package, distinct from the hosted `os` — is the gate's user side: the
typed Emo surface, and the only thing user code sees of the boundary.
It admits the `riscv64` target alone; the raw `ecall` lives in its
fourteen
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
- `syscall.read()` — the next input byte, blocking until one exists.
- `syscall.input_read()` — the next event of the merged input stream
  (T8.3, verb 12), blocking until one exists; the packed word the
  verb's section above describes.
- `syscall.present(grant, x, y, w, h)` — the desktop segment's commit
  (T8.4, verb 10), answering `(R.ok, 0)` or `(R.error, why)`.
- `syscall.output_info(index)` — the desktop segment's enumeration
  (T8.4, verb 11), answering `(R.ok, the packed rect)` or
  `(R.error, why)`.
- `syscall.win_new(w, h)` — the window buffer's creation (T8.5,
  verb 13), answering `(R.ok, the packed frame number and grant id)`
  or `(R.error, why)`.
- `syscall.win_close(grant)` — the window buffer's release (T8.5,
  verb 14), answering `(R.ok, 0)` or `(R.error, why)`.
- `syscall.spawn()` — a new process enters this image's top level on a
  fresh stack, answering `(R.ok, the child's pid number)`; the child
  knows it is the child by what the image's own memory holds (the
  spawned pass re-enters the program sharing the image), and the pair
  coordinates through raw cells or the console.
- `syscall.wait(pid)` — the exit of the child with that pid number,
  blocking until it happens, answering `(R.ok, the exit code)`.
- `syscall.file_write(name, name_len, buf, len)`,
  `syscall.file_read(name, name_len, buf, cap)`,
  `syscall.file_list(buf, cap)`, `syscall.file_remove(name, name_len)`
  — the filesystem verbs (T7.2), each answering `(R.ok, the answer)`
  or `(R.error, why)`; the reasons the earlier verbs name, plus
  `"no such file"` for reason 6. The names and the bytes are raw
  addresses in the program's own memory, like `write`'s buffer.

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

The filesystem's pages (T7.2, `.emo_fs`, three pages from
`0x87005000`) hold the service's pid cell the gate routes by, the
supervisor's pid cell the runtime's death notice posts to, the stash,
and the four request slots the gate fills; the layout is in
[`docs/fs.md`](fs.md).

The user window is `[0x87100000, 0x88000000)`; the user profile links
at its base.
