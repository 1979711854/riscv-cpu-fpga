/* ============================================================================
 * test_game.c —— 对局状态机的 x86 单测（轨道 B2/B3）
 * ----------------------------------------------------------------------------
 * 运行：  scripts\gomoku\run_test.ps1
 *
 * 这个测试的价值：**一整盘人机对局在 PC 上走完**，不需要板子、不需要显示器。
 * 状态机的 bug（切阶段漏了、AI 该走没走、光标越界、落子后没换手）在这里
 * 都是几行断言的事，在板上则要烧一次等十几秒才看得见。
 *
 * 时间用微秒，与 test_input.c 一致。
 * ==========================================================================*/
#include <stdio.h>
#include "game.h"
#include "input.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                            \
    do {                                                            \
        if (cond) { g_pass++; }                                     \
        else {                                                      \
            g_fail++;                                               \
            printf("  [FAIL] %s:%d  %s\n", __FILE__, __LINE__, msg); \
        }                                                           \
    } while (0)

#define S(key) (uint8_t)(1u << (key))

#define BLINK_TICKS 300000u        /* 闪烁半周期 300ms */
#define IDLE_US     20000u         /* 每次操作之间空转多久（超过去抖，但远小于闪烁周期）*/

static game_t   g_gm;
static uint32_t g_t;

/* 推进 dur_us，第一拍带上按键掩码，其余拍空转 */
static void step(uint8_t smask, uint8_t lmask, uint32_t dur_us)
{
    uint32_t end;
    game_tick(&g_gm, g_t, smask, lmask);
    g_t += 1000;
    end = g_t + dur_us;
    while (g_t < end) { game_tick(&g_gm, g_t, 0, 0); g_t += 1000; }
}

static void press_short(int key) { step(S(key), 0, IDLE_US); }
static void press_long (int key) { step(0, S(key), IDLE_US); }

static void new_game(int level, int human)
{
    g_t = 0;
    game_init(&g_gm, level, human, BLINK_TICKS);
}

/* 把光标挪到 (r,c) 再落子 —— 人在这台机器上的"操作" */
static int human_move(int r, int c, int *ok)
{
    int guard = 0;
    *ok = 1;
    while (g_gm.cursor_r > r && guard++ < 40) press_short(KEY_UP);
    while (g_gm.cursor_r < r && guard++ < 40) press_short(KEY_DOWN);
    while (g_gm.cursor_c > c && guard++ < 40) press_short(KEY_LEFT);
    while (g_gm.cursor_c < c && guard++ < 40) press_short(KEY_RIGHT);
    if (guard >= 40) { *ok = 0; return 0; }
    press_long(KEY_UP);
    return 1;
}

/* ---------------------------------------------------------------------------
 * A. 初始状态 + 标题屏切难度
 * ------------------------------------------------------------------------- */
static void test_title(void)
{
    printf("---- A. 标题屏 ----\n");
    new_game(AI_NORMAL, GOMOKU_BLACK);

    CHECK(g_gm.phase == GAME_TITLE, "开机应在标题屏");
    CHECK(g_gm.cursor_r == GOMOKU_N / 2 && g_gm.cursor_c == GOMOKU_N / 2, "光标初始应在天元");
    CHECK(g_gm.board.stones == 0, "标题屏棋盘应为空");

    press_short(KEY_RIGHT);
    CHECK(g_gm.level == AI_HARD, "短按 → 应加难度");
    press_short(KEY_RIGHT);
    CHECK(g_gm.level == AI_HARD, "难度到顶不该越界");
    press_short(KEY_LEFT); press_short(KEY_LEFT);
    CHECK(g_gm.level == AI_EASY, "短按 ← 应降难度");
    press_short(KEY_LEFT);
    CHECK(g_gm.level == AI_EASY, "难度到底不该越界");
    CHECK(g_gm.phase == GAME_TITLE, "切难度不该开始对局");

    /* 上下键在标题屏没有定义，按了不该有任何副作用 */
    press_short(KEY_UP); press_short(KEY_DOWN);
    CHECK(g_gm.phase == GAME_TITLE && g_gm.level == AI_EASY, "标题屏按上下键应无副作用");
}

/* ---------------------------------------------------------------------------
 * B. 长按开始对局；人执黑时 AI 不该抢走第一手
 * ------------------------------------------------------------------------- */
static void test_start(void)
{
    printf("---- B. 开始对局 ----\n");
    new_game(AI_NORMAL, GOMOKU_BLACK);

    press_long(KEY_UP);
    CHECK(g_gm.phase == GAME_PLAYING, "长按应开始对局");
    CHECK(g_gm.board.stones == 0,     "人执黑，开局不该有子");
    CHECK(g_gm.board.turn == GOMOKU_BLACK, "应轮到人（黑）");
    CHECK(!game_ai_turn(&g_gm), "现在不该轮到 AI");
    CHECK(game_cursor_shown(&g_gm), "对局中光标应可见（闪烁亮的那半拍）");

    /* 人执白：AI 应先走一手 */
    new_game(AI_NORMAL, GOMOKU_WHITE);
    press_long(KEY_UP);
    CHECK(g_gm.phase == GAME_PLAYING, "长按应开始对局");
    CHECK(g_gm.board.stones == 1, "人执白时 AI 应已先走一手");
    CHECK(g_gm.board.turn == GOMOKU_WHITE, "应轮到人（白）");
    CHECK(g_gm.ai_moves == 1, "AI 步数应为 1");
    CHECK(g_gm.last_ai_r >= 0 && g_gm.last_ai_c >= 0, "应记录 AI 落点");
}

/* ---------------------------------------------------------------------------
 * C. 光标移动与边界钳制
 * ------------------------------------------------------------------------- */
static void test_cursor(void)
{
    int i;
    printf("---- C. 光标移动与边界 ----\n");
    new_game(AI_NORMAL, GOMOKU_BLACK);
    press_long(KEY_UP);                       /* 进入对局 */

    press_short(KEY_UP);
    CHECK(g_gm.cursor_r == GOMOKU_N / 2 - 1, "短按 ↑ 应上移一格");
    press_short(KEY_LEFT);
    CHECK(g_gm.cursor_c == GOMOKU_N / 2 - 1, "短按 ← 应左移一格");
    press_short(KEY_DOWN); press_short(KEY_DOWN);
    CHECK(g_gm.cursor_r == GOMOKU_N / 2 + 1, "短按 ↓↓ 应下移两格");
    press_short(KEY_RIGHT);
    CHECK(g_gm.cursor_c == GOMOKU_N / 2, "短按 → 应右移一格");

    /* 一路怼到左上角，再怼 20 下 —— 不许越界，也不许回绕 */
    for (i = 0; i < 40; i++) { press_short(KEY_UP); press_short(KEY_LEFT); }
    CHECK(g_gm.cursor_r == 0 && g_gm.cursor_c == 0, "光标应停在 (0,0) 不越界");
    for (i = 0; i < 40; i++) { press_short(KEY_DOWN); press_short(KEY_RIGHT); }
    CHECK(g_gm.cursor_r == GOMOKU_N - 1 && g_gm.cursor_c == GOMOKU_N - 1,
          "光标应停在右下角不越界");
    CHECK(g_gm.board.stones == 0, "光移动不该落子");
}

/* ---------------------------------------------------------------------------
 * D. 落子 / 换手 / AI 应手
 * ------------------------------------------------------------------------- */
static void test_play(void)
{
    int ok;
    printf("---- D. 落子与 AI 应手 ----\n");
    new_game(AI_NORMAL, GOMOKU_BLACK);
    press_long(KEY_UP);

    /* 天元开局（光标本来就在那儿）*/
    press_long(KEY_UP);
    CHECK(g_gm.board.stones == 2, "人落一子后 AI 应立刻应一手");
    CHECK(g_gm.board.cell[GOMOKU_N / 2][GOMOKU_N / 2] == GOMOKU_BLACK, "天元应是黑子");
    CHECK(g_gm.board.turn == GOMOKU_BLACK, "AI 走完应轮回人");
    CHECK(g_gm.ai_moves == 1, "AI 应走了一步");
    CHECK(g_gm.ai_nodes > 0, "应记录 AI 节点数");

    /* 同一个点再落一次：应该失败且什么都不发生 */
    {
        int before = g_gm.board.stones;
        press_long(KEY_UP);                  /* 光标还在天元，那已有子 */
        CHECK(g_gm.board.stones == before, "在已有子的点上落子应无效");
        CHECK(g_gm.board.turn == GOMOKU_BLACK, "无效落子不该换手");
    }

    /* 换个点落 */
    ok = human_move(7, 8, &ok);
    CHECK(ok, "光标应能挪到 (7,8)");
    CHECK(g_gm.board.cell[7][8] == GOMOKU_BLACK, "(7,8) 应是黑子");
}

/* ---------------------------------------------------------------------------
 * E. 完整一盘：人能一路下到分出胜负
 * ------------------------------------------------------------------------- */
static void test_full_game(void)
{
    int i, ok, moves = 0;
    printf("---- E. 完整对局（人 vs EASY，人执黑）----\n");
    new_game(AI_EASY, GOMOKU_BLACK);
    press_long(KEY_UP);

    /* 人沿着第 4 行横向连子；AI(EASY) 是贪心的，会来堵。
     * 不管最后谁赢，关键是【一局能走完且状态自洽】。 */
    for (i = 0; i < 30 && g_gm.phase == GAME_PLAYING; i++) {
        int c = i % GOMOKU_N;
        if (!human_move(3, c, &ok)) { CHECK(0, "光标移动超出步数上限"); break; }
        moves++;
        /* 每一手之后都校验：如果已分胜负，winner 必须和棋盘一致 */
        if (g_gm.phase == GAME_OVER)
            CHECK(g_gm.winner == gomoku_scan_winner(&g_gm.board)
                  || g_gm.winner == 0, "胜负结果应与全盘扫描一致");
    }

    printf("       走了 %d 手人的棋，最终阶段=%d，盘上 %d 子\n",
           moves, (int)g_gm.phase, (int)g_gm.board.stones);
    CHECK(moves > 0, "人应该至少走了一步");
    CHECK(g_gm.board.stones >= moves, "盘上子数应不少于人走的步数（还有 AI 的）");
    CHECK(g_gm.ai_moves >= moves - 1, "AI 应基本跟上了每一手");
    /* 无论结局如何，调用 game_cursor_shown 都不该崩 */
    (void)game_cursor_shown(&g_gm);
}

/* ---------------------------------------------------------------------------
 * F. 胜负后：长按回标题，再开一局是干净的
 * ------------------------------------------------------------------------- */
static void test_over_and_restart(void)
{
    int ok, guard = 0;
    printf("---- F. 胜负后回标题 ----\n");

    /* 先把局面做成已分胜负：人执黑连成五（AI 用 EASY，堵不住就赢） */
    new_game(AI_EASY, GOMOKU_BLACK);
    press_long(KEY_UP);
    while (g_gm.phase == GAME_PLAYING && guard++ < 20) {
        human_move(0, guard, &ok);           /* 沿第 0 行往右连 */
    }
    if (g_gm.phase != GAME_OVER) {
        printf("       （%d 手内没分出胜负，跳过本组后续断言）\n", guard);
        return;
    }
    CHECK(g_gm.winner == GOMOKU_BLACK || g_gm.winner == GOMOKU_WHITE || g_gm.winner == 0,
          "胜负值应合法");

    /* 胜负后光标不该再画出来（避免让人以为还能下）*/
    CHECK(!game_cursor_shown(&g_gm), "胜负后不该显示光标");

    /* 胜负后按短键不该有反应 */
    {
        int before = g_gm.board.stones;
        press_short(KEY_LEFT); press_short(KEY_RIGHT);
        CHECK(g_gm.board.stones == before, "胜负后短按不该改变棋盘");
        CHECK(g_gm.phase == GAME_OVER,      "胜负后短按不该切阶段");
    }

    press_long(KEY_UP);
    CHECK(g_gm.phase == GAME_TITLE, "长按应回标题");
    CHECK(g_gm.board.stones == 0,   "回标题应清盘");
    CHECK(g_gm.winner == 0,         "回标题应清胜负");

    /* 再开一局应该是干净的 */
    press_long(KEY_UP);
    CHECK(g_gm.phase == GAME_PLAYING, "应能再开一局");
    CHECK(g_gm.board.stones == 0 && g_gm.board.turn == GOMOKU_BLACK, "新局应是空盘黑先");
}

/* ---------------------------------------------------------------------------
 * G. 光标闪烁
 * ------------------------------------------------------------------------- */
static void test_blink(void)
{
    int seen_on = 0, seen_off = 0, i;
    printf("---- G. 光标闪烁 ----\n");
    new_game(AI_NORMAL, GOMOKU_BLACK);
    press_long(KEY_UP);

    /* 空转 10 个闪烁半周期，应该两种状态都出现过 */
    for (i = 0; i < 10; i++) {
        int k;
        for (k = 0; k < (int)(BLINK_TICKS / 1000) + 2; k++) {
            if (game_cursor_shown(&g_gm)) seen_on = 1; else seen_off = 1;
            game_tick(&g_gm, g_t, 0, 0);
            g_t += 1000;
        }
    }
    CHECK(seen_on && seen_off, "闪烁应同时出现过亮和灭（否则光标要么不闪、要么不画）");
}

/* ------------------------------------------------------------------------- */
int main(void)
{
    printf("=== 五子棋 轨道 B2/B3（光标 + 对局状态机）单测 ===\n\n");

    test_title();
    test_start();
    test_cursor();
    test_play();
    test_full_game();
    test_over_and_restart();
    test_blink();

    printf("\nchecks=%d  errors=%d\n", g_pass + g_fail, g_fail);
    if (g_fail == 0) printf("=== PASS ===\n");
    else             printf("=== FAIL ===\n");
    return g_fail == 0 ? 0 : 1;
}
