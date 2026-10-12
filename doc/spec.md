# 架构文档 spec.md — RV32IM 五级流水线 SoC

> 最近更新：**2026-10-12**（补 §4.4 I/D Cache；当前实现还含**顺序双发射**、**A 扩展**、
> **CSR/异常/中断**、**任务C `EARLY_LD`** —— 这些见 `doc/resource_efficiency.md` §14 与 `CLAUDE.md`）
> 本文件是比赛《性能分析报告》的架构依据，描述**当前实现**（不是计划）。
> 任务分解见 `doc/plan.md`，基础任务核对见 `doc/base_task_status.md`。

## 1. 总体结构

```
                    ┌──────────────────────────────────────────┐
                    │              cpu_top (SoC)                │
                    │                                           │
   clk/resetn ──────┤  ┌────────┐  取指口   ┌───────────┐       │
                    │  │        ├──────────►│           │       │
                    │  │  core  │           │  mem_bus  │       │
                    │  │ (5 级  │◄──────────┤ (地址译码) │       │
                    │  │ 流水线)│  访存口    │           │       │
                    │  └────────┘           └─────┬─────┘       │
                    │                             │             │
                    │            ┌────────────────┼──────────┐  │
                    │            ▼                ▼          ▼  │
                    │     unified_mem        uart_tx/rx    gpio  │
                    │   (指令+数据共用)                          │
                    └──────────────────────────────────────────┘
```

## 2. 模块清单

| 文件 | 模块 | 功能 |
|---|---|---|
| `rtl/core/core.v` | core | 五级流水线数据通路：冒险、前递、分支冲刷、访存口 |
| `rtl/core/control.v` | control | 主译码：opcode/funct3/funct7 → 控制信号 |
| `rtl/core/alu.v` | alu | 算术逻辑 + M 扩展乘法（映射到 DSP） |
| `rtl/core/divider.v` | divider | 多拍迭代除法器（单拍组合除法会拖垮 Fmax） |
| `rtl/core/imm_gen.v` | imm_gen | 立即数扩展（I/S/B/U/J，B/J 已 <<1） |
| `rtl/core/regfile.v` | regfile | 32×32 寄存器堆，x0 恒 0，写优先 |
| `rtl/mem/unified_mem.v` | unified_mem | **统一存储器**：双端口 BRAM，A 口取指 / B 口访存 |
| `rtl/bus/addr_map.vh` | —— | 地址映射单点定义（RTL 侧唯一真相） |
| `rtl/bus/mem_bus.v` | mem_bus | **存储总线**：唯一的地址译码处 + 读数据 mux |
| `rtl/periph/uart_tx.v` | uart_tx | UART 发送，1024 深 FIFO |
| `rtl/periph/uart_rx.v` | uart_rx | UART 接收，中点采样 + 16 深 FIFO |
| `rtl/periph/gpio.v` | gpio | 8 位 LED 输出 + 8 位按键输入（2 级同步） |
| `rtl/top/cpu_top.v` | cpu_top | SoC 顶层，只做连线（`DUAL_ISSUE` / `DCACHE_EN` / `ICACHE_EN` / `EARLY_LD` 等 parameter 都在这里）|
| `rtl/core/csr_file.v` | csr_file | CSR 文件 + 异常/中断 + **`mimpid` 承载设计版本号 `DESIGN_REV`**（改 RTL 必须递增，见 `CLAUDE.md` 约定 42）|
| `rtl/core/multiplier.v` | multiplier | M 扩展乘法，**拆成 2 拍**（换时序余量）|
| `rtl/core/amo_unit.v` | amo_unit | A 扩展原子指令（AMO* / LR / SC）|
| `rtl/bus/cache_i.v` / `cache_d.v` | cache_i / cache_d | **I/D Cache**（4 KB/侧、2 路组相联，`parameter` 开关，默认关）—— 见 §4.4 |
| `rtl/top/cpu_top_board.v` | cpu_top_board | **上板顶层**（PDS 的 top）：PLL 27 → 85.0051 MHz + 引脚约束 + HDMI |
| `rtl/video/*.v` | video_top 等 | 视频子系统（tile PPU + TMDS），**独立于 CPU**，细节见 `rtl/video/video_top.v` 文件头 |

## 3. 流水线

五级：IF → ID → EX → MEM → WB。

### 3.1 取指时序（改代码前必读）

统一存储器 A 口是**同步读、恰好 1 拍延迟**，加上 IF/ID 一级，使流水线内部落后 2 拍。
稳态下有三条不变量：

```
imem_rd   = mem[pc_r - 4]      // 在途，下一拍进 IF/ID
if_id_pc  = pc_r - 8           // 正在 ID 译码
id_ex_pc  = pc_r - 12          // 正在 EX 执行
```

**stall / div_stall 时 `pc_r` 与 `if_addr_d` 都保持不动**，由 `imem_addr` 的 mux
退回 `if_addr_d[14:2]`（重读上一拍已读过的同一 word），让 `if_id` 在 stall 结束那拍
拿到 (pc, 指令) 同址的一对。

> [!] 是 **`imem_addr` 后退，不是 `pc_r` 后退**。若把 `pc_r` 也往后推，
> 连续两拍 stall 会让同一条指令被取两次，非幂等指令被重复执行 —— 历史上踩过。

**跳转目标在冲刷当拍就旁路给取指端**（2026-09-21 改造）。因为取指是**同步读 BRAM**，
地址发出后要到下一拍才拿得到指令；若只做冲刷、等 `pc_r` 更新后再取目标，中间会空 3 拍。
把 `ex_target` 直接送进 `imem_addr` 的 mux，目标指令就能早 1 拍进 IF/ID：

```verilog
wire [31:0] fetch_addr = ex_flush            ? ex_target :
                         (stall || div_stall) ? if_addr_d :
                                                pc_r;
assign imem_addr = fetch_addr[14:2];
// 地址已在当拍发出，pc_r 必须跳过它，否则目标指令会被取两次
else if (ex_flush) pc_r <= ex_target + 32'd4;
```

**分支惩罚：预测命中时 1 拍，未命中/误判时 2 拍**（2026-09-25 第四轮：条件分支方向
改由 256 项带 tag 的 BHT 动态预测）。预测器在 ID 级（BHT 动态预测条件分支方向 +
jal 的静态后向预测），命中当拍就重定向；未命中要等 EX 解析。
量化证据见 `doc/ila_analysis.md` §2：

```
计时区间自洽（**BHT 之前**）：288,056（提交）+ 20,720（load-use 停顿）+ 50,070（分支）= 358,846 [OK]
> BHT 之后计时区间降到 **354,119** 拍，分支损失不再是 50,070（见 `doc/resource_efficiency.md` §11.3）。
分支 50,070 的构成：命中 28,860×1 + 误判 2,367×2 + 未预测 8,238×2
```

> 历史沿革：本设计曾用 `ex_flush_d` 做第二道冲刷，那时的实际吞吐损失是 **3 拍**
> （2026-09-21 逐拍实测确认：全区间要 `3 × 193,698 + 174,890 + 2,013 + 4` 才闭合）。
> 取指重定向把 `ex_flush_d` 整个删掉后降为 2 拍；实测计时区间 420,070 → **382,972 拍**，
> 省下的 37,098 拍**恰好等于冲刷次数**。改造记录见
> `doc/reports/2026-09-21_branch_opt_verify.md`。

### 3.2 冒险处理

| 类型 | 处理 |
|---|---|
| RAW（EX 级） | 两级前递：EX/MEM 优先于 MEM/WB；load 结果不从前递取（`wb_sel==01` 排除） |
| load-use | `stall` 停顿 1 拍（`id_ex_mem_read` 命中 rs1/rs2 时） |
| 多拍除法 | `div_stall` 停住 EX 及之前各级，`ex_mem` 插气泡 |
| 分支/跳转 | ID 级预测：**256 项带 tag 的 BHT 预测条件分支方向** + jal 静态后向（jalr 不预测）；
命中则当拍重定向（损失 **1 拍**）；未命中/误判与 jalr 走 EX 冲刷，
同样**同拍把目标地址旁路给取指**（损失 **2 拍**）。见 §3.1 |

### 3.3 为什么是 modified-Harvard

体系结构/软件层把指令与数据**统一到一个地址空间**（跑 gcc/CoreMark 必须有 ——
链接脚本只能产出一份扁平的内存布局），而核**内部取指与访存通路仍分离**。
这是现代 CPU 的常见做法。

**当前实现把两者合并成一块物理双端口 BRAM**（`unified_mem`），A 口取指、B 口访存。
好处有两个：

1. **自修改代码可用** —— store 写进去的数据，后续取指天然能读到。这让
   riscv-tests 的 `fence_i`（自修改代码测试）能通过，`FENCE.I` 得以按 NOP 实现。
   原先的哈佛结构（指令/数据各一块 BRAM）下这是不可能的，与是否实现 FENCE.I 无关。
2. **BRAM 用量减半** —— 对"资源效率 CoreMark/LUTs"这一评分项有利。

代价与残留限制见 §6。

## 4. 存储器与总线

### 4.1 总线时序契约

`mem_bus` 与 `core` 之间是**同步、固定延迟**的简单总线，没有握手：

```
第 T   拍 (MEM)：core 给出 mem_addr / mem_wdata / mem_byte_en / mem_we
第 T+1 拍 (WB) ：mem_rdata 是 mem_addr(T) 对应地址的读数据
```

两条硬约束：

1. **写通路零寄存器** —— 直接打进 RAM 写口。插一拍会让 `st_ld`/`ld_st` 这类
   "存完立刻读回"的用例读到旧值。
2. **读选择位与读数据都在 MEM→WB 沿寄存** —— 所有地址源（RAM / 兼容区 / 外设区）
   一律 1 拍延迟，不搞特例。给读通路再插一级寄存器会让读数据推到 T+2，
   而 WB 在 T+1 采样，**没有任何 stall 机制能救**（冒险单元不知道内存有几拍）。

将来若要做多拍内存（外挂 SRAM、慢速外设），必须给总线加 `ready` 并接进冒险单元，
不能靠事后打补丁。

### 4.2 地址映射

```
0x0000_0000 - 0x0000_FFEF   RAM（统一存储器 64KB 内可用部分）
0x0000_FFF0 - 0x0000_FFFF   兼容区（CoreMark 移植层硬编码）
    0xFFF4 R  cycle_cnt[31:0]   core_portme.c 的 get_time()
    0xFFF8 W  done              start.S 里 main 返回后写 1
    0xFFFC W  UART TX           ee_printf 输出字符
0x8000_0000 起  外设区（字内偏移 = addr[5:2]）
    0x00 W LED[7:0]     R {16'b0, key[7:0], led[7:0]}   GPIO
    0x08 W UART TX      R 0
    0x0C R UART RX      {valid[31], 23'b0, data[7:0]} [重点] 读操作会弹出 FIFO 头
    0x10 R TIMER[31:0]  （与 0xFFF4 同一个计数器，即 CLINT 的 mtime）
    0x14 W/R MTIMECMP[31:0]  定时器比较值：mtime >= mtimecmp → MTIP 拉高
[重点] 只接受整字写（sw）；复位值全 1，上电不会误触发
[重点] 软件写新值后 MTIP 自动落下（纯电平比较，不锁存）
```

> **CLINT / 定时器中断**：`mtime` 就是那个自由跑计数器（32 位，不是规范建议的
> 64 位）。
> [!] **回绕周期跟着时钟走**：27 MHz 下约 **159 秒**，45 MHz 下 **95.4 秒**，
> 49.89 MHz 下 **86.1 秒**，**当前板上 85.0051 MHz 下约 50.5 秒**。
> 按"最长的一次连续计时"算，本项目最长的 CoreMark 计时区间是 **11.70 秒**
> （**当前跑分档**：ITER=4116 @85.0051 MHz，双发射 + `EARLY_LD`；历史：ITER=3170 @85.0051 MHz 双发射、ITER=2740 单发射），
> 远小于回绕周期，**当前无风险**。
> 但若日后把 ITER 加到几千、或做更长的长稳测试，**必须重新核对** ——
> 32 位计数器一回绕，`Total ticks` 就会算出错误的（甚至负的）时长。
> 要产生中断还需 `mie.MTIE`(bit7) 与 `mstatus.MIE`(bit3)。完整用法见
> `sim/tests/timer_irq.S`。

- RAM 译码**显式排除 0xFFF0~0xFFFF**（否则 CoreMark 写 0xFFF8 会落进 RAM，`done` 永不拉高）
- 栈顶必须 ≤ 0xFFF0（CoreMark 用 0xF000，五子棋同样）
- 单点定义：`rtl/bus/addr_map.vh`；软件侧镜像：`scripts/demo/addr_map.h`

### 4.3 外设设计要点

- **`uart_rx` 空 FIFO 必须返回 0，不能返回 `fifo[rptr]`** —— 那个槽位从未写过、值是 X。
  X 被 CPU 读走会污染分支比较（X 参与 `<` 的结果是 X，而 `if (X)` 在 Verilog 里按假
  处理），导致控制流走错分支。**本工程踩过这个坑**，详见 `uart_rx.v` 注释。
  > 推广：**任何外设都不该把 X 放上总线。**
- UART RX 的读语义是"读即弹出"（类 8051 RBR）。软件轮询务必只读一次：
  `v = UART_RX; if (v>>31) c = v & 0xFF;`，不要写成 `while(!(UART_RX>>31));` ——
  那会在判断里就把字节吃掉。
- GPIO 按键低电平有效，且**只做 2 级同步、不做硬件消抖**；去抖放在软件里
  （采样—延时—再采样），更容易仿真验证。

### 4.4 I/D Cache（4 KB/侧、2 路组相联，**可选**，2026-10-12 已上板）

**开关是 `parameter`，不是 `-D` 宏**（PDS 命令行传不了宏；`scripts\build_bitstream.ps1` 的做法是
"临时改默认值 → 综合 → 还原"）：

```verilog
parameter DCACHE_EN = 0;   // 数据 Cache（rtl/top/cpu_top.v）
parameter ICACHE_EN = 0;   // 指令 Cache
```

| 项 | 值 |
|---|---|
| 容量 / 组织 | **4 KB/侧**、2 路组相联、LRU（`IDX_BITS = 9`）|
| 位置 | `rtl/bus/cache_d.v`（数据）、`cache_i.v`（指令），插在 `mem_bus.v` 与 `unified_mem` 之间 |
| 命中延迟 | **1 拍**（与不命中**相同** —— 后端是单周期片内 BRAM）|
| 缺失代价 | 指令缺失冻结整条流水线约 5 拍（`stall_r`）；数据缺失由 `mem_ready=0` 停顿 |
| 命中/缺失计数 | 只读 MMIO：`0x8000_0018`(D 命中) / `0x1C`(D 缺失) / `0x20`(I 命中) / `0x24`(I 缺失) |

**时序代价（CPU 域实测）**：

| 配置 | 85.0051 MHz | 76.5052 MHz（`RATIO0=15.0`）|
|---|---|---|
| 不开 Cache | **+0.045 ns** ✓ | — |
| 只开 D-Cache | **+0.151 ns** ✓（分数与不开完全相同）| — |
| **I+D 全开** | **−1.143 ns / 343 失败端点 ✗** | **+0.589 ns / 0 失败端点 ✓** |

**为什么 I+D 必须降频**：I-Cache 挂在**取指关键链**上
（`D-Cache 数据阵列 → 前递/分支/重定向 → fetch_addr → I-Cache tag 比较 → 命中`，15~17 级、Route 占 63%）。
**不是逻辑问题、是布局拥塞**（所以"压逻辑"没用）。⇒ 想回 85 MHz 只有 PCE 区域约束或
把 I-Cache tag 比较移出取指链。

**对性能的实际影响**（板上实测）：I+D 全开 = **313.63 分**（@76.5052 MHz、ITER=3668），
相对 351.86 分 **−10.9%**，其中 **−10.0% 是主频、只有 −0.95% 是 Cache 周期代价**
（I-Cache 缺失 **2,455 次/迭代**，但冻结的拍几乎全藏在原有气泡里）。
命中率：**I 98.985% / D 99.929%**。

**`fence.i` 仍是 NOP** —— 现状安全（无自修改代码、无片外存储）；若将来支持
"软件写指令存储"，必须升级为**冲刷 I-Cache**。

> [!] **改容量/组织时的清单**（漏一处就是静默错位）：
> `cache_i.v` / `cache_d.v` 的 `IDX_BITS` → `mem_bus.v` 的实例化传参 →
> 相关地址切片。改完**必须**跑 `-DCache -ICache -EarlyLd` 回归。

## 5. 仿真与验证

| 层次 | 测试台 | 说明 |
|---|---|---|
| 单元 | `tb_alu_inst` `tb_alu_div` `tb_uart_fifo` | ALU / 除法器 / UART 发送 FIFO |
| 单元 | `tb_control` | 译码器，重点覆盖 P1 补的 4 条指令 |
| 单元 | `tb_gpio` `tb_uart_rx` | 外设 |
| 集成 | `tb_riscv` | riscv-tests 全量回归（50 项：rv32ui + rv32um） |
| 集成 | `tb_coremark` | CoreMark 跑分 |
| 集成 | `tb_demo` | 整个 SoC + 演示程序端到端 |

**回归纪律**：改动 RTL 后，riscv-tests 的 **49/1/0** 与 CoreMark 计时区间必须同时保持不变
（除非本次改动的目的就是改变某一项）。

**[重点] 现在是四条并列基线，不能混**（详见 `CLAUDE.md` 关键约定 37）：

| 配置 | riscv-tests | CoreMark 每迭代 |
|---|---|---|
| **双发射 + `EARLY_LD`（默认，= 板上口径）** | 49 PASS / 1 FAIL / 0 TIMEOUT | **241,633** |
| 双发射 + `EARLY_LD=0` | 49 PASS / 1 FAIL / 0 TIMEOUT | **262,018** |
| 单发射（`-Single`） | 49 PASS / 1 FAIL / 0 TIMEOUT | **312,428** |
| 带 Cache（`-DCache -ICache -EarlyLd`） | 49 PASS / 1 FAIL / 0 TIMEOUT | **243,933** |

> 演进：`420,070`（基线）→ `382,972`（取指重定向）→ `358,846`（ID 级静态预测）
> → `354,119`（BHT，2026-09-25）→ `363,515`（两拍乘法器）→ `313,886`（顺序双发射，2026-10-06）
> → `312,428`（单发射阶段0/1，2026-10-11）→ **`241,633`（双发射 + 任务C `EARLY_LD`，2026-10-11，当前）**。

## 6. 已知限制与后续方向

**限制**

1. **未对齐访存不提供正确结果，但会正确地陷入异常**（mcause 4/6）。
   规范要求"要么支持、要么陷入异常"，本设计取后者。`ma_data` 因此仍是唯一 FAIL，
   但失败形态已变：未对齐 `lh` 触发 mcause=4 → 测试自带的 handle_exception
   置 `gp |= 1337` → tohost=1337 → 测试台报 `FAIL (testnum 668)`
   （testnum 的旧记录 1 已二次勘误，实测迁移前后都是 668，见 `doc/test_report_riscv-tests.md` §1）。
   **真正要支持未对齐访存需在 MEM 级加多拍访问**，未做
2. 按键无硬件消抖（在软件里做）
3. EBREAK 现在是 **mcause=3 的异常**（不再只是软停机钩子）。顶层的 `done` 灯
   改从 trap 事件取（`ebreak = trap && trap_cause == 3`）
4. **外部中断（MEIP）未实现**：`mip.MEIP`/`mie.MEIE` 的位与 `core` 的输入端口都在，
   `cpu_top` 也接上了 UART RX 非空，但**没有针对它的测试**，不得当作已验证能力
5. UART 发送无中断（收发皆轮询，除上面的 MEIP 通路）
6. 取指窗口内的自修改代码仍有理论窗口（见 `doc/test_report_riscv-tests.md` §2）
7. `minstret`/`minstreth` 读 0（未实现退休指令计数）

**已实现的高阶能力（异常/中断）**

- **CSR 文件**：`rtl/core/csr_file.v`。实现 mstatus / misa / mie / mtvec / mscratch /
  mepc / mcause / mtval / mip / mcycle / mhartid 与三个只读 ID 寄存器。
  6 条 CSR 指令（CSRRW/RS/RC + 立即数变体）在 **EX 级**提交（理由见该文件头注释）。
- **同步异常**：非法指令(2) / EBREAK(3) / 未对齐 load(4) / 未对齐 store(6) /
  ECALL from M(11) / 写只读 CSR(2)。统一在 **EX 级**检测。
- **中断**：机器定时器中断（mcause = 0x8000_0007）。
- **trap 通路**：`fetch_addr` 加一条最高优先级的重定向腿；`mret` 折进 `ex_flush`
  通路（不为它再加腿，避免在 `pc_r` 临界路径上增加级数）。
- 测试：`sim/tests/exceptions.S`、`sim/tests/timer_irq.S`，
  一键跑 `scripts/run_own_tests.ps1`。

> [!] **只支持 M 模式**：`mstatus.MPP` 硬连线 2'b11，`mret` 永远回 M 模式。
> 这不是偷懒 —— riscv-tests 的 init 会 `csrwi mstatus, 0` 把 MPP 清 0，
> 如实实现会让 `mret` 降到 U 模式，与测试对 `mcause` 的假设不符。
>
> [!] **未实现的 CSR 读 0、写忽略、不抛非法**（stvec/medeleg/satp/pmp* 等）。
> init 段会访问它们，按规范抛异常会让 50 个基线 ELF 当场全挂。
> 这是明知与规范有偏差的工程取舍。

**已实现的高阶能力（动态分支预测，2026-09-25）**

- **BHT（分支历史表）**：`rtl/core/core.v` 里 256 项、2 位饱和计数器、**带 tag**
  （索引 `PC[9:2]`、tag `PC[31:8]`），**只预测条件分支方向**。
- `jal` 走静态后向预测、`jalr` 不预测（目标依赖 rs1，ID 级无前递通路），两者仍走
  EX 冲刷。这个"保守版"完整绕开了"预测对方向但目标算错"的坑（那只可能由 jalr 引起）。
- 训练在 EX 级用 `branch_taken`（门控于 `id_ex_branch`），未命中时每个条件分支都分配。
- 收益：计时区间 358,846 → **354,119** 拍（省 1.32%），理论上限 2.36%，捕获率 56%。
  残余空间来自 256 项表偏小、别名冲突（实测 341 个静态条件分支里 149 个冲突）——
  扩到 1024/4096 项预计还能回收约 1%，**是可优化项，不是缺陷**。
- ILA 硬件在环抓波形也已于 2026-09-25 完成（不再待办），逐拍证据在 `doc/board/ila_hw_*.vcd`。

**高阶任务方向（尚未做）**

- **2 路组相联 I/D Cache**：在统一存储器之上加两块 Cache。注意届时 `fence.i`
  必须从 NOP 升级为"冲刷 I-Cache"，否则会退化回 `fence_i` 失败。
  **但先想清楚**：存储器是行为级单周期 BRAM，访存恒 1 拍、无缺失惩罚、
  无结构冲突，Cache 只会引入缺失惩罚，是负收益（详见 `doc/resource_efficiency.md`）
- **边缘 AI 加速**：32KB BRAM 是硬墙（无片外存储），当前硬件条件下不可行

**扩展注意**：RAM 容量写死在 3 处 —— `unified_mem` 的数组深度、`mem_bus` 的
`mem_addr[14:2]`、`core` 的 `imem_addr[12:0]`。扩容必须三处同步改，否则高位被静默截断。
