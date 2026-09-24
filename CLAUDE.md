# D:\riscv-cpu-fpga — 嵌入式大赛 FPGA 赛道 · 基于紫光同创(Pango) 的 RISC-V CPU

## 项目目标
- 参赛方向：全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道（选题：**RISC-V 处理器设计**）
- 器件平台：紫光同创 **Logos2 PG2L200H**（速度 -6，封装 FBB676）；工具 **Pango Design Suite 2022.2-SP6.4**
- 当前目标板：**远程 FPGA 平台**（27MHz 固定时钟，约束已可用）；本地"盘古2L200H"开发板器件相同，后期只需改 `.fdc` 引脚/时钟
- 设计内容：**RV32I + M 扩展的 5 级流水线 CPU**（forwarding 前递 + load-use 停顿 + 多拍除法器），集成 UART/GPIO，跑 riscv-tests 与 **CoreMark v1.0**（要求运行 ≥10s）
- 可选加分项：2 路组相联 I/D Cache、BTB 动态分支预测 + 完整异常/中断、边缘 AI 加速

## 当前进度（2026-09-23 晚）
基础任务完成度详见 `doc/base_task_status.md`：

| 基础任务 | 状态 |
|---|---|
| ② ≥3 级流水线 + 数据冲突 + 分支跳转 | ✅ 达标（5 级流水线、前递、load-use 停顿、6 种分支；**分支惩罚 1 拍**，见下） |
| ① RV32I 基础整数指令集 | ✅ **全覆盖**，含 FENCE / FENCE.I / ECALL / EBREAK |
| ③ 集成基础外设（UART/GPIO） | ✅ 存储总线 + 地址译码 + GPIO + UART 收发；演示程序跑通 |

- 验证：riscv-tests rv32ui + rv32um（50 项）→ **49 PASS / 1 FAIL / 0 TIMEOUT**
  （M 扩展的 mul/mulh/mulhsu/mulhu/div/divu/rem/remu 8 项也纳入回归 —— CPU 实现了
   M 扩展且 CoreMark 用 `-march=rv32im` 编译，此前只有手写单测覆盖）
  > 唯一 FAIL 是 `ma_data`（testnum 1），归因是**未对齐访存不做特殊处理**：
  > `load_half = addr_low[1] ? … : …` 假设按访问宽度对齐，而该测试在 0x2001 做
  > `lh`（半字跨字节边界）→ 取错字节。**RISC-V 规范允许实现不支持未对齐访问**，
  > 属架构取舍，不是 bug。
  > ⚠️ **2026-09-21 勘误**：此前本文档与多份报告称"取指重定向后 `ma_data` 自动
  > 转 PASS、说明它是冲刷路径上的潜在 bug"——**该结论无法复现，已撤回**。
  > 用取指重定向【之前】的 RTL 复测，同样是 FAIL (testnum 1)，改造前后行为完全一致；
  > 且基线 ELF 的 SHA256 全部校验通过、riscv-tests 源码不存在，不存在"重编译出
  > 不同二进制"的可能。原文"架构取舍"的归因才是对的。详见
  > `doc/reports/2026-09-21_branch_opt_verify.md` §2.1。
  > 未对齐通路仍无专门测试覆盖，不把它当作已实现的功能对外承诺。
- **CoreMark**：2026-09-15 已在远程平台实测通过（旧取指路径，ITER=700，
  `Total ticks 294,065,438` → 10.89 秒，`Correct operation validated`，
  四个 CRC 与仿真逐位一致 → **CPU 真机算得对**）。
  2026-09-23 两轮分支优化后，仿真每迭代降到 **358,846** 周期 → **2.787 CoreMark/MHz**。
  > ⚠️ **改了流水线就必须重算 ITER，否则 CoreMark 判 invalid。**
  > **速算式：`ITER = 270,000,000 ÷ 每迭代周期数`**（27 MHz × 10 s = 2.7 亿拍，
  > 取整后留 5~10% 余量）。例：358,846 → 270e6/358846 ≈ 752 → 取 820。
  > 420,094 周期/迭代时 ITER=700 = 10.89s（已上板实测）；382,972 时 ITER=770 = 10.92s；
  > **当前 358,846，ITER=770 只剩 10.23s（余量仅 2.3%，太险）→ 取 820**（10.90s，余量 9.0%）。
  > 上板流程：`run_coremark.ps1 -Iter 820 -SkipSim` → `sync_firmware.ps1` → PDS 重新综合。
  > ✅ **2026-09-23 已在本地盘古板实测复测**：`Total ticks 294,262,913` → **10.898 s**，
  > 358,857 拍/迭代，与仿真 358,846 差 **+0.0031%**；`Correct operation validated`，
  > 四个 CRC 与仿真逐位一致。原始日志 `doc/board/uart_20260923_201540.txt`。
  > ⚠️ CoreMark 打印的 `Total time (secs)` / `Iterations/Sec` 是**整数截断**
  > （`HAS_FLOAT=0`），显示 10 / 82，真实值 10.898 / 75.24 —— 一律用
  > `Total ticks ÷ 27,000,000` 自己算。
  > ⚠️ **别用 ITER=1 的测试台总周期（当前 1,462,898）去推算迭代成本**。那是仿真
  > 测试台的总周期，含约 108 万周期的一次性串口打印开销；而 CoreMark 自己的
  > `Total ticks` 计时在打印**之前**就停了，不含打印。两个口径不同，混用会把迭代
  > 成本算错，进而把 ITER 估得偏小（本项目据此写成"ITER≈200 约 10s"，
  > 实测只有 3.11s，被判 invalid）。
- **本地盘古板上板跑通（2026-09-23 首次）**：clk/UART/GPIO 全链路验证通过，
  27 MHz 实测确认（串口无乱码）。**上板教程见 `doc/board_bringup.md`**，
  实测证据见 `doc/board/`，引脚出处见 `pds/RV32I_1/RV32I_1.fdc` 头部注释。
  > ⚠️ **上板 top module 是 `cpu_top_board`，不是 `cpu_top`**（`rtl/top/cpu_top_board.v`）——
  > 它把 `pc[31:0]`/`done` 挡在板外，因为 PDS 会把未约束的输出自动布到 BANKR5
  > （板上有 SFP/HSST）的真实引脚上。仿真仍用 `cpu_top`（`pc` 是 `+TRACE` 与
  > TIMEOUT 诊断的数据源，不能删）。
  > ⚠️ **板上 Jtag 与 USB UART 是两个独立接口**，两根 USB 线都要插 ——
  > 只插 Jtag，串口永远没输出（这是最容易卡住的一步）。
- 演示程序：`scripts\run_demo.ps1`（读按键 → 写 LED → 串口打印 + 串口回显）
  串口查看用 `scripts\serial_monitor.ps1`（零依赖，用 .NET 自带 SerialPort，
  默认把输出落盘到 `doc/board/uart_<时间戳>.txt`）
- **平台坑**：远程平台偶发"固件下载完成但设备唤醒失败"，**多烧录几次即可**，不是设计问题 ——
  别浪费时间怀疑自己的 RTL
- **工程坑**：综合前必须把 `mem.hex` 放进 PDS 工程目录（`scripts\sync_firmware.ps1`）。
  缺失时 PDS 只报一行 `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** ——
  但 BRAM 是空的，板上什么都不跑，且没有任何其他报错，极难排查。
  > ⚠️ **同一类坑的第二种形态（2026-09-21 实踩）：文件在，但内容过期。**
  > PDS 综合读的是 `pds\RV32I_1\mem.hex`（**不是** `sim\programs\mem.hex`），
  > 而且**从不检查时间戳**。跑过 `run_demo.ps1` 或 `run_riscv_tests.ps1` 之后再
  > `sync_firmware.ps1`，工程里就留下 demo / riscv-test 的镜像；此后无论怎么改 RTL、
  > 重新综合布线，**板上跑的都还是那个旧程序**，而 PDS 全程零报错。
  > 判据：看 `pds\RV32I_1\pds.log` 里的 `Loading memory data from file ... mem.hex`，
  > 再核对 `mem.hex` 的字数与 ELF 的 `.text` 规模是否相当（CoreMark = 4209 字）。
  > **上板前的固定动作：`run_coremark.ps1 -Iter 770 -SkipSim` → `sync_firmware.ps1` → PDS 综合。**
- **流水线效率基线（2026-09-23 两轮分支优化后实测，改动流水线后用来对比）**：CoreMark
  计时区间 **358,846** 拍 / 提交 288,056 条指令 → **CPI 1.2458**；损失构成：
  **分支惩罚 14.0%（50,070 拍）** + load-use 停顿 5.8%。实测方法见
  `doc/ila_analysis.md`，测试台已内置 `+PROF` / `+TRACE_*`（默认关闭，不影响回归）。
  > 三轮演进：**420,070**（基线，惩罚 3 拍，冲刷占 26.5%）→ **382,972**（取指重定向，
  > 2 拍）→ **358,846**（ID 级静态后向预测 + jal，1 拍）。CoreMark/MHz 2.380 → 2.611 → **2.787**。
  > 气泡分解精确闭合：`288,056（提交）+ 20,720（load-use）+ 50,070（分支）= 358,846`。
  > 优化记录见 `doc/reports/2026-09-21_branch_opt_verify.md`。
- **高阶任务②（完整异常/中断）已实现**（2026-09-23）：CSR 文件 + 6 条 CSR 指令 + `mret`
  + 六类同步异常（非法指令/EBREAK/未对齐 load+store/ECALL/写只读 CSR）+ 定时器中断（CLINT）。
  自写汇编测试在 `sim/tests/`，一键 `scriptsun_own_tests.ps1`。
  > 未做：BTB（实测剩余空间仅约 2.3%）、外部中断 MEIP（通路具备但无测试）。
  > 关键取舍见 `doc/spec.md` §6：只支持 M 模式（MPP 硬连线）；未实现的 CSR 读 0、写忽略、
  > 不抛非法（否则 50 个基线 ELF 的 init 段会全挂）。

**回归纪律（重要）**：改动 RTL 后，riscv-tests 的 **49/1/0** 与 CoreMark 的
**计时区间 358,846 拍**（测试台总周期 1,462,898）必须同时保持不变
（除非本次改动的目的就是改变某一项）。后者是"没碰坏流水线"最灵敏的探针。

## 仓库结构（以此为准，勿再新建顶层目录）
- `rtl/core/`    CPU 核：`core.v`(5 级流水线/冒险/分支/trap) `control.v`(主控译码) `alu.v`(含 M 扩展乘法) `divider.v`(多拍除法) `imm_gen.v` `regfile.v`
                 `csr_file.v`(**CSR 寄存器组 + trap/mret 副作用**，只支持 M 模式)
- `rtl/mem/`     `unified_mem.v` —— **统一存储器**（指令+数据共用一块双端口 BRAM：A 口取指 / B 口访存）。
                 行为级、仅 PDS 综合用，`$readmemh` 读 PDS 工程目录下的 `mem.hex`
- `rtl/bus/`     `addr_map.vh`(地址映射单点定义) `mem_bus.v`(**唯一的地址译码处** + 读数据 mux)
- `rtl/periph/`  `uart_tx.v`(发送，1024 深 FIFO) `uart_rx.v`(接收，16 深 FIFO、读弹出) `gpio.v`(LED+按键)
- `rtl/top/`     `cpu_top.v` SoC 顶层，只做连线（地址映射见 `rtl/bus/addr_map.vh`）
                 `cpu_top_board.v` **上板专用顶层**（PDS 的 top）：包住 `cpu_top`，
                 不引出 `pc[31:0]`/`done`（原因见"当前进度"里的 ⚠️）
- `rtl/top.v`    早期 LED 点灯练习工程顶层（保留）
- `sim/`         `mem_model.vh`(存储器行为模型，被各 tb `include)
                 `tb_riscv.v` `tb_coremark.v` `tb_demo.v`（集成）+ `tb_alu_*` `tb_control.v` `tb_gpio.v` `tb_uart_rx.v` `tb_uart_fifo.v`（单元）
                 `sim/tests/` **自写汇编测试**（`exceptions.S` `timer_irq.S` + `test_macros.h`）
                 `sim/tools/tb_debug_trap.v` 逐拍调试台（需 -WithCore；放在 tools/ 以免被 run_sim 的通配捞走）
                 `sim/programs/` 为生成的 hex/ELF（**不入库**）
- `scripts/`     `run_sim.ps1` `run_coremark.ps1` `run_riscv_tests.ps1`(支持 `-ElfDir` 免源码回归) `run_demo.ps1` `sync_firmware.ps1`
                 `run_own_tests.ps1`(**自写测试**：汇编 → 跑 → 汇总) `elf2mem.py`(出 imem/dmem/mem 三种 hex)
                 `trace2svg.py`(逐拍 trace → 流水线波形 SVG) `riscv_tests_link.ld` `coremark_port/` `demo/`(演示程序)
                 `build_bitstream.ps1`(**上板唯一入口**：固件→同步→综合出 `.sbit`，一条命令)
                 `serial_monitor.ps1`(**串口抓取**，零依赖；默认落盘 `doc/board/uart_<时间戳>.txt`)
- `pds/RV32I_1/`  **正式 CPU 工程**（`.pds` 内源文件已重指 `../../rtl/**`，单一真相）
                 `bitstreams/` 归档的 `.sbit`（`.sbit` 被 gitignore，只入库 README）
                 `bak_2026-09-21_ila/` 09-21 那次 ILA 调试版的产物归档（`.fic`/`timing`/`impl.tcl`）
- `pds/riscv_cpu/` 早期 LED 练习工程
- `third_party/coremark/`  官方 CoreMark 源码（含 LICENSE）
- `third_party/riscv-tests-elf/`    50 个**预编译基线 ELF**（回归金标准）
- `third_party/riscv-tests-env/`    上游 riscv-tests 的 **env 头文件**（encoding.h / riscv_test.h），
                                    自写汇编测试要用；从队友原件抢救入库，详见其 README
- `doc/`          `plan.md`(计划) `spec.md`(架构) `base_task_status.md`(基础任务核对) `RV32I指令集参考.md` `setup_env.md`(环境搭建) `test_report_riscv-tests.md` `resource_efficiency.md`(赛题三条性能指标成文) `ila_analysis.md`(流水线效率+ILA方案) `board_bringup.md`(**上板教程**) `board/`(**板上实测证据**：串口原始日志 + 索引) `figures/`(波形图) `patches/`(给队友的兼容补丁) `reports/`(会话报告/交接)
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
  - **`scripts\build_bitstream.ps1 coremark|demo`** —— **上板唯一入口**：
    生成固件 → 同步到 PDS 工程（并校验 `mem.hex` 字数）→ 综合布线出 `.sbit`。
    **`generate_bitstream\cpu_top_board.sbit` 这个名字看不出里面是哪个固件**，
    别猜，用这条命令确定。详见 `doc/board_bringup.md` §3

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
13. **测试台里悬空的输入端口会变成 Z，不是 0**。`tb_riscv.v` 一度漏接了
    `mem_bus` 的 `.irq_timer`，于是 core 里 `int_timer = mie.MTIE & Z` 是不定态，
    中断行为完全随机。**症状极具迷惑性：同一份 RTL、同一份 hex，调试台跑出
    "正常停在 PASS 自旋"，tb_riscv 跑出 pc 跑飞**。两个测试台结果不一致时，
    先怀疑接线不一致，别怀疑 RTL。
14. **C 预处理器会把 `.text.init` 拆成 `.` `text` `.` `init`** —— `init` 是独立
    token。`sim/tests/test_macros.h` 里补 riscv-tests 的 `init` 宏时若写成
    `#define init nop`，段名就被静默改写成 `.text.nop`，链接脚本匹配不到、
    内存布局整体错位（`_start` 从 0x0 跑到 0x1000）。
    **上游用汇编宏（`.macro init / .endm`）正是为了避开这个。**
15. **静态"全零字按气泡处理"是承重的**：取指是同步读、1 拍延迟，复位后第一拍
    发出的地址、数据下一拍才回来，所以那一拍 IF/ID 锁存到的是存储器的复位值
    `0x00000000`。`control.v` 的 `default` 必须对它例外（否则上电第一拍就 trap），
    `core.v` 的 `if_id_valid` 也用它判"是不是真指令"（否则中断会拿气泡的
    `id_ex_pc`=0 去写 mepc）。`tb_control` 里有回归锁。
16. **PDS 会把"未在 `.fdc` 里指定 LOC 的输出端口"自动布到 BANKR5 的真实引脚上**
    （实测 `pc[0]→M2`、`pc[10]→M5`）。本板 BANKR5 接的是 SFP/HSST，
    32 位输出乱布有驱动冲突风险 —— 所以上板 top 是 `cpu_top_board`（挡掉 `pc`/`done`），
    **不是在 `cpu_top` 里删端口**（`pc` 是仿真侧 `+TRACE` 与 TIMEOUT 诊断的数据源）。
17. **手册是 0 起编号、板上丝印是 1 起编号**：手册 `KEY0..KEY4` = 丝印 `SW3..SW7`。
    另外 **LED 丝印（D12..D19）相对开关是乱序的** —— 这是板卡硬件现状，不是映射错误
    （根因：按键引脚按排列分配，LED 引脚按布线就近分配）。所以 `led[]` 已按
    **开关正下方**重排，`.fdc` 头部有完整两张表。
18. **板上 Jtag 和 USB UART 是两块独立接口，要插两根 USB 线** —— Jtag 是 FTDI
    （枚举成两个 COM 口），USB UART 是 CP2102（枚举成一个 `Silicon Labs CP210x` 口）。
    **只插 Jtag，串口永远没输出**，这是上板最容易卡住的一步。
19. **PDS 命令行的实测事实**（`pds_shell.exe`）：
    `-run <action>` 的 action ∈ `compile / synthesize / dev_map / pnr / report_timing /
    gen_bit_stream`，**每个 `-run` 都会把前面的步骤重跑一遍**（所以 `-run gen_bit_stream`
    跑完整条链约 5 分钟）；`-file <tcl>` 与 `-project` **不能同时用**；
    **每次 `gen_bit_stream` 都会先清空 `generate_bitstream/`**（旧版进 `bak/`），
    重要比特流要及时归档到 `pds/RV32I_1/bitstreams/`。
20. **trap 必须同时清 EX/MEM，只清 ID/EX 不够**：`EX/MEM <= ID/EX` 是**同一个沿**
    发生的，清 ID/EX 只保证下一拍是气泡，这一拍 EX/MEM 照样把肇事指令收下 ——
    实测现象是"未对齐 `sw` 既正确陷入了 `mcause=6`，内存却也被改了"。
21. **CSR 写必须从 EX 级提交**（不是 WB）。riscv-tests 里 `csrw mepc, t0` 与 `mret`
    只隔 1 条指令，从 WB 提交会让 `mret` 读到复位值 0 → 跳回 `_start` → 50 个 TIMEOUT。
22. **`csr_wr_illegal` 只看地址，必须与"这条指令真的在写吗"相与** ——
    `csrr a0, mhartid` 是 RS 且 rs1=x0、根本不写，却被判成非法 → init 每轮 trap。
23. **`.sbit` 不进仓库，且 `generate_bitstream/cpu_top_board.sbit` 看不出是哪个固件**。
    `.sbit` 被 gitignore（9 MB/个），**队友 clone 下来一个比特流都没有**，必须自己生成；
    而那个固定文件名只代表"最后一次综合的那版"。PDS 的 Programmer 会记住上次的路径，
    所以"只点 Program 不重新浏览"极易烧成上一版 —— **2026-09-23 实踩：想烧跑分版
    结果烧成了演示程序版**（现象：按键有反应、串口是 `KEY=0x..`）。
    判据：`scripts\build_bitstream.ps1 coremark|demo` 会打印 md5，**别靠文件名猜**。

## 待办
- **ILA 硬件抓波形**（赛题点名要求的评分项，分析部分已完成）：分工是
  **远程平台出 JTAG 通道与波形界面，`.fic` 探针描述文件要本地 PDS 用 Fabric Inserter 生成**。
  流程：加防优化属性（`/* synthesis syn_keep=1 */`）→ Compile/Synthesize → TOOL → Inserter
  选 DebugCore → 配时钟/深度 1024/触发/通道映射 → **保存得到 `.fic`** → P&R → 出 `.sbit`
  → 平台烧写 → 平台 ILA 模块点「导入fic文件」。
  关键坑：**`.fic` 与 `.sbit` 必须来自同一次综合布线**，重新生成比特流后旧 `.fic` 就作废。
  通道位宽上限 256 bit（DebugCore 的 `ips_dbc_compare_256b` 硬件限制），PC 只连低 15 位能省一大半。
  详见 `doc/ila_analysis.md` §7。
- ✅ **上本地板卡已完成**（2026-09-23）：`.fdc` 已全部改为盘古板实测引脚，
  上板 top 是 `cpu_top_board`，教程见 `doc/board_bringup.md`。
  **本地板现在插两根 USB 线（Jtag + USB UART）即可烧录与看串口。**
  剩下的板卡相关待办：
  - ⬜ **ILA 硬件抓波形**（见上）—— 本地板在手后可以不走远程平台，
    改走本地 PDS Debugger 扫 JTAG 抓（`doc/ila_analysis.md` §7.4 备选路径）
  - ⬜ **演示视频/照片**：演示程序已在板上跑通（LED 已按开关位置重排），
    但 `doc/board/` 里还只有串口文本，缺录像/照片
  - ⬜ `doc/base_task_status.md` 的板卡相关描述若还有"引脚以注释预留"字样，需清理
- **补 riscv-tests 源码**（可选）：放到 `third_party/riscv-tests`（需联网 clone）。
  **不补也能全量回归** —— `scripts\run_riscv_tests.ps1` 不带参数时会自动回退到随附的
  基线 ELF（`third_party/riscv-tests-elf/`，50 个 = rv32ui 42 + rv32um 8，已入库，约 650KB）。
  之所以把二进制入库：上游 riscv-tests 会变，重新 clone 未必复现同一批二进制，
  基线漂移会让人误以为是自己改坏了 CPU。详见该目录的 README。
- **高阶任务**（详见 `doc/spec.md` §6）：
  - ✅ **完整异常/中断已做**：CSR 文件 + 6 条 CSR 指令 + mret + 六类同步异常
    + 定时器中断（CLINT）。测试 `sim/tests/`，一键 `scriptsun_own_tests.ps1`
  - ⬜ **BTB 动态分支预测**：实测剩余可优化空间只有约 **2.3%**（前向 taken + jalr），
    见 `doc/ila_analysis.md` §6
  - ⬜ **外部中断 MEIP**：通路已具备（cpu_top 接了 UART RX 非空），但**没有测试**，
    不得当作已验证能力
  - ⬜ 2 路组相联 I/D Cache：**负收益**（存储器是单周期 BRAM，访存恒 1 拍、无缺失惩罚）
  - ⬜ 边缘 AI：32KB BRAM 是硬墙（无片外存储），当前硬件条件不可行
