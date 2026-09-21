# 基础任务完成度核对（对照《紫光同创.pdf》选题指南）

> 核对日期：2026-09-15（更新）　依据：赛题"核心设计任务 → 基础任务"三条 + 代码与仿真核对
> 结论：**基础任务三条全部达成**，另有若干项超出基础要求。

## 赛题原文（基础任务）

1. **处理器内核构建**：实现一个支持 RV32I 基础整数指令集的通用处理单元。
2. **流水线架构设计**：设计不少于 3 级的流水线结构，并妥善处理数据冲突与分支跳转等底层逻辑。
3. **外设系统集成**：集成基础外设（如 UART 控制器、GPIO 等）用于系统控制与结果输出。

## 逐条核对

| # | 要求 | 现状 | 判定 |
|---|---|---|---|
| 2a | ≥3 级流水线 | **5 级**（IF/ID/EX/MEM/WB，`if_id`/`id_ex`/`ex_mem`/`mem_wb` 级间寄存器） | ✅ 达标 |
| 2b | 数据冲突处理 | forwarding 前递（EX/MEM、MEM/WB 两级）+ load-use 停顿 + 多拍除法 `div_stall`；regfile 写优先 | ✅ 达标 |
| 2c | 分支跳转处理 | 6 种分支条件全实现；jal/jalr 目标与 `ex_flush` + `ex_flush_d` 双拍冲刷（**实际吞吐损失 3 拍**，2026-09-21 实测更正） | ✅ 达标 |
| 1 | RV32I 基础整数指令集 | **全覆盖**，含此前缺的 FENCE / FENCE.I / ECALL / EBREAK | ✅ 达标 |
| 3a | UART 控制器 | **发送**（`uart_tx`，1024 深 FIFO）+ **接收**（`uart_rx`，16 深 FIFO，读弹出） | ✅ 达标 |
| 3b | GPIO | LED 输出 + 按键输入（`rtl/periph/gpio.v`，输入 2 级同步） | ✅ 达标 |
| 3c | 总线/外设集成 | 存储总线 `rtl/bus/mem_bus.v` + 地址映射单点定义 `rtl/bus/addr_map.vh`；CPU 不再硬译码地址 | ✅ 达标 |
| — | 演示程序 | `scripts/demo/`：读按键 → 写 LED → 串口打印 + 串口回显（`run_demo.ps1` 一键跑） | ✅ 额外完成 |

## 指令覆盖（RV32I 逐类）

| 类别 | 实现情况 |
|---|---|
| R 型（add/sub/and/or/xor/sll/srl/sra/slt/sltu） | ✅ |
| I 型算术（addi/andi/ori/xori/slli/srli/srai/slti/sltiu） | ✅ |
| 加载（lw/lh/lb/lhu/lbu，含符号/零扩展） | ✅（**未对齐访问不支持**，RISC-V 规范 §2.6 允许） |
| 存储（sw/sh/sb，byte_en 选通） | ✅（同上） |
| 分支（beq/bne/blt/bge/bltu/bgeu） | ✅ 全部 6 条 |
| 跳转（jal/jalr） | ✅ |
| 立即数高（lui/auipc） | ✅ |
| M 扩展（mul/mulh/mulhsu/mulhu + div/divu/rem/remu） | ✅（超出基础要求） |
| **FENCE / FENCE.I** | ✅ 显式译码为 NOP，依据见下 |
| **ECALL / EBREAK** | ✅ ECALL = NOP；EBREAK = 停机钩子（置 `done`，为将来接异常机制留口） |

### 4 条指令的实现依据（写进报告用）

- **FENCE / FENCE.I 作 NOP 的正当性**：本设计没有 I/D Cache，也就没有需要"刷"的
  写缓冲；且存储器已统一（`rtl/mem/unified_mem.v`），store 对后续取指天然可见，
  FENCE.I 的语义已由硬件结构本身保证。RISC-V 规范允许无 Cache 的实现视其为 NOP。
- **ECALL**：严格语义要跳 `mtvec`、写 `mepc`/`mcause`，属高阶任务的完整异常机制，
  阶段一实现为 NOP。
- **EBREAK**：置 `sys_ebreak`，经 ID/EX → EX/MEM 送到核外，顶层锁存为停机标志并点亮
  `done`。这是【软停机】——只置标志、不停 PC，程序应在 EBREAK 后跟自旋循环
  （riscv-tests 与 CoreMark 的 start.S 本来就是这个写法）。将来接异常机制时，
  这里就是 trap 的入口。

## 验证结果（2026-09-15）

| 项目 | 结果 |
|---|---|
| riscv-tests（50 项：rv32ui 42 + rv32um 8） | **49 PASS / 1 FAIL / 0 TIMEOUT**，唯一 FAIL 是 `ma_data`（未对齐访问，架构取舍） |
| └ M 扩展（rv32um 8 项） | mul / mulh / mulhsu / mulhu / div / divu / rem / remu **全部 PASS** |
| **CoreMark v1.0（板上实测，ITER=700）** | `Total ticks 294,065,438` → **实际 10.89 秒**，`Correct operation validated` ✅ **达标** |
| CoreMark 效率 | **每迭代 420,094 周期（板上）/ 420,070（仿真，ITER=1 计时区间实测），差 0.0057%** → **2.38 CoreMark/MHz** |
| 真机正确性 | seedcrc / crclist / crcmatrix / crcstate **四个 CRC 与仿真逐位一致** |
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

## 高阶任务（尚未做，记录备查）

2 路组相联 I/D Cache · BTB 动态分支预测 + 完整异常/中断 · 边缘 AI 加速

> 统一存储器已为 I/D Cache 备好后端：将来两块 Cache 共用这份 backing store，
> `fence.i` 需要相应升级为"冲刷 I-Cache"而不是当前的 NOP。

## 已知限制（诚实记录，避免答辩被问倒）

1. **未对齐 load/store 不支持** —— `ma_data` 因此 FAIL。RISC-V 规范允许。
2. **按键无硬件消抖** —— `gpio.v` 只做 2 级同步；去抖放在演示程序里
   （采样—延时 10ms—再采样），这样更容易验证。
3. **EBREAK 是软停机** —— 不停 PC，需软件配合自旋循环。
4. **UART 无中断** —— 收发都是轮询；中断属高阶任务的异常机制。
5. **PDS 工程当前仍按远程 FPGA 平台约束** —— 新增的 `led`/`key`/`uart_rx`
   引脚在 `RV32I_1.fdc` 里以注释形式预留（盘古 MES2L200HP 实测引脚已填好），
   未指定 LOC 会导致 place & route 失败；compile / synthesize 不受影响。
