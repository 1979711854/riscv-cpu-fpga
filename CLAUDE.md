# D:\riscv-cpu-fpga — 嵌入式大赛 FPGA 赛道 · 基于紫光同创(Pango) 的 RISC-V CPU

## 项目目标
- 参赛方向：全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道（选题：**RISC-V 处理器设计**）
- 器件平台：紫光同创 **Logos2 PG2L200H**（速度 -6，封装 FBB676）；工具 **Pango Design Suite 2022.2-SP6.4**
- 当前目标板：**远程 FPGA 平台**（27MHz 固定时钟，约束已可用）；本地"盘古2L200H"开发板器件相同，后期只需改 `.fdc` 引脚/时钟
- 设计内容：**RV32I + M 扩展的 5 级流水线 CPU**（forwarding 前递 + load-use 停顿 + 多拍除法器），集成 UART/GPIO，跑 riscv-tests 与 **CoreMark v1.0**（要求运行 ≥10s）
- 可选加分项：2 路组相联 I/D Cache、BTB 动态分支预测 + 完整异常/中断、边缘 AI 加速

## 当前进度（2026-09-15）
基础任务完成度详见 `doc/base_task_status.md`：

| 基础任务 | 状态 |
|---|---|
| ② ≥3 级流水线 + 数据冲突 + 分支跳转 | ✅ 达标（5 级流水线、前递、load-use 停顿、6 种分支 + 双拍冲刷；**实际分支惩罚 3 拍**，见下） |
| ① RV32I 基础整数指令集 | ✅ **全覆盖**，含 FENCE / FENCE.I / ECALL / EBREAK |
| ③ 集成基础外设（UART/GPIO） | ✅ 存储总线 + 地址译码 + GPIO + UART 收发；演示程序跑通 |

- 验证：riscv-tests rv32ui + rv32um（50 项）→ **49 PASS / 1 FAIL / 0 TIMEOUT**
  （M 扩展的 mul/mulh/mulhsu/mulhu/div/divu/rem/remu 8 项也纳入回归 —— CPU 实现了
   M 扩展且 CoreMark 用 `-march=rv32im` 编译，此前只有手写单测覆盖）
  （唯一 FAIL 是 `ma_data` 未对齐访问，RISC-V 规范允许，属架构取舍）
- **CoreMark 已达赛题要求（2026-09-15，远程平台实测，ITER=700）**：
  `Total ticks 294,065,438` → **实际 10.89 秒**（打印的 `Total time (secs): 10` 是整数截断）
  `Correct operation validated` + 四个 CRC 与仿真逐位一致 → **CPU 真机算得对**
  **每迭代 420,094 周期（板上）/ 420,070（仿真，ITER=1 计时区间实测），只差 0.0057%
  → 约 2.38 CoreMark/MHz**
  > ⚠️ **别用 ITER=1 的 1,529,499 周期去推算迭代成本**。那是仿真测试台的总周期，
  > 含约 110 万周期的一次性串口打印开销；而 CoreMark 自己的 `Total ticks` 计时在打印
  > **之前**就停了，不含打印。两者口径不同，混用会把迭代成本算错，进而把 ITER 估得偏小
  > （本项目据此写成"ITER≈200 约 10s"，实测只有 3.11s，被判 invalid）。
  > 27MHz 下跑满 10s 需要 **ITER ≈ 650 以上**，**用 700**（10.89s，留 8.9% 余量）。
- 演示程序：`scripts\run_demo.ps1`（读按键 → 写 LED → 串口打印 + 串口回显）
- **平台坑**：远程平台偶发"固件下载完成但设备唤醒失败"，**多烧录几次即可**，不是设计问题 ——
  别浪费时间怀疑自己的 RTL
- **工程坑**：综合前必须把 `mem.hex` 放进 PDS 工程目录（`scripts\sync_firmware.ps1`）。
  缺失时 PDS 只报一行 `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** ——
  但 BRAM 是空的，板上什么都不跑，且没有任何其他报错，极难排查。
- **流水线效率基线（2026-09-21 实测，改动流水线后用来对比）**：CoreMark 计时区间
  420,070 拍 / 提交 288,056 条指令 → **CPI 1.4583**；损失构成：
  **分支冲刷 26.5%（37,098 次 × 3 拍）** + load-use 停顿 4.9%。实测方法见
  `doc/ila_analysis.md`，测试台已内置 `+PROF` / `+TRACE_*`（默认关闭，不影响回归）。
  > ⚠️ **分支惩罚是 3 拍，不是 2 拍。** 冲刷确实 2 拍，但因取指是同步读 BRAM，
  > 第 3 拍还在等数据回来。此前 spec 与本文档都误记为 2 拍，已于 2026-09-21 更正。

**回归纪律（重要）**：改动 RTL 后，riscv-tests 的 49/1/0 与 CoreMark 的 1,529,499 周期
必须同时保持不变（除非本次改动的目的就是改变某一项）。后者是"没碰坏流水线"最灵敏的探针。

## 仓库结构（以此为准，勿再新建顶层目录）
- `rtl/core/`    CPU 核：`core.v`(5 级流水线/冒险/分支) `control.v`(主控译码) `alu.v`(含 M 扩展乘法) `divider.v`(多拍除法) `imm_gen.v` `regfile.v`
- `rtl/mem/`     `unified_mem.v` —— **统一存储器**（指令+数据共用一块双端口 BRAM：A 口取指 / B 口访存）。
                 行为级、仅 PDS 综合用，`$readmemh` 读 PDS 工程目录下的 `mem.hex`
- `rtl/bus/`     `addr_map.vh`(地址映射单点定义) `mem_bus.v`(**唯一的地址译码处** + 读数据 mux)
- `rtl/periph/`  `uart_tx.v`(发送，1024 深 FIFO) `uart_rx.v`(接收，16 深 FIFO、读弹出) `gpio.v`(LED+按键)
- `rtl/top/`     `cpu_top.v` SoC 顶层，只做连线（地址映射见 `rtl/bus/addr_map.vh`）
- `rtl/top.v`    早期 LED 点灯练习工程顶层（保留）
- `sim/`         `mem_model.vh`(存储器行为模型，被各 tb `include)
                 `tb_riscv.v` `tb_coremark.v` `tb_demo.v`（集成）+ `tb_alu_*` `tb_control.v` `tb_gpio.v` `tb_uart_rx.v` `tb_uart_fifo.v`（单元）
                 `sim/programs/` 为生成的 hex/ELF（**不入库**）
- `scripts/`     `run_sim.ps1` `run_coremark.ps1` `run_riscv_tests.ps1`(支持 `-ElfDir` 免源码回归) `run_demo.ps1` `sync_firmware.ps1`
                 `elf2mem.py`(出 imem/dmem/mem 三种 hex) `trace2svg.py`(逐拍 trace → 流水线波形 SVG) `riscv_tests_link.ld` `coremark_port/` `demo/`(演示程序)
- `pds/RV32I_1/`  **正式 CPU 工程**（`.pds` 内源文件已重指 `../../rtl/**`，单一真相）
- `pds/riscv_cpu/` 早期 LED 练习工程
- `third_party/coremark/`  官方 CoreMark 源码（含 LICENSE）
- `doc/`          `plan.md`(计划) `spec.md`(架构) `base_task_status.md`(基础任务核对) `RV32I指令集参考.md` `setup_env.md`(环境搭建) `test_report_riscv-tests.md` `resource_efficiency.md`(赛题三条性能指标成文) `ila_analysis.md`(流水线效率+ILA方案) `figures/`(波形图) `patches/`(给队友的兼容补丁)
- `.vscode/`      `tasks.json`(一键仿真) `settings.json`(Verilog lint 已改用 iverilog)
- `riscv32-FPGA-pds/`  队友交接的**原件**（已 gitignore，仅作回归对照，验证完可删）

## 工具链与常用命令
- **iverilog 14 + GTKWave**（scoop 安装）、**riscv-none-elf-gcc 15.2.0**（`D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin`，等价赛题写的 `riscv32-unknown-elf-`）、PDS 2022.2-SP6.4
- 常用命令：
  - `scripts\run_sim.ps1` —— 跑 `sim/` 下全部单测；`-Testbench sim/xxx.v` 单个；`-NoWave` 不弹波形；整核测试台加 `-WithCore`
  - `scripts\run_coremark.ps1 -Iter 700 -SkipSim` —— **上板用**：只生成固件，几秒钟
  - `scripts\run_coremark.ps1 -Iter 700` —— 完整仿真跑分（ITER=700 要跑十几分钟）
  - `scripts\run_demo.ps1 -SkipSim` —— 演示程序固件，同上
  - `scripts\run_riscv_tests.ps1` —— rv32ui 全量回归 + 汇总（**需 riscv-tests 源码**，见待办）
  - `scripts\sync_firmware.ps1` —— 把 `sim/programs/*.hex` 同步到 PDS 工程供 BRAM 初始化

## 关键约定（都是踩过的坑）
1. **iverilog 14 严格要求"先声明后使用"**：信号声明必须出现在使用之前，否则报 `Unable to bind ... declaration after use`（队友原始代码踩过，补丁见 `doc/patches/`）。改 RTL 时务必注意。
2. **仿真时不要编译 `rtl/mem/`**：testbench 通过 `` `include "mem_model.vh" `` 自带
   `unified_mem` 行为模型（带 `+IMEM=`/`+DMEM=` plusarg），重复定义会冲突；`rtl/mem` 只在 PDS 综合时用。
   单测（`tb_alu_*` 等）默认也不编 SoC 级模块（`core.v` / `mem_bus.v`），跑整核/SoC 测试台才用 `-WithCore`。
3. **Verilog 字符串转义里没有 `\r`**（标准只有 `\n \t \\ \" \ddd`）。iverilog 会把
   `"\r\n"` 里的 `\r` 当成字面字符 `'r'`，期望串永远对不上。换行统一用 `16'h0D0A` 常量拼。
4. **外设任何时候都不该把 X 放上总线**。X 被 CPU 读走会污染分支比较（X 参与 `<` 的结果是 X，
   而 `if (X)` 在 Verilog 里按假处理），导致控制流走错分支 —— 本工程被 `uart_rx` 空 FIFO 坑过。
5. **测试台驱动同步信号要避开 posedge 竞态**：`ack=1; @(posedge clk); ack=0;` 这种写法里，
   任务恢复执行与 always 块采样是同一时间步内的不确定顺序，信号可能被提前清零而丢掉这一拍。
   在 **negedge 之后**驱动就没这个问题。
6. **取指补偿逻辑是承重的**：stall 时是 `imem_addr` 退回 `if_addr_d`，**不是 `pc_r` 后退**。
   搞反会复现"指令被复制执行"的老 bug。细节见 `rtl/core/core.v` PC 段注释。
7. **PDS 工程源文件指向 `../../rtl/**`**：改了 rtl 只需在 PDS 里重新 compile，**不要再往 `pds/` 拷源码副本**。
8. 综合前先把固件 hex 放到 PDS 工程目录（`scripts\sync_firmware.ps1`）。
   统一存储器只用**一份** `mem.hex`（指令+数据并集），旧的 `imem.hex`/`dmem.hex` 已废弃。
9. 外部给的 GBK 文件用"以 GBK 重新打开"查看，**不要覆盖保存**；本项目源码统一 **UTF-8**。
10. 交流与输出默认使用**简体中文**。
11. 提交按里程碑拆分、信息写清改动；**不自动 push**。
12. PDS 是紫光同创的工具（Vivado 是 Xilinx/AMD 的），注意区分。

## 待办
- **ILA 硬件抓波形**（赛题点名要求的评分项，分析部分已完成）：分工是
  **远程平台出 JTAG 通道与波形界面，`.fic` 探针描述文件要本地 PDS 用 Fabric Inserter 生成**。
  流程：加防优化属性（`/* synthesis syn_keep=1 */`）→ Compile/Synthesize → TOOL → Inserter
  选 DebugCore → 配时钟/深度 1024/触发/通道映射 → **保存得到 `.fic`** → P&R → 出 `.sbit`
  → 平台烧写 → 平台 ILA 模块点「导入fic文件」。
  关键坑：**`.fic` 与 `.sbit` 必须来自同一次综合布线**，重新生成比特流后旧 `.fic` 就作废。
  通道位宽上限 256 bit（DebugCore 的 `ips_dbc_compare_256b` 硬件限制），PC 只连低 15 位能省一大半。
  详见 `doc/ila_analysis.md` §7。
- **上本地板卡**：`pds/RV32I_1/RV32I_1.fdc` 目前仍指向**远程 FPGA 平台**；新增的
  `led`/`key`/`uart_rx` 引脚以注释形式预留（盘古 MES2L200HP 实测引脚已填好）。
  未指定 LOC 会让 place & route 失败（compile/synthesize 不受影响）。
- **补 riscv-tests 源码**（可选）：放到 `third_party/riscv-tests`（需联网 clone）。
  **不补也能全量回归** —— `scripts\run_riscv_tests.ps1` 不带参数时会自动回退到随附的
  基线 ELF（`third_party/riscv-tests-elf/`，50 个 = rv32ui 42 + rv32um 8，已入库，约 650KB）。
  之所以把二进制入库：上游 riscv-tests 会变，重新 clone 未必复现同一批二进制，
  基线漂移会让人误以为是自己改坏了 CPU。详见该目录的 README。
- **高阶任务**（详见 `doc/spec.md` §6）：2 路组相联 I/D Cache、BTB + 完整异常/中断、边缘 AI。
  注意：加 I-Cache 后 `fence.i` 必须从 NOP 升级为"冲刷 I-Cache"，否则 `fence_i` 会失败。
