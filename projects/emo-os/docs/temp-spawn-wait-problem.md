# T4.4 WIP — the spawn/wait path faults at address 0

Status: open, as of 2026-10-27 (late session). The write and read
service paths are done and verified under QEMU; the spawn/wait path
panics with `fault_fetch` at address 0. This note captures everything
the next session needs to resume without re-deriving.

## What works (verified under QEMU, both runs' serial output)

- The gate's service routing: `dispatch` answers refusals directly and
  returns route codes (`-(1000 + op)`, `-103` = root poweroff) for the
  service verbs. The shim posts with `emo_gate_post` (raw pid + raw op
  word, **not boxed**) and parks the caller: slot[0] = sp+336 (the
  frame's switch-section base), state 5 (gate-wait), sepc+4, then
  `j emo_sched_pick`.
- The reply path: services answer through `gate_reply(answer)` (raw
  builtin), which writes the word **directly into the parked caller's
  frame a0 slot** (`slot[0] - 256`), flips state 5 → 1, and pushes.
  Ordinary sends never wake a 5, so mailbox ordering can't corrupt a
  reply. The resume is the existing `emo_os_trap_resume`.
- write (verb 1): the console service prints the caller's buffer and
  replies the count. Verified: `Ggate 500500 r3 r2`.
- read (verb 2): blocks in `device_wait` until a byte exists, replies
  the byte. Verified: `Gecho 88` after feeding `X`.

## The failing path

spawn (verb 3) → the process service's spawn arm → `user_spawn(entry,
stack)` (new raw builtin; builds a synthetic trap frame at
stack-544: zeroed 544 bytes, [144]=0x6020 sstatus, [152]=entry,
[336]=emo_trap_resume_hook, [536]=1 spare; slot[0]=F+336; runq push;
returns the raw pid) → gate_reply(pid) → the parent resumes →
wait(child) posts op 4 → ... → the child is scheduled → **the child's
first entry into emo_program faults: `cause:1, epc:0x0,
desc=fault_fetch` → the shim's `.Ltrap_bad` → the
"unexpected trap" panic.**

Verified correct (gdb, at user_spawn's return):

- a0 = 0x87102562 (the entry, from the user-program cell 0x87fff000 —
  the user stub parks emo_program there at boot),
- a1 = 0x87e00000 (the carved stack top),
- F = 0x87dffde0; F+336 = 0x80200462 (emo_trap_resume's address — the
  switch section's ra ✓),
- the slot: pid ✓, state ✓, slot[0] = F+336 ✓.

The fault's entry state: **sstatus FS bits = 0** at the shim entry
(the fsd prologue itself traps illegal, looping at its own epc
0x802001c8, tval = the fsd encoding 0xb502), and sepc = 0 on the first
FS=0 entry. So something **jumped to address 0 with sstatus.FS = 0**.

## Candidates (unverified)

1. The child's switch-in reads F+104..F+192 (fs0–fs11, zeros — fld is
   legal with FS=DIRTY) and F+200 (spare=1 → SIE on). emo_sched_pick
   then `ret`s to emo_os_trap_resume with sp = F+544 — the resume
   reads -544(sp) = F. All verified or consistent.
2. **F+144 (sstatus) / F+152 (sepc) were never dump-verified.** The
   stores in emo_user_spawn (`sd t1, 144(t4)`, `sd t0, 152(t4)`) look
   right, but if either slot reads 0 at switch-in, the resume csrw's
   FS=Off and sepc=0 → exactly the observed fault. **Next step:
   x/2gx 0x87dffe50 (= F+144) at the user_spawn breakpoint.**
3. emo_os_user_exit (the child's fall-off stub) was never stored into
   F+0 — the child's ra slot is 0 (latent, only bites if the top level
   returns, which exit(7) prevents).

## A design note for the child process

The spawned process re-enters emo_program **sharing the image's
runtime state** — emo_cur_slot, the pid world, the heap cursor are all
per-image, not per-kernel-process. self_pid() therefore reads the same
slot for parent and child (both pid 1), so the branch token cannot be
self_pid-based; hello uses the raw cell token (cell_in ≠ 0 → child).
The heap cursor is also shared (single-hart cooperative, no tearing),
and the child's user_spawn ra slot is 0 — fine while the child exits
through the gate, wrong if it ever returns.

## Debugging recipes that worked

- Pick tracing: `break *0x802017d2` (emo_sched_pick) + commands block
  printing cur-slot's pid/state/sp/ra. Commands-block printfs: single
  `%d` args are reliable; multi-arg printf intermittently fails with
  "Bad format string".
- user_spawn return dump: `break emo_user_spawn; finish;` then x the
  frame at 0x87dffde0 (F) — F+336 at 0x87dfff30.
- shim-entry FS tracing: `break *0x80200180` printing
  `($sstatus >> 13) & 3` — the boot phase shows FS=3, the failing
  phase shows FS=0 looping at sepc=0x802001c8 (the shim's own
  `fsd ft0, 168(sp)` re-trapping).
- emo_fail dump: `break emo_fail` then
  `p/x *(long*)($sp+160)` (scause) and `+152` (sepc) — the observed
  panic frame read scause=0, sepc=0 (a zeroed frame).

## Gotchas hit on the way (all fixed, keep an eye out)

- The shim's sp during a U-mode ecall is the **frame base** (S−544),
  not S: the park must use `addi t1, sp, 336` (the tick's preempt
  passes sp+336 the same way). Using −208 made the switch-in restore
  from a window 544 bytes too low → garbage sstatus (FS=0), garbage
  sepc (=0) → the same jump-to-0 signature.
- emo_gate_post originally boxed the op word; the service's dynamic
  body holds the mailbox word **raw**, so the boxed cell's *pointer*
  went into `op_of`'s shift → op 0 → the old-reader arm → a send to
  pid = the cell pointer's payload → msg_noproc.
- The process service originally read the entry from the handoff cell
  0x87002108, which runtime.S no longer fills (the entry moved to the
  user image's own cell at 0x87fff000) → the child's sepc was 0.
- collect_files walked into nested packages (the module walk always
  skipped them) — fixed, pinned in emo_project_test.
- `Pid == Pid` on metal was hardwired false (emo_eq_deep kind 18 →
  .Leq_no) — fixed to compare payloads (.Leq_cell).

## Files touched (all uncommitted, on feat/emo-os)

gate.emo, main.emo, trap.S, runtime.S, link.ld, user.emo, user.S,
hello/main.emo, run.sh, syscall.emo (5 stubs), the compiler's four
raw-builtins files, and the FS-probe/'G'-marker debug code (TEMPORARY —
remove before landing: the idle-loop FS probe in emo_riscv.ml's
emo_deadlock, and the 'G' poke in gate.emo's route).
