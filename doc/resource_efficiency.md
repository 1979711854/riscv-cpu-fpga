# 资源效率与性能指标（CoreMark / LUTs / Fmax）

> 对应赛题《FPGA 创新设计赛道选题指南（紫光同创）》选题一「性能测评标准 · 1. 性能指标」三条：
> 执行效率（CoreMark/MHz）、时钟频率（Fmax）、资源效率（CoreMark/LUTs）。
> 编制日期：2026-09-21　数据均为本仓库实测，来源逐项标注，可直接引用。

## 0. 一句话结论

| 指标 | 数值 | 赛题定位 |
|---|---|---|
| 执行效率 | **2.380 CoreMark/MHz** | 单发射顺序流水线的正常偏优水平 |
| 时钟频率 | **46.42 MHz**（约束 27 MHz，时序余量 72%） | 受远程平台 27 MHz 固定时钟限制，非设计上限 |
| 资源效率 | **1.035 CoreMark/MHz 每千 LUT** | LUT 仅占 1.44%，余量 98% |

---

## 1. 器件与工具

| 项目 | 值 | 来源 |
|---|---|---|
| 器件 | 紫光同创 Logos2 **PG2L200H-6IFBG676**（速度等级 -6） | `pds/RV32I_1/RV32I_1.pds` |
| 对应开发板 | 盘古 676 系列 MES2L676-200HP | 赛题指南「盘古 676 系列开发板」 |
| 工具 | Pango Design Suite **2022.2-SP6.4** | `multiseed_summary.csv` 首行 |
| 顶层模块 | `cpu_top` | 同上 |
| 实测时钟 | 27 MHz（远程 FPGA 平台固定） | `RV32I_1.fdc` |

---

## 2. 指标一：执行效率 CoreMark/MHz

### 2.1 赛题公式与等价换算

赛题式 (1)：`Score = CoreMark_Iterations / (Total_Time × Frequency)`

其中 `Frequency` 取 MHz、`Total_Time` 取秒，结果即 CoreMark/MHz。它与「每迭代周期数」是同一个量的两种写法：

```
CoreMark/MHz = 10^6 / 每迭代周期数
```

### 2.2 测量结果

| 口径 | 每迭代周期 | CoreMark/MHz | 来源 |
|---|---|---|---|
| **板上实测（权威口径）** | 294,065,438 / 700 = **420,094** | **2.380** | 远程平台 ITER=700 实测 |
| 板上实测（交叉验证） | 84,018,579 / 200 = **420,093** | 2.380 | 远程平台 ITER=200 实测 |
| 仿真（CoreMark 计时区间） | **420,070** | 2.381 | `+PROF` 本次实测 |

两个板级点独立测得 420,093 / 420,094，互差 1 个周期，口径自洽。

**板上与仿真差 24 周期 / 0.0057%** —— 行为级仿真模型与真实硬件的吻合度极高，
这一点本身就是结论：**后续所有仿真优化数据可以直接外推到板上**。

### 2.3 达到的实际得分

```
Score(27 MHz)   = 2.380 × 27      ≈  64.27 CoreMark（iterations/sec）
Score(46.42 MHz)= 2.380 × 46.4209 ≈ 110.50 CoreMark（若时序按更高频约束重跑）
```

赛题要求「运行时间不低于 10 秒」，本设计取 ITER=700：
`294,065,438 / 27 MHz = 10.891 秒`，余量 8.9%。**满足要求。**

> 注意口径陷阱：CoreMark 打印的 `Total time (secs): 10` 是整数截断，
> `Iterations/Sec: 70` 也是按截断后的 10 算的。真实值是 10.891 s / 64.27 次每秒。

---

## 3. 指标二：时钟频率 Fmax

来源：`pds/RV32I_1/report_timing/cpu_top.rtr`（PDS 时序分析报告）。

| 项目 | 值 |
|---|---|
| Requested Frequency | 27.0000 MHz（周期 37.037 ns） |
| **Estimated Frequency** | **46.4209 MHz**（周期 21.5420 ns） |
| Setup Slack (Slow corner) | **+15.495 ns** |
| Setup Slack (Fast corner) | +23.473 ns |
| Hold Slack (Slow / Fast) | +0.145 ns / +0.100 ns |
| 结论 | `Design Summary : All Constraints Met.` |
| TNS / 失败端点 | 0.000 / 0 |
| 收敛率 | Pass Rate 100% / Convergence Rate 100% |

**关键表述**：当前 `.fdc` 把时钟约束在 27 MHz（远程平台限制），时序余量高达 72%。
工具估计该设计在 -6 速度等级下可达 **46.42 MHz**。

> 这是文档里此前被漏掉的数字。早先 README / spec / test_report 只写了
> 「27MHz 下 Setup +15.495ns」，把最有信息量的一半丢掉了 —— 应改为
> **「约束 27 MHz，可达 46.42 MHz，余量 72%」**。

**Fmax 不是本设计的上限**，而是被平台时钟卡住。若换成本地盘古板并使用板载晶振
（或经 PLL 倍频），有实测提分空间。赛题该项要求「在满足时钟约束的前提下能达到的
最高工作频率」，报告里应同时给出「约束频率」与「估计可达频率」。

---

## 4. 指标三：资源效率 CoreMark/LUTs

### 4.1 资源占用明细

来源：`pds/RV32I_1/multiseed_summary.csv` · Device Map 段。

| 资源 | 用量 | 总量 | 精确占比 | PDS 显示 | 主要来源 |
|---|---|---|---|---|---|
| LUT | **2,301** | 159,800 | **1.44%** | 2% | 流水线控制、ALU、译码 |
| FF | 1,914 | 319,600 | 0.60% | 1% | 级间寄存器、FIFO |
| DRM（块 RAM） | 16 | 415 | 3.86% | 4% | 统一存储器（32KB 双端口 BRAM） |
| APM（DSP） | 11 | 740 | 1.49% | 2% | ALU 乘法器（M 扩展） |
| 分布式 RAM | 132 | 39,500 | 0.33% | 1% | 寄存器堆 32×32 |
| USCM | 1 | 32 | 3.13% | 4% | 时钟/全局资源 |
| HCKB / RCKB | 0 / 0 | 120 / 40 | 0 / 0 | 0% | 未使用 |

> PDS 的 `Utilization(%)` 列是向上取整的，所以 1.44% 显示成 2%。
> 报告里建议同时给出精确值与 PDS 显示值，避免被质疑「2% 是不是虚报」。

### 4.2 资源效率计算

赛题未定义 `CoreMark/LUTs` 的精确口径（分子是归一化的 CoreMark/MHz 还是完整得分，
分母是 SoC 全部 LUT 还是仅 CPU 核）。**本设计同时给出两种口径，并声明主口径**。

| 口径 | 计算式 | 结果 |
|---|---|---|
| **A（主口径）**：归一化性能 / 千 LUT | 2.380 ÷ 2.301 | **1.035 CoreMark/MHz 每千 LUT** |
| B：完整得分 / 千 LUT（27 MHz） | 64.27 ÷ 2.301 | 27.93 CoreMark 每千 LUT |
| B′：完整得分 / 千 LUT（46.42 MHz） | 110.50 ÷ 2.301 | 48.02 CoreMark 每千 LUT |

**为什么用 A 作主口径**：它与赛题四.1(1) 的 CoreMark/MHz 同源，剔除了平台固定
频率这个不可控变量，能纯粹反映「单位逻辑资源换取的流水线效率」，也便于与其他
队伍在同一天平上比较。

**分母口径声明（诚实起见）**：分母 2,301 LUT 是**整个 SoC 顶层 `cpu_top`** 的用量，
即包含 UART、GPIO、总线与统一存储器的控制逻辑 —— 没有只算 CPU 核。
理由是提交物是整个 SoC，且这样取值对评委最保守（分母偏大、效率偏低）。

---

## 5. 指标汇总（可直接抄进报告）

```
器件        : 紫光同创 Logos2 PG2L200H-6IFBG676
工具        : Pango Design Suite 2022.2-SP6.4

执行效率    : 2.380 CoreMark/MHz
              （ITER=700, Total ticks 294,065,438; 每迭代 420,094 周期 @27MHz）
时钟频率    : 约束 27.000 MHz / 估计可达 46.4209 MHz / Setup slack +15.495 ns
              All Constraints Met; TNS 0; 失败端点 0
资源占用    : LUT 2,301 (1.44%)  FF 1,914 (0.60%)
              DRM 16 (3.86%)     APM 11 (1.49%)
资源效率    : 1.035 CoreMark/MHz 每千 LUT
实际得分    : 64.27 CoreMark @27MHz（迭代 700 次 / 10.891 秒，满足 ≥10s）
```

---

## 6. 优化空间（由本次剖析数据支撑，详见 `doc/ila_analysis.md`）

CoreMark 计时区间（420,070 周期）内，**31.4% 的周期被浪费在控制冒险与数据冒险上**：

| 来源 | 损失周期 | 占计时区间 |
|---|---|---|
| 分支/跳转冲刷（37,098 次 × 3 拍） | 111,294 | **26.5%** |
| load-use 停顿 | 20,720 | 4.9% |
| 除法停顿 | 0 | 0% |
| 合计 | 132,014 | **31.4%** |

理论上限（假设完全消除这两类损失）：`10^6 / 288,056 = 3.472 CoreMark/MHz`，
即当前 2.380 的理论天花板是 3.472。**首要优化目标是分支冲刷**（单项占 26.5%），
且资源余量充足（LUT 仅用 2%），有空间加分支预测器。

---

## 7. 复现方式

```powershell
# 时序与资源：PDS GUI 中 Design > Report > Utilization / Timing，或直接读
#   pds\RV32I_1\multiseed_summary.csv        （资源占用 + 多 seed 收敛）
#   pds\RV32I_1\report_timing\cpu_top.rtr    （Fmax + slack）

# CoreMark 指标
scripts\run_coremark.ps1 -Iter 700 -SkipSim   # 生成固件
# 板上跑完后读 Total ticks，或跑完整仿真：
scripts\run_coremark.ps1 -Iter 700

# CoreMark 计时区间 + 流水线效率剖析（本次新增）
cd sim
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+PROF"
```

---

## 8. 口径勘误（本次核对发现）

既有文档（`doc/test_report_riscv-tests.md`、`CLAUDE.md`、`pds/README.md`、
`doc/base_task_status.md` 等）中「仿真 ≈ **420,414** 周期/迭代」这个数**无法复现**。

本次实测（ITER=1，`+PROF` 直接读取 CoreMark 的 `Total ticks`，并读数
start_time/stop_time 两次读 `0x7FF4` 的周期号交叉验证）：

```
start_time cycle : 21,533
stop_time  cycle : 441,603
region cycles    : 420,070   <- 与 CoreMark 自报 Total ticks 逐位一致
```

且本次改动前后 `ITER=1` 的测试台总周期均为 **1,529,499**（逐位一致），
说明整条执行序列没有变化 —— 因此**改动前的仿真也必然是 420,070**，
文档里的 420,414 应属推算或笔误。

**已同步（2026-09-21）**：既有文档中「仿真 ≈ 420,414」已统一更正为
「仿真 **420,070**（ITER=1，CoreMark 计时区间实测）」，涉及
`CLAUDE.md`、`doc/base_task_status.md`、`doc/test_report_riscv-tests.md`、
`pds/README.md`、`doc/paper/*.md`。修正后板上/仿真差值为 **0.0057%**（原写 0.08%），
论证反而更强。

同一批次还更正了另一处结论：**分支惩罚是 3 拍而非 2 拍**
（见 `doc/spec.md` §3.1 与 `doc/ila_analysis.md` §5）。

> 注意：「每迭代周期」不等于「ITER=1 的测试台总周期 1,529,499」——
> 后者含约 109 万拍的一次性 UART 打印开销。这个区分仍然成立，只是数值要更正。
