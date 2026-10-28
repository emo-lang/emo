# The weak-isolation window

What U-mode can and cannot reach before SV39 closes the window. The
window opens with the user profile (T4.1) and closes with SV39 (M5);
while it stands, user programs and the kernel share one flat physical
address space, and instruction privilege is the only line the hardware
draws between them. Fixed as of T4.5 (2026-10-27): this document is
the window's standing record, so the reach is a matter of account, not
folklore.

Chinese translation: [`isolation.zh-CN.md`](isolation.zh-CN.md).

## The route

Privilege first, address space later — the decided isolation route.
User programs enter U-mode behind the ecall gate a milestone before
paging exists, because the gate and what stands behind it — the
supervisor's argument checks, the copy semantics, per-process
accounting — are the permanent contract, and SV39 later moves their
enforcement into hardware without changing it. The window is the
price: between M3 and M5, isolation is effective, not enforced, and
the difference is written down here rather than hidden.

## The map

One flat map, every address physical. What QEMU `virt`'s 128 MiB of
RAM holds, and the MMIO beside it:

| Range | Contents |
| --- | --- |
| `0x80000000`–`0x80200000` | OpenSBI (M-mode) — the one region PMP locks |
| `0x80200000` | the kernel image — text, rodata, data, and the `.bss` holding the 96 MiB value heap, the 64 process slots, and the 64 × 64 KiB process stacks |
| `0x87000000` | the tick ring (`.emo_tick`) |
| `0x87001000` | the input ring (`.emo_in`) |
| `0x87002000` | the user handoff page (`.emo_user`) — the embedded image's bounds, the staged entry, the segment table |
| `0x87100000`–`0x88000000` | the user window — every user image links at its base |
| `0x10000000`, `0x0c000000`, … | MMIO — the 16550A UART, the PLIC, the rest of `virt`'s devices |

## What U-mode can reach

- **Every load and store is untranslated.** Nothing sits between a
  user address and the map: kernel text and data, the heap, the
  scheduler's slot table, every process's stack, both rings, the
  handoff page, other processes' memory, and the devices are all
  inside a wild address's reach. A wild jump into kernel text even
  executes — and stays in U-mode, because privilege rides the mode,
  not the code.
- **The raw family is admitted by target, not profile.** `peek`/`poke`,
  `ecall`, and `device_wait` are legal spellings in a user image, by
  the admission's own principle — a target admits the raw family iff
  the program owns the address space, and pre-SV39 the hardware grants
  a user program everything the builtins would reach. Refusing the
  spelling would hide the reach, not remove it; the process world's
  own words (`user_spawn`, `gate_reply`, `pid_num`, the T4.4 service
  vocabulary) are in the family and spellable from a user image for
  the same reason. The first user program's greeting rides the
  admission on purpose — it pokes the 16550A directly, with no gate
  at all, and `run.sh` pins the line.
- **The gate is the sanctioned door.** An `ecall` from U-mode always
  traps into the kernel's shim — never into OpenSBI — and the five
  verbs ride it. What the gate refuses it refuses as an answer: the
  caller's registers round-trip and execution resumes.

## What U-mode cannot reach

- **Privileged instructions, and every other fault.** Every S-mode CSR
  (`satp`, `sstatus`, `stvec`, `stimecmp`), `sfence.vma`, `sret` — an
  illegal instruction in U-mode; a load or store the hardware refuses
  (the firmware's PMP-locked region) — an access fault. Any such trap
  from U-mode kills the offender alone: the supervisor reports it
  loudly on the console (`user fault <pid> cause <scause> at <epc>`),
  the process's slot ends done, and the machine continues with its
  other processes. A fault from the kernel's own code is still the
  loud failure that ends the machine — that is the kernel's bug, not
  a user's. The pre-SV39 boundary this draws is honest about its
  width: the kill confines the *trap*, not the damage a wild store did
  before it — a user program that corrupted kernel memory and then
  faulted is killed cleanly, and the kernel runs on over the corruption
  until SV39 makes the store itself the fault.
- **The firmware.** An `ecall` from U-mode is the kernel's door, not
  OpenSBI's; the firmware's own region is the one range PMP keeps from
  lower privilege (OpenSBI locks it at boot — and the kill golden rides
  exactly this: the misbehaving program's load at `0x80000000` is the
  access fault the supervisor reports), and nothing else can stand
  behind PMP: the CSR is M-mode-writable, and OpenSBI defines no
  standard call to extend it.
- **Anything the gate refuses.** A verb outside the set, a pointer
  outside the caller's segments, a segment without the permission the
  access needs — each is a numbered refusal answered back over the
  gate, not a fault and not a crash.

## What defends what, meanwhile

- **Instruction privilege** — the hardware's one line, and it holds
  absolutely: U-mode cannot elevate itself.
- **The gate's supervisor checks.** Every pointer argument is bounded
  to one of the caller's own segments, carrying the permission the
  access needs, overflow-safe, all-or-nothing across segments (the
  contract in [`syscalls.md`](syscalls.md)). The gate never
  dereferences outside the caller's memory; pre-SV39 that is the
  supervisor's word, and SV39 makes it the MMU's.
- **Copy semantics.** Messages are snapshots at send, charged to the
  sender: a corrupted process cannot alias another's objects through
  the mailbox. It can still reach them by address — that is the
  window, and the copy discipline does not pretend otherwise.
- **Trap containment.** A user fault kills its process and nothing
  else; the kernel's own faults stay machine-wide, as they should.
- **Per-process accounting (Step 5)** — arenas and quotas: every
  allocation charges the running process's own arena, and a runaway
  process exhausts its own arena alone.
- **What does not defend:** the MMU (absent pre-SV39), PMP for S-mode
  memory (above), and — the honest limit of the kill — any damage a
  wild store did before its process trapped.

## Why the window is accepted

Bounded in time and in kind. In time: SV39 closes it, one milestone
away on a fixed roadmap. In kind: the defenses that matter long-term
are already the software contract, and the window does not erode them
— a user program that stays inside its own segments and works through
the gate is, in effect, isolated today, because the gate checks what
crosses and the copies keep processes from aliasing each other. What
the window leaves unenforced is exactly the wild-address reach, and
SV39 is the construct that removes that class of mistake. The reach
is on the record; nothing pretends otherwise.
