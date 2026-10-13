# RISC-V 五子棋 + RT-Thread 任务书（v2 · 2026-10-13）

> **读者：甲（五子棋 / RT-Thread 线）。** 本文**自包含**，不需要先读旧文档。
> 分支 `dualissue`（本地仓库 `D:\riscv-cpu-fpga_merged`）。开工前读工程根 `CLAUDE.md`
> 与 `doc/board_bringup.md`。
>
> **本文取代 v1（2026-10-12）。** v1 里"T1 待做"的口径已过期 —— **T1 做完了**（见 §0）。
> v1 的 §5 接口参考、§7 纪律仍然有效，本文只重写了变动的部分。
> 仓库侧权威记录：`doc/reports/2026-10-13_T1_rtthread_g3_checklist.md`（T1 全细节）。

---

## 0. 三十秒版（T1 之后）

| | 状态 |
|---|---|
| CPU | 顺序双发射 + `EARLY_LD` + A1 乘法器 II=1，**85.0051 MHz**，CoreMark **365.93**（板上实测）|
| 显示 | tile PPU + HDMI 已完成并上板；五子棋裸机版已板上可玩 |
| **T1（拆线程做 G3）** | **[OK] 已完成并首次上板（2026-10-13）** —— 位流 `8894cdcb`，日志 `doc/board/uart_20261013_224652.txt`。render(优先12) + AI(优先25) 两条线程，**两线程邮箱往返在真板上跑通了** |
| **你的活** | **① T1 的两件收尾（§2，先做）→ ② T2 + T3 → ③ T4 → ④ T5** |
| 完成的定义 | 菜单全路径可走；AI 思考期间画面**肉眼确认**不卡；板上连续 ≥10 分钟稳定；界面上显示**真实跑出来**的 CoreMark 分数 |

> [!] **别把 T1 当成"G3 已验证"** —— T1 那次上板**没接显示屏**，而且串口留了一条
> `[!] vblank timeout`。§2 就是这两件。

---

## 1. [!] 开工前必读：当前基线（别用旧数字）

```powershell
scripts\rtthread\build.ps1              # 编 RT-Thread 固件，打印占用
scripts\rtthread\run_sim.ps1            # 仿真（约 5 分钟）
scripts\gomoku\run_test.ps1             # x86 单测，不需要板子
scripts\build_bitstream.ps1 rtthread    # 上板唯一入口（约 6 分钟，出 .sbit）
```

| 项 | 当前值 |
|---|---|
| 板上时钟 | **85.0051 MHz**（`UART_DIV=738`、`BOARD_SYSTEM_CLOCK_HZ=85,005,100`）|
| RT-Thread 固件占用 | 静态 **51,193 / 61,440 B（83.3%）**，堆余 **9,368 B**；`_end=0xCB68`、栈顶 `0xFFF0` |
| 五子棋裸机固件 | `expectLines['gomoku'] = 11268`（`build_bitstream.ps1:128`）|
| RT-Thread 固件 | `expectLines['rtthread'] = 20270`（10135 字）—— **`-Sim` 编出来是 20266，差 4 行，别拿仿真口径的数去填** |
| riscv-tests | **49 PASS / 1 FAIL / 0 TIMEOUT**。唯一 FAIL 是 `ma_data`，**预期失败，别去"修"** |
| RAM | **64 KB**（`0x0~0xFFFF`）；可用代码/数据/堆 = `0x0~0xEFFF`（60 KB）|
| `mtime` | **32 位，85 MHz 下 ≈50.5 s 回绕一次**（见 §6）|
| T1 位流 | `8894cdcb` —— `pds/RV32I_1/bitstreams/rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_85mhz_rev1017_8894cdcb.sbit` |

> [!] **别碰 Cache 开关，也别去查 Cache 问题** —— 2026-10-14 查明：**带 Cache 的
> RT-Thread 五子棋固件会挂**（`-DCache` / `-ICache` / 两者**都能打挂它**，仿真 100 MHz
> 复现 ⇒ 功能 bug）。**那是 `rtl/bus/cache_*.v` 的事，归 CPU 线（乙）**，已进
> `2026-10-13_taskbook_v10_cpu.md` §3.1。
> **你的提交档一律 Cache 全关**（= `8894cdcb` 那一套，也是唯一板上验证过的组合）。
> 别在 Cache 上耗时间。

---

## 2. [P0 · 先做] T1 带下来的两件收尾

### 2.1 [!] `vblank timeout` —— 你新加的 yield 和 RTL 的脉冲宽度对不上

T1 那次上板，串口第 26 行打出：

```
[!] vblank timeout -- video not running (check D18 video_locked)
```

**这不是"视频坏了"这么简单，而且这句在归档里是第一次出现** ——
`doc/board/` 里 **23 份裸机五子棋日志一份都没打过**，而那些日志晚于这句代码入库
（`709446f`，2026-10-10 12:39；最新裸机日志 14:40），**不是"当时还没这句话"**。

**机制**（这条链要自己走一遍，别只信结论）：

* T1 在 `scripts/gomoku/video_port.c` 加了弱函数 `video_vblank_yield()`，
  RT-Thread 侧（`scripts/rtthread/app/main.c`）强覆盖成 **`rt_thread_mdelay(1)`** ——
  于是 vblank 忙等循环**每 ~1 ms 才看一次状态位**。
* 而 RTL 里这个状态位是 **`V_SYNC = 2` 行的脉冲**：
  `rtl/video/video_core.v:194-196` 的 `H_TOTAL=810`、pixel clk 25.5 MHz
  ⇒ **2 × 810 ÷ 25.5e6 ≈ 63 µs**。`video_core.v:133` 的注释自己写着
  "2 行 …… = 62.7us ≈ CPU 侧 3100 拍"。
* **拿 1 ms 的采样去看 63 µs 的脉冲，粒度差 16 倍。**

> [!] `video_port.c` 里那句注释假设的是"480p@60 的 **~1.4 ms** vblank 窗" ——
> **那是后肩 33 行（≈1.04 ms），不是状态位报的那个 vsync 脉冲**。RTL 注释专门区分了这两者。

**后果**（日志无法定量，因为这句按设计只打一次）：`video_wait_vblank()` 很可能经常要
等满 50 ms 超时才返回 ⇒ render 主循环从 ~60 fps 掉到 ~20 fps，而且 `draw_frame()`
会落在**消隐期之外**写显存 —— 恰好是 G3 最在意的东西。

**定案（一步，不用显示器）**：看板上 **led[1] = 丝印 D18（video_locked）**。
- D18 **亮** ⇒ 视频在跑、脉冲存在 ⇒ 只可能是被 1 ms 采样漏掉 ⇒ **真问题**；
- D18 **不亮** ⇒ 视频真没起来（但那样裸机版也该报，却没报 ⇒ 大概率还是前者）。

**修法（**优先走固件侧**，别碰 `rtl/`）**：

1. **首选：别在 vblank 忙等里睡。** 忙等要**紧**（裸机版就是紧忙等，所以一次都没漏过），
   让出 CPU 的动作挪到**帧内别处** —— 比如 `draw_frame()` 之后按帧节拍
   `rt_thread_mdelay()` 若干次。AI 线程拿到的 CPU 份额几乎不变（一帧里
   render 真正干活只有 ~1 ms），但 vblank 采样回到微秒级。
2. 备选：把状态位**加宽到整个消隐期**（`vsync + back porch + front porch` = 45 行 ≈ 1.42 ms），
   这样 1 ms 的采样必然命中。**但这是 RTL 改动（`rtl/video/video_core.v`），归乙线 ——
   要动先报告，别自己改。**

**验收**：串口**不再出现** `[!] vblank timeout`；接上显示器看画面顺；
`[hb] alive` 仍然每 5 s 一条、`rt_tick` 单调。

### 2.2 G3 的"画面不卡"要肉眼确认一次

T1 的**功能**在真板上已经证明（邮箱往返通了），但 G3 的**正题**——"AI 思考期间画面照刷、
光标照闪、按键有响应"——**没有人看过**，因为那次上板没接显示屏。

**做**：接一块 HDMI 显示器（板载口），HARD 档下一手要好几秒，正好观察：

| 看什么 | 期望 |
|---|---|
| AI 思考期间光标 | **照闪**（不卡住）|
| AI 思考期间按键 | **有响应**（光标能移动）|
| 画面整体 | 不冻结、不撕裂 |
| led[0]/led[1]（D19/D18）| pll_locked / video_locked **都亮** |

> [!] 反证也要做一次（便宜且能证明"双线程是承重的"）：把 render 优先级改成**低于** AI
> （12 → 28），重跑，应看到 AI 思考期间画面被憋住；然后**改回 12/25**。

---

## 3. 任务表与顺序

| # | 任务 | 优先级 | 一句话 |
|---|---|---|---|
| **T1'** | **§2 的两件收尾** | **P0** | vblank 采样 + 肉眼确认不卡 |
| T2 | 菜单系统 + AI 双向独立难度 + 间隔档位 | P0（最大块） | 标题屏→模式→难度/执子/间隔；`game_t` 拆字段 |
| T3 | HUD 行距重排 | P0（很小） | **随 T2 一起做**，别单独改一遍 |
| T4 | AI 思考卡顿 G1+G2 | P0 | 人落子立刻刷屏；AI 按层分批刷屏 |
| T5 | CoreMark 编进固件"一起运行"（强版本） | P0 | 真实跑、真实显示，**禁止写死数字** |

**顺序：T1' → T2+T3 → T4 → T5。**

> [!] **T4 的定位在 T1 之后变了**：G3（RT-Thread 路线）已经解决了"AI 思考时画面停住"，
> 所以 T4 的 **G1/G2 现在主要服务裸机版（`build_bitstream.ps1 gomoku`）**，
> 以及"AI 进度可见"这个演示加分项（`AI: NODES` 在涨）。**别把 T4 当成 G3 的替代品**。

**明确不做**：DDR3、音频、SD 卡、以太网；NES 模拟器（内存不可行）；
**不碰 `rtl/core/` 与 `rtl/bus/`，也不要碰 `rtl/video/`**（发现 CPU/视频侧异常走反馈回路，见 §6）；
不加新外设（PPU/GPIO/UART 已够）——真要加，先申请 `addr_map.vh` 变更（三处同步，归集成方裁决）。

---

## 4. 各任务细节与验收

### T2 · 菜单系统 + AI 双向独立难度（最大块）

```
标题屏 → 模式（人机对弈 / AI 对弈）
   ├─ 人机对弈 → 难度（EASY/NORMAL/HARD）→ 执子（人执黑先 / 人执白后）
   └─ AI 对弈  → 黑方难度 → 白方难度 → 每手间隔（快 0.5s / 中 1.0s / 慢 2.0s）
```

`game_t` 从单个 `level` 拆成 `mode` / `level_black` / `level_white` / `step_ms` / `menu_stage`；
`game_ai_turn()` 按执子方查难度；现有 `demo` 字段并进"AI 对弈"。
`test_game.c` 的标题屏用例跟着更新，并给菜单状态机补用例（进/出各层、上下键循环、长按确认、返回）。

> [!] **T1 留下的接口要一起改**：`game_ai_begin()` / `game_ai_finish()` / `game_ai_snapshot()`
> 现在按 `gm->level` 取难度。拆成双向难度后，**派单时要把"这一手是谁的难度"一起带给 AI**
> （`ai_cmd_t.level`），别再让 AI 线程回头读 `g_game` —— 那是 render 线程私有的。

**验收**：菜单全路径可走、4 个键可操作、x86 单测全绿、RT-Thread 仿真 PASS。

### T3 · HUD 行距（随 T2）

`LEVEL:` 与 `TURN:` 间距太小；`START: HOLD ANY KEY` 与 `AI: NODES` 间隙不够。
棋盘占行 7~21，行 0~6 和 22~29 空着 —— 纯排版，随 T2 的菜单重排一起做。

### T4 · AI 卡顿 G1+G2

现象（裸机版）：AI 一手 171 ms ~ 1,433 ms，整段时间主循环停住、光标闪烁也停。
- **G1**：人落子后**立刻刷一次屏**，再进 AI。
- **G2**：AI 按**迭代加深的层数分批**，每层搜完回主循环刷一次屏 —— 画面跳 2~3 次，
  且 HUD 的 `AI: NODES` 数字在涨（演示加分项）。
- **G3 裸机版不做**（递归改迭代风险太高），走 T1 的 RT-Thread 路线 —— 那条已经做完了。

> [!] 改了 AI 的搜索方式，**x86 单测里的棋力/自对弈用例要一起过** ——
> 分层返回不能改变最终选中那一手，否则就是搜索被改坏了。

### T5 · CoreMark 编进固件（强版本，先做决定再做）

**赛题口径**："一起运行" = 同一块板子能演示两者。**强版本**：真的把 CoreMark 编进固件，
在菜单里跑一遍，把**这次真跑出来的** `Total ticks`/ITER/分数显示在界面上，串口打出同样的数自证。
**禁止界面上写死数字**（评委一验证就穿帮）。

- 体积：gomoku ≈22.5 KB + CoreMark ≈17 KB ≈ **39 KB < 60 KB**，装得下（以 `size` 实测为准）。
- **>32 KB 区间是曾经的 bug 盲区**（`imem_addr2` 截位，已修但**零回归覆盖**）—— 合并固件天然
  跨入这一区间，**行为异常要第一时间想到这条并反馈**（这也是 T5 的真正价值：它是那通路的实战覆盖）。
- **ITER 必须按目标时钟重算**：`ITER = 时钟 × 10 ÷ 每迭代拍数`，留 5~17% 余量。
  当前 85.0051 MHz、**232,345 拍/迭代** → **ITER = 4280**（实测 11.6961 s / 365.93 分）。
  ⚠️ **别再用 241,633 或 ITER=4116** —— 那是 A1 之前的。
  选错会被 CoreMark 判 invalid（`ERROR! Must execute for at least 10 secs`）。
- **UART 归属**：CoreMark 移植层用兼容区 MMIO（`0xFFF4`/`0xFFF8`/`0xFFFC`），和五子棋的
  `hw_port.c` 共用同一个 UART 出口 —— **理清谁在什么时候写**（`ee_printf` 发每个字符都会
  忙等读 `0xFFF4`）。
- **验收**：界面上显示的 ticks/分数与串口输出一致、与单独跑 CoreMark 的一致。
  **四个 CRC**：`seedcrc=0xe9f5` / `crclist=0xe714` / `crcmatrix=0x1fd7` / `crcstate=0x8e3a`。
  **`crcfinal` 不比**（它是跨迭代累加器，必然随 ITER 变）。

---

## 5. 和乙（CPU/RTL 线）并行 —— 文件划分

**你们俩同时改同一个仓库，撞文件就等于白干。** 按这个划：

| | 甲（你，五子棋线） | 乙（CPU/RTL 线） |
|---|---|---|
| **你的文件** | `scripts/gomoku/**`、`scripts/rtthread/**`、`sim/tb_rtthread.v`、`sim/tb_gomoku.v` | `rtl/core/**`、`rtl/bus/**`、`rtl/mem/**`、`rtl/video/**`、`sim/tb_*.v`（CPU/视频侧）、`sim/tests/**` |
| **别碰** | `rtl/**`（**包括 `rtl/video/`**）、`sim/tb_riscv.v`、`sim/tb_coremark.v` | `scripts/gomoku/**`、`scripts/rtthread/**` |

**共用的东西，约定如下：**

1. **`scripts/build_bitstream.ps1` 的 `expectLines` / `expectDesc` —— 只有你改。**
   理由：RTL 改动**不改变固件体积**，只有你改固件源码才会变。改完固件就实测更新那两个数，
   **别放宽守卫**（它是"板上跑的是不是我以为的那个程序"的唯一自动判据）。
2. **`pds/RV32I_1/mem.hex` 和 `RV32I_1.pds`** —— 每次 `build_bitstream.ps1` / 综合都会改写它们
   （`mem.hex` 是**被 git 跟踪**的，内容是**生产固件 = CoreMark**）。
   **提交前一律 `git checkout -- pds/RV32I_1/mem.hex pds/RV32I_1/RV32I_1.pds` 还原**，
   别把 RT-Thread 固件提交进 `mem.hex`。
3. **`pds/RV32I_1/bitstreams/README.md`** —— 两人都会往里加行。加在**自己那组的区块里**
   （你的都在 `gomoku_*` / `rtthread_*`），冲突了就把两行都留下。
4. **`CLAUDE.md`** —— **别两人都改**。你要沉淀结论就写进
   `doc/reports/<日期>_session_state.md`，由集成方统一并进 `CLAUDE.md`。
5. **`doc/board/`** —— 文件名带时间戳，天然不冲突，放心加。
6. **[!] 板子只有一块、JTAG Server 只有一个** —— 谁要上板先打招呼；烧完**立刻归档位流**
   （`pds/RV32I_1/bitstreams/` + 登记 README）并记 `build_bitstream.ps1` 打印的 md5。

**Git**：**各开自己的特性分支**（如 `feat/gomoku-t2`），别两人直推 `dualissue`。
完成一个里程碑 → 推分支 → 由集成方合并。

---

## 6. 纪律（都是踩过的，照着做）

1. **不碰 `rtl/core/` / `rtl/bus/` / `rtl/video/`** —— 发现 CPU 或视频侧异常走反馈回路。
2. **[重点] `mtime` 是 32 位、85 MHz 下 ≈50.5 s 回绕一次。** 所有"当前时刻 − 起点"的
   差值比较**必须用无符号减法**（`board.c` 的 `rt_hw_us_delay` 和 `game.c` 的
   `now - t_next_ai` 已经是这么写的，**别改坏**）；`t_next_ai = now + delay` 这种
   "重写比较值"的写法是对的，**别换成"读 mtime 再加"**。
   **验收要求连续运行 ≥10 分钟 = 跨 ~12 次回绕**，必须显式验证，不能"跑一次没崩"就算过。
3. **显存写入必须在 vblank 窗口内**：拆线程后 `draw_frame()` 仍在 `video_wait_vblank()`
   之后调，**别把 `draw_frame` 挪到 AI 线程或 vblank 之外**。（§2.1 修完更要守住这条。）
4. **别裸读共享全局**：AI 线程只碰邮箱拷进去的副本（`ai_cmd`），**不碰 `g_game`**；
   `g_game` 是 render 线程私有的。任何跨线程传值走邮箱。
5. **改了固件，`build_bitstream.ps1` 的行数守卫会拦你** —— 守卫在工作，
   实测后更新 `expectLines`，**别放宽**。
6. **变短/换行的串口/HUD 字符串要整行重写**（`render_text` 先铺空格再覆盖）——
   否则屏幕上留下残字。
7. **新增 RTL 文件必须在 `.pds` 里手工登记**（`wgt_my_design_src` 加 `(_file ...)`）：
   仿真脚本是通配扫描，**仿真会过、综合才报错**。（你不该加 RTL 文件，提一句免得踩。）
8. **iverilog 14 严格要求"先声明后使用"**；**Verilog 字符串转义里没有 `\r`**
   （换行用 `16'h0D0A` 拼）。
9. **上板前必须 `scripts\build_bitstream.ps1 rtthread`（或 `gomoku`）** ——
   它会生成固件 → 同步 → **校验 `mem.hex` 字数** → 综合，并打印 md5。**别靠文件名猜固件。**
10. **跑过任何非生产综合（临时探针）之后，必须重跑一次 `build_bitstream.ps1 <变体>`**
    把标准路径上的 `.sbit` 盖回来 —— 它名字固定、大小一样，唯一的区别是烧上去**什么都不跑**。

---

## 7. 卡住了怎么办

| 症状 | 先查 |
|---|---|
| 串口没输出 | **两根 USB 线都插了吗**（Jtag + USB UART 是**两个独立接口**）；COM 口对不对 |
| 串口有 banner 但后面没了 | `generate_bitstream\cpu_top_board.sbit` 是不是上一版？核 md5 |
| 板上跑的还是老程序 | `pds\RV32I_1\mem.hex` 过期（PDS 从不检查时间戳）—— 重跑 `build_bitstream.ps1` |
| HDMI 黑屏 | **led[1] = 丝印 D18 = video_locked**，不亮先查视频 PLL，别去看 HDMI |
| 画面卡 / 撕裂 | §2.1 的 vblank 采样 |
| 跑到 ~50 s 就出怪事 | §6.2 的 `mtime` 回绕 |
| 板子像死了 | 复位键：**丝印 KEY1**（手册 KEY0 / 管脚 C22）。**别按 SW2/D22** |

**找谁**：CPU/RTL 相关 → 乙；接口/地址映射/集成 → 集成方；**别自己改 `rtl/`**。

---

## 8. 怎么跑（速查）

```powershell
# ---- 不需要板子 ----
scripts\gomoku\run_test.ps1              # x86 单测（改 game.c/ai.c/board.c 后必跑）
scripts\rtthread\run_sim.ps1             # RT-Thread 端到端仿真（约 5 分钟）
scripts\rtthread\build.ps1               # 只编固件，看体积
#   [!] 仿真口径 = -Sim（100MHz + 短延时 + AI_EASY）；
#       上板口径 = 不带 -Sim。两者编出来的 .text 差 8 字节，别混。

# ---- 上板 ----
scripts\build_bitstream.ps1 rtthread     # RT-Thread 五子棋版（本任务线的主变体）
scripts\build_bitstream.ps1 gomoku       # 裸机五子棋版（T4 主要作用在这里）
# 起 JTAG Server：D:\pango\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
# 烧录（无头，别用 GUI Programmer —— 它会记住上次路径）：
D:\pango\PDS_2022.2-SP6.4\bin\cdt_cfg_shell.exe -file scripts\flash.tcl `
    -args { D:/riscv-cpu-fpga_merged/pds/RV32I_1/generate_bitstream/cpu_top_board.sbit }
scripts\serial_monitor.ps1 -Port COM4 -Seconds 60   # 默认落盘 doc\board\uart_<时间戳>.txt
```

**RT-Thread 上板判据（这次要全绿）**：
`[build] FW=RTTHREAD-GOMOKU-G3 RTL=0x...` → `[boot] gomoku render thread running`
→ `[boot] gomoku ai thread running` → `[hb] alive` 每 5 s 一条且 `rt_tick` 单调
→ **不再有 `[!] vblank timeout`** → 棋盘/光标/落子正常。
