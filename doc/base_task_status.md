# 基础任务完成度核对（对照《紫光同创.pdf》选题指南）

> 核对日期：2026-09-21（更新）；2026-09-25 补时钟迁移（27 → 45 MHz → **49.89 MHz**）与动态分支预测口径
> 依据：赛题"核心设计任务 → 基础任务"三条 + 代码与仿真核对
> 结论：**基础任务三条全部达成**，另有若干项超出基础要求。

## 赛题原文（基础任务）

1. **处理器内核构建**：实现一个支持 RV32I 基础整数指令集的通用处理单元。
2. **流水线架构设计**：设计不少于 3 级的流水线结构，并妥善处理数据冲突与分支跳转等底层逻辑。
3. **外设系统集成**：集成基础外设（如 UART 控制器、GPIO 等）用于系统控制与结果输出。

## 逐条核对

| # | 要求 | 现状 | 判定 |
|---|---|---|---|
| 2a | ≥3 级流水线 | **5 级**（IF/ID/EX/MEM/WB，`if_id`/`id_ex`/`ex_mem`/`mem_wb` 级间寄存器） | [OK] 达标 |
| 2b | 数据冲突处理 | forwarding 前递（EX/MEM、MEM/WB 两级）+ load-use 停顿 + 多拍除法 `div_stall`；regfile 写优先 | [OK] 达标 |
| 2c | 分支跳转处理 | 6 种分支条件全实现；**条件分支方向由 256 项带 tag 的 BHT 动态预测**（2026-09-25），预测命中当拍重定向，吞吐损失 **1 拍**；未命中/误判与 jal/jalr 目标走 `ex_flush` 单拍冲刷 + **同拍把目标地址旁路给取指端**（损失 **2 拍**，2026-09-21 取指重定向改造） | [OK] 达标 |
| 1 | RV32I 基础整数指令集 | **全覆盖**，含此前缺的 FENCE / FENCE.I / ECALL / EBREAK | [OK] 达标 |
| 3a | UART 控制器 | **发送**（`uart_tx`，1024 深 FIFO）+ **接收**（`uart_rx`，16 深 FIFO，读弹出） | [OK] 达标 |
| 3b | GPIO | LED 输出 + 按键输入（`rtl/periph/gpio.v`，输入 2 级同步） | [OK] 达标 |
| 3c | 总线/外设集成 | 存储总线 `rtl/bus/mem_bus.v` + 地址映射单点定义 `rtl/bus/addr_map.vh`；CPU 不再硬译码地址 | [OK] 达标 |
| — | 演示程序 | `scripts/demo/`：读按键 → 写 LED → 串口打印 + 串口回显（`run_demo.ps1` 一键跑） | [OK] 额外完成 |

## 指令覆盖（RV32I 逐类）

| 类别 | 实现情况 |
|---|---|
| R 型（add/sub/and/or/xor/sll/srl/sra/slt/sltu） | [OK] |
| I 型算术（addi/andi/ori/xori/slli/srli/srai/slti/sltiu） | [OK] |
| 加载（lw/lh/lb/lhu/lbu，含符号/零扩展） | [OK]（**未对齐访问不支持**，RISC-V 规范 §2.6 允许） |
| 存储（sw/sh/sb，byte_en 选通） | [OK]（同上） |
| 分支（beq/bne/blt/bge/bltu/bgeu） | [OK] 全部 6 条 |
| 跳转（jal/jalr） | [OK] |
| 立即数高（lui/auipc） | [OK] |
| M 扩展（mul/mulh/mulhsu/mulhu + div/divu/rem/remu） | [OK]（超出基础要求） |
| **FENCE / FENCE.I** | [OK] 显式译码为 NOP，依据见下 |
| **ECALL / EBREAK** | [OK] **均已实现为同步异常**（2026-09-23）：ECALL = mcause=11、EBREAK = mcause=3（顶层 `done` 停机钩子从 trap 事件取） |

### 4 条指令的实现依据（写进报告用）

- **FENCE / FENCE.I 作 NOP 的正当性**：本设计没有 I/D Cache，也就没有需要"刷"的
  写缓冲；且存储器已统一（`rtl/mem/unified_mem.v`），store 对后续取指天然可见，
  FENCE.I 的语义已由硬件结构本身保证。RISC-V 规范允许无 Cache 的实现视其为 NOP。
- **ECALL**：**已实现为 mcause=11 的同步异常**（2026-09-23），跳 `mtvec`、
  写 `mepc`/`mcause`。
- **EBREAK**：**已实现为 mcause=3 的同步异常**。顶层的 `done` 停机钩子改从 trap
  事件取（`ebreak = trap && trap_cause == 3`）。
  注：装异常之后程序仍应在 EBREAK 后跟自旋循环 —— riscv-tests 与 CoreMark 的
  start.S 本来就是这个写法。

## 验证结果（2026-09-23 结果；2026-09-25 补时钟迁移口径）

| 项目 | 结果 |
|---|---|
| riscv-tests（50 项：rv32ui 42 + rv32um 8） | **49 PASS / 1 FAIL / 0 TIMEOUT**（唯一 FAIL 是 `ma_data` 未对齐访存，规范允许，见 §已知限制） |
| └ M 扩展（rv32um 8 项） | mul / mulh / mulhsu / mulhu / div / divu / rem / remu **全部 PASS** |
| **CoreMark v1.0（本地盘古板实测，49.8927 MHz，ITER=1663）** | `Total ticks 588,890,651` ÷ 49,892,700 = **实际 11.8031 秒** → **140.89 CoreMark**，`Correct operation validated` [OK] 达标，`seedcrc/crclist/crcmatrix/crcstate` 逐位一致。<br>原始串口日志：`doc/board/uart_20260925_172318.txt`。**上板教程：`doc/board_bringup.md`**<br>历史：45 MHz 时代（ITER=1500，`Total ticks 538,285,445` → 11.9619 秒 / 125.40 CoreMark）见 `doc/board/uart_20260925_005201.txt`；27 MHz 时代（ITER=820，`Total ticks 294,262,913` → 10.898 秒 / 75.24 CoreMark）见 `doc/board/uart_20260923_201540.txt`。**较 45 MHz +12.36%，较 27 MHz +87.3%** |
| **CoreMark 效率（当前设计，仿真）** | 每迭代 **354,119** 周期（`+PROF` 读 CoreMark `Total ticks`）→ **2.824 CoreMark/MHz**。<br>**四轮演进**：2.380 → 2.611 → 2.787 → **2.824**（最后一轮是 2026-09-25 的 BHT）|<br>板上实测 354,113 拍/迭代，与仿真 354,119 差 **−0.0016%**；历史：BHT 之前板上实测 358,857 拍/迭代，与仿真 358,846 差 **+0.0031%**，且**两个时钟下逐位相同**（与时钟无关）|
| **CoreMark 实际得分**（= CoreMark/MHz × 系统时钟） | 27 MHz 板测 **75.24** → 45 MHz 板测 **125.40** → **49.89 MHz 板测 140.89**（**均已板上实测**，累计 **+87.3%**）<br>口径见 `doc/resource_efficiency.md` §2 / §11 |
| 历史：改造前效率 | 每迭代 420,070（仿真）/ 420,094（板上），差 0.0057% → 2.380 CoreMark/MHz |
| 历史：改造前效率 | 每迭代 420,070（仿真）/ 420,094（板上），差 0.0057% → 2.380 CoreMark/MHz |
| 真机正确性 | seedcrc / crclist / crcmatrix / crcstate **逐位一致**（**`crcfinal` 不比** —— 它跨迭代累加、随 ITER 变：ITER=1 → `0xe714`、ITER=820 → `0xbd59`、ITER=1500 → `0x25b5`、ITER=1663 → `0x81c9`） |
| 演示程序端到端（`run_demo.ps1`） | 7/7 PASS：上电状态、按下/松开 KEY1、按下 KEY4、串口回显两例、done 状态 |
| 单元测试 | `tb_alu_inst` `tb_alu_div` `tb_uart_fifo` `tb_control` `tb_gpio` `tb_uart_rx` 全部 PASS |

详见 `doc/test_report_riscv-tests.md`。

## 地址映射

```
0x0000_0000 - 0x0000_7FEF   RAM（统一存储器，32KB 内可用部分）
0x0000_7FF0 - 0x0000_7FFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0x7FF4 R  周期计数器[31:0]      0x7FF8 W  done        0x7FFC W  UART 发送
0x8000_0000 起              外设区（字内偏移 = addr[5:2]）
    0x00 W LED[7:0] / R {key[7:0], led[7:0]}      0x08 W UART 发送
    0x0C R UART 接收（读弹出）                      0x10 R 周期计数器
```

单点定义在 `rtl/bus/addr_map.vh`；软件侧对应 `scripts/demo/addr_map.h`。

## 高阶任务进展

| 方向 | 状态 |
|---|---|
| **完整异常/中断** | [OK] **已完成**（2026-09-23）：CSR 文件 + 6 条 CSR 指令 + `mret` + 六类同步异常（非法指令 / EBREAK / 未对齐 load+store / ECALL / 写只读 CSR）+ 定时器中断（CLINT）。自写汇编测试在 `sim/tests/`，一键 `scripts\run_own_tests.ps1` |
| BTB 动态分支预测 | [OK] **已完成**（2026-09-25）：`core.v` 里 **256 项、2 位饱和计数器、带 tag 的 BHT**（`bht_tag/bht_ctr/bht_valid`，索引 `PC[9:2]`、tag `PC[31:8]`），**只预测条件分支方向**（`jal` 走静态后向预测、`jalr` 不预测）。收益 358,846 → **354,119** 拍（省 1.32%）。<br>残余：256 项表偏小、别名冲突（实测 341 个静态条件分支里 **149 个冲突**），扩到 1024/4096 项预计还能回收约 1% —— **可优化项，不是缺陷** |
| 外部中断 MEIP | [!] 只做了接口（`cpu_top` 接了 UART RX 非空），**没有测试**，不得当作已验证能力 |
| 2 路组相联 I/D Cache | [ ] 未做。**且经分析是负收益** —— 存储器是行为级单周期 BRAM，访存恒 1 拍、无缺失惩罚、无结构冲突，Cache 只会引入缺失惩罚 |
| 边缘 AI 加速 | [ ] 未做。32KB BRAM 是硬墙（无片外存储），当前硬件条件下不可行 |

> 统一存储器已为 I/D Cache 备好后端：将来两块 Cache 共用这份 backing store，
> `fence.i` 需要相应升级为"冲刷 I-Cache"而不是当前的 NOP。

## 已知限制（诚实记录，避免答辩被问倒）

1. **未对齐访存不提供正确结果，但会正确地陷入异常**（mcause 4/6，2026-09-23 起）。
   规范要求"要么支持、要么陷入异常"，本设计取后者。`ma_data` 因此仍是唯一 FAIL，
   失败形态是 `FAIL (testnum 668)`（与迁移前实测相同 —— "此前是 testnum 1"的说法已勘误，
   见 `doc/test_report_riscv-tests.md` §1）。
   真正要支持未对齐访存需在 MEM 级加多拍访问，未做。
2. **按键无硬件消抖** —— `gpio.v` 只做 2 级同步；去抖放在演示程序里
   （采样—延时 10ms—再采样），这样更容易验证。
3. **EBREAK 现在是 mcause=3 的异常** —— 顶层的 `done` 灯改从 trap 事件取。
4. **外部中断（MEIP）未实现** —— 通路与端口都在、`cpu_top` 也接了 UART RX 非空，
   但**没有测试**，不得当作已验证能力。
5. **只支持 M 模式** —— `mstatus.MPP` 硬连线 2'b11；未实现的 CSR 读 0、写忽略、
   不抛非法（否则 50 个基线 ELF 的 init 段会全挂）。
5. **PDS 工程已改为本地盘古板约束**（2026-09-23）—— `RV32I_1.fdc` 全部引脚
   按《MES2L676-200HP硬件使用手册》填好并**在板上实测验证过**；上板 top module
   是 `cpu_top_board`（不是 `cpu_top`）。详见 `doc/board_bringup.md`。
   2026-09-25 起系统时钟由板载 27 MHz 经 **PLL 倍频到 49.89 MHz**（先 45，再提频）——注意 `.fdc` 里
   约束的仍是 **27 MHz 输入晶振**，PLL 输出由 PDS 从 PLL IP 自动推导；**仿真与远程
   平台不进 PLL，仍是 27 MHz**。
