#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* 读 MMIO 周期计数器（0xFFF4，跟上系统时钟自由跑） */
CORETIMETYPE
barebones_clock(void)
{
    return (CORETIMETYPE)(*(volatile ee_u32 *)0xFFF4);
}

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1
/* 时钟频率 = 本固件要跑的那个平台的系统时钟。
 * [重点] 上板（本地盘古板）：PLL 27MHz→85.0051MHz，见 rtl/top/cpu_top_board.v；
 * [重点] 仿真 / 远程 FPGA 平台：固定 27MHz。
 * 填错不会报错，但 CoreMark 会算出错误的秒数 —— 判 valid 时按这个值卡。
 * [!] 这个常量【必须】与 PDS 时序报告里的实际频率一致（不用标称值）。
 *     历史：27e6 → 45e6 → 49,892,700 → 62,030,900 → 85,005,100。 */
#define EE_TICKS_PER_SEC           85005100

static CORETIMETYPE start_time_val, stop_time_val;

void
start_time(void)
{
    GETMYTIME(&start_time_val);
}
void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
}
CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed
        = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}
secs_ret
time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

ee_u32 default_num_contexts = 1;

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    /* [!] 版本自证（2026-10-10 加）：打在 CoreMark 自己的报告【之前】。
     *     理由：两版位流可以装着**完全相同的固件**，跑分日志因此一模一样，
     *     事后分不出烧的是哪一版（见 doc/board/README.md 的 A/B 那一节）。
     *     版本号来自 RTL 侧的 `mimpid`，常量在 rtl/core/csr_file.v 的 DESIGN_REV。
     * [!] mimpid 是只读 CSR，只读不写（写它会抛非法指令）。
     *
     * [!] **这里绝对不能用 `ee_printf`** —— 2026-10-10 实踩，我自己踩的：
     *     `ee_printf` 的 `uart_send_char()` 每发一个字符都要**读 `0xFFF4` 忙等**，
     *     而 `sim/tb_coremark.v` 判定"CoreMark 计时区间"的判据恰恰是
     *     **第 1 次 / 第 2 次读 `0xFFF4`**（CoreMark 自己在 `start_time()` 之前
     *     一个字都不打，所以那两个读本来正好是 `start_time` / `stop_time`）。
     *     用了 `ee_printf` 之后，区间在 banner 处就被提前打开、下一个字符又立刻关上，
     *     于是 `region cycles / commit / mem acc` **全部变成 1**，
     *     所有流水线分解数据静默失效（而 `Total ticks` 仍然是对的，所以看不出来）。
     *     所以这里**直接写 UART 口、不忙等**：这 30 来个字符进的是 1024 深的
     *     FIFO，而后头还有十几秒的 CoreMark 要跑，早在程序结束前就发完了。 */
    {
        volatile ee_u8 *uart = (volatile ee_u8 *)0xFFFC;   /* 兼容区 UART 发送口 */
        static const char pre[] = "[build] FW=COREMARK RTL=0x";
        static const char hx[]  = "0123456789abcdef";
        const char *p;
        unsigned    rev;
        int         i;

        __asm__ volatile ("csrr %0, mimpid" : "=r"(rev));
        for (p = pre; *p; p++) *uart = (ee_u8)*p;
        for (i = 28; i >= 0; i -= 4) *uart = (ee_u8)hx[(rev >> i) & 0xF];
        *uart = (ee_u8)'\r';
        *uart = (ee_u8)'\n';
    }

    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    /* [!] Cache 命中/缺失上报（高阶任务①，2026-10-11 加）。
     *   位置刻意放在 portable_fini：它在 CoreMark 报告【之后】、计时区间【之外】，
     *   所以既不影响 Total ticks，也不影响四个 CRC。
     *   计数器是 mem_bus 里的只读 MMIO（0x8000_0018~0x24，见 scripts/demo/addr_map.h）；
     *   DCACHE_EN/ICACHE_EN=0 时它们恒 0，所以这里无条件打也无害。
     *   同样直写 0xFFFC、不走 ee_printf（理由见 portable_init 的长注释）。 */
    {
        volatile ee_u8 *uart = (volatile ee_u8 *)0xFFFC;
        static const char hx[] = "0123456789abcdef";
        struct { const char *label; ee_u32 addr; } tab[4];
        int t, i;

        tab[0].label = "[cache] D hits=0x"; tab[0].addr = 0x80000018u;
        tab[1].label = "[cache] D miss=0x"; tab[1].addr = 0x8000001Cu;
        tab[2].label = "[cache] I hits=0x"; tab[2].addr = 0x80000020u;
        tab[3].label = "[cache] I miss=0x"; tab[3].addr = 0x80000024u;

        for (t = 0; t < 4; t++) {
            ee_u32 v = *(volatile ee_u32 *)tab[t].addr;
            const char *q;
            for (q = tab[t].label; *q; q++) *uart = (ee_u8)*q;
            for (i = 28; i >= 0; i -= 4) *uart = (ee_u8)hx[(v >> i) & 0xF];
            *uart = (ee_u8)'\r';
            *uart = (ee_u8)'\n';
        }
    }
    p->portable_id = 0;
}
