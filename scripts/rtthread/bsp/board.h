/* ============================================================================
 * board.h —— 本板（盘古 MES2L676-200HP）的板级定义
 * ----------------------------------------------------------------------------
 * 地址来自 rtl/bus/addr_map.vh（SoC 唯一真相）。改地址必须三处同步：
 *   1. rtl/bus/addr_map.vh
 *   2. scripts/demo/addr_map.h
 *   3. 本文件
 * ==========================================================================*/
#ifndef __BOARD_H__
#define __BOARD_H__

/* ---- 板上时钟：49.8927 MHz（板载 27MHz 经 PLL 倍频，RATIO0=23）----
 * 只用于延时换算和注释；RT-Thread 的 tick 由 mtimecmp 决定，不依赖这个数。 */
#define BOARD_SYSTEM_CLOCK_HZ       49892700u

/* ---- 外设 MMIO（字地址，直接读写）-------------------------------------- */
#define MMIO_GPIO_BASE              0x80000000u  /* W LED[7:0] / R {key[7:0], led[7:0]} */
#define MMIO_UART_TX                0x80000008u  /* W 发一个字符 */
#define MMIO_UART_RX                0x8000000Cu  /* R {valid, 23'b0, data[7:0]}，读清 valid */
#define MMIO_MTIME                  0x80000010u  /* R 周期计数器 [31:0] */
#define MMIO_MTIMECMP               0x80000014u  /* W/R 定时器比较值 */

/* ---- 兼容区（CoreMark 硬编码，不可移动；栈顶必须避开 0x7FF0 以上）---- */
#define MMIO_LEGACY_CYCLE           0x00007FF4u
#define MMIO_LEGACY_DONE            0x00007FF8u
#define MMIO_LEGACY_UART_TX         0x00007FFCu

/* ---- 中断号：RT-Thread 的 irq_id = mcause & 0x1F ----
 * 本 CPU 只产生两种中断：
 *   MTIP（mcause = 0x8000_0007）→ irq_id 7   ← 系统 tick 用它
 *   MEIP（mcause = 0x8000_000B）→ irq_id 11  ← 外部中断（UART RX 非空），
 *                                              [！] 通路具备但本工程未使用、无测试
 * 参考：rtl/core/csr_file.v 的 mip/mie 只实现 MTIP(bit7)/MEIP(bit11) */
#define IRQ_MTIP                    7
#define IRQ_MEIP                    11

/* RT-Thread 的中断表长度（trap_common.c 默认 32），7 和 11 都在范围内 */
#define BOARD_IRQ_NUM               32

#endif /* __BOARD_H__ */
