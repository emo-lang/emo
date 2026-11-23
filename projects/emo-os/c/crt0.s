# The C program's entry (EmoOS plan B, M0): the kernel's exec loader
# copies the ELF's PT_LOAD file bytes and leaves the .bss tail alone,
# so the first act is the zeroing the Emo entry stub also does. The
# stack is the process stack the kernel built; the ABI's alignment is
# restored and the C main runs. Its return value is the exit verb's
# code — the gate's verb 0, the only crossing this stub knows.

    .section .text.start, "ax"
    .globl _start
_start:
    la gp, __global_pointer$
    andi sp, sp, -16

    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    call main

    li a7, 0          # exit(code)
    ecall
3:
    j 3b
