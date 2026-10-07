/* ============================================================================
 * game.c —— 对局状态机的实现（轨道 B2/B3）
 * ----------------------------------------------------------------------------
 * 纯逻辑：不碰任何硬件。时间、按键、画面、AI 都由外部注入。
 * ==========================================================================*/
#include "game.h"
#include "input.h"

/* 光标默认起点：天元（棋盘正中） */
#define CURSOR_HOME_R (GOMOKU_N / 2)
#define CURSOR_HOME_C (GOMOKU_N / 2)

static int clamp(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void game_init(game_t *gm, int level, int human, uint32_t blink_ticks)
{
    gomoku_reset(&gm->board);
    gm->phase        = GAME_TITLE;
    gm->cursor_r     = CURSOR_HOME_R;
    gm->cursor_c     = CURSOR_HOME_C;
    gm->cursor_on    = 1;
    gm->cursor_hidden= 0;
    gm->t_blink      = 0;
    gm->blink_ticks  = blink_ticks ? blink_ticks : 1;
    gm->level        = level;
    gm->human        = human;
    gm->demo         = 0;
    gm->demo_delay   = blink_ticks ? blink_ticks : 1;
    gm->t_next_ai    = 0;
    gm->winner       = 0;
    gm->ai_nodes     = 0;
    gm->ai_ms        = 0;
    gm->ai_depth     = 0;
    gm->ai_moves     = 0;
    gm->last_ai_r    = -1;
    gm->last_ai_c    = -1;
}

/* 让 AI 走一步（同步，会阻塞）。返回 GOMOKU_OK 表示落子成功。 */
static int run_ai_move(game_t *gm)
{
    int r = -1, c = -1;
    ai_stats_t st;
    int ret;

    ret = ai_choose_move(&gm->board, gm->level, &r, &c, &st);
    if (ret != GOMOKU_OK) return ret;

    gm->ai_nodes = st.nodes;
    gm->ai_depth = (int)st.depth;
    gm->ai_moves++;

    ret = gomoku_place(&gm->board, r, c);
    if (ret != GOMOKU_OK) return ret;      /* AI 给出了非法点，属于内部错误 */

    gm->last_ai_r = r;                      /* 见 .h：留给上层做提示用 */
    gm->last_ai_c = c;
    if (gm->board.winner) gm->winner = gm->board.winner;
    return GOMOKU_OK;
}

/* 处理一次落子后的公共收尾：判胜负、切阶段 */
static void after_move(game_t *gm)
{
    if (gm->board.winner) {
        gm->winner = gm->board.winner;
        gm->phase  = GAME_OVER;
    } else if (gomoku_is_full(&gm->board)) {
        gm->winner = 0;
        gm->phase  = GAME_OVER;            /* 平局 */
    }
}

int game_ai_turn(const game_t *gm)
{
    if (gm->phase != GAME_PLAYING) return 0;
    if (gm->demo) return 1;              /* 演示：双方都是 AI */
    return (gm->board.turn != gm->human);
}

int game_cursor_shown(const game_t *gm)
{
    return (gm->phase == GAME_PLAYING && gm->cursor_on && !gm->cursor_hidden) ? 1 : 0;
}

/* ---------------------------------------------------------------------------
 * 标题屏：短按 ←/→ 切难度；长按任意键开始
 * ------------------------------------------------------------------------- */
static void tick_title(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask)
{
    if (short_mask & (1u << KEY_LEFT)) {
        if (gm->level > AI_EASY) gm->level--;
    }
    if (short_mask & (1u << KEY_RIGHT)) {
        if (gm->level < AI_HARD) gm->level++;
    }
    if (long_mask & (1u << KEY_UP)) {       /* 长按 ↑ = 自对弈演示（任务书 B2）*/
        gomoku_reset(&gm->board);
        gm->winner    = 0;
        gm->ai_nodes  = 0;
        gm->ai_ms     = 0;
        gm->ai_depth  = 0;
        gm->ai_moves  = 0;
        gm->last_ai_r = -1;
        gm->last_ai_c = -1;
        gm->cursor_r  = CURSOR_HOME_R;
        gm->cursor_c  = CURSOR_HOME_C;
        gm->cursor_on = 1;
        gm->demo      = 1;
        gm->level     = AI_NORMAL;          /* 演示固定 NORMAL */
        gm->phase     = GAME_PLAYING;
        gm->t_next_ai = now + gm->demo_delay;  /* 空盘先停一拍再下第一手 */
    } else if (long_mask) {                 /* 长按其它键 = 正常开始 */
        gomoku_reset(&gm->board);
        gm->winner    = 0;
        gm->ai_nodes  = 0;
        gm->ai_ms     = 0;
        gm->ai_depth  = 0;
        gm->ai_moves  = 0;
        gm->last_ai_r = -1;
        gm->last_ai_c = -1;
        gm->cursor_r  = CURSOR_HOME_R;
        gm->cursor_c  = CURSOR_HOME_C;
        gm->cursor_on = 1;
        gm->demo      = 0;
        gm->phase     = GAME_PLAYING;

        /* 人若执白，AI 要先走一步 —— 在这里直接下掉，免得主循环要为
         * "开局第一手"再开一条特例路径 */
        if (gm->board.turn != gm->human) run_ai_move(gm);
    }
}

/* ---------------------------------------------------------------------------
 * 对局中：短按方向移动光标；长按方向落子
 * ------------------------------------------------------------------------- */
static void tick_playing(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask)
{
    int dr = 0, dc = 0;

    if (gm->demo) {
        /* 演示模式：忽略人类按键，按节拍让 AI 走；长按任意键 = 中途退回标题。 */
        if (long_mask) {
            gomoku_reset(&gm->board);
            gm->winner = 0;
            gm->demo   = 0;
            gm->phase  = GAME_TITLE;
            return;
        }
        if ((int32_t)(now - gm->t_next_ai) >= 0) {
            run_ai_move(gm);
            after_move(gm);
            gm->t_next_ai = now + gm->demo_delay;
        }
        return;
    }

    if (!game_ai_turn(gm)) {                /* AI 思考时不吃按键 */
        if (short_mask & (1u << KEY_LEFT))  dc -= 1;
        if (short_mask & (1u << KEY_RIGHT)) dc += 1;
        if (short_mask & (1u << KEY_UP))    dr -= 1;
        if (short_mask & (1u << KEY_DOWN))  dr += 1;

        if (dr || dc) {
            gm->cursor_r = clamp(gm->cursor_r + dr, 0, GOMOKU_N - 1);
            gm->cursor_c = clamp(gm->cursor_c + dc, 0, GOMOKU_N - 1);
            gm->cursor_on     = 1;          /* 一移动就把光标点亮，别让它正好落在暗的半拍 */
            gm->cursor_hidden = 0;          /* 同时解除"落子后藏起来" */
            gm->t_blink       = now;        /* 闪烁计时从这次移动重新起算 */
        }

        /* 长按方向键 = 在【当前光标位置】落子。
         * 光标不会因为长按而移动 —— 短按才移动，这是 input.h 里那套时序的用意。 */
        if (long_mask) {
            int ret = gomoku_place(&gm->board, gm->cursor_r, gm->cursor_c);
            if (ret == GOMOKU_OK) {
                /* 落子成功 -> 先把光标藏起来，让玩家看清自己刚下的那一手。
                 * 理由见 game.h 的 game_cursor_shown 注释。 */
                gm->cursor_hidden = 1;
                after_move(gm);
                if (gm->phase == GAME_PLAYING && game_ai_turn(gm)) {
                    run_ai_move(gm);
                    after_move(gm);
                }
            }
            /* 落子失败（该点已有子）就什么都不做 —— 用户自己会再挪一格。
             * 不弹提示是因为 v1 没有文字，画面上"什么都没发生"已经够清楚。 */
        }
    }
}

/* ---------------------------------------------------------------------------
 * 胜负后：长按任意键回标题
 * ------------------------------------------------------------------------- */
static void tick_over(game_t *gm, uint32_t now, uint8_t long_mask)
{
    (void)now;
    if (long_mask) {
        gomoku_reset(&gm->board);
        gm->winner = 0;
        gm->demo   = 0;
        gm->phase  = GAME_TITLE;
    }
}

void game_tick(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask)
{
    /* ---- 光标闪烁（所有阶段都推进，切阶段时不会卡在暗的半拍）---- */
    if ((uint32_t)(now - gm->t_blink) >= gm->blink_ticks) {
        gm->t_blink    = now;
        gm->cursor_on  = !gm->cursor_on;
    }

    switch (gm->phase) {
    case GAME_TITLE:   tick_title(gm, now, short_mask, long_mask);   break;
    case GAME_PLAYING: tick_playing(gm, now, short_mask, long_mask); break;
    default:           tick_over(gm, now, long_mask);                break;
    }
}
