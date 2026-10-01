/* ============================================================================
 * link.ld —— RT-Thread 的链接脚本（32KB 统一存储器）
 * ----------------------------------------------------------------------------
 * 存储器布局（与 runtime/link.ld、scripts/coremark_port/link.ld 同一套规则）：
 *
 *   0x0000  ┌──────────────┐
 *           │  .text       │  代码
 *   0x1000  ├──────────────┤
 *           │  .rodata     │  常量
 *           │  .data       │  已初始化数据
 *           │  .bss        │  未初始化数据
 *   _end    ├──────────────┤
 *           │  堆          │  rt_system_heap_init(_end, __heap_end)
 *   0x7000  ├──────────────┤
 *           │  栈 / 中断栈  │  向下生长
 *   0x7FF0  └──────────────┘  __stack_top = __rt_rvstack
 *   (0x7FF0~0x7FFF 是兼容区 MMIO，被占用，栈顶绝不能越过)
 *
 * [!] 三条硬约束，改这个文件前先读：
 *   1. 栈顶必须 <= 0x7FF0。0x7FF0~0x7FFF 是 CoreMark 兼容区（0x7FF4 周期计数器 /
 *      0x7FF8 done / 0x7FFC UART），RAM 实际只能用到 0x7FEF。
 *   2. __rt_rvstack 必须存在。libcpu/risc-v/common/context_gcc.S 的
 *      rt_hw_context_switch_to 会 `la t0, __rt_rvstack` 并写进 mscratch ——
 *      它同时是「开机引导栈顶」和「中断栈顶」。少这个符号会链接失败。
 *   3. 堆和栈不能重叠。中间那段 0x1000~0x7000 是留给代码 + 数据 + 堆的，
 *      代码一大，堆就小；堆不够用时先裁 rtconfig.h（关组件），别去动栈。
 * ==========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

/* 栈顶：__rt_rvstack 与 __stack_top 是同一个位置（栈向下生长） */
__stack_top = 0x7FF0;
PROVIDE(__rt_rvstack = __stack_top);
PROVIDE(__stack_bottom = 0x7000);
PROVIDE(__heap_end = 0x7000);

SECTIONS
{
  . = 0x0;

  /* 中断入口 SW_handler 在 .text.entry 段里，必须放在最前面且 4 字节对齐 ——
   * mtvec 只有 direct 模式，写进去的是 {addr[31:2], 2'b00}，不对齐会跳飞。 */
  .text.init : { *(.text.init) *(.text.startup) }
  . = ALIGN(4);
  .text : {
    *(.text.entry)
    *(.text .text.*)
  }

  . = ALIGN(0x1000);
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  . = ALIGN(4);
  .data   : { *(.data .data.* .sdata .sdata.*) }

  . = ALIGN(8);
  .bss : {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.*)
    *(COMMON)
    . = ALIGN(8);
    _bss_end = .;
  }

  _end = .;
  PROVIDE(end = .);

  /* RT-Thread small mem 用得到堆的起止（board.c 里传给 rt_system_heap_init） */
  PROVIDE(__heap_start = _end);

  /DISCARD/ : {
    *(.comment)
    *(.note.*)
    *(.eh_frame)
    *(.riscv.attributes)
  }
}
