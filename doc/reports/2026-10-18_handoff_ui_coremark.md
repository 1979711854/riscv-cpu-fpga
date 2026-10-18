# 标题屏优化 + CoreMark 分数上 HDMI —— 任务交接书（2026-10-18）

> 发给：甲（RT-Thread + 五子棋）
> 目标：**对局中已经好看，这次只补标题屏；同时让 CoreMark 的分数出现在 HDMI 上，而不是只能看另一台电脑的串口。**
> 前提：**不碰 `rtl/**`、不跑 PDS**。最终位流由集成方用 `combined -Iter 3900`、seed 29 重出。

---

## 0. 当前状态（先对齐，避免做重复工作）

| 项 | 现状 |
|---|---|
| 单一位流 | 已落地：boot selector（`scripts/boot/boot.S`）在 `0x0`，按住 **SW6**（key[2]）→ CoreMark `0x1000`；松开 → RT-Thread `0x10000` |
| 交付档 | rev1028 `b45941d6`：76.5052 MHz、CoreMark **352.5 / 4.6075**、LUT 7,740、Fmax 78.3269 |
| 候选档 | rev1029 `273f6c5a`：LUT 6,932、Fmax 78.6596、板上已过；等四项板级收尾后合并 |
| 对局界面 | 已上板，用户认可；**本次不改对局布局**（除非上一份 UI 任务书的 8×8/480×480 重做已经在做） |
| 标题屏 | 纯文字 + 大片留白，用户反馈"略显单调" |
| CoreMark | 分数只在另一台电脑的串口终端可见；HDMI 上没有 |

> 与 `2026-10-17_handoff_gomoku_ui.md` 的关系：
> 那份是**整套界面重做**（8×8 字库 / 480×480 棋盘 / 右侧 HUD）。
> 本文只做**标题屏专项**和 **CoreMark HDMI 显示**。如果队友已经在做整套重做，
> 本文的标题屏方案直接叠在上面；如果没做，本文的方案也能用当前 5×7 字库先落地。

---

## 1. 两项任务与分支边界

| 任务 | 分支 | 目录 | 谁出最终位流 |
|---|---|---|---|
| **A. 标题屏优化** | `dualissue`（应用线） | `scripts/gomoku/**` | 集成方 |
| **B. CoreMark HDMI 显示** | 从 `feat/mem128k` 拉 `feat/coremark-display` | `scripts/coremark_port/**`、可选 `scripts/gomoku/**` | 集成方 |

**两条硬纪律**：

1. **不要跑 PDS、不要改 `rtl/**`、不要动 `pds/RV32I_1/*.pds`**。最终位流由集成方统一出。
2. **任何 `mem.hex` 变化都会改变位流 md5**，但布局/时序应当不变（RAM 内容不影响网表）。
   集成方会在 `feat/lut` 上重出，并读一次 `.rtr` 确认；你只需要交源码 + 上板日志。

---

## 2. 任务 A：标题屏优化

### 2.1 目标效果

现在的问题不是字不好，而是**没有视觉锚点、没有和五子棋发生关系、没有层次**。
目标是让标题屏在录像里"一眼像个完整游戏"，而不是一张文字菜单。

推荐目标：

```
+----------------------------------------+
|  . . . . . . . . . . . . . . . . . .   |  深色 UI 底 + 淡纹理
|                                        |
|         G O M O K U                    |  4x 大 logo，O = 黑白子
|         RISC-V + RT-THREAD             |
|                                        |
|   ▶ ● HUMAN VS AI    +------------+    |
|     ○ AI VS AI       | . . . . . .|    |  7x7 自动对弈（可选）
|                      | . . O . . .|    |
|   PLAY AGAINST       | . . X . . .|    |
|   THE COMPUTER       | . . . O . .|    |
|                      | . . . X . .|    |
|                      +------------+    |
|                                        |
|   UP/DOWN MOVE   HOLD OK               |
|        PRESS ANY KEY                   |  闪烁
|   RV32IMA · RT-THREAD · 76.5 MHz       |
+----------------------------------------+
```

### 2.2 P0：必须做（约 1.5~2 小时）

1. **统一 UI 底色**
   - 现在字库图块的背景是不透明的（`FONT_BG = 0`，棋盘木色）。
   - 把 `FONT_BG` 改成深色 UI 底（深棕或墨绿），并让标题屏、HUD 面板都用这个颜色。
   - 棋盘保持木色。形成"深色 UI + 木色棋盘"的两色体系，层次立刻出来。
   - [!] 这会同时影响对局 HUD 的文字背景。上板确认 HUD 仍然好看；如果不想动对局，至少让标题屏和 HUD 用同一个底色，不要出现两种文字底色。

2. **大标题 logo**
   - 把字模放大 4×（32×32），每个字母占 **2×2 tile**；"GOMOKU" 6 个字母 = **24 块**。
   - 两个 `O` 换成黑/白棋子图标（复用 `RENDER_TILE_ICON_*` 或放大版棋子）。
   - 加深色投影（整体偏移 1 tile 再画一遍）或金色底条，做出"logo 感"。
   - 预算：24~48 块，当前空闲约 102 块。

3. **菜单选中态**
   - **不要做整行金色底条** —— 字库背景不透明，会把底条盖住。
   - 用 **金色方框/下划线 + 左侧棋子图标**：`▶ ● HUMAN VS AI`。
   - 选中项用装饰 tile 围一圈，未选中项保持普通色。

4. **选中项说明行**
   - 菜单下面一行短描述，填掉空白：
     - `PLAY AGAINST THE CPU`
     - `WATCH TWO AIS PLAY`
   - 10~20 个字符，8×8 字模正好；5×7 字模也能放。

5. **闪烁的 `PRESS ANY KEY`**
   - 底部一行，500 ms 切换显示/空白。成本几乎为零，但屏幕"活"了。

6. **底部信息行**
   - `RV32IMA · RT-THREAD · 76.5 MHz`，可再加队伍/赛事名。
   - 既填空白，又让评委一眼看到平台。

### 2.3 P1：可选加分（约 2~3 小时）

**右侧自动对弈小棋盘（attract mode）**

- 右侧放 **7×7 或 9×9** 小棋盘，脚本化自动落子（每 700 ms 一手），不需要调 AI。
- 直接复用现有 32×32 或 16×16 棋盘图块，不新增美术。
- 菜单放左侧，标题放上方，右下角写 `AI VS AI DEMO`。
- 实现要点：
  - 新增 `render_board_region(g, r0, c0, rows, cols, screen_row, screen_col)`，只画子区域；
  - 用一个独立的 `gomoku_t demo` + 硬编码走法表，在 `tick_title` 里按时间推进；
  - 不占用 AI 线程，菜单操作不受影响。

### 2.4 图块与内存预算

| 项 | 值 |
|---|---|
| 图块显存 | 256 块（16×16，每块 256B） |
| 当前占用 | 棋盘 0..35、字库 36..130、装饰 131..153 = **154** |
| 空闲 | **102** |
| 大 logo | 24~48 块 |
| 背景纹理/选中框/提示 | 10~20 块 |
| 自动对弈棋盘 | **0 块**（复用现有棋盘图块） |

**硬约束**：

- 总数 ≤ **256**；做完在报告里给一张「编号 → 用途」表。
- 新美术**运行时合成**，不要写进 `.rodata`；否则 RT-Thread 镜像会涨，装不进 64KB 区。
- 固件大小相对当前增加 ≤ **4KB**；`[boot] heap ≥ 8KB`。

### 2.5 标题屏最容易踩的坑

1. **字库背景不透明**：深色背景 + 木色字底 = 一个个小方块。统一 `FONT_BG`。
2. **不要做整行底条**：会被字的背景盖住；用方框/下划线。
3. **不要渐变/半透明/精灵/滚动**：tile PPU 做不到；滚动会带着文字一起动。
4. **不要中文字库**：8×8 只能 ASCII，中文要 16×16，吃图块预算。
5. **不要忘了切回对局时清标题屏**：现有 `render_clear()`/`draw_hud()` 已有清理逻辑，改标题屏后要确认不会残留。
6. **自动对弈不要用 AI 线程**：标题屏用脚本走法，避免和菜单/渲染抢线程。

### 2.6 验收（任务 A）

| 项 | 判据 |
|---|---|
| x86 单测 | `scripts\gomoku\run_test.ps1` 228 PASS / 0 FAIL |
| 端到端仿真 | `scripts\gomoku\run_sim.ps1` PASS |
| RT-Thread 仿真 | `scripts\rtthread\run_sim.ps1` PASS，`[hb]` 无断 |
| 板上 | HDMI 标题屏有 logo/配色/层次，菜单居中，`PRESS ANY KEY` 闪烁 |
| 对局不受影响 | 从标题进对局、下完一局、回标题，无残字、无闪烁 |
| 图块数 | ≤ 256，报告编号表 |
| 固件 | 增加 ≤ 4KB，`[boot] heap ≥ 8KB` |
| 证据 | before/after 屏幕照片 + 串口日志，放 `doc/board/` |

---

## 3. 任务 B：CoreMark 分数上 HDMI

### 3.1 目标效果

CoreMark 跑分时，HDMI 上像终端一样滚动输出；结束后停在结果页：

```
+----------------------------------------+
| COREMARK 1.0                           |
| RV32IMA @ 76.5 MHz                     |
| ITER = 3900                            |
|                                        |
| Total ticks : 846440591                |
| Total time  : 11.063 s                 |
| CoreMark/MHz: 4.607                    |
| Score       : 352.5                    |
|                                        |
| seedcrc  : 0xe9f5                      |
| crclist  : 0xe714                      |
| crcmatrix: 0x1fd7                      |
| crcstate : 0x8e3a                      |
| CRC OK                                 |
|                                        |
| SW6 UP + RESET -> GOMOKU               |
+----------------------------------------+
```

> 数字以板上实际为准；上面是 rev1028/rev1029 当前口径（ITER=3900、846,440,591 ticks）。

### 3.2 为什么不会影响跑分（先看这条）

- CoreMark 的计时区间是 `start_time()` 到 `stop_time()`，**中间不打印**；
- 屏幕初始化在 `start_time()` **之前**，结果打印在 `stop_time()` **之后**；
- 视频 BRAM 和 CPU 统一存储器是**两块独立 BRAM**，PPU 扫描显存不抢 CPU 取指/访存；
- 所以 `Total ticks` 应当**逐位不变**。上板必须对比一次：
  - 不开屏幕：`846,440,591`（ITER=3900）
  - 开屏幕：应完全相同；如果变了，说明计时区间里有 CPU 写显存，必须挪出去。

### 3.3 推荐实现：极简 HDMI 文本控制台

新增 `scripts/coremark_port/video_text.c/.h`：

1. **初始化**（在 `start_time()` 之前调用）：
   - 写调色板（复用 `scripts/gomoku/tiles.h` 的 `TILE_PALETTE`，或定义一个最小的 7 色表）；
   - 把字库放大成 16×16 图块，写到 tile `FONT_TILE_BASE..FONT_TILE_BASE+94`（复用 `scripts/gomoku/font.h`）；
   - 用空格字模清 40×30 的 nametable；
   - 写 `scroll_x/scroll_y = 0`。
2. **字符输出**：`video_putc(char c)`：
   - 处理 `\n` 换行、`\r` 忽略、到 40 列自动换行、到 30 行滚动；
   - nametable 字节地址 = `row * 256 + col`。
3. **镜像 `ee_printf`**：
   - 在 `scripts/coremark_port/ee_printf.c` 输出 UART 字符的地方，同时调用 `video_putc(c)`；
   - 这样 banner、Total ticks、四个 CRC、分数会原样出现在 HDMI 上。
4. **保护计时区间**：
   - 加一个 `video_mirror_enable` 标志：`start_time()` 前置 1，`start_time()` 后置 0，`stop_time()` 后再置 1；
   - 即使以后有人在计时区间里打印，也不会写显存。

### 3.4 地址与常量

| 项 | 值 |
|---|---|
| nametable | `0x8001_0000`，字节地址 `r*256+c` |
| pattern | `0x8002_0000`，tile `T*256 + py*16 + px` |
| palette | `0x8003_0000`，每项 4 字节（B,G,R,0） |
| scroll | `0x8003_0400` / `0x8003_0404` |
| 字库 | `scripts/gomoku/font.h`，95 字，tile 基址 36 |
| 调色板 | `scripts/gomoku/tiles.h` 的 `TILE_PALETTE` |

> [!] 如果队友正在把字库改成 8×8，CoreMark 直接 include 同一个 `font.h`，不要复制一份旧字库。
> `FONT_BG` 必须和标题屏/HUD 的 UI 底色一致，否则 CoreMark 屏和五子棋屏会是两种风格。

### 3.5 结果页与共享邮箱（推荐）

CoreMark 结束后：

1. 把结果写进一个 **16 字节共享邮箱**，建议 `0x0000_FF00`：
   ```
   0xFF00  magic 0x434D ("CM")
   0xFF04  ITER
   0xFF08  Total ticks
   0xFF0C  score_x100（定点，如 35250 = 352.50）
   0xFF10  seedcrc
   0xFF14  crclist
   0xFF18  crcmatrix
   0xFF1C  crcstate
   ```
2. 屏幕显示 `SW6 UP + RESET -> GOMOKU`。
3. 用户松开 SW6、按复位 → boot selector 跳 RT-Thread → 五子棋标题屏读 `0xFF00`，显示：
   ```
   LAST COREMARK
   SCORE 352.5
   CRC OK
   ```
4. 因为 BRAM 不随复位清空，这个分数会**跨复位保留**；RT-Thread 的 `.bss` 从 `0x10000` 开始，不会覆盖 `0xFF00`。

> [!] 地址安全：`0xFF00` 在 CoreMark 栈顶 `0xF000` 之上、兼容区 `0xFFF0` 之下；
> boot selector 不使用栈和 RAM。**不要**把邮箱放到 `0x0~0xFFF`（selector）或 `0xF000` 以下（CoreMark 栈）。

**软跳转是可选项，不推荐**：CoreMark 结束后直接 `jr 0x10000` 涉及 `gp/sp/trap` 状态，
比"显示结果 → 复位"风险高。演示视频用复位完全够。

### 3.6 计时与显示实现注意

1. **score 计算要用 64 位**：
   `score_x100 = ITER * EE_TICKS_PER_SEC * 100 / ticks`，
   ITER=3900、EE_TICKS_PER_SEC=76,505,200，乘积超过 32 位。
   用 `unsigned long long`；构建默认链 libgcc，`__udivdi3` 可用。
2. **不要依赖 CoreMark 的 `Total time (secs)` 打印**：它是整数截断（HAS_FLOAT=0），
   显示 11 或 0。用 ticks 自己算 `secs_x1000 = ticks * 1000 / EE_TICKS_PER_SEC`。
3. **CRC 只显示四个**：`seedcrc/crclist/crcmatrix/crcstate`；
   `crcfinal` 是跨迭代累加器，不能比。
4. **UART 必须保留**：串口日志是回归和排查的证据，不能因为上屏就关掉。
5. **长行滚动**：CoreMark 的编译器 flags 那行约 100 字符，控制台要能自动换行 + 滚动。
6. **视频初始化时间**：95 块 ×256B ≈ 24KB 写显存，在 76.5MHz 下约 0.3ms，放在 `start_time()` 之前，不进计时。
7. **vblank**：CoreMark 的初始化/结果页是**一次性整屏写**，不需要等 vblank；
   现有串口里反复出现的 `[!] vblank timeout` 是既有问题，**不要在这个任务里追**。

### 3.7 分支与构建

1. 从 `feat/mem128k` 拉 `feat/coremark-display`，只改 `scripts/coremark_port/**`；
2. 编译命令沿用 `scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem`（先做小 ITER 验证）；
3. 验证四 CRC、`217,088` 拍/迭代（仿真）不变；
4. 上板用 `-Iter 3900` 的固件，对比 `846,440,591` ticks；
5. **不要自己跑 PDS**；把源码 + 日志交给集成方，由集成方在 `feat/lut` 上重出 `combined` 位流（seed 29）。
6. `mem.hex` 变了，位流 md5 必变；集成方重出一颗新流，旧 `273f6c5a` 仍归档。

### 3.8 验收（任务 B）

| 项 | 判据 |
|---|---|
| HDMI | 跑分时能看到 CoreMark 输出滚动；结束后停在结果页 |
| 跑分不变 | `Total ticks` 与不开屏幕时逐位相同（ITER=3900 → 846,440,591） |
| CRC | 四个 CRC 与串口一致；显示 `CRC OK` |
| 分数 | HDMI 上的 Score 与串口/`Total ticks ÷ 时间` 计算一致 |
| 共享邮箱（若做） | 复位后五子棋标题屏显示 `LAST COREMARK 352.5 / CRC OK` |
| 回归 | `run_coremark.ps1 -Iter 1` 四 CRC + 217,088 不变；`run_own_tests.ps1` 8/0 |
| 同一颗位流 | 复位+SW6 → CoreMark；松开+复位 → 五子棋；不需要重新烧录 |
| 证据 | HDMI 照片 + 串口日志，放 `doc/board/` |

---

## 4. 共用约束与禁止事项

| 禁止 | 原因 |
|---|---|
| 改 `rtl/**` / 跑 PDS / 动 `.pds` | 交付线 RTL 与归档位流一一对应；改了会破坏可复现性 |
| 改 `DESIGN_REV` | 实测每 +1 可能吃掉 0.35ns，把 +0.358 打到 +0.005 |
| 把新美术写进 `.rodata` | RT-Thread 镜像会涨，装不进 64KB 区 |
| 在 CoreMark 计时区间里写显存/UART | 会改变 `Total ticks`，跑分作废 |
| 用 libc / 浮点 / malloc | CoreMark 固件是 freestanding；五子棋侧同样不用 |
| 追 `[!] vblank timeout` | 既有问题，对局/跑分都还能跑；本次不修 |
| 并发跑 PDS | 会抢同一工程目录，综合结果不可信 |

---

## 5. 时间与顺序

| 顺序 | 内容 | 估时 |
|---|---|---|
| 1 | A-① 统一 UI 底色 + 大 logo | 1.5 h |
| 2 | A-② 菜单选中框 + 说明行 + 闪烁提示 + 底部信息 | 1 h |
| 3 | B-① `video_text` + `ee_printf` 镜像 + 结果页 | 2 h |
| 4 | B-② 跑分不变验证（ITER=1 → ITER=3900） | 0.5 h |
| 5 | A-③ 自动对弈小棋盘（可选） | 2~3 h |
| 6 | B-③ 共享邮箱 + 标题屏显示（可选，推荐） | 0.5 h |
| 7 | 上板迭代 + 照片/日志 | 1 h |

总计 **5~7 小时 + 上板迭代**。建议 A、B 可以并行做，但**上板验证分开做**：
A 只影响五子棋固件；B 只影响 CoreMark 固件；最终由集成方合成一颗位流。

---

## 6. 交付物

1. 分支 + 提交（A 在 `dualissue`，B 在 `feat/coremark-display`）；
2. 改动说明：改了哪些文件、为什么；
3. 回归日志：`run_test` / `run_sim` / `run_coremark -Iter 1` / `run_own_tests`；
4. 上板证据：HDMI 照片（标题屏 before/after、CoreMark 结果页）+ 串口日志；
5. 图块编号表（A）和固件大小/heap 数字（A/B）；
6. **不要**把 `.sbit`、`.pds`、`mem.hex` 的生成物提交进 git。

---

## 7. 一句话交接

**A：把标题屏做出"logo + 深色 UI + 选中态 + 节奏感"；B：把 CoreMark 的串口输出镜像到 HDMI，分数也在屏上，且 `Total ticks` 一位都不能变。**
两边都只碰固件，不碰 RTL；最终位流由集成方统一重出。
