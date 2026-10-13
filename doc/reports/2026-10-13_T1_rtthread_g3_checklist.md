# T1 —— RT-Thread 拆线程做 G3（AI 思考时画面不卡）可执行清单

> 日期：2026-10-13　任务线：五子棋 + RT-Thread（T1-T5 中的 T1）
> 目标：把现在「单线程 `gomoku_run()`」里的同步 AI，拆成 **render 线程（高优先）+ AI 线程（低优先）**，
> 让 NORMAL(0.4~0.7s) / HARD(6 层 14.5s) 思考期间光标照样闪、按键有响应、画面不卡。
>
> 依据：`doc/reports/2026-10-10_design_app_side.md` §5.2（G3 拆线程设计）与任务书 §3.8（线程间用信号量/邮箱，不裸用全局）。
> 现状代码：`scripts/gomoku/game.c` 的 `run_ai_move()`（同步阻塞）、`scripts/rtthread/app/main.c`（单 gomoku 线程）。

---

## 0. 核心结论（先看这五行）

1. **唯一阻塞点**是 `ai_choose_move()`，它已是 `const gomoku_t *` + 内部 `work = *g` 拷贝盘、**零全局态、可重入**（`scripts/gomoku/ai.c:327` 起）。所以 AI 天然可以拿到**副本盘**去另一个线程里跑，不用锁整块棋盘。
2. **拆分边界**：`game.c` 只负责「该不该派单」+「结果落子」，**不再自己调 `ai_choose_move`**；「怎么算一步棋」交给宿主（裸机宿主同步算、RT-Thread 宿主丢给 AI 线程）。
3. **同步原语**：两个邮箱 `rt_mb`（命令 `render→AI` + 结果 `AI→render`），**AI 只读副本盘、render 线程是唯一写真盘的人**，所以**不需要互斥锁**（`rt_mutex` 在 rtconfig.h 已开，但本设计用不到；要加锁反而拖累渲染）。
4. **不碰 RTL**：纯固件改动，`rtl/core/csr_file.v` 的 `DESIGN_REV` **不用改**；但 banner 里的 `FW=` 串建议加 `-G3` 后缀，让两版位流在串口上可分。
5. **别一次做完**：按下面的 Stage 1 → Stage 2 → Stage 3 分三步，每步都有独立验收，出问题分得清是谁。

---

## Stage 1 —— 前置基线（先做，别跳过）

目的：确认「单线程 RT-Thread 版」在板上真的能跑，记下改动前的体积与串口基线。这一步是 `app/main.c` 文件头里明说的前提——「单线程版上板验完，再拆线程」。

1. **体积基线**（本机有 riscv gcc 的话）：
   ```
   scripts\rtthread\build.ps1
   ```
   记下打印的 `.text/.data/.bss`、`堆可用`。当前口径约 **静态 44,021 B / 61,440 B，堆余 14,352 B**。
2. **上板基线**：
   ```
   scripts\build_bitstream.ps1 rtthread
   ```
   烧板（SW3 复位，别按 SW2/D22）。串口应见：RT-Thread banner → `[build] FW=RTTHREAD-GOMOKU RTL=0x...` → `heap=...` → `[boot] gomoku thread running` → 五子棋输出 → `[hb] alive, uptime N ticks`（每 5s 一条，`rt_tick` 在涨）。
3. **记下 `build_bitstream.ps1` 的守卫值**（`scripts/build_bitstream.ps1:130`）：`rtthread = 19124`（行）/ `9562 字`。T1 之后这个数会变，Stage 3 要**实测后更新，别放宽**。

> Stage 1 判据：串口有 banner + `[hb]` 交替出现、`rt_tick` 单调递增、复位后能稳定 ≥10 分钟。过了才进 Stage 2。

---

## Stage 2 —— 拆线程（改动点）

### 2.1 `scripts/gomoku/game.h` —— 给 `game_t` 加「派单中」状态

在 `typedef struct { ... } game_t;` 里加两个字段（放在现有 AI 统计字段旁）：

```c
    /* G3 异步 AI：派单时的棋盘副本 + 是否在等结果 */
    gomoku_t  ai_snap;      /* AI 只搜这个副本，绝不动真盘 board */
    int       ai_pending;   /* 1 = 已派单、等 AI 结果；0 = 空闲 */
```

新增三个函数声明（**替换**掉对 `run_ai_move` 的任何外部依赖——它本来就是 `static`，不导出）：

```c
/* 幂等派单：轮到 AI 且当前无在途任务时，把真盘拷进 ai_snap、置 ai_pending=1，
 * 返回 1；否则返回 0。宿主每帧都调它一次，只在 0→1 那一帧动手。 */
int game_ai_begin(game_t *gm);

/* 应用 AI 结果：落子 + 判胜负/切阶段 + 清 ai_pending。now 用于演示模式推进下一手节拍。 */
int game_ai_finish(game_t *gm, uint32_t now, int r, int c, const ai_stats_t *st);

/* 取派单时快照的只读指针，宿主拿去喂 ai_choose_move。 */
const gomoku_t *game_ai_snapshot(const game_t *gm);
```

### 2.2 `scripts/gomoku/game.c` —— 拆掉同步 `run_ai_move`

1. **删掉** `static int run_ai_move(game_t *gm)`（原在 `game.c:45`），换成：

```c
int game_ai_begin(game_t *gm)
{
    if (!game_ai_turn(gm)) return 0;      /* 没轮到 AI */
    if (gm->ai_pending)    return 0;      /* 已有在途任务，别重复派 */
    gm->ai_snap    = gm->board;           /* 拷盘 —— 之后 AI 只读 ai_snap */
    gm->ai_pending = 1;
    return 1;
}

int game_ai_finish(game_t *gm, uint32_t now, int r, int c, const ai_stats_t *st)
{
    int ret = gomoku_place(&gm->board, r, c);
    if (ret != GOMOKU_OK) { gm->ai_pending = 0; return ret; }  /* 非法点=内部错，放行 */

    gm->ai_nodes = st->nodes;
    gm->ai_depth = (int)st->depth;
    gm->ai_moves++;
    gm->last_ai_r = r;
    gm->last_ai_c = c;
    if (gm->board.winner) gm->winner = gm->board.winner;

    after_move(gm);                          /* 判胜负 / 平局 / 切阶段 */

    if (gm->demo) gm->t_next_ai = now + gm->demo_delay;   /* 演示：下一手在落子后隔 demo_delay */
    gm->ai_pending = 0;
    return GOMOKU_OK;
}

const gomoku_t *game_ai_snapshot(const game_t *gm) { return &gm->ai_snap; }
```

2. **三处同步调用点**改成 `game_ai_begin(gm)`（只派单，不落子）：

| 位置 | 原文 | 改为 |
|---|---|---|
| `tick_title`（`game.c:135`，人执白 AI 先手） | `if (gm->board.turn != gm->human) run_ai_move(gm);` | `if (gm->board.turn != gm->human) game_ai_begin(gm);` |
| `tick_playing` 演示（`game.c:156-158`） | `run_ai_move(gm); after_move(gm); gm->t_next_ai = now + gm->demo_delay;` | `game_ai_begin(gm);`（**不再**在这里 `after_move` / 推进 `t_next_ai`，改到 finish 里） |
| `tick_playing` 人机（`game.c:186-187`） | `if (...game_ai_turn(gm)) { run_ai_move(gm); after_move(gm); }` | `game_ai_begin(gm);` |

   > 注意 `tick_playing` 里人机那处本来在 `long_mask` 落子成功后立刻 `after_move(gm)` 一次（判人类这手是否赢），
   > 那一次 `after_move` **保留**，只把随后的 `run_ai_move+after_move` 换成 `game_ai_begin`。

3. **`game_tick` 里不要碰 `ai_pending`**——`ai_pending` 只由 `begin` 置 1、`finish` 清 0，状态机本身不感知「AI 还在算」。

### 2.3 `scripts/gomoku/main.c` —— 裸机宿主走同步路径（保持现状行为）

`gomoku_run()` 的主循环里，`game_tick(&g_game, ...)` 之后加一段**同步补算**，让裸机版行为与现在完全一致（AI 仍当场下完）：

```c
        game_tick(&g_game, now, smask, lmask);

        /* 裸机宿主：没有 AI 线程，当场同步算完（G3 只改 RT-Thread 宿主） */
        if (game_ai_begin(&g_game)) {
            ai_stats_t st;
            int r = -1, c = -1;
            uint32_t t0 = hw_mtime();
            ai_choose_move(game_ai_snapshot(&g_game), g_game.level, &r, &c, &st);
            g_game.ai_ms = hw_ticks_to_ms(hw_mtime() - t0);
            game_ai_finish(&g_game, hw_mtime(), r, c, &st);
        }
```

> 原来的 `moves_before/t0` 那套「只有这一拍真的走了 AI 才刷新 ai_ms」的判断，被上面这段取代——
> `game_ai_begin` 返回 1 就是「这一拍真派单」，天然只算一次。删掉 `moves_before` 相关几行。

### 2.4 `scripts/rtthread/app/main.c` —— RT-Thread 宿主拆两个线程

建议把线程胶水抽到新文件 `scripts/rtthread/app/gomoku_task.c`（`build.ps1` 会 `Get-ChildItem app -Filter *.c` 自动收编），`main.c` 只留启动 + 心跳。不抽也行，但 main.c 会变长。

**消息结构**（4 字节对齐，`rt_mb` 按 `size` 拷贝）：

```c
typedef struct { gomoku_t board; int level; }        ai_cmd_t;   /* ~236B，向上取整 240 */
typedef struct { int8_t r, c; int ret; ai_stats_t st; uint32_t ms; } ai_rsp_t;  /* ~24B */
static ai_cmd_t ai_cmd;      /* 命令缓冲（静态，进 .bss，不占堆） */
static ai_rsp_t ai_rsp;
static rt_uint8_t ai_cmd_pool[sizeof(ai_cmd_t)];
static rt_uint8_t ai_rsp_pool[sizeof(ai_rsp_t)];
static struct rt_mailbox mb_cmd, mb_rsp;
```

**AI 线程**（低优先级，栈 4KB）：

```c
static rt_uint8_t ai_stack[4096];
static struct rt_thread ai_thread;

static void ai_entry(void *p)
{
    for (;;) {
        ai_cmd_t c;
        ai_rsp_t r;
        if (rt_mb_recv(&mb_cmd, (rt_ubase_t*)&c, RT_WAITING_FOREVER) != RT_EOK) continue;
        r.r = r.c = -1;
        {
            uint32_t t0 = rt_tick_get();
            r.ret = ai_choose_move(&c.board, c.level, &r.r, &r.c, &r.st);
            r.ms  = (rt_tick_get() - t0) * 1000 / RT_TICK_PER_SECOND;  /* tick 差 → ms */
        }
        rt_mb_send(&mb_rsp, (rt_ubase_t)&r);
    }
}
```

**render 线程**（高优先级，栈 2KB）：主体就是现在 `gomoku_run()` 的循环，但把「算 AI」换成「派单 + 收结果」。关键节奏：

```c
for (;;) {
    video_wait_vblank();            /* 帧同步 + vblank 里写显存的前提 */
    now = hw_mtime();
    input_poll(...); 取 short/long 掩码;
    game_tick(&g_game, now, smask, lmask);

    if (game_ai_begin(&g_game)) {   /* 0→1 那一帧：派单 */
        ai_cmd.board = g_game.ai_snap;   /* 或直接 game_ai_snapshot(&g_game) 拷 */
        ai_cmd.level = g_game.level;
        rt_mb_send(&mb_cmd, (rt_ubase_t)&ai_cmd);
        uart_puts("AI thinking...\r\n");
    }
    if (rt_mb_recv(&mb_rsp, (rt_ubase_t*)&ai_rsp, RT_WAITING_NO) == RT_EOK) {
        g_game.ai_ms = ai_rsp.ms;
        game_ai_finish(&g_game, hw_mtime(), ai_rsp.r, ai_rsp.c, &ai_rsp.st);
        /* 串口打 "AI moved, nodes=... t=...ms" + 棋盘快照，逻辑照搬原 main.c */
    }
    draw_frame();
    /* 状态变化 / 棋子变化 / 光标变化 / 难度变化 的串口打印，照搬原 gomoku_run */
}
```

**优先级与栈**（`RT_THREAD_PRIORITY_MAX=32`，数字越小优先级越高）：

| 线程 | 优先级 | 栈 | 说明 |
|---|---|---|---|
| main（心跳） | 10（沿用） | 1024（rtconfig.h） | 不动 |
| render | **12** | **2048**（原来 gomoku 线程是 4096，现在 AI 递归不在它栈上，可以降） | 高优，保证 AI 算多久都不饿着它 |
| AI | **25** | **4096**（HARD 6 层递归实测 ~2KB + 余量） | 低优，render 每帧 vblank 都会抢占它 |

> render 优先级 **必须 > AI**（本设计 12 > 25）。这就是 G3 不卡的机制：AI 线程在纯算时，每到 vblank，
> render 线程（更高优先）抢到 CPU 去刷屏、采键、闪光标，AI 被 RTOS 抢占——不需要 G2 那种手动逐层切分。
> `app/main.c` 里原来那个「4KB 栈、优先级 20」的 gomoku 线程，拆成上表 render+AI 两条。

**初始化**（在 `main()` 里，`rt_thread_init` 前）：

```c
rt_mb_init(&mb_cmd, "aicmd", ai_cmd_pool, sizeof(ai_cmd_t), RT_IPC_FLAG_FIFO);
rt_mb_init(&mb_rsp, "airsp", ai_rsp_pool, sizeof(ai_rsp_t), RT_IPC_FLAG_FIFO);
/* render 线程 = 原 gomoku 线程改造；AI 线程新建。main 线程仍退到心跳。 */
```

### 2.5 `sim/tb_rtthread.v` —— 自检改成「双线程交替」

现在它匹配的是单线程版（`[boot] gomoku thread running`）。T1 后要新增/改判据：让 render 线程每帧打一行可预测的标记、AI 线程开工/完工各打一行，测试台断言**这两类标记交替出现且顺序稳定**（等价于「双线程信号量交替」）。`scripts/rtthread/run_sim.ps1` 头部那三条自检注释也一并更新（现在写的是旧 ping/pong 口径）。

> 注意：仿真必须走 `-Sim` 口径（`build.ps1 -Sim`：100MHz + `GOMOKU_AI_LEVEL=AI_EASY` + 短延时），否则 4 层 AI 在 iverilog 里跑不完——`build.ps1` 已有这段，别丢。

---

## 3. 体积与栈预算（改完必查）

`scripts\rtthread\build.ps1` 每编一次都会打印占用，超了直接报错停下。T1 的增量估算：

| 项 | 增量 |
|---|---|
| AI 线程栈 | +4096 B |
| render 线程栈 | 4096 → 2048，**−2048 B** |
| 邮箱控制块 ×2 + 消息池（240+24） | ~ +320 B |
| `game_t` 新增 `ai_snap`（232B）+ `ai_pending` | +236 B |
| 拆线程胶水代码（main.c/gomoku_task.c） | 几百 B |
| **净增** | **约 +2.6 KB** |

- 静态：44,021 → **约 46,600 / 61,440 B**，仍有余量。
- 堆余：14,352 → **约 11,700 B**，仍正。
- 若超了：**先裁 `rtconfig.h`**（栈按上表已经是下限了，别动 `link.ld` 的 0xF000/0xFFF0）。

> 栈和堆互相挤：`link.ld` 里堆在 `_end..0xF000`，栈在 `0xF000..0xFFF0`。上面所有线程栈都是**静态数组进 .bss**，不占堆——所以堆余只看静态占用，跟线程栈大小无直接关系；真正受挤压的是「静态总占用能否 < 0xF000」。

---

## Stage 3 —— 验收（过了才算 T1 完成）

1. **仿真**：`scripts\rtthread\run_sim.ps1` → 必须 `=== PASS ===`（tb_rtthread.v 新双线程自检过）。
2. **上板**：`scripts\build_bitstream.ps1 rtthread` → 烧板，串口同时满足：
   - banner + `[build] FW=RTTHREAD-GOMOKU-G3 RTL=0x...`（改过的 FW 串）；
   - **AI 思考期间光标照闪、按键有响应、画面不卡**（NORMAL 下肉眼可见；HARD 下最明显）；
   - 串口三类打印**交替出现、顺序稳定**：`[hb]`（心跳）/ render 的棋盘快照与 `cursor=`/ `AI thinking...` → `AI moved, nodes=... t=...ms`（AI 线程完工）；`rt_tick` 单调在涨；
   - **≥10 分钟稳定**（HARD 连续下几手，确认没有死锁/饿死——render 永远抢得过 AI）。
3. **体积守卫**：`build_bitstream.ps1` 会因为 `rtthread` 行数变化被拦——**实测后更新 `scripts/build_bitstream.ps1:130-131` 的 `expectLines['rtthread']` 与 `expectDesc`，别放宽守卫**。
4. **故意弄坏（必须 FAIL，别跳过）**：临时把 render 线程优先级改成 **低于** AI（例如 render=28、AI=12），重跑仿真/上板 → 应当看到 AI 思考期间光标不闪、串口 render 输出被 AI 憋住（证明「高优 render」是 G3 的关键，不是摆设）。然后**改回** render=12/AI=25。
5. **x86 单测不回归**：`game.c/game.h` 改了，`test_game.c` 若直接调过 `run_ai_move` 会编不过——按「begin → 同步 ai_choose_move → finish」的路径补上，保持「一份源码两处用」；`test_ai.c`/`test_board.c` 不受影响（它们只测 ai.c/board.c，没动）。

---

## 4. 铁律提醒（动手前读一遍）

1. **不碰 `rtl/core/`、`rtl/bus/`**——T1 纯固件，`DESIGN_REV` 不动。
2. **不 push main，push dualissue**（任务书 §7 纪律）。
3. **mtime 是 32 位、85MHz 下 ~50.5s 回绕**：所有「当前时刻 − 起点」的差值比较必须用无符号减法（`board.c` 的 `rt_hw_us_delay` 和 `game.c` 的 `now - t_next_ai` 已经是这么写的，别改坏）；演示模式 `t_next_ai = now + demo_delay` 这种「重写比较值」的写法是对的，别换成「读 mtime 再加」。
4. **显存写必须在 vblank 里**：拆线程后 render 线程的 `draw_frame()` 仍在 `video_wait_vblank()` 之后调，别把 `draw_frame` 挪到 AI 线程或 vblank 之外。
5. **别裸读共享全局**：AI 线程只碰 `ai_cmd`（邮箱拷进去的副本），不碰 `g_game`；`g_game` 是 render 线程私有。任何跨线程传值走邮箱。
6. **改了固件，`build_bitstream.ps1` 的行数守卫会拦你**——守卫在工作，实测后更新 `expectLines`，别放宽。
7. **变短/换行的串口/HUD 字符串整行重写**（`render_text` 先铺空格再覆盖）——T1 若改了 HUD 文字（比如加「AI 思考中」），注意这个坑。

---

## 5. 建议实施顺序

```
Stage 1（基线） → 2.1+2.2+2.3（game 异步化 + 裸机同步路径，先让裸机版不变、x86 单测过）
→ 2.4（RT-Thread 两线程 + 邮箱）→ 2.5（tb_rtthread 自检）→ Stage 3（仿真 + 上板 + 守卫更新）
```
每步一个可回退的 commit，别把 game.c 的异步化和 RT-Thread 线程胶水揉进一个改动里。
