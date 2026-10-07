/* ============================================================================
 * render.c —— 五子棋渲染层的实现（轨道 A3）
 * ----------------------------------------------------------------------------
 * [!] 不用 libc（没有 memset/memcpy），要能原样编进 RV32 固件。
 *     唯一的平台依赖是 vid_bulk_write()，在 render.h 里声明、由平台实现。
 * ==========================================================================*/
#include "render.h"
#include "tiles.h"
#include "font.h"

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

uint8_t render_tile_for(const gomoku_t *g, int r, int c, int cr, int cc)
{
    uint8_t shape = render_shape(r, c);
    uint8_t state;

    if (r == cr && c == cc) {                       /* 光标优先 */
        state = RENDER_ST_CURSOR;
    } else {
        switch (g->cell[r][c]) {
        case GOMOKU_BLACK: state = RENDER_ST_BLACK; break;
        case GOMOKU_WHITE: state = RENDER_ST_WHITE; break;
        default:           state = RENDER_ST_EMPTY; break;
        }
    }
    return RENDER_TILE(shape, state);
}

/* 写一个 nametable 字节。地址 = (BOARD_ROW0+r)*256 + (BOARD_COL0+c) */
static void put_nt(int r, int c, uint8_t tile)
{
    uint16_t off = (uint16_t)((BOARD_ROW0 + r) * 256 + (BOARD_COL0 + c));
    vid_bulk_write(VID_REGION_NT, off, &tile, 1);
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
 * HUD 文字
 * ------------------------------------------------------------------------- */
void render_text(int row, int col, const char *s)
{
    int i = 0;
    while (s[i] != '\0' && col + i < SCREEN_COLS) {
        int     ch = (int)(unsigned char)s[i];
        uint8_t tile;

        if (ch >= 'a' && ch <= 'z') ch -= 32;              /* 小写折叠到大写 */
        if (ch >= FONT_BASE && ch < FONT_BASE + FONT_N_GLYPHS)
            tile = (uint8_t)(FONT_TILE_BASE + (ch - FONT_BASE));
        else
            tile = (uint8_t)FONT_TILE_BASE;                /* 未定义 -> 空格 */

        vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256 + col + i), &tile, 1);
        i++;
    }
}

void render_text_center(int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text(row, (SCREEN_COLS - len) / 2, s);
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
}
