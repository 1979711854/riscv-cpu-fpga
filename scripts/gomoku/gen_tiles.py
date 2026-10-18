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
#
# [2026-10-18 标题屏改版] 前 7 项是棋盘/棋子的颜色，一项都不许动 ——
#   对局界面已上板、用户认可，这次只加**不冲突的新项**：
#     7  UI 深色底（墨绿）  —— 文字图块的背景，也是整屏底色
#     8  文字前景（暖白）
#     9  金色强调        —— logo / 选中框 / 分隔线
#    10  阴影（比 UI 底更深）—— 大 logo 的投影
#    11  分隔线（介于底与字之间）
#   [!] 为什么不用"整行金色底条"做选中态：字库图块的背景是**不透明**的，
#       整行铺金会被每个字的背景方块盖成一个个小方块（见任务书 §2.5.2）。
PAL = [
    0xE8C88C,   # 0  棋盘底色（浅木色）
    0x50381C,   # 1  棋盘线（深棕）
    0x101010,   # 2  黑子主体
    0x404040,   # 3  黑子高光
    0xF8F8F8,   # 4  白子主体
    0xA8A8A8,   # 5  白子描边
    0xD02020,   # 6  光标（红）
    0x16211C,   # 7  UI 底（墨绿）—— FONT_BG
    0xEDE3C8,   # 8  UI 文字（暖白）—— FONT_FG
    0xD8A93C,   # 9  金色强调（logo / 选中框 / 分隔线）
    0x0C1410,   # 10 阴影（比 UI 底更深）
    0x2E3A34,   # 11 细分隔线
]

(P_BG, P_LINE, P_BLACK, P_BLACK_HI, P_WHITE, P_WHITE_EDGE, P_CURSOR,
 P_UI_BG, P_UI_FG, P_GOLD, P_SHADOW, P_UI_LINE) = range(12)

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


# ---------------------------------------------------------------------------
# ASCII 字库（HUD 用）：紧凑 5x7 位图，上电时 render.c 放大 2x 成 16x16 图块。
# 只画大写/数字/常用标点；小写折叠到大写，其余可打印字符落到空格。
# 前景 FONT_FG（黑子主体色）/ 背景 FONT_BG（棋盘底色）。
# ---------------------------------------------------------------------------
FONT_W = 5
FONT_H = 7
FONT_SCALE = 2
FONT_BASE = 0x20
FONT_N_GLYPHS = 95          # 0x20..0x7E
FONT_TILE_BASE = N_TILE     # 36：棋盘图块 0..35 之后

# 每字 7 行 x 5 列，'#' 亮 / '.' 灭（左到右 = 列0..列4）
FONT_GLYPHS = {
    ' ': [".....",
          ".....",
          ".....",
          ".....",
          ".....",
          ".....",
          "....."],
    '!': ["..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          ".....",
          "..#.."],
    '0': [".###.",
          "#...#",
          "#..##",
          "#.#.#",
          "##..#",
          "#...#",
          ".###."],
    '1': ["..#..",
          ".##..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          ".###."],
    '2': [".###.",
          "#...#",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          "#####"],
    '3': [".###.",
          "#...#",
          "....#",
          "..##.",
          "....#",
          "#...#",
          ".###."],
    '4': ["...#.",
          "..##.",
          ".#.#.",
          "#..#.",
          "#####",
          "...#.",
          "...#."],
    '5': ["#####",
          "#....",
          "####.",
          "....#",
          "....#",
          "#...#",
          ".###."],
    '6': [".###.",
          "#....",
          "#....",
          "####.",
          "#...#",
          "#...#",
          ".###."],
    '7': ["#####",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          ".#...",
          ".#..."],
    '8': [".###.",
          "#...#",
          "#...#",
          ".###.",
          "#...#",
          "#...#",
          ".###."],
    '9': [".###.",
          "#...#",
          "#...#",
          ".####",
          "....#",
          "....#",
          ".###."],
    'A': [".###.",
          "#...#",
          "#...#",
          "#####",
          "#...#",
          "#...#",
          "#...#"],
    'B': ["####.",
          "#...#",
          "#...#",
          "####.",
          "#...#",
          "#...#",
          "####."],
    'C': [".###.",
          "#...#",
          "#....",
          "#....",
          "#....",
          "#...#",
          ".###."],
    'D': ["####.",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "####."],
    'E': ["#####",
          "#....",
          "#....",
          "####.",
          "#....",
          "#....",
          "#####"],
    'F': ["#####",
          "#....",
          "#....",
          "####.",
          "#....",
          "#....",
          "#...."],
    'G': [".###.",
          "#...#",
          "#....",
          "#.###",
          "#...#",
          "#...#",
          ".####"],
    'H': ["#...#",
          "#...#",
          "#...#",
          "#####",
          "#...#",
          "#...#",
          "#...#"],
    'I': [".###.",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          ".###."],
    'J': ["..###",
          "...#.",
          "...#.",
          "...#.",
          "...#.",
          "#..#.",
          ".##.."],
    'K': ["#...#",
          "#..#.",
          "#.#..",
          "##...",
          "#.#..",
          "#..#.",
          "#...#"],
    'L': ["#....",
          "#....",
          "#....",
          "#....",
          "#....",
          "#....",
          "#####"],
    'M': ["#...#",
          "##.##",
          "#.#.#",
          "#.#.#",
          "#...#",
          "#...#",
          "#...#"],
    'N': ["#...#",
          "##..#",
          "#.#.#",
          "#..##",
          "#...#",
          "#...#",
          "#...#"],
    'O': [".###.",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          ".###."],
    'P': ["####.",
          "#...#",
          "#...#",
          "####.",
          "#....",
          "#....",
          "#...."],
    'Q': [".###.",
          "#...#",
          "#...#",
          "#...#",
          "#.#.#",
          "#..#.",
          ".##.#"],
    'R': ["####.",
          "#...#",
          "#...#",
          "####.",
          "#.#..",
          "#..#.",
          "#...#"],
    'S': [".####",
          "#....",
          "#....",
          ".###.",
          "....#",
          "....#",
          "####."],
    'T': ["#####",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#.."],
    'U': ["#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          ".###."],
    'V': ["#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          ".#.#.",
          "..#.."],
    'W': ["#...#",
          "#...#",
          "#...#",
          "#.#.#",
          "#.#.#",
          "##.##",
          "#...#"],
    'X': ["#...#",
          "#...#",
          ".#.#.",
          "..#..",
          ".#.#.",
          "#...#",
          "#...#"],
    'Y': ["#...#",
          "#...#",
          ".#.#.",
          "..#..",
          "..#..",
          "..#..",
          "..#.."],
    'Z': ["#####",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          "#....",
          "#####"],
    ':': [".....",
          "..#..",
          "..#..",
          ".....",
          "..#..",
          "..#..",
          "....."],
    # [2026-10-18] 标题屏副标题 "RISC-V + RT-THREAD" 要用 '+'。
    #   原字库没有它（会落成空格），补一个 5x7 的十字。
    '+': [".....",
          "..#..",
          "..#..",
          "#####",
          "..#..",
          "..#..",
          "....."],
    '.': [".....",
          ".....",
          ".....",
          ".....",
          ".....",
          "..#..",
          "....."],
    '-': [".....",
          ".....",
          ".....",
          ".###.",
          ".....",
          ".....",
          "....."],
    '/': ["....#",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          "#....",
          "#...."],
}


def font_rows(ch):
    """返回 ch 的 7x5 位图（字符串列表）。小写折叠到大写，未定义 -> 空格。"""
    if ch == ' ':
        return FONT_GLYPHS[' ']
    if 'a' <= ch <= 'z':
        ch = chr(ord(ch) - 32)
    return FONT_GLYPHS.get(ch, FONT_GLYPHS[' '])


def font_row_bits(ch, fy):
    """字形第 fy 行打包成 5 位：bit4..bit0 = 列0..列4，1 = 亮。"""
    s = font_rows(ch)[fy]
    b = 0
    for fx in range(FONT_W):
        if s[fx] == '#':
            b |= 1 << (FONT_W - 1 - fx)
    return b


def make_font_tile(ch):
    """把 ch 放大 FONT_SCALE 倍成 16x16 图块（预览用；固件在 render.c 做同一件事）。"""
    rows = font_rows(ch)
    img = [[P_UI_BG] * TILE for _ in range(TILE)]
    ox = (TILE - FONT_W * FONT_SCALE) // 2
    oy = (TILE - FONT_H * FONT_SCALE) // 2
    for fy in range(FONT_H):
        for fx in range(FONT_W):
            if rows[fy][fx] == '#':
                for sy in range(FONT_SCALE):
                    for sx in range(FONT_SCALE):
                        img[oy + fy * FONT_SCALE + sy][ox + fx * FONT_SCALE + sx] = P_UI_FG
    return img


def emit_font(path):
    """生成 font.h：紧凑 5x7 位图 + 展开参数。16x16 图块由固件 render_init 放大。"""
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * font.h —— HUD 用的 ASCII 字库（紧凑 5x7 位图）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" *     改字形改那个脚本再重跑。\n")
        f.write(" *\n")
        f.write(" * 只存紧凑位图（%d 字 x %d 字节 = %d 字节）；render_init() 上电时\n"
                % (FONT_N_GLYPHS, FONT_H, FONT_N_GLYPHS * FONT_H))
        f.write(" * 放大 %dx 成 16x16 图块写进显存 tile %d..%d。\n"
                % (FONT_SCALE, FONT_TILE_BASE, FONT_TILE_BASE + FONT_N_GLYPHS - 1))
        f.write(" * 前景 FONT_FG / 背景 FONT_BG 的**下标**定义在 palette.h（调色板本体），\n")
        f.write(" * 这里直接写死数字是为了让 dev 板/控制台两处引用同一份下标。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_FONT_H\n#define GOMOKU_FONT_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define FONT_W          %d\n" % FONT_W)
        f.write("#define FONT_H          %d\n" % FONT_H)
        f.write("#define FONT_SCALE      %d\n" % FONT_SCALE)
        f.write("#define FONT_BASE       %d   /* 第一个字模 = 空格 */\n" % FONT_BASE)
        f.write("#define FONT_N_GLYPHS   %d   /* 0x20..0x7E */\n" % FONT_N_GLYPHS)
        f.write("#define FONT_TILE_BASE  %d   /* 棋盘图块 0..35 之后 */\n" % FONT_TILE_BASE)
        f.write("#define FONT_FG         %d   /* 文字前景（暖白，见 palette.h）*/\n" % P_UI_FG)
        f.write("#define FONT_BG         %d   /* 文字背景（深色 UI 底，见 palette.h）*/\n\n" % P_UI_BG)
        f.write("/* FONT_GLYPH[字模][行] = 5 位位图：bit4..bit0 = 列0..列4，1 = 亮 */\n")
        f.write("static const uint8_t FONT_GLYPH[FONT_N_GLYPHS][FONT_H] = {\n")
        for code in range(FONT_BASE, FONT_BASE + FONT_N_GLYPHS):
            bits = [font_row_bits(chr(code), fy) for fy in range(FONT_H)]
            f.write("    { %s },   /* 0x%02X */\n"
                    % (", ".join("%d" % b for b in bits), code))
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_FONT_H */\n")


def dump_font_preview(s="GOMOKU AI 123"):
    print("\n--- 字库预览（5x7 放大前）---")
    for ch in s:
        print("   [%s]" % ch)
        for row in font_rows(ch):
            print("    " + row.replace('.', ' '))
    print("   放大 2x 后 'A'（16x16，'.'=背景 '#'=前景）:")
    img = make_font_tile('A')
    for row in img:
        print("    " + "".join('#' if v == P_BLACK else '.' for v in row))


PAL_NAMES = [
    ("PAL_BG",         "棋盘底色（浅木）"),
    ("PAL_LINE",       "棋盘线"),
    ("PAL_BLACK",      "黑子主体"),
    ("PAL_BLACK_HI",   "黑子高光"),
    ("PAL_WHITE",      "白子主体"),
    ("PAL_WHITE_EDGE", "白子描边"),
    ("PAL_RED",        "光标 / 最后一手"),
    ("PAL_UI_BG",      "UI 深色底（= FONT_BG）"),
    ("PAL_UI_FG",      "UI 文字暖白（= FONT_FG）"),
    ("PAL_GOLD",       "金色强调（logo / 选中框）"),
    ("PAL_SHADOW",     "阴影（比 UI 底更深）"),
    ("PAL_UI_LINE",    "细分隔线"),
]


def emit_palette(path):
    """调色板单独一份头文件。

    为什么要拆出来：CoreMark 的 HDMI 文本控制台（scripts/coremark_port/video_text.c）
    也要写同一张调色板。让它 include 这个 12 项的小表，而不是 tiles.h —— 后者带
    36 块 x 256B 的棋盘图块（9KB），CoreMark 镜像不该为了一行颜色把它装进去。
    """
    assert len(PAL_NAMES) == len(PAL)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * palette.h —— 调色板（五子棋 + CoreMark 文本控制台共用）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" *     改颜色改那个脚本再重跑。\n")
        f.write(" *\n")
        f.write(" * 前 7 项是棋盘/棋子色（对局界面已上板，不要动）；\n")
        f.write(" * 7..11 是标题屏的深色 UI 配色。\n")
        f.write(" * [" + "!" + "] FONT_BG / FONT_FG（font.h）分别取 PAL_UI_BG / PAL_UI_FG，\n")
        f.write(" *     所以整屏文字底、CoreMark 控制台底、标题屏底色**必然是同一个颜色**。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_PALETTE_H\n#define GOMOKU_PALETTE_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define TILE_N_PALETTE %d\n\n" % len(PAL))
        for i, (name, desc) in enumerate(PAL_NAMES):
            f.write("#define %-15s %2d   /* %s */\n" % (name, i, desc))
        f.write("\nstatic const uint32_t TILE_PALETTE[TILE_N_PALETTE] = {\n")
        for i, c in enumerate(PAL):
            f.write("    0x%06Xu%s   /* %d  %s */\n"
                    % (c, "," if i < len(PAL) - 1 else " ", i, PAL_NAMES[i][1]))
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_PALETTE_H */\n")


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
        f.write("#include <stdint.h>\n")
        f.write("#include \"palette.h\"   /* 调色板独立一份：CoreMark 的文本控制台也 include 它 */\n\n")
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
        f.write("/* 调色板（TILE_N_PALETTE / TILE_PALETTE）在 palette.h 里，见上面的 include */\n\n")
        f.write("/* [!] 2026-10-18：36 块棋盘图块的**像素表**已从本文件移走 ——\n")
        f.write(" *     render.c 现在按同一套几何**运行时合成**（synth_board_tile），\n")
        f.write(" *     省下 9,216 字节 .rodata（RT-Thread 镜像就靠这 9KB 才装得下堆）。\n")
        f.write(" *     像素表在 tiles_data.h，**只给 x86 单测当参考真值**，不进固件。 */\n\n")
        f.write("#endif /* GOMOKU_TILES_H */\n")

    # ---- 参考像素表（只给单测用，不进固件）----
    dpath = path.replace("tiles.h", "tiles_data.h")
    with open(dpath, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * tiles_data.h —— 36 块棋盘图块的**参考像素表**（只给 x86 单测）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" * [!] **不要 include 进固件**：9,216 字节的常量表会把 RT-Thread 镜像顶爆。\n")
        f.write(" *     固件侧用 render.c 的 synth_board_tile() 运行时合成；\n")
        f.write(" *     test_render.c 拿这张表逐像素对拍，保证两边画出来的完全一样。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_TILES_DATA_H\n#define GOMOKU_TILES_DATA_H\n\n")
        f.write("#include \"tiles.h\"\n\n")
        f.write("/* [TILE_OF(shape,state)][py*16+px] = 调色板索引 */\n")
        f.write("static const uint8_t TILE_PATTERN[TILE_N_TOTAL][TILE_BYTES] = {\n")
        for i, img in enumerate(tiles):
            sh, st = i // N_STATE, i % N_STATE
            f.write("    {   /* tile %2d = shape %d state %d */\n" % (i, sh, st))
            for y in range(TILE):
                f.write("        " + ",".join("%d" % v for v in img[y]) + ",\n")
            f.write("    },\n")
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_TILES_DATA_H */\n")


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
    pout = os.path.join(here, "palette.h")
    emit_palette(pout)
    print("已生成 %s" % pout)
    out = os.path.join(here, "tiles.h")
    emit(out)
    print("已生成 %s" % out)
    fout = os.path.join(here, "font.h")
    emit_font(fout)
    print("已生成 %s" % fout)
    dump_preview(2)
    dump_font_preview()
