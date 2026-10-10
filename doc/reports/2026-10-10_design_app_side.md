# 应用侧 + 覆盖侧设计（2026-10-10）

> 入口/现状看 `2026-10-10_handoff_teammate.md`（总入口）与
> `2026-10-10_session_state.md`。本文只写**还没做**的：C / D / E / F / H-剩余 / 覆盖 A / 覆盖 B。
>
> **已经做完、别重做**：A（video_wait_vblank 超时）、B（双重 LEVEL 清行）、
> G（32KB→64KB，可用 RAM 60KB）、H 单线程仿真 PASS。CPU 侧（A 扩展 + 85MHz +
> 64KB）已收口。**CoreMark 现已到 324.4 分**（阶段0 编译选项 + 阶段1 到达级重定向，
> 见 `2026-10-10_review_stage01.md`）—— 本文写于那之前，下面提到 270.82 的地方按新口径读。

---

## 0. 三十秒版

| # | 任务 | 一句话设计 | 落点 |
|---|---|---|---|
| C | 菜单 + 双向独立难度 + 间隔 | `game_t` 加 `mode/level_black/level_white/step_ms/menu_stage/menu_sel`，`demo` 并入「双 AI」模式，5 阶段状态机 | game.h/game.c/main.c/test_game.c |
| D | HUD 行距 | TURN 第 1 行、LEVEL 第 3 行；标题专用行统一清行 | main.c（随 C） |
| E | AI 思考不卡（G1+G2） | ai.c 的同步 `ai_choose_move` 拆成 `ai_search_t + begin/step`（每层 `AI_STEP_BUDGET`），主循环每帧推进一层 | ai.h/ai.c/game.c/main.c |
| F | CoreMark 编进固件跑一遍显示分数 | 把 `third_party/coremark/` 核心 + 端口链进 gomoku 固件，开机跑一次，把真分数打上标题屏 + 串口 | gomoku/build.ps1、main.c、新增 wrapper |
| H-剩余 | RT-Thread 上板 + G3 | 单线程版上板验完，再拆 render(高优)/AI(低优) 两线程 | scripts/rtthread/ |
| 覆盖 A | AMO 转 tohost | `tb_amo_cpu.S` 改 `RVTEST_PASS/FAIL` 形式，保留 11 个失败分支，从 `$skipThese` 移除 | sim/tests/tb_amo_cpu.S、run_own_tests.ps1 |
| 覆盖 B | 代码 >32KB 取指 | 新增 `hi_fetch.S`：运行时把代码拷到 0x8000 以上，毒丸验证 `s0==0 && t2==N` | sim/tests/hi_fetch.S |

覆盖 A/B 的**字节级完整做法**已在 `2026-10-10_handoff_teammate.md` §2 里写好，实现时两篇对着读。

---

## 1. C —— 菜单系统 + AI 双向独立难度 + 每手间隔（最大一块）

### 1.1 目标

- 两种**模式**：`HUMAN`（人机对弈）/ `AI`（双 AI 自对弈，原 `demo` 并入这里）。
- 人机模式：独立设 **AI 难度** + **执子颜色**。
- 双 AI 模式：**黑白双方独立难度** + **每手间隔三档**。
- 5 阶段菜单：`MODE → (LEVEL → COLOR | AI_LEVELS → STEP)`。
- 操作约定（沿用现有输入）：**短按 = 移动/改值，长按 600ms = 确认进入下一阶段**。

### 1.2 `game.h` 数据结构改动

```c
typedef enum { GAME_MODE_HUMAN = 0, GAME_MODE_AI = 1 } game_mode_t;

typedef enum {
    MENU_STAGE_MODE,      /* 选模式：HUMAN / AI */
    MENU_STAGE_LEVEL,     /* 人机：选 AI 难度 */
    MENU_STAGE_COLOR,     /* 人机：选执子色 */
    MENU_STAGE_AI_LEVELS, /* 双AI：选黑白双方难度（两列） */
    MENU_STAGE_STEP,      /* 双AI：选每手间隔 */
    MENU_STAGE_COUNT
} menu_stage_t;

typedef struct {
    /* ... 原有 board/phase/keys 不变 ... */

    game_mode_t  mode;          /* 替代原 demo */
    int          human;         /* 人机模式执子色（BLACK/WHITE，菜单 COLOR 阶段定） */
    int          level_black;   /* 黑方 AI 难度（AI_EASY=0 / AI_NORMAL=1 / AI_HARD=2） */
    int          level_white;   /* 白方 AI 难度 */
    uint32_t     step_ms;       /* 双AI 每手间隔（毫秒） */

    menu_stage_t menu_stage;
    int          menu_sel;      /* 当前高亮行 / 列 */

    uint32_t     t_next_ai;

    /* 任务 E 的 G2 分步搜索状态（见 §3） */
    ai_search_t  ai_srch;
    int          ai_thinking;
    uint32_t     ai_t0;
} game_t;

/* 签名收敛：只传默认难度 + 每毫秒 tick 数，blink_ticks 内部派生 */
void game_init(game_t *gm, int level, uint32_t ticks_per_ms);
```

删除：`demo`、`demo_delay` 两个字段（`demo` 语义并入 `mode==GAME_MODE_AI`）。

### 1.3 `game.c` 状态机

新增两个查询（`game_ai_turn` 语义修正 + 当前回合难度）：

```c
/* 当前这一手是否该 AI 下：双AI 恒真；人机 = 轮到非人类色 */
int game_ai_turn(const game_t *gm) {
    if (gm->mode == GAME_MODE_AI) return 1;
    return gm->board.turn != gm->human;
}
int game_current_level(const game_t *gm) {
    return (gm->board.turn == GOMOKU_BLACK) ? gm->level_black : gm->level_white;
}
```

`run_ai_move()` / AI 调用点一律改用 `game_current_level(gm)`，不再读单个 `gm->level`。

`tick_title()` 重写为 5 阶段状态机（短按改值、长按确认；进入每阶段时 `menu_sel` 复位到默认项）：

| 阶段 | 键 | 作用 | 确认后 |
|---|---|---|---|
| MODE | UP/DOWN | HUMAN ↔ AI | AI→AI_LEVELS；HUMAN→LEVEL |
| LEVEL | UP/DOWN | EASY/NORMAL/HARD | →COLOR |
| COLOR | UP/DOWN | BLACK/WHITE | →开始对局 |
| AI_LEVELS | LEFT/RIGHT | 切活动列（黑/白） | — |
| AI_LEVELS | UP/DOWN | 改活动列难度 | →STEP（长按） |
| STEP | UP/DOWN | FAST/MID/SLOW | →开始对局 |

默认值：MODE=`HUMAN`、LEVEL=`NORMAL`、COLOR=`BLACK`、AI_LEVELS 双方=`NORMAL`、STEP=`MID`。

间隔档位常量（`game.h`）：`STEP_FAST=500`、`STEP_MID=1500`、`STEP_SLOW=3000`（单位 ms，与现 `DEMO_DELAY_MS=1500` 一致，MID 就是老演示间隔）。

`begin_playing()` 集中收口「确认后进入对局」的所有初始化：清盘、`phase=GAME_PLAYING`、
`t_next_ai = now + step_ms * ticks_per_ms`（双AI 空盘先停一拍再下第一手，保持老 demo 行为）。

### 1.4 `main.c` 渲染

新增 `draw_menu()`（标题屏专用，每帧整行重写）：

- 第 1 行：`GOMOKU`（居中，老样子）。
- 第 4 行：阶段标题（`MODE` / `AI LEVEL` / `COLOR` / `AI LEVELS` / `STEP`）。
- 第 8/10/12 行：当前阶段 2~3 个选项；高亮项用反色/`>` 标记，**上一处高亮必须整行重写擦掉**（CLAUDE.md 铁律）。
- `AI_LEVELS` 阶段：第 8 行 `BLACK`/`WHITE` 两列标题，第 10 行两列难度值，活动列高亮。
- 第 26/27 行：操作提示（`UP/DOWN 选择  HOLD 确认`）。

`draw_hud()` 的对局分支改为**模式感知**：
- 人机：`TURN` 行显示 `TURN: BLACK  YOU/AI`。
- 双 AI：`TURN` 行显示 `AI VS AI`，LEVEL 行显示双方难度。
- `LEVEL:` 行改用 `level_name(level_black/level_white)`，不再读单个 `level`。

`uart_dump_*()` 同步更新（把 `g_game.level` 换成 `level_black/level_white`、`mode` 分支输出）。

### 1.5 `test_game.c`

重写菜单相关用例（现第 55 行的 `game_init(&g_gm, level, human, BLINK_TICKS)` 换成
`game_init(&g_gm, level, TICKS_PER_MS)`）：
- `start_human_black` / `start_human_white`：走 MODE→LEVEL→COLOR 确认后，`human`/`level_black` 正确、`phase==PLAYING`。
- `start_ai`：MODE→AI_LEVELS（分别设黑/白难度）→STEP 确认后，`mode==AI`、`level_black/white` 各自正确、`step_ms` 正确。
- 越界：难度/间隔到顶到底不越界（对应现第 85~96 行的难度越界用例，扩到双方 + 间隔）。
- 标题屏副作用：各阶段按 UP/DOWN 只在当前阶段生效、不误改其它状态。

---

## 2. D —— HUD 行距重排（随 C 一起做，别单独改）

对局屏（`draw_hud` 对局分支）定稿行号：

| 行 | 内容 |
|---|---|
| 1 | `TURN:`（或 `AI VS AI`） |
| 3 | `LEVEL:`（从原来紧贴第 1 行改成第 3 行，拉开） |
| 7~21 | 棋盘 |
| 24 | 胜负横幅（game over 时） |
| 28 | `AI: NODES ... DEPTH ...`（AI 统计） |

**标题屏专用行清行**：标题屏现在占用 4/8/10/12/26/27 这几行，进入对局后必须擦掉。
做法：对局分支先对 `TITLE_ONLY_ROWS = {4,8,10,12,26,27}` 逐个 `render_text(row,0,"")`
（整行铺空格）。这同时把老 B（双重 LEVEL 清行）吸收成一个统一机制，不再单独在
第 3/27 行打补丁。

---

## 3. E —— AI 思考时画面卡顿（G1 + G2）

### 3.1 现状

`ai.c` 的 `ai_choose_move()` 是**同步**的：内部 `for (d=2; d<=depth; d+=2)` 迭代加深，
全局预算 `AI_NODE_BUDGET=12000`，一次算完整棵搜索才返回。板测最长 1433ms ——
期间主循环卡在 `ai_choose_move` 里，光标停、画面不动。

### 3.2 数据结构（`ai.h` 新增 `ai_search_t`）

把一次同步搜索的全部中间态搬进结构体，供「分步推进」：

```c
typedef struct {
    board_t work;          /* 搜索工作盘副本（AI 只在副本上算，不碰真盘） */
    int cand[225], order[225];  /* 候选落点 + 按启发排序后的索引 */
    int n;                 /* 候选数 */
    int width;             /* 每层候选宽度（EASY 贪心特殊处理） */
    int depth;             /* 目标深度：EASY=1 / NORMAL=4 / HARD=6 */
    int me;                /* 我方颜色 */

    int next_d;            /* 下一步要搜的深度 */
    int depth_done;        /* 上一轮完整搜完的深度（本层预算耗尽时回退用它） */
    int picked, best;      /* 当前最优落点（order[picked]）与评分 */
    int nodes, leaves;     /* 累计节点 / 叶节点 */
    int aborted;           /* 本层预算耗尽 */
    int greedy;            /* depth==1 的贪心捷径 */
    int done;              /* 已出结果 */
} ai_search_t;
```

### 3.3 算法（`ai.c`）

```c
void ai_search_begin(ai_search_t *s, const board_t *b, int level, int me);
int  ai_search_step(ai_search_t *s, int *out_r, int *out_c);  /* 1=已出结果；0=还要继续 */
void ai_search_abort(ai_search_t *s);
```

- `ai_search_begin`：由 `level` 定 `depth/width`，算候选与排序，`next_d = (greedy? 1 : 2)`。
- `ai_search_step`：**只搜一层**（深度 `next_d`），本层预算 `AI_STEP_BUDGET`（相对本层起点，不是全局）。
  预算耗尽 → `aborted=1`，回退到 `depth_done` 的最优结果，`done=1`；否则 `next_d += 2`，
  若 `next_d > depth` 则以本轮结果收尾。`done` 时把 `out_r/out_c` 填成 `work` 坐标。
- **保留同步包装**（PC 工具 `gomoku_cli.c` / `measure_ai.c` / `test_ai.c` 还在用，签名不变）：

```c
void ai_choose_move(const board_t *b, int level, int *r, int *c, ai_stats_t *st);
/* 内部 = ai_search_begin + 循环 ai_search_step 到 done */
```

- 常量：`AI_NODE_BUDGET`（全局 12000）→ **`AI_STEP_BUDGET = 1200`（每层）**。
  依据：HARD 整棵约 ~800 节点、最大单层 ~400~600，1200/层绰绰有余，**强度不降**；
  3 层合计最坏 ~3600，远小于原 12000 的全局上限，不影响对弈质量。

### 3.4 接线（`game.c` / `main.c`）

```c
/* game.c */
static void start_ai_search(game_t *gm) {
    ai_search_begin(&gm->ai_srch, &gm->board, game_current_level(gm), gm->board.turn);
    gm->ai_thinking = 1;
    gm->ai_t0 = now;
}
static int game_ai_step(game_t *gm) {   /* 每帧调一次，推进一层 */
    int r, c;
    if (!gm->ai_thinking) return 0;
    if (ai_search_step(&gm->ai_srch, &r, &c)) {
        gm->ai_thinking = 0;
        board_place(&gm->board, r, c);      /* 落子 + 记录 stats 供 HUD */
        return 1;
    }
    return 0;                              /* 还在想 */
}
```

`main.c` 主循环每帧顺序：
1. **G1**：人类落子后（`tick_playing` 里 `board_place` 已经即时写盘），马上 `start_ai_search`；
   **本帧照常 draw** —— 人类的子 + `AI THINKING` 状态立刻上屏。
2. `game_ai_step()` 推进一层。
3. `draw_frame()` —— HUD 显示 `AI: NODES <当前> DEPTH <next_d>`，光标正常闪烁。

**关键效果**：AI 总耗时不变，但被切成每帧一层，主循环再也不会卡在搜索里，光标全程动。

### 3.5 验收

- `test_ai.c` 增加**等价性测试**：同一批固定棋盘，`ai_choose_move`（同步）与
  `ai_search_begin + 循环 step`（分步）给出**完全相同**的落点。
- `measure_ai.c` 输出的节点数/耗时与改前**逐位一致**（证明强度没掉）。
- `run_test.ps1`（x86 侧 270 项 + RV32 交叉编译）全绿。
- 板测：HARD 走子期间光标不卡；串口 `AI thinking` 打印改成按 `game_current_level` 报难度。

---

## 4. F —— CoreMark 编进固件跑一遍显示分数（强版本，用户已定）

> 依据 `handoff_teammate.md` §1.4：60KB 放得下（gomoku 22.5KB + CoreMark 16.8KB = 39.3KB < 60KB），
> 所以「同一块板一起演示」成立，直接上**强版本**。

### 4.1 源码清单（复用现成的，不新写 CoreMark 本体）

- CoreMark 核心（不动）：`third_party/coremark/` 下 `core_main.c`、`core_list_join.c`、
  `core_matrix.c`、`core_state.c`、`core_util.c`。
- 端口（不动）：`scripts/coremark_port/` 下 `core_portme.c`、`ee_printf.c`、`core_portme.h`
  （`EE_TICKS_PER_SEC` 已是 85,005,100）。
- **排除** `scripts/coremark_port/start.S` —— 它提供 `_start`，与裸机 `demo/start.S` 冲突，
  合并构建里**不能**链它。

### 4.2 入口冲突处理

`core_main.c` 定义了 `main`（`MAIN_HAS_NO_ARGC` 二选一签名）。gomoku 裸机入口是
`main_entry.c` 的 `main`。二者链接期必撞，用**编译期改名**解决：

- `scripts/gomoku/build.ps1` 里给 `core_main.c` 加 `-Dmain=coremark_main`（或 `-DMAIN_HAS_NO_ARGC`
  并包一层 `coremark_main(void)` 薄封装），把 CoreMark 主循环改名为 `coremark_main`。

### 4.3 运行与展示

1. `gomoku_run()` 在**打完串口 banner 之后、进入菜单循环之前**调一次 `run_coremark_once()`：
   - 固定一个小 `ITERATIONS`（如 300 → 约 1.1s，别用 3170 的 11.7s，演示不能干等）。
   - 调 `coremark_main()`；把端口报告的真分数（或从 `total_ticks / EE_TICKS_PER_SEC` 重算）
     存进 `g_cmark_score` 全局。
2. 展示（两处都写，互相印证）：
   - 标题屏（`draw_menu`）第 6 行：`COREMARK <g_cmark_score> @85.0051MHz`。
   - 串口同一行（沿用 `[build] FW=... RTL=0x...` 的版本自证口径，让日志能自证网表 + 分数）。
3. 共享 MMIO 无需处理：CoreMark 的 `barebones_clock()` 读 0xFFF4、`ee_printf` 写 0xFFFC，
   与 gomoku 的 `hw_port` 同一兼容区，就是普通 UART TX。

### 4.4 验收

- `scripts\gomoku\build.ps1` 产出的 gomoku 固件能编译链接（无 `main` 重定义）。
- 板测：开机先出 `[build]` 行 → CoreMark 真跑一遍（分数 ≈270.8 附近，落在噪声内即自证真实）→
  进五子棋菜单，标题屏显示该分数。
- **铁律**：固件行数变了，`build_bitstream.ps1` 第 105 行 `expectLines['gomoku']` 会拦 ——
  实测新字数后更新它（`expectDesc` 同步改），**别放宽成宽松判断**。

---

## 5. H-剩余 —— RT-Thread 上板 + 拆线程做 G3

### 5.1 上板（先做）

- `scripts\build_bitstream.ps1 rtthread` → 烧板，串口应见 RT-Thread banner + 五子棋前进
  （单线程版已仿真 PASS，commit `925070d`）。`expectLines['rtthread']` 若因上板口径改动
  而变，实测后更新。

### 5.2 G3 —— 拆线程

把 `gomoku_run()` 的活拆成两个 RT-Thread 线程（用 `rt_thread` + `rt_mb` 邮箱 + `rt_mutex`
互斥，**不裸用全局变量**，任务书 §3.8 口径）：

- **render 线程（高优先级）**：`video_wait_vblank()` → `draw_frame()` → 轮询按键。
  显存写必须落在 vblank 里（这是拆线程的首要约束）。
- **AI 线程（低优先级）**：收到「该 AI 下」的邮箱消息后，用**现有同步 `ai_choose_move`**
  在**副本盘**上算完整步（RTOS 会抢占它，渲染不受阻），算完把落点经邮箱发回；
  主线程落子并画 G1（人类子即时上屏）。

关键点：
- **AI 读副本盘、主线程写真盘**，避免多毫秒搜索期间锁整块 `board_t`。
- G3 与 G2 的关系：**G2 是裸机的手动逐层切分，G3 是 RTOS 用线程抽象达成同一目的**；
  两边各做各的宿主，不互相替代。E 的 `ai_search_step` 已完成，G3 的 AI 线程想逐层让出
  时间片也可直接调它（二选一，推荐先用同步 `ai_choose_move` 最省事）。
- 验收：仿真 `scripts\rtthread\run_sim.ps1` 仍 `=== PASS ===`，且上板后 AI 思考期间
  光标/画面不卡、按键有响应。

---

## 6. 覆盖 A —— AMO 零回归：`tb_amo_cpu.S` 转 tohost

> 字节级做法见 `handoff_teammate.md` §2.1。要点：

1. **改写头部**：把自定义 `_start`/栈初始化换成 `RVTEST_CODE_BEGIN`（照抄 `exceptions.S` 的
   标准形，`#include "riscv_test.h"`），结尾 `RVTEST_PASS`。
2. **保留全部 11 个失败分支**（`fail_amoadd/aswap/chain/maxu/max/lr/sc/sc_mem/sc_noq/mix/mix2`），
   测试体（amoadd×10、amoswap、`0x80000000` 处的 signed/unsigned amomax、LR/SC、AMO+load 混用）**逐字不动**。
3. 每个失败分支 `li a0, 0xE1; j report` → `li TESTNUM, N; j fail`（N=1..11，按原错误码
   0xE1..0xEB 顺序映射），共享 `fail: RVTEST_FAIL`；删掉原 `report:` 的 UART `0xAC`/done `0xFFF8` 尾巴。
4. `scripts\run_own_tests.ps1`：从第 46 行 `$skipThese` 删掉 `'tb_amo_cpu'`，同步更新 41~45 行注释。
5. AMO 目标地址（0x2000/0x2010/0x2020/0x2030）在 RAM、避开 0xFFF0+ 兼容区，**不用动**。

**验收**：
- `scripts\run_own_tests.ps1 -Name tb_amo_cpu` → `=== PASS ===`；全量跑 PASS 数 +1。
- **故意弄坏（必须 FAIL）**：把 `rtl/core/amo_unit.v` 的 `amomax` 实现临时改成和
  `amomaxu` 一样（signed 比较换 unsigned），重跑 `tb_amo_cpu` → 必须落在 `fail_max`
  （TESTNUM=5）报 FAIL。然后**还原**。这一步不跑，就不知道测试是不是恒真。

---

## 7. 覆盖 B —— 「代码 > 32KB」取指测试：`hi_fetch.S`

> 字节级做法见 `handoff_teammate.md` §2.2。要点（用运行时拷贝，**不改链接脚本**）：

1. 新增 `sim/tests/hi_fetch.S`，tohost 形式（`RVTEST_PASS/FAIL`）。
2. 结构：
   - 低地址放「**毒丸**」：`addi s0, s0, 1` 重复 N 次（N 取 8191）。
   - 高地址（≥0x8000）放「**正确体**」：`addi t2, t2, 1` 重复 N 次。
   - 运行时 `la` 算出低区末尾地址 P，把正确体拷到 `D = 8191 + P`，`fence.i` 后 `jalr` 过去执行。
3. **判据**：跑完断言 `s0 == 0 && t2 == N`。
   - `s0 != 0` ⇒ 有取指口误取了低地址毒丸 —— 正是 `imem_addr2` 13 位截位（`f72ef25` 修的那个）的
     症状：PC 在 0x7FFC 时 lane B 取 0x8000，截位回绕到低 32KB → 取到毒丸。
4. 该测试用 tohost，**不进** `$skipThese`，随 `run_own_tests.ps1` 正常回归。
5. **故意弄坏（必须 FAIL）**：把 `rtl/core/core.v` 的 `imem_addr2` 端口宽度从 `[13:0]`
   临时退回 `[12:0]`，重跑 → `hi_fetch` 必须 FAIL（`s0 != 0`）。然后**还原**。

---

## 8. 铁律与总验收清单（改之前读一遍）

1. **改 RTL 必跑四条基线，逐位不变**：双发射 49/1/0 + CoreMark **262,018**；
   单发射 49/1/0 + **312,428**。（阶段0+1 之后的新口径；再往前是 -O2 的 313,886 / 363,515。）本项目 7 件事里只有「故意弄坏→验证→还原」会碰 RTL，
   还原后必须回到这四条数字。
2. **改 RTL 后、综合前，改 `rtl/core/csr_file.v` 的 `DESIGN_REV`**（固件把它打在串口第一行
   `[build] FW=... RTL=0x...`，日志靠它自证网表版本）。
3. **CoreMark 跑 ITER=1 时打印的 `ERROR! Must execute for at least 10 secs` / `Errors detected`
   是正常现象**，不是失败 —— 看 `Total ticks` 和四个 CRC。
4. **改了固件，`build_bitstream.ps1` 的行数守卫会拦你** —— 那是守卫在工作，实测后更新
   `expectLines`/`expectDesc`，别放宽它。
5. **「故意弄坏必须 FAIL」的验证别跳过**（覆盖 A 的 amomax 换 unsigned、覆盖 B 的
   imem_addr2 退回 13 位）—— 不跑就不知道测试是不是恒真。
6. 别按 SW2/D22（FPGA 配置键）；真复位是 SW3，判据是两盏 PLL 灯还亮不亮。
7. 变短/换行的字符串**整行重写**（render_text 先铺满空格再覆盖）；菜单高亮移动时上一处
   高亮必须擦掉。

**建议实施顺序**：C+D（一起）→ E → 覆盖 A → 覆盖 B → F → H（上板 → G3）。
C/D/E 互有依赖（都动 game.h/main.c），一起改一起测 `run_test.ps1`，别拆成三次改三遍 HUD。
