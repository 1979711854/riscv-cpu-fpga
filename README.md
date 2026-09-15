# 基于紫光同创 FPGA 的 RISC-V 五级流水线 CPU

> 全国大学生嵌入式芯片与系统设计竞赛 —— FPGA 赛道 · 紫光同创选题

器件：紫光同创 **Logos2 PG2L200H-6FBB676**　工具：**Pango Design Suite 2022.2-SP6.4**
处理器：**RV32I + M 扩展**，5 级流水线（IF/ID/EX/MEM/WB）

## 当前成绩

| 项目 | 结果 |
|---|---|
| riscv-tests（rv32ui + rv32um，50 项） | **49 PASS / 1 FAIL / 0 TIMEOUT** |
| CoreMark v1.0 **板上实测** | **10.89 秒**，`Correct operation validated`，**2.38 CoreMark/MHz** |
| 时序（27MHz，多 seed） | Setup +15.495ns / Hold +0.145ns，**失败端点 0** |

> 唯一 FAIL 是 `ma_data`（未对齐访问）。RISC-V 规范 §2.6 把它列为**可选**；
> 且 gcc 假设变量自然对齐、**永远不会生成未对齐的 load/store**，所以不影响任何 C 程序。

---

## 🚀 主流程：在 PDS 里做

### 第 1 步：打开工程

```
PDS → File > Open Project →  pds/RV32I_1/RV32I_1.pds
```

> ⚠️ **工程是 `pds/RV32I_1/`，不是 `pds/riscv_cpu/`**（后者是早期的 LED 练习工程）。
> 工程里的源文件指向仓库根的 `../../rtl/**`，**不要在 `pds/` 下另存 RTL 副本**，
> 否则两处会漂移。改 RTL 只需在 PDS 里重新 compile。

### 第 2 步：跑流程

```
compile → synthesize → device map → place & route → generate bitstream
```

产物：`pds/RV32I_1/generate_bitstream/cpu_top.sbit`

### 第 3 步：烧录

> ⚠️ 同目录的 `cpu_top.smsk` 是掩码文件，**大小和文件头与 `.sbit` 一模一样**，别点错。

**已知无害告警**（可以忽略）：
- `C: Bitstream-2001: SCBV has not been set` —— 配置 bank 电压提醒，不影响上板
- `W: Port 'key[*]' / 'uart_rx' is not constrained` —— GPIO 引脚未分配，跑 CoreMark 无影响

---

## ⚠️ 唯一需要命令行的一步：编译 C 程序

**PDS 不是 C 编译器**，CoreMark 和演示程序都是 C，必须先用 RISC-V gcc 编成机器码，
再转成 BRAM 能加载的 `mem.hex`。

> 💡 **只有换程序时才需要做这一步。** 平时改 RTL 的话，流程全在 PDS 里。

### 需要装的工具链

```
RISC-V GCC:  D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin
Python 3:    用于把 ELF 拆成 hex
```

### 两条命令（几秒钟）

```powershell
# 1) 生成固件（三选一）
scripts\run_coremark.ps1 -Iter 700 -SkipSim   # 跑分用：板上约 10.9 秒，满足 ≥10s
scripts\run_demo.ps1 -SkipSim                 # 演示用：读按键 → 写 LED → 串口打印
scripts\build_c.ps1 -Dir scripts\myprog       # 你自己的 C 程序（见下）

# 2) 同步到 PDS 工程目录
scripts\sync_firmware.ps1
```

然后回 PDS 重新 compile → … → bitstream。

### 写自己的 C 程序

复制 `scripts/template/` 改 `main.c` 即可，另外三个文件（`uart.h` / `start.S` / `link.ld`）
是裸机环境必需的脚手架：

```powershell
scripts\build_c.ps1 -Dir scripts\myprog -Run    # 编译 + 在电脑上跑一遍看串口输出
scripts\build_c.ps1 -Dir scripts\myprog -Sync   # 编译 + 同步到 PDS 工程
```

详见 `scripts/template/README.md`（含五条裸机硬约束）。

> `-SkipSim` = 只生成固件、不跑仿真。**上板流程只需要 `mem.hex`**，加上这个开关
> 从十几分钟降到几秒。想去掉它跑完整仿真（核实 CoreMark 数值）也可以，ITER=700
> 大约要跑十几分钟。

> 🔴 **`mem.hex` 缺失时 PDS 不会拦住你！** 它只报一行
> `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** —— 但 BRAM 是空的，
> 板上什么都不跑，**且没有任何其他报错**。这个坑踩过，极难排查。
> 综合前务必确认 `pds/RV32I_1/mem.hex` 存在。

---

## 📁 目录结构

```
riscv-cpu-fpga/
├── rtl/                     RTL 源码
│   ├── core/                CPU 核：core/control/alu/divider/imm_gen/regfile
│   ├── mem/                 unified_mem.v  统一存储器（仅 PDS 综合用）
│   ├── bus/                 addr_map.vh + mem_bus.v（唯一的地址译码处）
│   ├── periph/              uart_tx / uart_rx / gpio
│   └── top/cpu_top.v        SoC 顶层
│
├── pds/RV32I_1/             ★ PDS 工程（源文件指向 ../../rtl/**）
│   ├── RV32I_1.pds          工程文件
│   ├── RV32I_1.fdc          引脚/时钟约束
│   ├── mem.hex              固件快照（BRAM 初值）
│   └── README.md            工程交接说明（含 7 条踩过的坑，建议先读）
│
├── sim/                     仿真测试台（可选，见下）
├── scripts/                 一键脚本 + 固件生成工具
├── doc/                     架构、进度、测试报告
└── third_party/             CoreMark 源码、riscv-tests 基线 ELF
```

**生成物不入库**：`pds/RV32I_1/` 下的 `compile/ synthesize/ device_map/ place_route/`
`report_timing/ generate_bitstream/` 等都已被 `.gitignore` 屏蔽，各自本地重新编译即可。

---

## 地址映射

单点定义在 `rtl/bus/addr_map.vh`：

```
0x0000_0000 - 0x0000_7FEF   RAM（32KB 内可用部分，栈顶 ≤ 0x7FF0）
0x0000_7FF0 - 0x0000_7FFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0x7FF4 R 周期计数   0x7FF8 W done   0x7FFC W UART 发送
0x8000_0000 起              外设区
    0x00 W LED / R {key, led}   0x08 W UART 发送
    0x0C R UART 接收（读弹出）   0x10 R 周期计数
```

---

## 🔧 可选：命令行仿真与回归

改 RTL 后建议跑一遍，比上板快得多：

```powershell
scripts\run_riscv_tests.ps1     # 49 PASS / 1 FAIL / 0 TIMEOUT（不需联网）
scripts\run_sim.ps1             # 6 个模块单元测试
scripts\run_coremark.ps1 -Iter 1
scripts\run_demo.ps1            # 演示程序端到端 7/7 PASS
```

**回归纪律**：改动 RTL 后，下面两条必须同时保持不变（除非本次改动就是要改变某一项）：

1. riscv-tests 的 **49/1/0**
2. CoreMark ITER=1 的 **1,529,499 周期** ← "没碰坏流水线"最灵敏的探针

工具链（scoop 安装）：`scoop install iverilog gtkwave`

---

## 📚 文档索引

| 文件 | 内容 |
|---|---|
| `pds/README.md` | **PDS 工程交接说明**（先读这个） |
| `doc/spec.md` | 架构：流水线、存储器与总线、地址映射、已知限制 |
| `doc/base_task_status.md` | 基础任务三条逐条核对 |
| `doc/test_report_riscv-tests.md` | 回归结果、CoreMark 口径推导、板上验证证据 |
| `doc/plan.md` | 开发计划 |

---

## 🔄 Git 协作

```powershell
git pull origin main                    # 开始工作前
git add .
git commit -m "feat: 描述你做了什么"
git push origin main
```

提交信息前缀：`feat:` 新功能 · `fix:` 修复 · `docs:` 文档 · `refactor:` 重构

> ⚠️ **不要提交 PDS 生成物**（`compile/`、`synthesize/`、`.sbit` 等）。
> `.gitignore` 已配置好，用 `git add .` 时它们不会被加入。
> 唯一例外是 `pds/RV32I_1/mem.hex`——它是固件快照，有意入库，便于复现比特流。

---

## ⚠️ 常见问题

**Q：PDS 打开工程后提示找不到源文件？**
A：确认仓库结构完整（`rtl/` 与 `pds/` 同级）。工程用的是相对路径 `../../rtl/**`，
整个仓库目录结构变了就会失效。

**Q：板上什么都没反应，串口没输出？**
A：先查 `pds/RV32I_1/mem.hex` 是否存在。缺失时 PDS 会静默生成空 BRAM 的比特流，
板上什么都不会跑（详见上文红字）。

**Q：烧录提示"设备唤醒失败"？**
A：远程平台偶发问题，**多烧录几次即可**，不是设计问题。

**Q：改了 RTL，板上行为没变？**
A：PDS 里的 compile 是不是没重跑？另外确认 PDS 打开的是 `pds/RV32I_1/` 而不是旧副本。
