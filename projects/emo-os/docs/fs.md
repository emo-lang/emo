# The filesystem service — authoritative and rebuildable state

How EmoOS keeps files: the service that owns the disk's layout, the
line it draws between the state the disk holds and the state it keeps
in memory, what a crash of the service costs and how the kernel brings
it back, and the verbs a user program sees. Fixed as of T7.2
(2026-10-30). The block driver underneath is T7.1's; the shell above
is T7.3's.

Chinese translation: [`fs.zh-CN.md`](fs.zh-CN.md).

## The split

The kickoff decided that a kernel service is restarted when it dies,
and that a service can only be restarted if it keeps two kinds of
state apart: the **authoritative** state, which exists in exactly one
place and whose loss is the loss of the thing itself, and the
**rebuildable** state, which is derived from the authoritative state
and can be thrown away and derived again. The filesystem is the first
service with authoritative state, so it is where the split is drawn
for real.

- **Authoritative — the disk.** The superblock in sector 0, with the
  mount table in it; the name table; the data sectors. Nothing else is
  authoritative. A fact about a file that the disk does not hold does
  not exist.
- **Rebuildable — the service's memory.** The copy of the superblock,
  the copy of the name table, the free map, the request bookkeeping.
  A fresh instance of the service derives all of it from the disk in
  its first milliseconds and trusts nothing it finds in memory.

The rule that keeps the split honest is **write-through**: every
change goes to the disk inside the request that makes it, before the
request is answered. An answered write is on the disk; the service's
memory never holds a change the disk does not yet hold. There is no
write-back cache and no flush verb, because there is nothing to
flush.

The free map is the one piece of state that is kept in memory and
never written to the disk, and that is deliberate: the map is a
function of the name table (every sector a file's extent covers is
used, every other data sector is free), so a copy on the disk would be
a second authority that could disagree with the first. The map is
rebuilt from the name table at every mount.

## The disk

The disk is the block device the driver found (T7.1): 512-byte
sectors, 2048 of them on the 1 MiB image `run.sh` creates. The layout
is fixed by sector number:

| Sectors | Contents |
| --- | --- |
| 0 | the superblock |
| 1–8 | the name table: 64 entries of 64 bytes, eight per sector |
| 9–2047 | the data region |

**The superblock** (sector 0), as 64-bit little-endian words:

| Offset | Contents |
| --- | --- |
| 0 | the magic, `EmoFS-01` as eight bytes read in order |
| 8 | the generation: incremented and written back at every mount |
| 16 | the disk's size in sectors, as the driver reported it at the format |
| 24 | the number of mount entries |
| 32 | the mount table: entries of 64 bytes |

**The mount table** is the list of volumes the service serves — for
each, where its name table and its data region lie. One entry today:
the volume the disk itself is, named `root`, its name table at
sectors 1–8, its data region at 9 to the end. The table is on the disk
and nowhere else, which is what makes it durable: a fresh instance of
the service, whether after a crash or after a power cycle, reads
sector 0 and knows what it serves without being told. The entry
carries no device field because there is one device; a second disk is
the entry that would add it.

| Entry offset | Contents |
| --- | --- |
| 0 | the volume's name, 16 bytes, NUL-padded |
| 16 | the name table's first sector |
| 24 | the name table's sector count |
| 32 | the data region's first sector |
| 40 | the data region's sector count |

**A name-table entry** (64 bytes):

| Offset | Contents |
| --- | --- |
| 0 | the file's name, up to 24 bytes, NUL-padded; a NUL first byte is a free entry |
| 24 | the size in bytes |
| 32 | the extent's first sector |
| 40 | the extent's sector count |
| 48 | the generation of the mount that wrote it |
| 56 | reserved, zero |

A file is one contiguous extent of sectors. The namespace is flat:
there are no directories, because nothing above the service asks for
them yet — the shell (T7.3) lists and names files, and a flat volume
is what it needs.

**The format.** A disk whose sector 0 carries no magic is blank, and
the service's first mount formats it: the eight name-table sectors
written zero, then the superblock written with generation 1 and the
one mount entry. The format is the mount's own act, not a separate
tool, so a blank image boots to a working filesystem; a disk that
carries the magic is never formatted, whatever else is on it.

## The operations and their commit points

Every operation is one request, and a request is one transaction:
the service holds no handle on a client's behalf between requests, so
a client has nothing to re-open after a restart. Four operations:

- **write** a whole file: the name and the bytes; an existing name is
  replaced.
- **read** a whole file: the name; the bytes land in the caller's
  buffer.
- **list** the names, one per line.
- **remove** a file.

A write is where the disk changes, and its order is the crash
semantics:

1. The extent is allocated from the free map in memory — a
   first-fit run of as many sectors as the bytes need. No run: the
   write is refused (reason 5), the disk untouched.
2. The bytes go to the new sectors, one sector per request to the
   driver; the last sector's tail is written zero.
3. The name-table entry is written — name, size, extent, generation —
   in memory first, then its sector to the disk. **This single-sector
   write is the commit point.**
4. If the name existed, its old extent is freed in the memory map.

A crash before step 3 leaves the old entry intact: the file is what it
was, and the new sectors are referenced by nothing — the next mount's
rebuild of the free map finds them free again. A crash after step 3
leaves the new file: step 4 touched only memory, which the rebuild
derives correctly. There is no state in which the disk refers to
bytes that were not written, because the bytes are written before
the entry that names them.

The remove's commit point is the same entry write, with the entry
cleared; the read and the list change nothing.

What the ordering assumes is that **a 512-byte sector write is
atomic**: the device writes the whole sector or none of it. That is
the block device's contract as the driver speaks it, and the one
assumption the crash semantics rest on; a torn sector is outside the
design.

## The restart

### What a death is

A kernel service runs in S-mode on the kernel's own table, so the
isolation a process boundary buys for it is narrower than a user
pass's: **a fault in a kernel service is the kernel's fault**. An
illegal access in the filesystem's code is a kernel bug, and the
machine ends loudly with it, as it does for any supervisor trap
(T4.6). The deaths a kernel service dies alone are two:

- **The arena kill.** The kernel has no garbage collector and every
  message the service sends or receives allocates in its 64 KiB
  arena, so a long-lived service exhausts it — the kill T5.1 confines
  (`heap gone in process N`). The restart is what turns that from a
  lifetime limit into a maintenance event: the instance dies, a fresh
  one with a fresh arena rebuilds from the disk, and the files are
  exactly what they were, because the disk is the authority.
- **The stop.** A service that returns from its loop ends as any
  process does. The filesystem returns when a kernel-side client asks
  it to (the operation below), which is how the restart is driven on
  purpose.

Both deaths meet the same mechanism.

### The notice

The runtime gained a **death hook**, the console and block hooks'
pattern: a word (`emo_death_hook`) that is zero in every image whose
stub leaves it, and that the kernel's boot stub parks at a trap-shim
routine. The runtime calls it with the dead process's pid at the two
places a green process ends — the entry thunk's return and the arena
kill — after the slot is marked done and before the reclamation. The
routine posts a raw word to the supervisor's mailbox the way the gate
posts a request (`emo_gate_post`, no allocation, inside the masked
region): `256 << 32 | pid`, an op no gate verb reaches. A kernel
whose supervisor cell is zero gets no notices; a user pass's death
takes the shim's own routes and the process service's exit table, as
before.

### The supervisor

The **supervisor** is a kernel process the root spawns once, and the
filesystem service's owner:

- It takes the service's **cache block** — the one 64 KiB block the
  service's memory lives in (the superblock copy, the name table copy,
  the free map, the sector staging) — from the frame allocator once,
  and hands the same block to every instance. The block outlives the
  instances; each one overwrites it from the disk and trusts nothing
  it held.
- It spawns the service, receives the announce (the instance's pid),
  parks the raw number in the filesystem's pid cell the gate routes
  by, and forwards the Pid to the root.
- On a death notice naming the current instance, it first answers
  every client the dead instance left parked: the request slots on the
  filesystem's pages (below) say who is waiting, and each one is
  refused with reason 5 — the kernel ran out of the resource, which is
  what happened — and the slots and the stash are cleared. Then it
  spawns the next instance and parks its pid as before. A client
  whose request was in flight at the crash gets a refusal, not a
  hang, and the next request it makes finds the new instance; a
  request that arrives during the gap between one instance's death
  and the next one's start is not refused at all — the gate sets it
  aside in the same stash and the shim parks the caller without
  posting, so the next instance serves it first (a client that
  retried across the gap instead would spin on refusals, and a
  cooperative kernel has nothing to take the processor back with).

The supervisor itself allocates almost nothing per notice and is not
supervised; its death would be the kernel's bug.

### The mount

Every instance begins the same way, whether it is the first after
power-on or the fifth after a crash: it reads sector 0 through the
driver; a missing magic is the format; the generation is incremented
and the superblock written back — so the superblock write path runs
at every mount and the generation on the wire counts the instances the
disk has seen; the eight name-table sectors are read into the block;
the free map is rebuilt from them; the mount line is printed
(`fs gen <generation> files <count>`, after `fs formatted` when the
mount formatted); the announce goes to the supervisor; the loop
begins. The instance's memory is a function of the disk, computed at
the start, and of the requests since — nothing of the previous
instance survives into it.

## The gate

The verbs, continuing `docs/syscalls.md`'s table — every pointer
argument under the gate's checks, the name and the bytes copied in at
the gate (the write verb's discipline, T6.2):

| Verb | Spelling | Answer |
| --- | --- | --- |
| 6 | `file_write(name, name_len, buf, len)` | the file named by the `name_len` bytes at `name` becomes the `len` bytes at `buf`; answers `len` |
| 7 | `file_read(name, name_len, buf, cap)` | the file's bytes land at `buf`, at most `cap` of them; answers the file's size |
| 8 | `file_list(buf, cap)` | the names, each followed by a newline, land at `buf`; answers the bytes written — a name that would not fit is left out with everything after it |
| 9 | `file_remove(name, name_len)` | the file is gone; answers 0 |

A name is 1 to 24 bytes and carries no NUL and no newline (reason 4
otherwise); a write is at most 2048 bytes (reason 4); a name no entry
holds is **reason 6, no such file** — a reason the table did not have
and the `syscall` package names (`"no such file"`); a full name table
or a data region with no run long enough is reason 5.

**The request slots.** The filesystem is the first service whose
transaction waits on another process — the driver's reply — and a
request that arrives while it waits must not be mistaken for that
reply. The gate copies each request's arguments into one of **four
request slots** on the filesystem's fixed pages (the name, the
lengths, the caller's buffer address, the bytes), marks the slot busy,
and puts the slot's index into the route (`-(1000 + op + 16 × slot)`,
so the request word the service decodes is `(slot << 36 | op << 32 |
pid)`); a slot is free again when the service has answered its
request. Four callers can be parked on the filesystem at once; a fifth
is refused with reason 5 before anything is copied. While the service
waits for the driver, a request it receives instead goes to a
**stash** of raw words on the same pages, and is served in order after
the transaction — the mailbox and the stash together are one FIFO.

The service's own answers follow the gate's convention: the write
answers from the gate's copy, and the read and the list write into
the caller's buffer through the supervisor's low window (the kernel's
own table maps the RAM at identity, the alias the gate's answers into
parked frames already ride) — the range was checked at the gate, and
the caller is parked while the bytes land.

**The kernel side.** A kernel process reaches the service without the
gate: a six-tuple message `(op, from, name, name_len, buf, len)` with
the addresses kernel ones, answered by a message to `from`. The same
ops, and one more: **op 0 is the stop** — the service returns, which
is a death the supervisor restarts. The root uses it once at boot, to
drive the restart the chain pins. A kernel client sends one request at
a time and waits for its answer; one parked across a crash would wait
forever (the root never is).

## The block driver's part

The driver's protocol grew for a client that is not the root. A
request is a tuple `(op << 32 | sector, from, word)`: the op is 1 or 2
for T7.1's word in and out of a sector, and **3 or 4** for a whole
sector written from or read into a buffer whose kernel address is
`word` — the device sees its physical address, and the buffer must be
one contiguous piece of RAM, which the service's cache block is
(T6.5's discipline). The reply goes to `from`: the word for ops 1 and
2, the sector number echoed for 3 and 4 — the echo is what the service
checks, so a message that is not the reply ends loudly instead of
being taken for one. The completion wait stays polled, bounded as
T7.1 left it; nothing in this task demanded the interrupt-driven
wait.

## Bounds

- One disk, one volume, a flat namespace, whole-file operations; 64
  files of up to 24-byte names; 2048 bytes per write; a file is one
  contiguous extent.
- Durability is the device's completion: there is no flush verb and
  the driver issues no flush, so a host that caches the image is the
  host's business.
- The sector write is assumed atomic (above).
- The driver is not supervised: its arena is its bound (hundreds of
  requests per boot), and restarting it needs what a restarted
  service's clients lack today — a way to reach a service by a number
  rather than a Pid value. That is the next piece when a session
  outlives the driver's arena.
- A client's request in flight at a crash is refused, never replayed:
  the service cannot know how far a write got, and the disk is
  consistent either way.
- The supervisor answers parked gate clients, not parked kernel
  clients.

## The pins

`run.sh` zeroes the image before the first boot, so the two legs are
one story: the legacy boot formats the disk and the sstc boot finds
it. On every boot the chain carries the mount line, then the root's
kernel-side proof — a file written through the first instance, the
stop, the mount line of the instance the supervisor restarted (the
generation one higher, the file counted), the file read back through
it, `fs restart ok` — and then, in U-mode, hello's proof through the
gate: a 600-byte file written and read back byte for byte (`fs rw
ok`), a second file written and removed, the list naming two
(`fs ls 2`). The second leg's first mount line counts the two files
the first leg left, and `fs formatted` is absent from it.

## The fixed addresses

The filesystem's pages (`.emo_fs`, three pages from `0x87005000`),
addressed by the kernel's constants:

| Address | Contents |
| --- | --- |
| `0x87005000` | the filesystem service's pid (the gate routes by it) |
| `0x87005008` | the supervisor's pid (the death hook posts to it) |
| `0x87005010` | the stash's count |
| `0x87005018` | the stash: four request words |
| `0x87005100` | request slot 0; slots are 2304 bytes apart |

A request slot:

| Offset | Contents |
| --- | --- |
| 0 | busy |
| 8 | the caller's pid |
| 16 | the name's length |
| 24 | the write's length, or the read's and the list's capacity |
| 32 | the caller's buffer, for the read and the list |
| 64 | the name, 32 bytes |
| 256 | the write's bytes, 2048 bytes |
