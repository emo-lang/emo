# The kernel's trap machinery (T3.6): the stvec entry shim, the full
# trap frame, and the timer. The boot stub calls emo_os_trap_init once
# before the program runs — it probes the SBI for the Sstc extension,
# sets stvec, enables the supervisor timer interrupt, and arms the
# first deadline — and parks emo_os_trap_resume in the runtime's
# emo_trap_resume_hook, the address a preempted process resumes at.
#
# The frame the shim lays down on the interrupted process's own stack
# (544 bytes, below the interrupted sp) is two sections: the top 208
# bytes are shaped exactly like the scheduler's context frame — that is
# what makes preemption a context switch, emo_sched_preempt points the
# victim's slot at it — and the rest sits below, read by the resume
# stub through negative offsets once the scheduler's pop has brought
# sp back to the interrupted value. The ISR discipline (T3.6): no
# allocation — the shim and everything it calls are assembly over
# fixed words; the tick ring is preallocated at a fixed address the
# kernel's linker script owns; ack (re-arm), enqueue (the ring), wake
# (the scheduler: the quota step, then the preemption).

    .section .text

# emo_os_trap_init: vector, probe, enables, first deadline. The probe
# is the capability itself: Sstc is an ISA delegation, not an SBI
# extension, so nothing can be asked — the first stimecmp write either
# works or traps as an illegal instruction, and the shim answers it
# (the state word to 2, sepc past the failed write, sret home). The
# probing window is the three instructions around the write; no other
# illegal instruction can land inside it.
    .globl emo_os_trap_init
emo_os_trap_init:
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_os_trap_shim
    csrw stvec, t0
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
    li t0, 32               # sie.STIE
    csrs sie, t0
    csrsi sstatus, 2        # SIE on
    call emo_os_timer_rearm
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

# The trap frame, from the interrupted sp S down: 544 bytes. The rest
# section (336 bytes, offsets 0..335) holds everything the scheduler's
# context frame does not; the switch section (336..543) matches
# emo_schedule's frame — ra, s0-s11, fs0-fs11, and the spare word that
# records the mask (here: the pre-trap SIE, from sstatus.SPIE).
# emo_sched_preempt points the victim's slot at S-208 (offset 336),
# and the resume stub — entered with sp back at S after the scheduler's
# pop — reads the rest section through negative offsets.

# emo_os_trap_shim: stvec lands here. Everything the interrupted code
# owns is saved before a bit of it is clobbered; the dispatch is
# scause's: the supervisor timer interrupt runs the discipline, and any
# other trap is the loud failure.
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
    ld t1, 144(sp)
    srli t1, t1, 5
    andi t1, t1, 1
    sd t1, 536(sp)           # the spare word: the pre-trap SIE
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
    # dispatch on scause: the supervisor timer interrupt, the probe's
    # illegal-instruction answer, or the loud failure for anything else
    ld t0, 160(sp)
    bgez t0, .Ltrap_exc      # bit 63 clear: an exception
    slli t0, t0, 1           # drop the interrupt bit
    li t1, 10                # cause 5, shifted
    beq t0, t1, .Ltrap_timer
    j .Ltrap_bad
.Ltrap_exc:
    li t1, 2                 # illegal instruction — the probe's answer?
    bne t0, t1, .Ltrap_bad
    la t2, emo_os_probe_state
    ld t3, 0(t2)
    li t4, 1
    bne t3, t4, .Ltrap_bad
    li t3, 2
    sd t3, 0(t2)             # no stimecmp: the legacy transport it is
    ld t0, 152(sp)
    addi t0, t0, 4           # sepc past the failed write
    sd t0, 152(sp)
    addi sp, sp, 544
    j emo_os_trap_resume
.Ltrap_timer:
    call emo_os_timer_rearm
    # enqueue the tick: the ISR is the ring's only producer, the entry
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
    addi a0, sp, 336         # the victim's switch-section base
    call emo_sched_preempt
.Ltrap_home:
    addi sp, sp, 544         # sp back to the interrupted value; the
    j emo_os_trap_resume     # frame now reads through negative offsets

.Ltrap_bad:
    la a0, msg_unexpected
    la a1, msg_unexpected_end
    call emo_fail

# emo_os_trap_resume: the preempted process's landing — entered with
# sp at the interrupted value and the rest of the frame below it. The
# shim's own exit path lands here too. The status and cause registers
# restore through a scratch whose own slot is read last.
    .globl emo_os_trap_resume
emo_os_trap_resume:
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
    csrw sstatus, t0
    ld t0, -392(sp)
    csrw sepc, t0
    ld t0, -520(sp)
    ld t1, -512(sp)
    sret

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
