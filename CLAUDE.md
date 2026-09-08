# D:\riscv-cpu-fpga — 嵌入式大赛 FPGA 赛道 · 基于紫光同创(Pango) 的 RISC-V CPU

## 项目目标
- 参赛方向：嵌入式芯片与系统设计大赛 FPGA 赛道
- 器件平台：紫光同创 Pango FPGA，配套工具 Pango Design Suite (PDS)
- 设计内容：基于 RISC-V 指令集的 CPU 核（指令集规格以赛题为准，常见 rv32i / rv32imc）

## 工作约定
- 交流与输出默认使用简体中文。
- 代码统一存放在本目录 `D:\riscv-cpu-fpga`，不使用全盘 git。
- 所有源码通过 git 管理，按里程碑提交，提交信息需清晰说明改动。
- 上板/综合之前，先在 `sim/` 完成功能仿真验证。
- PDS 是紫光同创的工具（Vivado 是 Xilinx/AMD 的），涉及工具操作时注意区分。

## 目录规划
- `doc/`      需求、架构、赛题要求、参考资料（含官方 RISC-V 规范/指令手册）
- `rtl/`      RTL 源码（Verilog / SystemVerilog）
- `sim/`      仿真 testbench、程序(hex)与波形
- `pds/`      Pango PDS 工程目录（生成物不入库）
- `scripts/`  自动化脚本（编译、跑仿真、批处理）
- `.claude/`  Claude Code 本项目配置（不入库）

## 当前状态
- 2026-09-08 初始化：移除误建于 D:\ 根的全盘空 git 仓库，在本目录新建独立仓库（main 分支），已建立目录骨架。
- 尚无 RTL 代码，尚未创建 PDS 工程。
