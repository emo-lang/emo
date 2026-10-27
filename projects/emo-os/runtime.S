# The EmoOS boot stub: the package owns its image (T3.1). The standard
# boot discipline — park the non-boot harts, clear .bss, set the stack
# — plus the console hook (T3.5): after the clear, the raw entry of the
# fully typed Emo def console_put_byte (its label carries the root
# module's prefix) is parked in the runtime's emo_console_hook, so
# every console byte the runtime emits rides the 16550A polling driver
# in main.emo instead of the SBI console ecalls. Then the trap
# machinery (T3.6): the resume stub's address is parked in the
# runtime's emo_trap_resume_hook and emo_os_trap_init arms the timer
# under the shim's vector. SBI stays for poweroff.

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
    # the user handoff (T4.1): the embedded user image's bounds go to
    # the handoff page, the staged entry starts zeroed — nothing enters
    # user mode unless the kernel's loader (user.emo) stages it
    la t0, emo_os_user_blob
    la t1, emo_os_handoff_blob
    sd t0, 0(t1)
    la t0, emo_os_user_blob_end
    sd t0, 8(t1)
    sd zero, 16(t1)
    # the service handoff (T4.4): the spawn stacks grow down from
    # 0x87e00000 (above the user image, under the board's top); the
    # service pids and the caller cell start zeroed, filled by the
    # kernel's own boot flow. The spawned process's entry is the user
    # image's own business — its stub parks it in the user cell.
    li t1, 0x87002100
    li t0, 0x87e00000
    sd t0, 0(t1)
    sd zero, -16(t1)
    sd zero, -8(t1)
    sd zero, 16(t1)
    la t0, emo_main__console_put_byte
    la t1, emo_console_hook
    sd t0, 0(t1)
    # the trap machinery (T3.6): the resume stub's address goes to the
    # runtime's hook, then the init probes the timer, sets stvec, and
    # arms the first deadline — all before the program runs
    la t0, emo_os_trap_resume
    la t1, emo_trap_resume_hook
    sd t0, 0(t1)
    call emo_os_trap_init
    call emo_runtime_init
    call emo_program
    # the kernel's program is done: enter the staged user image (T4.1) —
    # or come straight back when none was staged — then the poweroff
    call emo_os_user_boot
    li a7, 8
    ecall
emo_park:
    wfi
    j emo_park
