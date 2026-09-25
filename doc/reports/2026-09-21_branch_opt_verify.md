# 取指重定向改造验证记录（分支惩罚 3 拍 → 2 拍）

> [!] **本文是历史记录（27 MHz 时代、BTB/BHT 之前 / 2026-09-21），** 里面所有频率、
> 周期数、资源数字都是**当时**的实测值，**不代表当前设计**。当时：每迭代 **382,972** 拍
> （改造前 420,070）、估计可达 **47.8126 MHz**、slack +16.122 ns、LUT **2,316** / FF 1,913，
> 分支惩罚刚由 3 拍降到 2 拍（ID 级静态预测与 BHT 都还没有）。
> **当前口径**见 `CLAUDE.md` 与 `doc/resource_efficiency.md`：
> **49.8927 MHz / 每迭代 354,119 拍 / 140.89 CoreMark / LUT 3,721 / FF 2,441**。
> 本文保留原貌（含当时的判断与自我更正），**其中的数字不要当当前值引用**。

> 日期：2026-09-21　被测改动：`rtl/core/core.v` + `sim/tb_coremark.v`
> 结论：**正确性提升、性能提升，全部验证通过。时序与资源已补测（§3）。
> 有一个必须先改的参数：ITER 700 → 770（§4）。**
> 连带文档同步与两张波形图重做已于同日完成（§5）。

## 1. 改动内容

**去掉 `ex_flush_d`，改为"冲刷当拍就把跳转目标地址发给取指端"。**

```verilog
// 新增：本拍真正发出的取指地址，跳转目标在当拍旁路进去
wire [31:0] fetch_addr = ex_flush            ? ex_target :
                         (stall || div_stall) ? if_addr_d :
                                                pc_r;
assign imem_addr = fetch_addr[14:2];
assign ex_target = id_ex_jump_reg ? jalr_target : branch_target;   // 提升为模块级

// if_addr_d 现在记录【实际发出的地址】，不再记 pc_r
if (!stall && !div_stall) if_addr_d <= fetch_addr;

// 重定向到 ex_target + 4（不是 ex_target）——地址已在当拍发出，pc_r 要跳过它
else if (ex_flush) pc_r <= ex_target + 32'd4;

// IF/ID 只在 ex_flush 清一拍（原来是 ex_flush || ex_flush_d 清两拍）
```

**原理**：同步读 BRAM 使取指有 1 拍延迟。提前一拍发出目标地址，目标指令就能早 1 拍进
IF/ID，惩罚由 3 拍降到 2 拍。`pc_r <= ex_target + 4` 的关键在于地址已在当拍发出，
若写成 `ex_target` 会重发同一地址、目标指令被取两次。

## 2. 实测结果

### 2.1 正确性

| 项目 | 基线 | 现在 | 判定 |
|---|---|---|---|
| riscv-tests（50 项） | 49 PASS / 1 FAIL（`ma_data`，testnum 1） | **49 PASS / 1 FAIL**（逐项不变） | **无变化** |
| CoreMark CRC | 0xe9f5 / 0xe714 / 0x1fd7 / 0x8e3a | **完全相同** | **逐位一致** |

> [!] **本节初稿写错了，已更正。** 初稿称 `ma_data` 从 FAIL 变 PASS、并据此推断
> "它更像是冲刷路径上的潜在 bug"。**该结论无法复现**：
>
> 1. 用取指重定向【之前】的 RTL 单独跑 `ma_data` → 同样 **FAIL (testnum 1)**
> 2. 改造【之后】单独跑两次 → **FAIL (testnum 1)**，确定性复现
> 3. 50 个基线 ELF 的 `sha256sum -c` 全部通过，且仓库内无 riscv-tests 源码
>    → 两次测量用的是**同一批二进制**
>
> 且从代码即可确证：本次改造只碰取指重定向路径，**完全没有动 load/store 的字节
> 抽取逻辑**，物理上不可能改变未对齐访存的结果。原文"架构取舍"的归因才是对的。
>
> **教训**：`ma_data` 的 PASS/FAIL 被当成了改造效果的证据，但它其实与改造无关。
> 一处结论要写进文档与论文之前，必须能**独立复现**，而不是只跑一次就采信。

### 2.2 性能（CoreMark ITER=1）

| 指标 | 基线 | 现在 | 变化 |
|---|---|---|---|
| 计时区间周期 | 420,070 | **382,972** | **−8.83%** |
| 计时区间 CPI | 1.4583 | **1.3295** | −8.83% |
| 分支惩罚 | 3 拍 | **2 拍** | −1 拍 |
| 测试台总周期 | 1,529,499 | 1,488,333 | −2.69% |
| **CoreMark/MHz** | 2.380 | **2.611** | **+9.7%** |

**自洽校验**（`+PROF` 输出）：

```
区域提交指令 288,056  +  load-use 停顿 20,720  +  2 × 冲刷 37,098  =  382,972 [OK] 精确闭合
```

且 `420,070 − 382,972 = 37,098`，**恰好等于冲刷事件数** —— 与"每次冲刷省 1 拍"完全吻合。

区域内的提交指令数、停顿数、前递数、访存数与基线**完全相同**，说明只改变了时序、没改变行为。

> 总周期只降 2.69% 而计时区间降 8.83%：整场仿真里约 109 万拍是 UART 打印区间，
> 其拍数由波特率决定，不随核心提速而减少。

### 2.3 分支方向分布（区域内，新增口径）

| 类别 | 数量 |
|---|---|
| 条件分支总数 | 53,173 |
| ├ taken / not taken | 29,398 / 23,775 |
| ├ **后向** | **25,664**（其中 taken **23,297 = 90.8%**） |
| └ 前向 | 27,509（其中 taken 6,101） |
| jal / jalr | 5,563 / ≈2,137 |

**后向分支 90.8% 都跳转** —— 这意味着"后向分支预测跳转"这类简单静态规则就能覆盖绝大部分
循环回边，是下一步加分支预测的成本最低方案。

## 3. 时序与资源（已补测）

本报告初稿写"尚未测量"，**随后拿到了与新 RTL 同批的 PDS 报告**（09-21 14:08 那次
综合 —— 它编的就是改后的 `core.v`），所以这里补齐实测值：

| 项目 | 改造前 | **改造后** | 说明 |
|---|---|---|---|
| **Estimated Fmax** | 46.4209 MHz | **47.8126 MHz** | 反而**升了 3.0%** |
| Setup slack（Slow） | +15.495 ns | **+16.122 ns** | 余量 72% → **77%** |
| Hold slack（Slow） | +0.145 ns | **+0.147 ns** | |
| **LUT** | 2,301 | **2,316**（+15） | 新增取指地址 mux 的开销 |
| **FF** | 1,914 | **1,913**（−1） | **正好对应删掉的 `ex_flush_d` 触发器** |
| CoreMark/LUTs（主口径） | 1.035 | **1.127** | |

> **初稿的推断是错的，值得记下来**：我当时判断"新路径把 `ex_target` 直接接到 BRAM
> 地址口，关键路径变长、Fmax 可能下降"。实测反而升了 —— 因为同一次改动也删掉了
> `ex_flush_d` 及其配套 mux，净效果是简化。
> **教训：关键路径必须重新综合才知道，不能靠推断。**

数据来源：`pds/RV32I_1/report_timing/cpu_top.rtr` 与 `multiseed_summary.csv`
（均 09-21 14:08）。改造前的备份在 `report_timing/bak/`、`synthesize/bak/`。

## 4. 行动项：ITER 必须从 700 提到 770

赛题要求 CoreMark 运行 **≥10 秒**，否则判 invalid。

```
每迭代周期 = 382,972
ITER = 700  →  700 × 382,972 / 27MHz = 9.93 s [X] 不足 10 秒
ITER = 705  →  刚好 10 秒 [X] 无余量
ITER = 770  →  770 × 382,972 / 27MHz = 10.92 s [OK] 余量 9.2%（与原来 8.9% 相当）
```

**重烧比特流之前先改 ITER，否则 CoreMark 会判 invalid。**

> [!] 还有一步容易漏：改完 ITER 编译出固件后，**必须 `sync_firmware.ps1`**。
> PDS 综合读的是 `pds/RV32I_1/mem.hex`，不是 `sim/programs/mem.hex`，而且不看时间戳。

## 5. 连带需要同步的地方 —— **已于同日完成**

| 文件 | 过期内容 | 状态 |
|---|---|---|
| `doc/spec.md` | §3.1「分支惩罚 = 3 拍」整段、§3.2 表格、§4 BTB | 已改 |
| `doc/ila_analysis.md` | §1/§2/§3/§4/§5/§7（含探针表里的 `ex_flush_d`） | 已改（§3/§4 的图也换了热点、重抓重画） |
| `CLAUDE.md` | 基础任务表、CoreMark 段、工程坑、流水线效率基线段 | 已改 |
| `doc/base_task_status.md` | 2c 行、验证结果表、已知限制 1 | 已改 |
| `pds/README.md` | BTB 行、交付状态表、时序段、回归纪律、坑 1b | 已改 |
| `doc/resource_efficiency.md` | §0–§6 全部指标、新增 §9 对照表 | 已改 |
| `doc/paper/*.md` | 多处「3 拍」「`ex_flush_d`」、指标表、风险表 | 已改 |
| `doc/test_report_riscv-tests.md` | §1 整节（已二次更正：`ma_data` 仍是 FAIL）、CoreMark 附录、回归纪律 | 已改 |
| `README.md` / `doc/README.md` / `rtl/README.md` / `scripts/README.md` / `third_party/riscv-tests-elf/README.md` | 成绩表、回归基线 | 已改 |
| `scripts/trace2svg.py` + `doc/figures/*` | `fd` lane（本来就是死线）、两张旧波形图 | 已改：`fd` 换成 `br`/`br_taken`/`jal-jalr`；图按 `core_bench_list` 的两个热循环重做 |

**顺带修掉一个真 bug**：`scripts/elf2mem.py` 的临时文件清理原排在 `write_hex()` 之前，
`os.remove` 一旦抛异常就会在**写出 hex 之前**中止（留旧镜像、且无报错）。已修正。

## 6. 复现命令

```powershell
# 正确性
scripts\run_riscv_tests.ps1                  # 期望 49/1/0

# 性能（先确认 sim\programs\*.hex 与 coremark.elf 对应 —— 固件错配会给出假结论）
scripts\run_coremark.ps1 -Iter 1             # 期望 total cycles 1,488,333

# 完整剖析（计时区间 382,972 拍、CPI 1.3295、自洽校验）
cd sim
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+PROF"

# 逐拍波形（一次抓足整个区间再切；+TRACE_* 受 +PROF 门控）
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" `
    "+PROF" "+TRACE_START=18000" "+TRACE_LEN=390000" "+TRACE_FILE=programs/trace_r1.txt"

# 上板：换回 770 并同步进 PDS 工程（否则板子上跑的是上一次的镜像）
scripts\run_coremark.ps1 -Iter 770 -SkipSim
scripts\sync_firmware.ps1
```

> 波形窗口的切法、热点定位、以及"抓 trace 前必须确认固件 ITER"这个坑，
> 都记在项目技能 `.workbuddy/skills/riscv-pipeline-profiling/`。
