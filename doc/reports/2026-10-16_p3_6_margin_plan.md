# P3.6 计划：把 1 档 @85 MHz 的 CPU 域余量从 `+0.014 ns` 抬到 `≥ +0.3 ns`

> **目标（逐字）**：接 P3.5（HEAD `92d09d9`）。目标：把 1 档 `9b58e84c` 的 CPU 域余量从
> `+0.014 ns` 抬到 `≥ +0.3 ns`。先做零风险的 **②（多 seed / 逐 seed 读 CPU 域）**，
> 不够再做 **①（region/floorplan，工程当前零物理约束）**。
> 判据：**WNS ≥ +0.3 @85.0051 MHz 且 CoreMark 仍 `217,088` + 四 CRC**
> （② 不改 RTL 时只需重综合，不用重跑仿真）。
>
> 依据：`doc/reports/2026-10-16_session_state_p3_5.md`（§4.1 剩余大头 / §5 补余量建议 / §6 坑）
> 与 `doc/reports/2026-10-15_pce_region_result.md`（① 的负面前科）。
> **②/① 都不动 RTL ⇒ `DESIGN_REV` 保持 `0x2026_1027`，不递增（约定 42 只对改 RTL 生效）。**

---

## 0. 起点状态

| 项 | 值 |
|---|---|
| 位流 | `bitstreams/coremark_dual_noaext_ms_earlyld_a1_ras_btb_lanebmem_85mhz_rev1027_9b58e84c.sbit`（**未上板**） |
| CPU 域 @85.0051 MHz | WNS **+0.014 ns**（0 失败端点 / 19,083）；可达 Fmax 85.1064 MHz；LUT 7,753 / FF 3,691 |
| 功能 | CoreMark `217,088` + `e9f5/e714/1fd7/8e3a`；own_tests 6/0；riscv-tests 49/1/0；RT-Thread 四配置全 PASS |
| 对照 | rev1023 交付档 `55fae69e`：WNS +0.330 ns / Fmax 87.4585 MHz |
| 物理约束 | **零** —— `.pds` 的 `wgt_edit_placement_cons` 只引用 `device_map/cpu_top.pcf`，该文件 **0 行 region**（已核） |

**要补的缺口**：`+0.014 → +0.3` = **0.286 ns**（占 11.764 ns 周期的 2.4%）。
关键路径（§4.1）：`D-RAM 读 → ld_early_val → rs1_val → ALU 的 lt 比较链 → branch_taken →
ex_resolve_taken → if_addr_d → imem_addr → imem_addr2 → BRAM ADB0`（15 级，Logic/Route 约 40/60）。

---

## 1. 判据与读法（**唯一真判据**，别读错两列）

```powershell
# CPU 域 WNS：Setup Summary(Slow Corner) 里 launch == capture == clk|u_pll/u_gpll/CLKOUT0_Inferred 那一行
pds\RV32I_1\report_timing\cpu_top_board.rtr      # 现第 65 行 = 0.014（第 63-65 行块）
pds\RV32I_1\place_route\seed_<n>\cpu_top_board.rtr   # 逐 seed 的同一行（现只有 seed_6）
```

* `place_route/multiseed_result.csv` 的 **`Setup(Slow)` = 跨域 CPU→`pix_clk`**（本批 `−1.074 … −1.098`），
  **不是 CPU 域**；`Worst Slack(place)` 是 place 期的 **ps** 值 —— **这两列都不能给 seed 排 CPU 域的序**。
* 跨域 `−1.074 ns / 21 端点` 是**既有伪影**（2026-10-04 即 −1.283），**它永远不会满足 `≥ +0.3`**，
  所以"WNS ≥ +0.3"一律按 **CPU 域那一行**读。

---

## 2. ② 多 seed / 逐 seed 读 CPU 域（**先做，零风险**）

**依据**：`multiseed_result.csv` 的选种口径是 **"全设计最差"**（= 跨域伪影），**不保证 CPU 域最优** ——
本次 8 seed 里 `Best Seed = 6`；而 **P2 实测 seed 间 CPU 域波动达 6 MHz**
（77.67 / 80.44 / 83.83 / 82.97），⇒ **0.286 ns 的缺口完全落在种子散布内**。

**现状配置**：`RV32I_1.pds` 的 `cmd_pnr` 只有 `gplace_times=8` + `parallel=4`，**没有 `saved_outcome`**。

**关键障碍**：P&R 结束时**只保留被选中的那个 seed 的工作目录**（现只剩 `place_route/seed_6/`），
其余 7 个已删 —— 所以"逐 seed 读 CPU 域"**拿不到数据**，先解决取证，再谈收益。

| 备选 | 做法 | 代价 / 判定 |
|---|---|---|
| (i) 试 `saved_outcome` | 在 `cmd_pnr` 加 `(_option saved_outcome (_integer 1))`（10-10 记录里它和多 seed 选项同批出现，语义**待自证**） | 一轮 P&R 就能拿 8 份；**判据**：跑完 `Get-ChildItem place_route/seed_*` 是否出现 `seed_0..7` 且各带 `cpu_top_board.rtr` |
| (ii) 跑动中拷出 | P&R 期间轮询 `place_route/seed_*/cpu_top_board.rtr`，落地一份拷一份 | 只读、无风险，但**有竞态**（PDS 删目录很快）；配合日志看时序 |
| (iii) 抽样重跑 | 拉大 `gplace_times`（8 → 16/32）反复抽布局，每轮只拿"被选中那个"的 `.rtr` | 最慢（每轮整跑 P&R），但**零风险、零新知识**，兜底用 |

**纪律**：

* 不改 RTL ⇒ **不递增 `DESIGN_REV`**；**不重跑仿真**（RTL 与综合网表逐位不变，只有布局变）。
* 选中的 seed 必须**重出位流**（`scripts\build_bitstream.ps1 coremark`，仍走 `run_coremark -SkipSim`）
  并归档（文件名带新 md5 前缀）；**引用余量必须写明是哪一轮跑的**（技能 §5）。
* 上板前照旧重跑 `build_bitstream.ps1` + 核对 `mem.hex` 行数守卫（CoreMark `17104` 行，
  `expectLines` 拦下就别放宽），再上板跑一轮 CoreMark 才算闭环。
* 只认"**CPU 域那一行**"≥ +0.3 才算 ② 成功；选出来的 seed 若比 `seed_6` 更差 ⇒ 保留 `9b58e84c`。

---

## 3. ① region / floorplan（不够再做；**已有负面前科，且必须窄**）

**2026-10-15 已经试过一次并判死**（`2026-10-15_pce_region_result.md`）：
把 `u_soc/u_core` + `u_soc/u_bus/u_mem` 框进同一块区域（**约 29% 的 die**）⇒
`u_pll` slack **+0.034 → −0.755 ns**（可达 85.25 → 79.88 MHz）；连**不在区域里**的 `u_video`
也被从 190.37 拉到 175.69 ⇒ **整个布局被搅动**。且 PDS 在同约束下**确定性**（还原后逐位相同）
⇒ 那次 −0.789 ns **100% 归因于约束**（不是 P&R 噪声）。

* **⇒ ① 不能重复"大区域"**：本设计最大的一块是 **布局距离**（`imem_addr2 → BRAM ADB` 长线 **1.236 ns**），
  要做就做**定向/窄**约束（对准 `u_core` 与 `u_mem` 之间那条网线，或单点相对位置，而不是把两个模块塞进一小块）。
* **止损线照抄 10-15 的判据表**：只跑一轮；CPU 域那一行**没改善就停**，如实记录，不再投入第二轮。
* **已试通的做法（省一轮踩坑）**：
  1. PDS 会**覆盖**你放进工程的 pcf —— 仅在 `_input` 下放一份、把 `target_file` 改 OFF **没用**
     （PDS 把它当默认覆盖目标，写回 1912 字节自动产物，`flow.log` 只留一行 `W: Public-4010: Pcf file ... has been covered.`）。
  2. **正解**：`_input` 下**放两份** —— 主那份显式 `target_file ON`（去承接覆盖），
     region 那份**纯输入**；**且 region 那份里不得有 `def_port`**（含端口 LOC ⇒
     `E: PhysicalConstraintEditor-0013: R25 is already placed`，**8/8 seed 全失败、出不了位流**）。
  3. 判据：跑完 grep `flow.log` 的 `has been covered`，**它指向哪个文件、就是哪个文件被覆盖了**。
  4. GUI 取坐标（绕开"器件网格尺寸拿不到"）的步骤见 `2026-10-15_pce_region_attempt.md` §2。
* **现场遗留**：`pds/RV32I_1/cpu_top_region.pcf`（435 KB / 6575 行 region）与 `cpu_top_region1.pcf`
  仍在目录里（gitignore、不进仓库）—— 那是**失败实验的产物，当前不被 `.pds` 引用**，
  别看到它以为约束还生效着。
* 收尾：无论成败，`.pds` 的 `wgt_edit_placement_cons` 与 `device_map/cpu_top.pcf` **都要还原/记录**，
  并留下"哪一版有约束、哪一版没有"的取证（`flow.log` 的覆盖行 + `prr` 的约束清单）。

---

## 4. 若 ②① 都不够（登记，不在本次范围）

* §4.1 剩余大头（按量级）：BRAM `tco 1.644 + net 2.143`（前端，固定）、ALU `lt` 比较链 4 级（≈0.8 ns）、
  `imem_addr2 → BRAM ADB` 长线 **1.236 ns**（布局距离 → 正是 ① 的靶子）。
* 保底档：PLL `RATIO0=14.0` ⇒ 81.97 MHz / 预计 slack ≈ +0.27 ns / **377.6 分**（改频三处联动 + 重算 ITER，
  见 `2026-10-16_handoff_p3.md` §(保底)）。
* 不动：`pair_now`、`fetch_addr` 新增 mux 腿（任务书 §8.6 明令）。

---

## 5. 命令速查

```powershell
# ②/① 都只需重综合（RTL 未改）
scripts\build_bitstream.ps1 coremark                       # P&R 多 seed + report_timing + 位流
Get-Content pds\RV32I_1\place_route\multiseed_result.csv   # 只是选种口径（跨域），别当 CPU 域
# CPU 域那一行：
Select-String -Path pds\RV32I_1\report_timing\cpu_top_board.rtr -Pattern 'u_gpll/CLKOUT0_Inferred'
# 逐 seed（若 ② 的取证方案生效）：
Get-ChildItem pds\RV32I_1\place_route\seed_*\cpu_top_board.rtr
# 上板前（功能口径未变，仍要求一轮板上 CoreMark 闭环）
scripts\serial_monitor.ps1
```

**不做**：改 RTL / 递增 `DESIGN_REV` / 重跑仿真回归 / push（项目纪律）。

---

## 6. 方向② 实测记录（2026-10-16 下午；**RTL 未改**，仍是 `DESIGN_REV=0x2026_1027`）

**构建口径自证**：`pds/RV32I_1/mem.hex` 与 `sim/programs/mem.hex` **sha256 逐字节一致**
（`3C06B46F…465E`，17104 行）；`cpu_top_board.v: DEBUG_LED=1`；`cpu_top.v: DUAL_ISSUE=1 /
EARLY_LD=1 / LANEB_MEM=1 / A_EXT=0 / DCACHE_EN=ICACHE_EN=0`；`LANEB_MEM` 1 档。

### 6.1 三条取证事实（比预想更硬，直接决定后面怎么做）

1. **`saved_outcome` 无效（方案 i 判死）**：写进 `cmd_pnr` 后跑完一轮，PDS **把该键从 `.pds` 里删掉**
   （只剩 `gplace_times`/`parallel`），日志里逐条
   `I: Seed N: Work directory "…" has been removed.`（除被选中的那个）⇒ 保留全部 seed 目录做不到。
2. **"跑动中抢拷"可行且已跑通（方案 ii 采用）**：P&R 期间每 **4 s** 轮询
   `place_route/seed_*/cpu_top_board.rtr`，出现即拷出。本次 24 个 seed 的 `.rtr` **全部拿到**。
   * 竞态就一次：某次拷到 **0 字节**（正在写）⇒ 判据是"长度 > 1 KB 才拷"，跑完再从被保留的
     `seed_<best>/` 重拷。**这个抢拷脚本值得固化成 `scripts/` 里的工具**（每轮 P&R 都要用）。
   * `report_timing/cpu_top_board.rtr` 在整个 P&R 期间**不更新**，只在最后（`gen_bit_stream`）生成一份
     ⇒ **别读它来排 seed**，要读 `seed_*/` 里那份。
3. **`gplace_seed` = 起始 seed，可用于钉住布局**（已自证两次）：
   * `gplace_seed 5` + `gplace_times 1` ⇒ 单 seed 模式（结果直接落 `place_route/`，**不再有 `seed_*/`**），
     CPU 域 **+0.277 ns / 可达 87.0549 MHz**，与采样轮 seed_5 **逐位相同**；
   * `gplace_seed 8` + `gplace_times 8` ⇒ 拿到 **seed_8..15**（是"起始号"不是"唯一号"）。
   * [!] 两个坑：**① 改 `.pds` 必须在流程没在跑的时候改** —— PDS 跑完会重写 `.pds`
     （实测把 `gplace_seed 16` 冲回 `8`）；**② `gplace_times 1` 会被 PDS 删掉**（单 seed 是默认态）。
   * 还有一组对称的 route 选项：`groute_times / groute_seed / route_seed_step / route_parallel /
     route_saved_outcome`（见 §6.4）。

### 6.2 24 个 seed 的 CPU 域余量（@85.0051 MHz，判据行 = Setup Summary 里 launch==capture==`clk|u_pll/u_gpll/CLKOUT0_Inferred`）

| seed | 5 | 16 | 1 | 15 | 14 | 18 | 17 | 0 | 6 | 10 | 22 | 23 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **WNS (ns)** | **+0.277** | +0.229 | +0.181 | +0.166 | +0.161 | +0.119 | +0.049 | +0.037 | +0.014 | −0.014 | −0.017 | −0.018 |

| seed | 11 | 12 | 13 | 7 | 4 | 8 | 20 | 2 | 9 | 21 | 19 | 3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **WNS (ns)** | −0.018 | −0.021 | −0.035 | −0.054 | −0.061 | −0.066 | −0.111 | −0.114 | −0.119 | −0.133 | −0.166 | −0.254 |

* 分布 **−0.254 … +0.277 ns**（极差 0.531 ns，中位 ≈ −0.02），**24 个里没有一个 ≥ +0.3**。
* 与 0 档的对照：同一版 RTL 在 0 档（`LANEB_MEM=0`）是 +0.330 ns（rev1023）⇒
  **1 档的余量缺口约 0.29–0.32 ns 是"结构性的"（lane B 逻辑），不是种子运气**；换布局只能买回 ~0.26 ns。

### 6.3 [重点] PDS 的选种口径**在这颗设计上是错的**（三次实证）

`multiseed_result.csv` 按 `Setup(Slow)`（= **跨域 CPU→`pix_clk` 伪影**，本批 −1.07…−1.21）排序选 seed：

| 轮次 | PDS 选中的 seed | 该 seed 的 CPU 域 WNS | 同批 CPU 域最优 |
|---|---|---|---|
| 第 1 批（seed 0..7） | **6** | +0.014 | **seed_5 +0.277** |
| 第 2 批（seed 8..15） | **15** | +0.166 | seed_5 +0.277（另：seed_16 属下一批 +0.229） |
| 第 3 批（seed 16..23） | **20** | **−0.111（时序不过！）** | seed_16 +0.229 |

⇒ **照 PDS 默认流程出位流，会拿到 CPU 域 −0.111 ns 的不可交付品**（第 3 批那颗 = `??`
未归档，只做证据）。**结论：1 档出位流必须"先逐 seed 读 CPU 域、再钉 `gplace_seed`"。**

### 6.4 现状与中间产物

| 产物 | CPU 域 WNS | 可达 Fmax | 位流 md5 | 说明 |
|---|---|---|---|---|
| P3.5 交付候选（seed_6，PDS 默认选种） | +0.014 ns | 85.1064 MHz | `9b58e84c` | 归档、未上板 |
| **钉 seed_5（当前最优）** | **+0.277 ns** | **87.0549 MHz** | `2e966285` / `c1b7e279` | 同一布局的两次构建；**`c1b7e279` 是最终归档那颗**（§6.11） |
| 第 2 批 PDS 默认（seed_15） | +0.166 ns | — | `241c4aa0` | 仅证据 |
| 第 3 批 PDS 默认（seed_20） | −0.111 ns | — | — | **时序不过**，仅证据 |

* 逐 seed 的 `.rtr` 证据：`pds/_capture_p36/seed_<n>_cpu_top_board.rtr`（40 个）+
  `pds/_capture_p36/route_sweep/`（同一布局 8 个 route seed）+ `baseline_seed6_rtr_before.txt`。
* **阶段性结论**：方向② 单靠"换布局 + 钉 seed"把 1 档余量从 **+0.014 → +0.277 ns（18×）**，
  Fmax 85.1064 → **87.0549 MHz**（已回到 rev1023 的 87.46 量级），**但离判据 +0.3 还差 0.023 ns**。

### 6.5 [新发现][!] 位流 md5 **不是**布局指纹

seed_6 的布局两轮完全相同（`cpu_top_board.rtr` 除 8 行运行元数据 = `Date` / CPU time / Peak memory
外**逐行相同**，坐实 P&R 确定性），但 `.sbit` 的 md5 从 `9b58e84c` 变成 `28f8ae6b`。
⇒ **引用位流 md5 时只能当"这一次构建的名字"，不能用它判"布局是否相同"**（判布局要看 `.rtr` / `.adf`）；
也意味着 P3.5 归档名里的 `9b58e84c` **不可复现**（同一布局再跑一次就是另一个名字）。

### 6.6 钉布局 + 扫 route seed（已做）：**换路由换不出余量**

动机：CPU 域关键路径 route 占 ~60%，末端就是 `imem_addr2 → BRAM ADB` 的 **1.236 ns 长线**，
所以"同一布局、只换布线 seed"值得一试。做法：`gplace_seed 5`（钉住最优布局）
+ `groute_times 8` + `route_parallel 4`（PDS 把 `groute_seed/route_seed_step/route_saved_outcome`
当默认值删掉，保留 `groute_times`）。

同一布局（8 份报告 `totalEP` **全 = 19114**，与 seed_5 一致 ⇒ 确实是同一 placement）：

| route seed | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| **WNS (ns)** | **+0.277** | +0.114 | +0.151 | +0.213 | +0.151 | +0.218 | +0.168 | +0.152 |

* **没有任何 route seed 超过 +0.277**（= place+route 同为 seed_5 的值）⇒ **route 变化只能让余量变差**。
* PDS 又一次按跨域口径选中 **route seed 2（+0.151）**，而该布局真正最优是 route seed 0（+0.277）
  ⇒ §6.3 的"选种口径错"在 route 维度**同样成立**（两轮跑结果逐位重复，确定性）。

### 6.7 第 4 批（seed 24..39，16 个布局）：tail 也够不到 +0.3

| seed | 28 | 33 | 26 | 35 | 31 | 25 | 38 | 37 | 32 | 30 | 39 | 36 | 27 | 24 | 29 | 34 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **WNS (ns)** | +0.184 | +0.130 | +0.101 | +0.068 | +0.051 | −0.043 | −0.052 | −0.075 | −0.091 | −0.100 | −0.123 | −0.149 | −0.187 | −0.223 | −0.244 | −0.376 |

* **累计 40 个 place seed：max 仍是 seed_5 的 +0.277**，第 2 名 +0.229，第 3 名 +0.184
  ⇒ 分布右侧有明显的**软顶**（≈ +0.28），**没有一个 ≥ +0.3**。
* 第 4 批 PDS 选的是 **seed_32（CPU 域 −0.091 ns，时序不过）** —— §6.3 的口径错误第 4 次复现。

### 6.8 优化开关：PDS 没有偷懒（干净的反证）

把官方示例里那 5 个开关显式打开（`optimize_multi_corner_timing` / `fix_hold_violation` /
`optimize_gp_recovery` / `optimize_dp_recovery` / `optimize_rp_recovery`，全部 `ON`）后，
**结果与关着时逐位相同**（+0.277 ns / failEP 0 / totalEP 19114，布局未变）
⇒ **这些开关本来就在生效**，② 不是"工具没用力"造成的。

* 附带发现：`(_option optimize_hf_by_copy (_switch ON))` **被 PDS 写回时删掉** ⇒ 本版本不认这个键名
  （想复制高扇出网驱动得另找键名，见 §6.10）。
* [!] **钉 `gplace_seed 5` 的副作用**：进入单 seed 模式后 **`place_route/multiseed_result.csv` 不再产生**
  （`.pds` 里那条输出项也被删）。⇒ 交付档 `c6af65be` **没有** multiseed csv 可查；
  要看多布局分布请用 §6.2/§6.7 的表 + `pds/_capture_p36/seed_cpu_wns_summary.csv`（本地证据）。
* **口径提醒**：`.pds` 里只留非默认选项；**PDS 每次跑完都会重写 `.pds`**
  （本次把我手工加的 `gplace_seed 16` 冲回 `8`、把 `gplace_times 1` 删掉）⇒
  **改选项必须在流程空闲时做，且每次跑完要复核一遍**。

### 6.9 关键路径诊断（+0.277 ns 那版，`Logic 4.522 / Route 6.620`，14 级）

```
Start  u_video/u_core/u_pat/mem_1_3/gopdrm_36k/CLKA      ← 视频域调色板 DRAM
  DRM(490,336) tco 1.644 → net 1.760  pat_q[23]          ← ★ 跨模块长线（u_video → u_soc）
  → vid_rdata → load_half_b[7] → load_data_b → wb_data_b[21]
  → rs2_val[21] → ALU 的 lt 比较链(N590.eq…) → branch_taken
  → ex_resolve_taken → if_addr_d[5] → imem_addr[3] → imem_addr2[12]
  net (fanout=16) 1.201 → ADB0[13]  DRM(490,888)          ← ★ 高扇出长线（→ u_mem 的 16 个 ADB）
Data arrival 16.032 ; 时钟树插入 net(fanout=3140) 1.615    ← ★ 时钟分布也吃掉一块
```

⇒ 剩余可动的只有三处：**跨模块投放线 1.76 ns**、**ADB 高扇出线 1.20 ns**、**时钟树 1.62 ns**。
② 只能换布局（已到顶）；要到 +0.3 只剩 **定向物理约束（①）** 或改 RTL（不在本轮）。

### 6.11 结论与交付（方向② 收口）

**结论：② 的上限 = `+0.277 ns`（place seed 5），可达 87.0549 MHz。**
四条路都试过了，**没有一条能过 +0.277**：40 个 place seed（max +0.277）/ 同一布局 8 个 route seed
（max +0.277）/ 5 个官方优化开关全开（逐位不变）/ `place_ignore_high_fanout_net=OFF`（逐位不变，
且该键被 PDS 丢弃）。相对 P3.5 的 `+0.014` 是 **+0.263 ns（18×）**，相对判据 `+0.3` **差 0.023 ns（0.2% 周期，未达）**。

| 交付候选 | 值 |
|---|---|
| 位流 | **`bitstreams/coremark_dual_noaext_ms_earlyld_a1_ras_btb_lanebmem_85mhz_rev1027_seed5pin_c6af65be.sbit`**（= `generate_bitstream/cpu_top_board.sbit`，**由 `scripts\build_bitstream.ps1 coremark` 在 15:36–15:45 走完整条唯一入口重出**：固件重建 → `mem.hex` sha256 校验 → 综合 51 s → P&R → 出位流，共 9 分 39 秒） |
| CPU 域 | WNS **+0.277 ns**（0 失败端点 / 19,114）、请求 85.0051 → 可达 **87.0549 MHz**（周期 11.764 / 11.487）、LUT 7,753 / FF 3,691 |
| RTL / 固件 | **未改**（`DESIGN_REV=0x2026_1027`）；`git status` 只有 `.pds`（`gplace_seed 5` + `_timespec`）与文档；**`mem.hex` sha256 `3C06B46F…465E` / 17104 行 = 与 P3.5 逐字节相同**（守卫通过） |
| 功能 | 与 P3.5 **逐位相同**（CoreMark 217,088 + 四 CRC）；⚠ 按纪律，**交付前仍需板上跑一轮**（见 §7） |

> **md5 沿革（同 RTL、同布局，纯构建名不同）**：`9b58e84c`（P3.5 的 seed_6 布局，+0.014）→
> `2e966285` / `c1b7e279`（第一次钉 seed_5 的两次构建）→ **`c6af65be`（最终交付档，走完标准入口）**。
> 中间那两颗已从 `bitstreams/` 删掉，避免同一布局留多个归档名。

**复现"钉住 +0.277 布局"的那一步**（`pds/RV32I_1/RV32I_1.pds` 的 `cmd_pnr`，单 seed 模式）：

```
(_option gplace_seed (_integer 5))      # 替换原来的 (_option gplace_times (_integer 8))
(_option parallel (_integer 4))
```

* 本会话结束时已把 `.pds` **还原成提交态（多 seed 默认）**：要不要把 `gplace_seed 5` 钉进仓库
  是一个**策略决定**（钉住 = 复现得到 +0.277；不钉 = 默认流程会挑到 +0.014 的布局，见 §6.3）。
* PDS 每次跑完都会重写 `.pds`（含 `_timespec`）——**改选项前先确认流程没在跑**（§6.8）。

### 6.12 [!] 位流身份的两个新坑（务必写进口径）

1. **`.sbit` 的 md5 不是布局指纹**：同一布局两次构建得到 `9b58e84c` / `28f8ae6b`；
   再跑两次同一布局得到 `2e966285` / `c1b7e279`（同 RTL、同固件、`.rtr` 除 `Date` 行外逐行相同）。
2. **`DESIGN_REV` 不变而位流变了**：串口首行 `[build] FW=COREMARK RTL=0x20261027` **区分不出**
   `9b58e84c`（+0.014 ns）与 `c1b7e279`（+0.277 ns）⇒ 判"板上烧的是哪颗"只能靠 md5 + 本表。

### 6.13 没做的（决策点）

* **① region/floorplan**：按计划该转它，但**坐标拿不到** —— `pce.exe` 的 CLI 未通、器件 `.eval` 加密、
  `.adf` 是二进制 ⇒ 必须进 **PCE GUI 框选**（`2026-10-15_pce_region_attempt.md` §1/§2）；
  且已有**确定性负面前科**（29% die 的大区域 ⇒ u_pll slack `+0.034 → −0.755`，10-15 报告 §2）。
  要动的三处见 §6.9（跨模块投放线 1.76 ns / ADB 高扇出线 1.20 ns / 时钟树 1.62 ns）。
* 继续采样 place seed：40 个样本的 max 是 +0.277、软顶 ≈ +0.28 ⇒ 命中 +0.3 的概率很低，
  只值墙钟时间（每 8 个 seed ≈ 10 min）。
* 未 push、未提交（项目纪律：等一次把 `.pds` + 文档一起提交）。

---

## 7. 上板验证（交付档 `c6af65be`）：**[OK] 已通过（2026-10-16 15:56）**

日志 **`doc/board/uart_20261016_155605.txt`**（20 行，一次跑完）：

| 判据 | 实测 | 结论 |
|---|---|---|
| 版本自证 | `[build] FW=COREMARK RTL=0x20261027` | ✓（**与 `9b58e84c` 同 REV ⇒ 只能靠 md5 区分**）|
| `Total ticks` | **940,200,316** ÷ 85,005,100 = **11.0605 s** | ✓ 得分 **391.66**（`Iterations 4332`）|
| 拍/迭代 | **217,036.1**（仿真 217,088） | ✓ 差 **−0.0239%**（模型口径 ±0.04% 内）|
| 四 CRC | `e9f5 / e714 / 1fd7 / 8e3a` | ✓ 与仿真逐位一致 |
| `Correct operation validated` | 有 | ✓ |
| 有效性 | 11.0605 s **≥ 10 s** | ✓（余量 10.6%；0 档 17.0%）|

⇒ **1 档（`LANEB_MEM=1`）+ 钉 seed 的交付档首次上板即通过，得分 370.31 → `391.66`（+5.76%）**；
跨域伪影与 0 档无关，未出现任何异常。**这一步同时把 P3.5/P3.6 的功能判据（217,088 + 四 CRC）在硬件上闭环。**

### 7.1 上板清单（已执行，留作下次照抄）

1. **烧前先看板子**：`led[0]=pll_locked` 是否亮；**别按 SW2/D22**（那是 FPGA 配置键）；
   真复位是 **SW3**；板子断电即丢配置（两灯不亮先问"是不是没重烧"）。
2. **Programmer**：器件 `PG2L200H`，**每次重新 `Assign New Configuration File`**，
   文件固定选：
   `pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`（= 归档的 `…_seed5pin_c6af65be.sbit`；
   **别用 `bitstreams\` 里的旧文件**）；JTAG 与 USB-UART **两根 USB 线都要插**。
3. **抓串口**（一轮只有 ~11 s，慢一拍就错过）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60
   ```
   日志自动落盘 `doc/board/uart_<时间戳>.txt`（判读记录写进 `doc/board/README.md` 末尾）。
4. **板上判据**（全部要对）：

   | 判据 | 期望值 | 说明 |
   |---|---|---|
   | 版本自证行 | `[build] FW=COREMARK RTL=0x20261027` | **与 `9b58e84c` 同 REV** ⇒ 它区分不出这两颗，只有 md5 能（§6.12） |
   | `Total ticks` | **≈ 940,425,216**（= 217,088 × 4332；板上 ±0.04% 属正常） | 见下面 [!] |
   | 四 CRC | `seedcrc 0xe9f5` / `crclist 0xe714` / `crcmatrix 0x1fd7` / `crcstate 0x8e3a` | `crcfinal` 随 ITER 变，**不比** |
   | 有效性 | `Correct operation validated` + 真实秒数 **11.06 s ≥ 10 s** | 真实秒数 = ticks ÷ **85,005,100** |
   | 得分 | **391.6**（= 85.0051e6 ÷ 217,088）；主分口径 = **4.6064 CoreMark/MHz** | 日志里的 `Iterations/Sec` 是 `HAS_FLOAT=0` 的整数截断假值，别引用 |

5. 烧完把日志路径 + 实际 ticks/CRC 回填到本文（或 `doc/board/README.md`），并同步技能 §1 的口径行。

> [!] **`build_bitstream.ps1` 打印的期望值是 0 档口径，别照抄**：脚本里
> `$cpiCycles = if ($dualIssue -eq 1) { 229597 } else { 303140 }` **没有考虑 `LANEB_MEM`**
> ⇒ 它会打"期望 ≈ 994,614,204 ticks / 370.2 分"，而 1 档的真实值是
> **940,425,216 ticks / 391.6 分**。**这是脚本的口径 bug（待修）**，修法照抄它读 `DUAL_ISSUE`
> 的那段：从 `rtl/top/cpu_top.v` 读 `parameter\s+LANEB_MEM\s*=\s*(\d+)`，
> 为 1 时用 `217088`。**改 `.ps1` 必须保持 UTF-8 BOM**（PS 5.1 否则按 GBK 读、中文注释会吃掉引号配对）。

## 8. 遗留（下次）

* 上面那条 `build_bitstream.ps1` 的 `cpiCycles`/得分口径（1 档应是 217,088 / 391.6）。
* `run_coremark.ps1` 在 PS 5.1 下被 vvp stderr 警告打断（P3.5 §6，仍待修）。
* ①（region/floorplan）要进 PCE GUI 取坐标才能做，且带 10-15 的确定性负面前科（§6.13）。
* `pds/_capture_p36/`（逐 seed 证据 + 抢拷脚本套路）尚未固化成 `scripts/` 里的工具 ——
  下次换档还要用，建议连同"抢拷"逻辑一起做成一个 `.ps1`。

### 6.10 最后一张纯②牌：把高扇出网纳入布局优化 —— **也无效**

钉 seed_5 + `place_ignore_high_fanout_net = OFF`（若默认为"忽略高扇出网"，那根 fanout=16 的
ADB 网在布局阶段就不被优化）：**结果仍逐位相同**（+0.277 ns / failEP 0 / totalEP 19114），
且该键**被 PDS 写回时丢弃** ⇒ 要么本版本默认就是"不忽略"，要么键名/取值不对。
（连同 §6.8 的开关实验：**P&R 侧没有可再榨的旋钮**。）



