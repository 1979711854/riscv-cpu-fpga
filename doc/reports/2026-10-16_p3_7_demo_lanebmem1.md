# P3.7：演示档切 1 档 + 收口（2026-10-16 傍晚）

> 接 P3.6（入口 HEAD `f9ff405`；P3.6 里程碑提交 = `e8426dd`）。
> 本会话目标：(A) 演示档（RT-Thread 五子棋）切 1 档 → 功能仿真 + 位流 + 上板；
> (B) 若还要补时序余量 → ① 定向窄 region（需 GUI 坐标，**本轮未做**）；
> (C) 脚本口径修复 + 把"抢拷逐 seed 报告"固化成工具。
> **数字口径以 `doc/paper/论文框架_v1_20261012.md` §0/§0.1 + `CLAUDE.md` 提交档表为准**；
> 本会话已同步五处：论文框架 §0/§0.1、`CLAUDE.md`（提交档表 + P3.7 块）、`doc/board/README.md`、
> `pds/RV32I_1/bitstreams/README.md`、`doc/skills/riscv-cpu-fpga/SKILL.md` §1。

---

## 0. 一句话

**1 档（`LANEB_MEM=1`）现在是"跑分档 + 演示档"统一定版**：跑分 `c6af65be`（391.66 分，P3.6 已上板）
与演示 **`e51ac9e5`**（2026-10-16 16:30 上板，四条判据全过）**同为 rev1027、同一份 `rtl/**`、同一布局**
（都钉 `gplace_seed 5`）；从 P3 起挂账的 **gomoku 1 档功能仿真也补齐了（6/6 PASS）**。

---

## 1. 状态（精确）

| 项 | 值 |
|---|---|
| RTL | **未改**（`DESIGN_REV=0x2026_1027`；`rtl/**` 一行未动）|
| 演示档位流 | `pds/RV32I_1/bitstreams/rtthread_dual_noaext_ms_earlyld_a1_ras_btb_gomoku_g3_lanebmem_85mhz_rev1027_seed5pin_e51ac9e5.sbit`（**已上板验证**）|
| 跑分档位流 | `…_seed5pin_c6af65be.sbit`（P3.6 已上板，391.66 分，本会话未重出）|
| `RV32I_1.pds` | `cmd_pnr` 仍为 `(_option gplace_seed (_integer 5))`（单 seed 模式，PDS 跑完只改了 `_comment`/`_timespec`，**已核 diff**）|
| 证据 | 板级日志 `doc/board/uart_20261016_163009.txt`（333 行）；仿真日志 `doc/reports/2026-10-16_gomoku_g3_lanebmem1_sim.txt`；时序报告 `pds/_capture_p36/demo_rt_p36/final_report_timing_cpu_top_board.rtr`（未跟踪）|
| `pds/mem.hex` | 构建把它同步成了 rtthread 固件（21046 行）—— **提交前已还原成 HEAD 的跑分固件（17104 行）**，理由见 §8 |

---

## 2. (A1) 补上挂账的 gomoku 1 档功能仿真 → **6/6 PASS**

**为什么"只需要重跑"**：`sim/tb_gomoku.v` 例化 `cpu_top` **不传任何 parameter** ⇒ 取 `rtl/top/cpu_top.v`
的默认值，而 P3 起 `LANEB_MEM` 默认已是 **1**。所以从 P3 起这个测试台跑的一直是 1 档，只是**没人跑过**。

**顺手补的一处**（本次改）：`tb_gomoku.v` 原来**没有**配置自证行（`tb_rtthread`/`tb_coremark`/`tb_riscv` 都有），
补上后日志首行即口径（这也是我重启了一次仿真的唯一原因）：

```
SIM CONFIG: DUAL_ISSUE=1 EARLY_LD=1 LANEB_MEM=1 (来自 cpu_top.v 的默认值)
```

**结果**（`doc/reports/2026-10-16_gomoku_g3_lanebmem1_sim.txt`）：

```
=== tb_gomoku：五子棋固件端到端 ===
  [ok]   banner 收到：固件已启动
  [ok]   棋盘左上角已铺好（tile=20）
  [ok]   天元是空格（tile=0）—— 标题屏不画光标，符合预期
  [ok]   菜单开局成功
  [ok]   天元已落黑子（tile=1）
  [ok]   AI 已应手
checks=6  errors=0
=== PASS ===          （$finish at 168,402,000,000 ps = 168.4 ms 仿真时间）
```

**耗时**：16:12:52 → **16:37:08 = 24.3 min 墙钟**。⚠ 本机 iverilog 实测偏慢
（50M 周期的空基准仿真 = 32 s），且后台 vvp 只拿到 **~7% 一核**（28 min 只累计 117 s CPU）——
**下次排时间要留足**（见 §6 坑 2）。

---

## 3. (A2) 演示档 1 档位流

```powershell
scripts\build_bitstream.ps1 rtthread      # 唯一入口：固件重建 → mem.hex sha256/行数守卫 → 综合 → P&R → 出位流
```

| 项 | 值 |
|---|---|
| 位流 md5 / 时间 | **`e51ac9e5`** / 2026-10-16 **16:19:57**（`generate_bitstream/cpu_top_board.sbit`，8.76 MB）|
| 归档 | `bitstreams/rtthread_dual_noaext_ms_earlyld_a1_ras_btb_gomoku_g3_lanebmem_85mhz_rev1027_seed5pin_e51ac9e5.sbit` |
| 固件守卫 | `mem.hex` **21046 行 / 10523 字**、sha256 与 `sim/programs/mem.hex` 一致 ✓（`expectLines` 拦截通过）|
| 参数自证 | 构建摘要打印 `LANEB_MEM = 1`（**脚本已修，见 §5**）；`cpu_top.v: LANEB_MEM=1`（git 未动）|
| CPU 域 | **+0.277 ns / 0 失败端点（19,114）/ 请求 85.0051 → 可达 87.0549 MHz**（周期 11.764 / 11.487）|
| 布局一致性 | `totalEP = 19,114` 与跑分档 `c6af65be` **完全相同**；`.prr` 的 FF **3,691** 同网表 ⇒ 确是同一布局/同一网表（钉 `gplace_seed 5`）|
| 跨域 | `u_pll→pix_clk` **−1.093 ns / 21 端点** = 既有伪影（P3.6 那份是 −1.074），**不是回归**；`Design Summary : Some Constraints Violated` 只由它引起 |

---

## 4. (A3) 上板四条判据（**全过**）

日志 `doc/board/uart_20261016_163009.txt`（333 行，16:30:10–16:31:10，一次跑完 + 两局棋）：

| 判据 | 实测 |
|---|---|
| banner | `[build] FW=RTTHREAD-GOMOKU-G3 **RTL=0x20261027**`（app 侧 `FW=GOMOKU RTL=0x20261027` 一致）✓ |
| `[boot] gomoku render thread running` | ✓ |
| `[boot] gomoku ai thread running` | ✓ |
| 两线程 + `[hb]` 无断 | `[hb] alive, uptime 5000 → 50000 ticks` **十条**、每 5 s 一条、单调递增、**无断** ✓ |
| 真按键 + HDMI 下完一局 | 光标 `H8→I8→J8→K8→L8→L9→L10`、落子、AI 应手；**判出 `WHITE wins`**；回 `title` 后又开**第二局** ✓；**用户确认 `D18`(video_locked) 常亮、HDMI 显示正常** ✓ |
| 灯 | `D19` / `D18` 常亮；`D13`(led[2]=done) **本变体不亮，别误判** |

**"烧对了哪一颗"的自证链**：`RTL=0x20261027` + RT-Thread/GOMOKU banner ⇒ **只可能是 `e51ac9e5`** ——
rev1027 的 rtthread 位流**只有这一颗**（0 档演示档 `1e2075e6` 是 rev1023，会打 `0x20261023`；
跑分档 `c6af65be` 虽是同 REV，但会打 CoreMark 报告）。

**已知假超时**：日志第 31 行 `[!] vblank timeout -- video not running` —— 0 档 `1e2075e6` 的同款日志也有，
而当时 `D18` 亮、画面正常 ⇒ **判据看 D18，不看这句话**。

**应用侧旁证（非受控测量，别当数字引用）**：同一开局位置 `nodes=1287 depth=4` 本颗是 `t=569ms`；
0 档 rev1019 的 RT-Thread 档（76.5052 MHz）是 `t=672ms`。含主频 +11.1% 与 lane B 的效率收益，
也含 RT-Thread 调度噪声。

---

## 5. (C) 脚本口径修复 + 新工具

### 5.1 `scripts/build_bitstream.ps1`：`$cpiCycles` 按 `LANEB_MEM` 分档

修前：只按 `DUAL_ISSUE` 选 ⇒ 出 1 档位流时打"期望 994,614,204 ticks / 370.2 分"（板上真值 940,425,216 / 391.66）。
修后（照抄它读 `DUAL_ISSUE` 的那段）：

```
$laneBMem = 从 rtl/top/cpu_top.v 读 parameter LANEB_MEM
$cpiCycles = 双发射 ? (LANEB_MEM==1 ? 217088 : 229597) : 300392
```

* 顺手把**单发射的 pre-RAS 旧值 303,140 换成 2026-10-15 P0 修正值 `300,392`**（同理 §4 的 `EARLY_LD=0` 写 249,982）；
* 构建摘要新增 `LANEB_MEM = 1  1 档：lane B 可放 load（当前生产档）`；`=== 完成 ===` 的"配置"行也带上了它。
* **`.ps1` 必须保持 UTF-8 BOM**（PS 5.1 否则按 GBK 读、中文注释会吃掉引号配对）—— 本次改完已复核 BOM + 语法。

### 5.2 新工具 `scripts/capture_seed_timing.ps1`

```powershell
# 另一窗口先起 P&R
scripts\build_bitstream.ps1 coremark
# 本脚本盯它（每轮必须换独立 -Tag！）
scripts\capture_seed_timing.ps1 -Tag p37_b1
# 只打表（P&R 已结束 / 复盘）
scripts\capture_seed_timing.ps1 -Parse pds\_capture_p36
```

* P&R 跑动中每 4 s 轮询 `place_route/seed_*/cpu_top_board.rtr`，**`Length > 1KB` 才拷**（防拷到半截），落 `<OutRoot>\<Tag>\`；
* PDS 退出后收尾再拷一次，然后打 **CPU 域 WNS 降序表**（判据行 = `Setup Summary(Slow Corner)` 里
  launch == capture == `clk|u_pll/u_gpll/CLKOUT0_Inferred`）+ 落 `seed_cpu_wns_summary.csv` + 给出"最优 seed 的复现改法"；
* 还会读 `.pds` 提示当前是单 seed（钉了 `gplace_seed`）还是多 seed 模式。
* **回归验证**：用 P3.6 归档的 41 份 `.rtr`（含 `batch4/`、`route_sweep/` 里命名成 `*_rtr.txt` 的那些）跑，
  数值与 `2026-10-16_p3_6_margin_plan.md` §6.2/§6.6/§6.7 **逐项一致**（seed_5 +0.277 … seed_34 −0.376）。

### 5.3 **新坑**：钉 `gplace_seed`（单 seed 模式）时，P&R 阶段**两个地方都不出 `.rtr`**

本次实测：`place_route\` 里只有 `.prr` / `.adf` / `.netlist`，`report_timing/cpu_top_board.rtr`
要等 PDS 把 Report Timing 跑完才写。⇒ 单 seed 模式**抢不到东西是正常的**，
工具已加兜底：PDS 退出后按 `place_route\` → `report_timing\` 顺序找（只认本轮 `$t0` 之后写的），
存成 `final_report_timing_cpu_top_board.rtr`（本会话那份就是这么来的）。
（多 seed 模式下这份 = **PDS 最终选中那个 seed** 的报告，正好是"选种口径错"的现场证据。）

---

## 6. 本会话的坑 / 教训（新增）

1. **钉 seed 的单 seed 模式不出 `place_route/seed_*/`，也不在 P&R 阶段出 `.rtr`**（见 §5.3）——
   想拿多布局分布必须换回 `gplace_times`。
2. **本机 iverilog 吞吐要按实测估，别按文档的"20~50 min"**：空基准 50M 周期 = 32 s 墙钟；
   本次 gomoku 端到端 168.4 ms 仿真时间 = **24.3 min 墙钟**。且后台 vvp 的 CPU 占用只到 **~7% 一核**
   （原因未定论：环境限流 or 本机就是慢）⇒ **长仿真要么留足墙钟，要么前台跑**。
3. **改测试台之前先想清楚**：为了给 `tb_gomoku` 加一行配置自证，我重启了一次仿真（多花 5 min 墙钟），
   换来"日志首行自带 1 档口径"—— 值，但**要在起仿真之前就做**。
4. `.gitignore` 里 `*.log` 被忽略 ⇒ **仿真/构建日志要存成 `.txt` 才能进仓库**（板级日志本来就这么做的）。

---

## 7. 下一步账本（**"还需要做什么"** —— 按"收益 / 成本 / 风险"排序）

**关键前提（2026-10-15 新计分口径）**：`Score = Iterations/(Total_Time × Frequency)` **化简即 CoreMark/MHz**
⇒ **主频与面积都不进主分**；三项指标 = (1) 执行效率 (2) Fmax (3) CoreMark/LUTs，**先比性能、性能相同再比面积**。
⇒ **主分唯一战场 = RTL 执行效率（每迭代 217,088 拍）**；为"自定判据 ≥+0.3 ns 差的那 0.023 ns"去冒布局风险**不值**。

| # | 方向 | 预期收益 | 成本 | 风险 | 建议 |
|---|---|---|---|---|---|
| 1 | **论文 + 评审材料**：§3 微架构章按 1 档口径重写、表 6 优化闭环补 lane B 一级、**录像/照片至今为零**、答辩 PPT | 评审硬门槛（**唯一"没做就真扣分"的事**）| 0.5~1 天 | 无 | ★★★ **先做这个** |
| 2 | **演示档 app 新版整合**（等队友发新版） | 演示"最终定版" | 20 min/轮 | 低（守接口面，见 §7.1）| ★★★ 收到就做 |
| 3 | **修掉 `vblank timeout` 那句**（T1'a：加只读帧计数器，固件改采样方式）| 演示日志不再有 `[!]`，答辩不被追问 | RTL 小改 + `DESIGN_REV` + 两颗位流重出 + 回归 + 上板（半天）| 低（只读寄存器）| ★★ 有余力再做 |
| 4 | **效率（主分，唯一主战场）**：lane B 放 store / 提高配对率 / RAS·BTB 深度 | 每迭代 −1~2%（217,088 → ~213k）| 半天~1 天 + **全量回归**（四基线+四 CRC+riscv-tests+own_tests+rtthread+gomoku）| **中**（store 涉及写口/前递/store-load 顺序，错了是静默错值）| ★★ 1/2/3 做完再做 |
| 5 | **时序（指标 2）**：RTL 打断关键路径那条 **1.76 ns 跨模块投放线**（lane B load 数据源打一拍）| 可能 +0.3~0.5 ns（Fmax 回到 0 档 87.46 以上）| 半天 + 访存延迟 +1 拍要算账（217,088 会变）| 中高 | ★ 只在想抬指标(2) 时做 |
| 6 | **① 定向窄 region**（需 PCE GUI 框坐标）| 上限 **+0.02~0.05 ns** | 每轮 10 min + GUI 取坐标 | **高**（29% die 大区域已有确定性负面前科 +0.034→−0.755）| ☆ **不做**（收益与风险不成比例，且主分不吃它）|
| 7 | 面积（指标 3，只在性能相同时才比）| LUT 7,753 已 4.85% | — | — | ☆ 低优先 |
| 8 | 更多 place seed（40 个软顶 ≈ +0.28，判据 +0.3 差 0.023）| 概率很低 | 每 8 个 ≈ 10 min | 无 | ☆ 不值 |
| 9 | 提频（85.0051 → 87 MHz）| +2.4% 分 | PLL 三处联动 + 重测 | **不值**（Fmax 余量只剩 0.055 MHz）| ☆ 不做 |

| 10 | **ILA 波形取证**（用户要求：**等所有 CPU 优化定版后再抓**）| 答辩/§5 的波形证据 | 半天（插 ILA + 重综合 + 抓取）| 低 | ★ 定版后做 —— **现在别做**（RTL 一改波形就作废）|

### 7.1 队友新版 app 来的 SOP（20 分钟）

1. **只看 `git diff`，别整包覆盖**：`scripts/gomoku/{board,hw_port,video_port}.c` 里有我们的板级适配（`CPU_HZ`、寄存器映射）。
2. **守接口面**：G3 线程拆分依赖 `gomoku_run()` / `game_ai_snapshot()` / `game_ai_finish()` / `game_t.ai_snap`
   （实现落在**我们的** `scripts/rtthread/app/main.c`）；他若改这几个签名/结构体，我这边要适配一次。
3. `scripts\rtthread\build.ps1 -Firmware` 重建固件 → **`.text` 变了就同步 `build_bitstream.ps1` 的 `$expectLines`**（别放宽守卫）。
4. `scripts\build_bitstream.ps1 rtthread` 重出位流 → 归档新 md5 → 上板跑同样四条判据。
   **RTL 没动 ⇒ CPU 域仍 +0.277 ns**（`.pds` 已钉 `gplace_seed 5`），这些数字不用重算。
5. **绝对不做**：烧队友给的 `.sbit`（那就是换了颗 CPU、口径分裂 —— rev1017→1019 那次踩过的坑）。
6. **两个交付档的结论都保得住**：本次上板验的是 RTL/SoC 层（双线程/邮箱/按键/PPU/UART），
   与 app 小版本无关；换 app 只改 BRAM 初始化与 `.text`。

---

## 8. 提交

本会话提交内容：`CLAUDE.md`（提交档表 + P3.7 块）、`doc/paper/论文框架_v1_20261012.md`（§0 更新块 9 / §0.1 表 / §1 映射表）、
`doc/board/README.md`（顶部口径横幅 + 1 档演示档上板节）、`doc/board/uart_20261016_163009.txt`（新证据）、
`pds/RV32I_1/bitstreams/README.md`（登记 `e51ac9e5`）、`doc/skills/riscv-cpu-fpga/SKILL.md`（§1 改成"只留锚 + 指向论文框架 §0"、
§3/§4 数字更新）、`doc/reports/2026-10-16_gomoku_g3_lanebmem1_sim.txt`（新证据）、本文件、
`scripts/build_bitstream.ps1`（LANEB_MEM 口径）、`scripts/capture_seed_timing.ps1`（新工具）、
`sim/tb_gomoku.v`（配置自证行）、`pds/RV32I_1/RV32I_1.pds`（PDS 例行重写的 `_comment`/`_timespec`，`gplace_seed 5` 未变）。

> **`pds/RV32I_1/mem.hex` 已还原成 HEAD 的跑分固件**（17104 行）：构建过程会把它同步成"最后构建的那版"
> （本次是 rtthread 的 21046 行）。仓库里保留跑分固件与 `★ 提交档（跑分）` 一致，也避免一次 13k 行的无意义 diff；
> 要跑演示版固件时 `build_bitstream.ps1 rtthread` 会自己重新同步 + 校验（sha256 守卫）。
> **`.sbit` 本身不入库**（9 MB/个，见 `.gitignore`）。

提交纪律：**commit，不 push**。

---

## 9. 下一会话开场提示词（复制粘贴）

> 用户 2026-10-16 定的下阶段方针：**一边做 CPU 优化（效率 + Fmax），一边写论文正文**；
> 录屏/照片**等队友新版 app**（现在不能录）；**ILA 波形等所有 CPU 优化定版后**再抓（别提前做，RTL 一改就作废）。

```
接 P3.7（HEAD 以 `git log --oneline -1` 为准；P3.7 里程碑提交 = a806d8e）。
现状收口：两个交付档同为 1 档 rev1027 / LANEB_MEM=1 —— 跑分 c6af65be（391.66 分，CPU 域 +0.277 ns /
Fmax 87.0549 MHz，钉 gplace_seed 5）、演示 e51ac9e5（2026-10-16 16:30 上板四条判据全过，
日志 doc/board/uart_20261016_163009.txt）；gomoku 1 档功能仿真 6/6 PASS
（doc/reports/2026-10-16_gomoku_g3_lanebmem1_sim.txt）。⇒ "1 档统一定版"成立。

本会话主线 = 两条并行推进（一条卡在 PDS/仿真上时就切另一条）：
(A) CPU 优化：**效率（主分，唯一主战场）优先，其次 Fmax（指标 2）**；
(B) 论文正文：先写不依赖未来结果、也不依赖队友新版的章节。
**明确不做**：录屏/照片（等队友新版 app，见下文 SOP）；ILA 波形（等所有 RTL 优化定版后再抓）。

先读（按顺序）：
1) doc/reports/2026-10-16_p3_7_demo_lanebmem1.md   ← §7 下一步账本（含优化候选表 + §7.1 队友 SOP）
2) doc/reports/2026-10-16_handoff_p3_6.md          ← 上一条线 + §6 坑
3) doc/reports/2026-10-16_p3_6_margin_plan.md      ← 关键路径三处瓶颈的全量数据
4) doc/paper/论文框架_v1_20261012.md §0/§0.1（唯一数字口径）+ §3（章节提纲）+ §4（图表空位）+ §5（完稿前置）
5) doc/skills/riscv-cpu-fpga/SKILL.md §1（口径锚）+ §8（避坑）

(A) CPU 优化 —— 建议顺序（每条都走"先仿真对拍 → 再 PDS → 再全量回归 → 再上板"）
 A1【效率，收益最大】**lane B 放 store**（把 1 档的"lane B 放 load"对称到 store）。落点已探明（全在
    rtl/core/core.v）：lane B control 译码白名单 545-547；配对白名单/判据 810-812（p_opcode_b_ok）、
    756-757（p_ld_b 只有 load）、814-828（p_rd_b != 5'd0 等）；写口三条腿都缺 lane B ——
    335（mem_we）、1538-1564（mem_wdata / mem_byte_en）、353 地址 mux 已有 B 腿但只对读；
    974（ld_bad_st = id_ex_mem_write）要并上 lane B 那一支，否则 store→load 快通路会读旧值。
    硬约束：**每对至多一条访存**（827 的 !(p_mem_a && p_ld_b) 要改成同时禁 p_mem_b），
    且 dmem 只有一套写口（rtl/bus/mem_bus.v:52-55）⇒ 同拍不可能两条 store。
    预期 **+1~3%（先仿真数拍数，别拍脑袋）**；风险中（写口/前递/ld_bad_st 判据，错了是静默错值）
    ⇒ 必须 riscv-tests 49/1/0 + own_tests 6 + CoreMark 四 CRC 与 baseline 逐位一致 + rtthread/gomoku 端到端。
 A2【效率】**配对率扩展**：core.v:814-828。**先统计** CoreMark 里"因规则被拒的相邻指令对"占比（跑仿真加计数器），
    再决定放宽哪条 —— 每条放宽都要有等价性论证，别盲动。
 A3【效率】BTB 扩容（任务书 P1-3 建议 256→1024/4096）：硬编码在 core.v:638-640 / 776 / 1360（BTB 无参数），
    RAS_DEPTH=16 在 core.v:619。先估面积/Fmax 代价再决定（LUT 现 7,753 = 4.85%）。
 A4【Fmax，指标 2】只做确定性最高的那条：摘 **1.76 ns 跨模块投放线**（lane B load 数据源打一拍，
    见 margin_plan 的"关键路径三处瓶颈"）。注意访存延迟 +1 拍会改写每迭代周期数 ⇒ **217,088 要重测**，
    并同步三处口径。① 定向窄 region **不做**（上限 +0.02~0.05 ns，29% die 已有确定性负面前科）。
 A5【收口】任何 RTL 改动 ⇒ **DESIGN_REV 递增**；成功后 **两颗位流都要重出**（coremark + rtthread，
    都用 build_bitstream.ps1 唯一入口，.pds 保持钉 gplace_seed 5）+ **两颗都重新上板**（跑分四条判据 /
    演示四条判据）+ 五处口径同步 + bitstreams/README 登记 + 旧档降为历史参照。

(B) 论文正文（与 (A) 并行；建议先在"等 PDS/等仿真"的空档写）
 顺序：§3.3 第 3 章 微架构（重心：双发射配对规则、lane B 访存管道、RAS/BTB、EARLY_LD —— 把
 "设计—收益—代价"讲成闭环，含 0 档→1 档 +5.76% 这一级的完整链路）→ §3.6 第 6 章 性能分析
 （按 §0.1 的 1 档口径：391.66 / 4.6064 / Fmax 87.0549 / LUT 7,753 = 4.85%，**三个口径必须同时给**，
 主动讲"1 升 2 降"）→ §3.5 第 5 章 验证（riscv-tests 49/1/0 + own_tests 6 + 四 CRC 逐位 + 板级四条判据，
 每一条都有可引用的日志）→ §3.1/3.2/3.4/3.8。
 §3.7 应用演示章 + §4 的照片/波形空位 **留到队友新版 app 与 ILA 之后**（现在别填）。
 铁律：论文里每个数字都要能在 §0/§0.1 找到同口径来源；改数字 = 五处同步。

队友新版 app 到的 SOP（本次先别准备录屏）：见本报告 §7.1 —— 只看 git diff / 守 gomoku_run 等接口面 /
.text 变了同步 expectLines / 重出 + 重上板 / **绝不烧他给的 .sbit**。RTL 没动 ⇒ CPU 域仍 +0.277 ns。

纪律与坑：
- 钉 gplace_seed（单 seed）时 P&R 阶段不出 .rtr ⇒ 用 scripts\capture_seed_timing.ps1 收（会从 report_timing 兜底）。
- 想拿多布局分布：把 .pds 的 gplace_seed 换回 gplace_times 8，只在流程空闲时改、跑完复核。
- 改 .ps1 必须保持 UTF-8 BOM（PS 5.1 否则按 GBK 读中文注释）。
- 长仿真按实测估时：本机 168 ms 仿真时间 ≈ 24 min 墙钟（iverilog 慢，后台 vvp 只拿到 ~7% 一核）。
- .sbit 的 md5 不是布局指纹；引用位流给"md5 + 来源报告 + 日志时间"三件套。
- 交付纪律：上板前重跑 build_bitstream.ps1（唯一入口，含 mem.hex sha256/行数守卫）；commit 不 push。
```
