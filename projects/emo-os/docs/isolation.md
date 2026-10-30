# The weak-isolation window

What U-mode could and could not reach while user programs and the
kernel shared one flat physical address space, and what closed it. The
window opened with the user profile (T4.1) and closed with SV39's
per-process tables (T6.2); this document is its standing record, so
the reach is a matter of account, not folklore. Fixed as of T4.5
(2026-10-27), updated for T6.1 (2026-10-29 — the window became a
mapping in the kernel's own table), closed as of T6.2 (2026-10-29 —
every user process runs on its own page table, and the window's
entries are gone), hardened as of T6.3 (2026-10-30 — the trap entry
no longer obeys the user's `sp` either). The kernel's address-space
layout is its own document: [`sv39.md`](sv39.md).

Chinese translation: [`isolation.zh-CN.md`](isolation.zh-CN.md).

## The route

Privilege first, address space later — the decided isolation route.
User programs enter U-mode behind the ecall gate a milestone before
paging exists, because the gate and what stands behind it — the
supervisor's argument checks, the copy semantics, per-process
accounting — are the permanent contract, and SV39 later moves their
enforcement into hardware without changing it. The window was the
price: between M3 and M5, isolation was effective, not enforced, and
the difference was written down here rather than hidden.

## The map

One flat map, every address physical. What QEMU `virt`'s 128 MiB of
RAM holds, and the MMIO beside it:

| Range | Contents |
| --- | --- |
| `0x80000000`–`0x80200000` | OpenSBI (M-mode) — the one region PMP locks |
| `0x80200000` | the kernel image — text, rodata, data, and the `.bss` holding the 96 MiB value heap (the root's arena), the 64 process slots, and the 64 × 64 KiB green-process stacks |
| the image's end–`0x87000000` | the frame allocator's region (T5.3) — the free RAM above the image, rounded up to a block, in 64 KiB blocks of sixteen 4 KiB frames: every spawned process's arena, every user process's stack, the kernel's and every process's page tables (T6.1/T6.2) |
| `0x87000000` | the tick ring (`.emo_tick`) |
| `0x87001000` | the input ring (`.emo_in`) |
| `0x87002000` | the user handoff page (`.emo_user`) — the embedded image's bounds, the staged entry, the segment table, the staged space cell (T6.2) |
| `0x87003000` | the frame allocator's page (`.emo_frames`) — the freelist head, the counts, the region's bounds, the claimed bitmap, the frame freelist |
| `0x87004000` | the Sv39 page (`.emo_sv39`) — the kernel's root table, the live `satp`, the switch's cache |
| `0x87100000`–`0x88000000` | the user window — every user image links at its base |
| `0x10000000`, `0x0c000000`, … | MMIO — the 16550A UART, the PLIC, the rest of `virt`'s devices |

While the window stood (T4.1–T6.1), the user reached every row of
this table at the physical address itself — untranslated before T6.1,
through the window's two U gigapage entries in the kernel's table
after it. Since T6.2 the kernel's table carries no U anywhere: the
kernel reaches its half and the supervisor's low window
(`0x80200000`–`0x88000000`, identity, no U — the loader's copies, the
handoff cells, the answers into parked trap frames), and every user
process reaches exactly what its own table maps
([`sv39.md`](sv39.md) — the image's segments with U, its own stack
and arena, the cells page, and the kernel's high half without U).

## What U-mode can reach

- **Its own pages, and nothing else.** The image's segments — code
  RX, data RW (the passes of one image share them: a spawned pass
  re-enters the top level and finds the tokens the parent poked) —
  its own 64 KiB stack and arena blocks, and the cells page. The
  kernel's half is mapped into the same table without U: present for
  the trap's sake, unreachable from U-mode — and the boot pass's trap
  page (`0x87ffe000`, T6.3) joins it on the same bargain, the one
  page of scratch that is nobody's execution memory. Every other
  address is a page fault the supervisor kills the pass for.
- **The raw family is admitted by target, not profile.** `peek`/`poke`,
  `ecall`, and `device_wait` are legal spellings in a user image, by
  the admission's own principle — a target admits the raw family iff
  the program owns the address space. Since T6.2 the admission is
  honest in both directions: the spellings reach only the pass's own
  pages (anything else is the page fault), and the vocabulary the
  kernel's own services use (`user_spawn`, `gate_reply`, `pid_num`)
  still refuses where the surface refuses it. The first user
  program's greeting rode the admission while the window stood — it
  poked the 16550A directly, and `run.sh` pinned the line. Since T6.2
  the pass's table maps no UART, and the greeting rides the gate with
  the same bytes on the wire.
- **The gate is the sanctioned door.** An `ecall` from U-mode always
  traps into the kernel's shim — never into OpenSBI — and the verbs
  ride it. What the gate refuses it refuses as an answer: the
  caller's registers round-trip and execution resumes. The write's
  bytes are copied into the kernel's staging page by the same trap
  that checked the range (T6.2) — the service reads the kernel's
  copy, never the caller's memory.

## What U-mode cannot reach

- **Anything its table does not map, and anything mapped without U.**
  The kernel's memory, the other processes' stacks and arenas, the
  allocator's page, the page tables themselves, the rings, the
  devices — each is a page fault (cause 12/13/15) or a permission
  refusal by the hardware, and the supervisor kills the offending
  pass loudly (`user fault <pid> cause <scause> at <epc>` — the
  kill golden's cause is now 13, the load page fault, where the
  window's RAM gigapage made the same access PMP's access fault,
  cause 5). A fault from the kernel's own code is still the loud
  failure that ends the machine — that is the kernel's bug, not a
  user's.
- **Privileged instructions.** Every S-mode CSR (`satp`, `sstatus`,
  `stvec`, `stimecmp`), `sfence.vma`, `sret` — an illegal instruction
  in U-mode, the same confined kill.
- **The firmware.** An `ecall` from U-mode is the kernel's door, not
  OpenSBI's; the firmware's own region is in no mapping at all (the
  supervisor's low window begins at the load address, T6.1's
  decision kept), and PMP stays behind everything as the range even
  S-mode is refused.
- **Anything the gate refuses.** A verb outside the set, a pointer
  outside the caller's segments, a segment without the permission the
  access needs — each is a numbered refusal answered back over the
  gate, not a fault and not a crash.

## What defends what

- **Instruction privilege** — the hardware's one line, and it holds
  absolutely: U-mode cannot elevate itself.
- **The per-process tables (T6.2)** — the window's closure: a wild
  address is a fault before it is a write, and the kill confines the
  process because the fault confined the access. The checks the gate
  makes are now backed by the mapping they describe.
- **The gate's supervisor checks.** Every pointer argument is bounded
  to one of the caller's own segments, carrying the permission the
  access needs, overflow-safe, all-or-nothing across segments (the
  contract in [`syscalls.md`](syscalls.md)) — and the bytes cross at
  the gate, copied in the checking trap, so no kernel process ever
  dereferences the caller's memory after the fact.
- **Copy semantics.** Messages are snapshots at send, charged to the
  sender: a corrupted process cannot alias another's objects through
  the mailbox.
- **Trap containment.** A user fault kills its process and nothing
  else; the kernel's own faults stay machine-wide, as they should.
  Since T6.3 the trap entry itself no longer obeys the user either:
  the trampoline frames every user trap at the pass's anchor — memory
  the kernel chose, not the pass's `sp` — so a pass cannot aim the
  kernel's frame stores by moving its stack pointer, and the dispatch
  runs on the kernel's own table and stack, past a `satp` swap the
  entry performs mid-transition (see the trampoline section of
  [`sv39.md`](sv39.md)).
- **Per-process accounting (Step 5)** — arenas, quotas, and the frame
  allocator: every allocation charges the running process's own arena,
  a runaway process exhausts its own arena alone, and every block a
  process holds — its arena, a user process's stack — is the kernel's
  frame allocator's, taken at the spawn and given back at the death.
- **PMP** — the firmware's region, the one range even the supervisor's
  window does not map.

## Why the window was accepted

Bounded in time and in kind, and now closed. In time: SV39 closed it,
one milestone away on a fixed roadmap, and the closure did not change
the contract the gate had been enforcing all along. In kind: the
defenses that mattered long-term were already the software contract —
a user program that stayed inside its own segments and worked through
the gate was, in effect, isolated from the first gate release, because
the gate checked what crossed and the copies kept processes from
aliasing each other. What the window left unenforced was exactly the
wild-address reach, and the per-process tables removed that class of
mistake without moving a verb or a reason code. The reach is on the
record for as long as it stood; nothing pretends otherwise.
