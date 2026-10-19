# T7 交接：CoreMark 终端演示屏（2026-10-19，给下一个会话）

## 三十秒版

T7（CoreMark 终端演示屏彩蛋）**功能代码已全部落盘**：boot.S 三路径、A1 重放屏、
配色/字模扩展、长按退出、邮箱标志全部写完，boot.S 编译通过，RT-Thread 镜像
**61,263 / 61,424 字（99.7%，堆余 160B）**。

**唯一卡点** = `test_render` 两个 FAIL。本会话末尾已完成**代码级根因定位**（高置信）：

> `synth_glyph_set`（render.c:630）映射模式按 **ASCII 原值**索引 tiles 表，
> 而 `FONT8G_TILE` / `FONT_TERM_*_TILE` 的生成约定（gen_tiles.py:276/309/319）
> 是 **`ord(ch)-32`（0..94）索引** ⇒ 传表的三处调用点**错位 32 格**：
> 错位后多数字符写到错误 tile，落 `0xFF` 表项的字符把字形写进 **tile 255**；
> `&`(ASCII 38) 恰落 0xFF 项 → 真正的 tile 73 从未被写 → 缺 PAL_GOLD_DIM。
> **两个 FAIL 同源。**

修复方案（推荐 A，未动代码——用户叫停修改后先交接）见 §5。

> **（T7-R2 已修复：方案 A 已落地，§4 结论成立但漏了一处同源调用点。最新状态看 §0。）**

---

## 0. 更新：T7-R2 收尾（2026-10-19，已实跑验证）

### 0.1 实改

- `render.c`：新增 `synth_glyph_set_ord32()`（栈表 **127 项**，方案 A），三处错位调用点
  （FONT8G / TERM_GREEN16 / TERM_GOLD16）全部改走它。
- `render.c`：补 `synth_glyph_set` 非 wide8 分支的**垂直 2x 缩放**（原 `oy/fy` 没乘
  `FONT_SCALE` ⇒ 16x16 字形只有半高、整体偏下）；新增 `glyph_coord()` 修 C 整数除法
  向零截断导致的左上多一条像素（同时用于 GREEN16/GOLD16/WINS 三个合成循环）。
- `render.h/.c`：新增 `render_term_tile(set, ch)`（统一按 `ord(ch)-FONT_BASE` 查表，
  返回 0xFF）与 `RENDER_TILE_TERM_OK_O/K/PCT` 常量。
- `coremark_screen.c`（**§4 没抓到的同源第二处，x86 单测完全没覆盖**）：
  `term_span()` 原来按 ASCII 原值查终端表，`'O'/'C'/'3'/'.'` 等全部错位 32 格；
  `'[' / ']' / '%'` 三处直接下标同样错位（`[` 会取到 0xFF ⇒ 写 tile 255，
  预览里显示成木色块）。已全部改走 `render_term_tile()` / 常量。
  顺带修两个版式 bug（预览图直接看出来）：`[ PASS ]` 的 `]` 被
  `render_clear_span(row,9,..)` 擦掉（屏上是 `[ PASS`）；CRC 行 `OK` 后残留
  `WAIT` 的 `IT`（显示成 `OKIT`）。
- `test_render.c`：删掉 tile 255 字符画/写序列诊断（保留负向断言）；新增 **§G**
  19 条检查（4 条 `render_term_tile()` API + 15 条直接调 `render_term_begin/end`）：
  借图块号、绿/金/灰配色、10x14 几何、tile 255 不写、`render_term_end` 对图块与
  调色板逐字节还原。
- `run_test.ps1`：RV32 交叉编译清单补 `coremark_screen.c`（七个 → 八个文件）。
- `preview.ps1`：源清单补 `coremark_screen.c`（T7 之后预览脚本原本直接链接失败）。

### 0.2 验证结果（本会话实跑）

- `run_test.ps1`：board 70 / ai 63 / render **125** / input 39 / game 92，**全部 0 error**；
  RV32 八个文件编译通过、无警告。
- `preview.ps1 -Scene all`：五个场景全部出图；标题屏 `POWERED BY RISC-V & RT-THREAD`
  的 `&`/`-` 正确落到 73/74（修复前会写 tile 255）。
  演示屏另用宿主预览（真实 `coremark_screen.c` + 假显存 + 假邮箱）核对：
  `[ PASS ]`、金色 `352.50` / `4.6075`、`CRC VALIDATION : OK`、进度条 `[`/`]`/`%`
  全部正确；NO DATA 页版式正常。预览图在 `doc/board/preview_t7_*.bmp|png`。
  （`preview.ps1 -Check` 对 title 有 **T6-R4 遗留的 golden 差异**，与本修复无关，
  golden 未更新，别当回归失败。）
- 裸机 `gomoku/build.ps1`：静态 **36,688 B**，栈余 24,752 B。
- RT-Thread `build.ps1`（**板级 76.5MHz 口径，combined 实际使用的就是这份**）：
  T7-R5（当前版：监控区 + 绿字 + 异常诊断 + 金线/最后一手修复）后
  **59,980 / 61,424 B（97.6%，堆余 1,440B）**；text 50,668 / data 296 / bss 9,016。
  （T7-R3 中间版曾为 60,028 / 1,392，已作废。）**不要再回到 61,212/208B 那版**（上板黑屏，见 §0.2.1）。
- RT-Thread 仿真：按用户要求**不跑**（五子棋仿真成本高，直接上板）；编译通过。

### 0.2.1 上板首测：黑屏根因 = 堆 208B（已修）

首颗 combined（md5 `01159e98…`）上板现象：**HDMI 全黑，串口只有 RT-Thread banner 5 行**：

```
 \ | /
- RT -     Thread Operating System
 / | \     5.3.1 build Oct 19 2026 14:32:41
```

没有 `[build] FW=...`、没有 `[boot] ... thread running`、没有 `[hb]`。

**根因**：RT-Thread 自己的 main 线程由 `rt_application_init()` 里的
`rt_thread_create("main", ..., RT_MAIN_THREAD_STACK_SIZE=1024, ...)` 从**堆**分配
（1024B 栈 + 148B TCB + 分配头 ≈ 1.2KB），而当时堆只剩 **208B** ⇒ 创建失败。
banner 在创建 main 线程**之前**打印，所以串口看起来“正常启动了”，实际调度器起来后
只有 idle 线程在跑，`gomoku_run()` 从未执行 ⇒ 视频没初始化 ⇒ 黑屏。

**修法**：`scripts/rtthread/app/main.c` 里 render / AI 线程栈各 4KB → 3KB
（render_init 峰值约 1.7KB、AI 递归实测约 2KB，各留 1KB 余量），堆先回到 **2,248B**；
T7-R5 加监控区/绿字/异常诊断/渲染修复后为 **1,440B**（仍高于 main 线程所需 ~1.2KB）。
取舍：仍低于 128K 交接文档里“堆 ≥8KB”的建议值 —— 当前统一存储器里 text 已占
49.9KB，要 8KB 堆得再砍 6KB 代码（或扩 RAM），本次先保证能跑；app 除 main 线程外
不再 malloc。

**上板预期日志**（新版）：
`[build] FW=RTTHREAD-GOMOKU-G3 RTL=0x20261028` → `[boot] heap = 1440 bytes` →
`[boot] gomoku render thread running` → `[boot] gomoku ai thread running` → `[hb] alive`。

### 0.3 位流已生成（**当前版：T7-R5，2026-10-19 17:01:11，combined**）

- 文件：`pds/RV32I_1/generate_bitstream/cpu_top_board.sbit`
- 大小 **9,188,552 B（8.76 MB）**，md5 **`6E2D60209E7B2F61059CBA9C67BB2496`**
- 镜像：boot 60 行（30 字）+ coremark 22,728 行（11,364 字）+ rtthread 25,482 行
  （12,741 字）= **48,270 行 / 24,135 字**（`sha256` 同步校验通过）
- 配置：`DUAL_ISSUE=1` / `LANEB_MEM=1` / `gplace_seed 10`；PDS **All Constraints Met**，
  CPU 域 WNS **+0.304 ns**（0 / 21,135 端点），Estimated Fmax **78.3269 MHz**
  （请求 76.5052 MHz）；跨域 CPU→pix_clk 伪影 +6.484 ns（既有，忽略）
- 上一版（16:29，md5 `8549F819…`）在 `generate_bitstream/bak/` 里，**勿烧**。
- `expectLines` 已按实测更新（boot 60 / coremark 22,728 / rtthread 25,482 /
  combined 48,270 / gomoku 18,508）

### 0.3.2 T7-R4：标题崩溃根因已定位 = **CPU 双发射 bug**（软件绕行）

R3 上板日志（`doc/board/uart_20261019_161349.txt`）拿到决定性证据：

```
TRAP epc=00012488 mcause=00000004 mepc=00018818 mtval=0000010a
ra=0x18cb0  a0=12 a1=6 a2=11
```

- `mcause=4` = load address misaligned；`mepc=0x18818` = `draw_menu_row` 里
  `lw a5,264(s3)`（读 `gm->human`）；`mtval=0x10A` ⇒ **s3 = 2**（0x10A − 264）。
- `a0/a1/a2 = 12/6/11` 正好是 **`render_rule(row=12,col=6,len=11)`** 的参数。
- 反汇编：`draw_menu_row` 对 `render_rule` 做**尾调用**：
  `jr -112(t1)` 的下一条正是 `lw a5,264(s3)`（fall-through）。
- **根因**：JALR 在 BTB 未命中时 `p_pred_taken=0`，`pair_now` 遂把 `jr` 的下一条
  fall-through 配进 lane B；lane B 在 EX 真的执行，用恢复后的旧 s3=2 算出
  0x10A ⇒ misaligned load trap。lane B 的 `ex_mem_b_valid` 虽被 `ex_flush` 清掉，
  但 **trap 没有被 `ex_flush` 抑制**。
- 这是 **CPU 功能 bug**（JALR 后的顺序指令不在执行路径上，不该配对执行），
  不是 render 代码问题。正确修法 = `pair_now` 增加 `p_op_a != 7'b1100111`
  并递增 `DESIGN_REV`；**用户决定暂不动 RTL**。

**T7-R4 采用软件绕行**：`draw_menu_row` 里 `render_rule(...)` 之后加
`__asm__ volatile("nop")`，GCC 因此不能再做尾调用；反汇编确认变成
`jalr render_rule; nop; lw ra,...`，fall-through 是无害的 nop。
代价：+4B 代码（text 50,684，堆 1,424B）。**其他 JALR+load 组合仍有潜在风险**，
等 RTL 修复时一起清掉。

### 0.3.3 T7-R5：金线 / 最后一手两个渲染修复

1. **金线停在 COLOR**（`main.c::draw_menu_row`）：最后一项原来画在 `row-1`：
   HUMAN 的 START(row15) 线落 row14（正好是 COLOR 的线），AI 的 START(row17)
   线落 row16（STEP 的线）。改为一律 `row+1`（HUMAN 16 / AI 18；AI 页说明行
   已下移到 19，不冲突）。
2. **最后一手棋子右上角木色块**（`render.c`）：旧 `synth_last2()` 把整个右上
   象限填成 `PAL_BG` + 红三角，直接擦掉棋子的右上四分之一。改为在 `render_init`
   里用 `synth_cell32(shape=0, 黑/白)` 生成真实棋子、在右上角叠红三角，拆出
   右上象限存成两张专用图块：**249（黑）/ 252（白）**；`render_full2` 按棋子
   颜色选 tile。`test_render` 新增 §H（6 条检查）锁住“含棋子像素 + 含红三角”。
   限制：只做 shape=0（内部格），最后一手落在棋盘边缘时该象限可能多一条网格线；
   要完全覆盖边缘需 9×2 个 tile，当前没有空闲号段，先接受。
3. 新增单测后 `test_render` **131 checks** 全绿；裸机静态 38,020 B；RT-Thread
   **59,980 / 61,424 B（97.6%，堆 1,440B）**。
4. 预览：`doc/board/preview_t7_game.png` 可见最后一手黑子右上角红三角、棋子完整。

### 0.3.4 T7-R5 上板验证（2026-10-19 18:49 日志）

日志：`doc/board/uart_20261019_184426.txt`（R5，build 16:49:39）。

- **无 TRAP**；标题/菜单/对子菜单/对局都正常，用户确认标题屏与棋子显示已正确。
- AI vs AI `NORMAL vs NORMAL` 完整一局约 **195 秒**，每手 depth=4、0.3~1.9 s，
  `[hb]` 每 5 s 不断，**堆恒定 1440B**，无卡死/无异常 —— RT-Thread 稳定性过关。
- 再次跑官方 CoreMark：`Total ticks 846440591`、四个 CRC 全对、354 iter/s。
- 多次复位（含 CoreMark 后、演示屏后）都正常回到 RT-Thread 标题页；
  **上次“只有背景色”未复现**，暂按一次性视频域复位/按键时序问题记录。
- `[!] vblank timeout -- video not running` 仍**每次 boot 都打印**，但画面正常
  ⇒ 该 STATUS 位不可信（误报），不要据此判断视频没跑；除非出现撕裂再查。
- 演示屏路径也成功进入（`[boot] coremark demo screen (SW6+SW7)`），随后复位正常。

### 0.3.1 T7-R3 本次改了什么

1. **异常诊断**（`third_party/rt-thread/.../trap_common.c`）：`rt_show_stack_frame()`
   补 `TRAP epc/mcause/mepc/mtval` 一行；**只打一次**后 `for(;;)` 自旋，
   不再无限 `mret` 回出错指令把串口灌成乱码。
2. **标题页崩溃仍未修**：15:33 版日志的 `ra=0x18ca4` 反查到
   `title_draw_all` → `draw_menu_row` → **`render_rule(row=12,col=6,len=11)`**；
   `-fstack-usage` 实测 render 路径最深约 500B、`render_init` 1,712B，3KB 栈够。
   具体异常类型要等 R3 上板打出 `mcause/mepc/mtval` 才能定。
3. **CoreMark 演示屏 UI 精修**（`coremark_screen.c`）：
   - 全部改绝对 X：信息块标签 @4 / 冒号 @18 / 值 @21；监控区标签 @4 / 冒号 @14 / 值 @16；
   - 标题右侧 `RT-THREAD`、状态行右侧 `THREADS: 4`；
   - 进度条 `[` @2、29 格、`]` @32、百分比右对齐到 38 + `%` @39；
   - 新增监控区（19..22）：`UI TICK`（`rt_tick_get()`）、`UPTIME`
     （`rt_tick_get()/RT_TICK_PER_SECOND`）、`HEAP FREE`（`rt_memory_info()` 实时）；
     **删除了写死的 `CPU USAGE : 99%`**；
   - 监控值用新增 **8x8 亮绿子集**（15 字，借 2x2 棋盘图块 188..202，
     `render_term_end -> render_init` 逐字节还原），不是假数据；
   - Score/MHZ 移到 24/25、CRC 26、HOLD 27、footer 28；
   - 每 100ms 只局部刷新监控值列。
4. **RT-Thread 构建去掉串口整盘镜像**（`main.c` 的 `uart_dump_board` 用
   `#ifndef __RTTHREAD__` 包起来）：省约 500B，也避免 15x15 棋盘频繁打印拖慢 UI。
5. `test_render §G` 的逐字节还原判据通过（绿字借的 188..202 由 `render_init` 重建）。

**上板预期日志（R5）**：`[boot] heap = 1440 bytes` → 两条 thread running →
标题页/最后一手/金线正常；若仍有异常，会打出且只打一行
`TRAP epc=... mcause=... mepc=... mtval=...`，然后停住（不再刷屏）。

### 0.4 仍未做（上板）

1. **烧 R5（17:01，md5 `6E2D6020…`）验证标题页 + 两个渲染修复**：正常 SW3
   复位应完整显示标题/菜单/小棋盘/LAST COREMARK/提示行，不再出 `TRAP`；
   HUMAN/AI 子菜单光标移到 START 时金线应在 START 下方；对局最后一手棋子
   右上角应完整、只多一个红三角。
2. **验证演示屏 UI**：SW6+SW7 进入，核对监控区 `UI TICK / UPTIME / HEAP FREE`
   三个真实值（`HEAP FREE` 会显示约 `0.2K`，这是 256KB 统一存储器里 text 占 50KB
   后的真实余量，不是 bug）；再看 Score 24/25、CRC 26、HOLD 27 的位置。
3. 演示屏读 0xFF00 邮箱 ⇒ **先跑一次官方 SW6 跑分档**，否则只能看到 NO DATA 页。
4. **RTL 正确修复（待排期）**：`pair_now` 排除 JALR（`p_op_a != 7'b1100111`），
   递增 `DESIGN_REV`，按风险清单跑四条基线 + CoreMark 四 CRC + RT-Thread 回归。
   当前 nop 绕行只保护 `render_rule` 这一个点。
5. 文档四处同步：boot.S 字数、镜像口径 **59,980/61,424（板级，堆 1,440B）**、
   `CLAUDE.md`、论文框架 §0/§0.1。
6. 提交（按里程碑拆；不自动 push）。

---

## 1. 冻结决策（用户多轮问答确认，不可再讨论）

| 决策 | 内容 |
|---|---|
| **Q0 boot 三路径** | SW6 按住+SW7 松开 → `0x1000` 官方裸机 CoreMark（**口径不变**）；SW6+SW7 都按住 → 写标志 `0xFF80` → `0x10000` RT-Thread（读标志进演示屏）；SW6 松开 → `0x10000` 默认五子棋 |
| **A1 方案（重放+真实成绩）** | RT-Thread 镜像塞不下真跑 CoreMark（体积探测证实）。演示屏从 `0xFF00` 邮箱读**上次官方跑分的真实结果**，按真实总时长重放进度动画；无历史数据时显示提示文案 |
| **Q1 配色** | 绿 `#2ECC71` = 现有 PAL_OK(13)；灰 `#888888` = 现有 PAL_UI_DIM(14)；亮金 `#FFD700` = **新增**调色板条目 18（gen_tiles.py 已加） |
| **退出方式** | 长按 SW6 1 秒**软跳**回 title（**禁用复位**：boot 会再次选路）。game.c 已实现 `key[2]` 长按判定 |
| **静态结果页** | 官方裸机 CoreMark 的结果页**版式可改**，测量过程一行不能动（coremark_port 已改版式） |
| **数字口径** | ITER=3900 @76.5052MHz、352.5 分、4.6075 CM/MHz（128KB 档实测口径，以 board 上板日志为准） |

## 2. 已落盘改动（git 工作树全部未提交，含 T6-R4 遗留 + T7）

| 文件 | 改动 |
|---|---|
| `scripts/boot/boot.S` | 三路径选路，**30 字**（`_start` `.size` 0x78），编译通过；`0xFF80` 写 `'CMED'`=0x434D4544 |
| `scripts/gomoku/cm_mailbox.h` | `CM_BOOT_FLAG_ADDR 0xFF80` / `CM_BOOT_FLAG_MAGIC 0x434D4544`（与 boot.S 常量配对） |
| `scripts/gomoku/coremark_screen.c/.h` | **新增** A1 重放屏全部逻辑；主频用 `#define CM_FREQ_KHZ() (hw_ticks_per_ms())` 现算（绕开两个 board.h 的 `BOARD_SYSTEM_CLOCK_HZ` 歧义） |
| `scripts/gomoku/game.h/.c`、`main.c` | `GAME_COREMARK` 相位 + 长按 key[2] 回 title + boot 标志读取（读完清零）+ draw_frame 分支 |
| `scripts/gomoku/gen_tiles.py` | PAL += `0xFFD700`(18)；FONT8_CHARS 补 `-`,`Z`（39 字 → tiles 90..128）；FONT8G_TILE_NUMS=73..86+[180,181,251]（**让出 127/128，255 禁用**）；主字模补 `[`/`]`/`%`；新增 FONT_TERM_GREEN16（`[]RUNIGPAS`→154..163）/GOLD16（`COREMAKS/:.0123456789HZ`→164..177+131..134+87..89+141..142）/GREEN8（`OK`→143..144）/GRAY8（`%`→145）；**删除标题中灰子集**（129/130/146..149/178..179 释放） |
| `scripts/gomoku/font.h`（再生） | FONT_N_GLYPHS=37、FONT_TILE_BASE=36、FONT8_N_GLYPHS=39、TILE_N_PALETTE=19（已核对无误） |
| `scripts/gomoku/render.c` | 新增 `synth_glyph_set` 通用助手 + `render_term_begin/end`；render_init 三处循环改用助手；tgray 与中灰合成循环删除；TERM 8x8 小映射改栈上 `m8[95]` |
| `scripts/gomoku/render.h` | `RENDER_TILE_TERM_FILL=135`/`TRACK=136`（借 THINKING 的 T/H）；tgray 声明删除 |
| `scripts/gomoku/test_render.c` | 中灰检查 → "退役图块不被写"负向检查；埋入诊断（tile 255 字符画 / 写入序列打印 / 0xAA 监视） |
| `scripts/rtthread/bsp/link.ld` | `.rodata` 前 `ALIGN(0x1000)`→`ALIGN(4)`（省 ~3.3KB 填充；elf2mem 按段名+VMA 分桶，无 4KB 依赖，已核实） |
| `scripts/gomoku/build.ps1`、`scripts/rtthread/build.ps1` | 源清单加 `coremark_screen.c` |
| `scripts/coremark_port/*` | 静态结果页版式改造（测量过程未动） |

## 3. 验证状态

> T7 会话当时的状态；**最新结果看 §0.2**（两 FAIL 已消除，镜像 61,200/61424）。

- x86 单测：board / ai / input / game **全 PASS**；**test_render 106 检查 2 FAIL**（见 §4）
- boot.S：编译通过，30 字
- RT-Thread 镜像：**61,263 / 61,424 字 = 99.7%，堆余 160B**（四步瘦身后装下）
- 未做：RT-Thread 仿真回归（`run_sim.ps1 -Sim`）、裸机 `gomoku/build.ps1` 编译验证、
  `build_bitstream` combined 链路、上板（boot.S 变 30 字后跑分位流口径需重出重验）

## 4. 当前卡点：test_render 两 FAIL —— 根因已定位（本会话末尾成果）

### 4.1 症状（`run_test.ps1`，test_render 106 checks / 2 errors）

1. **[FAIL] test_render.c:277** —— tile 255 被写；字符画诊断显示内容 = 全颜色 7
   （全背景色的"空格样"字形）。写入序列片段：
   `... 126 127 128 | 255 255 | 180 181 251 | 141 142 143 144 145 | 135..140 | 131..134 | 150..177 | 186 187 253`
2. **[FAIL] test_render.c:347** —— 暗金 8x8 `&`（tile 73）缺 `PAL_GOLD_DIM` 笔画。

### 4.2 根因（代码级证据，高置信——下一会话可直接照此修）

**索引约定不匹配，两处调用点错位 32 格：**

- `synth_glyph_set`（`render.c:630`）映射模式按 **ASCII 原值**取表：
  `int tn = tiles ? (int)tiles[(unsigned char)chars[g]] : base + g;`
- 生成侧约定（`gen_tiles.py:276/309/319`）是 **`ord(ch) - FONT_BASE`（0..94）**：
  `FONT8G_TILE[ord(_ch) - FONT_BASE] = FONT8G_TILE_NUMS[_i]`
- render_init 的 8x8 暗金子集（`render.c:922-924`）直接把 `FONT8G_TILE` 当 tiles 传 →
  `&`(38) 取到 `FONT8G_TILE[38]`（=第 38 格 = 0xFF）而非第 6 格（=0x49=73）。
  错位规律（按表逐格核过）：`'E'→76、'V'→180、'W'→181、'Y'→251`、
  空格/`&`/`-`/`.` 等 → 0xFF → **写 tile 255**；tile 73 **从未被写** → FAIL ②。
  这同时解释写入序列里 `255 255` 与 `180 181 251` 的出现位置，全部自洽。
- `GREEN8/GRAY8`（`render.c:668-679`）用**栈上 `m8[95]`、按 ASCII 索引**（`m8['O']=143`）
  ——与助手的 ASCII 原值约定**一致** ⇒ 正确。这就是其余测试全 PASS 的原因。

**同源第二处（测试没盖住、更要紧）**：`render_term_begin`（`render.c:662-667`）把
`FONT_TERM_GREEN16_TILE` / `FONT_TERM_GOLD16_TILE`（同为 `ord-32` 索引，gen_tiles.py:309/319）
直接传助手 ⇒ **演示屏本身的 16x16 终端字形也会整体错位画错**。x86 单测没调
render_term_begin，所以没报。

### 4.3 修复方案（推荐 A；B/C 的坑写明）

- **A（推荐）调用点适配**：三处错位调用点（8x8G、GREEN16、GOLD16）改用栈上映射，
  与 m8 风格统一：`uint8_t m[127]; for(i=0;i<127;i++)m[i]=0xFF; for(i=32;i<127;i++)m[i]=表[i-32];`
  不占 rodata（镜像 99.7% 满，rodata 预算极敏感，**禁选"生成侧扩表"**——每表 +32B×4 会爆）。
- **[!] 栈表必须开 127 不是 95**：GREEN16 字符集含 `[`(91)/`]`(93) ≥95，`m8[95]` 会越界
  （现 m8['O']=79 只是碰巧没炸）。
- 修完判据：`run_test.ps1` 全绿（两 FAIL 消失、退役图块负向检查仍 PASS），
  再用 `preview_coremark.ps1` 出预览图人工核对演示屏字形。
- 然后清理 test_render.c 的序列打印诊断（保留 tile 255 负向断言）。

## 5. 关键技术事实速查（下一会话省时间的）

- **gen_tiles.py exit=-1 陷阱**：GBK 控制台打印预览阶段 UnicodeEncodeError 嫌疑，
  但**文件已全部写完**——勿误判失败。判据：看 font.h 再生成时间戳/内容。
- **elf2mem** 按段名+VMA 分桶，无 4KB 边界依赖（已核实）→ link.ld ALIGN(4) 安全。
- 图块"借用"：演示屏借标题屏专用块（logo 154..177、WINS 131..134、中文 87..89、
  GOMKU 141..145、THINKING 135..140 前两块），退出时 render_init 全量恢复。
- `RENDER_TILE_TERM_FILL=135 / TRACK=136`；tile 255 = 测试断言"永不写"的哨兵。
- 镜像预算红线：61,424 字（0x10000~0x1EFF0，栈 0x1EFF0~0x1FFF0）；当前 61,263，**堆余 160B**。
  任何加 rodata/bss 的改动都要重看这两个数。
- boot 标志：`0xFF80` / magic `0x434D4544`，boot.S 与 cm_mailbox.h 两处常量必须一致；
  是"选路阶段唯一一次写 RAM"，在两边 .bss 之外。
- 邮箱 `0xFF00`：官方跑分档写入上次结果（A1 重放数据源）；无数据 → 显示提示文案。
- 官方跑分档数字：ITER=3900 @76.5052MHz；352.5 分；4.6075 CM/MHz。
  （85MHz 交付档 391.66 是另一口径，见 CLAUDE.md/论文框架 §0，别混。）
- 退出 = 长按 SW6 1s 软跳 title；**不能复位**（boot 会再选路）。

## 6. 剩余工作（T7 会话当时的顺序；1~4 已完成，最新看 §0.3）

1. **修两处错位调用点**（§4.3 方案 A）→ `run_test.ps1` 全绿
2. 清 test_render.c 临时诊断（保留 tile 255 负向断言与字符画？建议只留断言）
3. `preview_coremark.ps1` 出预览图，人工核对演示屏（绿/金/灰配色、`[`/`]`/`%`/`-`/`Z` 字形）
4. 裸机 `scripts/gomoku/build.ps1` 编译 + `scripts/rtthread/run_sim.ps1 -Sim` 回归
5. `build_bitstream.ps1` combined 链路验证（boot.S 30 字后**官方跑分位流口径需重出重验**，
   ITER/得分按 §1 纪律重算核对）
6. 文档同步：boot.S 字数（17→30）、镜像口径（61,263/61,424）、
   `CLAUDE.md` + 论文框架 §0/§0.1 + `doc/board/README.md`（按"四处同步"纪律）
7. 提交（按里程碑拆；不自动 push）

## 7. 下一会话开场提示词（可直接粘）

> 读 `doc/reports/2026-10-19_t7_coremark_demo_handoff.md`。T7 演示屏代码已全部落盘，
> 只剩 test_render 两个 FAIL：根因已定位 = synth_glyph_set 映射模式按 ASCII 原值索引，
> 而 FONT8G_TILE/FONT_TERM_*_TILE 是 ord(ch)-32 索引约定，render.c 922 与 662-667
> 两处调用点错位 32 格。先按文档 §4.3 方案 A（栈表 127 项，禁扩 rodata）修复，
> 跑 run_test.ps1 到全绿，再清诊断、出预览图，然后按文档 §6 顺序收尾。

## 8. 风险

- 镜像 99.7% / 堆 160B：**没有余量**。修复方案若意外增大 rodata/bss，立刻回退看 §5 预算红线。
- render_term_begin 的错位在 x86 单测无覆盖：修复后必须出预览图（或补一个直接调
  render_term_begin 的单测段），不能只看 run_test.ps1 绿。
- boot.S 30 字改动未上板验证过：跑分位流重出后按惯例核对四 CRC 与 ticks 口径。
