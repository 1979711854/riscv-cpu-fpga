OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x0;
  .text.init : { *(.text.init) *(.text.startup) }
  . = ALIGN(4);
  .text : { *(.text) *(.text.*) }

  . = ALIGN(0x1000);
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data   : { *(.data .data.* .sdata .sdata.*) }
  .bss    : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
  _end = .;
  _bss_start = ADDR(.bss);

  _stack_top = 0xF000;
  _tohost    = 0xFFF8;
}
