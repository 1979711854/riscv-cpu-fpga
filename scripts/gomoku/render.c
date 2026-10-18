/* ============================================================================
 * render.c —— 五子棋渲染层的实现（轨道 A3）
 * ----------------------------------------------------------------------------
 * [!] 不用 libc（没有 memset/memcpy），要能原样编进 RV32 固件。
 *     唯一的平台依赖是 vid_bulk_write()，在 render.h 里声明、由平台实现。
 * ==========================================================================*/
#include "render.h"
#include "tiles.h"
#include "font.h"

/* 调色板下标 —— 与 gen_tiles.py 的 PAL 顺序、palette.h 的 TILE_PALETTE 一致。
 * 合成图块（红标/星位/外框/图标/logo/选中框）用这些常量取色，不硬编码数字。
 * [!] 2026-10-18 起调色板拆到 palette.h（CoreMark 的文本控制台也 include 它），
 *     所以这里不再自己 #define，直接由 tiles.h -> palette.h 提供。 */

/* 四条边哪几条有线（up<<3 | down<<2 | left<<1 | right）-> shape 0..8
 * 只有 9 种组合会出现在 15x15 的棋盘上：
 *   15=内部  7=上边 11=下边 13=左边 14=右边  5=左上 6=右上 9=左下 10=右下
 * 其余（1x1 棋盘之类的退化情况）落到 0（内部形状），反正不会出现。
 * [!] 这张表必须与 gen_tiles.py 的 SHAPES 顺序一致。 */
static const uint8_t SHAPE_LUT[16] = {
    /* 0 0000 */ 0,
    /* 1 0001 */ 0,
    /* 2 0010 */ 0,
    /* 3 0011 */ 0,
    /* 4 0100 */ 0,
    /* 5 0101 */ 5,   /* 上 + 左  = 左上角 */
    /* 6 0110 */ 6,   /* 上 + 右  = 右上角 */
    /* 7 0111 */ 1,   /* 上边 */
    /* 8 1000 */ 0,
    /* 9 1001 */ 7,   /* 下 + 左  = 左下角 */
    /*10 1010 */ 8,   /* 下 + 右  = 右下角 */
    /*11 1011 */ 2,   /* 下边 */
    /*12 1100 */ 0,
    /*13 1101 */ 3,   /* 左边 */
    /*14 1110 */ 4,   /* 右边 */
    /*15 1111 */ 0    /* 内部 */
};

uint8_t render_shape(int r, int c)
{
    uint8_t m = 0;
    if (r > 0)              m |= 8u;   /* 上 */
    if (r < GOMOKU_N - 1)   m |= 4u;   /* 下 */
    if (c > 0)              m |= 2u;   /* 左 */
    if (c < GOMOKU_N - 1)   m |= 1u;   /* 右 */
    return SHAPE_LUT[m];
}

/* 任意 rows x cols 子盘上的形状（标题屏 7x7 小棋盘用）。
 * [!] 不能直接给 render_shape 传 7x7 之外的尺寸 —— 它写死 GOMOKU_N，
 *     拿去画小盘会把"下边"当成内部。 */
static uint8_t shape_dim(int r, int c, int rows, int cols)
{
    uint8_t m = 0;
    if (r > 0)          m |= 8u;
    if (r < rows - 1)   m |= 4u;
    if (c > 0)          m |= 2u;
    if (c < cols - 1)   m |= 1u;
    return SHAPE_LUT[m];
}

/* 星位点：天元 + 四个小目（15x15 交叉点）。落子/光标盖在星位上时星位自然被遮。 */
static int render_is_star(int r, int c)
{
    return (r == 3 && c == 3) || (r == 3 && c == 11) ||
           (r == 7 && c == 7) ||
           (r == 11 && c == 3) || (r == 11 && c == 11);
}

/* 字符 → 字库图块号。小写折叠到大写，范围外/不可见字符落空格图块。 */
static uint8_t glyph_tile(int ch)
{
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch >= FONT_BASE && ch < FONT_BASE + FONT_N_GLYPHS)
        return (uint8_t)(FONT_TILE_BASE + (ch - FONT_BASE));
    return (uint8_t)FONT_TILE_BASE;          /* 空格 */
}

uint8_t render_tile_for(const gomoku_t *g, int r, int c, int cr, int cc)
{
    uint8_t shape = render_shape(r, c);
    int     is_last = (g->last_r == r && g->last_c == c);   /* 最后一手 */

    if (r == cr && c == cc) {                       /* 光标优先 */
        return RENDER_TILE(shape, RENDER_ST_CURSOR);
    }
    if (g->cell[r][c] == GOMOKU_BLACK) {
        if (is_last) return (uint8_t)(RENDER_TILE_LAST_BASE + shape * 2 + 0);
        return RENDER_TILE(shape, RENDER_ST_BLACK);
    }
    if (g->cell[r][c] == GOMOKU_WHITE) {
        if (is_last) return (uint8_t)(RENDER_TILE_LAST_BASE + shape * 2 + 1);
        return RENDER_TILE(shape, RENDER_ST_WHITE);
    }
    if (render_is_star(r, c)) return RENDER_TILE_STAR;
    return RENDER_TILE(shape, RENDER_ST_EMPTY);
}

/* 写一个 nametable 字节。地址 = (BOARD_ROW0+r)*256 + (BOARD_COL0+c) */
static void put_nt(int r, int c, uint8_t tile)
{
    uint16_t off = (uint16_t)((BOARD_ROW0 + r) * 256 + (BOARD_COL0 + c));
    vid_bulk_write(VID_REGION_NT, off, &tile, 1);
}

/* 写一个 nametable 字节（【绝对】行/列 0..29 / 0..39）。HUD 图标/坐标轴/外框逐格写用它。 */
static void put_abs(int row, int col, uint8_t tile)
{
    uint16_t off = (uint16_t)(row * 256 + col);
    vid_bulk_write(VID_REGION_NT, off, &tile, 1);
}

void render_put(int row, int col, uint8_t tile)
{
    if (row < 0 || row >= SCREEN_ROWS || col < 0 || col >= SCREEN_COLS) return;
    put_abs(row, col, tile);
}

void render_cell(const gomoku_t *g, int r, int c, int cr, int cc)
{
    if (r < 0 || r >= GOMOKU_N || c < 0 || c >= GOMOKU_N) return;
    put_nt(r, c, render_tile_for(g, r, c, cr, cc));
}

void render_full(const gomoku_t *g, int cr, int cc)
{
    int r, c;
    for (r = 0; r < GOMOKU_N; r++)
        for (c = 0; c < GOMOKU_N; c++)
            put_nt(r, c, render_tile_for(g, r, c, cr, cc));
}

void render_move_cursor(const gomoku_t *g, int oldr, int oldc, int newr, int newc)
{
    /* 旧位置按"没有光标"重画，新位置带上光标 —— 正好 2 个字节。
     * 注意别用 render_cell(..., newr, newc) 去重画旧位置：那样光标会跟过去。 */
    render_cell(g, oldr, oldc, -1, -1);
    render_cell(g, newr, newc, newr, newc);
}

void render_clear(void)
{
    /* 用【空格字模】（16x16 纯底色图块）铺满整屏 40x30。HUD 文字画在上面，
     * 底色干净才好看 —— 原来的"内部形状空格"带网格线，会让留白区变成网格底。 */
    uint8_t row[SCREEN_COLS];
    int r, c;
    for (c = 0; c < SCREEN_COLS; c++) row[c] = (uint8_t)FONT_TILE_BASE;
    for (r = 0; r < SCREEN_ROWS; r++)
        vid_bulk_write(VID_REGION_NT, (uint16_t)(r * 256), row, (uint16_t)SCREEN_COLS);
    /* [!] 整屏被抹平了 ⇒ 幂等写的缓存必须作废，否则下次 render_text_dedup
     *     会认为"内容没变"而跳过，那一行就【永远空白】。 */
    render_dedup_reset();
}

/* ---------------------------------------------------------------------------
 * 棋盘外框 + 坐标轴（阶段 1 静态装饰）。都画在 15x15 之外，上电各调一次即可；
 * render_full 每帧全刷只碰棋盘区，不会覆盖它们。
 * ------------------------------------------------------------------------- */
void render_frame_at(int r0, int c0, int n)
{
    int i;
    /* 四角复用棋盘边角图块（shape 5/6/7/8 空状态）—— 与棋盘边角同款，不另做图块。 */
    put_abs(r0 - 1, c0 - 1, RENDER_TILE(TILE_SHAPE_TOPLEFT,  RENDER_ST_EMPTY));
    put_abs(r0 - 1, c0 + n, RENDER_TILE(TILE_SHAPE_TOPRIGHT, RENDER_ST_EMPTY));
    put_abs(r0 + n, c0 - 1, RENDER_TILE(TILE_SHAPE_BOTLEFT,  RENDER_ST_EMPTY));
    put_abs(r0 + n, c0 + n, RENDER_TILE(TILE_SHAPE_BOTRIGHT, RENDER_ST_EMPTY));
    /* 上下横边 */
    for (i = 0; i < n; i++) {
        put_abs(r0 - 1,    c0 + i, RENDER_TILE_FRAME_H);
        put_abs(r0 + n,    c0 + i, RENDER_TILE_FRAME_H);
    }
    /* 左右竖边 */
    for (i = 0; i < n; i++) {
        put_abs(r0 + i, c0 - 1, RENDER_TILE_FRAME_V);
        put_abs(r0 + i, c0 + n, RENDER_TILE_FRAME_V);
    }
}

void render_board_frame(void)
{
    render_frame_at(BOARD_ROW0, BOARD_COL0, GOMOKU_N);
}

/* 子盘区域：只有棋子/空格，没有光标、星位、最后一手标记。
 * 一行一次 vid_bulk_write（cols 个字节），比逐格写少 cols-1 次调用。 */
void render_board_region(const gomoku_t *g, int r0, int c0, int rows, int cols,
                         int sr, int sc)
{
    uint8_t line[GOMOKU_N];
    int r, c;

    if (rows > SCREEN_COLS) rows = SCREEN_COLS;
    for (r = 0; r < rows; r++) {
        for (c = 0; c < cols; c++) {
            uint8_t shape = shape_dim(r, c, rows, cols);
            uint8_t st    = RENDER_ST_EMPTY;
            uint8_t v     = g->cell[r0 + r][c0 + c];
            if (v == GOMOKU_BLACK)      st = RENDER_ST_BLACK;
            else if (v == GOMOKU_WHITE) st = RENDER_ST_WHITE;
            line[c] = RENDER_TILE(shape, st);
        }
        vid_bulk_write(VID_REGION_NT, (uint16_t)((sr + r) * 256 + sc), line, (uint16_t)cols);
    }
}

void render_board_labels(void)
{
    int i;
    /* 列坐标 A-O：外框上方一行 */
    render_text(BOARD_ROW0 - 2, BOARD_COL0, "ABCDEFGHIJKLMNO");
    /* 行坐标 1-15：外框左侧，右对齐到 BOARD_COL0-2 列（十位在 -3 列）*/
    for (i = 0; i < GOMOKU_N; i++) {
        int n   = i + 1;
        int row = BOARD_ROW0 + i;
        if (n >= 10) put_abs(row, BOARD_COL0 - 3, glyph_tile('0' + n / 10));
        put_abs(row, BOARD_COL0 - 2, glyph_tile('0' + n % 10));
    }
}

/* ---------------------------------------------------------------------------
 * HUD 文字
 * ------------------------------------------------------------------------- */
/* ---------------------------------------------------------------------------
 * 把 (col, s) 摊成【整行】图块索引：先铺满空格，再把文字盖上去。
 * [!] 必须整行铺，不能"只写字符串本身" —— 那样会留下上一次的残字，而且【左端也留】：
 *     2026-10-07 板上实踩，标题屏从 "LEVEL: NORMAL"(13 字) 切到 "LEVEL: EASY"(11 字)，
 *     居中起点由列 13 变成 14、终点由 25 变成 24，两端各留一个 'L'
 *     ⇒ 屏幕显示成 "LLEVEL: EASYL"。（第一版只补了行尾，测试当场抓出左端还漏。）
 * ------------------------------------------------------------------------- */
static void build_line(uint8_t *line, int col, const char *s)
{
    int i;
    for (i = 0; i < SCREEN_COLS; i++) line[i] = (uint8_t)FONT_TILE_BASE;
    i = 0;
    while (s[i] != '\0' && col + i < SCREEN_COLS) {
        int ch = (int)(unsigned char)s[i];
        if (col + i >= 0) line[col + i] = glyph_tile(ch);
        i++;
    }
}

void render_text(int row, int col, const char *s)
{
    /* 整行一次 vid_bulk_write 比逐字符写快得多。 */
    uint8_t line[SCREEN_COLS];
    build_line(line, col, s);
    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256), line, (uint16_t)SCREEN_COLS);
}

void render_text_span(int row, int col, const char *s)
{
    /* [!] 只写这几个格子，**不铺整行**。
     *     用途：和其他内容共享同一行的短标签（标题屏的 "AI VS AI"、LAST COREMARK
     *     那三行）。用 render_text 会把整行先铺成空格，把同一行上的选中框/说明行
     *     一起抹掉 —— 2026-10-18 第二轮反馈里"选中框缺一段"就是这么来的。 */
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        int c = col + i;
        if (c < 0 || c >= SCREEN_COLS) break;
        put_abs(row, c, glyph_tile((int)(unsigned char)s[i]));
    }
}

void render_text_center(int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text(row, (SCREEN_COLS - len) / 2, s);
}

/* ---------------------------------------------------------------------------
 * [2026-10-17 加] **幂等写**：内容没变就不写。
 * ---------------------------------------------------------------------------
 * 为什么需要：`draw_hud()` 是【每帧】调的，而 `render_text` 每次都整行重铺
 *   ～40 个图块（哪怕内容一模一样）。写的时候若已经出了 vblank 窗口，屏上就
 *   看得见这一行在闪 —— 2026-10-17 用户实测反馈："AI VS AI 下 STEP 那行字有闪烁"。
 *   （其它 HUD 行内容平时不变、所以看不出；AI 对弈时每帧都在推进，最容易暴露。）
 *
 * 用法：`slot` 由调用方给一个【固定编号】(0..RENDER_DEDUP_SLOTS-1)，同一槽位永远
 *   对应同一行；换行/换内容时**换槽位**，别复用 —— 否则会拿旧内容当基准比。
 *   `col` 一并参与比较（同一个 slot 换列也算变化）。
 *
 * RAM 代价：RENDER_DEDUP_SLOTS × SCREEN_COLS 字节（6×40 = 240 B），
 *   只给会频繁重画的 HUD 行用，不是全局缓存。
 * ------------------------------------------------------------------------- */
#define RENDER_DEDUP_SLOTS 6
static uint8_t dedup_cache[RENDER_DEDUP_SLOTS][SCREEN_COLS + 1];   /* +1 存 col */
static uint8_t dedup_valid;

void render_text_dedup(int slot, int row, int col, const char *s)
{
    uint8_t line[SCREEN_COLS];
    int     i;

    if (slot < 0 || slot >= RENDER_DEDUP_SLOTS) {      /* 槽位越界就别缓存，老老实实写 */
        render_text(row, col, s);
        return;
    }

    build_line(line, col, s);

    if (dedup_valid & (uint8_t)(1u << slot)) {
        if (dedup_cache[slot][SCREEN_COLS] == (uint8_t)col) {
            for (i = 0; i < SCREEN_COLS; i++)
                if (dedup_cache[slot][i] != line[i]) break;
            if (i == SCREEN_COLS) return;              /* 整行一字不差 ⇒ 跳过这次写 */
        }
    }

    for (i = 0; i < SCREEN_COLS; i++) dedup_cache[slot][i] = line[i];
    dedup_cache[slot][SCREEN_COLS] = (uint8_t)col;
    dedup_valid |= (uint8_t)(1u << slot);

    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256), line, (uint16_t)SCREEN_COLS);
}

void render_dedup_reset(void)
{
    dedup_valid = 0;
}

void render_text_dedup_center(int slot, int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text_dedup(slot, row, (SCREEN_COLS - len) / 2, s);
}

/* ---- 阶段 1 合成图块：在 render_init 里现算，不占固件 .rodata ---------------
 * 刻意【不用 libc】（没有 memcpy），用显式循环搬像素。 */

/* 棋盘图块的合成函数（定义在下面 render_init 之前，这里先声明）。 */
static void synth_board_tile(uint8_t *buf, int shape, int state);

/* 拷贝棋盘图块并在右上角叠一个红色小三角（最后一手标记）。color: 0=黑 1=白。 */
static void synth_last_move(uint8_t *buf, int shape, int color)
{
    int y, x;
    synth_board_tile(buf, shape, color + 1);     /* BLACK=1 / WHITE=2 */
    /* 右上角 4x4 小三角（顶点朝左下）。避开中心子（半径 6）与行/列 7-8 的网格线。 */
    for (y = 0; y < 4; y++)
        for (x = 12 + y; x < TILE_W; x++)
            buf[y * TILE_W + x] = PAL_RED;
}

/* 星位点：内部空格图块 + 中心 4x4 实心点（比网格线粗，一眼能认出是星位）。 */
static void synth_star(uint8_t *buf)
{
    int y, x;
    synth_board_tile(buf, TILE_SHAPE_INNER, TILE_ST_EMPTY);
    for (y = 6; y <= 9; y++)
        for (x = 6; x <= 9; x++)
            buf[y * TILE_W + x] = PAL_LINE;
}

/* 外框纯横线 / 纯竖线（2px，与棋盘线同色）。四角复用棋盘边角图块。
 * [!] 2026-10-18 保留 **PAL_BG（木色）底**，不要改成 UI 深色：
 *     外框四角复用的是棋盘边角图块（木色），只把横/竖线改成深色底，
 *     棋盘四周就会出现 4 个"木色小方块"角块，看着像画错了。
 *     木框 + 木棋盘 = 一整块木色棋盘，外面才是深色 UI —— 这正是任务书
 *     §2.2.1 要的"深色 UI + 木色棋盘"两色体系。 */
static void synth_frame_h(uint8_t *buf)
{
    int i, x;
    for (i = 0; i < TILE_BYTES; i++) buf[i] = PAL_BG;
    for (x = 0; x < TILE_W; x++) { buf[7 * TILE_W + x] = PAL_LINE; buf[8 * TILE_W + x] = PAL_LINE; }
}

static void synth_frame_v(uint8_t *buf)
{
    int i, y;
    for (i = 0; i < TILE_BYTES; i++) buf[i] = PAL_BG;
    for (y = 0; y < TILE_W; y++) { buf[y * TILE_W + 7] = PAL_LINE; buf[y * TILE_W + 8] = PAL_LINE; }
}

/* 纯底棋子图标（无网格线）。color/hi_color 与 gen_tiles.py 的 draw_stone 同义；
 * 用 2x 整数坐标替代浮点（dx = x-7.5 ⇒ 2dx = 2x-15），避免链接 libm。 */
static void synth_icon(uint8_t *buf, int color, int hi_color)
{
    int y, x;
    for (y = 0; y < TILE_W; y++) {
        for (x = 0; x < TILE_W; x++) {
            int dx = 2 * x - (TILE_W - 1);
            int dy = 2 * y - (TILE_W - 1);
            int d2 = dx * dx + dy * dy;
            if (d2 <= 144) {                              /* (2*STONE_R)^2 = 144 */
                int hx = dx + 4, hy = dy + 4;             /* 高光圆心左/上偏 2px */
                buf[y * TILE_W + x] = (uint8_t)((hx * hx + hy * hy <= 16) ? hi_color : color);
            } else {
                /* 2026-10-18：图标现在只出现在深色 UI 上（标题屏菜单 + 对局 HUD），
                 * 背景跟着 FONT_BG 走，否则会出现一个个木色小方块。 */
                buf[y * TILE_W + x] = PAL_UI_BG;
            }
        }
    }
}

/* ---------------------------------------------------------------------------
 * 标题屏装饰：4x 大 logo / 金色选中框 / 金色分隔线（2026-10-18）
 * ---------------------------------------------------------------------------
 * [!] 全部在 render_init() 里现算，源码里只有一小段循环，**没有 24 块 × 256B
 *     的常量表**（那会把 RT-Thread 镜像顶爆，见任务书 §2.4）。
 * [!] 图块是 16x16，没有精灵层、没有半透明 —— 所以"投影"是在合成时把
 *     字模/棋子整体往右下偏 2 像素再画一遍，不是运行时叠加。
 * ------------------------------------------------------------------------- */

/* logo 一个字母（或一颗棋子）占 2x2 图块 = 32x32 像素。 */
#define LOGO_CELL (RENDER_LOGO_TILE_W * TILE_W)          /* 32 */
#define LOGO_OX   ((LOGO_CELL - FONT_W * RENDER_LOGO_SCALE) / 2)   /* 6  */
#define LOGO_OY   ((LOGO_CELL - FONT_H * RENDER_LOGO_SCALE) / 2)   /* 2  */
#define LOGO_SHADOW 2                                    /* 投影偏移（像素） */

/* 字模像素：gx/gy 是 0..31 的 logo 内坐标。1 = 亮。 */
static int logo_glyph_px(const uint8_t *rows, int gx, int gy)
{
    int fx, fy;
    if (gx < LOGO_OX || gy < LOGO_OY) return 0;           /* 先挡住负下标 —— C 的
                                                          * 负数除法朝 0 截断，
                                                          * 会错误地落回 fx=0 */
    fx = (gx - LOGO_OX) / RENDER_LOGO_SCALE;
    fy = (gy - LOGO_OY) / RENDER_LOGO_SCALE;
    if (fx >= FONT_W || fy >= FONT_H) return 0;
    return (rows[fy] >> (FONT_W - 1 - fx)) & 1;
}

/* 棋子像素：stone = 1 黑 / 2 白。返回该像素该用的调色板下标，0xFF = 不属于棋子。 */
static uint8_t logo_stone_px(int gx, int gy, int stone)
{
    int dx = 2 * gx - (LOGO_CELL - 1);
    int dy = 2 * gy - (LOGO_CELL - 1);
    int d2 = dx * dx + dy * dy;
    int hx, hy;

    if (d2 > 900) return 0xFF;                            /* r = 15 之外 */
    if (d2 >= 676) return (uint8_t)PAL_GOLD;              /* r 13..15：金边
                                                           * （深底上黑子没有边
                                                           *  就看不见） */
    hx = dx + 8; hy = dy + 8;                             /* 高光偏左上 4px */
    if (hx * hx + hy * hy <= 64)
        return (uint8_t)(stone == 1 ? PAL_BLACK_HI : PAL_WHITE_EDGE);
    return (uint8_t)(stone == 1 ? PAL_BLACK : PAL_WHITE);
}

/* 合成一块 logo 图块：ch 为字符；stone != 0 时忽略字模、画棋子。 */
static void synth_logo_tile(uint8_t *buf, char ch, int stone, int qx, int qy)
{
    const uint8_t *rows = FONT_GLYPH[(int)ch - FONT_BASE];
    int x, y;

    for (y = 0; y < TILE_W; y++) {
        for (x = 0; x < TILE_W; x++) {
            int gx = qx * TILE_W + x;
            int gy = qy * TILE_W + y;
            uint8_t v = (stone ? logo_stone_px(gx, gy, stone)
                               : (logo_glyph_px(rows, gx, gy) ? (uint8_t)PAL_GOLD : 0xFF));
            if (v == 0xFF) {
                /* 投影：本像素的左上 LOGO_SHADOW 处有笔画 ⇒ 这里落阴影。
                 * 效果 = 笔画整体往右下偏 2px 的那一份。 */
                int sgx = gx - LOGO_SHADOW, sgy = gy - LOGO_SHADOW;
                int ink = 0;
                if (sgx >= 0 && sgy >= 0)
                    ink = stone ? (logo_stone_px(sgx, sgy, stone) != 0xFF)
                                : logo_glyph_px(rows, sgx, sgy);
                v = (uint8_t)(ink ? PAL_SHADOW : PAL_UI_BG);
            }
            buf[y * TILE_W + x] = v;
        }
    }
}

/* 选中框的 8 块图块：2px 金色描边，底是 UI 深色。
 * kind: 0=TL 1=T 2=TR 3=L 4=R 5=BL 6=B 7=BR
 *   上排三块的横线在**底部**（紧贴文字行），下排三块的横线在**顶部**。 */
static void synth_box(uint8_t *buf, int kind)
{
    int x, y;
    int hline_bottom = (kind <= 2);
    int hline_top    = (kind >= 5);
    int vleft        = (kind == 0 || kind == 3 || kind == 5);
    int vright       = (kind == 2 || kind == 4 || kind == 7);
    /* [!] 竖线只画在**框内侧**（2026-10-18 第二轮反馈 T4）：
     *     角块如果让竖线贯穿整块 16px，就会从上下边框外面戳出去 14px，
     *     看起来像"金条超出框"。所以上排角块的竖线只占 y=14..15（正好接上边框），
     *     下排角块只占 y=0..1，只有左右两条边（L/R）才是整块通高。 */
    int vy0 = hline_bottom ? 14 : 0;
    int vy1 = hline_top    ?  1 : (TILE_W - 1);

    for (y = 0; y < TILE_W; y++)
        for (x = 0; x < TILE_W; x++)
            buf[y * TILE_W + x] = PAL_UI_BG;

    if (hline_bottom) {
        for (x = 0; x < TILE_W; x++) {
            buf[14 * TILE_W + x] = PAL_GOLD;
            buf[15 * TILE_W + x] = PAL_GOLD;
        }
    }
    if (hline_top) {
        for (x = 0; x < TILE_W; x++) {
            buf[0 * TILE_W + x] = PAL_GOLD;
            buf[1 * TILE_W + x] = PAL_GOLD;
        }
    }
    for (y = vy0; y <= vy1; y++) {
        if (vleft)  { buf[y * TILE_W + 0] = PAL_GOLD; buf[y * TILE_W + 1] = PAL_GOLD; }
        if (vright) { buf[y * TILE_W + 14] = PAL_GOLD; buf[y * TILE_W + 15] = PAL_GOLD; }
    }
}

/* 金色分隔线：中间两行金色，其余 UI 底。 */
static void synth_rule(uint8_t *buf)
{
    int x, y;
    for (y = 0; y < TILE_W; y++)
        for (x = 0; x < TILE_W; x++)
            buf[y * TILE_W + x] = (uint8_t)((y == 7 || y == 8) ? PAL_GOLD : PAL_UI_BG);
}

/* 把一块图块写进显存（合成一遍写一次，只在 init 调）。 */
static void put_pat(uint16_t tile, const uint8_t *buf)
{
    vid_bulk_write(VID_REGION_PAT, (uint16_t)(tile * TILE_BYTES), buf, (uint16_t)TILE_BYTES);
}

/* ---------------------------------------------------------------------------
 * 36 块棋盘图块：**运行时合成**（2026-10-18 从 .rodata 搬到这里）
 * ---------------------------------------------------------------------------
 * 为什么：那张 36 × 256B 的常量表 = 9,216 字节，跟着 RT-Thread 镜像一起驻留
 *   RAM。镜像已经到 96.8%，堆只剩一百多字节 —— 把表换成这段几何代码，
 *   .rodata 少 9KB、代码多几百字节，堆立刻回到 8KB 以上。
 *
 * [!] 几何必须与 gen_tiles.py 逐像素一致（那边是 Python 参考实现）：
 *     线宽 2px 在 7..8 行列；棋子半径 6、高光半径 2 偏左上；光标是 5.5..7 的空心圈。
 *     `test_render.c` 用 tiles_data.h 的参考表逐像素对拍，画歪了会当场 FAIL。
 * ------------------------------------------------------------------------- */

/* 9 种形状的四条边（上/下/左/右）有没有线 —— 顺序与 gen_tiles.py 的 SHAPES 一致 */
static const uint8_t SHAPE_EDGES[TILE_N_SHAPE][4] = {
    {1, 1, 1, 1},   /* 0 内部 */
    {0, 1, 1, 1},   /* 1 上边 */
    {1, 0, 1, 1},   /* 2 下边 */
    {1, 1, 0, 1},   /* 3 左边 */
    {1, 1, 1, 0},   /* 4 右边 */
    {0, 1, 0, 1},   /* 5 左上角 */
    {0, 1, 1, 0},   /* 6 右上角 */
    {1, 0, 0, 1},   /* 7 左下角 */
    {1, 0, 1, 0},   /* 8 右下角 */
};

static void synth_board_tile(uint8_t *buf, int shape, int state)
{
    const uint8_t *e = SHAPE_EDGES[shape];
    int up = e[0], dn = e[1], lf = e[2], rt = e[3];
    int i, x, y;

    for (i = 0; i < TILE_BYTES; i++) buf[i] = PAL_BG;

    /* 横线：两端都有线就贯穿，只有一端就从中心画到那一端（必须画到边界，
     * 否则相邻两块之间会断开，整张棋盘看起来是虚线）。 */
    if (lf || rt) {
        int x0 = lf ? 0 : 8;
        int x1 = rt ? (TILE_W - 1) : 7;
        for (y = 7; y <= 8; y++)
            for (x = x0; x <= x1; x++) buf[y * TILE_W + x] = PAL_LINE;
    }
    /* 竖线（同上）*/
    if (up || dn) {
        int y0 = up ? 0 : 8;
        int y1 = dn ? (TILE_W - 1) : 7;
        for (x = 7; x <= 8; x++)
            for (y = y0; y <= y1; y++) buf[y * TILE_W + x] = PAL_LINE;
    }

    if (state == TILE_ST_BLACK || state == TILE_ST_WHITE) {
        /* 实心圆 + 左上高光。用 2x 整数坐标代替浮点（dx = x-7.5 ⇒ 2dx = 2x-15），
         * 这样不用链接 libm，且与 gen_tiles.py 的 float 版本逐像素等价。 */
        int color    = (state == TILE_ST_BLACK) ? PAL_BLACK : PAL_WHITE;
        int hi_color = (state == TILE_ST_BLACK) ? PAL_BLACK_HI : PAL_WHITE_EDGE;
        for (y = 0; y < TILE_W; y++) {
            for (x = 0; x < TILE_W; x++) {
                int dx = 2 * x - (TILE_W - 1);
                int dy = 2 * y - (TILE_W - 1);
                if (dx * dx + dy * dy <= 144) {          /* (2*STONE_R)^2 = 144 */
                    int hx = dx + 4, hy = dy + 4;        /* 高光圆心左/上偏 2px */
                    buf[y * TILE_W + x] = (uint8_t)((hx * hx + hy * hy <= 16) ? hi_color : color);
                }
            }
        }
    } else if (state == TILE_ST_CURSOR) {
        /* 空心圈：5.5..7 像素（不能挡中心，否则看不见底下的交叉点）*/
        for (y = 0; y < TILE_W; y++) {
            for (x = 0; x < TILE_W; x++) {
                int dx = 2 * x - (TILE_W - 1);
                int dy = 2 * y - (TILE_W - 1);
                int d2 = dx * dx + dy * dy;
                if (d2 >= 121 && d2 <= 196)              /* (2*5.5)^2 .. (2*7)^2 */
                    buf[y * TILE_W + x] = PAL_RED;
            }
        }
    }
}

void render_init(void)
{
    uint8_t  pal[TILE_N_PALETTE * 4];
    uint8_t  tile[TILE_BYTES];
    uint16_t i;

    /* ---- 调色板：24bit RGB 存成字（小端）⇒ 字节序 B,G,R,0 ---- */
    for (i = 0; i < TILE_N_PALETTE; i++) {
        uint32_t rgb = TILE_PALETTE[i];
        pal[i * 4 + 0] = (uint8_t)(rgb & 0xFF);          /* B */
        pal[i * 4 + 1] = (uint8_t)((rgb >> 8) & 0xFF);   /* G */
        pal[i * 4 + 2] = (uint8_t)((rgb >> 16) & 0xFF);  /* R */
        pal[i * 4 + 3] = 0;
    }
    vid_bulk_write(VID_REGION_PAL, 0, pal, (uint16_t)(TILE_N_PALETTE * 4));

    /* ---- 图块像素：36 块棋盘图块**运行时合成**（省 9,216 字节 .rodata，
     *      见上面 synth_board_tile 的说明）。 ---- */
    {
        int shape, state;
        for (shape = 0; shape < TILE_N_SHAPE; shape++) {
            for (state = 0; state < TILE_N_STATE; state++) {
                synth_board_tile(tile, shape, state);
                vid_bulk_write(VID_REGION_PAT,
                               (uint16_t)(TILE_OF(shape, state) * TILE_BYTES),
                               tile, (uint16_t)TILE_BYTES);
            }
        }
    }

    /* ---- 字库图块：把紧凑 5x7 位图放大 FONT_SCALE 倍成 16x16，写到 tile 36..130。
     * [!] 这里 95 x 256 = 24KB 是写进【显存】的；固件只存 95 x 7 字节的紧凑位图，
     *     不占那 24KB RAM（见 build.ps1 的 28KB 限制）。 ---- */
    {
        int  g, y, x;
        int  ox = (TILE_W - FONT_W * FONT_SCALE) / 2;
        int  oy = (TILE_W - FONT_H * FONT_SCALE) / 2;

        for (g = 0; g < FONT_N_GLYPHS; g++) {
            for (y = 0; y < TILE_W; y++) {
                for (x = 0; x < TILE_W; x++) {
                    int fx = (x - ox) / FONT_SCALE;
                    int fy = (y - oy) / FONT_SCALE;
                    uint8_t v = (uint8_t)FONT_BG;
                    if (fx >= 0 && fx < FONT_W && fy >= 0 && fy < FONT_H &&
                        ((FONT_GLYPH[g][fy] >> (FONT_W - 1 - fx)) & 1u))
                        v = (uint8_t)FONT_FG;
                    tile[y * TILE_W + x] = v;
                }
            }
            vid_bulk_write(VID_REGION_PAT,
                           (uint16_t)((FONT_TILE_BASE + g) * TILE_BYTES),
                           tile, (uint16_t)TILE_BYTES);
        }
    }

    /* ---- 阶段 1 装饰图块：运行时合成（编号 131..153，见 render.h） ---- */
    {
        int shape, color;
        for (shape = 0; shape < TILE_N_SHAPE; shape++) {
            for (color = 0; color < 2; color++) {          /* 0=黑 1=白 */
                synth_last_move(tile, shape, color);
                vid_bulk_write(VID_REGION_PAT,
                               (uint16_t)((RENDER_TILE_LAST_BASE + shape * 2 + color) * TILE_BYTES),
                               tile, (uint16_t)TILE_BYTES);
            }
        }
        synth_star(tile);
        vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_STAR * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
        synth_frame_h(tile);
        vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_FRAME_H * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
        synth_frame_v(tile);
        vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_FRAME_V * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
        synth_icon(tile, PAL_BLACK, PAL_BLACK_HI);
        vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_ICON_BLACK * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
        synth_icon(tile, PAL_WHITE, PAL_WHITE_EDGE);
        vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_ICON_WHITE * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
    }

    /* ---- 标题屏装饰（编号 154..186，运行时合成）---- */
    {
        /* 4x 大 logo："GOMOKU"，两个 O 换成黑/白棋子（第 2 个字母黑、第 4 个白）。 */
        static const char LOGO[] = "GOMOKU";
        int gi, qx, qy;

        for (gi = 0; gi < 6; gi++) {
            int stone = 0;
            if (LOGO[gi] == 'O') stone = (gi == 1) ? 1 : 2;
            for (qy = 0; qy < RENDER_LOGO_TILE_H; qy++) {
                for (qx = 0; qx < RENDER_LOGO_TILE_W; qx++) {
                    synth_logo_tile(tile, LOGO[gi], stone, qx, qy);
                    put_pat((uint16_t)(RENDER_TILE_LOGO_BASE + gi * 4 + qy * 2 + qx), tile);
                }
            }
        }

        for (gi = 0; gi < 8; gi++) {
            synth_box(tile, gi);
            put_pat((uint16_t)(RENDER_TILE_BOX_TL + gi), tile);
        }

        synth_rule(tile);
        put_pat((uint16_t)RENDER_TILE_RULE, tile);
    }
}

/* ---------------------------------------------------------------------------
 * 标题屏绘制原语（只写 nametable，图块在 render_init 已经合成好）
 * ------------------------------------------------------------------------- */
void render_logo(int row, int col)
{
    uint8_t line[RENDER_LOGO_TILE_W * 6];
    int i, half;

    /* 一行 12 格 = 6 个字母 × 每字 2 格；qy=half 决定取上半还是下半图块。 */
    for (half = 0; half < RENDER_LOGO_TILE_H; half++) {
        for (i = 0; i < 6 * RENDER_LOGO_TILE_W; i++)
            line[i] = (uint8_t)(RENDER_TILE_LOGO_BASE + (i / RENDER_LOGO_TILE_W) * 4
                                + half * RENDER_LOGO_TILE_W + (i % RENDER_LOGO_TILE_W));
        vid_bulk_write(VID_REGION_NT, (uint16_t)((row + half) * 256 + col),
                       line, (uint16_t)sizeof(line));
    }
}

void render_rule(int row, int col, int len)
{
    uint8_t line[SCREEN_COLS];
    int i;
    if (len > SCREEN_COLS) len = SCREEN_COLS;
    for (i = 0; i < len; i++) line[i] = (uint8_t)RENDER_TILE_RULE;
    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256 + col), line, (uint16_t)len);
}

void render_box(int row, int col, int w)
{
    uint8_t line[SCREEN_COLS];
    int i;

    if (w < 2 || w > SCREEN_COLS) return;

    /* 上边（横线在底部）*/
    for (i = 1; i < w - 1; i++) line[i] = (uint8_t)RENDER_TILE_BOX_T;
    line[0] = (uint8_t)RENDER_TILE_BOX_TL;
    line[w - 1] = (uint8_t)RENDER_TILE_BOX_TR;
    vid_bulk_write(VID_REGION_NT, (uint16_t)((row - 1) * 256 + col), line, (uint16_t)w);

    /* 左右竖线：盖在文字行两端（所以本函数必须在 render_text 之后调）*/
    if (row >= 0) {
        put_abs(row, col, (uint8_t)RENDER_TILE_BOX_L);
        put_abs(row, col + w - 1, (uint8_t)RENDER_TILE_BOX_R);
    }

    /* 下边（横线在顶部）*/
    for (i = 1; i < w - 1; i++) line[i] = (uint8_t)RENDER_TILE_BOX_B;
    line[0] = (uint8_t)RENDER_TILE_BOX_BL;
    line[w - 1] = (uint8_t)RENDER_TILE_BOX_BR;
    vid_bulk_write(VID_REGION_NT, (uint16_t)((row + 1) * 256 + col), line, (uint16_t)w);
}
