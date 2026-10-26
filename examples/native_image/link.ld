OUTPUT_ARCH(riscv)
ENTRY(emo_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

/* The image's mark: an absolute symbol the boot stub reads and the
   program sees through raw memory — only this package's script defines
   it, so the value in RAM is proof this script linked the image. */
emo_image_mark = 0x87000010;

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

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .note .comment) }
}
