# 架构文档 spec.md — RV32IM 五级流水线 SoC

> 最近更新：2026-09-15
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
| `rtl/top/cpu_top.v` | cpu_top | SoC 顶层，只做连线 |

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

> ⚠️ 是 **`imem_addr` 后退，不是 `pc_r` 后退**。若把 `pc_r` 也往后推，
> 连续两拍 stall 会让同一条指令被取两次，非幂等指令被重复执行 —— 历史上踩过。

`ex_flush_d` 是 `ex_flush` 的延迟一拍：跳转前已发出的那次读会带着旧路数据进 IF/ID，
必须用第二道冲刷杀掉。**分支惩罚 = 2 拍。**

### 3.2 冒险处理

| 类型 | 处理 |
|---|---|
| RAW（EX 级） | 两级前递：EX/MEM 优先于 MEM/WB；load 结果不从前递取（`wb_sel==01` 排除） |
| load-use | `stall` 停顿 1 拍（`id_ex_mem_read` 命中 rs1/rs2 时） |
| 多拍除法 | `div_stall` 停住 EX 及之前各级，`ex_mem` 插气泡 |
| 分支/跳转 | `ex_flush` + `ex_flush_d` 双拍冲刷 IF/ID |

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
0x0000_0000 - 0x0000_7FEF   RAM（统一存储器 32KB 内可用部分）
0x0000_7FF0 - 0x0000_7FFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0x7FF4 R  cycle_cnt[31:0]   core_portme.c 的 get_time()
    0x7FF8 W  done              start.S 里 main 返回后写 1
    0x7FFC W  UART TX           ee_printf 输出字符
0x8000_0000 起  外设区（字内偏移 = addr[5:2]）
    0x00 W LED[7:0]     R {16'b0, key[7:0], led[7:0]}   GPIO
    0x08 W UART TX      R 0
    0x0C R UART RX      {valid[31], 23'b0, data[7:0]}   ★ 读操作会弹出 FIFO 头
    0x10 R TIMER[31:0]  （与 0x7FF4 同一个计数器）
```

- RAM 译码**显式排除 0x7FF0~0x7FFF**（否则 CoreMark 写 0x7FF8 会落进 RAM，`done` 永不拉高）
- 栈顶必须 ≤ 0x7FF0（CoreMark 用 0x7000）
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

## 5. 仿真与验证

| 层次 | 测试台 | 说明 |
|---|---|---|
| 单元 | `tb_alu_inst` `tb_alu_div` `tb_uart_fifo` | ALU / 除法器 / UART 发送 FIFO |
| 单元 | `tb_control` | 译码器，重点覆盖 P1 补的 4 条指令 |
| 单元 | `tb_gpio` `tb_uart_rx` | 外设 |
| 集成 | `tb_riscv` | riscv-tests 全量回归（50 项：rv32ui + rv32um） |
| 集成 | `tb_coremark` | CoreMark 跑分 |
| 集成 | `tb_demo` | 整个 SoC + 演示程序端到端 |

**回归纪律**：改动 RTL 后，riscv-tests 的 49/1/0 与 CoreMark 的 **1,529,499** 周期
必须同时保持不变（除非本次改动的目的就是改变某一项）。

## 6. 已知限制与后续方向

**限制**

1. 未对齐 load/store 不支持（`ma_data` 因此 FAIL）—— RISC-V 规范允许
2. 按键无硬件消抖（在软件里做）
3. EBREAK 是软停机（不停 PC，需配合自旋循环）
4. UART 无中断，收发皆轮询
5. 取指窗口内的自修改代码仍有理论窗口（见 `doc/test_report_riscv-tests.md` §2）

**高阶任务方向（尚未做）**

- **2 路组相联 I/D Cache**：在统一存储器之上加两块 Cache。注意届时 `fence.i`
  必须从 NOP 升级为"冲刷 I-Cache"，否则会退化回 `fence_i` 失败
- **BTB 动态分支预测**：当前分支惩罚固定 2 拍，BTB 可显著降低
- **完整异常/中断**：`EBREAK` 已留好 `ebreak` 钩子，CSR 与 trap 通路需要新增
- **边缘 AI 加速**

**扩展注意**：RAM 容量写死在 3 处 —— `unified_mem` 的数组深度、`mem_bus` 的
`mem_addr[14:2]`、`core` 的 `imem_addr[12:0]`。扩容必须三处同步改，否则高位被静默截断。
