/* ============================================================================
 * cm_mailbox.h —— CoreMark → 五子棋的跨复位共享邮箱（0xFF00）
 * ----------------------------------------------------------------------------
 * 干什么：CoreMark 跑完把成绩写进 8 个字，五子棋标题屏读出来显示
 *         "LAST COREMARK / SCORE 352.5 / CRC OK"（任务书 §3.5）。
 *
 * 为什么能跨复位保留：BRAM 不随复位清空，而 0xFF00 这段**两边都不占**——
 *     · CoreMark 的栈顶是 0xF000（scripts/coremark_port/link.ld）⇒ 0xFF00 在栈之上；
 *     · RT-Thread/五子棋镜像从 0x10000 起（scripts/rtthread/bsp/link.ld）⇒ 在镜像之下；
 *     · 兼容区 MMIO 从 0xFFF0 起（0xFFF4 计时 / 0xFFF8 done / 0xFFFC UART）
 *       ⇒ 0xFF00..0xFF23 是干净的 RAM。
 * [!] **别把这个地址挪到** 0x0~0xFFF（boot selector）或 0xF000 以下（CoreMark 栈）。
 *
 * [!] 本文件被两边共用：
 *     · 五子棋      scripts/gomoku/main.c
 *     · CoreMark    scripts/coremark_port/video_text.c（写完再打结果页）
 * ==========================================================================*/
#ifndef GOMOKU_CM_MAILBOX_H
#define GOMOKU_CM_MAILBOX_H

/* 邮箱基址（字节地址，字对齐）。 */
#define CM_MBOX_BASE      0x0000FF00u

/* magic：CoreMark 写完所有字段后**最后**写它 —— 读的一方据此判断"这是完整结果"。
 * 0x434D 就是 ASCII 的 'C','M'（小端存的低 16 位）。 */
#define CM_MBOX_MAGIC     0x434Du

/* 字下标（每个 4 字节）。改顺序要同时改 scripts/coremark_port/video_text.c。 */
#define CM_MBOX_I_MAGIC     0   /* 0xFF00  magic（最后写）*/
#define CM_MBOX_I_ITER      1   /* 0xFF04  迭代数（3900）*/
#define CM_MBOX_I_TICKS     2   /* 0xFF08  Total ticks（846,440,591）*/
#define CM_MBOX_I_SCORE     3   /* 0xFF0C  分数 x100（35250 = 352.50）*/
#define CM_MBOX_I_SEEDCRC   4   /* 0xFF10  seedcrc  */
#define CM_MBOX_I_CRCLIST   5   /* 0xFF14  crclist  */
#define CM_MBOX_I_CRCMAT    6   /* 0xFF18  crcmatrix */
#define CM_MBOX_I_CRCSTATE  7   /* 0xFF1C  crcstate */
#define CM_MBOX_I_FLAGS     8   /* 0xFF20  bit0 = 四个 CRC 校验通过 */
#define CM_MBOX_N_WORDS     9

#define CM_MBOX_FLAG_CRC_OK 0x1u

#endif /* GOMOKU_CM_MAILBOX_H */
