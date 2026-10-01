/* ============================================================================
 * main.c —— RT-Thread 移植验证程序
 * ----------------------------------------------------------------------------
 * 照 libcpu/risc-v/common/readme.md §5「验证」那条做：
 *   「创建一个静态线程，在线程中调用 RT-Thread 提供的与系统时基相关函数接口，
 *     例如 rt_thread_mdelay，调试观察系统是否可以正常运行」
 *
 * 这里做了三件事，正好覆盖移植是否成功的三个必要条件：
 *
 *   [1] 控制台通了        —— main 里第一条 rt_kprintf 能打出来
 *   [2] 系统 tick 在走     —— rt_tick_get() 递增、rt_thread_mdelay 真的会等
 *   [3] 上下文切换正确     —— 两个线程用信号量你一下我一下地交替，
 *                            顺序错乱或卡死都说明上下文切换有问题
 *
 * [!] 用【静态线程】（rt_thread_init + 自己的栈数组，放 .bss），不用
 *     rt_thread_create（从堆分配）。32KB 下这样更省、也更好排错 ——
 *     栈不够时链接期就报错，而不是运行期莫名崩。
 * ==========================================================================*/

#include <rtthread.h>
#include <rthw.h>

/* ---- 线程栈：静态数组，进 .bss，不占堆 ----
 * [!] 这两个数直接吃掉 2KB 静态内存。它们和堆是互斥的（堆在它们之后才分配），
 *     所以调大之前先看 build.ps1 打印的占用。 */
#define STACK_PING          512
#define STACK_PONG          512

static struct rt_thread ping_thread;
static struct rt_thread pong_thread;
static rt_uint8_t ping_stack[STACK_PING];
static rt_uint8_t pong_stack[STACK_PONG];

/* 乒乓的节奏。上板用 500ms（肉眼看得清），仿真用 build.ps1 -Sim 传个小值 ——
 * 500ms 在 27MHz 仿真里是 1350 万周期，跑几轮就要好几分钟，没必要。
 * [!] 判断 tick 是否正常看的是【rt_tick_get() 的差值 ≈ 这个值】，
 *     所以改这个数不会让判据失效，只是让仿真快很多。 */
#ifndef APP_DELAY_MS
#define APP_DELAY_MS 500
#endif

/* 两个线程用这个信号量玩"乒乓球"：ping 放、pong 取，顺序错了立刻能看出来 */
static struct rt_semaphore ping_pong_sem;
static rt_uint32_t round_count = 0;

/* ---------------------------------------------------------------------------
 * ping：每 500ms 放一次信号量，并检查 tick 是不是真的走过了 500ms
 * -------------------------------------------------------------------------*/
static void ping_entry(void *parameter)
{
    rt_uint32_t last_tick = rt_tick_get();
    rt_uint32_t n = 0;

    RT_UNUSED(parameter);

    while (1)
    {
        rt_uint32_t now;

        rt_sem_release(&ping_pong_sem);

        /* 信号量要等对方取走后再放下一个 —— 用 mdelay 卡住节奏。
         * [!] 这里是验证 tick 的地方：如果 tick 没在走，mdelay 会永远不返回。 */
        rt_thread_mdelay(APP_DELAY_MS);

        now = rt_tick_get();
        n++;

        rt_kprintf("[ping] round %d  tick %d (delta %d, expect %d)\n",
                   n, now, now - last_tick, APP_DELAY_MS);
        last_tick = now;
    }
}

/* ---------------------------------------------------------------------------
 * pong：等 ping 的信号量，取到就报一次数
 * -------------------------------------------------------------------------*/
static void pong_entry(void *parameter)
{
    RT_UNUSED(parameter);

    while (1)
    {
        /* 等不到就永远阻塞 —— 卡在这里说明调度或信号量有问题 */
        if (rt_sem_take(&ping_pong_sem, RT_WAITING_FOREVER) == RT_EOK)
        {
            round_count++;
            rt_kprintf("[pong] got semaphore, total %d\n", round_count);
        }
    }
}

/* ---------------------------------------------------------------------------
 * main：RT-Thread 的 main 线程入口（由 rt_application_init 创建）
 * -------------------------------------------------------------------------*/
int main(void)
{
    rt_err_t err;

    /* 堆有多大 = link.ld 里 __heap_end - __heap_start。代码一大这个数就变小，
     * 打出来比事后猜"为什么 malloc 失败"省事得多。 */
    extern char __heap_start;
    extern char __heap_end;
    rt_uint32_t heap_size = (rt_uint32_t)(&__heap_end - &__heap_start);

    rt_kprintf("\n");
    rt_kprintf("========================================\n");
    rt_kprintf(" RISC-V RV32IM @ 62.0309MHz  RT-Thread  \n");
    rt_kprintf("========================================\n");
    rt_kprintf("[boot] tick         = %d\n", rt_tick_get());
    rt_kprintf("[boot] tick period  = %d Hz\n", RT_TICK_PER_SECOND);
    rt_kprintf("[boot] heap         = %d bytes\n", (int)heap_size);

    /* 信号量：初值 0 —— ping 先放，pong 才能取 */
    err = rt_sem_init(&ping_pong_sem, "pp", 0, RT_IPC_FLAG_FIFO);
    if (err != RT_EOK)
    {
        rt_kprintf("[boot] rt_sem_init FAILED (%d)\n", err);
        return -1;
    }

    /* 静态线程：ping 优先级 20，pong 优先级 21 —— 让 ping 先跑 */
    err = rt_thread_init(&ping_thread, "ping", ping_entry, RT_NULL,
                         ping_stack, sizeof(ping_stack), 20, 10);
    if (err != RT_EOK)
    {
        rt_kprintf("[boot] rt_thread_init(ping) FAILED (%d)\n", err);
        return -1;
    }
    rt_thread_startup(&ping_thread);

    err = rt_thread_init(&pong_thread, "pong", pong_entry, RT_NULL,
                         pong_stack, sizeof(pong_stack), 21, 10);
    if (err != RT_EOK)
    {
        rt_kprintf("[boot] rt_thread_init(pong) FAILED (%d)\n", err);
        return -1;
    }
    rt_thread_startup(&pong_thread);

    rt_kprintf("[boot] both threads started -- watching ping/pong alternate\n");

    /* 主线程自己退到后台：它的工作已经做完了。
     * 系统会继续跑 ping / pong 两个线程 —— 它们交替打印就说明调度正常。 */
    while (1)
    {
        rt_thread_mdelay(APP_DELAY_MS * 10);
        rt_kprintf("[main] still alive, uptime %d ticks\n", rt_tick_get());
    }
}
