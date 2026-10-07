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
 * [!] 全盘重画是 225 个字节/帧。60fps 下约 13.5KB/s，在 85MHz 上可以忽略 ——
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

#ifndef GOMOKU_AI_LEVEL
#define GOMOKU_AI_LEVEL AI_NORMAL      /* 上板默认：4 层，棋力够看 */
#endif

/* 光标闪烁半周期（毫秒）。300ms ⇒ 亮 300 / 灭 300，够醒目又不闪眼 */
#define BLINK_MS   300u

/* 演示模式（AI 自对弈）每手之间的间隔（毫秒）。1.5s 看得清又不拖。 */
#define DEMO_DELAY_MS 1500u

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

/* ---- 字符串拼接 / 数字格式化（固件没有 libc，自己写）---- */
/* 把 s 拷贝到 d 末尾，返回指向结束符的指针（便于链式拼字符串）。 */
static char *buf_append(char *d, const char *s)
{
    while (*s) *d++ = *s++;
    *d = '\0';
    return d;
}

/* 无符号十进制写进 buf（补结束符），返回指向结束符的指针。 */
static char *u32_to_str(char *buf, unsigned v)
{
    char tmp[11];
    int  n = 0;
    if (v == 0) { buf[0] = '0'; buf[1] = '\0'; return buf + 1; }
    while (v && n < 11) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) *buf++ = tmp[n];
    *buf = '\0';
    return buf;
}

/* ---- 串口棋盘快照 ---------------------------------------------------------
 * [!] **没有 HDMI 显示器时的唯一目视手段。** 板上跑的时候靠它验证棋局：
 *     棋盘对不对、光标在哪、轮到谁、AI 落哪了，全在串口里。
 * 15 列 A..O、15 行 1..15；X = 黑、O = 白、. = 空；`*` = 最后一手（覆盖颜色）。
 * 只在**棋子数变化**与**阶段变化**时打印，不刷屏 —— 于是串口留下的是一串
 * "每手一张棋盘"的记录，事后能逐手复盘。
 * [!] 别改成每帧打印：60fps 下会把串口灌爆，反而看不出东西。 */
static void uart_dump_board(const game_t *gm)
{
    char line[3 + GOMOKU_N * 2 + 3];
    int  r, c;

    uart_puts("\r\n    A B C D E F G H I J K L M N O\r\n");
    for (r = 0; r < GOMOKU_N; r++) {
        int n = r + 1;
        line[0] = (char)(n >= 10 ? ('0' + n / 10) : ' ');
        line[1] = (char)('0' + n % 10);
        line[2] = ' ';
        for (c = 0; c < GOMOKU_N; c++) {
            uint8_t v  = gm->board.cell[r][c];
            char    ch = (v == GOMOKU_BLACK) ? 'X' :
                         (v == GOMOKU_WHITE) ? 'O' : '.';
            if (r == (int)gm->board.last_r && c == (int)gm->board.last_c) ch = '*';
            line[3 + c * 2]     = ch;
            line[3 + c * 2 + 1] = ' ';
        }
        line[3 + GOMOKU_N * 2]     = '\r';
        line[3 + GOMOKU_N * 2 + 1] = '\n';
        line[3 + GOMOKU_N * 2 + 2] = '\0';
        uart_puts(line);
    }
    uart_puts("cursor=");
    hw_uart_putc((char)('A' + gm->cursor_c));
    uart_putdec((unsigned)(gm->cursor_r + 1));
    uart_puts(" you=");
    uart_puts(gm->human == GOMOKU_BLACK ? "BLACK" : "WHITE");
    uart_puts(" turn=");
    uart_puts(gm->board.turn == GOMOKU_BLACK ? "BLACK" : "WHITE");
    uart_puts("\r\n");
}

/* ---- HUD 文字 ----
 * 把轮次/难度/AI 统计/胜负写到屏幕上下留白区（棋盘列 12..26、行 7..21 之外）。 */
static const char *level_name(int level)
{
    return level == AI_EASY   ? "EASY" :
           level == AI_NORMAL ? "NORMAL" : "HARD";
}

static void draw_hud(void)
{
    char line[SCREEN_COLS + 1];
    char *p;

    if (g_game.phase == GAME_TITLE) {
        render_text_center(1, "GOMOKU");
        p = line; p = buf_append(p, "LEVEL: "); p = buf_append(p, level_name(g_game.level));
        render_text_center(3, line);
        render_text_center(27, "START: HOLD ANY KEY");
        render_text_center(28, "DEMO: HOLD UP");
        return;
    }

    /* 顶部：轮次 / 难度（演示模式显示 DEMO）*/
    if (g_game.demo)
        render_text(1, 1, "DEMO: AI VS AI");
    else
        render_text(1, 1, g_game.board.turn == GOMOKU_BLACK ? "TURN: BLACK" : "TURN: WHITE");
    p = line; p = buf_append(p, "LEVEL: "); p = buf_append(p, level_name(g_game.level));
    render_text(2, 1, line);

    /* 底部：AI 统计（最有展示价值的一行）*/
    p = line; p = buf_append(p, "AI: NODES ");
    p = u32_to_str(p, g_game.ai_nodes);
    p = buf_append(p, " DEPTH ");
    p = u32_to_str(p, (unsigned)g_game.ai_depth);
    p = buf_append(p, " ");
    p = u32_to_str(p, g_game.ai_ms);
    p = buf_append(p, "MS");
    render_text(28, 1, line);

    /* 胜负横幅 */
    if (g_game.phase == GAME_OVER) {
        const char *msg = g_game.winner == GOMOKU_BLACK ? "BLACK WINS" :
                          g_game.winner == GOMOKU_WHITE ? "WHITE WINS" : "DRAW";
        render_text_center(24, msg);
    }
}

/* 画一帧。光标只在"该显示"的时候才画 —— 闪烁灭的那半拍、以及胜负之后都不画。 */
static void draw_frame(void)
{
    int cr = -1, cc = -1;
    if (game_cursor_shown(&g_game)) {
        cr = g_game.cursor_r;
        cc = g_game.cursor_c;
    }
    render_full(&g_game.board, cr, cc);
    draw_hud();
}

/* ---------------------------------------------------------------------------
 * 主程序
 * ------------------------------------------------------------------------- */
int main(void)
{
    int i;
    int prev_phase;
    int prev_stones;
    int prev_cr, prev_cc;      /* 上次打印时的光标位置 —— 短按移动要有串口反馈 */
    int prev_level;            /* 上次打印时的难度 —— 标题屏切档同样要有反馈 */

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
    /* 难度可编译期覆盖 —— **仿真必须用 EASY**。
     * NORMAL(4 层) 一次搜索约 2 亿拍，仿真里要跑十几分钟真实时间；
     * EASY 是纯贪心、一次函数调用，秒出。见 build.ps1 -Sim。 */
    game_init(&g_game, GOMOKU_AI_LEVEL, GOMOKU_BLACK, BLINK_MS * hw_ticks_per_ms());
    g_game.demo_delay = DEMO_DELAY_MS * hw_ticks_per_ms();   /* 演示每手间隔 1.5s */

    uart_puts("\r\n=== GOMOKU on RV32I ===\r\n");
    uart_puts("keys: SW4/5/6/7 = left/right/up/down\r\n");
    uart_puts("      tap = move cursor, hold 0.6s = place, hold on title = start\r\n");
    uart_puts("      hold UP on title = AI self-play demo (NORMAL vs NORMAL)\r\n");
    uart_puts("      SW3 = reset\r\n");
    uart_puts("board: X=black O=white .=empty *=last move  (serial mirror, no monitor needed)\r\n");

    prev_phase  = (int)g_game.phase;
    prev_stones = (int)g_game.board.stones;
    prev_cr     = g_game.cursor_r;
    prev_cc     = g_game.cursor_c;
    prev_level  = -1;          /* -1 保证上电第一圈就打一次当前档位 */

    /* ---- 3) 主循环 -------------------------------------------------------- */
    for (;;) {
        uint32_t now;
        uint32_t t0;
        uint8_t  smask = 0, lmask = 0;
        int      moves_before;

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
        /* [!] AI 是【同步阻塞】跑的（见文件头）。NORMAL 一手 0.4~0.7 秒无所谓，
         * 但 HARD(6 层) 实测一手要【14.5 秒】（开局那手 24,246 节点）——
         * 之前这段时间串口一片安静，玩家以为板子死了（2026-10-04 实测反馈）。
         *
         * [!] 但这里必须【先预测】再打，不能无脑打。只有"长按 + 轮到自己 +
         *     该点为空"三件事同时成立，game_tick 里的那次长按才会真的落子并触发 AI。
         *     2026-10-04 实踩：无脑打的话，往【已有子】的点长按会打出
         *     "AI thinking..." 却因为落子失败而没有下文 —— 看着比不打还糟，
         *     用户直接以为是卡死了（H6 已经有一颗黑子，实测复现）。
         *     所以落子失败也【必须】给一行话：串口上没有输出 = 用户以为按键没生效。 */
        if (!g_game.demo && lmask != 0 && g_game.phase == GAME_PLAYING && game_ai_turn(&g_game)) {
            if (g_game.board.cell[g_game.cursor_r][g_game.cursor_c] != GOMOKU_EMPTY) {
                uart_puts("occupied -- move the cursor and try again\r\n");
            } else {
                uart_puts(g_game.level == AI_HARD   ? "AI thinking (HARD 6-ply)...\r\n" :
                          g_game.level == AI_NORMAL ? "AI thinking (NORMAL 4-ply)...\r\n" :
                                                      "AI thinking (EASY)...\r\n");
            }
        }
        /* 只有【这一拍真的走了 AI】才刷新 ai_ms —— 否则空闲帧会把"上次 AI 耗时"
         * 覆盖成 0~1ms，HUD 那行 AI 统计看着像抽风。 */
        moves_before = g_game.ai_moves;
        t0 = hw_mtime();
        game_tick(&g_game, now, smask, lmask);
        if (g_game.ai_moves != moves_before)
            g_game.ai_ms = hw_ticks_to_ms(hw_mtime() - t0);

        /* ---- 刷屏 ---- */
        draw_frame();

        /* ---- 状态变化就打串口（一次性事件，不刷屏）---- */
        if (g_game.phase != (game_phase_t)prev_phase) {
            if (g_game.phase == GAME_PLAYING) {
                if (g_game.demo) {
                    uart_puts("demo mode (AI vs AI, NORMAL)\r\n");
                } else {
                    uart_puts("start, level=");
                    uart_putdec((unsigned)g_game.level);
                    uart_puts("\r\n");
                }
            } else if (g_game.phase == GAME_OVER) {
                uart_puts(g_game.winner == GOMOKU_BLACK ? "BLACK wins\r\n" :
                          g_game.winner == GOMOKU_WHITE ? "WHITE wins\r\n" :
                                                          "draw\r\n");
            } else {
                uart_puts("title\r\n");
            }
            /* [!] 开始一局时要把【空棋盘】也打出来。2026-10-04 实测反馈：
             * 只打一行 "start, level=N" 的话，玩家根本不知道游戏开没开、
             * 轮到谁、光标在哪 —— 因为开局时棋子数还是 0，不算"变化"，
             * 下面那段 stone-diff 的棋盘快照【不会触发】。 */
            if (g_game.phase == GAME_PLAYING) uart_dump_board(&g_game);
            prev_phase = (int)g_game.phase;
        }
        if (g_game.board.stones != prev_stones) {
            int delta = g_game.board.stones - prev_stones;
            /* AI 落子时 stones 会 +2（人一手 + AI 一手）；单独打印 AI 那手的统计 */
            if (delta > 1 || g_game.board.turn == g_game.human || g_game.demo) {
                uart_puts("AI moved, nodes=");
                uart_putdec((unsigned)g_game.ai_nodes);
                uart_puts(" depth=");
                uart_putdec((unsigned)g_game.ai_depth);
                uart_puts(" t=");
                uart_putdec((unsigned)g_game.ai_ms);
                uart_puts("ms\r\n");
            }
            /* 每变一次棋子就吐一张棋盘 —— 无显示器时靠它验证棋局（见 uart_dump_board） */
            uart_dump_board(&g_game);
            prev_stones = (int)g_game.board.stones;
        }

        /* [!] 标题屏切难度【本来是完全静默的】—— 2026-10-04 实测反馈：
         * 按了 SW4/SW5 却没有任何输出，只能靠开局那行 "start, level=N" 反推，
         * 玩家根本不知道档位切没切。这里补上。 */
        if (g_game.level != prev_level) {
            prev_level = g_game.level;
            uart_puts("level=");
            uart_putdec((unsigned)prev_level);
            uart_puts(prev_level == AI_EASY   ? " EASY (greedy)\r\n" :
                      prev_level == AI_NORMAL ? " NORMAL (4-ply)\r\n" :
                                                " HARD (6-ply)\r\n");
        }

        /* 光标动了就报一行。短按移动在板上本来是"零反馈"的 ——
         * 没有这行，按住方向键完全不知道有没有生效（2026-10-04 实测反馈）。 */
        if (g_game.cursor_r != prev_cr || g_game.cursor_c != prev_cc) {
            prev_cr = g_game.cursor_r;
            prev_cc = g_game.cursor_c;
            uart_puts("cursor=");
            hw_uart_putc((char)('A' + prev_cc));
            uart_putdec((unsigned)(prev_cr + 1));
            uart_puts("\r\n");
        }
    }

    return 0;   /* 不会走到 */
}
