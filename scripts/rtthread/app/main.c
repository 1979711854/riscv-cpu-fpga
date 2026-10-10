/* ============================================================================
 * main.c —— RT-Thread 版五子棋的入口线程
 * ----------------------------------------------------------------------------
 * 这是任务 H（把五子棋跑在 RT-Thread 上）的【第一步：单线程版】。
 *
 * 现在的形态是**最小可用**：
 *       main 线程 → 建一个 gomoku 线程 → 游戏在那个线程里跑
 *   没有任何拆分。目的是先把"挂了 RTOS 的游戏"跑通 —— 出了问题只可能是
 *   RTOS 移植或链接，不会是线程间同步。
 *
 * [!] **下一步才是 G3（AI 思考时画面不卡）**：把 AI 拆到低优先级线程、
 *     渲染留在高优先级，这样 AI 那 1.4 秒里光标照样闪。
 *     **别一次做完** —— RTOS 调度 + 显存 vblank 都是时序敏感的，
 *     两件事一起动，出问题分不清是谁的。
 *
 * [!] 上一个版本的"ping/pong 双线程验证程序"在 git 历史里（commit 2a5807f 之前）。
 *     那个已经完成使命（证明移植成功），这里换成真应用。
 * ==========================================================================*/

#include <rtthread.h>
#include <rthw.h>

/* 五子棋的应用主体。**不叫 main** —— 见 scripts/gomoku/main_entry.c 的文件头：
 * 五子棋要同时支持裸机与 RT-Thread 两种宿主，两个 main() 会撞。
 * 本函数【不会返回】（内部 for(;;)）。 */
void gomoku_run(void);

/* ---- 游戏线程栈：静态数组，进 .bss，不占堆 ----
 * 给 4KB 的依据：AI 是递归 α-β，实测 6 层递归 + 调用链约 2KB；
 * 裸机时代整个程序只有 6KB 栈也够用。这里 4KB 留了余量。
 * [!] 调大之前先看 build.ps1 打印的堆可用量 —— 栈和堆是互相挤的。 */
#define GOMOKU_STACK        4096
#define GOMOKU_PRIORITY     20

/* 主线程心跳周期（毫秒）。上板 5 秒足够看出"还活着"又不刷屏；
 * [!] 仿真必须调小 —— 5000ms @100MHz = 5 亿周期，iverilog 跑不完。 */
#ifndef HB_DELAY_MS
#define HB_DELAY_MS         5000
#endif

static struct rt_thread gomoku_thread;
static rt_uint8_t       gomoku_stack[GOMOKU_STACK];

static void gomoku_entry(void *parameter)
{
    RT_UNUSED(parameter);

    rt_kprintf("[boot] gomoku thread running\n");
    gomoku_run();                       /* 不返回 */
}

/* ---------------------------------------------------------------------------
 * main：RT-Thread 的 main 线程入口（由 rt_application_init 创建）
 * -------------------------------------------------------------------------*/
int main(void)
{
    rt_err_t err;

    /* 堆有多大 = link.ld 里 __heap_end - __heap_start。
     * 扩到 64KB 之后这个数应该有三万多 —— 打出来比事后猜"为什么 malloc 失败"省事。 */
    extern char __heap_start;
    extern char __heap_end;
    rt_uint32_t heap_size = (rt_uint32_t)(&__heap_end - &__heap_start);

    rt_kprintf("\n");
    rt_kprintf("========================================\n");
    rt_kprintf(" RV32IMA + RT-Thread + GOMOKU @85.0051MHz\n");
    rt_kprintf("========================================\n");
    rt_kprintf("[boot] tick         = %d\n", rt_tick_get());
    rt_kprintf("[boot] tick period  = %d Hz\n", RT_TICK_PER_SECOND);
    rt_kprintf("[boot] heap         = %d bytes\n", (int)heap_size);

    /* 静态线程：不占堆，栈不够时【链接期就报错】而不是运行期莫名崩 */
    err = rt_thread_init(&gomoku_thread, "gomoku", gomoku_entry, RT_NULL,
                         gomoku_stack, sizeof(gomoku_stack),
                         GOMOKU_PRIORITY, 10);
    if (err != RT_EOK)
    {
        rt_kprintf("[boot] rt_thread_init(gomoku) FAILED (%d)\n", err);
        return -1;
    }
    rt_thread_startup(&gomoku_thread);

    /* 主线程退到后台当"心跳"。它的存在本身就是判据：
     * 串口里 [hb] 和五子棋的输出交替出现 ⇒ 调度正常、游戏线程没独占 CPU。 */
    while (1)
    {
        rt_thread_mdelay(HB_DELAY_MS);
        rt_kprintf("[hb] alive, uptime %d ticks\n", rt_tick_get());
    }
}
