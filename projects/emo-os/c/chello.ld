/* The C user image's layout (EmoOS plan B, M0): the Emo user image's
   own window, 0x87100000 … 0x88000000, which exec.emo's measure
   enforces. Two PT_LOAD segments — text RX, data RW — the entry the
   first text byte, the .bss tail left to crt0's zeroing. The
   attributes and unwind tables are no image's business here. */

OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x87100000;

  .text : {
    *(.text.start)
    *(.text .text.*)
  } :text

  .rodata : {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  } :text

  . = ALIGN(4096);
  __global_pointer$ = . + 0x800;

  .data : {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } :data

  .bss : {
    . = ALIGN(16);
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } :data

  /DISCARD/ : {
    *(.eh_frame .eh_frame_hdr)
    *(.note .note.*)
    *(.comment)
    *(.riscv.attributes)
  }
}
