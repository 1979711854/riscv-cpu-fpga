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

/* AI 对弈每手间隔的档位在标题屏菜单里选（step_ms：500/1000/2000ms，见
 * game.c 的 step_next/step_prev）；主循环每帧把 step_ms 换算成 demo_delay。 */

/* ---- 全局对象 ------------------------------------------------------------
 * 放静态区而不是栈上：栈顶只有 0xF000，而 game_t 里光 gomoku_t 就 232 字节，
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

/* ---------------------------------------------------------------------------
 * 上板自证：读【设计版本号】并打在串口第一行
 * ---------------------------------------------------------------------------
 * [!] 为什么要有这个（2026-10-10 实踩）：**两版位流可以装着完全相同的固件**，
 *     串口日志因此一模一样，事后分不出烧的是哪一版（见 doc/board/README.md 的
 *     A/B 那一节）。所以版本号必须来自【RTL 侧】—— 它由 `mimpid`（0xF13）读出，
 *     常量定义在 rtl/core/csr_file.v 的 DESIGN_REV。
 * [!] mimpid 是规范里的**只读** ID 寄存器：写它会抛非法指令（csr_file.v 的
 *     `wr_illegal`），只读不写。
 * [!] 这一行必须用**大写** `FW=GOMOKU` —— tb_rtthread.v 用小写 "gomoku"
 *     专门匹配 `[boot] gomoku render thread running`，这里写小写会让那条自检永远为真。 */
static uint32_t design_rev(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mimpid" : "=r"(v));
    return v;
}

static void uart_puthex32(uint32_t v)
{
    static const char hx[] = "0123456789abcdef";
    int i;
    for (i = 28; i >= 0; i -= 4) hw_uart_putc(hx[(v >> i) & 0xF]);
}

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

/* 菜单层名 —— 只用字库里有字的字符（字母/数字/空格），见 font.h 的可用字形。 */
static const char *menu_stage_name(int stage)
{
    switch (stage) {
    case MENU_MODE:       return "MODE";
    case MENU_H_DIFF:     return "DIFFICULTY";
    case MENU_H_COLOR:    return "COLOR";
    case MENU_A_BLACK:    return "BLACK AI";
    case MENU_A_WHITE:    return "WHITE AI";
    case MENU_A_INTERVAL: return "INTERVAL";
    default:              return "";
    }
}

static void draw_hud(void)
{
    char line[SCREEN_COLS + 1];
    char *p;

    if (g_game.phase == GAME_TITLE) {
        /* 清掉对局屏用过的行，防残留：行 2 的黑白/难度行、行 24 的胜负横幅。
         * render_text(row, 0, "") 会整行铺空格字模（见 render.c 的实现）。 */
        render_text(2,  0, "");
        render_text(24, 0, "");

        render_text_center(1, "GOMOKU");

        /* 菜单：当前层名（行 3）+ 当前值（行 4），任务 T2 多级菜单 */
        render_text_center(3, menu_stage_name(g_game.menu_stage));
        p = line;
        switch (g_game.menu_stage) {
        case MENU_MODE:
            p = buf_append(p, g_game.mode == GAME_MODE_HUMAN ? "HUMAN" : "AI");
            break;
        case MENU_H_DIFF:
            p = buf_append(p, level_name(g_game.level_black));
            break;
        case MENU_H_COLOR:
            p = buf_append(p, g_game.human == GOMOKU_BLACK ? "BLACK" : "WHITE");
            break;
        case MENU_A_BLACK:
            p = buf_append(p, level_name(g_game.level_black));
            break;
        case MENU_A_WHITE:
            p = buf_append(p, level_name(g_game.level_white));
            break;
        case MENU_A_INTERVAL:
            p = u32_to_str(p, g_game.step_ms);
            p = buf_append(p, "MS");
            break;
        default:
            break;
        }
        render_text_center(4, line);

        render_text_center(27, "UP OR DOWN  CHANGE");
        render_text_center(28, "HOLD OR RIGHT  OK  LEFT  BACK");
        return;
    }

    /* [!] 先清掉【标题屏专用的行】—— 否则进对局后屏幕上会残留菜单文字。
     *     （2026-10-10 板上实踩。这和"同一行内的残字"是同类问题的另一种形态。）
     *     行 28 不用在这里清：它马上会被下面的 AI 统计整行覆写。 */
    render_text(3,  0, "");
    render_text(4,  0, "");
    render_text(27, 0, "");
    render_text(24, 0, "");          /* 上一局的胜负横幅 */

    /* 顶部：轮次 + 难度（任务 T2/T3 行距重排）。
     *   人机：一行难度（黑白同步）；AI 对弈：黑/白/间隔三行。 */
    if (g_game.mode == GAME_MODE_AI) {
        render_text(1, 1, "AI VS AI");
        p = line; p = buf_append(p, "BLACK AI: "); p = buf_append(p, level_name(g_game.level_black));
        render_text(2, 1, line);
        p = line; p = buf_append(p, "WHITE AI: "); p = buf_append(p, level_name(g_game.level_white));
        render_text(3, 1, line);
        p = line; p = buf_append(p, "STEP: ");
        p = u32_to_str(p, g_game.step_ms);
        p = buf_append(p, "MS");
        render_text(4, 1, line);
    } else {
        render_text(1, 1, g_game.board.turn == GOMOKU_BLACK ? "TURN: BLACK" : "TURN: WHITE");
        p = line; p = buf_append(p, "LEVEL: "); p = buf_append(p, level_name(g_game.level_black));
        render_text(2, 1, line);
        render_text(3, 1, "");
        render_text(4, 1, "");
    }

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
/* [!] 入口【不叫 main】—— 叫 gomoku_run()。
 *     原因：五子棋要同时支持【裸机】和【RT-Thread】两种宿主，
 *     而 RT-Thread 自己也有一个 main()（入口线程）。两个 main() 在链接期必撞。
 *     所以把主循环摘成普通函数：
 *       · 裸机      -> main_entry.c 里的 main() 直接调它
 *       · RT-Thread -> app/main.c 建一个线程调它（见 scripts/rtthread/）
 *     本函数【不会返回】（for(;;)）。 */

/* ---------------------------------------------------------------------------
 * 宿主 AI 泵（弱函数）：每一帧 game_tick 之后调一次，负责「把该下的 AI 下掉」。
 *   裸机默认：同步算完（阻塞在 ai_choose_move）。
 *   RT-Thread 宿主：用强定义覆盖成「派单给低优先级 AI 线程 + 非阻塞收结果」。
 *   返回 1 = 这一帧真的落了 AI 的子。
 * ------------------------------------------------------------------------- */
__attribute__((weak))
int gomoku_ai_pump(game_t *gm, uint32_t now)
{
    ai_stats_t st;
    uint32_t   t0 = hw_mtime();

    if (game_ai_run_sync(gm, now, &st)) {
        gm->ai_ms = hw_ticks_to_ms(hw_mtime() - t0);
        return 1;
    }
    return 0;
}

void gomoku_run(void)
{
    int i;
    int prev_phase;
    int prev_stones;
    int prev_cr, prev_cc;      /* 上次打印时的光标位置 —— 短按移动要有串口反馈 */
    int prev_mode, prev_human; /* 菜单：模式 / 执子（变化要有串口反馈）*/
    int prev_level_black, prev_level_white;   /* 菜单：黑白难度 */
    int prev_step_ms, prev_stage;             /* 菜单：间隔档 / 当前层 */
    int warned_no_video = 0;   /* vblank 超时只报一次，别把串口灌爆 */

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
    /* demo_delay（AI 对弈每手间隔）在主循环里每帧按 step_ms 现算 —— 菜单可改档 */

    /* 第一行就自证版本：FW=固件名，RTL=设计版本号（来自 mimpid）。
     * 两版位流装同一份固件时，靠 RTL= 那一段区分（见上面 design_rev 的说明）。 */
    uart_puts("\r\n[build] FW=GOMOKU RTL=0x");
    uart_puthex32(design_rev());
    uart_puts("\r\n");

    uart_puts("=== GOMOKU on RV32I ===\r\n");
    uart_puts("keys: SW4/5/6/7 = left/right/up/down\r\n");
    uart_puts("      title menu: up/down = change, hold or right = OK, left = back\r\n");
    uart_puts("      play: tap = move cursor, hold = place\r\n");
    uart_puts("      SW3 = reset\r\n");
    uart_puts("board: X=black O=white .=empty *=last move  (serial mirror, no monitor needed)\r\n");

    prev_phase  = (int)g_game.phase;
    prev_stones = (int)g_game.board.stones;
    prev_cr     = g_game.cursor_r;
    prev_cc     = g_game.cursor_c;
    prev_mode        = -1;
    prev_human       = -1;
    prev_level_black = -1;
    prev_level_white = -1;
    prev_step_ms     = -1;
    prev_stage       = -1;     /* -1 保证上电第一圈就把菜单当前值全打一遍 */

    /* ---- 3) 主循环 -------------------------------------------------------- */
    for (;;) {
        uint32_t now;
        uint8_t  smask = 0, lmask = 0;

        /* 与帧同步。这一句同时也是主循环的节拍器。 */
        /* [!] 非 0 = 视频没在跑（vblank 超时）。**注意区分"偶发超时"和"一直超时"**：
         *     偶发一次可能是复位后视频刚起来，不必刷屏；一直超时才值得报。
         *     这里只在【第一次】超时时打一行串口 —— 之后不再刷，免得把串口灌爆。
         *     关键点：**超时也继续往下走**，所以按键、状态机、串口都还活着。 */
        if (video_wait_vblank() != 0) {
            if (!warned_no_video) {
                warned_no_video = 1;
                uart_puts("[!] vblank timeout -- video not running (check D18 video_locked)\r\n");
            }
        }
        now = hw_mtime();

        /* AI 对弈每手间隔：菜单里 step_ms 是毫秒，这里换算成 now 的单位。
         * 每帧现算 —— 菜单改档后下一局自然生效，不用在别处同步。 */
        g_game.demo_delay = g_game.step_ms * hw_ticks_per_ms();

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
        if (g_game.mode != GAME_MODE_AI && lmask != 0 && g_game.phase == GAME_PLAYING && game_ai_turn(&g_game)) {
            if (g_game.board.cell[g_game.cursor_r][g_game.cursor_c] != GOMOKU_EMPTY) {
                uart_puts("occupied -- move the cursor and try again\r\n");
            } else {
                uart_puts("AI thinking (");
                uart_puts(level_name(game_ai_level(&g_game)));
                uart_puts(")...\r\n");
            }
        }
        game_tick(&g_game, now, smask, lmask);
        /* 宿主 AI 泵：裸机在这里同步算完并刷新 ai_ms；RT-Thread 宿主覆盖成
         * 「派单给低优先级 AI 线程 + 非阻塞收结果」（见 app/main.c）。
         * 只有真的落了 AI 子的那一帧才刷新 ai_ms —— 见 gomoku_ai_pump。 */
        gomoku_ai_pump(&g_game, now);

        /* ---- 刷屏 ---- */
        draw_frame();

        /* ---- 状态变化就打串口（一次性事件，不刷屏）---- */
        if (g_game.phase != (game_phase_t)prev_phase) {
            if (g_game.phase == GAME_PLAYING) {
                if (g_game.mode == GAME_MODE_AI) {
                    uart_puts("AI match: black=");
                    uart_puts(level_name(g_game.level_black));
                    uart_puts(" white=");
                    uart_puts(level_name(g_game.level_white));
                    uart_puts(" step=");
                    uart_putdec(g_game.step_ms);
                    uart_puts("ms\r\n");
                } else {
                    uart_puts("start, level=");
                    uart_puts(level_name(g_game.level_black));
                    uart_puts(" you=");
                    uart_puts(g_game.human == GOMOKU_BLACK ? "BLACK" : "WHITE");
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
            if (delta > 1 || g_game.board.turn == g_game.human || g_game.mode == GAME_MODE_AI) {
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

        /* [!] 标题屏菜单变化【本来是完全静默的】—— 2026-10-04 实测反馈：
         * 按了键却没有任何输出，只能靠开局那行反推，玩家根本不知道档位切没切。
         * 这里把菜单每一项的变化都打到串口。 */
        if (g_game.menu_stage != prev_stage) {
            prev_stage = g_game.menu_stage;
            uart_puts("menu=");
            uart_puts(menu_stage_name(prev_stage));
            uart_puts("\r\n");
        }
        if (g_game.mode != prev_mode) {
            prev_mode = g_game.mode;
            uart_puts("mode=");
            uart_puts(prev_mode == GAME_MODE_AI ? "AI" : "HUMAN");
            uart_puts("\r\n");
        }
        if (g_game.human != prev_human) {
            prev_human = g_game.human;
            uart_puts("you=");
            uart_puts(prev_human == GOMOKU_BLACK ? "BLACK" : "WHITE");
            uart_puts("\r\n");
        }
        if (g_game.level_black != prev_level_black) {
            prev_level_black = g_game.level_black;
            uart_puts("black=");
            uart_puts(level_name(prev_level_black));
            uart_puts("\r\n");
        }
        if (g_game.level_white != prev_level_white) {
            prev_level_white = g_game.level_white;
            uart_puts("white=");
            uart_puts(level_name(prev_level_white));
            uart_puts("\r\n");
        }
        if ((int)g_game.step_ms != prev_step_ms) {
            prev_step_ms = (int)g_game.step_ms;
            uart_puts("step=");
            uart_putdec(g_game.step_ms);
            uart_puts("ms\r\n");
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

    /* 不会走到（上面是 for(;;)）。函数返回 void，所以直接 return。 */
}
