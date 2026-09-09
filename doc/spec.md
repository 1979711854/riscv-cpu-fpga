# 架构文档 spec.md — 单周期 RV32I（当前阶段）

> 状态：2026-09-08 建立骨架。本文件会随设计推进持续更新，最终作为比赛《性能分析报告》的架构依据。
> 目录：`rtl/core/` 下骨架文件已建好（只有端口与注释，正文 TODO 待实现）。

## 1. 当前目标（对应 plan.md W2 检查点1）
- 单周期 RV32I 子集，在 iverilog 仿真中跑通手写汇编。
- 跑通后再谈流水线（W3~W4）。

## 2. 模块清单与功能
| 文件 | 模块 | 功能 | 实现要点 |
|---|---|---|---|
| core/pc.v | PC | 锁存 next_pc | 同步复位，stall 保留 |
| core/imem.v | 指令存储器 | 按 pc 取指 | 先组合读+$readmemh |
| core/dmem.v | 数据存储器 | lw/sw | 先支持字访问，字节/半字留 TODO |
| core/regfile.v | 寄存器堆 32×32 | 2读1写 | x0 恒 0 |
| core/imm_gen.v | 立即数扩展 | I/S/B/U/J | B/J 输出已左移1位 |
| core/alu.v | ALU | 算数逻辑移位比较 | 编码见 defs.v |
| core/alu_ctrl.v | ALU 译码 | funct→alu_ctrl | 与 main_ctrl 配合 |
| core/main_ctrl.v | 主译码 | opcode→控制信号 | 见下方控制信号表 |
| core/branch_unit.v | 分支比较 | beq..bgeu 判定 | 有符号/无符号 |
| core/single_cycle.v | 顶层连线 | 数据通路 | 依连线清单例化 |

## 3. 存储器与编码约定
- 哈佛结构：指令、数据分开（单周期阶段，先不做统一总线）。
- imem/dmem 参数化 `DEPTH`（默认 1024 字）；`$readmemh` 加载 hex。
- 复位向量 0x0；字对齐，字索引用 `addr[11:2]`。
- 立即数：imm_gen 统一输出**符号扩展且对齐后**的 32 位（B/J 已 <<1）。

## 4. 控制信号表（你来实现后回填）
| 信号 | 含义 | 各类指令取值（实现后填表） |
|---|---|---|
| reg_write | 写寄存器 | R/lw/jal/…=1，sw/branch=0 |
| mem_write / mem_read | 访存使能 | 仅 sw / 仅 lw |
| mem_to_reg | 回写源 | lw=1 其余=0 |
| alu_src | B 源 | R=0, I/S/U=1 |
| alu_src_a | A 源 | RS1 / ZERO(LUI) / PC(AUIPC) |
| branch / jal / jalr | 跳转类别 | B/J/JALR 对应置 1 |
| alu_op | 粗 ALU 控制 | 00=加法族 / 10=按 funct 译码 |

## 5. 支持的指令子集（里程碑 A，回填打勾）
- [ ] R 型：add sub sll slt sltu xor srl sra or and
- [ ] I 型算术：addi slti sltiu xori ori andi slli srli srai
- [ ] 访存（先字）：lw sw
- [ ] 分支：beq bne blt bge bltu bgeu
- [ ] 跳转：jal jalr
- [ ] 立即数高：lui auipc
- 扩展点（后做）：lb/lbu/lh/lhu/sb/sh、ecall、CSR

## 6. 尚未决定的设计点（团队讨论后回填）
- jal/jalr 的 rd 写回值 pc+4 走哪条路径（建议由顶层单独 mux 到 wb_data）。
- 未用功能（stall、overflow 标志）单周期阶段如何处理。
- 仿真通过判定口径：跑哪个测试程序、寄存器终值如何核对。

## 7. 单测建议（每个模块一个小 tb）
按 alu → regfile → pc → imm_gen → imem/dmem → alu_ctrl → main_ctrl →
branch_unit → single_cycle 的顺序逐个写 tb、逐个过，别攒到最后一起排错。
（tb 放 `sim/`，见 sim/README.md）
