/* ==========================================================================
 * palette.h —— 调色板（五子棋 + CoreMark 文本控制台共用）
 *
 * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。
 *     改颜色改那个脚本再重跑。
 *
 * 前 7 项是棋盘/棋子色（对局界面已上板，不要动）；
 * 7..11 是标题屏的深色 UI 配色。
 * [!] FONT_BG / FONT_FG（font.h）分别取 PAL_UI_BG / PAL_UI_FG，
 *     所以整屏文字底、CoreMark 控制台底、标题屏底色**必然是同一个颜色**。
 * ========================================================================== */

#ifndef GOMOKU_PALETTE_H
#define GOMOKU_PALETTE_H

#include <stdint.h>

#define TILE_N_PALETTE 12

#define PAL_BG           0   /* 棋盘底色（浅木） */
#define PAL_LINE         1   /* 棋盘线 */
#define PAL_BLACK        2   /* 黑子主体 */
#define PAL_BLACK_HI     3   /* 黑子高光 */
#define PAL_WHITE        4   /* 白子主体 */
#define PAL_WHITE_EDGE   5   /* 白子描边 */
#define PAL_RED          6   /* 光标 / 最后一手 */
#define PAL_UI_BG        7   /* UI 深色底（= FONT_BG） */
#define PAL_UI_FG        8   /* UI 文字暖白（= FONT_FG） */
#define PAL_GOLD         9   /* 金色强调（logo / 选中框） */
#define PAL_SHADOW      10   /* 阴影（比 UI 底更深） */
#define PAL_UI_LINE     11   /* 细分隔线 */

static const uint32_t TILE_PALETTE[TILE_N_PALETTE] = {
    0xE8C88Cu,   /* 0  棋盘底色（浅木） */
    0x50381Cu,   /* 1  棋盘线 */
    0x101010u,   /* 2  黑子主体 */
    0x404040u,   /* 3  黑子高光 */
    0xF8F8F8u,   /* 4  白子主体 */
    0xA8A8A8u,   /* 5  白子描边 */
    0xD02020u,   /* 6  光标 / 最后一手 */
    0x1A1A1Eu,   /* 7  UI 深色底（= FONT_BG） */
    0xEDE3C8u,   /* 8  UI 文字暖白（= FONT_FG） */
    0xD8A93Cu,   /* 9  金色强调（logo / 选中框） */
    0x0E0E10u,   /* 10  阴影（比 UI 底更深） */
    0x3A3A40u    /* 11  细分隔线 */
};

#endif /* GOMOKU_PALETTE_H */
