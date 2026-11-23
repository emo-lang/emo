# fork (EmoOS plan B, T1.4b2): the parent's callee-saved context on its
# stack, the ecall that asks the kernel to clone the address space, and
# the child's way home. The child starts at emo_fork_resume with every
# register zero and the stack top the spawn handed it — it reloads the
# parent's gp, moves sp to the saved context on the copied stack, and
# returns through the same epilogue as the parent, with a0 = 0. The
# context is the callee-saved integer state (ra, s0..s11), the
# callee-saved floating-point state (fs0..fs11) and fcsr.

    .text
    .globl fork
    .type fork, @function
fork:
    addi sp, sp, -224
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd s6, 56(sp)
    sd s7, 64(sp)
    sd s8, 72(sp)
    sd s9, 80(sp)
    sd s10, 88(sp)
    sd s11, 96(sp)
    fsd fs0, 104(sp)
    fsd fs1, 112(sp)
    fsd fs2, 120(sp)
    fsd fs3, 128(sp)
    fsd fs4, 136(sp)
    fsd fs5, 144(sp)
    fsd fs6, 152(sp)
    fsd fs7, 160(sp)
    fsd fs8, 168(sp)
    fsd fs9, 176(sp)
    fsd fs10, 184(sp)
    fsd fs11, 192(sp)
    frcsr t0
    sd t0, 200(sp)
    mv a0, sp
    la a1, emo_fork_resume
    call emo_fork_call

.Lfork_return:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    ld s5, 48(sp)
    ld s6, 56(sp)
    ld s7, 64(sp)
    ld s8, 72(sp)
    ld s9, 80(sp)
    ld s10, 88(sp)
    ld s11, 96(sp)
    fld fs0, 104(sp)
    fld fs1, 112(sp)
    fld fs2, 120(sp)
    fld fs3, 128(sp)
    fld fs4, 136(sp)
    fld fs5, 144(sp)
    fld fs6, 152(sp)
    fld fs7, 160(sp)
    fld fs8, 168(sp)
    fld fs9, 176(sp)
    fld fs10, 184(sp)
    fld fs11, 192(sp)
    ld t0, 200(sp)
    fscsr t0
    addi sp, sp, 224
    ret
    .size fork, .-fork

    .globl emo_fork_resume
emo_fork_resume:
    la gp, __global_pointer$
    li t0, 0x87fff090
    ld sp, 0(t0)
    li a0, 0
    j .Lfork_return
