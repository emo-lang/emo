# The EmoOS boot stub: the package owns its image (T3.1). The standard
# boot discipline — park the non-boot harts, clear .bss, set the stack
# — plus the console hook (T3.5): after the clear, the raw entry of the
# fully typed Emo def console_put_byte (its label carries the root
# module's prefix) is parked in the runtime's emo_console_hook, so
# every console byte the runtime emits rides the 16550A polling driver
# in main.emo instead of the SBI console ecalls. SBI stays for
# poweroff.

    .section .text
    .globl emo_start
emo_start:
    bnez a0, emo_park
    la sp, emo_stack_top
    la t0, __emo_bss_start
    la t1, __emo_bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    la t0, emo_main__console_put_byte
    la t1, emo_console_hook
    sd t0, 0(t1)
    call emo_runtime_init
    call emo_program
    li a7, 8
    ecall
emo_park:
    wfi
    j emo_park
