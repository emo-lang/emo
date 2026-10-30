OUTPUT_ARCH(riscv)

/* The kernel's high-half layout (T6.1): every kernel virtual address is
   its physical address plus KOFF, the base of Sv39's high half — so the
   image links at the high alias of the load address OpenSBI enters, and
   every section's LMA (where QEMU loads it, where the boot stub runs
   until satp is on) stays physical. The stub builds its three-entry
   boot table at the physical alias, turns satp on, and jumps up; the
   Emo-built kernel table (sv39.emo) takes over before the program. */
KOFF = 0xFFFFFFC000000000;
LOAD = 0x80200000;

/* The ELF entry is the physical alias of the stub — QEMU enters at the
   image's load address regardless, so the stub also opens .text. */
ENTRY(emo_entry)
emo_entry = emo_start - KOFF;

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
  tick PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = KOFF + LOAD;

  /* The permission boundaries the kernel's own table draws are page
     boundaries: text RX, rodata R, data and bss RW. */
  .text : AT(ADDR(.text) - KOFF) {
    *(.text.boot)
    *(.text .text.*)
    /* The trampoline page (T6.3): the trap entry, alone on its own
       page-aligned page at the end of the text — the one page every
       address space maps (map_kernel's text RX) that the crossing
       through satp may touch before the swap. */
    . = ALIGN(4096);
    *(.emo_tramp)
    . = ALIGN(4096);
    __emo_text_end = .;
  } :text
  .rodata : AT(ADDR(.rodata) - KOFF) {
    *(.rodata .rodata.*)
    . = ALIGN(4096);
    __emo_rodata_end = .;
  } :text
  .data : AT(ADDR(.data) - KOFF) { *(.data .data.*) } :data

  .bss : AT(ADDR(.bss) - KOFF) {
    . = ALIGN(16);
    __emo_bss_start = .;
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    __emo_bss_end = .;
  } :data

  /* The tick ring (T3.6) at its fixed address, in the free RAM above
     the image's 96 MiB heap and under the top of the board's 128 MiB:
     the kernel's own Emo code reads it with peek/poke like a device,
     and the trap shim reaches it by symbol. NOBITS — the image
     carries none of it; the init writes the cursors. */
  . = KOFF + 0x87000000;
  .emo_tick (NOLOAD) : AT(ADDR(.emo_tick) - KOFF) { *(.emo_tick) } :tick

  /* The input ring (T3.7) at its own fixed address, a page above the
     tick ring: the trap shim fills it from the UART's receive FIFO
     and the console process drains it through peek/poke. */
  . = KOFF + 0x87001000;
  .emo_in (NOLOAD) : AT(ADDR(.emo_in) - KOFF) { *(.emo_in) } :tick

  /* The user handoff page (T4.1), a page above the input ring: the
     boot stub parks the embedded user image's bounds and zeroes the
     staged entry; the kernel's Emo loader (user.emo) reads the bounds
     at the same fixed constants and parks the entry; emo_os_user_boot
     reads the entry and srets into U-mode. */
  . = KOFF + 0x87002000;
  .emo_user (NOLOAD) : AT(ADDR(.emo_user) - KOFF) { *(.emo_user) } :tick

  /* The frame allocator's page (T5.3), a page above the handoff page:
     the freelist head, the counts, the region's bounds, and the
     claimed bitmap — the kernel's Emo (frames.emo) reads and writes it
     through peek/poke, and the free RAM it hands out lies between the
     image's end and the tick ring's page. NOLOAD — the boot stub's
     emo_frames__boot builds the freelist. */
  . = KOFF + 0x87003000;
  .emo_frames (NOLOAD) : AT(ADDR(.emo_frames) - KOFF) { *(.emo_frames) } :tick

  /* The Sv39 page (T6.1), a page above the allocator's: the kernel's
     root table and the satp the stub read back after the switch — the
     kernel's Emo (sv39.emo) writes the first, the stub the second, the
     program's own check reads both. */
  . = KOFF + 0x87004000;
  .emo_sv39 (NOLOAD) : AT(ADDR(.emo_sv39) - KOFF) { *(.emo_sv39) } :tick

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .note .comment) }
}
