/* ============================================================================
 * 你自己的 C 程序 —— 从这里开始改
 * ----------------------------------------------------------------------------
 * 编译：scripts\build_c.ps1 -Dir scripts\template
 * 烧录：build_c.ps1 -Sync 会顺手同步到 PDS 工程目录，然后回 PDS 重跑流程
 *
 * ⚠️ 这是 freestanding 环境（没有操作系统、没有 libc），几条硬约束：
 *   1. main 不能 return —— 没有 exit()，返回后 start.S 的 ebreak 会停机
 *   2. 没有 printf / malloc / memcpy —— 用 uart.h 里的输出函数
 *      （编译器内建的 memcpy/memset 可以用，gcc 会内联展开）
 *   3. 栈很小（0x7000 往下，32KB 以内），别开大数组当局部变量
 *   4. 不要依赖未对齐访问 —— 本 CPU 不支持（gcc 也不会生成，正常写就行）
 *   5. 全局变量初值不为 0 的要用 `= 初值` 显式写，因为 .data 段会被加载；
 *      未初始化的全局变量由 start.S 清零
 * ==========================================================================*/
#include "uart.h"

int main(void)
{
    unsigned i;

    uart_puts("Hello from RISC-V!\r\n");
    uart_puts("我的第一个程序跑起来了\r\n");

    /* 演示：打印计数器（用了 M 扩展的 divu/remu）
     *
     * ⚠️ delay_ms 是【真实时间】：1ms = 27000 个周期，而仿真大约每秒只能跑
     *    3 万周期 —— 也就是说【仿真里 1ms 的延时 ≈ 1 秒的实际等待】。
     *    下面 2ms × 5 = 10ms，仿真要跑十来秒。
     *    调试阶段建议把延时去掉或调到 0，迭代会快得多。 */
    for (i = 0; i < 5; i++) {
        uart_puts("count = ");
        uart_putdec(i);
        uart_puts("\r\n");
        delay_ms(2);
    }

    uart_puts("done\r\n");

    /* 结束方式二选一：
     *   ebreak   —— CPU 停机钩子。tb_run 会立刻结束仿真，顶层也把 done 拉高。
     *               开发阶段推荐，仿真跑得快。
     *   for(;;); —— 死循环挂住。板上这样用没问题，但仿真要跑满 -MaxCyc 才停。 */
    __asm__ volatile("ebreak");
    for (;;)
        ;
}
