/* ============================================================================
 * uart.h —— 最简串口输出（不依赖 libc）
 * ----------------------------------------------------------------------------
 * 这是本工程跑 C 的唯一"输出手段"：直接写 MMIO 到 UART 发送寄存器。
 * 因为我们是 freestanding（没有 libc），printf / puts / malloc 都用不了，
 * 这些函数就是替代品。用法见 main.c。
 *
 * 外设地址定义在 rtl/bus/addr_map.vh（RTL 侧）与 scripts/demo/addr_map.h
 * （软件侧），这里只取用得到的几个。
 * ==========================================================================*/
#ifndef TEMPLATE_UART_H
#define TEMPLATE_UART_H

#define REG8(a)   (*(volatile unsigned char *)(a))
#define REG32(a)  (*(volatile unsigned int  *)(a))

/* 外设区 0x8000_0000 起 */
#define UART_TX   0x80000008u   /* W：发一个字符（取低字节） */
#define TIMER     0x80000010u   /* R：32 位自由跑周期计数器  */
#define GPIO      0x80000000u   /* W：LED[7:0]  R：{key[7:0], led[7:0]} */

#define CPU_HZ    27000000u     /* 远程平台固定 27MHz */

static inline void uart_putc(char c)
{
    REG8(UART_TX) = (unsigned char)c;
}

static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

/* 打印两位十六进制（0x00 ~ 0xFF） */
static void uart_puthex8(unsigned v)
{
    unsigned hi = (v >> 4) & 0xFu, lo = v & 0xFu;
    uart_putc(hi < 10u ? (char)('0' + hi) : (char)('A' + hi - 10u));
    uart_putc(lo < 10u ? (char)('0' + lo) : (char)('A' + lo - 10u));
}

/* 打印十进制（无符号）。用 10 取余，会用到 M 扩展的 divu/remu */
static void uart_putdec(unsigned v)
{
    char buf[11];
    int  n = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) { buf[n++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (n--)
        uart_putc(buf[n]);
}

/* 忙等 ms 毫秒（用周期计数器，27MHz） */
static void delay_ms(unsigned ms)
{
    unsigned start = REG32(TIMER);
    unsigned ticks = ms * (CPU_HZ / 1000u);
    while ((REG32(TIMER) - start) < ticks)   /* 无符号减法天然处理回绕 */
        ;
}

#endif /* TEMPLATE_UART_H */
