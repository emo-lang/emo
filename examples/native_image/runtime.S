# The package-provided boot stub: the image's entry discipline is the
# package's own. This one marks the free RAM above the heap with the
# package's magic, records the address of extra.S's word and the linker
# script's mark for the program to read back, then runs the standard
# boot — park the non-boot harts, clear .bss, set the stack, initialize
# the heap cursor, run the program, and power off through SBI.

    .section .text
    .globl emo_start
emo_start:
    bnez a0, emo_park
    li t0, 0x87000000
    li t1, 0x12345678
    sd t1, 0(t0)
    la t1, extra_word
    sd t1, 8(t0)
    la t1, emo_image_mark
    sd t1, 16(t0)
    la sp, emo_stack_top
    la t0, __emo_bss_start
    la t1, __emo_bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    call emo_runtime_init
    call emo_program
    li a7, 8
    ecall
emo_park:
    wfi
    j emo_park
