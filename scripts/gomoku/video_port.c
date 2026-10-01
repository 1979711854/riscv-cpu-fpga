/* ============================================================================
 * video_port.c —— render.h 声明的平台端口在这里落地（MMIO 直写显存）
 * ----------------------------------------------------------------------------
 * 本文件是【固件专用】：x86 单测（test_render.c）自己实现一份假的 vid_bulk_write，
 * 所以不编译这个文件。两边实现同一个接口，render.c 因此两边跑同一份源码。
 * ==========================================================================*/
#include "addr_map.h"
#include "render.h"
#include "video_port.h"

#define REG8(a)  (*(volatile unsigned char  *)(a))
#define REG32(a) (*(volatile unsigned int   *)(a))

void vid_bulk_write(uint8_t region, uint16_t offset, const uint8_t *data, uint16_t len)
{
    uint32_t base;
    uint16_t i;

    switch (region) {
    case VID_REGION_NT:  base = VIDEO_NT;  break;
    case VID_REGION_PAT: base = VIDEO_PAT; break;
    default:             base = VIDEO_PAL; break;
    }

    /* 逐字节写（sb 语义）。三块显存都支持按字节写 —— mem_bus 的字节使能是直通的
     * （rtl/bus/mem_bus.v 里 vid_be = mem_byte_en），所以调色板那种 4 字节项也能
     * 一条一条写：第 4 个字节（高 8 位）写 0 无害，硬件本来就把高 8 位忽略掉。 */
    for (i = 0; i < len; i++)
        REG8(base + offset + i) = data[i];
}

void video_set_scroll(int x, int y)
{
    /* 控制寄存器【只接受整字写 sw】—— 这里必须是 REG32，用字节写会无效 */
    REG32(VIDEO_SCROLL_X) = (unsigned int)(x & 0xFFF);
    REG32(VIDEO_SCROLL_Y) = (unsigned int)(y & 0xFFF);
}

void video_wait_vblank(void)
{
    /* VIDEO_STATUS bit0 = vblank。
     * [重点] 这里**忙等**，而且没有超时保护 —— 如果视频 PLL 没锁（pix_clk 不走），
     *         这个位永远不变，程序会卡死在这里、串口也不打印，看起来像"死机"。
     *         首次上板如果卡在这，先去查 led 上的 video_locked（丝印 D18）。 */
    while ((REG32(VIDEO_STATUS) & 1u) == 0u)
        ;
}
