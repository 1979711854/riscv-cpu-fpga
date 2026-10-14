# 基于紫光同创 FPGA 的 RISC-V 五级流水线 CPU

> 全国大学生嵌入式芯片与系统设计竞赛 —— FPGA 赛道 · 紫光同创选题

器件：紫光同创 **Logos2 PG2L200H-6FBB676**　工具：**Pango Design Suite 2022.2-SP6.4**
处理器：**RV32IMA**（+ Zicsr/Zifencei），5 级流水线（IF/ID/EX/MEM/WB），**顺序双发射**

## 当前成绩

| 项目 | 结果 |
|---|---|
| riscv-tests（rv32ui + rv32um，50 项） | **49 PASS / 1 FAIL / 0 TIMEOUT**（**带 Cache 的配置也是 49/1/0**，见 `doc/test_report_riscv-tests.md`）|
| 动态分支预测 | [OK] **已实现**（256 项、2 位饱和计数器、带 tag 的 BHT，只预测条件分支方向，2026-09-25）—— 高阶任务②（动态分支预测 + 完整异常/中断）**已完整** |
| **I/D Cache** | [OK] **已实现并上板**（4 KB/侧、2 路组相联；`DCACHE_EN`/`ICACHE_EN` 两个 parameter，默认关；两条挂死根因（约定 56/57）已于 2026-10-14 修复并上板验证）<br>只开 D-Cache：**85.0051 MHz 下不吃余量**（+0.151 ns），分数与不开 Cache **完全相同**；<br>**I+D 全开：85 MHz 塞不进（−1.143 ns）→ 76.5052 MHz 收敛并上板实测通过**（2026-10-12）|
| CoreMark 效率 | **4.304 CoreMark/MHz**（**顺序双发射 + 任务C `EARLY_LD` + A1 乘法器 II=1**，每迭代 **232,345** 周期，与时钟无关；A1 前为 4.139 / 241,633）<br>历史：**3.186**（双发射 313,886）→ 2.751（单发射 363,515）→ 2.824 → 2.787 → 2.611 → 2.380 |
| CoreMark **板上实测** | [OK] **85.0051 MHz / ITER=4280 → 11.696 秒 / 365.93 CoreMark**（2026-10-13，**A1 乘法器 II=1 流水线**，双发射 + `EARLY_LD`；位流 `bcd8fdd2` / `RTL=0x20261017`；每迭代 232,296.6 拍，仿真 232,345，差 −0.021%）—— **当前最好成绩，较 A1 前的 351.86 +4.00%**<br>（A1 前：85.0051 MHz / ITER=4116 → 351.86 CoreMark，`2ddaf32f` 无 Cache 与 `2f7a4d0a` 只开 D-Cache **分数完全相同**）<br>[OK] **I+D Cache 版：A1 后 76.5052 MHz / ITER=3800 → 11.6578 秒 / 325.96 CoreMark**（位流 `da8ffd31`，`RTL=0x20261017`）<br>（A1 前：ITER=3668 → 11.6952 秒 / 313.63，位流 `c6b12d95`，`RTL=0x20261016`）<br>历史：270.82（双发射 ITER=3170）→ 233.85（单发射）→ 170.64 → 140.89 → 125.40 → 75.24 |
| 时序（CPU 域，`clk_sys`） | 85.0051 MHz：**不开 Cache +0.045 ns / 只开 D +0.151 ns**，失败端点都 0<br>**I+D 全开：85 MHz `−1.143 ns / 343 失败端点`（✗）→ 76.5052 MHz `+0.589 / 0`（✓）**（I-Cache 挂在取指关键链上，见 `doc/reports/2026-10-12_idcache_board_bitstream.md`）<br>归档位流索引：`pds/RV32I_1/bitstreams/README.md` |
| 资源（**双发射 + Cache**，全 SoC 含视频） | I+D 版：LUT **7,896**（4.94%）、DRM **106.5**、APM 4（2026-10-12 实测）；只开 D 版 DRM **105.5**<br>历史（**无 Cache** 的双发射）：LUT 6,909、FF 3,267、DRM 61.5 —— 双发射 + Cache + A 扩展 + 任务C 的累计增量 |
| 实际得分 | **365.93 CoreMark** @85.0051 MHz（2026-10-13 板上实测，**A1 后**，ITER=4280；A1 前为 351.86 / ITER=4116）<br>**I+D Cache 版 325.96**（@76.5052 MHz，ITER=3800，位流 da8ffd31，**A1 后板上实测**；A1 前 313.63 / c6b12d95）；历史：270.82（双发射）→ 233.85（单发射）→ 170.64 → 140.89 → 125.40 → 75.24 → 64.3（改造前）—— 累计 **+368%**（相对改造前） |
| ILA 硬件波形 | [OK] **已抓齐**（`doc/board/ila_hw_*.vcd`，86 探针调试版比特流 md5 `96ee7877`）—— 逐拍证据见 `doc/ila_analysis.md` |
| **应用场景**（RT-Thread + 五子棋）| [OK] **已做成并上板**：RT-Thread Nano 跑在板上（`scripts/rtthread/`），五子棋走**板载 HDMI** 出棋盘、4 键操作、**串口棋盘镜像**（无显示器也能验）。<br>**T1/G3 双线程（render 高优 + AI 低优）2026-10-13 首次上板**（位流 `8894cdcb`）：两条线程都起、**两线程邮箱往返真通**（`AI moved, nodes=10592 depth=6 t=5068ms`）<br>[!] **"AI 思考期间画面不卡"（G3 正题）2026-10-14 已验** —— 位流 `53b81dfe` / `90944754`（`RTL=0x20261019`）：**接屏 + 真按键下完一局判出 `WHITE wins`**，AI 思考 5.7 s 期间画面与按键均正常响应；`vblank timeout` 已定性为 `video_wait_vblank()` **概率命中**（≈1 ms 采样 vs 62.7 µs vsync 脉冲，非显示故障），见 `doc/board/README.md` |

> [当前口径] 板上时钟 **85.0051 MHz**（PLL `STATIC_RATIO0` = 13.5）；CPU 为**顺序双发射**
> **[提交档声明]** 提交档 = 双发射 + `EARLY_LD` + **Cache 全关** @85.0051（跑分 `bcd8fdd2` / 演示 `8894cdcb`）；D-only@85（`56374a08`）与 I+D@76.5（`da8ffd31`）是**评估档**，引用须带"配置 + 主频" —— 权威表见 `doc/paper/论文框架_v1_20261012.md` **§0.1**
> （`rtl/top/cpu_top.v` 的 `parameter DUAL_ISSUE = 1`）+ **任务 C 的 `EARLY_LD=1`** +
> **A1 的乘法器 II=1 流水线**（2026-10-13）+ **I/D Cache 两个 parameter 默认关**（`DCACHE_EN` / `ICACHE_EN`）。
> **[OK] A1 已上板实测通过**（2026-10-13，位流 `bcd8fdd2` / `RTL=0x20261017`，日志 `doc/board/uart_20261013_184111.txt`）：
> 每迭代 **241,633 → 232,345 拍**、效率 **4.139 → 4.304**、ITER **4116 → 4280**，
> `Total ticks 994,229,330` ÷ 85,005,100 = **11.6961 s / 365.93 CoreMark**（拍/迭代 232,296.6，
> 仿真 232,345，差 **−0.021%**），四个 CRC 与仿真逐位相同 ⇒ 较 A1 前的 351.86 **+4.00%**。
> **[历史] A1 之前最后一次板上实测**（2026-10-11/12，位流 `2ddaf32f` / `2f7a4d0a`）：
> `Total ticks 994,386,960` ÷ 85,005,100 = **11.69797 s / 351.86 CoreMark**（ITER=4116，
> **241,633 拍/迭代**）⇒ 比任务 C 之前的 324.5 **+8.4%**；只开 D-Cache 时分数与不开 Cache **完全相同**。
> **[OK] I/D Cache 已上板跑通（A1 后）**（2026-10-13，位流 `da8ffd31`，时钟 76.5052 MHz，
> `RTL=0x20261017`）：`Total ticks 891,885,963` → **11.6578 s / 325.96 分**（ITER=3800，**234,706.8 拍/迭代**），
> 四个 CRC 逐位相同、`[cache] I` 98.944% / `[cache] D` 99.929%；**A1 前**（`c6b12d95`/`RTL=0x20261016`）：`894,745,801` → 11.6952 s / 313.63 分
> ⇒ 相对 85 MHz 版 **−10.9%**，其中 **−10.0% 是主频、只有 −1.03% 是 Cache 周期代价**；
> **两条挂死根因（约定 56/57）已于 2026-10-14 修复**并上板验证（`53b81dfe`/`90944754`，接屏下完一局判出 `WHITE wins`）⇒ **Cache 功能已可用，但仍负收益 ⇒ 提交档默认关**。
> 全流程见 `doc/reports/2026-10-12_idcache_board_bitstream.md`；
> 下一步方针见 `doc/reports/2026-10-12_taskbook_v8.md`。
> **[OK] 双发射已板上实测**（2026-10-06，位流 md5 `5c4893de`）：`Total ticks 994,988,178` ÷ 85,005,100 =
> **11.7050 s / 270.82 CoreMark**（ITER=3170，313,876 拍/迭代，仿真 313,886，差 −0.003%）。
> 日志 `doc/board/uart_20261006_162410.txt`。
> 双发射改的是**效率**（2.751 → 3.186，+15.8%），**时钟没动**；
> 代价：Fmax 91.3993 → 87.0019 MHz、LUT 4,377 → 6,909（+58%）、
> **CoreMark/LUTs 0.0534 → 0.0392（−27%）** —— 赛题三项指标是 **1 升 2 降**，报告里要一起摆。
> 回退版（单发射）位流 `ae4deea9` 仍在，一键回退、不用重综合。
>
> [已板上实测（历史，**单发射**）] **85.0051 MHz 版**（2026-10-04 11:47，位流 md5 `ae4deea9`）：`Total ticks 996,015,474` ÷ 85,005,100 =
> **11.7171 s / 233.85 CoreMark**（ITER=2740，**363,509 拍/迭代**，仿真 363,515，差 −0.0016%）。
> 四个 CRC 与仿真逐位一致，`Correct operation validated`。日志 `doc/board/uart_20261004_114730.txt`。
>
> [已板上实测（历史，**单发射**）] **62.0309 MHz 版**（2026-09-28 21:24）：`Total ticks 727,018,199` ÷ 62,030,900 =
> **11.7203 s / 170.64 CoreMark**，`Iterations 2000`，**363,509 拍/迭代**（仿真 363,515，差 −0.0016%）。
> 累计（单发射线）：75.24（27MHz）→ 125.40（45MHz）→ 140.89（49.89MHz）→ 170.64（62.03MHz）→ 233.85（85.01MHz）。
>
> [重点] **本工程 = CPU 优化线（两拍乘法器 + 提频 + 双发射）+ 视频线（PPU/HDMI）合并**。
> 双发射 CPU 域每迭代 **232,345** 拍（含任务C `EARLY_LD` + A1 乘法器 II=1；`EARLY_LD=0` 时 252,730；单发射 303,140），
> 与视频无关、直接可用。
>
> [重点] 提频的依据是 PDS"满足约束即收敛"（`Estimated Frequency` **不是设计上限**，而是"这次被要求跑多快"）：
> 同一份 RTL 只改分频比实测，请求 85.01 MHz → 达 91.3993 MHz、slack +0.823；请求 99.79 MHz → 失败。
> （上表是**单发射** RTL 的扫频；双发射正式构建的 Estimated 为 **87.0019 MHz**。）
> **真实上限 ≈90 MHz**，取 85 留 ~7% 余量。
> 两拍乘法器把关键路径上的单拍乘法（占 56% ≈ 10.05 ns）摘成独立两拍单元；
> 代价是每迭代 +9,396 拍（+2.65%）。
>
> 板上验证流程见 `doc/board_bringup.md`；CPU 优化交接见
> `doc/reports/2026-09-28_cpu_opt_handoff.md`；ILA 分析见 `doc/ila_analysis.md`。

> 唯一 FAIL 是 `ma_data`（未对齐访存）。2026-09-21 曾据一次测量认为"取指重定向后
> 它自动转为 PASS、说明是冲刷路径的潜在 bug"，**该结论已复核并撤回**：用改造
> 【之前】的 RTL 复测同样是 FAIL，前后行为完全一致（2026-09-25 再次复核，
> 迁移前后都是 `testnum 668`）。
> 真实归因是未对齐访存不做特殊处理（**RISC-V 规范允许**，属架构取舍）。
> 未对齐通路没有专门的测试覆盖，**不把它当作已实现的功能对外承诺**。

---

##  主流程：在 PDS 里做

### 第 1 步：打开工程

```
PDS → File > Open Project →  pds/RV32I_1/RV32I_1.pds
```

> [!] **工程是 `pds/RV32I_1/`，不是 `pds/riscv_cpu/`**（后者是早期的 LED 练习工程）。
> 工程里的源文件指向仓库根的 `../../rtl/**`，**不要在 `pds/` 下另存 RTL 副本**，
> 否则两处会漂移。改 RTL 只需在 PDS 里重新 compile。

### 第 2 步：跑流程

```
compile → synthesize → device map → place & route → generate bitstream
```

产物：`pds/RV32I_1/generate_bitstream/cpu_top_board.sbit`

> [!] **这个文件名看不出里面是哪个固件**（跑分版的还是演示版的）。它只代表
> "最后一次综合的那版"，而 PDS Programmer 会记住上次的路径 —— 只点 Program
> 不重新浏览文件，很容易烧成上一版。**要烧哪一版就用 `build_bitstream.ps1` 生成哪一版**，
> 它会打印 md5。别靠文件名猜。

### 第 3 步：烧录

> [!] 同目录的 `cpu_top_board.smsk` 是掩码文件，**大小和文件头与 `.sbit` 一模一样**，别点错。

**已知无害告警**（可以忽略）：
- `C: Bitstream-2001: SCBV has not been set` —— 配置 bank 电压提醒，不影响上板
- `W: Port 'key[*]' / 'uart_rx' is not constrained` —— 早期未分配 GPIO 引脚时会打印
  （2026-09-23 起 `.fdc` 已分配 LOC），跑 CoreMark 无影响

---

## [!] 唯一需要命令行的一步：编译 C 程序

**PDS 不是 C 编译器**，CoreMark 和演示程序都是 C，必须先用 RISC-V gcc 编成机器码，
再转成 BRAM 能加载的 `mem.hex`。

>  **只有换程序时才需要做这一步。** 平时改 RTL 的话，流程全在 PDS 里。

### 需要装的工具链

```
RISC-V GCC:  D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin
Python 3:    用于把 ELF 拆成 hex
```

### 两条命令（几秒钟）

```powershell
# 上板唯一入口（一条命令：生成固件 → 同步并校验 → 综合出 .sbit，约 5 分钟）
scripts\build_bitstream.ps1 coremark    # 跑分版（双发射 + EARLY_LD，ITER=4280，板上约 11.7 秒）
scripts\build_bitstream.ps1 demo        # 演示版（读按键 → 写 LED → 串口打印）
```

想分步走也可以（**但别漏第 2 步**）：

```powershell
scripts\run_coremark.ps1 -Iter 4280 -SkipSim  # 跑分用（双发射 + EARLY_LD）：85.0051MHz 下约 11.70 秒，满足 ≥10s
scripts\run_demo.ps1 -SkipSim                 # 演示用
scripts\sync_firmware.ps1                     # 必须！同步到 PDS 工程目录
```

然后回 PDS 重新 compile → … → bitstream。

> `-SkipSim` = 只生成固件、不跑仿真。**上板流程只需要 `mem.hex`**，加上这个开关
> 从十几分钟降到几秒。想去掉它跑完整仿真（核实 CoreMark 数值）也可以，要跑十几分钟。
>
> **ITER 的分子是你往哪儿烧的那个时钟，改流水线或换平台都要重算。**
> 当前设计（**双发射 + 任务C `EARLY_LD` + A1 乘法器 II=1**）每迭代 **232,345** 周期（与时钟无关；
> A1 前 241,633；`EARLY_LD=0` → 252,730；**单发射** → 303,140；**带 Cache** → 235,628）：
> * **板上 85.0051 MHz：ITER=4280 → 11.70 秒**（余量 17%；A1 前是 ITER=4116）
> * **I+D Cache 版（76.5052 MHz）：ITER=3668 → 11.70 秒**
> * 仿真 / 远程平台 27 MHz：`270,000,000 ÷ 232,345 ≈ 1162`；27 MHz 时代用的是 **ITER=820**
>   （当时每迭代 358,857 → 实测 10.898 秒）
>
> **用错分子的后果**：ITER 算错会跑不满 10 秒 —— **CoreMark 要求 ≥10 秒，会判 invalid。**

> **`mem.hex` 缺失时 PDS 不会拦住你！** 它只报一行
> `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** —— 但 BRAM 是空的，
> 板上什么都不跑，**且没有任何其他报错**。这个坑踩过，极难排查。
> 综合前务必确认 `pds/RV32I_1/mem.hex` 存在。
>
> **文件在、但内容是上一次的程序，更隐蔽。** PDS 读的是 `pds/RV32I_1/mem.hex`，
> **不是** `sim/programs/mem.hex`，而且从不比较时间戳。跑过 `run_demo.ps1` /
> `run_riscv_tests.ps1` 之后再 sync，工程里就留下 demo / riscv-test 的镜像；
> 此后无论怎么改 RTL、重新综合布线，**板上跑的还是那个旧程序**，PDS 全程零报错。
> **纪律：每次上板前重新跑一遍 `sync_firmware.ps1`。**
> 核对：`mem.hex` 字数应与 ELF 的 `.text` 规模相当 —— CoreMark 固件 = **8,552 字**。

---

##  目录结构

```
riscv-cpu-fpga/
├── rtl/                     RTL 源码
│   ├── core/                CPU 核：core/control/alu/divider/imm_gen/regfile
│   ├── mem/                 unified_mem.v  统一存储器（仅 PDS 综合用）
│   ├── bus/                 addr_map.vh + mem_bus.v（唯一的地址译码处）
│   ├── periph/              uart_tx / uart_rx / gpio
│   ├── top/cpu_top.v        SoC 顶层（仿真用）
│   └── top/cpu_top_board.v [重点] 上板顶层（PDS 的 top）：PLL 27→85.01MHz + 裁剪调试端口 + HDMI
│
├── pds/RV32I_1/ [重点] PDS 工程（源文件指向 ../../rtl/**）
│   ├── RV32I_1.pds          工程文件
│   ├── RV32I_1.fdc          引脚/时钟约束（只有 27MHz 输入晶振；85.01MHz 由 PLL IP 推导）
│   ├── ipcore/pll/          Pango PLL IP（27MHz→85.01MHz），必须以 IP 源形式引用
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
0x0000_0000 - 0x0000_FFEF   RAM（64KB；可用 0x0~0xEFFF = 60KB，栈顶 0xF000）
0x0000_FFF0 - 0x0000_FFFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0xFFF4 R 周期计数   0xFFF8 W done   0xFFFC W UART 发送
0x8000_0000 起              外设区
    0x00 W LED / R {key, led}   0x08 W UART 发送
    0x0C R UART 接收（读弹出）   0x10 R 周期计数
```

---

##  可选：命令行仿真与回归

改 RTL 后建议跑一遍，比上板快得多：

```powershell
scripts\run_riscv_tests.ps1     # 49 PASS / 1 FAIL / 0 TIMEOUT（不需联网）
scripts\run_sim.ps1             # 6 个模块单元测试
scripts\run_coremark.ps1 -Iter 1
scripts\run_demo.ps1            # 演示程序端到端 7/7 PASS
```

**回归纪律**：改动 RTL 后，riscv-tests 与 CoreMark **各跑两种配置**，两条基线**不同、不能混**（除非本次改动就是要改变某一项）：

1. riscv-tests 的 **49/1/0**（双发射、单发射**都是 49/1/0**）
2. CoreMark 计时区间 ← "没碰坏流水线"最灵敏的探针

| 配置 | 怎么跑 | riscv-tests | CoreMark 每迭代 |
|---|---|---|---|
| **双发射 + `EARLY_LD`（默认，= 板上口径）** | `scripts\run_riscv_tests.ps1` / `run_coremark.ps1` | 49 PASS / 1 FAIL / 0 TIMEOUT | **232,345 拍**（A1 前 241,633）|
| 双发射 + `EARLY_LD=0` | 上面不传 `-EarlyLd` | 49 PASS / 1 FAIL / 0 TIMEOUT | **252,730 拍**（原 262,018）|
| **单发射（回退版口径）** | 上面加 `-Single` | 49 PASS / 1 FAIL / 0 TIMEOUT | **303,140 拍**（原 312,428）|
| **带 Cache** | 加 `-DCache -ICache -EarlyLd` | 49 PASS / 1 FAIL / 0 TIMEOUT | **235,628 拍**（原 243,933）|

> `tb_riscv` / `tb_coremark` 靠编译期 `-DDUAL` 选配置；测试台 t=0 打印 `SIM CONFIG: DUAL_ISSUE=?`
> （也进 `sim/programs/results.txt` 首行）；`build_bitstream.ps1` 综合前打印它将综合的 `DUAL_ISSUE`
> （与 md5 并列），并支持 `-Single` 出回退版位流。
> 历史基线（均为**单发射**口径）：358,846 → 382,972 → 420,070 → 354,119 → 363,515 → 312,428 → 303,140。双发射另起一条：`313,886` → `241,633` → `232,345`。

工具链（scoop 安装）：`scoop install iverilog gtkwave`

---

##  文档索引

| 文件 | 内容 |
|---|---|
| `pds/README.md` | **PDS 工程交接说明**（先读这个） |
| `doc/spec.md` | 架构：流水线、存储器与总线、地址映射、已知限制 |
| `doc/base_task_status.md` | 基础任务三条逐条核对 |
| `doc/test_report_riscv-tests.md` | 回归结果、CoreMark 口径推导、板上验证证据 |
| `doc/resource_efficiency.md` | 赛题三个性能指标成文（CoreMark/MHz、Fmax、CoreMark/LUTs） |
| `doc/ila_analysis.md` | 流水线效率剖析 + ILA 抓取方案（含 `.fic` 生成流程）；**硬件波形已抓齐**，三种分支预测行为的逐拍证据在此 |
| `doc/board/` | 板上实测证据：串口原始日志 + ILA 硬件波形（`ila_hw_*.vcd`） |
| `doc/reports/` | 单次改动的验证记录（如取指重定向改造） |
| `doc/plan.md` | 开发计划 |
| `scripts/rtthread/README.md` | **RT-Thread 移植**（BSP / 中断栈切换 / 静态线程 / 内存账）|
| `doc/reports/2026-10-13_T1_rtthread_g3_checklist.md` | 五子棋 RT-Thread 版 **T1/G3 拆线程**的阶段划分与验收判据 |
| `doc/reports/2026-10-13_handoff_btbras.md` | **BTB/RAS 任务书**（分支目标预测；实测判定 BTB 低收益、正解是 RAS）|

---

##  Git 协作

```powershell
git pull origin dualissue               # 开始工作前
git add .
git commit -m "feat: 描述你做了什么"
git push origin dualissue
```

提交信息前缀：`feat:` 新功能 · `fix:` 修复 · `docs:` 文档 · `refactor:` 重构

> [!] **主线分支是 `dualissue`，不是 `main`。** `main` 是"原始 CPU 线"的历史存档
> （两条历史无关，不能直接合并）。**绝不 `git push --force origin main`** ——
> 会把原始历史抹掉。详见 `doc/reports/2026-10-12_taskbook_v8.md` §9。

> [!] **不要提交 PDS 生成物**（`compile/`、`synthesize/`、`.sbit` 等）。
> `.gitignore` 已配置好，用 `git add .` 时它们不会被加入。
> 唯一例外是 `pds/RV32I_1/mem.hex`——它是固件快照，有意入库，便于复现比特流。

---

## [!] 常见问题

**Q：PDS 打开工程后提示找不到源文件？**

A：确认仓库结构完整（`rtl/` 与 `pds/` 同级）。工程用的是相对路径 `../../rtl/**`，
整个仓库目录结构变了就会失效。

**Q：板上什么都没反应，串口没输出？**

A：先查 `pds/RV32I_1/mem.hex` 是否存在。缺失时 PDS 会静默生成空 BRAM 的比特流，
板上什么都不会跑（详见上文红字）。


**Q：改了 RTL，板上行为没变？**

A：PDS 里的 compile 是不是没重跑？另外确认 PDS 打开的是 `pds/RV32I_1/` 而不是旧副本。

**Q：板子跑起来了，但输出的是**上一次**的程序（比如 demo），不是刚编的那个？**

A：**`pds/RV32I_1/mem.hex` 过期了。** PDS 综合读的是工程目录里那一份，不看时间戳，
也**不会**自动从 `sim/programs/` 取新固件。重跑 `scripts\sync_firmware.ps1` 再综合。
排查方法：对 `mem.hex` 的字数 —— CoreMark 固件 **8,552 字**，demo 只有 **163 字**，
riscv-test 约 **431 字**；数字对不上就是拿错镜像了。
