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
    # The kernel's first stack (T1.4a): the args base on the cells
    # page, the runtime's stack top above it; the sp moves to the
    # args, argc at it, argv at sp + 8, the envp's NULL after the
    # argv's. The pointers are read before the alignment; main gets
    # the triple, its callee-saved frame below.
    li t0, 0x87fff080
    ld t1, 0(t0)
    mv sp, t1
    ld a0, 0(sp)
    addi a1, sp, 8
    slli t0, a0, 3
    add a2, a1, t0
    addi a2, a2, 8
    andi sp, sp, -16

    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    # The library's environ (T1.4b1): the main's envp, before the call.
    la t0, environ
    sd a2, 0(t0)
    call main

    li a7, 0          # exit(code)
    ecall
3:
    j 3b
