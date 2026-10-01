/* ============================================================================
 * main.c —— 五子棋固件主程序（轨道 E1）
 * ----------------------------------------------------------------------------
 * 把 A/B/C/D 四个模块接起来，做成一个能烧进板子的固件：
 *
 *     上电 -> 填调色板与图块 -> 标题屏 -> 对局 <-> 胜负 -> 回标题
 *
 * 主循环**与帧同步**：每帧等一次 vblank，再采样按键、推状态机、全刷棋盘。
 * 这么做的两个理由：
 *   1) **防撕裂** —— 改显存要在 vblank 里做，否则可能上半屏新、下半屏旧
 *   2) **给主循环一个稳定节拍** —— 否则它会以几十万次/秒空转，白白耗电
 * 代价是按键采样周期从"微秒级"变成"帧级"（16.7ms），所以一次按压要
 * 2 帧（约 33ms）才认账。人按一下约 100ms，够用；长按 600ms 更是绰绰有余。
 *
 * [!] 全盘重画是 225 个字节/帧。60fps 下约 13.5KB/s，在 62MHz 上可以忽略 ——
 *     所以这里**不做增量更新**，每帧无脑全刷。省下的复杂度换可靠性，
 *     而且"闪一下但一定对"比"省几个周期但可能残留旧格"划算得多。
 *
 * 构建：scripts\gomoku\build.ps1        （出 mem.hex）
 * 上板：scripts\build_bitstream.ps1 gomoku
 * ==========================================================================*/
#include "board.h"
#include "ai.h"
#include "render.h"
#include "video_port.h"
#include "input.h"
#include "hw_port.h"
#include "game.h"

/* 光标闪烁半周期（毫秒）。300ms ⇒ 亮 300 / 灭 300，够醒目又不闪眼 */
#define BLINK_MS   300u

/* ---- 全局对象 ------------------------------------------------------------
 * 放静态区而不是栈上：栈顶只有 0x7000，而 game_t 里光 gomoku_t 就 232 字节，
 * 加上 AI 搜索的递归栈，放局部变量会把栈压穿。
 * [!] 它们会被 start.S 的 .bss 清零，所以显式初始化一次是必须的（见 main）。 */
static game_t  g_game;
static input_t g_input;

/* --------------------------------------------------------------------------- */
static void uart_putdec(unsigned v)
{
    char buf[12];
    int  n = 0;
    if (v == 0) { hw_uart_putc('0'); return; }
    while (v && n < 11) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) hw_uart_putc(buf[n]);
}

static void uart_puts(const char *s) { hw_uart_puts(s); }

/* 画一帧。光标只在"该显示"的时候才画 —— 闪烁灭的那半拍、以及胜负之后都不画。 */
static void draw_frame(void)
{
    int cr = -1, cc = -1;
    if (game_cursor_shown(&g_game)) {
        cr = g_game.cursor_r;
        cc = g_game.cursor_c;
    }
    render_full(&g_game.board, cr, cc);
}

/* ---------------------------------------------------------------------------
 * 主程序
 * ------------------------------------------------------------------------- */
int main(void)
{
    int i;
    int prev_phase;
    int prev_stones;

    /* ---- 1) 显示初始化 ----------------------------------------------------
     * [!] 显存上电是**随机内容**（BRAM 未初始化），不填调色板和图块的话
     *     屏幕上是一片雪花。render_init 必须最先做。 */
    render_init();
    video_set_scroll(0, 0);      /* 棋类静态，滚动归零；但必须显式写一次 */
    render_clear();

    /* ---- 2) 输入与状态机 -------------------------------------------------- */
    input_init(&g_input, hw_mtime(), hw_key_raw(),
               INPUT_DEBOUNCE_MS * hw_ticks_per_ms(),
               INPUT_LONG_MS     * hw_ticks_per_ms());
    game_init(&g_game, AI_NORMAL, GOMOKU_BLACK, BLINK_MS * hw_ticks_per_ms());

    uart_puts("\r\n=== GOMOKU on RV32I ===\r\n");
    uart_puts("keys: SW4/5/6/7 = left/right/up/down\r\n");
    uart_puts("      tap = move cursor, hold 0.6s = place, hold on title = start\r\n");
    uart_puts("      SW3 = reset\r\n");

    prev_phase  = (int)g_game.phase;
    prev_stones = (int)g_game.board.stones;

    /* ---- 3) 主循环 -------------------------------------------------------- */
    for (;;) {
        uint32_t now;
        uint32_t t0;
        uint8_t  smask = 0, lmask = 0;

        /* 与帧同步。这一句同时也是主循环的节拍器。 */
        video_wait_vblank();
        now = hw_mtime();

        /* ---- 采样按键：4 个键逐个取事件 ---- */
        input_poll(&g_input, now, hw_key_raw());
        for (i = 0; i < INPUT_N_KEYS; i++) {
            if (input_take_short(&g_input, i)) smask |= (uint8_t)(1u << i);
            if (input_take_long(&g_input, i))  lmask |= (uint8_t)(1u << i);
        }

        /* ---- 推状态机。AI 在这里同步跑完（会阻塞几帧的时间）---- */
        t0 = hw_mtime();
        game_tick(&g_game, now, smask, lmask);
        g_game.ai_ms = hw_ticks_to_ms(hw_mtime() - t0);

        /* ---- 刷屏 ---- */
        draw_frame();

        /* ---- 状态变化就打串口（一次性事件，不刷屏）---- */
        if (g_game.phase != (game_phase_t)prev_phase) {
            if (g_game.phase == GAME_PLAYING) {
                uart_puts("start, level=");
                uart_putdec((unsigned)g_game.level);
                uart_puts("\r\n");
            } else if (g_game.phase == GAME_OVER) {
                uart_puts(g_game.winner == GOMOKU_BLACK ? "BLACK wins\r\n" :
                          g_game.winner == GOMOKU_WHITE ? "WHITE wins\r\n" :
                                                          "draw\r\n");
            } else {
                uart_puts("title\r\n");
            }
            prev_phase = (int)g_game.phase;
        }
        if (g_game.board.stones != prev_stones) {
            int delta = g_game.board.stones - prev_stones;
            /* AI 落子时 stones 会 +2（人一手 + AI 一手）；单独打印 AI 那手的统计 */
            if (delta > 1 || g_game.board.turn == g_game.human) {
                uart_puts("AI moved, nodes=");
                uart_putdec((unsigned)g_game.ai_nodes);
                uart_puts(" depth=");
                uart_putdec((unsigned)g_game.ai_depth);
                uart_puts(" t=");
                uart_putdec((unsigned)g_game.ai_ms);
                uart_puts("ms\r\n");
            }
            prev_stones = (int)g_game.board.stones;
        }
    }

    return 0;   /* 不会走到 */
}
