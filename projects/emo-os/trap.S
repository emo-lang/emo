# The kernel's trap machinery (T3.6): the stvec entry trampoline (T6.3),
# the kernel-path shim, the full trap frame, and the timer. The boot
# stub calls emo_os_trap_init once before the program runs — it probes
# the SBI for the Sstc extension, sets stvec to the trampoline, enables
# the supervisor timer interrupt, and arms the first deadline — and
# parks emo_os_trap_resume in the runtime's emo_trap_resume_hook, the
# address a preempted process resumes at.
#
# The trap frame (544 bytes) is two sections: the top 208 bytes are
# shaped exactly like the scheduler's context frame — that is what
# makes preemption a context switch, emo_sched_preempt points the
# victim's slot at it — and the rest sits below, read by the resume
# stub through negative offsets. Since T6.3 a trap out of U-mode does
# not frame on the interrupted stack: the trampoline builds the frame
# at the pass's trap anchor — a fixed address in the pass's own memory,
# carried in sscratch (the anchor while user code runs, the sentinel 0
# while kernel code runs) — and the interrupted sp parks in the word
# below the frame, restored just before the sret home. A kernel trap
# still frames on the interrupted kernel stack through the shim, whose
# prologue the trampoline's kernel path reaches unchanged. The ISR
# discipline (T3.6): no allocation — the shim and everything it calls
# are assembly over fixed words; the tick ring is preallocated at a
# fixed address the kernel's linker script owns; ack (re-arm), enqueue
# (the ring), wake (the scheduler: the quota step, then the
# preemption).
#
# Addresses (T6.1): the kernel runs in Sv39's high half, so every fixed
# address the machinery names — the devices, the handoff cells, the
# rings by symbol — is the physical one plus EMO_KOFF. The user cells
# at 0x87fff000 stay physical: they are the user image's, read and
# written through the identity alias — the pass's own table before the
# trampoline's swap, the supervisor's low window after it.

    .set EMO_KOFF, 0xFFFFFFC000000000

    .section .text

# emo_os_trap_init: vector, probe, enables, first deadline. The probe
# is the capability itself: Sstc is an ISA delegation, not an SBI
# extension, so nothing can be asked — the first stimecmp write either
# works or traps as an illegal instruction, and the shim answers it
# (the state word to 2, sepc past the failed write, sret home). The
# probing window is the three instructions around the write; no other
# illegal instruction can land inside it.
    .align 2                 # stvec's low bits are the vector mode
    .globl emo_os_trap_init
emo_os_trap_init:
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_os_trap_trampoline
    csrw stvec, t0
    csrw sscratch, zero      # the sentinel: no anchor until the first
                             # return into U-mode arms one (T6.3)
    li t0, 1
    la t1, emo_os_probe_state
    sd t0, 0(t1)
    li t0, -1               # the probe write: all-ones never fires
    csrw stimecmp, t0
    la t1, emo_os_probe_state
    ld t0, 0(t1)            # still 1 = the write worked; 2 = the shim said no
    li t2, 2
    beq t0, t2, .Linit_sbi
    li t0, 1
    j .Linit_kind
.Linit_sbi:
    li t0, 0
.Linit_kind:
    la t1, emo_os_timer_kind
    sd t0, 0(t1)
    li t0, 0x220            # sie.STIE and sie.SEIE — the tick and the devices
    csrs sie, t0
    csrsi sstatus, 2        # SIE on
    # the probe is settled: the state word goes to 3, so the shim's
    # probe answer is only ever for a probe in flight — a stray illegal
    # instruction (a user program's, from T4.1 on) is the loud failure
    # it looks like
    li t0, 3
    la t1, emo_os_probe_state
    sd t0, 0(t1)
    call emo_os_timer_rearm
    # the PLIC (T3.7): the UART's receive line (IRQ 10 on `virt`) into
    # this S-mode context — a priority above the threshold, the enable
    # bit, threshold zero (OpenSBI leaves context 1's threshold at 7 —
    # masked — the kernel owns the context now). The device side of the
    # receive interrupt (IER bit 0) is the driver's own `uart_init`.
    li t0, EMO_KOFF + 0x0c000028  # priority[10]
    li t1, 1
    sw t1, 0(t0)
    li t0, EMO_KOFF + 0x0c002080  # enable[context 1] word 0
    li t1, 1024             # 1 << 10
    sw t1, 0(t0)
    li t0, EMO_KOFF + 0x0c201000  # threshold[context 1]
    sw zero, 0(t0)
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_os_timer_rearm: the ISR's ack — the next deadline one interval
# out, by stimecmp write when Sstc is delegated, else the legacy SBI
# set_timer ecall (a7 = 0). The virt board's timebase is 10 MHz; the
# interval is 100000 cycles — a 10 ms tick.
    .globl emo_os_timer_rearm
emo_os_timer_rearm:
    la t0, emo_os_timer_kind
    ld t0, 0(t0)
    beqz t0, .Lrearm_sbi
    rdtime t1
    li t2, 100000
    add t1, t1, t2
    csrw stimecmp, t1
    ret
.Lrearm_sbi:
    rdtime t1
    li t2, 100000
    add a0, t1, t2
    li a7, 0
    ecall
    ret

# The trap frame: 544 bytes at the anchor A (the frame's base), with
# the interrupted sp parked in the word below it (A-8) — the slot the
# resume stub reads at -552 to put the pass back on its own sp before
# the sret home. The rest section (336 bytes, offsets 0..335) holds
# everything the scheduler's context frame does not; the switch section
# (336..543) matches emo_schedule's frame — ra, s0-s11, fs0-fs11, and
# the spare word that records the mask (here: the pre-trap SIE, from
# sstatus.SPIE). emo_sched_preempt points the victim's slot at A+336
# (offset 336), and the resume stub — entered with sp back at A+544
# after the scheduler's pop — reads the rest section through negative
# offsets. A kernel trap frames the old way instead: the shim lays the
# same 544 bytes below the interrupted kernel sp, which the frame's own
# base then equals — the negative offsets read the same, and the sp
# slot below is simply never read.
#
# emo_os_trap_shim: the kernel path's prologue. stvec lands on the
# trampoline (T6.3), which routes a trap out of the kernel here with
# the interrupted sp recovered and nothing clobbered; the shim frames
# on the interrupted kernel stack — trusted, the kernel's own — and
# everything the interrupted code owns is saved before a bit of it is
# clobbered. The dispatch it falls into is the trampoline's shared
# body: scause's — the supervisor timer interrupt runs the discipline,
# and any other trap is the loud failure.
    .align 2
    .globl emo_os_trap_shim
emo_os_trap_shim:
    addi sp, sp, -544
    sd t0, 24(sp)
    sd t1, 32(sp)
    csrr t0, scause
    csrr t1, sepc
    sd t0, 160(sp)
    sd t1, 152(sp)
    csrr t0, sstatus
    sd t0, 144(sp)
    sd zero, 536(sp)         # the spare word: a trap frame switches in
                             # masked — its sret restores SIE from the
                             # saved SPIE, and an interrupt landing between
                             # the scheduler's unmask and the resume would
                             # lay its own frame over this one's rest section
    sd ra, 0(sp)             # the rest section keeps its own ra copy
    sd gp, 8(sp)
    sd tp, 16(sp)
    sd t2, 40(sp)
    sd t3, 48(sp)
    sd t4, 56(sp)
    sd t5, 64(sp)
    sd t6, 72(sp)
    sd a0, 80(sp)
    sd a1, 88(sp)
    sd a2, 96(sp)
    sd a3, 104(sp)
    sd a4, 112(sp)
    sd a5, 120(sp)
    sd a6, 128(sp)
    sd a7, 136(sp)
    fsd ft0, 168(sp)
    fsd ft1, 176(sp)
    fsd ft2, 184(sp)
    fsd ft3, 192(sp)
    fsd ft4, 200(sp)
    fsd ft5, 208(sp)
    fsd ft6, 216(sp)
    fsd ft7, 224(sp)
    fsd ft8, 232(sp)
    fsd ft9, 240(sp)
    fsd ft10, 248(sp)
    fsd ft11, 256(sp)
    fsd fa0, 264(sp)
    fsd fa1, 272(sp)
    fsd fa2, 280(sp)
    fsd fa3, 288(sp)
    fsd fa4, 296(sp)
    fsd fa5, 304(sp)
    fsd fa6, 312(sp)
    fsd fa7, 320(sp)
    # the interrupted code's switch section, top of frame
    sd ra, 336(sp)
    sd s0, 344(sp)
    sd s1, 352(sp)
    sd s2, 360(sp)
    sd s3, 368(sp)
    sd s4, 376(sp)
    sd s5, 384(sp)
    sd s6, 392(sp)
    sd s7, 400(sp)
    sd s8, 408(sp)
    sd s9, 416(sp)
    sd s10, 424(sp)
    sd s11, 432(sp)
    fsd fs0, 440(sp)
    fsd fs1, 448(sp)
    fsd fs2, 456(sp)
    fsd fs3, 464(sp)
    fsd fs4, 472(sp)
    fsd fs5, 480(sp)
    fsd fs6, 488(sp)
    fsd fs7, 496(sp)
    fsd fs8, 504(sp)
    fsd fs9, 512(sp)
    fsd fs10, 520(sp)
    fsd fs11, 528(sp)
    la t0, emo_os_trap_frame
    sd sp, 0(t0)             # the dispatch reads the frame through this
                             # word, never through sp: the handler keeps
                             # running on the interrupted kernel stack
                             # (T6.3), and the frame's base must not ride
                             # a register the calls below would lose
    j .Ltrap_arena           # into the shared dispatch — the frame is
                             # whole, the CSRs are read, and a kernel
                             # trap proceeds exactly as it always has

# The trampoline (T6.3): stvec lands here, in the one page every address
# space maps (link.ld gives the section its own page at the end of the
# text; map_kernel's text RX carries it into each table, no U — the
# trampoline is the supervisor's to execute, not the user's). The entry
# spends no register before the interrupted state is safe: the swap
# between sp and sscratch both chooses the path and hands the user path
# its frame. sscratch holds the running pass's trap anchor while user
# code runs — the identity address of its fixed trap frame, armed by
# every return into U-mode (emo_os_anchor_arm) — and the sentinel 0
# while kernel code runs. A trap out of U-mode swaps the anchor into
# sp: every register is then saved sp-relative, into the anchor frame,
# before one of them is spent, and the interrupted sp — recovered from
# sscratch — parks in the word below the frame. A trap out of the
# kernel swaps the sentinel in: two instructions undo the swap and the
# shim runs exactly as it always has, framing on the interrupted kernel
# stack. The user path ends the transition mid-page: the kernel's own
# table comes through the switch's resolve/write pair (the pick's own
# discipline, so the cache on the Sv39 page stays true), and
# the dispatch that follows runs on the kernel's own table and the
# kernel's own trap stack, the frame reached through the base the
# prologue parked (emo_os_trap_frame), never through sp. Nothing of the
# pass's table is trusted past the swap, and the interrupted sp the
# pass chose is never a place the kernel stores anything: a wild sp is
# saved and handed back, not obeyed. The resume stub restores it and
# srets home.
    .section .emo_tramp, "ax"
    .align 2                 # stvec's low bits are the vector mode
    .globl emo_os_trap_trampoline
emo_os_trap_trampoline:
    csrrw sp, sscratch, sp   # the anchor in, the interrupted sp out —
    bnez sp, .Ltramp_user    # or the sentinel: a kernel trap takes its
    csrrw sp, sscratch, sp   # own sp back and the shim proceeds unchanged
    j emo_os_trap_shim
.Ltramp_user:
    sd ra, 0(sp)
    sd t0, 24(sp)
    csrr t0, sscratch        # the interrupted sp — t0's own value is
    sd t0, -8(sp)            # already in the frame; the word below it is
    csrw sscratch, zero      # the sp slot, and the sentinel is back
                             # before another kernel line runs
    sd t1, 32(sp)
    sd gp, 8(sp)
    sd tp, 16(sp)
    csrr t0, scause
    csrr t1, sepc
    sd t0, 160(sp)
    sd t1, 152(sp)
    csrr t0, sstatus
    sd t0, 144(sp)
    sd zero, 536(sp)         # the spare word: a trap frame switches in
                             # masked, as the shim's always were
    sd t2, 40(sp)
    sd t3, 48(sp)
    sd t4, 56(sp)
    sd t5, 64(sp)
    sd t6, 72(sp)
    sd a0, 80(sp)
    sd a1, 88(sp)
    sd a2, 96(sp)
    sd a3, 104(sp)
    sd a4, 112(sp)
    sd a5, 120(sp)
    sd a6, 128(sp)
    sd a7, 136(sp)
    fsd ft0, 168(sp)
    fsd ft1, 176(sp)
    fsd ft2, 184(sp)
    fsd ft3, 192(sp)
    fsd ft4, 200(sp)
    fsd ft5, 208(sp)
    fsd ft6, 216(sp)
    fsd ft7, 224(sp)
    fsd ft8, 232(sp)
    fsd ft9, 240(sp)
    fsd ft10, 248(sp)
    fsd ft11, 256(sp)
    fsd fa0, 264(sp)
    fsd fa1, 272(sp)
    fsd fa2, 280(sp)
    fsd fa3, 288(sp)
    fsd fa4, 296(sp)
    fsd fa5, 304(sp)
    fsd fa6, 312(sp)
    fsd fa7, 320(sp)
    # the interrupted code's switch section, top of frame
    sd ra, 336(sp)
    sd s0, 344(sp)
    sd s1, 352(sp)
    sd s2, 360(sp)
    sd s3, 368(sp)
    sd s4, 376(sp)
    sd s5, 384(sp)
    sd s6, 392(sp)
    sd s7, 400(sp)
    sd s8, 408(sp)
    sd s9, 416(sp)
    sd s10, 424(sp)
    sd s11, 432(sp)
    fsd fs0, 440(sp)
    fsd fs1, 448(sp)
    fsd fs2, 456(sp)
    fsd fs3, 464(sp)
    fsd fs4, 472(sp)
    fsd fs5, 480(sp)
    fsd fs6, 488(sp)
    fsd fs7, 496(sp)
    fsd fs8, 504(sp)
    fsd fs9, 512(sp)
    fsd fs10, 520(sp)
    fsd fs11, 528(sp)
    la t0, emo_os_trap_frame
    sd sp, 0(t0)             # the frame's base, for the dispatch: it
                             # reads the frame through this word, never
                             # through sp (T6.3)
    # the transition's middle: the kernel's own table, through the
    # switch's own resolve/write pair (the pick's discipline — the
    # cache on the Sv39 page stays true about what satp holds). From
    # here to the sret home, nothing the pass maps is trusted — every
    # kernel access goes through the kernel's half or the low window,
    # never the pass's own view of its pages.
    la t0, emo_space_hook
    ld t0, 0(t0)
    li a0, 0                 # the kernel's own table: word 0's answer
    jalr t0                  # resolve: the physical root, or -1 when
    bltz a0, 2f              # satp already names it
    la t0, emo_space_write_hook
    ld t0, 0(t0)
    jalr t0                  # the swap, fences included
2:
    la sp, emo_os_trap_stack_top
                             # the handler's own stack: the kernel's, not
                             # the pass's — the dispatch, the reports,
                             # the scheduler all descend here, so no
                             # kernel line ever runs through the pass's
                             # memory or off the bottom of its block
    j .Ltrap_arena           # the shared dispatch, on the kernel's
                             # table and the kernel's stack

    .section .text

# The shared dispatch: both prologues land here — the shim's, for a
# trap out of the kernel framed on the interrupted kernel stack, and
# the trampoline's, for a trap out of U-mode framed at the pass's
# anchor with the kernel's table and stack live. Every frame access
# below goes through emo_os_trap_frame (the base both prologues parked),
# never through sp — the two paths' handler stacks differ, and the
# calls the body makes must never write below the frame into the word
# the resume reads the interrupted sp from.
.Ltrap_arena:
    # dispatch on scause: the supervisor timer interrupt, the
    # supervisor external interrupt (the devices, through the PLIC),
    # the U-mode ecall (the gate's door), the probe's
    # illegal-instruction answer, or the loud failure for anything else.
    # First the arena's save (T5.1): a trap out of U-mode leaves the
    # user image's arena cursor behind — the leaver's slot takes it
    # home, so the next resume can hand the arena to someone else. The
    # boot pass is the exception: it IS the kernel's own root still
    # (the stub entered it after the kernel's program returned), and
    # the root slot's arena words must stay the kernel heap's — the
    # spawn carve reads them — so the boot pass's progress lands in
    # the boot pair below. A trap from the kernel's own code saves
    # nothing: the kernel's processes allocate against their own
    # slot's arena directly. The slot's words are kernel addresses
    # (T6.1), the cells the user's — the pass runs on the identity
    # alias — so the cursor crosses with the offset added; the boot
    # pass's pair round-trips the user's values as they are.
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    ld t0, 144(t0)
    srli t0, t0, 8
    andi t0, t0, 1           # sstatus.SPP: 0 = the trap came from U-mode
    bnez t0, .Larena_saved
    li t0, 0x87fff008        # the user stub parked the address of its
    ld t0, 0(t0)             # root slot's arena cursor word here
    beqz t0, .Larena_saved   # nothing staged: nothing to save
    la t2, emo_cur_slot
    ld t2, 0(t2)
    ld t3, 8(t2)             # the leaver's pid
    li t1, 1
    beq t3, t1, .Larena_boot
    ld t1, 0(t0)             # the running pass's cursor, the user's address
    li t4, EMO_KOFF
    add t1, t1, t4           # the kernel's
    sd t1, 576(t2)
    j .Larena_saved
.Larena_boot:
    ld t1, 0(t0)
    la t3, emo_os_boot_cur
    sd t1, 0(t3)
    li t0, 0x87fff010
    ld t0, 0(t0)             # the end word beside it
    ld t1, 0(t0)
    la t3, emo_os_boot_lim
    sd t1, 0(t3)
.Larena_saved:
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    ld t0, 160(t0)
    bgez t0, .Ltrap_exc      # bit 63 clear: an exception
    slli t0, t0, 1           # drop the interrupt bit
    li t1, 10                # cause 5, shifted
    beq t0, t1, .Ltrap_timer
    li t1, 18                # cause 9, shifted
    beq t0, t1, .Ltrap_ext
    j .Ltrap_bad
.Ltrap_exc:
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    ld t0, 160(t0)
    li t1, 8                 # environment call from U-mode
    beq t0, t1, .Ltrap_ucall
    li t1, 2                 # illegal instruction — the probe's answer?
    bne t0, t1, .Ltrap_fault
    la t2, emo_os_probe_state
    ld t3, 0(t2)
    li t4, 1
    bne t3, t4, .Ltrap_fault
    li t3, 2
    sd t3, 0(t2)             # no stimecmp: the legacy transport it is
    la t0, emo_os_trap_frame
    ld t0, 0(t0)
    ld t1, 152(t0)
    addi t1, t1, 4           # sepc past the failed write
    sd t1, 152(t0)
    j .Ltrap_home
.Ltrap_fault:
    # An exception the gate does not own: whose fault is it? The
    # frame's saved sstatus carries SPP — the privilege the trap came
    # from. A kernel fault is the machine's own: the loud failure. A
    # user fault is the offender's: the report is loud (who, why,
    # where — through the kernel's typed def, on the kernel's trap
    # stack, the gate's precedent), the slot ends done — sends to it
    # drop, replies to it refuse, the deadlock scan reads a finished
    # process — and the machine continues without it. The root's death
    # ends the machine, as its own exit does. The frame is abandoned:
    # no sepc, no resume — and the victim's s0 is the shim's to spend,
    # because nothing on this path ever resumes.
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    ld t0, 144(t0)
    srli t0, t0, 8
    andi t0, t0, 1           # sstatus.SPP: 0 means the trap came from U-mode
    bnez t0, .Ltrap_bad
    la s0, emo_cur_slot
    ld s0, 0(s0)             # the offender's slot
    ld a0, 8(s0)             # its pid
    la t0, emo_os_trap_frame
    ld t0, 0(t0)
    ld a1, 160(t0)           # scause
    ld a2, 152(t0)           # sepc
    call emo_main__fault_report
    li t3, 3
    sd t3, 16(s0)            # done
    mv a0, s0
    call emo_arena_reap      # the stack block and the arena go home
                             # unless a queued message still pins the
                             # arena (T5.2/T5.3)
    ld t0, 8(s0)
    li t1, 1
    beq t0, t1, .Ltrap_exit  # the root's death is the machine's end
    j emo_sched_pick
.Ltrap_ucall:
    # the gate (T4.2/T4.4): every verb marshals into the gate's Emo
    # dispatcher — the verb, then the six words. The caller's pid goes
    # to its handoff cell first (the dispatcher reads it through
    # peek/poke like everything else on the page). The answer is one of
    # three shapes: -103 the root's exit (the machine ends here), a
    # -1000-op route (the request goes to a service process and the
    # caller parks — its context IS this frame), or anything else: an
    # answer or a refusal, riding home in the trapped a0.
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    ld t1, 136(t0)           # the trapped a7: the verb
    la t2, emo_cur_slot
    ld t2, 0(t2)
    ld t2, 8(t2)             # the caller's pid
    li t3, EMO_KOFF + 0x87002110  # the caller-pid cell (+272)
    sd t2, 0(t3)
    ld a0, 136(t0)
    ld a1, 80(t0)
    ld a2, 88(t0)
    ld a3, 96(t0)
    ld a4, 104(t0)
    ld a5, 112(t0)
    ld a6, 120(t0)
    call emo_gate__dispatch
    li t1, -103
    beq a0, t1, .Ltrap_exit
    li t1, -104
    beq a0, t1, .Ltrap_heap
    li t1, -1000
    bgt a0, t1, .Ltrap_answer   # answers and refusals ride home; the
    j .Ltrap_route              # routes are -1000 (a child's exit) and
                                # below it — the exit is the boundary
.Ltrap_heap:
    # The heap's death route (T5.1): the user image's allocator
    # reported its caller's arena exhausted (verb 5), the dispatch
    # answered -104, and the offender dies alone — the loud report on
    # the kernel's trap stack (the fault report's precedent), the
    # slot ending done, the frame abandoned, the machine continuing.
    # The root's death is the machine's end, as its exit is.
    la s0, emo_cur_slot
    ld s0, 0(s0)                # the offender's slot
    ld a0, 8(s0)                # its pid
    call emo_main__heap_report
    li t3, 3
    sd t3, 16(s0)               # done
    mv a0, s0
    call emo_arena_reap         # the stack block and the arena go home
                                # unless a queued message still pins the
                                # arena (T5.2/T5.3)
    ld t0, 8(s0)
    li t1, 1
    beq t0, t1, .Ltrap_exit     # the root's death is the machine's end
    j emo_sched_pick
.Ltrap_answer:
    la t0, emo_os_trap_frame
    ld t0, 0(t0)                # the frame's base (T6.3)
    sd a0, 80(t0)
    # the ecall is a synchronous exception: sret returns to sepc, so
    # the frame's sepc moves past the instruction — without this the
    # same ecall re-executes forever
    ld t1, 152(t0)
    addi t1, t1, 4
    sd t1, 152(t0)
    j .Ltrap_home
.Ltrap_route:
    # a0 = -(1000 + op): the op goes to its service's mailbox (the
    # helper posts and wakes), the caller's slot takes this frame as
    # its context with state 5 — gate-wait, woken only by the reply —
    # and the ecall's sepc moves past the instruction before the
    # switch. The pick never returns to the shim. The exit (op 0) is
    # the one route that never answers: the caller's death IS the
    # transaction, so its slot ends done (3, the state a returning
    # entry thunk writes) and the frame is abandoned — not parked as a
    # gate-wait that no reply will ever relieve.
    addi t5, a0, 0
    sub t6, zero, t5
    addi t6, t6, -1000       # the op
    li t3, 3
    bge t6, t3, .Lroute_proc # ops 3 (spawn) and 4 (wait)
    beqz t6, .Lroute_exit    # op 0 (a child's exit): the death route
.Lroute_cons:
    li a0, EMO_KOFF + 0x870020f0  # the console service's pid cell (+240)
    j .Lroute_post
.Lroute_proc:
    li a0, EMO_KOFF + 0x870020f8  # the process service's pid cell (+248)
.Lroute_post:
    ld a0, 0(a0)             # the service's raw pid
    slli a1, t6, 32          # the request word: op << 32 | the caller's
    la t2, emo_cur_slot      # pid — the answer's addressee rides with
    ld t2, 0(t2)             # the request, so the service's reply lands
    ld t2, 8(t2)             # on the caller that asked, not on whichever
    or a1, a1, t2            # state-5 slot a scan finds first
    call emo_gate_post
    la t0, emo_cur_slot
    ld t0, 0(t0)             # the caller's slot
    la t1, emo_os_trap_frame
    ld t1, 0(t1)             # the frame's base (T6.3)
    addi t1, t1, 336         # the frame's switch-section base — the tick's
    sd t1, 0(t0)             # own preempt passes the same shape
    ld t2, emo_trap_resume_hook
    sd t2, 0(t1)             # the resume is the trap resume
    li t3, 5
    sd t3, 16(t0)            # state 5: gate-wait
    la t3, emo_os_trap_frame
    ld t3, 0(t3)
    ld t4, 152(t3)
    addi t4, t4, 4           # the ecall is consumed
    sd t4, 152(t3)
    j emo_sched_pick
.Lroute_exit:
    # The death route: the request reaches the process service exactly
    # as every route's does, but the caller is not parked — a finished
    # process holds no transaction. Its slot takes state 3, the done
    # the entry thunk's own return writes: a send to the pid now drops
    # instead of queueing into a mailbox nobody drains, a stray reply
    # to it is the loud service bug instead of a resurrection, and the
    # deadlock scan reads a finished process, not a pending one. The
    # frame stays where the exit left it, at the dead pass's anchor, for
    # the reclamation (T5) to take back — the stack block and the arena.
    li a0, EMO_KOFF + 0x870020f8  # the process service's pid cell (+248)
    ld a0, 0(a0)             # the service's raw pid
    slli a1, t6, 32          # the request word: op << 32 | the caller's
    la t2, emo_cur_slot      # pid — the record's subject rides with it
    ld t2, 0(t2)
    ld t2, 8(t2)
    or a1, a1, t2
    call emo_gate_post
    la t0, emo_cur_slot
    ld t0, 0(t0)             # the exiting caller's slot
    li t3, 3
    sd t3, 16(t0)            # done
    mv a0, t0
    call emo_arena_reap      # the stack block and the arena go home
                             # unless a queued message still pins the
                             # arena (T5.2/T5.3)
    j emo_sched_pick
.Ltrap_exit:
    # the machine's end: the frame allocator's account is the last line
    # (T5.3) — on whichever stack the root died on, the typed def
    # allocating nothing — then the SBI poweroff
    call emo_frames__report
    li a7, 8
    ecall                    # the SBI poweroff
1:  wfi
    j 1b
.Ltrap_ext:
    call emo_os_console_irq
    j .Ltrap_home
.Ltrap_timer:
    call emo_os_timer_rearm    # enqueue the tick: the ISR is the ring's only producer, the entry
    # carries its sequence number, and the store fence orders it before
    # the producer cursor the consumer reads
    la t0, emo_os_tick_prod
    ld t1, 0(t0)
    la t2, emo_os_tick_cons
    ld t3, 0(t2)
    sub t4, t1, t3
    li t5, 64
    bgeu t4, t5, .Ltrap_full
    addi t4, t1, 1           # the tick's sequence number
    andi t5, t1, 63          # its slot
    slli t5, t5, 3
    la t6, emo_os_tick_ring
    add t5, t5, t6
    sd t4, 0(t5)
    fence w, w
    sd t4, 0(t0)             # the producer cursor follows the entry
    j .Ltrap_ticked
.Ltrap_full:
    la t5, emo_os_tick_drops
    ld t6, 0(t5)
    addi t6, t6, 1
    sd t6, 0(t5)
.Ltrap_ticked:
    # the wake: the quota step, then — a spent slice — the preemption,
    # which dispatches the next process and never comes back
    call emo_sched_tick
    beqz a0, .Ltrap_home
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    addi a0, t0, 336         # the victim's switch-section base
    call emo_sched_preempt
.Ltrap_home:
    la t0, emo_os_trap_frame
    ld t0, 0(t0)             # the frame's base (T6.3)
    addi sp, t0, 544         # sp to the frame's top: the interrupted
                             # kernel sp on the shim's path, and the
                             # landing the resume's negative offsets and
                             # the parked interrupted sp read on the
                             # trampoline's
    j emo_os_trap_resume

# emo_os_console_irq: the external interrupt's handler — the ISR
# discipline (T3.6) on the console's line (T3.7). Claim through the
# PLIC, drain the UART's receive FIFO into the input ring — the ring's
# backpressure is the device's own: a full ring stops the drain and
# the line re-raises after the complete — wake the device-waiter, and
# complete the claim. Nothing allocates; everything is fixed words.
    .globl emo_os_console_irq
emo_os_console_irq:
    addi sp, sp, -16
    sd ra, 0(sp)
    li t0, EMO_KOFF + 0x0c201004  # claim[context 1]
    lw a0, 0(t0)
    beqz a0, .Lcons_done     # a spurious claim: nothing to complete
    li t1, 10
    bne a0, t1, .Lcons_bad   # a device this kernel does not know
.Lcons_drain:
    li t0, EMO_KOFF + 0x10000005  # the line-status register
    lbu t1, 0(t0)
    andi t1, t1, 1           # data ready?
    beqz t1, .Lcons_wake
    li t0, EMO_KOFF + 0x10000000  # the receive buffer; the read clears DR
    lbu t2, 0(t0)
    la t3, emo_os_in_prod
    ld t4, 0(t3)
    la t5, emo_os_in_cons
    ld t6, 0(t5)
    sub t1, t4, t6
    li t0, 128
    bgeu t1, t0, .Lcons_wake # the ring is full: the line re-raises
    andi t1, t4, 127
    la t5, emo_os_in_ring
    add t5, t5, t1
    sb t2, 0(t5)             # the entry, then the cursor behind it
    addi t4, t4, 1
    fence w, w
    sd t4, 0(t3)
    j .Lcons_drain
.Lcons_wake:
    call emo_sched_wake_console
    li t0, EMO_KOFF + 0x0c201004
    li t1, 10
    sw t1, 0(t0)             # complete the claim
.Lcons_done:
    ld ra, 0(sp)
    addi sp, sp, 16
    ret
.Lcons_bad:
    la a0, msg_unexpected
    la a1, msg_unexpected_end
    call emo_fail

.Ltrap_bad:
    la a0, msg_unexpected
    la a1, msg_unexpected_end
    call emo_fail

# emo_os_anchor_arm: sscratch takes the current pass's trap anchor (T6.3)
# — the identity address of its fixed trap frame's base, in memory the
# pass's own execution never uses for live data. A spawned pass anchors
# at the bottom of its own stack block (the slot's word at 864): the
# sp slot at block+544, the frame at block+552, both beneath any call
# chain the block's top can grow — a descent that deep is the overflow
# the block's edge used to swallow. The boot pass anchors in its own
# trap page, the fixed page under the user cells page (0x87ffe000,
# mapped rw without U by every table's kernel half — space.emo's base —
# so it is the supervisor's alone, and the low window reaches it for
# the kernel-side frame accesses). The frame region is scratch while
# the pass runs and the frame while it is stopped — a pass cannot run
# and be stopped at once, so nothing user-side can reach a parked
# frame, and the next trap rewrites every word of it before any is
# read. Clobbers t0..t2 and ra; called where all of those are dead.
    .globl emo_os_anchor_arm
emo_os_anchor_arm:
    la t0, emo_cur_slot
    ld t0, 0(t0)
    ld t1, 8(t0)             # the pass's pid
    li t2, 1
    beq t1, t2, .Lanchor_boot
    ld t0, 864(t0)           # the stack block's base, as the pass runs
                             # on it — the identity of the physical
    j .Lanchor_set
.Lanchor_boot:
    li t0, 0x87ffe000        # the boot pass's own trap page
.Lanchor_set:
    addi t0, t0, 552         # the frame's base: the anchor — the sp slot
                             # sits in the word below it
    csrw sscratch, t0
    ret

# emo_os_trap_resume: the preempted process's landing — entered with
# sp at the interrupted value and the rest of the frame below it. The
# shim's own exit path lands here too. The status and cause registers
# restore through a scratch whose own slot is read last. First the
# arena's restore (T5.1): a frame that srets into U-mode hands its
# process's arena to the user image — cursor and limit through the
# cells the user stub parked — so the user image's own allocator
# charges the pass that is about to run. A frame returning to the
# kernel restores nothing. The slot's words are kernel addresses, the
# cells take the user's (T6.1): the offset comes off on the way down.
# The return home (T6.3): a frame entering U-mode also takes the armed
# anchor (sscratch) and the interrupted sp back — the word below the
# frame — so the trap out of this pass lands in the trampoline's user
# path, on the pass's own frame, whatever sp it was running with.
    .globl emo_os_trap_resume
emo_os_trap_resume:
    ld t0, -400(sp)
    srli t0, t0, 8
    andi t0, t0, 1           # sstatus.SPP: 0 = the frame enters U-mode
    bnez t0, .Lkernel_home
    call emo_os_anchor_arm   # the pass's anchor into sscratch (T6.3):
                             # its next trap out of U-mode lands in the
                             # trampoline's user path, on its own frame
    # satp follows the process home (T6.3): a resume the answer and
    # home paths reach directly rides no pick, and the trampoline left
    # the kernel's table live — the resolve/write pair brings the
    # pass's own table back before the sret, with the cache kept true.
    la t0, emo_cur_slot
    ld t0, 0(t0)
    ld a0, 872(t0)           # the pass's space word
    la t1, emo_space_hook
    ld t1, 0(t1)
    beqz t1, 3f              # no per-process spaces, no table to follow
    jalr t1                  # resolve: the physical root, or -1 when
    bltz a0, 3f              # satp already names it
    la t1, emo_space_write_hook
    ld t1, 0(t1)
    jalr t1                  # the swap, fences included
3:
    li t0, 0x87fff008
    ld t0, 0(t0)             # the user image's arena cursor word
    beqz t0, .Larena_ready   # nothing staged: nothing to hand over
    la t1, emo_cur_slot
    ld t1, 0(t1)
    ld t2, 8(t1)             # the passer's pid
    li t3, 1
    beq t2, t3, .Larena_boot_in
    li t4, EMO_KOFF
    ld t2, 576(t1)
    sub t2, t2, t4           # the passer's cursor, as the user addresses it,
    sd t2, 0(t0)             # becomes the arena's
    li t0, 0x87fff010
    ld t0, 0(t0)             # and the end word beside it
    ld t2, 584(t1)
    sub t2, t2, t4
    sd t2, 0(t0)
    j .Larena_ready
.Larena_boot_in:
    la t2, emo_os_boot_cur
    ld t2, 0(t2)
    sd t2, 0(t0)
    li t0, 0x87fff010
    ld t0, 0(t0)
    la t2, emo_os_boot_lim
    ld t2, 0(t2)
    sd t2, 0(t0)
    j .Larena_ready
.Lkernel_home:
    csrw sscratch, zero      # the sentinel is back: kernel mode from
                             # here, whoever resumes (T6.3)
.Larena_ready:
    ld ra, -544(sp)
    ld gp, -536(sp)
    ld tp, -528(sp)
    ld t2, -504(sp)
    ld t3, -496(sp)
    ld t4, -488(sp)
    ld t5, -480(sp)
    ld t6, -472(sp)
    ld a0, -464(sp)
    ld a1, -456(sp)
    ld a2, -448(sp)
    ld a3, -440(sp)
    ld a4, -432(sp)
    ld a5, -424(sp)
    ld a6, -416(sp)
    ld a7, -408(sp)
    fld ft0, -376(sp)
    fld ft1, -368(sp)
    fld ft2, -360(sp)
    fld ft3, -352(sp)
    fld ft4, -344(sp)
    fld ft5, -336(sp)
    fld ft6, -328(sp)
    fld ft7, -320(sp)
    fld ft8, -312(sp)
    fld ft9, -304(sp)
    fld ft10, -296(sp)
    fld ft11, -288(sp)
    fld fa0, -280(sp)
    fld fa1, -272(sp)
    fld fa2, -264(sp)
    fld fa3, -256(sp)
    fld fa4, -248(sp)
    fld fa5, -240(sp)
    fld fa6, -232(sp)
    fld fa7, -224(sp)
    ld t0, -400(sp)
    li t1, 0x40000
    or t0, t0, t1            # SUM is the kernel's, not the frame's (T6.1):
    csrw sstatus, t0         # every return keeps the user's pages reachable
    ld t0, -392(sp)          # for the next trap's frame — a spawn's synthetic
    csrw sepc, t0            # frame carries a bare sstatus
    ld t1, -400(sp)          # the SPP bit again (t0 and t1 are dead until
    srli t1, t1, 8           # their own restores below): a frame entering
    andi t1, t1, 1           # U-mode takes the interrupted sp back — the
    bnez t1, 2f              # word below its frame, where the trampoline
                             # parked it; a kernel frame IS on the
                             # interrupted sp already, and stays there.
                             # The frame reads all happen while sp is
                             # still the frame's top; the sp itself moves
                             # last, by its own self-relative load.
    ld t0, -520(sp)
    ld t1, -512(sp)
    ld sp, -552(sp)
    sret
2:
    ld t0, -520(sp)
    ld t1, -512(sp)
    sret

# emo_os_user_boot: the kernel's own program is done — the stub calls
# this before the poweroff. The entry word the loader (user.emo) parked
# decides: zero means nothing was staged and the call returns straight
# to the stub's poweroff; anything else is the user's entry, and the
# sret lands in U-mode. The boot pass's own address space (T6.2) comes
# first: the loader built the boot table at stage time and parked its
# physical root in the handoff page's space cell — the runtime takes
# it into the root slot's space word (so the first switch back to the
# boot pass installs the same table), space.emo's cache adopts it (so
# the switch's resolve knows satp already names it), and the satp
# shim performs the switch. From here on every address space is a
# process's own. sstatus keeps what the kernel left but three bits —
# SPP cleared (sret enters U-mode), SPIE set (S-mode interrupts return
# on), FS set Dirty (the floats run). The boot pass's anchor (T6.3) is
# armed before the sret: its first trap out of U-mode lands in the
# trampoline's user path, on its own frame, like every pass's.
    .globl emo_os_user_boot
emo_os_user_boot:
    la t0, emo_os_user_entry
    ld a0, 0(t0)
    beqz a0, 1f
    la t0, emo_os_user_space
    ld a0, 0(t0)
    beqz a0, 2f              # a staged entry always carries its table;
                             # the guard keeps a half-staged handoff
                             # on the old path rather than a fault
    call emo_space_set       # the root slot's word: the boot pass's own
    la t0, emo_os_user_space # (a0 is the caller's to lose across a call,
    ld a0, 0(t0)             # so each call re-reads the cell)
    call emo_space__adopt    # the switch's cache: satp is about to name it
    la t0, emo_os_user_space
    ld a0, 0(t0)
    call emo_os_satp_switch  # the boot pass's table is live
2:  call emo_os_anchor_arm   # sscratch takes the boot pass's anchor —
                             # the image's writable segment end, minus
                             # the frame — before the first sret up
    la t0, emo_os_user_entry
    ld a0, 0(t0)
    csrr t1, sstatus
    andi t1, t1, -257        # SPP = 0: sret enters U-mode
    ori t1, t1, 0x20         # SPIE = 1: S-mode interrupts return on
    li t2, 0xC000
    or t1, t1, t2            # FS = Dirty: the floating point runs
    csrw sstatus, t1
    csrw sepc, a0
    sret
1:  ret

    .section .rodata
msg_unexpected:
    .ascii "the kernel took an unexpected trap"
msg_unexpected_end:

    .section .bss
    .align 8
# The timer's transport, decided once at init: 1 = Sstc is delegated
# and stimecmp is ours, 0 = the legacy SBI set_timer ecall. The probe
# state word sits beside it — 1 while the probe write is in flight,
# 2 once the shim has answered no. Both live in .bss, which the boot
# stub clears before this file's init writes them.
    .globl emo_os_timer_kind
emo_os_timer_kind:
    .zero 8
emo_os_probe_state:
    .zero 8

# The in-flight frame's base (T6.3): both prologues park it — the
# trampoline at the anchor, the shim below the interrupted kernel sp —
# and the shared dispatch reads the frame through this word, never
# through sp, because the two paths run their handler stacks
# differently and the calls below must never write into the word below
# the frame, where the interrupted sp waits for the resume.
    .globl emo_os_trap_frame
emo_os_trap_frame:
    .zero 8

# The trap stack (T6.3): the trampoline's handler runs here — 8 KiB of
# the kernel's own .bss, deep enough for any dispatch, report, or
# scheduler chain the shared body reaches, so no kernel line descends
# through the pass's frame into its memory or off the bottom of its
# block. The shim's path keeps the interrupted kernel stack it always
# ran on.
    .align 16
emo_os_trap_stack:
    .zero 8192
    .globl emo_os_trap_stack_top
emo_os_trap_stack_top:

# The boot pass's arena (T5.1): the kernel's own root is the boot user
# pass — the stub entered it once the kernel's program returned — and
# its arena progress lands here, not in the root slot, whose words
# stay the kernel heap's (the kernel's own root allocates against
# them; a spawn's block comes from the frame allocator, never the
# carve, but the pair keeps the two worlds apart either way).
emo_os_boot_cur:
    .zero 8
emo_os_boot_lim:
    .zero 8

# The tick ring: the ISR's preallocated channel — the producer cursor,
# the consumer cursor, the dropped count, and 64 one-word entries at
# the fixed address the kernel's linker script gives the section. The
# kernel's own Emo code reads it with peek/poke like any device.
    .section .emo_tick, "aw", @nobits
    .globl emo_os_tick_prod
emo_os_tick_prod:
    .zero 8
    .globl emo_os_tick_cons
emo_os_tick_cons:
    .zero 8
    .globl emo_os_tick_drops
emo_os_tick_drops:
    .zero 8
    .globl emo_os_tick_ring
emo_os_tick_ring:
    .zero 512

# The input ring (T3.7): the console interrupt's channel — the
# producer cursor, the consumer cursor, then 128 one-byte entries, in
# its own section at the fixed address the kernel's linker script
# gives it. The trap shim is the only producer; the console process is
# the only consumer; a full ring leaves the bytes in the UART's FIFO
# and the line re-raises.
    .section .emo_in, "aw", @nobits
    .globl emo_os_in_prod
emo_os_in_prod:
    .zero 8
    .globl emo_os_in_cons
emo_os_in_cons:
    .zero 8
    .globl emo_os_in_ring
emo_os_in_ring:
    .zero 128

# The user handoff (T4.1): the boot stub parks the embedded user image's
# bounds in the first two words and zeroes the third; the kernel's Emo
# loader (user.emo) reads the bounds at the same fixed constants, copies
# the segments, and parks the entry; emo_os_user_boot reads the entry
# and srets into U-mode. A zero entry means nothing was staged. The
# space cell (T6.2, at +456) rides beside them: the loader builds the
# boot pass's own page table at stage time and parks its physical root
# there; emo_os_user_boot takes it into the root slot's space word,
# adopts it into the switch's cache, and switches satp before the sret.
    .section .emo_user, "aw", @nobits
    .globl emo_os_handoff_blob
emo_os_handoff_blob:
    .zero 8
    .globl emo_os_handoff_end
emo_os_handoff_end:
    .zero 8
    .globl emo_os_user_entry
emo_os_user_entry:
    .zero 8
# The cells between here and the space cell — the segment count and
# table, the services' pid cells, the request cells, the exit table —
# are addressed by the kernel's fixed constants, not by symbols. The
# space cell sits at +456 (0x870021c8), the first word after the
# pending-wait pair the constants already name.
    .zero 432
    .globl emo_os_user_space
emo_os_user_space:
    .zero 8

# The frame allocator's page (T5.3): the kernel's Emo (frames.emo) owns
# every word — the freelist head, the free and total counts, the
# region's bounds, the take and give tallies, and the claimed bitmap —
# at the fixed address the kernel's linker script gives the section.
# The boot stub builds the freelist through emo_frames__boot; the
# runtime reaches the words only through the allocator's own defs, by
# the block hooks. Named here so the forensics can read them.
    .section .emo_frames, "aw", @nobits
    .globl emo_os_frames_head
emo_os_frames_head:
    .zero 8
    .globl emo_os_frames_free
emo_os_frames_free:
    .zero 8
    .globl emo_os_frames_total
emo_os_frames_total:
    .zero 8
    .globl emo_os_frames_lo
emo_os_frames_lo:
    .zero 8
    .globl emo_os_frames_hi
emo_os_frames_hi:
    .zero 8
    .globl emo_os_frames_taken
emo_os_frames_taken:
    .zero 8
    .globl emo_os_frames_given
emo_os_frames_given:
    .zero 8
    .zero 8                  # padding: the bitmap opens at +64
    .globl emo_os_frames_claimed
emo_os_frames_claimed:
    .zero 64
# The frame freelist (T6.1), at +128: the head, the count, and the
# blocks split so far — the page tables' 4 KiB unit, sixteen off a
# block at a time.
    .globl emo_os_frames_frame_head
emo_os_frames_frame_head:
    .zero 8
    .globl emo_os_frames_frame_free
emo_os_frames_frame_free:
    .zero 8
    .globl emo_os_frames_frame_split
emo_os_frames_frame_split:
    .zero 8
