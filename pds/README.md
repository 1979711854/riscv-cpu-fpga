# PDS 工程目录 —— 交接说明

> 更新：2026-09-15　面向：接手本工程的队友
> 你原来那份 5 级流水线 CPU 仍在，但**存储器、总线和外设做了一次重构**，构建流程也跟着变了。
> 这份文档说清三件事：**现在是什么状态**、**和交接时有什么不同**、**还剩什么没做**。

---

## 一、先看这些

| 我想…… | 去这里 |
|---|---|
| 打开工程 | PDS → `File > Open Project` → `pds/RV32I_1/RV32I_1.pds` |
| 了解架构 | `doc/spec.md`（当前实现的权威描述） |
| 了解基础任务达标情况 | `doc/base_task_status.md` |
| 了解测试结果与基线 | `doc/test_report_riscv-tests.md` |
| 跑回归 | `scripts/run_riscv_tests.ps1`（不带参数即可，不需联网） |

> ⚠️ **不要从 `riscv32-FPGA-pds/RV32I_1/` 打开。** 那是你交接时的原始副本，里面的 RTL
> 已是旧版本。正式工程是 `pds/RV32I_1/`，源文件指向仓库根的 `../../rtl/**`（单一真相）。

---

## 二、交付状态（一句话）

**基础任务三条全部达标，赛题硬指标（CoreMark ≥10s）已在远程平台实测通过。**

| 赛题要求 | 状态 | 证据 |
|---|---|---|
| ① 支持 RV32I 基础整数指令集 | ✅ 全覆盖 | riscv-tests **49 PASS / 1 FAIL / 0 TIMEOUT**（含 M 扩展 8 项） |
| ② ≥3 级流水线 + 数据冲突 + 分支跳转 | ✅ | 你原来的 5 级流水线，未改结构 |
| ③ 集成 UART / GPIO 用于系统控制与结果输出 | ✅ | 总线 + GPIO + UART 收发；演示程序仿真端到端 7/7 PASS |
| 测评：CoreMark 运行 ≥10s | ✅ **板上实测** | `Total ticks 294,065,438` → **10.89 秒**，`Correct operation validated` |
| 测评：CoreMark/MHz | ✅ | **2.38**（真机 420,094 周期/迭代 vs 仿真 420,414，差 0.08%） |

---

## 三、和交接时的差异（重要）

### 3.1 存储器：指令/数据合并成一块

**原来**：`imem` + `bram` 两块独立 BRAM（哈佛）。
**现在**：`rtl/mem/unified_mem.v` 一块双端口 BRAM —— A 口取指、B 口访存。

**为什么必须改**：riscv-tests 的 `fence_i` 测的是**自修改代码**（用 `sh` 把新指令写进代码区，
`fence.i` 后跳过去执行）。哈佛结构下 store 永远改不到指令，`fence.i` 做成 NOP 也没用，
测试必然 TIMEOUT。合并后 store 对取指天然可见，`fence.i` 按 NOP 实现即满足语义。

副产品：BRAM 用量减半，且这正是 `doc/spec.md` 早先写下的 modified-Harvard 路线。

### 3.2 访存从核内移到总线上

**原来**：`core.v` 内部直接例化 `bram`，顶层用地址比较硬译码 MMIO。
**现在**：`core.v` 只给出 `mem_addr/mem_wdata/mem_byte_en/mem_we/mem_re/mem_rdata`，
地址译码全部收敛到 `rtl/bus/mem_bus.v`。**核不再知道存储器映射。**

`mem_bus.v` 头注释里写了两条**硬约束**，改动前务必读：

1. **写通路零寄存器** —— 否则 `st_ld`/`ld_st` 这类"存完立刻读回"会读到旧值
2. **读数据与读选择位都在 MEM→WB 沿寄存**，所有地址源统一 1 拍延迟

### 3.3 新增外设

- `rtl/periph/gpio.v` —— 8 位 LED 输出 + 8 位按键输入（2 级同步，不做硬件消抖）
- `rtl/periph/uart_rx.v` —— UART 接收，8N1 115200，16 深 FIFO，**读操作弹出**
- `rtl/periph/uart_tx.v` —— 你的原文件，未改动

### 3.4 补了 4 条指令

`control.v` 新增 `7'b0001111`（FENCE/FENCE.I → NOP）与 `7'b1110011`
（ECALL → NOP；EBREAK → 置 `sys_ebreak` 停机钩子，经 ID/EX→EX/MEM 送到核外）。

### 3.5 ⚠️ 一处**没改**但容易被"好心改坏"的地方

`core.v` 里取指通路的补偿逻辑是**承重的**，请不要动：

```
stall / div_stall 时：pc_r 与 if_addr_d 都保持不动，
由 imem_addr 的 mux 退回 if_addr_d[14:2]（重读上一拍已读过的同一 word）
```

**是 `imem_addr` 后退，不是 `pc_r` 后退。** 若把 `pc_r` 也往后推，连续两拍 stall 会让
同一条指令被取两次，非幂等指令被重复执行 —— 你交接的那版之前就踩过这个坑
（`sb`/`sh`/`sw` 曾因此 FAIL，后来你修好了）。`ex_flush_d` 的第二道冲刷同理。

---

## 四、构建流程（和以前不同了）

### 4.1 固件：只用一份 `mem.hex`

**统一存储器只初始化一个数组**，所以不再用 `imem.hex` + `dmem.hex`：

```powershell
# 1) 生成固件（选一种）
scripts\run_coremark.ps1 -Iter 700     # 跑分用：10.89s，满足赛题 ≥10s
scripts\run_demo.ps1                   # 演示用：读按键→写 LED→串口打印

# 2) 同步到本工程目录（会删掉过期的 imem.hex/dmem.hex）
scripts\sync_firmware.ps1
```

> ⚠️ **`mem.hex` 缺失时 PDS 不会拦住你。** 它只报一行
> `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** —— 但 BRAM 是空的，
> 板上什么都不跑，且**没有任何其他报错**。这个坑我们踩过，极难排查。

### 4.2 PDS 里跑流程

```
compile → synthesize → device map → place & route → generate bitstream
```

产物：`generate_bitstream/cpu_top.sbit`（9,188,552 字节，约 8.8 MB）

> 同目录的 `cpu_top.smsk` 是掩码文件，**大小和文件头与 `.sbit` 完全一样**，上传平台时别点错。

### 4.3 已知的无害告警

- `C: Bitstream-2001: SCBV has not been set.` —— 配置 bank 电压提醒，**实测不影响上板运行**
- `W: Port 'key[*]' / 'uart_rx' is not constrained` —— 见 §7 待办

---

## 五、地址映射

单点定义在 `rtl/bus/addr_map.vh`（软件侧镜像 `scripts/demo/addr_map.h`）：

```
0x0000_0000 - 0x0000_7FEF   RAM（统一存储器 32KB 内可用部分）
0x0000_7FF0 - 0x0000_7FFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0x7FF4  R  周期计数器[31:0]      0x7FF8  W  done        0x7FFC  W  UART 发送
0x8000_0000 起              外设区（字内偏移 = addr[5:2]）
    0x00  W LED[7:0] / R {key[7:0], led[7:0]}     0x08  W UART 发送
    0x0C  R UART 接收（读弹出）                     0x10  R 周期计数器
```

> ⚠️ RAM 译码**显式挖掉了 `0x7FF0~0x7FFF`**。若把它改回连续译码，CoreMark 写 `0x7FF8`
> 会落进 RAM，`done` 永不拉高。
> **栈顶必须 ≤ 0x7FF0**（CoreMark 用 0x7000）。

---

## 六、已验证的结果（附复现命令）

```powershell
scripts\run_riscv_tests.ps1     # 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_sim.ps1             # 6 个单元测试全过
scripts\run_coremark.ps1 -Iter 1
scripts\run_demo.ps1            # 演示程序端到端 7/7 PASS
```

**riscv-tests：49 PASS / 1 FAIL / 0 TIMEOUT**（50 项）
- 唯一 FAIL 是 `ma_data`（未对齐访问）—— 见 §7
- `fence_i` 已从 TIMEOUT 转 PASS
- rv32um 的 8 项（mul/mulh/mulhsu/mulhu/div/divu/rem/remu）**一次全过**，
  给 M 扩展补上了官方测试背书（此前只有手写单测）

**CoreMark（远程平台实测，ITER=700）**
```
Total ticks      : 294065438     → 实际 10.89 秒
Iterations       : 700
seedcrc/crclist/crcmatrix/crcstate 四个 CRC 与仿真逐位一致
Correct operation validated.
```

**时序（27MHz，多 seed 报告）**
```
Setup(Slow) 最差裕量 : +15.495 ns     失败端点 : 0
Hold(Slow)  最差裕量 : +0.145 ns      失败端点 : 0
收敛率 : 100%
```
裕量还有 15.5ns / 周期 37.037ns → 关键路径约 21.5ns，**理论上还能跑到约 46MHz**
（粗略外推，真要提频需要重新约束和验证）。

### 回归纪律（请务必遵守）

改动 RTL 后，**这两条必须同时保持不变**（除非本次改动的目的就是改变某一项）：

1. riscv-tests 的 **49/1/0**
2. CoreMark ITER=1 的 **1,529,499 周期**

第 2 条是"没碰坏流水线"最灵敏的探针 —— 多一个停顿、少一次前递都会让它变。

---

## 七、还没做的（截至 2026-09-15）

### 高优先级

| 项目 | 说明 |
|---|---|
| **`ma_data` 未对齐访问** | 唯一的 FAIL。RISC-V 规范 §2.6 允许多不做，但评委大概率会问。实现后回归可全绿 |
| **演示程序上板** | 目前**只在仿真里验证过**。远程平台约束只有 `clk/resetn/uart_tx/done` 四个信号，大概没有按键和 LED，要现场演示得换本地盘古板 |
| **GPIO 引脚未分配** | `cpu_top` 的 `led[7:0]` / `key[7:0]` / `uart_rx` 共 17 个端口**没有位置约束**（`.fdc` 里被注释掉了）。跑 CoreMark 无影响，但 P&R 只做时序告警就放过去了 |
| **资源效率未测** | 赛题评分项 `CoreMark/LUTs`。PDS GUI 里 `Design > Report > Utilization` 可直接读到 |

### 中优先级

| 项目 | 说明 |
|---|---|
| **ILA 波形分析** | 赛题明确要求"用 ILA 抓取的波形图分析流水线效率"，属分析报告内容 |
| **riscv-arch-test** | RISC-V 官方合规套件，用签名文件逐字节比对，比 riscv-tests 更严格 |
| **应用场景构建** | 目前只有"读按键→写 LED→串口"雏形，赛题有独立评分项 |

### 高阶任务（尚未开始）

| 方向 | 注意 |
|---|---|
| 2 路组相联 I/D Cache | ⚠️ **加 I-Cache 后 `fence.i` 必须从 NOP 升级为"冲刷 I-Cache"**，否则 `fence_i` 会退回失败 |
| BTB 动态分支预测 | 当前分支惩罚固定 2 拍（`ex_flush` + `ex_flush_d` 双拍冲刷），BTB 可显著降低 |
| 完整异常/中断 | `EBREAK` 已留好 `sys_ebreak` 钩子，CSR 与 trap 通路需新增 |
| 边缘 AI 加速 | —— |

---

## 八、会咬人的坑（都踩过）

1. **`mem.hex` 缺失 → 静默生成空 BRAM 比特流**（见 §4.1）
2. **Verilog 转义里没有 `\r`**。标准只有 `\n \t \\ \" \ddd`，iverilog 会把 `"\r\n"` 里的
   `\r` 当成字面字符 `'r'`，测试台的期望串永远对不上。换行用 `16'h0D0A` 拼
3. **外设不该把 X 放上总线**。`uart_rx` 空 FIFO 曾返回未初始化槽位（值是 X），
   X 被 CPU 读走会污染分支比较（X 参与 `<` 结果是 X，而 `if (X)` 按假处理），
   导致控制流走错分支。已修
4. **测试台驱动同步信号要避开 posedge 竞态**：`ack=1; @(posedge clk); ack=0;` 这种写法
   里，任务恢复与 always 块采样是同一时间步内的不确定顺序。在 **negedge 之后**驱动
5. **PDS 循环展开上限 2000 次**。综合用的 `rtl/mem/unified_mem.v` 里**不能**加整数组
   清零的 for 循环（8192 次）。清零是仿真侧需求，写在 `sim/mem_model.vh` 里
6. **仿真时不要编译 `rtl/mem/`**。testbench 通过 `` `include "mem_model.vh" `` 自带
   `unified_mem` 行为模型，重复定义会冲突
7. **远程平台偶发"固件下载完成但设备唤醒失败"** —— **多烧录几次即可**，与设计无关

---

## 九、目录速查

```
rtl/core/     core.v(5级流水线) control.v alu.v divider.v imm_gen.v regfile.v
rtl/mem/      unified_mem.v          ← 统一存储器（仅 PDS 综合用）
rtl/bus/      addr_map.vh  mem_bus.v ← 地址映射 + 唯一译码处
rtl/periph/   uart_tx.v  uart_rx.v  gpio.v
rtl/top/      cpu_top.v              ← SoC 顶层，只做连线

sim/          tb_riscv.v tb_coremark.v tb_demo.v（集成）
              tb_alu_* tb_control.v tb_gpio.v tb_uart_rx.v tb_uart_fifo.v（单元）
              mem_model.vh           ← 测试台共用的存储器行为模型
scripts/      run_sim / run_coremark / run_riscv_tests / run_demo / sync_firmware
doc/          spec.md(架构) base_task_status.md(达标核对) test_report_riscv-tests.md

pds/RV32I_1/  本工程（源文件指向 ../../rtl/**，不在 pds/ 保存副本）
pds/riscv_cpu/ 早期 LED 练习工程
```

生成物（`compile/ synthesize/ device_map/ place_route/ report_timing/ generate_bitstream/`
等）均不入库；`mem.hex` 作为固件快照入库。

---

**有疑问或者发现本文与代码不符，以代码和 `doc/spec.md` 为准，并请顺手更新本文。**
