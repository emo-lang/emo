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
    # the disk ELFs' blobs (emo-desktop A11.1): the three apps' images
    # ride beside the boot image, and their bounds go to the handoff
    # page's free tail — the first boot installs them on the volume
    # (the root writes each through the filesystem service when a probe
    # says the file is missing), the boots after find the volume that
    # carries them and exec from the disk
    la t0, emo_os_user_blob_c
    li t1, 0xFFFFFFC0870021d0
    sd t0, 0(t1)
    la t0, emo_os_user_blob_c_end
    sd t0, 8(t1)
    la t0, emo_os_user_blob_f
    li t1, 0xFFFFFFC0870021e0
    sd t0, 0(t1)
    la t0, emo_os_user_blob_f_end
    sd t0, 8(t1)
    la t0, emo_os_user_blob_e
    li t1, 0xFFFFFFC0870021f0
    sd t0, 0(t1)
    la t0, emo_os_user_blob_e_end
    sd t0, 8(t1)
    la t0, emo_os_user_blob_s
    li t1, 0xFFFFFFC087002200
    sd t0, 0(t1)
    la t0, emo_os_user_blob_s_end
    sd t0, 8(t1)
    la t0, emo_os_user_blob_w
    li t1, 0xFFFFFFC087002210
    sd t0, 0(t1)
    la t0, emo_os_user_blob_w_end
    sd t0, 8(t1)
    # the C door's first image (EmoOS plan B, M0): the cross-built
    # program's bounds ride the handoff page's next free pair
    la t0, emo_os_user_blob_x
    li t1, 0xFFFFFFC087002220
    sd t0, 0(t1)
    la t0, emo_os_user_blob_x_end
    sd t0, 8(t1)
    # the emosh shell (T3.2): the same handoff tail, the next free pair
    la t0, emo_os_user_blob_m
    li t1, 0xFFFFFFC087002230
    sd t0, 0(t1)
    la t0, emo_os_user_blob_m_end
    sd t0, 8(t1)
    # dash and its acceptance script (T4.1)
    la t0, emo_os_user_blob_d
    li t1, 0xFFFFFFC087002240
    sd t0, 0(t1)
    la t0, emo_os_user_blob_d_end
    sd t0, 8(t1)
    la t0, emo_os_user_blob_t
    li t1, 0xFFFFFFC087002250
    sd t0, 0(t1)
    la t0, emo_os_user_blob_t_end
    sd t0, 8(t1)
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
    # the arena's run (T8.9): the arena hook goes to frames.emo's
    # take_run — the window buffer's own machinery — and the run's
    # length to the runtime's word beside it, both this stub's writes:
    # a child's arena is a contiguous run of frames.arena_run blocks,
    # claimed in one take at the spawn and walked home block by block
    # at the death, the length never a runtime-side guess.
    la t0, emo_frames__take_run
    la t1, emo_arena_take_hook
    sd t0, 0(t1)
    li t0, 4                    # frames.emo's arena_run: the run the
                                # kernel's own green processes — the
                                # services — are born with. A user pass's
                                # run is its spawn's own (the process
                                # service pokes this word around the
                                # spawn, through the cell parked below)
    la t1, emo_arena_run_len
    sd t0, 0(t1)
    # the tick's slice (T8.21): the root's quota word — the one policy
    # word the machine's preemption rides on. 0 is the unassigned value
    # the ISR's quota step answers dormant, so the stub assigns the
    # root's slice and every child inherits it at the spawn (the spawn's
    # own copy of the parent's policy words); five ticks — 50 ms of the
    # 10 ms tick — the honest round-robin: a busy app keeps the hart no
    # longer than one slice, and a wake it never yields to runs within
    # the next. The quota loads at the pick, so the root's earliest
    # work — everything before its first park's return — runs
    # unassigned; from the first park on, the root shares the discipline
    # with everything it spawns, and a round-robin of one spends its
    # slice on itself.
    la t1, emo_procs
    li t0, 5
    sd t0, 56(t1)
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
    # the death notice (T7.2): the runtime's death hook goes to the
    # shim's routine, which posts a green process's end to the
    # supervisor's mailbox — the filesystem service's restart hangs on
    # it. Zero in every image whose stub leaves it.
    la t0, emo_os_death_notice
    la t1, emo_death_hook
    sd t0, 0(t1)
    # the image give hook (emo-desktop A11.1): an exec's child's death
    # walks its image's run home through exec.emo's def — the pid's
    # image cell names the record, the record the run's base and
    # length. Zero in every image whose stub leaves it.
    la t0, emo_exec__image_home
    la t1, emo_image_give_hook
    sd t0, 0(t1)
    # the signal trampoline (EmoOS plan B, T1.6): the page every user
    # table maps RX with U — a handler's return is this page's
    # sig_return ecall, and the ebreak after it is the loud end of a
    # return no handler entered.
    li t0, EMO_KOFF + 0x87ffd000
    li t1, 0x0000007304000893 # addi a7, x0, 64 then ecall — the
    sd t1, 0(t0)              # sig_return verb, two words
    li t1, 0x00100073        # ebreak — the loud end of a return no
    sd t1, 8(t0)             # handler entered
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
    # the arena run's word, named for the process service (the arena
    # track's answer): the runtime reads its length at every spawn, a
    # user pass's spawn pokes its own run through this cell and puts
    # the services' default back after. The allocator's page keeps the
    # address (frames.emo's arena_len_cell), written here because its
    # boot has just cleared the page.
    la t0, emo_arena_run_len
    li t1, EMO_KOFF + 0x87003158
    sd t0, 0(t1)
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

# emo_user_replace (EmoOS T1.4b3b): the in-place exec. a0 = the pid to
# reuse, a1 = the new image's entry, a2 = the new stack's top (the
# physical address the build maps at its identity), a3 = the new
# arena's run base and a4 its end (kernel addresses). The slot's old
# image, stack, arena and grown blocks go home; the slot is dressed
# with the new stack and arena, its synthetic frame starts the new
# entry, the build hook consumes the staged image record, and the same
# pid is queued. a0 = the pid, or -1 when no slot carries it. Masked
# throughout: the reaps and the build are kernel work, and no pick may
# see the half-dressed slot.
    .section .text
    .globl emo_user_replace
emo_user_replace:
    csrci sstatus, 2
    addi sp, sp, -64
    sd ra, 0(sp)
    sd a0, 8(sp)                # the pid, the answer
    sd a1, 16(sp)               # the entry
    sd a2, 24(sp)               # the stack top, physical
    sd a3, 32(sp)               # the arena run's base, kernel
    sd a4, 40(sp)               # its end, kernel
    sd s0, 48(sp)
    la t0, emo_procs
    li t1, 0
    li t2, 64
.Lur_scan:
    bgeu t1, t2, .Lur_fail
    li t3, 888
    mul t4, t1, t3
    add t4, t0, t4
    ld t5, 8(t4)
    beq t5, a0, .Lur_found
    addi t1, t1, 1
    j .Lur_scan
.Lur_fail:
    li a0, -1
    j .Lur_out
.Lur_found:
    mv s0, t4
    # The old world goes home: the image through the hook, the stack
    # and the arena through the reaper (state 3 is the reaper's gate),
    # the grown blocks through their own walk.
    li t5, 3
    sd t5, 16(s0)
    mv a0, s0
    call emo_arena_reap
    ld a0, 8(sp)
    call emo_space__grow_reap
    # The new arena (T1.3/T8.9): the service's run, claimed, the
    # freelist's head cleared at its end; the old mailbox is empty.
    sd zero, 24(s0)
    sd zero, 32(s0)
    ld t0, 32(sp)
    ld t1, 40(sp)
    sd t0, 576(s0)
    sd t1, 584(s0)
    sd t0, 880(s0)
    li t2, 1
    sd t2, 600(s0)
    sd zero, 592(s0)
    sd zero, -8(t1)
    sd t2, 16(s0)               # alive
    # The synthetic frame at the new stack's bottom: the entry, the
    # stack top, the user-exit return, the resume hook — the spawn's
    # own shape.
    ld t5, 24(sp)
    li t6, 65536
    sub t6, t5, t6
    sd t6, 864(s0)
    addi t4, t6, 552
    mv a0, t4
    addi a1, t4, 552
.Lur_zero:
    sd zero, 0(a0)
    addi a0, a0, 8
    blt a0, a1, .Lur_zero
    sd t5, -8(t4)
    la t1, emo_os_user_exit
    sd t1, 0(t4)
    ld t0, 16(sp)
    li t1, 0x6020               # SPIE, SPP clear, FS dirty
    sd t1, 144(t4)
    sd t0, 152(t4)
    ld t1, emo_trap_resume_hook
    sd t1, 336(t4)
    sd zero, 536(t4)
    addi t4, t4, 336
    sd t4, 0(s0)
    # The child's table: the build hook consumes the staged record and
    # writes the new root into the slot's space word.
    la t4, emo_space_build_hook
    ld t4, 0(t4)
    beqz t4, .Lur_nospace
    mv a0, s0
    jalr t4
.Lur_nospace:
    mv a0, s0
    call emo_runq_push
    ld a0, 8(sp)
.Lur_out:
    ld s0, 48(sp)
    ld ra, 0(sp)
    addi sp, sp, 64
    csrsi sstatus, 2
    ret
