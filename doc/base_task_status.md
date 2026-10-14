# 基础任务完成度核对（对照《紫光同创.pdf》选题指南）

> 核对日期：2026-09-21（更新）；2026-10-04 补时钟迁移（27 → 45 → 49.89 → 62.03 → **85.0051 MHz**）、两拍乘法器与动态分支预测口径；2026-10-06 补**顺序双发射**口径；**2026-10-13 补 A1 乘法器 II=1 口径（板上实测 365.93 分）**
> **2026-10-13 再补**：动态分支预测一行改口径（**做的是 BHT 方向预测，赛题点名的 BTB 未做**；实测判定 BTB 低收益、正解是 RAS）+ 新增「应用场景」一节（RT-Thread + 五子棋 / T1-G3 首次上板）
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

- **FENCE / FENCE.I 作 NOP 的正当性**：默认配置不开 Cache，无写缓冲需要"刷"；
  且存储器已统一（`rtl/mem/unified_mem.v`），store 对后续取指天然可见。
  RISC-V 规范允许无 Cache 的实现视其为 NOP。
  [!] I/D Cache 已可实现（parameter 默认关）——开了 I-Cache 后 `fence.i` 仍是 NOP，
  现状安全（无自修改代码）；若将来支持"软件写指令存储"，必须升级为冲刷 I-Cache
  （见 `doc/spec.md` §4.4）。
- **ECALL**：**已实现为 mcause=11 的同步异常**（2026-09-23），跳 `mtvec`、
  写 `mepc`/`mcause`。
- **EBREAK**：**已实现为 mcause=3 的同步异常**。顶层的 `done` 停机钩子改从 trap
  事件取（`ebreak = trap && trap_cause == 3`）。
  注：装异常之后程序仍应在 EBREAK 后跟自旋循环 —— riscv-tests 与 CoreMark 的
  start.S 本来就是这个写法。

## 验证结果（2026-09-23 结果；2026-10-04 补时钟迁移到 85.0051 MHz 口径；2026-10-06 补顺序双发射口径；2026-10-11/12 更新为**任务C `EARLY_LD` + I/D Cache** 口径；**2026-10-13 补 A1 乘法器 II=1 口径（**已板上实测 365.93 分**）**）

| 项目 | 结果 |
|---|---|
| riscv-tests（50 项：rv32ui 42 + rv32um 8） | **49 PASS / 1 FAIL / 0 TIMEOUT**（唯一 FAIL 是 `ma_data` 未对齐访存，规范允许，见 §已知限制） |
| └ M 扩展（rv32um 8 项） | mul / mulh / mulhsu / mulhu / div / divu / rem / remu **全部 PASS** |
| **CoreMark v1.0（本地盘古板实测，85.0051 MHz，ITER=4116，【双发射 + 任务C `EARLY_LD`】）—— A1 前板上实测的最后一个数；A1 后板上实测 365.93 分（ITER=4280，位流 `bcd8fdd2`，日志 `doc/board/uart_20261013_184111.txt`）** | `Total ticks 994,386,960` ÷ 85,005,100 = **实际 11.69797 秒** → **351.86 CoreMark**，`Correct operation validated` [OK] 达标，`seedcrc/crclist/crcmatrix/crcstate` 与仿真**逐位一致**。<br>原始串口日志：`doc/board/uart_20261011_225624.txt` / `doc/board/uart_20261012_002541.txt`；位流 md5 `2ddaf32f`（无 Cache）/ `2f7a4d0a`（只开 D-Cache，分数相同）；每迭代 **241,584** 拍（仿真 241,633，−0.02%）。**上板教程：`doc/board_bringup.md`**<br>**I+D Cache 版**：76.5052 MHz / ITER=3668 → `Total ticks 894,745,801` = **11.6952 秒 / 313.63 分**（243,933 拍/迭代，位流 `c6b12d95`，日志 `doc/board/uart_20261012_155934.txt`）。<br>**历史**（均有原始日志，见 `doc/board/`）：**双发射 313,886 时代** —— 85.0051 MHz / ITER=3170 → 11.7050 秒 / **270.82** 分（`uart_20261006_162410.txt`，位流 md5 `5c4893de`）；**单发射** —— 85.0051 MHz / ITER=2740 → 11.7171 秒 / **233.85** 分（`uart_20261004_114730.txt`）；62.03 MHz / ITER=2000 → 11.7203 秒 / 170.64 分（`uart_20260928_212449.txt`）；49.89 MHz / ITER=1663 → 11.8031 秒 / 140.89 分（`uart_20260925_172318.txt`；同代两拍乘法器版 137.25，`uart_20260928_212347.txt`）；45 MHz / ITER=1500 → 11.9619 秒 / 125.40 分（`uart_20260925_005201.txt`）；27 MHz / ITER=820 → 10.898 秒 / 75.24 分（`uart_20260923_201540.txt`）。**较 313,886 时代 +29.9%，较单发射 85 MHz +50.5%，较 27 MHz +368%** |
| **CoreMark 效率（当前设计 = 双发射 + 任务C `EARLY_LD` + A1 乘法器 II=1，仿真）** | 每迭代 **232,345** 周期（`+PROF` 读 CoreMark `Total ticks`）→ **4.304 CoreMark/MHz**；**I+D Cache 版 235,628 → 4.244**（A1 前为 241,633 → 4.139 / I+D 243,933 → 4.099）。<br>历史：**3.186**（双发射 313,886，2026-10-06）→ 2.751（单发射 363,515）→ 2.824（BHT 后 354,119）→ 2.787（358,846）→ 2.611（382,972）→ 2.380（420,070）|
| **CoreMark 实际得分**（= CoreMark/MHz × 系统时钟） | 27 MHz 板测 **75.24** → 45 MHz **125.40** → 49.89 MHz **140.89** → 62.03 MHz **170.64** → 85.0051 MHz（单发射）**233.85** → 85.0051 MHz（双发射）**270.82** → **85.0051 MHz（+任务C `EARLY_LD`）351.86** → **I+D Cache @76.5052 MHz 325.96**（A1 后；A1 前 313.63）（**以上均板上实测**，较 27 MHz 累计 **+368%**；**A1 后板上实测 365.93 分**）<br>口径见 `doc/resource_efficiency.md` §2 / §12 / §13 / **§14** |
| 历史：改造前效率 | 每迭代 420,070（仿真）/ 420,094（板上），差 0.0057% → 2.380 CoreMark/MHz |
| 真机正确性 | seedcrc / crclist / crcmatrix / crcstate **逐位一致**（**`crcfinal` 不比** —— 它跨迭代累加、随 ITER 变：ITER=1 → `0xe714`、ITER=820 → `0xbd59`、ITER=1500 → `0x25b5`、ITER=1663 → `0x81c9`、ITER=2740 → `0x988c`） |
| 演示程序端到端（`run_demo.ps1`） | 7/7 PASS：上电状态、按下/松开 KEY1、按下 KEY4、串口回显两例、done 状态 |
| 单元测试 | `tb_alu_inst` `tb_alu_div` `tb_uart_fifo` `tb_control` `tb_gpio` `tb_uart_rx` 全部 PASS |

详见 `doc/test_report_riscv-tests.md`。

## 地址映射

```
0x0000_0000 - 0x0000_FFEF   RAM（统一存储器，64KB；可用 0x0~0xEFFF = 60KB，栈顶 0xF000）
0x0000_FFF0 - 0x0000_FFFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0xFFF4 R  周期计数器[31:0]      0xFFF8 W  done        0xFFFC W  UART 发送
0x8000_0000 起              外设区（字内偏移 = addr[5:2]）
    0x00 W LED[7:0] / R {key[7:0], led[7:0]}      0x08 W UART 发送
    0x0C R UART 接收（读弹出）                      0x10 R 周期计数器
```

单点定义在 `rtl/bus/addr_map.vh`；软件侧对应 `scripts/demo/addr_map.h`。

## 高阶任务进展

| 方向 | 状态 |
|---|---|
| **完整异常/中断** | [OK] **已完成**（2026-09-23）：CSR 文件 + 6 条 CSR 指令 + `mret` + 六类同步异常（非法指令 / EBREAK / 未对齐 load+store / ECALL / 写只读 CSR）+ 定时器中断（CLINT）。自写汇编测试在 `sim/tests/`，一键 `scripts\run_own_tests.ps1` |
| 动态分支预测 | [!] **做的是 BHT（方向），不是 BTB（目标）**（2026-09-25）：`core.v` 里 **256 项、2 位饱和计数器、带 tag 的 BHT**（`bht_tag/bht_ctr/bht_valid`，索引 `PC[9:2]`、tag `PC[31:8]`），**只预测条件分支方向**（`jal` 走静态后向预测、`jalr` 不预测）。收益 358,846 → **354,119** 拍（省 1.32%）。<br>**[!] 赛题原文点名的是"动态分支预测器（如 BTB）"，而 BTB 至今未实现。** 2026-10-13 用 `+JALRTRACE` 探针实测后判定：本 workload 上 **BTB 记目标几乎无收益**（jalr 1,374 条 **100% 是函数返回**；直接映射 BTB 16~16384 项、1/2/4 路捕获率**恒为 6.40%**），**正解是 RAS**（4/8/16/32 项 = 99.78/99.93/99.93/99.93%）。**RAS 与 BTB 都还没做。** 任务书见 `doc/reports/2026-10-13_handoff_btbras.md` |
| 外部中断 MEIP | [!] 只做了接口（`cpu_top` 接了 UART RX 非空），**没有测试**，不得当作已验证能力 |
| **2 路组相联 I/D Cache** | [OK] **已实现并上板**（4 KB/侧，`DCACHE_EN` / `ICACHE_EN` 两个 parameter，默认关）。只开 D：85 MHz 下**不吃余量**（+0.151 ns）、分数与不开 Cache **完全相同**（351.86）；**I+D 全开：85 MHz 塞不进（−1.143 ns / 343 失败端点）⇒ 降频到 76.5052 MHz 收敛并上板实测通过（**A1 后 325.96 分 / ITER=3800 / 位流 da8ffd31**；A1 前 313.63）**，2026-10-12。**两条挂死根因（约定 56/57）已修、2026-10-14 上板验证（带 Cache 的 RT-Thread 五子棋跑通）。**<br>[!] **对分数贡献 = 0**（后端是单周期片内 BRAM，命中与不命中的数据通路一样快）—— 价值在**功能条目**；代价与账见 `doc/resource_efficiency.md` §14 |
| 边缘 AI 加速 | [ ] 未做。RAM 仅 64 KB（无片外存储），当前硬件条件下不可行 |

> 统一存储器已为 I/D Cache 备好后端（两块 Cache 共用这份 backing store，
> 实现见 `rtl/bus/cache_i.v` / `cache_d.v` / `mem_bus.v`）。
> [!] **`fence.i` 仍是 NOP** —— 现状安全（本设计无自修改代码、无片外存储），
> 但若将来加了"软件写指令存储"的场景，`fence.i` 必须升级为**冲刷 I-Cache**。

## 应用场景（RT-Thread + 五子棋）—— 2026-10-13 状态

> 赛题评分里有"应用场景演示"这一项，这里是它的交付物现状。

| 项 | 状态 |
|---|---|
| **五子棋**（裸机宿主）| [OK] 已做、已上板可玩：HDMI 出 15×15 棋盘 + 红色光标圈、4 键操作、串口棋盘镜像（无显示器也能验）。**最近一次板上验证**的位流是 `gomoku_dual_aext_ms_85mhz_addrfix_f00c6659.sbit`（2026-10-10，两局正常、屏幕正常）；各代见 `pds/RV32I_1/bitstreams/README.md` |
| **RT-Thread Nano 移植** | [OK] 已移植并上板（`scripts/rtthread/`）。BSP / 中断栈切换 / 静态线程见该目录 `README.md` |
| **T1/G3 拆线程**（render 高优 + AI 低优两条线程 —— AI 思考期间画面照刷、光标照闪）| [OK] **2026-10-13 已并入并首次上板**（位流 `8894cdcb`，日志 `doc/board/uart_20261013_224652.txt`）：两条线程都起、`[hb]` 全程无断、**两线程邮箱往返真通**（`AI moved, nodes=10592 depth=6 t=5068ms`），对局/按键/轮次全对 |
| G3 的"画面不卡"正题 | [OK] **显示侧已验**（2026-10-14，位流 `53b81dfe` / `90944754`，`RTL=0x20261019`）：接屏 + 真按键下完一局判出 `WHITE wins`，AI 思考 5.7 s 期间画面/按键仍响应；串口 `[!] vblank timeout` 已定性为 `video_wait_vblank()` **概率命中**（非显示故障，见 `doc/board/README.md`）|
| 下一步（T2–T5）| [ ] 见 `doc/reports/2026-10-13_T1_rtthread_g3_checklist.md` |

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
6. **PDS 工程已改为本地盘古板约束**（2026-09-23）—— `RV32I_1.fdc` 全部引脚
   按《MES2L676-200HP硬件使用手册》填好并**在板上实测验证过**；上板 top module
   是 `cpu_top_board`（不是 `cpu_top`）。详见 `doc/board_bringup.md`。
   2026-10-04 起系统时钟由板载 27 MHz 经 **PLL 倍频到 85.0051 MHz**（演进：45 → 49.89 → 62.03 → 85.0051）——注意 `.fdc` 里
   约束的仍是 **27 MHz 输入晶振**，PLL 输出由 PDS 从 PLL IP 自动推导；**仿真与远程
   平台不进 PLL，仍是 27 MHz**。
