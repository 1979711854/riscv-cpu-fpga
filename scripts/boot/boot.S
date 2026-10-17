/* ============================================================================
 * boot.S —— 0 级 boot selector（128KB 单一位流的复位入口）
 * ----------------------------------------------------------------------------
 * 为什么要有它：官方答疑第 53 问（R99）明确「跑分和应用必须是**同一个 bit 流**」。
 * 我们的做法是一颗位流里同时驻留 CoreMark 与 RT-Thread 五子棋，复位后由按键选路
 * （决策见 doc/reports/2026-10-17_qa_compliance.md §3.1 / §8.1 D1）。
 *
 * 行为（上电/复位后 PC = 0x0）：
 *   读 GPIO（0x8000_0000）的 **key[2]**（板上丝印 **SW6**，低有效）：
 *     按住（= 0）  → 跳 0x1000   CoreMark 跑分档
 *     松开（= 1）  → 跳 0x10000  RT-Thread + 五子棋演示档
 *
 * 按键位置来自 rtl/top/cpu_top_board.v 的注释与 doc/board_bringup.md §2：
 *   key[0]=SW4  key[1]=SW5  key[2]=SW6  key[3]=SW7（SW3 是复位）
 *   GPIO 读回格式 = {16'b0, key[7:0], led[7:0]} ⇒ key[2] 是 **bit 10**。
 *
 * [!] 三个容易写错的点：
 *   1. 按键**低有效** —— 判"按下"要判 bit 为 0，不是 1。
 *   2. 不要只读一次就跳：上电极性建立 + 手指按下的先后差几十 ms。
 *      这里连采 3 次（每次间隔约 0.5 ms @76.5MHz），三次都读到 0 才算按住，
 *      任一次读到 1 就按"松开"处理 —— 松开是默认档（RT-Thread），失败方向安全。
 *   3. 复位后 **不能**先开栈/清 bss 再跳：两个程序的 .bss 覆盖的范围不同
 *      （CoreMark 0x1000~0xF000，RT-Thread 0x10000~0x1FFF0），
 *      选路必须在**任何写内存之前**完成，否则会把对方还没跑的数据区清掉。
 *      所以本文件只做「读 GPIO / 延时 / 跳转」，不用栈、不碰 RAM。
 *
 * 体积约束：0x0~0xFFF（4KB），链接脚本里有 ASSERT。
 * ==========================================================================*/

    .option norvc                 # 本 CPU 没有 RVC，别让汇编器塞压缩指令
    .section .text.init
    .globl _start
    .type _start, @function
_start:
    li   t0, 0x80000000          # GPIO_BASE（见 rtl/bus/addr_map.vh）
    li   t1, 0x00000400          # key[2] = bit 10
    li   t2, 3                   # 采样次数
    li   t3, -1                  # 三次采样的按位与：只要有一次是 1 就当"没按住"

1:  lw   t4, 0(t0)               # 读 {16'b0, key[7:0], led[7:0]}
    and  t4, t4, t1              # 只看 key[2]
    and  t3, t3, t4

    /* 约 0.5 ms 的间隔（@76.5MHz，按 ~2 拍/次估算 20000 次 ≈ 4 万拍）。
     * 用简单的倒计数循环而不是读 timer：timer 在 0x8000_0010，一样能读，
     * 但这里是选路阶段，越少依赖外设越好。 */
    li   t5, 20000
2:  addi t5, t5, -1
    bnez t5, 2b

    addi t2, t2, -1
    bnez t2, 1b

    /* t3 == 0 ⇒ 三次都是按下 ⇒ CoreMark；否则 RT-Thread */
    li   t0, 0x10000             # RT-Thread + 五子棋（默认档）
    bnez t3, 3f
    li   t0, 0x1000              # CoreMark（见 scripts/coremark_port/link.ld）
3:  jr   t0                     # 直接跳，不返回
    .size _start, . - _start
