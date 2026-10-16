/* ============================================================================
 * render.c —— 五子棋渲染层的实现（轨道 A3）
 * ----------------------------------------------------------------------------
 * [!] 不用 libc（没有 memset/memcpy），要能原样编进 RV32 固件。
 *     唯一的平台依赖是 vid_bulk_write()，在 render.h 里声明、由平台实现。
 * ==========================================================================*/
#include "render.h"
#include "tiles.h"
#include "font.h"

/* 调色板下标 —— 与 gen_tiles.py 的 PAL 顺序、tiles.h 的 TILE_PALETTE 数组一致。
 * 阶段 1 的合成图块（红标/星位/外框/图标）用这些常量取色，不硬编码数字。 */
#define PAL_BG         0   /* 棋盘底色 */
#define PAL_LINE       1   /* 棋盘线 */
#define PAL_BLACK      2   /* 黑子主体 */
#define PAL_BLACK_HI   3   /* 黑子高光 */
#define PAL_WHITE      4   /* 白子主体 */
#define PAL_WHITE_EDGE 5   /* 白子描边 */
#define PAL_RED        6   /* 光标红（阶段 1 也用作最后一手标记）*/

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
}

/* ---------------------------------------------------------------------------
 * 棋盘外框 + 坐标轴（阶段 1 静态装饰）。都画在 15x15 之外，上电各调一次即可；
 * render_full 每帧全刷只碰棋盘区，不会覆盖它们。
 * ------------------------------------------------------------------------- */
void render_board_frame(void)
{
    int i;
    /* 四角复用棋盘边角图块（shape 5/6/7/8 空状态）—— 与棋盘边角同款，不另做图块。 */
    put_abs(BOARD_ROW0 - 1, BOARD_COL0 - 1, RENDER_TILE(TILE_SHAPE_TOPLEFT,  RENDER_ST_EMPTY));
    put_abs(BOARD_ROW0 - 1, BOARD_COL0 + GOMOKU_N, RENDER_TILE(TILE_SHAPE_TOPRIGHT, RENDER_ST_EMPTY));
    put_abs(BOARD_ROW0 + GOMOKU_N, BOARD_COL0 - 1, RENDER_TILE(TILE_SHAPE_BOTLEFT,  RENDER_ST_EMPTY));
    put_abs(BOARD_ROW0 + GOMOKU_N, BOARD_COL0 + GOMOKU_N, RENDER_TILE(TILE_SHAPE_BOTRIGHT, RENDER_ST_EMPTY));
    /* 上下横边 */
    for (i = 0; i < GOMOKU_N; i++) {
        put_abs(BOARD_ROW0 - 1,        BOARD_COL0 + i, RENDER_TILE_FRAME_H);
        put_abs(BOARD_ROW0 + GOMOKU_N, BOARD_COL0 + i, RENDER_TILE_FRAME_H);
    }
    /* 左右竖边 */
    for (i = 0; i < GOMOKU_N; i++) {
        put_abs(BOARD_ROW0 + i, BOARD_COL0 - 1,        RENDER_TILE_FRAME_V);
        put_abs(BOARD_ROW0 + i, BOARD_COL0 + GOMOKU_N, RENDER_TILE_FRAME_V);
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
void render_text(int row, int col, const char *s)
{
    /* [!] 整行一次写完：先铺满空格，再把文字盖上去。
     *     不能"只写字符串本身" —— 那样会留下上一次的残字，而且【左端也留】：
     *     2026-10-07 板上实踩，标题屏从 "LEVEL: NORMAL"(13 字) 切到 "LEVEL: EASY"(11 字)，
     *     render_text_center 的居中起点由列 13 变成列 14、终点由 25 变成 24，
     *     两端各留一个 'L' ⇒ 屏幕显示成 "LLEVEL: EASYL"。
     *     （第一版只补了行尾，测试当场抓出左端还漏 —— 所以改成整行写。）
     *     底部 AI 统计行同理：节点数 1287 -> 812 时字符串变短会留残字。
     *     顺带：整行一次 vid_bulk_write 比逐字符写快得多。 */
    uint8_t line[SCREEN_COLS];
    int     i;

    for (i = 0; i < SCREEN_COLS; i++) line[i] = (uint8_t)FONT_TILE_BASE;

    i = 0;
    while (s[i] != '\0' && col + i < SCREEN_COLS) {
        int ch = (int)(unsigned char)s[i];
        if (col + i >= 0)
            line[col + i] = glyph_tile(ch);
        /* 范围外 / 越界字符保持空格（line 已铺满） */
        i++;
    }

    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256), line, (uint16_t)SCREEN_COLS);
}

void render_text_center(int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text(row, (SCREEN_COLS - len) / 2, s);
}

/* ---- 阶段 1 合成图块：在 render_init 里现算，不占固件 .rodata ---------------
 * 刻意【不用 libc】（没有 memcpy），用显式循环搬像素。 */

/* 拷贝棋盘图块并在右上角叠一个红色小三角（最后一手标记）。color: 0=黑 1=白。 */
static void synth_last_move(uint8_t *buf, int shape, int color)
{
    int i, y, x;
    const uint8_t *src = TILE_PATTERN[TILE_OF(shape, color + 1)];  /* BLACK=1 / WHITE=2 */
    for (i = 0; i < TILE_BYTES; i++) buf[i] = src[i];
    /* 右上角 4x4 小三角（顶点朝左下）。避开中心子（半径 6）与行/列 7-8 的网格线。 */
    for (y = 0; y < 4; y++)
        for (x = 12 + y; x < TILE_W; x++)
            buf[y * TILE_W + x] = PAL_RED;
}

/* 星位点：内部空格图块 + 中心 4x4 实心点（比网格线粗，一眼能认出是星位）。 */
static void synth_star(uint8_t *buf)
{
    int i, y, x;
    const uint8_t *src = TILE_PATTERN[TILE_OF(TILE_SHAPE_INNER, TILE_ST_EMPTY)];
    for (i = 0; i < TILE_BYTES; i++) buf[i] = src[i];
    for (y = 6; y <= 9; y++)
        for (x = 6; x <= 9; x++)
            buf[y * TILE_W + x] = PAL_LINE;
}

/* 外框纯横线 / 纯竖线（2px，与棋盘线同色）。四角复用棋盘边角图块。 */
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
                buf[y * TILE_W + x] = PAL_BG;
            }
        }
    }
}

void render_init(void)
{
    uint8_t  pal[TILE_N_PALETTE * 4];
    uint8_t  tile[TILE_BYTES];
    uint16_t t, i, py;

    /* ---- 调色板：24bit RGB 存成字（小端）⇒ 字节序 B,G,R,0 ---- */
    for (i = 0; i < TILE_N_PALETTE; i++) {
        uint32_t rgb = TILE_PALETTE[i];
        pal[i * 4 + 0] = (uint8_t)(rgb & 0xFF);          /* B */
        pal[i * 4 + 1] = (uint8_t)((rgb >> 8) & 0xFF);   /* G */
        pal[i * 4 + 2] = (uint8_t)((rgb >> 16) & 0xFF);  /* R */
        pal[i * 4 + 3] = 0;
    }
    vid_bulk_write(VID_REGION_PAL, 0, pal, (uint16_t)(TILE_N_PALETTE * 4));

    /* ---- 图块像素：tiles.h 里是一行 16 字节的二维数组，显存里也是行优先，
     *      但【方向相反】：显存是 [tile][row][col]，C 数组也是 [tile][y][x]，
     *      所以可以一块一块整片搬 —— 不用逐像素。 ---- */
    for (t = 0; t < TILE_N_TOTAL; t++) {
        for (py = 0; py < TILE_BYTES; py++) tile[py] = TILE_PATTERN[t][py];
        vid_bulk_write(VID_REGION_PAT, (uint16_t)(t * TILE_BYTES), tile, TILE_BYTES);
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
}
