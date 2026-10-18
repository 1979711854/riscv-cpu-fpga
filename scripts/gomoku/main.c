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
#include "cm_mailbox.h"     /* CoreMark -> 五子棋的跨复位邮箱（LAST COREMARK）*/

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

/* 菜单页名 / 选中项名 / 项文案 —— 只用字库里有字的字符（大写/数字/空格），见 font.h。 */

static const char *menu_page_name(int page)
{
    return page == MENU_PAGE_MAIN  ? "MAIN" :
           page == MENU_PAGE_HUMAN ? "HUMAN" : "AI";
}

static const char *menu_item_name(const game_t *gm)
{
    switch (gm->menu_page) {
    case MENU_PAGE_MAIN:  return gm->menu_cursor == 0 ? "HUMAN" : "AI";
    case MENU_PAGE_HUMAN: return gm->menu_cursor == 0 ? "DIFF" :
                                  gm->menu_cursor == 1 ? "COLOR" : "START";
    case MENU_PAGE_AI:    return gm->menu_cursor == 0 ? "BLACK" :
                                  gm->menu_cursor == 1 ? "WHITE" :
                                  gm->menu_cursor == 2 ? "STEP" : "START";
    }
    return "";
}

/* 菜单某一项的显示文案（label + 当前值）。返回静态缓冲，立即渲染/打印，别跨项复用。 */
static const char *menu_item_text(const game_t *gm, int i)
{
    static char buf[24];
    char *p = buf;

    switch (gm->menu_page) {
    case MENU_PAGE_MAIN:
        return i == 0 ? "HUMAN VS AI" : "AI VS AI";
    case MENU_PAGE_HUMAN:
        if (i == 0) {
            p = buf_append(p, "DIFFICULTY  ");
            p = buf_append(p, level_name(gm->level_black));
        } else if (i == 1) {
            p = buf_append(p, "COLOR  ");
            p = buf_append(p, gm->human == GOMOKU_BLACK ? "BLACK" : "WHITE");
        } else {
            return "START";
        }
        break;
    case MENU_PAGE_AI:
        if (i == 0) {
            p = buf_append(p, "BLACK AI  ");
            p = buf_append(p, level_name(gm->level_black));
        } else if (i == 1) {
            p = buf_append(p, "WHITE AI  ");
            p = buf_append(p, level_name(gm->level_white));
        } else if (i == 2) {
            p = buf_append(p, "STEP  ");
            p = u32_to_str(p, gm->step_ms);
            p = buf_append(p, "MS");
        } else {
            return "START";
        }
        break;
    default:
        return "";
    }
    *p = '\0';
    return buf;
}

/* ---------------------------------------------------------------------------
 * 标题屏（2026-10-18 改版，任务书 §2.2）
 * ---------------------------------------------------------------------------
 * 目标：一眼像个完整游戏，而不是一张文字菜单。
 *   深色 UI 底 + 4x 大 logo（O = 黑白子）+ 金色选中框 + 选中项说明行
 *   + 闪烁 PRESS ANY KEY + 底部平台信息 + 右侧 7x7 自动对弈小棋盘。
 *
 * [!] 三条容易踩的坑（任务书 §2.5）：
 *   1. 字库图块背景**不透明** ⇒ 不能做整行金色底条（会被每个字的背景切成小方块），
 *      所以选中态只能用**描边框 + 棋子图标**；
 *   2. 新美术**运行时合成**（render_init 里现算）⇒ 不写进 .rodata，镜像不涨；
 *   3. 小棋盘用**脚本走法**（下面的 DEMO_MOVES），不调 AI 线程 ⇒ 菜单不会被搜索卡住。
 *
 * [!] 标题屏是**整屏重画**，但只在「内容真的变了」时重画（菜单/小棋盘/邮箱），
 *     闪烁那一行单独重画 —— 否则 60fps 全屏重绘会在 vblank 窗口外写显存，看得见闪。
 * ------------------------------------------------------------------------- */

/* ---- 版面（40 列 × 30 行，2026-10-18 第二轮反馈）-------------------------
 *   行 0        空（四边留白）
 *   行 1-2      GOMOKU 4x logo（12 格宽，居中）
 *   行 3        空（标题/副标题之间的空行 —— 反馈 T1）
 *   行 4        副标题 RISC-V + RT-THREAD
 *   行 5-6      空
 *   行 7        菜单第 1 项  ← MINI_BOARD_TOP 也等于这一行（反馈 T10）
 *   行 7/11/15/19  菜单 4 项，项间 gap 4（3 行选中框 + 1 行空 —— 反馈 T11）
 *   行 14/18/21 选中项说明（跟着菜单往下走，与菜单文字左对齐）
 *   行 6-14     右侧 7x7 小棋盘（外框 6/14 行、25/33 列）
 *   行 15       小棋盘标签 AI VS AI
 *   行 18/20/21 右侧 LAST COREMARK（读 0xFF00，有三行空地时）
 *   行 22/24    操作提示（中间空 1 行 —— 反馈 T7）
 *   行 26       平台信息（27~29 留白 —— 反馈 T6）
 * ------------------------------------------------------------------------- */
#define TITLE_LOGO_ROW    1
#define TITLE_LOGO_COL    14
#define TITLE_LOGO_COLS   12
#define TITLE_SUB_ROW     4
#define TITLE_MENU_ROW0   7
#define TITLE_MENU_GAP    4
#define TITLE_MENU_LEFT   1
#define TITLE_MENU_WIDTH  23          /* 固定框宽：最长项 18 + 图标列 + 右留白 */
#define TITLE_MENU_ICON_X (TITLE_MENU_LEFT + 1)
#define TITLE_MENU_TEXT_X (TITLE_MENU_LEFT + 3)
#define TITLE_DESC_X      TITLE_MENU_TEXT_X   /* 描述行与菜单文字左对齐 */
#define TITLE_DESC_MAXROW 21                  /* 4 项时也不能压到提示行 */
#define TITLE_CM_ROW      18
#define TITLE_HINT1_ROW   22
#define TITLE_HINT2_ROW   24
#define TITLE_PLAT_ROW    26

/* [!] 小棋盘顶行必须**严格等于**第一项菜单行（反馈 T10：两处各写一个行号就会漂）。
 *     编译期自检：不相等的话下面这个 typedef 会变成"负长度数组"，直接编译失败。 */
#define MINI_BOARD_TOP    TITLE_MENU_ROW0     /* 第一格所在行；外框在它上一行 */
#define MINI_BOARD_LEFT   25                  /* 外框左列；格子从右边一列开始 */
#define MINI_CELL_COL     (MINI_BOARD_LEFT + 1)   /* 26：第 0 列格子 */
#define MINI_CELL_ROW     MINI_BOARD_TOP          /*  7：第 0 行格子 */
#define TITLE_DEMO_N      7                   /* 7x7 自动对弈小棋盘 */
#define TITLE_DEMO_MS     700u                /* 每手间隔 */
typedef char title_layout_assert[(MINI_BOARD_TOP == TITLE_MENU_ROW0) ? 1 : -1];

/* 小棋盘的对局状态。放静态区（.bss 232 字节），不占栈 —— 栈顶只有 0xF000。 */
static gomoku_t s_demo;
static int      s_demo_i;      /* 下一手在表里的下标 */
static uint32_t s_demo_t;      /* 上一手落子时刻 */
static int      s_demo_gen;    /* 每落一子 +1；主循环据此判断要不要重画 */

/* 脚本走法：每两个字节一手 (行,列)，坐标是 7x7 子盘的 0..6。
 * 走完一轮就清盘重来 —— 录像里看起来像"两个 AI 一直在下"。
 * [!] 不调 AI：标题屏不该为装饰去抢 AI 线程/CPU（任务书 §2.3）。 */
static const uint8_t DEMO_MOVES[] = {
    3,3,  3,4,  4,4,  2,3,  4,3,  2,2,  5,4,  1,3,
    5,2,  5,5,  4,2,  3,1,  6,3,  2,4,  1,4,  6,4,
};
#define DEMO_N_MOVES  ((int)(sizeof(DEMO_MOVES) / 2))

/* 选中项的说明行（填掉菜单下方的空白，任务书 §2.2.4）。
 * [!] 全部控制在 19 字符内：描述从 col 4 起，最多到 col 22，
 *     再长就会压到右侧小棋盘/LAST COREMARK 那一列（col 25+）。 */
static const char *menu_desc(const game_t *gm)
{
    switch (gm->menu_page) {
    case MENU_PAGE_MAIN:
        return gm->menu_cursor == 0 ? "PLAY AGAINST THE CPU" : "WATCH TWO AIS PLAY";
    case MENU_PAGE_HUMAN:
        return gm->menu_cursor == 0 ? "AI SEARCH DEPTH" :
               gm->menu_cursor == 1 ? "YOUR STONE COLOR" : "BEGIN THE MATCH";
    default:
        return gm->menu_cursor == 0 ? "BLACK SIDE STRENGTH" :
               gm->menu_cursor == 1 ? "WHITE SIDE STRENGTH" :
               gm->menu_cursor == 2 ? "DELAY BETWEEN MOVES" : "BEGIN THE MATCH";
    }
}

/* 菜单项在屏幕上的行号（0-based 第几项）。 */
#define MENU_ROW_OF(i)  (TITLE_MENU_ROW0 + (i) * TITLE_MENU_GAP)

/* 说明行行号：跟在最后一项的选中框下面（空 1 行），但不能压到提示行。 */
static int desc_row(int n_items)
{
    int r = MENU_ROW_OF(n_items - 1) + 3;      /* 框底 + 1 */
    return r > TITLE_DESC_MAXROW ? TITLE_DESC_MAXROW : r;
}

/* 一行菜单项（反馈 T3/T11）：
 *   · **所有项共用固定框宽** TITLE_MENU_WIDTH（按最长项 “DIFFICULTY  NORMAL” 定）；
 *   · 图标列、文字列**固定**（不随文本长度漂移），文字在框内左对齐；
 *   · 未选中：不画框，文字仍落在同一列 —— 换选中项时文字不会跳。 */
static void draw_menu_row(int row, const char *s, int selected)
{
    render_text(row, TITLE_MENU_TEXT_X, s);
    if (!selected) return;

    render_put(row, TITLE_MENU_ICON_X, RENDER_TILE_ICON_BLACK);
    render_box(row, TITLE_MENU_LEFT, TITLE_MENU_WIDTH);
}

/* 底部平台信息。**主频是算出来的**，不是写死的字面量 ——
 * 换主频/换板子时只改 addr_map.h 的 CPU_HZ，这一行自己跟着变。
 * （约定 58：由 RTL/编译宏决定的数字一律算出来。） */
static void draw_platform_row(void)
{
    char  buf[SCREEN_COLS + 1];
    char *p = buf;
    /* MHz x10：ticks/ms = Hz/1000 ⇒ Hz/1e5 = (ticks/ms)/100 */
    uint32_t mhz10 = (hw_ticks_per_ms() * 10u) / 1000u;

    p = buf_append(p, "RV32IMA RT-THREAD ");
    p = u32_to_str(p, mhz10 / 10u);
    p = buf_append(p, ".");
    p = u32_to_str(p, mhz10 % 10u);
    p = buf_append(p, "MHZ");
    render_text_center(TITLE_PLAT_ROW, buf);
}

/* LAST COREMARK：读 0xFF00 的共享邮箱（CoreMark 写、跨复位保留）。
 * 放在**右侧小棋盘下方那一列**（col 26 起），不占左菜单的版面。
 * 反馈 T8：标题一行、值一行，中间空 1 行；两行都从同一列起，不再按长度居中。 */
static void draw_last_coremark(void)
{
    volatile uint32_t *m = (volatile uint32_t *)CM_MBOX_BASE;
    char  buf[SCREEN_COLS + 1];
    char *p;
    uint32_t score;
    int    x = MINI_BOARD_LEFT + 1;        /* 26：与小棋盘格子左对齐 */

    if (m[CM_MBOX_I_MAGIC] != CM_MBOX_MAGIC) return;

    score = m[CM_MBOX_I_SCORE];
    render_text_span(TITLE_CM_ROW, x, "LAST COREMARK");

    p = buf;
    p = buf_append(p, "SCORE: ");
    p = u32_to_str(p, score / 100u);
    p = buf_append(p, ".");
    p = u32_to_str(p, (score % 100u) / 10u);
    render_text_span(TITLE_CM_ROW + 2, x, buf);     /* 空一行再写值 */

    render_text_span(TITLE_CM_ROW + 3, x,
                     (m[CM_MBOX_I_FLAGS] & CM_MBOX_FLAG_CRC_OK) ? "CRC: OK" : "CRC: BAD");
}

/* 小棋盘推进一手：走完一轮就清盘重来；落到已占的格子上就跳过（表写错了也不会崩）。 */
static void demo_advance(void)
{
    int guard = DEMO_N_MOVES;

    if (s_demo_i >= DEMO_N_MOVES) {
        gomoku_reset(&s_demo);
        s_demo_i = 0;
        s_demo_gen++;
        return;
    }
    while (guard-- > 0 && s_demo_i < DEMO_N_MOVES) {
        int r = DEMO_MOVES[s_demo_i * 2];
        int c = DEMO_MOVES[s_demo_i * 2 + 1];
        s_demo_i++;
        if (gomoku_place(&s_demo, r, c) == GOMOKU_OK) {
            s_demo_gen++;
            return;
        }
    }
}

/* 整屏重画标题页。只在内容变化时调（见 draw_title）。 */
static void title_draw_all(void)
{
    int i, n = game_menu_item_count(&g_game);

    render_clear();                    /* 深色 UI 底铺满 40x30，并作废 dedup 缓存 */

    render_logo(TITLE_LOGO_ROW, TITLE_LOGO_COL);
    render_text_center(TITLE_SUB_ROW, "RISC-V + RT-THREAD");

    for (i = 0; i < 4; i++) {
        if (i < n)
            draw_menu_row(MENU_ROW_OF(i), menu_item_text(&g_game, i),
                          i == g_game.menu_cursor);
    }
    render_text(desc_row(n), TITLE_DESC_X, menu_desc(&g_game));

    draw_last_coremark();

    render_text_center(TITLE_HINT1_ROW, "UP/DN MOVE | L/R CHANGE");
    render_text_center(TITLE_HINT2_ROW, "HOLD = OK | L = BACK");
    draw_platform_row();

    /* ---- 小棋盘放到**最后**画（反馈 T2：以前它先画，被菜单的整行 text 抹掉两行）----
     * [!] render_text() 是**整行铺底**的：菜单项在第 7/11 行，正好压着小棋盘的
     *     第 1/5 行，之前先画棋盘后画菜单 ⇒ 棋盘有两行变成纯背景。
     *     现在顺序固定：背景 → 文本 → 小棋盘 → （选中框在 draw_menu_row 里已画完）。
     *     棋盘区在 col 25 右侧、菜单文字最右到 col 21，两者不会互压。 */
    render_frame_at(MINI_CELL_ROW, MINI_CELL_COL, TITLE_DEMO_N);
    render_board_region(&s_demo, 0, 0, TITLE_DEMO_N, TITLE_DEMO_N,
                        MINI_CELL_ROW, MINI_CELL_COL);
    /* 标签用 span 写（不铺整行）：它所在的第 15 行在 3 项页面上是第 3 项菜单行，
     * 用 render_text 会把那一项的选中框抹掉。 */
    render_text_span(MINI_CELL_ROW + TITLE_DEMO_N + 1, MINI_BOARD_LEFT, "AI VS AI");
}

/* 内容签名：只有它变了才整屏重画。闪烁单独处理（只重画一行）。 */
static int title_sig_changed(void)
{
    static int s_page = -1, s_cursor = -1, s_mode = -1, s_human = -1;
    static int s_lb = -1, s_lw = -1, s_step = -1, s_demo = -1, s_cm = -1;
    volatile uint32_t *m = (volatile uint32_t *)CM_MBOX_BASE;
    int cm = (m[CM_MBOX_I_MAGIC] == CM_MBOX_MAGIC) ? (int)m[CM_MBOX_I_SCORE] : -1;
    int ch = 0;

    if (s_page   != g_game.menu_page  || s_cursor != g_game.menu_cursor ||
        s_mode   != g_game.mode       || s_human  != g_game.human      ||
        s_lb     != g_game.level_black || s_lw    != g_game.level_white ||
        s_step   != (int)g_game.step_ms || s_demo != s_demo_gen || s_cm != cm)
        ch = 1;

    s_page = g_game.menu_page;  s_cursor = g_game.menu_cursor;
    s_mode = g_game.mode;       s_human  = g_game.human;
    s_lb   = g_game.level_black; s_lw    = g_game.level_white;
    s_step = (int)g_game.step_ms; s_demo = s_demo_gen; s_cm = cm;
    return ch;
}

/* 标题页的一拍：推进小棋盘、按需重画。返回 1 = 这一拍画了东西。 */
static int draw_title(uint32_t now, int force)
{
    if (now - s_demo_t >= TITLE_DEMO_MS * hw_ticks_per_ms()) {
        s_demo_t = now;
        demo_advance();
    }

    if (force || title_sig_changed()) {
        title_draw_all();
        return 1;
    }
    return 0;
}

/* 对局 HUD（标题屏在 draw_title 里画，**不经过这里**）。
 * [!] 进对局时 draw_frame 已经整屏抹过一次，所以这里只负责"当前该显示什么"。 */
static void draw_hud(void)
{
    char line[SCREEN_COLS + 1];
    char *p;

    /* [2026-10-17] 下面几行改用【幂等写】，且必须与后面 HUD 用【同一批槽位】。
     * [!] 若这里用普通 render_text、而下面 HUD 用 render_text_dedup，
     *     缓存就和实际屏幕对不上 ⇒ 下一帧 HUD 以为"没变"而跳过 ⇒ 该行永远空白。
     *     槽位约定：0=行1  1=行2(空) 2=行3  3=行4  4=行27(统计)  5=行24(胜负横幅)。
     *     2026-10-18 第二轮反馈 H2：TURN / LEVEL 之间空一行（行 2），
     *     所以数值行从行 2 挪到行 3（AI 模式的 BLACK/WHITE 占行 3/4）。 */
    render_text_dedup(1, 2,  0, "");          /* 行 2：组间空行 */
    render_text_dedup(5, 24, 0, "");          /* 上一局的胜负横幅 */

    /* 顶部：轮次/对局类型（行 1）+ 空一行（行 2）+ 难度（行 3/4）。
     *   [!] render_text 会整行铺空格，所以图标必须在 render_text 之后用 render_put 盖上。
     *   [!] 反馈 T5/H1：WHITE AI 那一行也要有**白子图标**，与 BLACK 行对称。 */
    if (g_game.mode == GAME_MODE_AI) {
        render_text_dedup(0, 1, 5, "AI VS AI");
        p = line; p = buf_append(p, "BLACK AI: "); p = buf_append(p, level_name(g_game.level_black));
        render_text_dedup(2, 3, 3, line);
        render_put(3, 1, RENDER_TILE_ICON_BLACK);
        p = line; p = buf_append(p, "WHITE AI: "); p = buf_append(p, level_name(g_game.level_white));
        render_text_dedup(3, 4, 3, line);
        render_put(4, 1, RENDER_TILE_ICON_WHITE);
        /* STEP 并进底部统计行（行 4 让给 WHITE AI，行距才拉得开）*/
        p = line; p = buf_append(p, "STEP ");
        p = u32_to_str(p, g_game.step_ms);
        p = buf_append(p, "MS  AI ");
        p = u32_to_str(p, g_game.ai_nodes);
        p = buf_append(p, " N D");
        p = u32_to_str(p, (unsigned)g_game.ai_depth);
        p = buf_append(p, " ");
        p = u32_to_str(p, g_game.ai_ms);
        p = buf_append(p, "MS");
    } else {
        int who = g_game.board.turn;
        render_text_dedup(0, 1, 3, who == GOMOKU_BLACK ? "TURN: BLACK" : "TURN: WHITE");
        render_put(1, 1, who == GOMOKU_BLACK ? RENDER_TILE_ICON_BLACK : RENDER_TILE_ICON_WHITE);
        p = line; p = buf_append(p, "LEVEL: "); p = buf_append(p, level_name(g_game.level_black));
        render_text_dedup(2, 3, 3, line);
        render_put(3, 1, who == GOMOKU_BLACK ? RENDER_TILE_ICON_BLACK : RENDER_TILE_ICON_WHITE);
        render_text_dedup(3, 4, 0, "");
        /* 底部：AI 统计（最有展示价值的一行）*/
        p = line; p = buf_append(p, "AI: NODES ");
        p = u32_to_str(p, g_game.ai_nodes);
        p = buf_append(p, " DEPTH ");
        p = u32_to_str(p, (unsigned)g_game.ai_depth);
        p = buf_append(p, " ");
        p = u32_to_str(p, g_game.ai_ms);
        p = buf_append(p, "MS");
    }
    /* 行 27 写统计（行 28/29 留白 —— 反馈 H3：底部不贴边）*/
    render_text_dedup(4, 27, 1, line);

    /* 胜负横幅 */
    if (g_game.phase == GAME_OVER) {
        const char *msg = g_game.winner == GOMOKU_BLACK ? "BLACK WINS" :
                          g_game.winner == GOMOKU_WHITE ? "WHITE WINS" : "DRAW";
        render_text_dedup_center(5, 24, msg);
    }
}

/* 画一帧。
 *   标题屏：整屏重画（logo/菜单/小棋盘），只在内容变化时落地。
 *   对局屏：光标只在"该显示"的时候才画 —— 闪烁灭那半拍、胜负之后都不画。
 * [!] 标题屏**不画 15x15 大棋盘**了（改版前它是"空棋盘 + 左上角菜单"）。
 *     所以进出对局各要**整屏抹一次**：标题屏的 logo / 小棋盘 / 说明行都在
 *     棋盘区之外，不清会留残影（任务书 §2.5.5）。 */
static void draw_frame(uint32_t now)
{
    static int last_phase = -1;
    int cr = -1, cc = -1;

    if (g_game.phase == GAME_TITLE) {
        /* 从对局/胜负回来时 force 一次全体重画，把棋盘和 HUD 清干净。 */
        draw_title(now, last_phase != GAME_TITLE);
        last_phase = GAME_TITLE;
        return;
    }

    if (last_phase != (int)g_game.phase && last_phase == (int)GAME_TITLE) {
        render_clear();                 /* 抹掉标题屏 */
        render_board_frame();
        render_board_labels();
    }
    last_phase = g_game.phase;

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
    int prev_step_ms;                         /* 菜单：间隔档 */
    int prev_page, prev_cursor;               /* 菜单：页 / 选中项 */
    int warned_no_video = 0;   /* vblank 超时只报一次，别把串口灌爆 */

    /* ---- 1) 显示初始化 ----------------------------------------------------
     * [!] 显存上电是**随机内容**（BRAM 未初始化），不填调色板和图块的话
     *     屏幕上是一片雪花。render_init 必须最先做。 */
    render_init();
    video_set_scroll(0, 0);      /* 棋类静态，滚动归零；但必须显式写一次 */
    render_clear();
    render_board_frame();        /* 阶段 1：外框 + 坐标轴，上电画一次（在 15x15 之外）*/
    render_board_labels();

    /* ---- 2) 输入与状态机 -------------------------------------------------- */
    input_init(&g_input, hw_mtime(), hw_key_raw(),
               INPUT_DEBOUNCE_MS * hw_ticks_per_ms(),
               INPUT_LONG_MS     * hw_ticks_per_ms());
    /* 难度可编译期覆盖 —— **仿真必须用 EASY**。
     * NORMAL(4 层) 一次搜索约 2 亿拍，仿真里要跑十几分钟真实时间；
     * EASY 是纯贪心、一次函数调用，秒出。见 build.ps1 -Sim。 */
    game_init(&g_game, GOMOKU_AI_LEVEL, GOMOKU_BLACK, BLINK_MS * hw_ticks_per_ms());
    /* demo_delay（AI 对弈每手间隔）在主循环里每帧按 step_ms 现算 —— 菜单可改档 */

    /* 标题屏右侧的 7x7 自动对弈小棋盘：清盘 + 计时起点（脚本走法，见 DEMO_MOVES）*/
    gomoku_reset(&s_demo);
    s_demo_i   = 0;
    s_demo_gen = 0;
    s_demo_t   = hw_mtime();

    /* 第一行就自证版本：FW=固件名，RTL=设计版本号（来自 mimpid）。
     * 两版位流装同一份固件时，靠 RTL= 那一段区分（见上面 design_rev 的说明）。 */
    uart_puts("\r\n[build] FW=GOMOKU RTL=0x");
    uart_puthex32(design_rev());
    uart_puts("\r\n");

    /* 版式自检（反馈 T10 要求"在代码里加一条自检，或启动时打印两者"）：
     * 编译期已有 title_layout_assert 卡住 MINI_BOARD_TOP == TITLE_MENU_ROW0，
     * 这里再把实际值打出来，上板时一眼能对。 */
    uart_puts("[title] menu_row0=");
    uart_putdec(TITLE_MENU_ROW0);
    uart_puts(" mini_top=");
    uart_putdec(MINI_BOARD_TOP);
    uart_puts(" mini_left=");
    uart_putdec(MINI_BOARD_LEFT);
    uart_puts(" gap=");
    uart_putdec(TITLE_MENU_GAP);
    uart_puts(" width=");
    uart_putdec(TITLE_MENU_WIDTH);
    uart_puts("\r\n");

    uart_puts("=== GOMOKU on RV32I ===\r\n");
    uart_puts("keys: SW4/5/6/7 = left/right/up/down\r\n");
    uart_puts("      title menu: up/down = move, left/right = change value, hold = OK\r\n");
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
    prev_page        = -1;
    prev_cursor      = -1;     /* -1 保证上电第一圈就把菜单当前值全打一遍 */

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
        draw_frame(now);

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
        if (g_game.menu_page != prev_page) {
            prev_page = g_game.menu_page;
            uart_puts("menu=");
            uart_puts(menu_page_name(prev_page));
            uart_puts("\r\n");
        }
        if (g_game.menu_cursor != prev_cursor) {
            prev_cursor = g_game.menu_cursor;
            uart_puts("item=");
            uart_puts(menu_item_name(&g_game));
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
