/* ============================================================================
 * game.h —— 对局状态机（轨道 B2/B3）
 * ----------------------------------------------------------------------------
 * 标题屏 → 对局 → 胜负 → 回标题。光标移动/落子、轮到谁、AI 何时出手，都在这里。
 *
 * [!] 本文件**不碰硬件**：时间由调用方传进来（now），按键由调用方取成掩码传进来，
 *     画面更新交给 render.*，AI 交给 ai.*。所以整个对局逻辑能在 PC 上跑完整盘。
 *
 * 按键方案（板上只有 4 个用户键 SW4..SW7 = key[0..3]，见 input.h 的论证）：
 *
 *   标题屏    短按 ←/→ 切难度        长按 ↑ 自对弈演示，长按其它键 开始对局
 *   对局中    短按 ←/→/↑/↓ 移动光标   长按任意方向键 在光标处落子
 *   胜负后    长按任意键 回标题
 *
 *   人的颜色固定黑（先手）—— 先手在五子棋里有优势，让 AI 后手能看出棋力。
 *
 * [!] AI 是在 game_tick() 里**同步跑**的，会阻塞。回合制棋盘游戏里这是可接受的
 *     （思考期间光标不闪而已）。但 HARD 档在板上要多久**还没标定** ——
 *     如果太慢，`level` 就只开 EASY/NORMAL 两档。
 * ==========================================================================*/
#ifndef GOMOKU_GAME_H
#define GOMOKU_GAME_H

#include <stdint.h>
#include "board.h"
#include "ai.h"

typedef enum {
    GAME_TITLE = 0,     /* 标题屏：选难度 */
    GAME_PLAYING,       /* 对局中 */
    GAME_OVER           /* 已分胜负或平局 */
} game_phase_t;

typedef struct {
    gomoku_t     board;
    game_phase_t phase;

    int cursor_r, cursor_c;     /* 光标位置（交叉点坐标） */
    int cursor_on;              /* 闪烁：这一拍光标画不画 */
    int cursor_hidden;          /* 落子后临时藏起光标 —— 见 game_cursor_shown 的说明 */
    uint32_t t_blink;           /* 上次翻转时刻 */
    uint32_t blink_ticks;       /* 半周期（单位与 now 相同）*/

    int level;                  /* AI_EASY / AI_NORMAL / AI_HARD */
    int human;                  /* 人执哪一方（GOMOKU_BLACK / GOMOKU_WHITE）*/
    int winner;                 /* 0 = 未分胜负 */

    /* 自对弈演示模式：双方都是 AI，每手之间停 demo_delay。 */
    int      demo;              /* 1 = 演示（AI vs AI）*/
    uint32_t demo_delay;        /* 每手之间的间隔（单位与 now 相同）*/
    uint32_t t_next_ai;         /* 演示模式下下一手 AI 的时刻 */

    /* AI 最近一步的统计 —— 给上层打串口用（工作清单要求"打印节点数/耗时"）*/
    uint32_t ai_nodes;
    uint32_t ai_ms;
    int      ai_depth;
    int      ai_moves;          /* AI 一共走了几步 */
    int      last_ai_r, last_ai_c;  /* AI 最近一手（-1 = 还没走过）*/

    /* G3 异步 AI：派单时的棋盘副本 + 是否在等结果。
     * game_tick 内部只调 game_ai_begin（快、不阻塞、只置 ai_pending 并拷盘）；
     * 真正的搜索由宿主决定怎么跑 —— 裸机/x86 同步算完，RT-Thread 丢给低优先级 AI 线程。 */
    gomoku_t ai_snap;           /* AI 只搜这个副本，绝不动真盘 board */
    int      ai_pending;        /* 1 = 已派单、等 AI 结果 */
    uint32_t ai_gen;            /* 派单序号：每次 game_ai_begin 自增，宿主据此丢弃过期结果 */
} game_t;

/* 初始化并进入标题屏。
 *   level 初始难度；blink_ticks 光标闪烁半周期（单位与 now 相同）。
 *   human 传 GOMOKU_BLACK 或 GOMOKU_WHITE。 */
void game_init(game_t *gm, int level, int human, uint32_t blink_ticks);

/* 推进一拍。
 *   now        = 当前时刻
 *   short_mask = bit k = 这一拍有 key k 的【短按】事件
 *   long_mask  = bit k = 这一拍有 key k 的【长按】事件
 * 调用方每拍从 input.c 取完事件后调它一次。 */
void game_tick(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask);

/* 现在轮到 AI 吗（标题屏/胜负后不算）*/
int game_ai_turn(const game_t *gm);

/* 光标是否要画出来。
 * [!] 落子之后会【临时藏起来】，直到玩家再按方向键。原因：显示层没有精灵，
 *     光标和棋子占用的是【同一层的同一块图块】—— 光标画着就看不见底下的子。
 *     而刚落完子那一拍恰恰是玩家最想确认自己下在哪的时候，所以让它先消失，
 *     一按键（反正要挪光标了）立刻回来。
 *     另一条路是给 9 种网格形状各加 黑/白 两个带光标的图块（+18 块 = +4.6KB），
 *     但 32KB 里那 4.6KB 更该留给后面加字库。 */
int game_cursor_shown(const game_t *gm);

/* ---- 异步 AI（G3）----------------------------------------------------------
 * 「该不该下」和「下在哪」拆成两步：game_tick 内部只调 game_ai_begin
 * （幂等派单，置 ai_pending 并拷盘，立即返回、绝不阻塞）；搜索由宿主跑 ——
 * 裸机/x86 用 game_ai_run_sync 同步算完，RT-Thread 把 ai_snap 丢给低优先级
 * AI 线程、算完再 game_ai_finish 落子。 */
int game_ai_begin(game_t *gm);
int game_ai_finish(game_t *gm, uint32_t now, int r, int c, const ai_stats_t *st);
const gomoku_t *game_ai_snapshot(const game_t *gm);
int game_ai_run_sync(game_t *gm, uint32_t now, ai_stats_t *out_st);

#endif /* GOMOKU_GAME_H */
