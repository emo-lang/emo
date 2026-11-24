# The musl body's entry (EmoOS plan B, T2.2): the same kernel handoff
# the C door's `crt0.s` uses — the args base on the cells page, the
# process stack above it, the argc/argv/envp triple — then the static
# TLS block's `tp`, the C `main`, the stdout flush and the gate's exit.
# The BSS clear runs before `__emo_tls_init`: the pthread block and the
# arena's state are `.bss` words.

    .section .text.start, "ax"
    .globl _start
_start:
    la gp, __global_pointer$
    li t0, 0x87fff080
    ld t1, 0(t0)
    mv sp, t1
    ld s0, 0(sp)              # argc
    addi s1, sp, 8            # argv
    slli t0, s0, 3
    add s2, s1, t0
    addi s2, s2, 8            # envp
    andi sp, sp, -16

    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    la t0, __environ
    sd s2, 0(t0)
    call __emo_tls_init

    mv a0, s0
    mv a1, s1
    mv a2, s2
    call main

    mv s0, a0
    li a0, 0
    call fflush
    mv a0, s0
    call emo_exit
3:
    j 3b
