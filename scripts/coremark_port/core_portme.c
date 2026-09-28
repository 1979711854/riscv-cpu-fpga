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

/* 读 MMIO 周期计数器（0x7FF4，跟上系统时钟自由跑） */
CORETIMETYPE
barebones_clock(void)
{
    return (CORETIMETYPE)(*(volatile ee_u32 *)0x7FF4);
}

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1
/* 时钟频率 = 本固件要跑的那个平台的系统时钟。
 * [重点] 上板（本地盘古板）：PLL 27MHz→62.0309MHz，见 rtl/top/cpu_top_board.v；
 * [重点] 仿真 / 远程 FPGA 平台：固定 27MHz。
 * 填错不会报错，但 CoreMark 会算出错误的秒数 —— 判 valid 时按这个值卡。
 * [!] 这个常量【必须】与 PDS 时序报告里的实际频率一致（不用标称值）。
 *     历史：27e6 → 45e6 → 49,892,700 → 62,030,900。 */
#define EE_TICKS_PER_SEC           62030900

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
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
