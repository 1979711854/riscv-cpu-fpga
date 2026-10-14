# 交接说明 · CPU 优化线（B1-RAS/BTB 已上板，370.23 分）—— 2026-10-14 深夜

> [!] **数字口径提示**：本文写于 2026-10-14 23:5x。**当前唯一口径以 `doc/paper/论文框架_v1_20261012.md` §0
> （+ §0.1 提交档声明）与 `CLAUDE.md`「当前进度」为准**；本文是**交接快照**，数字会随后续工作变动，
> 以那两处为准。
>
> **给接手 CPU 优化线的队友。** 本会话完成：合并你 21:06 发的 `riscv-cpu-fpga_dualissue_20261014_cpu (2).zip`
> （B1-RAS/BTB + AMO-分支修复，`rev1020-1022`）→ Review → 重算 ITER → 五轮回归 → **重出跑分位流并上板通过**。
> 交接包即本仓库（含 `.git`），`.sbit` 不入库，**跑分位流需自行综合**（`scripts\build_bitstream.ps1 coremark`，默认 ITER 已是 4332）。

---

## 1. 一句话结论

**B1-RAS + B1-BTB 已上板坐实：370.23 CoreMark @ 85.0051 MHz**（位流 `f64b977`，`RTL=0x20261022`，
ITER=4332，`Total ticks 994,412,748` = 11.6980 s），较前一档 `bcd8fdd2`（365.93）**+1.17%**，
与 RAS 减少的 1.18% 周期精确吻合；四 CRC 与仿真逐位一致。**`f64b977` 即新提交档（跑分）。**

## 2. 当前基线（2026-10-14 23:39 上板口径，别再用旧数）

| 配置 | 怎么跑（仿真） | 每迭代周期 | 效率 CoreMark/MHz |
|---|---|---|---|
| **双发射 + `EARLY_LD` + RAS/BTB（板上口径）** | `run_coremark.ps1 -Iter 1 -EarlyLd` | **229,597** | **4.355** |
| 双发射 + `EARLY_LD=0` | 去掉 `-EarlyLd` | 252,730（**未含 RAS，未重测**）| 3.957 |
| 单发射 | 加 `-Single` | 303,140（同上）| 3.299 |
| 双发射 + I+D Cache | 加 `-DCache -ICache -EarlyLd` | 235,628（同上）| 4.244 |

* 板上实测：**370.23 分**（`f64b977`，日志 `doc/board/uart_20261014_233933.txt`）；板上 229,574.8 拍/迭代（仿真 229,597，−0.0097%）。
* 回归判据：riscv-tests **49 PASS / 1 FAIL(ma_data) / 0 TIMEOUT**（默认 + `-DCache -ICache -EarlyLd` 双口径都要）；
  自写 **5 PASS**（`btb_indirect`/`hi_fetch`/`tb_amo_cpu`/`exceptions`/`timer_irq`）；
  RT-Thread `-DCache -ICache` **PASS**（见 §4 的固件口径守卫）。
* **板上 ITER = 4332**（`build_bitstream.ps1` 默认值已同步；动拍数必须重算，约定 3）。

## 3. 时序口径（只认这一个数）

`pds/RV32I_1/report_timing/cpu_top_board.rtr` 的 Setup Summary，**只看 `clk|u_pll/.../CLKOUT0_Inferred → 自己`**：

| | WNS | 失败端点 |
|---|---|---|
| **CPU 域（唯一指标）** | **+0.034 ns** | **0 / 20,507** |
| CPU → 视频 | −1.046 | 21（**建模假象，修不了，别碰**）|
| 视频 → CPU | −0.189 | 1（同上）|

* 请求 85.0051 → 实测 **85.2515 MHz**。`Design Summary: Some Constraints Violated` 是那 22 条跨域假迹，
  **历届 85 MHz 生产档全都有，CPU 域 0 失败即达标**。别拿 `pnr` 每 seed 的 `Setup(Slow): −1.1xx` 判 CPU 时序
  （全设计最差，被假象主导）。
* **余量只剩 0.29% 周期**。往 `core.v` 加任何东西**之前**先想时序；更动后必须重跑 `build_bitstream.ps1`
  （或至少 `pds_shell -run report_timing`）重新量。**若吃成负：BTB 缩 64 项 → 仍负则 `BTB_EN` 默认 0**
  （`-DNOBTB` 可复现；CoreMark 已证 BTB 对跑分逐位中性，关掉不损失分数，只损失赛题点名项）。
* 资源：LUT **8,104 / 5.07%**（`f64b977` 综合实测；B1 前 7,482，RAS+BTB 代价 +622）。

## 4. [!] 纪律（本轮新产生 + 老纪律重申）

1. **RT-Thread 仿真的固件口径守卫（2026-10-14 实踩，白查一轮）**：`scripts/rtthread/build/` 的 hex 会被
   **板级构建覆盖**（76.5MHz / `HB_DELAY_MS=5000`）；`run_sim.ps1 -NoBuild` 拿它跑 100MHz 仿真 ⇒ 心跳 3.8 秒
   wall time 才出现、30ms 扫描窗等不到 ⇒ `[FAIL] 没看到主线程心跳`（**与 RTL 无关**）。
   已加守卫：`build.ps1 -Sim` 写 `build/.sim_build_ok`、板载构建删它；`-NoBuild` 缺标记直接 throw。
   **RT-Thread 仿真 FAIL，先确认固件是 `-Sim` 口径，再怀疑 RTL。**
2. **冻结拍自查清单**（`mem_ready_int=0` 拍上"只该发生一次"的副作用必须与"离开该级"同拍）：级间清零、
   CSR 写、`mret`、多拍单元使能、快照选源、**以及预测器更新/RAS push/BTB train**（B1 三项均已按此门控：
   `mem_ready_int && !mc_stall && !trap`）。`trap` 是唯一例外（无条件）。
3. **`fetch_addr` 是关键路径第一风险点**：任何预测目标只许折进**既有的 `p_target` 腿**，不许新增腿；
   目标校验只比 `rs1_val & ~1`，**不许把 `ex_target` 加法器（~2 ns）拽进去**（B1-RAS 实测量化过：
   直接比 `ex_target` ⇒ −0.271 ns / 66 失败端点）。
4. 改 RTL 三连：递增 `DESIGN_REV`（`csr_file.v`）→ 五轮回归（§2）→ 同步文档口径（`CLAUDE.md` +
   论文框架 §0/§0.1 + 本技能）。ITER 随拍数重算。`.ps1` 保持 UTF-8 BOM。

## 5. 剩余可做项（按性价比排序，均需先过 §3 时序关）

1. **演示档重出（推荐先做，~30 分钟）**：`8894cdcb`（RT-Thread 五子棋）还是 **rev1017** 的 RTL。
   功能与 rev1022 等价（Cache 关 + 无 AMO ⇒ `mem_ready_int≡1`，两处门控恒真），但交付口径应统一：
   `scripts\build_bitstream.ps1 rtthread` → 综合 → 上板看四条判据（banner / render 线程 / AI 线程 / `[hb]` 无断）。
   ITER 不涉及（rtthread 档时钟口径未动）。
2. **约定 45 剩余两项（`EARLY_LD` 扩展）**：基址在 EX（**+1.81%** 理论）/ 紧前是 store（**+0.71%**）。
   每项约需 0.43 ns 级时序代价 ⇒ **以现在 +0.034 ns 的余量，大概率要先做 §3 的后备动作或找到更省的写法**；
   **做之前先用 §4.3 的口径自检是否新增了 `fetch_addr` 腿**。
3. **明确不做**（v10/v11 已定，别回头）：A3 BHT 加大（+0.10% 已回退）、A0 修 CDC（死胡同）、
   A2 剩余 load-use（要 0.43 ns、余量不够）、**Cache 相关一件都不用做**。
4. **答辩/论文线**：口径已全部刷成 370.23（论文框架 §0/§0.1、CLAUDE.md、位流索引、技能两份副本）；
   "多层分支预测（静态后向 + 256 项 BHT + 16 项 RAS + 256 项 BTB）"的表述已有 `btb_indirect.S` +
   `+BTBTRACE` 探针证据（开 15/15 对 `-DNOBTB` 0/0，`btb_indirect` 省 16 拍）。

## 6. 关键文件位置

| 东西 | 位置 |
|---|---|
| 上板日志（370.23） | `doc/board/uart_20261014_233933.txt` |
| 跑分位流（归档） | `pds/RV32I_1/bitstreams/coremark_dual_aext_ms_earlyld_a1_ras_btb_85mhz_rev1022_f64b977.sbit` |
| 集成/综合全过程 | `doc/reports/2026-10-14_integrate_b1_ras_btb.md` |
| 任务书（B1 四项已完） | `doc/reports/2026-10-14_taskbook_v11_cpu.md` |
| 数字唯一口径 | `doc/paper/论文框架_v1_20261012.md` §0 / §0.1 |

> 会话结束状态：`dualissue` 分支，最新提交 `b9fd5d3`（位流归档+口径）+ 本次交接书提交；**未 push**（按纪律不自动 push）。
