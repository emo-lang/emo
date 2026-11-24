# The self-hosted link's entry (T4.5): the C door's handoff and BSS
# clear, but the bounds the TCC linker knows — `__bss_start` at this
# object's own .bss and `_end` at the image's tail. The wrapper's
# `emo.ld` defines neither, so this crt is TCC's alone.

    .section .text.start, "ax"
    .globl _start
_start:
    la gp, __global_pointer$
    li t0, 0x87fff080
    ld t1, 0(t0)
    mv sp, t1
    ld s0, 0(sp)
    addi s1, sp, 8
    slli t0, s0, 3
    add s2, s1, t0
    addi s2, s2, 8
    andi sp, sp, -16

    la t0, _edata
    la t1, _end
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

    .globl __bss_start
    .set __bss_start, _edata
