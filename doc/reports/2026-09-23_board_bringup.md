# 本地板上板记录与下一步（2026-09-23 晚）

> **本文取代了同日的 `2026-09-23_handoff.md`（已删除）。**
> 那份里仍有效的三条 RTL 坑（trap 要清 EX/MEM、CSR 从 EX 提交、`csr_wr_illegal`
> 要与"真的在写"相与）已并入 `CLAUDE.md` 关键约定 20–22；其余内容已过期或被本文覆盖。
> 需要查旧记录用 `git log --all -- doc/reports/2026-09-23_handoff.md`。
>
> 本文记录的是**拿到本地盘古板之后**的工作。

---

## 0. 一分钟状态

**本地板跑通了，CoreMark 在板上实测达标，一个高优先级待办关闭。**
**上板这条路现在完全在自己手上，不再依赖队友的远程 FPGA 平台。**

| | 数值 | 变化 |
|---|---|---|
| riscv-tests | **49 PASS / 1 FAIL / 0 TIMEOUT** | 不变（唯一 FAIL 仍是 `ma_data` testnum 668） |
| **CoreMark 板上实测** | **`Total ticks 294,262,913` → 10.898 s** | [OK] **本轮新增**（此前只有推算） |
| 板上 vs 仿真（每迭代） | 358,857 vs 358,846 = **+0.0031%** | [OK] 硬件与仿真几乎完全吻合 |
| CoreMark/MHz | **2.787** | 不变（板上算出与仿真一致） |
| Fmax（当前提交口径） | **37.5333 MHz**（slack +10.394） | 旧文档写 47.81 MHz，见 §4 |
| LUT / FF | **2,915 / 2,183** | 旧文档写 2,316（阶段 1 旧值） |

---

## 1. 本轮完成的事

### 1.1 本地板首次跑通（clk / UART / GPIO 全链路）

| 验证项 | 结论 |
|---|---|
| `clk` = **D18**（27 MHz） | [OK] 串口无乱码 → 波特率分频正确 → 时钟确实是 27 MHz |
| `uart_tx`/`uart_rx` = **C24/B24**（经 CP2102） | [OK] 收发都对 |
| `key[0..3]` = **C23/B22/A22/B20**（丝印 SW4–SW7） | [OK] 从左到右依次按 → `0x01/0x02/0x04/0x08` |
| `resetn` = **C22**（丝印 SW3） | [OK] 能重启程序（重印 `RV32I SoC demo ready`） |
| `led[0..7]` | [OK] 写入字节与读到字节一致 |

引脚表出处：`pds/RV32I_1/RV32I_1.fdc` 头部注释（按《MES2L676-200HP硬件使用手册》逐条核对）。
**上板教程：`doc/board_bringup.md`**。**实测证据：`doc/board/`**。

### 1.2 CoreMark ITER=820 板上实测（赛题硬指标 ≥10 s）

```
Total ticks      : 294262913      → 10.898 s
Iterations       : 820
Correct operation validated.
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
```

四个 CRC 与仿真基准（`doc/reports/2026-09-21_branch_opt_verify.md`）**逐位一致**。

> [!] CoreMark 打印的 `Total time (secs): 10` 与 `Iterations/Sec: 82` 是**整数截断**
> （`HAS_FLOAT=0`，见 `scripts/coremark_port/core_portme.h`）。真实值是 **10.898 / 75.24**。
> 报告里一律用 `Total ticks ÷ 27,000,000` 自己算，别引用打印值。

### 1.3 PDS 工程修复（此前**根本无法按最新 RTL 综合**）

发现并修掉三处，任何一处都会让"重新综合"静默失败或产出错误设计：

1. **`rtl/core/csr_file.v` 从未加入工程源文件列表** —— 而 `core.v:431` 例化了它。
   直接 Compile 会报模块找不到。异常/中断那次改动之后一直没同步过工程。
2. **`.pds` 里残留 `wgt_my_fic_src → cpu_top_syn.fic`** —— 综合会插回 ILA 调试核
   （LUT 从干净值涨到 3,058）。已摘除，调试产物归档到 `pds/RV32I_1/bak_2026-09-21_ila/`。
3. **`device_map/cpu_top.pcf` 是陈旧放置约束**（还写着 `uart_tx=AB26`/`done=U16`）。

顺带确认 **PDS 可以命令行驱动**（`pds_shell.exe -project X.pds -run <action>`），
整条 compile→synthesize→dev_map→pnr→report_timing→gen_bit_stream 全自动。

### 1.4 上板专用顶层 `cpu_top_board`

**为什么加**：PDS 会把未在 `.fdc` 里指定 LOC 的输出端口**自动布到 BANKR5 的真实引脚**上
（实测 `pc[0]→M2`、`pc[10]→M5`、`led[0]→P6`），而本板 BANKR5 接的是 SFP/HSST。

**为什么不在 `cpu_top` 里删端口**：`pc` 是**仿真侧分析的数据源** ——
`tb_coremark` 的 `+TRACE`/`+PROF` 逐拍 dump 和各测试台的 TIMEOUT 诊断都依赖它，
删掉会废掉 `doc/ila_analysis.md` 里那套分析方法。

**做法**：`rtl/top/cpu_top_board.v` 包住 `cpu_top`，只引出 16 个上板端口，
`pc`/`done` 悬空，`key[7:4]` 恒定接 1。**PDS 的 top module 已从 `cpu_top` 改成 `cpu_top_board`。**

### 1.5 LED 按板卡实际位置重排

板上 LED 的引脚是**按布线就近分配**的，丝印 `D12..D19` 相对开关是乱序的
（按键按排列分配、LED 按布线分配 → 两者必然对不上）。直接用手册 `LED0..LED7` 顺序，
现场会出现"按某个开关、亮隔壁那个灯"。

`.fdc` 里把 `led[]` 改成接**开关正下方**那颗灯：`led[0]=C19(D19,SW4下)`、
`led[1]=C18(D18,SW5下)`、`led[2]=E18(D13,SW6下)`、`led[3]=A17(D14,SW7下)`，
`led[4..7]` 接剩下的。**代价**：`led[i]` 不再等于手册 `LEDi`，报告里需注明"按板卡实际位置重排"。

### 1.6 证据链与工具

* `scripts/serial_monitor.ps1` —— 零依赖串口抓取（.NET 自带 SerialPort），
  默认把输出落盘到 `doc/board/uart_<时间戳>.txt`
* `doc/board/` —— 从**空目录**变成 3 份串口原始日志 + `README.md` 索引
* `pds/RV32I_1/bitstreams/` —— 归档两版 `.sbit`（跑分版 / 演示版）+ 重新生成方法

---

## 2. 回归基线（改动后用来对比）

```powershell
scripts\run_riscv_tests.ps1         # 期望 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_coremark.ps1 -Iter 1    # 期望 Total ticks 358846 / total cycles 1462898
scripts\run_sim.ps1 -NoWave         # 期望 6 个单测全过
scripts\run_own_tests.ps1           # 期望 exceptions PASS + timer_irq PASS
```

**PDS 侧当前口径**（top = `cpu_top_board`，板卡实测引脚）：

| 项 | 值 |
|---|---|
| LUT / FF | 2,915 / 2,183 |
| Fmax / slack | **37.5333 MHz** / +10.394 ns（约束 27 MHz） |
| 约束 | All Constraints Met |

> 对比：同样 RTL 但 top 用 `cpu_top` 时 LUT 2,938 / Fmax 33.8627 MHz；
> 本地板约束 + LED 原序时 Fmax 38.4231 MHz。差异来自顶层端口裁剪与引脚布局，
> **不是 RTL 变了**。

---

## 3. [重点] 本轮踩的坑（已写进 `CLAUDE.md` 关键约定 16–19）

1. **PDS 把未约束的输出端口自动布到 BANKR5**（本板是 SFP/HSST）—— 见 §1.4。
2. **手册 0 起编号、板上丝印 1 起编号**；LED 丝印相对开关乱序是硬件现状。
3. **板上 Jtag 和 USB UART 是两块独立接口，要插两根 USB 线** ——
   Jtag 是 FTDI（枚举成**两个** COM 口），USB UART 是 CP2102（枚举成**一个** CP210x 口）。
   **只插 Jtag，串口永远没输出** —— 这是上板最容易卡住的一步。
4. **PDS 命令行的实测事实**：每个 `-run` 会把前面的步骤重跑一遍（`gen_bit_stream`
   实际跑完整条链约 5 分钟）；`-file` 与 `-project` 不能同用；
   每次 `gen_bit_stream` 会**先清空 `generate_bitstream/`**（旧版进 `bak/`）。
5. **`doc/base_task_status.md` 里那处 CoreMark 数字是错的** ——
   原本写 `Total ticks 294,888,440`（ITER=820）并标注为"板上实测"，
   但当时**并未复测**，且 294,888,440 对应 359,620 拍/迭代，
   既不是仿真的 358,846 也不是实测的 358,857。**已修正为实测值 294,262,913 / 10.898 s。**

---

## 4. [!] 新产生的数据债：文档里的 Fmax / LUT 全是旧值

`doc/resource_efficiency.md`、`doc/ila_analysis.md`、`doc/paper/*` 等处写的是
**Fmax 47.8126 MHz / LUT 2,316**，那是"取指重定向后（=382,972 时代）"的**阶段 1 干净基线**。

当前实测（含第三轮分支优化 + 异常/中断 + 上板顶层）：

| 指标 | 文档旧值 | **当前值** |
|---|---|---|
| Fmax | 47.8126 MHz（余量 77%） | **37.5333 MHz（余量 39%）** |
| LUT | 2,316 | **2,915** |
| FF | — | 2,183 |
| CoreMark/MHz | 2.611 | **2.787** |
| CoreMark/LUTs | 1.127 | **0.956** |

> 归因提醒：Fmax/LUT 的变化**同时**包含第三轮分支优化与**高阶任务②（CSR/异常/中断）**，
> 报告里必须分开说，不能全算在优化头上。

---

## 5. 下一步（按性价比排序）

| 优先级 | 事项 | 说明 |
|---|---|---|
| **高** | **ILA 硬件抓波形**（赛题点名评分项） | 现在**本地板在手，可以走本地 PDS Debugger 扫 JTAG**，不必依赖远程平台（`doc/ila_analysis.md` §7.4 备选路径）。缺的窗口：**load-use 停顿 / 前递**（分支冲刷那版 `.fic` 已随 RTL 变更作废，需重做）。**`.fic` 与 `.sbit` 必须同批**；插 `syn_keep` 会让 LUT 涨到 ~3,058，**抓完要移除属性再出一版干净比特流** |
| **高** | **文档口径回填**（§4 那笔数据债） | 8 份文档里的 Fmax/LUT 旧值 + `doc/paper/` 里自相矛盾的"分支惩罚固定 2 拍"/"余量 72%/46.4MHz" |
| **高** | **论文正文**（唯一完全空白的评分项） | 骨架已就绪（9 章），数据齐了：CoreMark/MHz 2.787、Fmax 37.53 MHz、LUT 2,915、板上 10.898 s、四个 CRC 一致。**截止 2026-11-04** |
| 中 | 演示视频 / 照片 | `doc/board/` 目前只有串口文本，缺录像/照片。「应用场景」是**独立评分项** |
| 中 | `doc/base_task_status.md` 遗留描述 | 检查是否还有"引脚以注释预留"字样（§已知限制第 5 条已改） |
| 低 | BTB 动态分支预测 | 实测剩余空间仅约 2.3% |
| 低 | 外部中断 MEIP 测试 | 通路在、无测试，不得当已验证能力 |
| 低 | 未对齐访存真正支持 | 需 MEM 级多拍访问；会动流水线 → 要重算 ITER、重上板 |

### 不建议做

* **2 路组相联 I/D Cache**：单周期 BRAM 无缺失惩罚，加 Cache 是负收益
* **边缘 AI**：32KB BRAM 是硬墙

---

## 6. 复现要点

* **上板看 `doc/board_bringup.md`**（接线、引脚表、烧录、排障速查）
* 本地板**插两根 USB 线**：Jtag（FTDI）+ USB UART（CP2102，那个才是串口）
* 命令行重建比特流：`run_coremark.ps1 -Iter 820 -SkipSim` → `sync_firmware.ps1`
  → `cd pds/RV32I_1 && pds_shell.exe -project RV32I_1.pds -run gen_bit_stream`
* 串口：`scripts\serial_monitor.ps1 -Port COM4`
* **改了 RTL / `.fdc` / 固件之后必须重新综合出比特流再烧** —— PDS 不检查时间戳
