OUTPUT_ARCH(riscv)
ENTRY(emo_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
  tick PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x80200000;

  .text : { *(.text .text.*) } :text
  .rodata : { *(.rodata .rodata.*) } :text
  .data : { *(.data .data.*) } :data

  .bss : {
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
  . = 0x87000000;
  .emo_tick (NOLOAD) : { *(.emo_tick) } :tick

  /* The input ring (T3.7) at its own fixed address, a page above the
     tick ring: the trap shim fills it from the UART's receive FIFO
     and the console process drains it through peek/poke. */
  . = 0x87001000;
  .emo_in (NOLOAD) : { *(.emo_in) } :tick

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .note .comment) }
}
