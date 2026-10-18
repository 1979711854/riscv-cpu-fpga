/* ============================================================================
 * test_render.c —— 渲染层的 x86 单测（轨道 A3）
 * ----------------------------------------------------------------------------
 * 运行：  scripts\gomoku\run_test.ps1
 *
 * 这个文件干两件事：
 *   1) **逐字节验证**渲染层写出来的显存对不对（地址、图块号、调色板字节序…）
 *   2) **在没有显示器的情况下把画面显示出来** —— 自己实现一遍 PPU 的读取路径
 *      （nametable -> pattern -> palette），把结果打成字符画。
 *      这也是"手上没有 HDMI 线/显示器"时唯一能看见棋盘的办法。
 *
 * 为什么值得这么做：渲染层的 bug 有几个是仿真测试台也难看的 ——
 *   地址算错一格、图块号形状选错、调色板字节序反了（BGR vs RGB）、
 *   光标没把旧格恢复。这些在字符画里一眼就能看出来。
 * ==========================================================================*/
#include <stdio.h>
#include <string.h>
#include "board.h"
#include "render.h"
#include "tiles.h"
#include "tiles_data.h"   /* 参考像素表（只给单测；固件里是 render.c 运行时合成）*/
#include "font.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                            \
    do {                                                            \
        if (cond) { g_pass++; }                                     \
        else {                                                      \
            g_fail++;                                               \
            printf("  [FAIL] %s:%d  %s\n", __FILE__, __LINE__, msg); \
        }                                                           \
    } while (0)

/* ---------------------------------------------------------------------------
 * 假的显存 + PPU
 * 尺寸照抄 rtl/video/video_core.v 里 vram 的例化参数
 * ------------------------------------------------------------------------- */
#define NT_BYTES  (32u * 256u)      /* 8KB  */
#define PAT_BYTES (256u * 256u)     /* 64KB */
#define PAL_BYTES (256u * 4u)       /* 1KB  */

static uint8_t g_nt[NT_BYTES];
static uint8_t g_pat[PAT_BYTES];
static uint8_t g_pal[PAL_BYTES];

static unsigned long g_writes;      /* 写字节计数 —— 用来验"移动光标只写 2 字节" */

/* render.h 声明的平台端口：测试侧就是往数组里塞 */
void vid_bulk_write(uint8_t region, uint16_t offset, const uint8_t *data, uint16_t len)
{
    uint16_t i;
    g_writes += len;
    for (i = 0; i < len; i++) {
        if (region == VID_REGION_NT) {
            if ((unsigned)offset + i < NT_BYTES)  g_nt[offset + i] = data[i];
        } else if (region == VID_REGION_PAT) {
            if ((unsigned)offset + i < PAT_BYTES) g_pat[offset + i] = data[i];
        } else {
            if ((unsigned)offset + i < PAL_BYTES) g_pal[offset + i] = data[i];
        }
    }
}

/* 模拟 PPU 的读取路径：屏幕像素 (px,py) -> 调色板索引。
 *   nametable[屏幕图块行][屏幕图块列] -> 图块号 -> pattern[图块][块内 y][块内 x]
 * 这与 rtl/video/ppu.v 的三级查表是同一条路（它内部有 6 拍流水线，这里不需要）。 */
static uint8_t ppu_pixel(int px, int py)
{
    int trow = py / TILE_W;
    int tcol = px / TILE_W;
    uint8_t tile;
    if (trow >= SCREEN_ROWS || tcol >= SCREEN_COLS) return 0;
    tile = g_nt[trow * 256 + tcol];
    return g_pat[(unsigned)tile * TILE_BYTES + (py % TILE_W) * TILE_W + (px % TILE_W)];
}

/* ---------------------------------------------------------------------------
 * 把画面打成字符画
 *   全盘总览：每个交叉点取一个特征像素，判"这儿是空 / 黑 / 白 / 光标"
 *   局部放大：一个图块 16x16 逐像素打出来（看线宽、棋子形状对不对）
 * ------------------------------------------------------------------------- */
static char classify_pixel(uint8_t idx)
{
    switch (idx) {
    case 2: case 3: return 'X';   /* 黑子主体 / 高光 */
    case 4: case 5: return 'O';   /* 白子主体 / 描边 */
    case 6:         return '+';   /* 光标 */
    case 1:         return '#';   /* 棋盘线 */
    default:        return '.';   /* 底色 */
    }
}

/* 每个交叉点采样【块内 (x=13,y=7)】这一个像素。
 * 为什么选这儿：它在棋盘线的延长线上（空点 -> 线色）、又在棋子和光标圈上
 * （有子 -> 子色；光标 -> 光标色），一个像素就能区分四种状态。
 * 选块中心 (7,7) 是不行的 —— 光标是空心圈，中心是底色，看不出光标。 */
static char sample_intersection(int r, int c)
{
    int px = (BOARD_COL0 + c) * TILE_W + 13;
    int py = (BOARD_ROW0 + r) * TILE_W + 7;
    return classify_pixel(ppu_pixel(px, py));
}

/* 把采样结果归成四类。
 * [!] 别直接拿字符比 —— 空交叉点上采样点落在**棋盘线**上，本来就该是 '#'
 *     （棋盘边缘外侧的格子才会是底色 '.'）。两者都表示"这儿没有棋子、没有光标"，
 *     所以判据必须是【四分类】而不是字符相等。 */
#define CAT_EMPTY  0
#define CAT_BLACK  1
#define CAT_WHITE  2
#define CAT_CURSOR 3

static int sample_cat(int r, int c)
{
    char ch = sample_intersection(r, c);
    if (ch == 'X') return CAT_BLACK;
    if (ch == 'O') return CAT_WHITE;
    if (ch == '+') return CAT_CURSOR;
    return CAT_EMPTY;
}

static void show_board(void)
{
    int r, c;
    printf("       ");
    for (c = 0; c < GOMOKU_N; c++) printf("%c ", 'A' + c);
    printf("\n");
    for (r = 0; r < GOMOKU_N; r++) {
        printf("   %2d  ", r + 1);
        for (c = 0; c < GOMOKU_N; c++) printf("%c ", sample_intersection(r, c));
        printf("\n");
    }
    printf("       ");
    for (c = 0; c < GOMOKU_N; c++) printf("%c ", 'A' + c);
    printf("\n      （X=黑 O=白 +=光标 .=空）\n");
}

/* 把一个 16x16 图块逐像素打出来 —— 看线宽/棋子形状/光标圈对不对 */
static void show_tile(int shape, int state)
{
    uint8_t tile = RENDER_TILE(shape, state);
    int y, x;
    printf("     图块 shape=%d state=%d (tile=%d)：\n", shape, state, tile);
    for (y = 0; y < TILE_W; y++) {
        printf("       ");
        for (x = 0; x < TILE_W; x++)
            putchar(classify_pixel(g_pat[(unsigned)tile * TILE_BYTES + y * TILE_W + x]));
        putchar('\n');
    }
}

/* ---------------------------------------------------------------------------
 * A. render_shape：15x15 上只有 9 种形状，且各形状的数量是对的
 *    内部 13x13=169，边 4x13=52，角 4
 * ------------------------------------------------------------------------- */
static void test_shapes(void)
{
    int r, c, cnt[9];
    int i;
    for (i = 0; i < 9; i++) cnt[i] = 0;
    for (r = 0; r < GOMOKU_N; r++)
        for (c = 0; c < GOMOKU_N; c++) {
            uint8_t s = render_shape(r, c);
            if (s < 9) cnt[s]++;
        }

    printf("---- A. 网格线形状 ----\n");
    printf("       内部=%d  上边=%d 下边=%d 左边=%d 右边=%d  "
           "左上=%d 右上=%d 左下=%d 右下=%d\n",
           cnt[0], cnt[1], cnt[2], cnt[3], cnt[4], cnt[5], cnt[6], cnt[7], cnt[8]);
    CHECK(cnt[0] == 169, "内部形状应 169 个（13x13）");
    CHECK(cnt[1] == 13 && cnt[2] == 13 && cnt[3] == 13 && cnt[4] == 13,
          "四条边各 13 个");
    CHECK(cnt[5] == 1 && cnt[6] == 1 && cnt[7] == 1 && cnt[8] == 1, "四个角各 1 个");
    CHECK(cnt[0] + cnt[1] + cnt[2] + cnt[3] + cnt[4]
          + cnt[5] + cnt[6] + cnt[7] + cnt[8] == 225, "九个形状加起来应覆盖全盘");
}

/* ---------------------------------------------------------------------------
 * B. render_init 写出来的调色板与图块像素
 * ------------------------------------------------------------------------- */
static void test_init(void)
{
    int i, y, x;
    int pal_ok = 1, pat_ok = 1;

    printf("---- B. render_init：调色板与图块 ----\n");
    memset(g_nt, 0xAA, sizeof(g_nt));
    memset(g_pat, 0xAA, sizeof(g_pat));
    memset(g_pal, 0xAA, sizeof(g_pal));

    render_init();

    /* 调色板：字节序必须是 B,G,R,0（对应 RTL 侧的 0xRRGGBB 小端字） */
    for (i = 0; i < TILE_N_PALETTE; i++) {
        uint32_t rgb = TILE_PALETTE[i];
        if (g_pal[i * 4 + 0] != (uint8_t)(rgb & 0xFF))       pal_ok = 0;
        if (g_pal[i * 4 + 1] != (uint8_t)((rgb >> 8) & 0xFF)) pal_ok = 0;
        if (g_pal[i * 4 + 2] != (uint8_t)((rgb >> 16) & 0xFF))pal_ok = 0;
    }
    CHECK(pal_ok, "调色板字节序应为 B,G,R,0（小端）");

    /* 图块像素：逐字节比对 tiles.h */
    for (i = 0; i < TILE_N_TOTAL; i++)
        for (y = 0; y < TILE_W; y++)
            for (x = 0; x < TILE_W; x++)
                if (g_pat[i * TILE_BYTES + y * TILE_W + x] != TILE_PATTERN[i][y * TILE_W + x])
                    pat_ok = 0;
    CHECK(pat_ok, "36 块图块像素应与 tiles.h 逐字节一致");

    /* 相邻图块不能互相踩（地址偏移算错的话会串） */
    CHECK(g_pat[TILE_BYTES - 1] == TILE_PATTERN[0][TILE_BYTES - 1], "第 0/1 块边界不应串");

    /* ---- 字库图块：render_init 应把紧凑字库放大写进 tile 36..130 ---- */
    {
        int blank_ok = 1, f_ok = 1;
        int g;

        /* 空格字模（tile 36）应全是背景色 */
        for (y = 0; y < TILE_W; y++)
            for (x = 0; x < TILE_W; x++)
                if (g_pat[FONT_TILE_BASE * TILE_BYTES + y * TILE_W + x] != FONT_BG)
                    blank_ok = 0;
        CHECK(blank_ok, "空格字模（tile 36）应全是背景色 FONT_BG");

        /* 'A' 字模应有前景色像素（不是空白）*/
        {
            int a_tile = FONT_TILE_BASE + ('A' - FONT_BASE);
            int fg = 0;
            for (y = 0; y < TILE_W && !fg; y++)
                for (x = 0; x < TILE_W && !fg; x++)
                    if (g_pat[a_tile * TILE_BYTES + y * TILE_W + x] == FONT_FG) fg = 1;
            CHECK(fg, "'A' 字模应含前景色像素");
        }

        /* 每个字模都只由 FONT_FG / FONT_BG 两种颜色组成（展开不能引入杂色）*/
        for (g = 0; g < FONT_N_GLYPHS; g++)
            for (y = 0; y < TILE_W; y++)
                for (x = 0; x < TILE_W; x++) {
                    uint8_t v = g_pat[(FONT_TILE_BASE + g) * TILE_BYTES + y * TILE_W + x];
                    if (v != FONT_FG && v != FONT_BG) f_ok = 0;
                }
        CHECK(f_ok, "字库图块只应含 FONT_FG/FONT_BG 两种颜色");
    }

    /* 字库（36..130）+ 装饰图块区（131..186）之后不该被写 */
    CHECK(g_pat[(unsigned)RENDER_TILE_MAX * TILE_BYTES] == 0xAA,
          "已用图块（0..RENDER_TILE_MAX-1）之后不该被写");
    CHECK(RENDER_TILE_MAX <= 256, "图块总数必须 ≤ 256（显存只有 256 块）");
}

/* ---------------------------------------------------------------------------
 * B2. 深色 UI / 标题屏装饰图块（2026-10-18）
 *     这几块最容易画错：描边的横线该在上还是下、底色是不是 UI 底、
 *     大 logo 的"O"到底有没有画成棋子。
 * ------------------------------------------------------------------------- */
static uint8_t pat_at(int tile, int y, int x)
{
    return g_pat[(unsigned)tile * TILE_BYTES + y * TILE_W + x];
}

static void test_theme(void)
{
    int t, y, x, gold, black, white, ui;

    printf("---- B2. 深色 UI 与标题屏装饰图块 ----\n");
    render_init();          /* 保证 g_pat 已按当前源码重新合成 */

    /* 字库底色必须就是 UI 底 —— 否则标题屏 / HUD / CoreMark 控制台会是三种底色 */
    CHECK(FONT_BG == PAL_UI_BG, "FONT_BG 必须等于 PAL_UI_BG");
    CHECK(FONT_FG == PAL_UI_FG, "FONT_FG 必须等于 PAL_UI_FG");
    CHECK(TILE_PALETTE[PAL_UI_BG] != TILE_PALETTE[PAL_BG], "UI 底色不能等于棋盘木色");

    /* 外框：必须是**木色**底 —— 它四角复用的是棋盘边角图块（木色），
     * 改成 UI 深色会在棋盘四周留下 4 个木色小方块角块。 */
    CHECK(pat_at(RENDER_TILE_FRAME_H, 0, 0) == PAL_BG, "外框横线图块底色应是棋盘木色");
    CHECK(pat_at(RENDER_TILE_FRAME_V, 0, 0) == PAL_BG, "外框竖线图块底色应是棋盘木色");
    /* 棋子图标：只出现在深色 UI 上（HUD / 标题菜单），底必须是 UI 底 */
    CHECK(pat_at(RENDER_TILE_ICON_BLACK, 0, 0) == PAL_UI_BG, "黑子图标底色应是 UI 底");
    CHECK(pat_at(RENDER_TILE_ICON_WHITE, 0, 0) == PAL_UI_BG, "白子图标底色应是 UI 底");

    /* 金色分隔线：中间两行金、上下是 UI 底 */
    CHECK(pat_at(RENDER_TILE_RULE, 7, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_RULE, 8, 15) == PAL_GOLD, "分隔线中间两行应是金色");
    CHECK(pat_at(RENDER_TILE_RULE, 0, 0) == PAL_UI_BG, "分隔线上下应是 UI 底");

    /* 选中框（2026-10-18 第二轮反馈 T4：竖线**只画框内侧**，不许戳出上下边框）
     *   上排三块：横线在 y=14..15，竖线也只占 y=14..15；
     *   下排三块：横线在 y=0..1，  竖线也只占 y=0..1；
     *   只有左/右边（L/R）是整块通高。 */
    CHECK(pat_at(RENDER_TILE_BOX_TL, 15, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_TL, 15, 15) == PAL_GOLD,
          "TL 横线在底部两端都该是金色");
    CHECK(pat_at(RENDER_TILE_BOX_TL, 0, 0) == PAL_UI_BG,
          "TL 竖线不许戳出上边框（T4）");
    CHECK(pat_at(RENDER_TILE_BOX_T, 15, 8) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_T, 0, 8) == PAL_UI_BG, "T 横线应在底部");
    CHECK(pat_at(RENDER_TILE_BOX_TR, 15, 15) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_TR, 0, 15) == PAL_UI_BG,
          "TR 横线在底部、竖线不外露");
    CHECK(pat_at(RENDER_TILE_BOX_L, 0, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_L, 8, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_L, 15, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_L, 8, 15) == PAL_UI_BG, "L 只有左侧竖线（通高）");
    CHECK(pat_at(RENDER_TILE_BOX_R, 8, 15) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_R, 8, 0) == PAL_UI_BG, "R 只有右侧竖线");
    CHECK(pat_at(RENDER_TILE_BOX_BL, 0, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_BL, 0, 15) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_BL, 15, 0) == PAL_UI_BG, "BL 横线在顶部、竖线不外露");
    CHECK(pat_at(RENDER_TILE_BOX_B, 0, 8) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_B, 15, 8) == PAL_UI_BG, "B 横线应在顶部");
    CHECK(pat_at(RENDER_TILE_BOX_BR, 0, 15) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_BR, 0, 0) == PAL_GOLD &&
          pat_at(RENDER_TILE_BOX_BR, 15, 15) == PAL_UI_BG, "BR 横线在顶部、竖线不外露");

    /* 大 logo：24 块全都要有金色（字）或棋子色（O），且只出现这几种颜色 */
    for (t = 0; t < 24; t++) {
        int tile = RENDER_TILE_LOGO_BASE + t;
        gold = black = white = ui = 0;
        for (y = 0; y < TILE_W; y++)
            for (x = 0; x < TILE_W; x++) {
                uint8_t v = pat_at(tile, y, x);
                if      (v == PAL_GOLD)   gold++;
                else if (v == PAL_BLACK)  black++;
                else if (v == PAL_WHITE)  white++;
                else if (v == PAL_UI_BG)  ui++;
                else if (v != PAL_SHADOW && v != PAL_BLACK_HI && v != PAL_WHITE_EDGE) {
                    printf("  [FAIL] logo 图块 %d 出现杂色 %d（像素 %d,%d）\n", tile, v, x, y);
                    g_fail++;
                }
            }
        CHECK(ui > 0, "logo 图块应保留 UI 底色（字母之间要能透出背景）");
        if (t / 4 == 1)      /* 第 2 个字 = 黑子 */
            CHECK(black > 0 && gold > 0, "第 2 个字应画成黑子（黑体 + 金边）");
        else if (t / 4 == 3) /* 第 4 个字 = 白子 */
            CHECK(white > 0 && gold > 0, "第 4 个字应画成白子（白体 + 金边）");
        else
            CHECK(gold > 0, "标题字母应有金色笔画");
    }
}

/* ---------------------------------------------------------------------------
 * C. nametable 地址：棋盘必须落在 (7,12) 起、每行跨 256 字节
 * ------------------------------------------------------------------------- */
static void test_nt_address(void)
{
    gomoku_t g;
    printf("---- C. nametable 地址 ----\n");
    gomoku_reset(&g);
    memset(g_nt, 0xAA, sizeof(g_nt));
    render_full(&g, -1, -1);

    CHECK(BOARD_ROW0 == 7 && BOARD_COL0 == 12, "棋盘原点应为 (行7, 列12)");
    CHECK(g_nt[BOARD_ROW0 * 256 + BOARD_COL0] == RENDER_TILE(TILE_SHAPE_TOPLEFT, RENDER_ST_EMPTY),
          "左上角格应是「左上角形状 + 空」");
    CHECK(g_nt[(BOARD_ROW0 + 14) * 256 + (BOARD_COL0 + 14)]
          == RENDER_TILE(TILE_SHAPE_BOTRIGHT, RENDER_ST_EMPTY), "右下角格应是「右下角形状」");
    /* T6 起天元画星位点（render_tile_for 优先级：星位 > 空；与 tb_gomoku.v 的
       T_STAR 断言同口径）*/
    CHECK(g_nt[(BOARD_ROW0 + 7) * 256 + (BOARD_COL0 + 7)]
          == RENDER_TILE_STAR, "正中天元应是星位点");
    /* 棋盘以外不许被碰 */
    CHECK(g_nt[(BOARD_ROW0 - 1) * 256 + BOARD_COL0] == 0xAA, "棋盘上方不该被写");
    CHECK(g_nt[BOARD_ROW0 * 256 + (BOARD_COL0 - 1)] == 0xAA, "棋盘左侧不该被写");
}

/* ---------------------------------------------------------------------------
 * D. 落子与光标：整条 PPU 读取路径还原出来必须和棋盘状态一致
 * ------------------------------------------------------------------------- */
static void test_render_states(void)
{
    gomoku_t g;
    int r, c, bad = 0, cbad = 0;

    printf("---- D. 落子 / 光标（沿 PPU 读取路径还原）----\n");
    gomoku_reset(&g);

    /* 摆一个能同时覆盖四种状态的局面 */
    gomoku_place(&g, 7, 7);    /* 黑 */
    gomoku_place(&g, 7, 8);    /* 白 */
    gomoku_place(&g, 6, 7);    /* 黑 */
    gomoku_place(&g, 8, 8);    /* 白 */
    gomoku_place(&g, 6, 6);    /* 黑 */

    render_full(&g, 7, 6);     /* 光标放在 (7,6)：那里是空的 */

    /* 逐点还原，与棋盘状态对拍 */
    for (r = 0; r < GOMOKU_N; r++) {
        for (c = 0; c < GOMOKU_N; c++) {
            int got = sample_cat(r, c);
            int want;
            if (r == 7 && c == 6)                       want = CAT_CURSOR;
            else if (g.cell[r][c] == GOMOKU_BLACK)      want = CAT_BLACK;
            else if (g.cell[r][c] == GOMOKU_WHITE)      want = CAT_WHITE;
            else                                        want = CAT_EMPTY;
            if (got != want) {
                bad++;
                if (bad <= 3)
                    printf("  [FAIL] (%d,%d) 画面类别 %d，应为 %d（字符 '%c'）\n",
                           r, c, got, want, sample_intersection(r, c));
            }
        }
    }
    CHECK(bad == 0, "225 个交叉点逐点还原都应与棋盘一致");

    /* 光标挪走之后，旧位置必须恢复成"空"（不是还留着光标） */
    render_move_cursor(&g, 7, 6, 7, 5);
    CHECK(sample_cat(7, 6) == CAT_EMPTY, "光标移走后旧位置应恢复为空");
    CHECK(sample_cat(7, 5) == CAT_CURSOR, "新位置应显示光标");

    /* 再挪一次，确认来回都对 */
    render_move_cursor(&g, 7, 5, 8, 5);
    CHECK(sample_cat(7, 5) == CAT_EMPTY, "再挪一次后旧位置仍应恢复");
    CHECK(sample_cat(8, 5) == CAT_CURSOR, "再挪一次后新位置应是光标");

    /* 挪到棋子上：正常不会发生（落子合法性拦着），但不该崩 */
    render_move_cursor(&g, 8, 5, 7, 7);
    CHECK(sample_cat(7, 7) == CAT_CURSOR, "光标停在棋子上时光标仍应画出来");
    (void)cbad;
}

/* ---------------------------------------------------------------------------
 * E. 移动光标只写 2 个字节 —— 这是"没有精灵层"下的性能关键
 * ------------------------------------------------------------------------- */
static void test_cursor_cost(void)
{
    gomoku_t g;
    unsigned long before;

    printf("---- E. 移动光标/落子的字节开销 ----\n");
    gomoku_reset(&g);
    render_full(&g, 7, 7);

    before = g_writes;
    render_move_cursor(&g, 7, 7, 7, 8);
    printf("       移动光标一次写 %lu 字节\n", g_writes - before);
    CHECK(g_writes - before == 2, "移动光标应只写 2 个字节（旧格 + 新格）");

    gomoku_place(&g, 7, 7);
    before = g_writes;
    render_cell(&g, 7, 7, 7, 8);
    printf("       落子一次写   %lu 字节\n", g_writes - before);
    CHECK(g_writes - before == 1, "落子应只写 1 个字节");

    before = g_writes;
    render_full(&g, 7, 8);
    printf("       全盘重画一次写 %lu 字节（225 格）\n", g_writes - before);
    CHECK(g_writes - before == 225, "全盘重画应恰好 225 字节");
}

/* ---------------------------------------------------------------------------
 * F. HUD 文字：字符 -> 字库图块号、小写折叠、居中、越界落空格
 * ------------------------------------------------------------------------- */
static void test_text(void)
{
    printf("---- F. HUD 文字 ----\n");
    memset(g_nt, 0xAA, sizeof(g_nt));
    render_init();

    /* 写一行文字，验证 nametable 里每个字符落到正确的字库图块 */
    render_text(1, 0, "TURN: BLACK");
    CHECK(g_nt[1 * 256 + 0] == FONT_TILE_BASE + ('T' - FONT_BASE), "第 0 列应是 'T' 字模");
    CHECK(g_nt[1 * 256 + 4] == FONT_TILE_BASE + (':' - FONT_BASE), "第 4 列应是 ':' 字模");
    CHECK(g_nt[1 * 256 + 5] == FONT_TILE_BASE, "第 5 列应是空格字模");
    CHECK(g_nt[1 * 256 + 6] == FONT_TILE_BASE + ('B' - FONT_BASE), "第 6 列应是 'B' 字模");

    /* 小写折叠到大写：'a' 应映射到 'A' 的字模 */
    render_text(2, 0, "abc");
    CHECK(g_nt[2 * 256 + 0] == FONT_TILE_BASE + ('A' - FONT_BASE), "'a' 应折叠到 'A'");
    CHECK(g_nt[2 * 256 + 1] == FONT_TILE_BASE + ('B' - FONT_BASE), "'b' 应折叠到 'B'");
    CHECK(g_nt[2 * 256 + 2] == FONT_TILE_BASE + ('C' - FONT_BASE), "'c' 应折叠到 'C'");

    /* 居中：len=5 的字符串起点应在 (40-5)/2 = 17 列 */
    render_text_center(3, "HELLO");
    CHECK(g_nt[3 * 256 + 17] == FONT_TILE_BASE + ('H' - FONT_BASE), "居中起点应在列 17");

    /* 未定义字符 -> 空格字模。用 0x7F（DEL，在 0x20..0x7E 之外）当未定义字符；
     * 别用 '@' —— '@' 是 0x40，本来就在字库范围内，会命中它自己的字模。 */
    render_text(4, 0, "\x7F");
    CHECK(g_nt[4 * 256 + 0] == FONT_TILE_BASE, "未定义字符应落空格字模");

    /* [!] 2026-10-07 板上实踩：**变短的字符串会留下上一次的残字**。
     * 标题屏从 "LEVEL: NORMAL"(13 字) 切到 "LEVEL: EASY"(11 字) 时，居中起点由
     * 列 13 变成列 14，两端各留一个 'L' ⇒ 屏幕显示成 "LLEVEL: EASYL"。
     * 修法是 render_text 写完补空格到行尾。下面两段把这个行为锁住。 */
    render_text(5, 0, "LEVEL: NORMAL");
    render_text(5, 0, "LEVEL: EASY");
    CHECK(g_nt[5 * 256 + 11] == FONT_TILE_BASE, "变短后第 11 列应被补成空格");
    CHECK(g_nt[5 * 256 + 12] == FONT_TILE_BASE, "变短后第 12 列应被补成空格");

    /* 居中：13 字占列 13..25，换成 11 字后占列 14..24 —— 两端都不该有残字 */
    render_text_center(6, "LEVEL: NORMAL");
    render_text_center(6, "LEVEL: EASY");
    CHECK(g_nt[6 * 256 + 13] == FONT_TILE_BASE, "居中变短后左端应被补成空格");
    CHECK(g_nt[6 * 256 + 25] == FONT_TILE_BASE, "居中变短后右端应被补成空格");

    /* [!] 2026-10-10：**整行清空**的原语。main.c 的 draw_hud() 靠它清掉
     * "标题屏专用的行"，否则进对局后屏幕上会同时出现两个 LEVEL
     * （标题屏画在行 3、对局屏画在行 2）。这条锁住 render_text(row,0,"") 的行为。 */
    render_text(7, 0, "LEVEL: NORMAL");
    render_text(7, 0, "");                       /* 整行清空 */
    {
        int k, all_blank = 1;
        for (k = 0; k < SCREEN_COLS; k++)
            if (g_nt[7 * 256 + k] != FONT_TILE_BASE) all_blank = 0;
        CHECK(all_blank, "render_text(row,0,\"\") 应把整行铺成空格字模");
    }
}

/* ------------------------------------------------------------------------- */
int main(void)
{
    gomoku_t g;

    printf("=== 五子棋 轨道 A3（渲染层）单测 ===\n");
    printf("调色板 %d 项 / 图块 %d 块 × %d 字节 = %d 字节（常驻内存）\n\n",
           TILE_N_PALETTE, TILE_N_TOTAL, TILE_BYTES, TILE_N_TOTAL * TILE_BYTES);

    test_shapes();
    test_init();
    test_theme();
    test_nt_address();
    test_render_states();
    test_cursor_cost();
    test_text();

    /* ---- 把画面显示出来（没有显示器时唯一能看见棋盘的办法）---- */
    printf("\n================ 画面预览（模拟 PPU 读显存后的结果）================\n");
    gomoku_reset(&g);
    gomoku_place(&g, 7, 7);   /* 黑天元 */
    gomoku_place(&g, 7, 8);   /* 白 */
    gomoku_place(&g, 6, 7);   /* 黑 */
    gomoku_place(&g, 8, 8);   /* 白 */
    gomoku_place(&g, 6, 6);   /* 黑 */
    gomoku_place(&g, 6, 5);   /* 白 —— 凑一个形状好看点 */
    render_init();
    render_full(&g, 7, 6);    /* 光标在 (7,6) */
    show_board();

    printf("\n---- 局部放大：棋盘内部格（线宽/棋子形状）----\n");
    show_tile(TILE_SHAPE_INNER, RENDER_ST_EMPTY);
    show_tile(TILE_SHAPE_INNER, RENDER_ST_BLACK);
    show_tile(TILE_SHAPE_INNER, RENDER_ST_CURSOR);
    printf("\n---- 局部放大：左上角格 ----\n");
    show_tile(TILE_SHAPE_TOPLEFT, RENDER_ST_WHITE);
    printf("=================================================================\n");

    printf("\nchecks=%d  errors=%d\n", g_pass + g_fail, g_fail);
    if (g_fail == 0) printf("=== PASS ===\n");
    else             printf("=== FAIL ===\n");
    return g_fail == 0 ? 0 : 1;
}
