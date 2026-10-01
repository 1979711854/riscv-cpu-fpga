#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_tiles.py —— 生成五子棋的调色板与图块表（轨道 A2）

    用法：  python scripts/gomoku/gen_tiles.py
    产物：  scripts/gomoku/tiles.h   （C 头文件，**自动生成，别手改**）

为什么用脚本生成而不是手画二进制：
  1. 图块是 16x16 = 256 字节/块，36 块 = 9216 字节 —— 手改一个像素就得重算一整个
     数组，不现实
  2. 棋盘线是"程序化"的（哪几条边有线而已），用代码描述比位图清楚得多
  3. 它是**【唯一真相】**：想改颜色/线宽/棋子大小，改这里的常数重跑即可；
     tiles.h 是产物，不需要 review

图块编号约定（render.c 依赖它，改这里必须同步改 render.c）：
    tile = shape * 4 + state
      shape 0..8  = 9 种网格线形状（见下面 SHAPES）
      state 0..3  = 0 空 / 1 黑子 / 2 白子 / 3 光标
    ⇒ 共 36 块，占 tile 0..35

显存映射（见 rtl/bus/addr_map.vh 的视频区小节）：
    调色板  VIDEO_PAL + i*4            = 0xRRGGBB（高 8 位忽略）
    图块像素 VIDEO_PAT + T*256 + py*16 + px = 调色板索引
"""
import sys

TILE = 16
N_SHAPE = 9
N_STATE = 4
N_TILE = N_SHAPE * N_STATE      # 36

# ---- 调色板 ----------------------------------------------------------------
# 索引 -> 24bit RGB。**索引号被 tiles 数组直接引用**，改顺序等于改画。
PAL = [
    0xE8C88C,   # 0 棋盘底色（浅木色）
    0x50381C,   # 1 棋盘线（深棕）
    0x101010,   # 2 黑子主体
    0x404040,   # 3 黑子高光
    0xF8F8F8,   # 4 白子主体
    0xA8A8A8,   # 5 白子描边
    0xD02020,   # 6 光标（红）
]

P_BG, P_LINE, P_BLACK, P_BLACK_HI, P_WHITE, P_WHITE_EDGE, P_CURSOR = range(7)

# ---- 9 种网格线形状 --------------------------------------------------------
# 每个 shape 说明"四条边哪几条有线"：(上, 下, 左, 右)
# 顺序必须与 render.c 的 SHAPE_LUT 一致
SHAPES = [
    (1, 1, 1, 1),   # 0 内部（15x15 里占 13x13 = 169 个）
    (0, 1, 1, 1),   # 1 上边
    (1, 0, 1, 1),   # 2 下边
    (1, 1, 0, 1),   # 3 左边
    (1, 1, 1, 0),   # 4 右边
    (0, 1, 0, 1),   # 5 左上角
    (0, 1, 1, 0),   # 6 右上角
    (1, 0, 0, 1),   # 7 左下角
    (1, 0, 1, 0),   # 8 右下角
]

LINE_W = 2          # 线宽（像素）—— 2 像素在 640x480 上看得清又不糊
STONE_R = 6         # 棋子半径（像素）。6.5 取整为 6，留 1.5px 空隙不粘线
CURSOR_R = 7        # 光标半径


def blank():
    return [[P_BG] * TILE for _ in range(TILE)]


def draw_lines(g, shp):
    """按 shape 的四条边把线画上去。线居中：行/列 7..8（2 像素宽）。

    横线和竖线各自独立判断：两端都有线就贯穿整块，只有一端就从中心画到那一端。
    ⚠️ 关键是**必须画到块的边界（像素 0 / 15）** —— 否则相邻两块之间会断开，
       整张棋盘看起来是虚线。
    """
    up, dn, lf, rt = shp
    lo = (TILE - LINE_W) // 2          # 7
    hi = lo + LINE_W - 1               # 8

    if lf and rt:      xr = range(TILE)
    elif lf:           xr = range(0, lo + 1)
    elif rt:           xr = range(hi, TILE)
    else:              xr = range(0)
    for y in range(lo, hi + 1):
        for x in xr:
            g[y][x] = P_LINE

    if up and dn:      yr = range(TILE)
    elif up:           yr = range(0, lo + 1)
    elif dn:           yr = range(hi, TILE)
    else:              yr = range(0)
    for x in range(lo, hi + 1):
        for y in yr:
            g[y][x] = P_LINE


def draw_stone(g, color, hi_color):
    """实心圆 + 左上角高光（点光源在左上，看起来是凸的）。"""
    for y in range(TILE):
        for x in range(TILE):
            dx = x - (TILE - 1) / 2.0
            dy = y - (TILE - 1) / 2.0
            d2 = dx * dx + dy * dy
            if d2 <= STONE_R * STONE_R:
                # 高光：圆心往左上偏 2px 的另一个圆
                hx, hy = dx + 2.0, dy + 2.0
                g[y][x] = hi_color if (hx * hx + hy * hy) <= 4.0 else color


def draw_cursor(g):
    """空心圈 —— 画在空交叉点上，不能挡住棋盘的线。"""
    for y in range(TILE):
        for x in range(TILE):
            dx = x - (TILE - 1) / 2.0
            dy = y - (TILE - 1) / 2.0
            d2 = dx * dx + dy * dy
            if (CURSOR_R - 1.5) ** 2 <= d2 <= CURSOR_R * CURSOR_R:
                g[y][x] = P_CURSOR


def make_tile(shape, state):
    img = blank()
    draw_lines(img, SHAPES[shape])
    if state == 1:
        draw_stone(img, P_BLACK, P_BLACK_HI)
    elif state == 2:
        draw_stone(img, P_WHITE, P_WHITE_EDGE)   # 白子高光用描边色，避免太白看不出立体
    elif state == 3:
        draw_cursor(img)
    return img


def emit(path):
    tiles = []
    for shape in range(N_SHAPE):
        for state in range(N_STATE):
            tiles.append(make_tile(shape, state))
    assert len(tiles) == N_TILE

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * tiles.h —— 五子棋的调色板与图块表\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" *     改颜色/线宽/棋子大小请改那个脚本再重跑。\n")
        f.write(" *\n")
        f.write(" * 图块编号：tile = shape * 4 + state\n")
        f.write(" *   shape 0..8 = 内部/上边/下边/左边/右边/左上/右上/左下/右下\n")
        f.write(" *   state 0..3 = 空 / 黑子 / 白子 / 光标\n")
        f.write(" * 共 %d 块 × 256 字节 = %d 字节。\n" % (N_TILE, N_TILE * 256))
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_TILES_H\n#define GOMOKU_TILES_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define TILE_W         %d\n" % TILE)
        f.write("#define TILE_BYTES     %d\n" % (TILE * TILE))
        f.write("#define TILE_N_SHAPE   %d\n" % N_SHAPE)
        f.write("#define TILE_N_STATE   %d\n" % N_STATE)
        f.write("#define TILE_N_TOTAL   %d\n\n" % N_TILE)
        f.write("#define TILE_SHAPE_INNER       0\n")
        f.write("#define TILE_SHAPE_TOP         1\n")
        f.write("#define TILE_SHAPE_BOTTOM      2\n")
        f.write("#define TILE_SHAPE_LEFT        3\n")
        f.write("#define TILE_SHAPE_RIGHT       4\n")
        f.write("#define TILE_SHAPE_TOPLEFT     5\n")
        f.write("#define TILE_SHAPE_TOPRIGHT    6\n")
        f.write("#define TILE_SHAPE_BOTLEFT     7\n")
        f.write("#define TILE_SHAPE_BOTRIGHT    8\n\n")
        f.write("#define TILE_ST_EMPTY  0\n")
        f.write("#define TILE_ST_BLACK  1\n")
        f.write("#define TILE_ST_WHITE  2\n")
        f.write("#define TILE_ST_CURSOR 3\n\n")
        f.write("#define TILE_OF(shape, state)  ((uint8_t)((shape) * TILE_N_STATE + (state)))\n\n")
        f.write("#define TILE_N_PALETTE %d\n" % len(PAL))
        f.write("static const uint32_t TILE_PALETTE[TILE_N_PALETTE] = {\n")
        for i, c in enumerate(PAL):
            f.write("    0x%06Xu%s   /* %d */\n" % (c, "," if i < len(PAL) - 1 else " ", i))
        f.write("};\n\n")
        f.write("/* [TILE_OF(shape,state)][py*16+px] = 调色板索引 */\n")
        f.write("static const uint8_t TILE_PATTERN[TILE_N_TOTAL][TILE_BYTES] = {\n")
        for i, img in enumerate(tiles):
            sh, st = i // N_STATE, i % N_STATE
            f.write("    {   /* tile %2d = shape %d state %d */\n" % (i, sh, st))
            for y in range(TILE):
                f.write("        " + ",".join("%d" % v for v in img[y]) + ",\n")
            f.write("    },\n")
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_TILES_H */\n")


def dump_preview(n=2):
    """在终端里用字符画预览前 n 个 shape 的 4 个状态 —— 生成完扫一眼别画歪了。"""
    chars = {P_BG: ".", P_LINE: "#", P_BLACK: "@", P_BLACK_HI: "*",
             P_WHITE: "O", P_WHITE_EDGE: "o", P_CURSOR: "+"}
    for shape in range(n):
        print("--- shape %d ---" % shape)
        for state in range(N_STATE):
            img = make_tile(shape, state)
            for y in range(TILE):
                print("   " + "".join(chars[v] for v in img[y]) + "")
            print()


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "tiles.h")
    emit(out)
    print("已生成 %s" % out)
    dump_preview(2)
