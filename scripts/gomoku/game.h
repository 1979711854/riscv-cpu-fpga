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
 *   标题屏    短按 ←/→ 切难度        长按任意键 开始对局
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
    uint32_t t_blink;           /* 上次翻转时刻 */
    uint32_t blink_ticks;       /* 半周期（单位与 now 相同）*/

    int level;                  /* AI_EASY / AI_NORMAL / AI_HARD */
    int human;                  /* 人执哪一方（GOMOKU_BLACK / GOMOKU_WHITE）*/
    int winner;                 /* 0 = 未分胜负 */

    /* AI 最近一步的统计 —— 给上层打串口用（工作清单要求"打印节点数/耗时"）*/
    uint32_t ai_nodes;
    uint32_t ai_ms;
    int      ai_depth;
    int      ai_moves;          /* AI 一共走了几步 */
    int      last_ai_r, last_ai_c;  /* AI 最近一手（-1 = 还没走过）*/
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

/* 光标是否要画出来（闪烁 + 非 AI 思考时）*/
int game_cursor_shown(const game_t *gm);

#endif /* GOMOKU_GAME_H */
