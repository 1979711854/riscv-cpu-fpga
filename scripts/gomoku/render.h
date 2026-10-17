/* ============================================================================
 * render.h —— 五子棋渲染层（轨道 A3）
 * ----------------------------------------------------------------------------
 * 干什么：把"棋盘 + 棋子 + 光标"翻译成**显存里的字节**。它不碰 RTL、不碰 PPU，
 *         只按 addr_map 的约定写三块显存：
 *             nametable  = 每格放哪个图块号（8KB，字节寻址 r*256+c）
 *             pattern    = 每个图块的 16x16 像素（64KB，字节寻址 T*256+py*16+px）
 *             palette    = 256 项 24bit RGB（1KB，字寻址 i*4）
 *
 * [!] 关键约束（来自显示硬件的现状）：**没有精灵层**。
 *     所以"光标"不是叠上去的，而是**换图块** —— 把那一格换成"带光标的图块"。
 *     同理棋子也是烤进图块的。因此：
 *         移动光标 = 写 2 个字节（旧格换回普通、新格换成光标）
 *         落子     = 写 1 个字节
 *     这也是本模块存在的意义：把"该换成哪一块"这件事集中到一处，
 *     免得棋盘逻辑里散落一堆 tile 号算术。
 *
 * 平台无关：唯一的外部依赖是 vid_bulk_write()，固件侧是 MMIO、x86 测试侧是假数组，
 *          所以 render.c 两边跑同一份（见 test_render.c）。
 * ==========================================================================*/
#ifndef GOMOKU_RENDER_H
#define GOMOKU_RENDER_H

#include <stdint.h>
#include "board.h"

/* ---- 显存分区（vid_bulk_write 的 region 参数）---- */
#define VID_REGION_NT   0
#define VID_REGION_PAT  1
#define VID_REGION_PAL  2

/* 由【平台】实现：把 len 个字节写进显存对应分区的 offset 处。
 *   固件侧  -> MMIO 直写（scripts/gomoku/video_port.c）
 *   x86 测试 -> 写进假 VRAM 数组（test_render.c）
 * 这是本模块唯一的平台依赖 —— 有了它，render.c 才能在 PC 上被逐字节验证。 */
void vid_bulk_write(uint8_t region, uint16_t offset, const uint8_t *data, uint16_t len);

/* ---- 棋盘在屏幕上的位置 ----------------------------------------------------
 * 屏幕是 40 列 × 30 行图块（640×480 像素）。15×15 的棋盘居中：
 *   列起点 (40-15)/2 = 12，行起点 (30-15)/2 = 7
 * 剩下的边角留给 HUD。scroll 保持 0（棋类是静态的，不需要滚动）。 */
#define SCREEN_COLS  40
#define SCREEN_ROWS  30
#define BOARD_COL0   ((SCREEN_COLS - GOMOKU_N) / 2)   /* 12 */
#define BOARD_ROW0   ((SCREEN_ROWS - GOMOKU_N) / 2)   /* 7  */

/* ---- 图块编号：必须与 gen_tiles.py 的 TILE_OF 一致 ---- */
#define RENDER_SHAPE_N   9
#define RENDER_TILE(shape, state)  ((uint8_t)((shape) * 4 + (state)))
#define RENDER_ST_EMPTY   0
#define RENDER_ST_BLACK   1
#define RENDER_ST_WHITE   2
#define RENDER_ST_CURSOR  3

/* ---- 阶段 1 新增图块：由 render.c 在 render_init 里【运行时合成】（不写进 tiles.h），
 *     编号排在字库（36..130）之后，别动 FONT_TILE_BASE。 ----
 *     最后一手红标 = 棋盘图块 + 右上角红三角；星位 = 内部空格 + 中心点；
 *     外框横/竖线 = 2px 纯线；图标 = 纯底棋子。外框四角复用棋盘边角图块
 *     （TILE_OF(shape 5/6/7/8, EMPTY)），不另设编号。 */
#define RENDER_TILE_LAST_BASE  131   /* 最后一手：131 + shape*2 + (黑?0:白?1)，共 18 */
#define RENDER_TILE_STAR       149   /* 星位点（天元 + 四小目） */
#define RENDER_TILE_FRAME_H    150   /* 外框横线 */
#define RENDER_TILE_FRAME_V    151   /* 外框竖线 */
#define RENDER_TILE_ICON_BLACK 152   /* 纯底黑子图标 */
#define RENDER_TILE_ICON_WHITE 153   /* 纯底白子图标 */

/* 交叉点 (r,c) 的网格线形状（0..8）—— 由"四条边有没有线"决定，见 gen_tiles.py */
uint8_t render_shape(int r, int c);

/* (r,c) 该显示哪一块图块。光标位置用 (cr,cc) 传，(-1,-1) 表示没有光标。
 * **光标的优先级高于棋子** —— 光标只在空交叉点上（落子合法性已经保证），
 * 所以正常情况下两者不会同时出现在一格。 */
uint8_t render_tile_for(const gomoku_t *g, int r, int c, int cr, int cc);

/* 上电调一次：把调色板 + 36 块图块写进显存。
 * [!] 显存上电是**随机内容**，不调这个函数屏幕上就是雪花。 */
void render_init(void);

/* 铺满整张棋盘（含光标）。落子/悔棋后直接全刷最省事：225 字节，
 * 在 62MHz 上就是几十微秒，比维护增量状态可靠得多。 */
void render_full(const gomoku_t *g, int cr, int cc);

/* 只重画一格 —— 光标移动时用它，省掉一次全刷 */
void render_cell(const gomoku_t *g, int r, int c, int cr, int cc);

/* 移动光标：只写 2 个字节（旧格重画成普通，新格画成带光标） */
void render_move_cursor(const gomoku_t *g, int oldr, int oldc, int newr, int newc);

/* 清屏成纯底色（用【空格字模】铺满）。标题画面之前调一次。
 * 空格字模是 16x16 的纯底色图块 —— 比原来的"内部形状空格"干净，
 * 后者带网格线，会让 HUD 留白区看起来像网格底。 */
void render_clear(void);

/* ---- HUD 文字 ----
 * 字库见 font.h：render_init() 已把紧凑 5x7 位图放大成 16x16 图块写到
 * tile FONT_TILE_BASE .. FONT_TILE_BASE+FONT_N_GLYPHS-1。这里按【绝对】屏幕
 * 行/列（0..29 / 0..39）写 nametable。小写自动折叠到大写，未定义字符落空格。 */
void render_text(int row, int col, const char *s);

/* 同一行水平居中写一段文字。 */
void render_text_center(int row, const char *s);

/* [2026-10-17] 幂等写：内容（含列）没变就跳过这一行的写。
 *   `slot` 是调用方给的固定编号 0..5，同一槽位要一直对应同一行；换行就换槽位。
 *   用途 = HUD 每帧重画时避免"内容没变也在重写"导致的闪烁。
 *   **`render_clear()` 会调用 `render_dedup_reset()` 作废缓存**，所以整屏重画后
 *   第一次写一定会落地，不会出现"同一行永远空白"。 */
void render_text_dedup(int slot, int row, int col, const char *s);

/* 作废所有幂等写缓存（整屏被抹平/切屏后必须调，否则旧缓存会吃掉新内容）。 */
void render_dedup_reset(void);

/* 居中版的幂等写。 */
void render_text_dedup_center(int slot, int row, const char *s);

/* ---- 静态装饰（阶段 1）----------------------------------------------------
 * 都只画【棋盘 15x15 之外的固定区域】，上电各调一次即可；render_full 每帧
 * 全刷只碰棋盘区，不会覆盖它们。 */
/* 写一个 nametable 字节（【绝对】行/列 0..29 / 0..39）。给 HUD 图标、坐标轴用。 */
void render_put(int row, int col, uint8_t tile);

/* 画棋盘外框（一圈 1 图块厚的边框，四角复用棋盘边角图块）。 */
void render_board_frame(void);

/* 画坐标轴：列 A-O（顶，外框上方）+ 行 1-15（左，外框左侧）。 */
void render_board_labels(void);

#endif /* GOMOKU_RENDER_H */
