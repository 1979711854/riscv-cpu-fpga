# scripts/gomoku —— 五子棋（轨道 C：规则 / 判定）

> 对应 `doc/reports/2026-10-01_gomoku_worklist.md` 的**轨道 C**。
> 当前进度：**C1 棋盘结构 + C2 五连判胜 + C3 平局判定 已完成**（2026-10-01）。

## 怎么跑（**不需要板子、不需要 RISC-V 工具链、不需要 iverilog**）

```powershell
scripts\gomoku\run_test.ps1      # 跑单测（轨道 C 70 项 + 轨道 D 47 项 + RV32 交叉编译检查）
scripts\gomoku\play.ps1          # 跟 AI 下棋（-Easy / -Hard / -White 可选）
```

只要一个 x86 gcc。没装的话：`scoop install gcc`。

### 量 AI 的搜索成本：`measure_ai.c`

调 AI 之前先跑它 —— 它回答"哪个阶段最贵、HARD 比 NORMAL 贵多少"：

```bash
cd scripts/gomoku
gcc -O2 -I. board.c ai.c measure_ai.c -o measure_ai.exe && ./measure_ai.exe
```

做法是**用 NORMAL 自对弈走到若干采样点（2/6/10/…/40 子），然后在同一个局面上分别跑三档** ——
同局面三档对比，排除"各下各的、局面越走越不一样"的干扰。输出 `nodes / depth / 板上约几秒`。

> [!] **板上秒数 = 节点数 × 0.6 ms**，这个系数是 2026-10-04 板上实测的
> （HARD 开局 24,246 节点 = 14,503 ms）。它随盘面变满而上升（0.52 → 0.88 ms/节点），
> 所以工具给出的"板上约几秒"是**偏乐观的下界**。
>
> **2026-10-04 用它得到的结论**（推翻了两个想当然的方案，别再提）：
> HARD 是**全程都慢**（2.8~11.9 秒），最贵的是**中盘**而不是开局 →
> 所以「加开局库」和「调小 `AI_NODE_BUDGET`」**两个方案都不成立**。
> 完整数据与原因见 `doc/reports/2026-10-04_work_split.md` §4。
>
> **2026-10-07（B3 收尾）**：HARD 慢的正确解法是**收窄搜索宽度**，不是上面那两个。
> `ai.c` 里 `AI_WIDTH_HARD=10`（EASY/NORMAL 仍 14），用「少看点宽」换「多看点深」。
> 8 宽实测和 NORMAL 打平（深 6 却每层少看 6 个候选，损失 > 多 2 层的收益），10~12 才是平衡点。
> 验收：HARD 自对弈仍赢 NORMAL —— `test_ai.c` 的 C 段机器校验（20 局、10 个不同开局）。
> 节点数只打印、不再卡 ≤4000（那和「深度 6 仍赢 NORMAL」本就冲突），给板上耗时标定用。

## [!] 输出中文乱码怎么办

**症状**：棋盘和中文提示显示成一堆 `���`。

**原因**：程序输出的是 **UTF-8** 字节，而中文 Windows 的控制台默认代码页是
**GBK(cp936)** —— 解码方式对不上。**不是程序的问题**（用 `od -c` 看输出，
字节确实是合法的 UTF-8）。

**三道保险（都已加好，正常情况下你什么都不用做）**：

| # | 位置 | 做什么 |
|---|---|---|
| 1 | `play.ps1` / `run_test.ps1` | `chcp 65001` —— 把控制台代码页切到 UTF-8 |
| 2 | 同上 | `[Console]::OutputEncoding = UTF8` —— 让 PowerShell 按 UTF-8 解码子进程输出 |
| 3 | `gomoku_cli.c`（`#ifdef _WIN32`）| `SetConsoleOutputCP(65001)` —— **直接双击 `.exe` 也管用** |

**如果还是乱码**：先确认你是**用脚本跑的**（`scripts\gomoku\play.ps1`），
而不是跑了一个旧的 `gomoku.exe`。改完源码要重新生成 `.exe` ——
`play.ps1` 每次都会重编，但如果 **`.exe` 正在运行，重编会失败**
（Windows 锁住可执行文件，报 `cannot open output file ... Permission denied`）。
**先把旧的关掉再跑脚本。**

## 为什么单独开一条 x86 路径

工作清单 §6：

> C 轨道的判胜是安全的，建议用 gcc 在 x86 上把核心函数先单测透
> （横/竖/两斜/贴边/满盘平局/反向连子），再上板。

判胜逻辑改一行就走 iverilog 全仿真太慢，没法迭代。这里是纯 C 逻辑，
x86 上毫秒级出结果。

## 「一份源码两处用」—— 这是硬要求，不是口号

`board.c` / `board.h` 刻意做成**平台无关的纯逻辑**：

| 约束 | 原因 |
|---|---|
| 只依赖 `<stdint.h>` | 固件侧是 freestanding，没有 libc |
| 不用 `memset`/`memcpy`/`printf`/`assert` | 同上；清零写成显式循环（N=15 编译器自己展开）|
| 无全局状态、无动态内存、无浮点 | 一份代码两边行为必须一致 |

**已验证**（2026-10-01）：

```
x86     : gcc -std=c99 -O2 -Wall -Wextra   -> 70 项检查全过
rv32im  : riscv-none-elf-gcc -march=rv32im -O2 -Wall -Wextra -ffreestanding
          -> 零警告；.text = 1,040 字节，.data/.bss = 0（无静态数据）
```

[!] **改完 `board.c` 要两边都编一遍** —— 只编 x86 不够，`int8_t`/`int` 混用这类
问题在 rv32 上才暴露（而且固件那边没有 printf 兜底）。

## API

```c
#include "board.h"

gomoku_t g;
gomoku_reset(&g);                       /* 清盘，黑先 */

int ret = gomoku_place(&g, r, c);       /* 用 g.turn 落子；失败不改状态 */
/* ret: GOMOKU_OK / ERR_RANGE / ERR_OCCUPIED / ERR_TURN / ERR_OVER */

int n = gomoku_run_len(&g, r, c, who);  /* 假想落子能连几个 —— 只读，给 AI 用 */
/* 返回 >= GOMOKU_WIN_LEN 即成五 */

g.winner;   /* 0=未分胜负，否则是胜方颜色 */
g.stones;   /* 已落子数，配合 gomoku_is_full() 判平局 */
```

**判胜是增量的**：只从刚落的那一格沿 4 个方向数，O(1)，不做全盘扫描。
全盘扫描版 `gomoku_scan_winner()` 只留给单测做对拍基准。

## 规则取舍（写死在这里，免得反复讨论）

- 15×15 交叉点，**五连即胜；长连（6 子及以上）同样算胜**（无禁手规则）
- **不实现禁手**（黑棋三三 / 四四 / 长连禁手）。工作清单没要求，且判定复杂、
  容易和"到底算不算胜"纠缠。真要加，在本层之上单开模块
- 胜负已分后 `gomoku_place` 返回 `GOMOKU_ERR_OVER`；重开用 `gomoku_reset`

## 单测覆盖（70 项）

| 组 | 内容 |
|---|---|
| A | reset 后初始状态 |
| B | 四个方向各一条五连（横/竖/两斜）|
| B2 | **反向连子**（决定性那手在左端）—— 专门抓"只往正方向数"的 bug |
| C | 贴边 / 贴角（含 (0,0) 与 (14,14)）|
| D | 反向用例：四连、被隔断、被夹住——**都不该判胜** |
| D2 | 长连算胜；胜负已分后拒绝落子 |
| E | 非法落子被拒**且状态不变**（越界/重复/轮次）|
| F | `gomoku_run_len` 是只读的、越界返回 0 |
| G | **满盘平局**（构造了四方向都无五连的填法，113:112）|
| H | **[最重要] 300 局随机对局 / 32,297 手，增量判胜 vs 全盘扫描逐步对拍** |

## 下一步（轨道 D：AI 对手）

`gomoku_run_len` 已经为 D1（启发式评分）铺好路了 —— 对每个空位假想落子、
取 `run_len` 就是最朴素的评分。D 开工时新建 `ai.c` / `ai.h`，
**不要动 `board.c` 的接口**（A/B/D 都依赖它）。
