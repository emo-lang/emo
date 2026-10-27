# T4.4 — the spawn/wait fault, resolved

Status: **closed**, 2026-10-27. The write and read service paths were
already verified; the spawn/wait path now completes its round trip
under QEMU on both timer transports — `born` (the child's line through
the gate) then `wait 7` (the parent's wait answered by the child's
exit) — with the machine's own self-exit after. The proof lives in
`hello/main.emo` and `run.sh`'s ordered assertions.

The note below once carried the open state; what remains is the
record of what was actually wrong. Three defects, each masked by the
next until the first fix exposed it:

1. **The child's saved sp was the frame base, not the switch-section
   base.** `emo_user_spawn` built the synthetic trap frame at
   `stack - 544` and stored that base in the slot's sp word — but the
   switch-in protocol (`emo_sched_pick`, the shim's own park, and
   `emo_sched_preempt`) treats the slot's word as the **switch-section
   base**: 208 bytes of context are restored from it, then `sp += 208`
   and `ret` through its ra. From the frame base, that ra was the
   frame's zeroed word at +0 — the child's first dispatch `ret`ted to
   address 0, the exact observed signature (`cause:1, epc:0x0,
   fault_fetch`). The fix stores `frame + 336` and, as the comment had
   always promised, plants `emo_os_user_exit` in the frame's ra slot
   so a top-level fall-off is an exit rather than a jump into the
   weeds. (The stub moved from the kernel's `trap.S` into the
   compiler's runtime body — the user profile assembles without the
   kernel package, and `emo_user_spawn` serves every image.)

2. **The gate's reply had no addressee, and the request cells were
   global.** With spawn/wait, two transactions park at once (the
   parent in `wait`, the child in its `write`), and the old
   machinery — reply to whichever slot is in state 5, arguments in one
   shared pair of handoff cells — broke deterministically: the
   parent's `wait` dispatch clobbered the child's queued write's
   `buf` cell, and the console service faulted loading `peek8(8)`.
   The request word now carries the caller's pid beside the op
   (`op << 32 | pid`, packed by the shim), `emo_gate_reply` takes the
   target's pid and answers that exact parked frame, the request
   argument cells are per service, and the process service remembers
   the waiter's pid (`pending_waiter`) beside the pid being waited on
   (`pending_target`). `gate_reply` is a two-argument raw builtin now
   (checker signature and codegen with it).

3. **The exit route was its own boundary case.** The shim dispatched
   with `a0 >= -1000` as the answer range — but `route_process_exit`
   **is** `-1000` (op 0), so a child's exit was treated as an answer:
   the ecall "returned" −1000 and the child fell through into the
   parent's proof code. The comparison is strict (`> -1000`), and the
   route range is −1000 and below.

The debugging recipes that closed it: a one-character verb trace at
the shim's ecall entry (`trap.S`, temporary, removed) — serial/stderr
interleaving under `-d int` splits lines, so read verb chars next to
the trap lines, not inside the clean view; and the disassembly of the
faulting `epc` to name the faulting load. The child still parks forever
in state 5 after its exit reply (a slot held by a finished process) —
the reclamation is later work, not a fault.
