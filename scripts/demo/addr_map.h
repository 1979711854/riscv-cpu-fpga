/* ============================================================================
 * addr_map.h —— 外设地址映射（软件侧）
 * ----------------------------------------------------------------------------
 * 必须与 RTL 侧 rtl/bus/addr_map.vh 保持一致。改一处要同步改另一处。
 * ==========================================================================*/
#ifndef ADDR_MAP_H
#define ADDR_MAP_H

/* 外设区 0x8000_0000 起 */
#define GPIO_BASE   0x80000000u   /* W: LED[7:0]      R: {key[7:0], led[7:0]}  */
#define UART_TX     0x80000008u   /* W: 发送一个字符（取低字节）                  */
#define UART_RX     0x8000000Cu   /* R: {valid[31], 23'b0, data[7:0]}，读会弹出一个 */
#define TIMER       0x80000010u   /* R: 32 位自由跑周期计数器（= mtime）           */
#define MTIMECMP    0x80000014u   /* W/R: 定时器比较值。mtime >= mtimecmp → MTIP 拉高
                                   *      写新的 mtimecmp 后 MTIP 自动落下。
                                   *      只接受整字写（sw），sb/sh 会被忽略。
                                   *      复位值为全 1，所以上电时不会误触发。
                                   *      要开中断还需 mie.MTIE(bit7) 与 mstatus.MIE(bit3)。*/

/* 兼容区（CoreMark 移植层硬编码，本程序不用，列出仅供对照）
 *   0x7FF4 R 周期计数   0x7FF8 W done   0x7FFC W UART 发送 */
#define LEGACY_TIMER   0x00007FF4u
#define LEGACY_DONE    0x00007FF8u
#define LEGACY_UART_TX 0x00007FFCu

/* 板上时钟：本地盘古板经 PLL 27MHz→45MHz（见 rtl/top/cpu_top_board.v）。
 * [重点] 仿真与远程 FPGA 平台固定 27MHz —— 回远程平台要把这里改回 27000000u，
 *   同时 scripts/coremark_port/core_portme.c 的 EE_TICKS_PER_SEC 一起改。 */
#define CPU_HZ      45000000u

#endif /* ADDR_MAP_H */
