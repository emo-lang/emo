# The EmoOS boot stub: the package owns its image (T3.1). The standard
# boot discipline — park the non-boot harts, clear .bss, set the stack
# — then Sv39 (T6.1): the kernel links in the high half (link.ld —
# every kernel address is the physical one plus KOFF), so the stub runs
# at the physical alias only long enough to clear .bss and lay down the
# boot table: three gigapage entries — RAM at identity, so the
# instructions after the satp write keep fetching; RAM and the MMIO at
# the high alias, enough for the Emo that builds the kernel's own table
# — then turns satp on and jumps up. Everything from there is the high
# half: the console hook (T3.5) — the raw entry of the fully typed Emo
# def console_put_byte parked in the runtime's emo_console_hook, so
# every console byte rides the 16550A polling driver in main.emo
# instead of the SBI console ecalls; the trap machinery (T3.6) — the
# resume stub's address parked in emo_trap_resume_hook and
# emo_os_trap_init arming the timer under the shim's vector; the frame
# allocator (T5.3) — the block hooks pointing at frames.emo's take and
# give, its init building the freelist over the free RAM above this
# image; and the kernel's own table (sv39.emo) — built in Emo over the
# allocator's frames, switched to through the shim, SUM set so the
# kernel reaches the user's pages. SBI stays for poweroff.

    .set EMO_KOFF, 0xFFFFFFC000000000

    .section .text.boot
    .globl emo_start
emo_start:
    bnez a0, emo_park
    la sp, emo_stack_top     # `la` is PC-relative: at the physical alias
    la t0, __emo_bss_start   # every symbol answers its physical address
    la t1, __emo_bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    # the boot table (T6.1): a PTE is PPN << 10 | flags, and a leaf in
    # the root is a gigapage. V|R|W|X|A|D = 0xcf for RAM, V|R|W|A|D =
    # 0xc7 for the MMIO. The page itself is .bss the clear just zeroed.
    la t0, emo_os_boot_root
    li t2, 2048
    add t2, t0, t2           # the root's upper half: entry 256
    li t1, 0x80000000
    srli t1, t1, 12
    slli t1, t1, 10
    ori t1, t1, 0xcf
    sd t1, 16(t0)            # root[2]: RAM at identity — this code's next fetches
    sd t1, 16(t2)            # root[258]: RAM at the high alias
    li t1, 0xc7
    sd t1, 0(t2)             # root[256]: the MMIO at the high alias
    srli t0, t0, 12
    li t1, 1
    slli t1, t1, 63          # MODE 8: Sv39, ASID 0
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero
    la t0, .Lhigh
    li t1, EMO_KOFF
    add t0, t0, t1
    jr t0                    # up into the high half
.Lhigh:
    la sp, emo_stack_top     # the same stack, by its kernel address
    # the user handoff (T4.1): the embedded user image's bounds go to
    # the handoff page, the staged entry starts zeroed — nothing enters
    # user mode unless the kernel's loader (user.emo) stages it
    la t0, emo_os_user_blob
    la t1, emo_os_handoff_blob
    sd t0, 0(t1)
    la t0, emo_os_user_blob_end
    sd t0, 8(t1)
    sd zero, 16(t1)
    # the service handoff (T4.4): the service pids and the caller cell
    # start zeroed, filled by the kernel's own boot flow. The spawned
    # process's entry is the user image's own business — its stub parks
    # it in the user cell.
    li t1, EMO_KOFF + 0x87002100
    sd zero, -16(t1)
    sd zero, -8(t1)
    sd zero, 16(t1)
    la t0, emo_main__console_put_byte
    la t1, emo_console_hook
    sd t0, 0(t1)
    # the frame allocator (T5.3): the block hooks' raw entries go to the
    # runtime's two words — from here on every block a spawn claims (an
    # arena, a user process's stack) and every death returns is the
    # kernel's frames.emo, the freelist over the free RAM between this
    # image's end and the tick ring's page. Its boot builds the freelist
    # after the runtime's own init, before the program's first spawn.
    la t0, emo_frames__take
    la t1, emo_block_take_hook
    sd t0, 0(t1)
    la t0, emo_frames__give
    la t1, emo_block_give_hook
    sd t0, 0(t1)
    # the address spaces (T6.2): the three space hooks go to the
    # runtime's words — the build (a spawned pass's table, built at the
    # end of emo_user_spawn from the slot's own words), the resolve (the
    # pick's switch: the incoming slot's word to the physical root satp
    # should name, or -1 when it already does), and the write (the satp
    # switch itself). Zero in every image whose stub leaves them — the
    # plain programs and the user image never touch satp; here every
    # switch and every spawn drives the per-process tables.
    la t0, emo_space__build
    la t1, emo_space_build_hook
    sd t0, 0(t1)
    la t0, emo_space__switch
    la t1, emo_space_hook
    sd t0, 0(t1)
    la t0, emo_os_satp_switch
    la t1, emo_space_write_hook
    sd t0, 0(t1)
    # the trap machinery (T3.6): the resume stub's address goes to the
    # runtime's hook, then the init probes the timer, sets stvec, and
    # arms the first deadline — all before the program runs
    la t0, emo_os_trap_resume
    la t1, emo_trap_resume_hook
    sd t0, 0(t1)
    call emo_os_trap_init
    call emo_runtime_init
    la a0, __emo_bss_end
    call emo_frames__boot
    # the kernel's own table (T6.1): sv39.emo maps the image by its
    # permission boundaries, the rest of the RAM, the devices, and the
    # window the user still runs in, over frames the allocator hands
    # out; the shim switches satp to it and answers what it wrote, kept
    # on the Sv39 page for the program's own check. SUM then lets the
    # kernel read and write the user's pages — the gate's buffers, the
    # loader's copies, the trap frames on a user stack.
    la a0, __emo_text_end
    la a1, __emo_rodata_end
    call emo_sv39__boot      # a0 = the root's physical address
    call emo_os_satp_switch  # a0 = the satp written
    la t1, emo_os_sv39_satp
    sd a0, 0(t1)
    li t0, 0x40000
    csrs sstatus, t0         # SUM
    call emo_program
    # the kernel's program is done: enter the staged user image (T4.1) —
    # or come straight back when none was staged — then the account
    # (T5.3) and the poweroff
    call emo_os_user_boot
    call emo_frames__report
    li a7, 8
    ecall
emo_park:
    wfi
    j emo_park

# The boot table's root (T6.1): one page of .bss, the three gigapage
# entries written above, live only until the kernel's own table
# replaces it. Nothing refers to it after the switch.
    .section .bss
    .balign 4096
emo_os_boot_root:
    .zero 4096
