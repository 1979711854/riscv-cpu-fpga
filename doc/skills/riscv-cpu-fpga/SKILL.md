---
name: riscv-cpu-fpga
description: >-
  紫光同创 PDS + RV32IMA 顺序双发射 CPU 竞赛项目（riscv-cpu-fpga）的避坑与工作流技能。
  当在本仓库（含 _merged / _ac 副本）编写或修改 Verilog RTL、跑 riscv-tests / CoreMark 回归、
  用 PDS 综合与上板、报告性能数字、抓 ILA 波形、或更新项目文档时使用。
  内容 = 58 条已踩坑的口径判据 + 当前唯一数字口径 + 提交纪律 + Cache 事故复盘。
  触发词：RISC-V、Verilog、riscv-tests、CoreMark、PDS、紫光同创、上板、位流、ITER、
  DESIGN_REV、回归基线、双发射、Cache、分支预测、ma_data。
---

# riscv-cpu-fpga 项目技能

> 本技能是**避坑地图与判据速查**，不是权威文档。细节以仓库为准：
> `CLAUDE.md`（**58 条**约定）、`doc/spec.md`（架构）、
> `doc/reports/2026-10-13_taskbook_v10_cpu.md` / `..._taskbook_gomoku_v2.md`（当前方针，接到新任务书后以新的为准）、
> `pds/README.md`（工程坑）、`doc/paper/论文框架_v1_20261012.md` §0（数字口径）、
> **§10 事故复盘**（Cache + RT-Thread 挂死的两条根因，2026-10-14 修完并上板验证）。
> **本技能与仓库文档冲突时，以仓库文档为准**，并顺手更新本技能。

## 0. 三十秒版（最高频 9 条）

1. **改 RTL → 递增 `DESIGN_REV`（`csr_file.v`）→ 跑四条基线回归 → 同步文档口径**，三步缺一不可。
2. **CoreMark 得分只认 `ITER × 时钟 ÷ Total ticks`**；串口日志里的 `Iterations/Sec` 是 `HAS_FLOAT=0` 的**整数截断假值**（如日志打 374，真实 351.86）。
3. **`ITER = 时钟 × 10s ÷ 每迭代拍数`**；动流水线 / 动时钟 / 换配置**必须重算**，否则跑不满 10s 被 CoreMark 判 invalid（提频同样会令旧 ITER 失效，两个方向都踩过）。
4. **CRC 只比 `seedcrc / crclist / crcmatrix / crcstate` 四个**；`crcfinal` 是跨迭代累加器，必然随 ITER 变，**不比**。
5. **上板唯一入口 `scripts\build_bitstream.ps1 coremark|demo`**；PDS **不校验 `mem.hex` 时间戳**——缺失和过期都静默产出错误位流、零报错。
6. **`.sbit` 文件名认不出版本**；烧完先看串口首行 `[build] ... RTL=0x...`（= `DESIGN_REV`）对版。
7. **iverilog 报“端口宽度不一致”是静默截位**（32KB 边界回绕、编译零报错、测试全过），脚本已把它当**硬错误**——报错别改脚本，去对齐宽度。
8. **主线分支是 `dualissue`**；`main` 是无关历史的“原始 CPU 线”存档，**禁强推**。
9. **[最贵的一条 · 2026-10-14]** 冻结（`mem_ready_int=0`）拍上，**凡“只该发生一次”的 EX 级副作用都必须与“离开 EX”同拍**：级间寄存器的**清零**（约定 56）、**CSR 写**与 `mret` 的 mstatus（约定 57）、乘法器使能（约定 51）。漏一处就是**静默错值**，而且**只在"有停顿"的配置下暴露**（Cache / `+MEMWAIT` / AMO）——四条基线全盖不住。详见 **§10 事故复盘**。

## 1. 当前口径速查（**2026-10-14**，唯一准入口径）

| 项 | 值 |
|---|---|
| 设计 | RV32IMA + Zicsr/Zifencei，5 级流水线，**顺序双发射**（`DUAL_ISSUE=1`）+ `EARLY_LD=1` + **A1 乘法器 II=1** |
| `DESIGN_REV` | **`0x2026_1019`**（`csr_file.v`；改 RTL 必须递增，约定 42）|
| 平台 | 紫光同创 Logos2 PG2L200H（-6）；PDS 2022.2-SP6.4；盘古板 27MHz 晶振 → PLL：**85.0051 MHz**（`RATIO0=13.5`，生产档）／ **76.5052 MHz**（`RATIO0=15.0`，带 Cache 的降频档）|
| **跑分档（交付）** | **365.93 CoreMark** @85.0051MHz，ITER=**4280**，**232,345** 拍/迭代；位流 **`bcd8fdd2`**（无 Cache）／ **`56374a08`**（D-only，365.92 同分）|
| 功能完整档（I+D） | I+D 全开 @76.5052MHz，ITER=**3800**，**325.96 分**，**234,706.8** 拍/迭代（**A1 后板上实测**，位流 `da8ffd31`，`RTL=0x20261017`）；**A1 前**：313.63 分 / ITER=3668 / 243,932.9 拍（位流 `c6b12d95`）|
| **RT-Thread + Cache 档**（新增）| rtthread 五子棋 + I+D @76.5052 MHz，位流 **`53b81dfe`** / `90944754`（`RTL=0x20261019`）—— **2026-10-14 上板通过**（两条根因修完后的第一颗，见 §10）|
| 效率 | **4.304 CoreMark/MHz**（A1 后；A1 前 4.139）；Fmax 87.00MHz（双发射），真实上限 ≈90MHz |
| 回归 | riscv-tests **49 PASS / 1 FAIL / 0 TIMEOUT**（唯一 FAIL = `ma_data`，**必须是 FAIL**，见 §8） |
| **四条基线（计时区间拍/迭代）** | 双发射+`EARLY_LD` **232,345** / `EARLY_LD=0` **252,730** / 单发射 **303,140** / 双发射+I+D Cache **235,628**（仿真；**板上 234,706.8**）|
| 资源 | LUT **7,482**（**A1 后**双发射无 Cache 口径 = 提交档 `bcd8fdd2` 综合实测；A1 前 6,909）/ **7,896 = 4.94%**（I+D 全 SoC 含视频）；DRM 106.5；APM 4 |
| RTL 规模 | 31 文件 6,106 行（CPU 侧 19 模块 + 视频 PPU 11 模块） |

> 旧→新映射（文档里见到即换算）：351.86→**365.93**；4.139→**4.304**；241,633→**232,345**；
> 262,018→**252,730**；312,428→**303,140**；243,933/235,628→**234,706.8**（板上；仿真值仍写 235,628）；ITER 4116→**4280**；ITER 3668→**3800**；313.63→**325.96**；`RTL=0x20261017`→**`0x20261019`**；
> “Cache 未做”→“已实现、贡献 0、**默认关（但功能已修复并上板验证）**”；“Cache 会挂”→“两条根因已修”（§10）；“32KB”→“**64KB**”。
> （更早：270.82→351.86；3.186→4.139；313,886/313,876→241,633/241,604；ITER=3170→4116；单发射 363,515→312,428。）

## 2. RTL 开发纪律（改 `core.v` / `mem_bus.v` 前必读）

**承重逻辑，不许“顺手改”（改了会静默出错）：**
- **取指补偿**：stall 时是 `imem_addr` 退回 `if_addr_d`，**不是 `pc_r` 后退**——搞反会复现“指令被复制执行”老 bug；跳转重定向的 `+4` 同理。
- **写通路零寄存器**（`mem_bus`）：否则“存完立刻读回”读到旧值（`st_ld`/`ld_st` FAIL）。
- **读数据与读选择位在 MEM→WB 沿寄存**，所有地址源统一 1 拍延迟。
- **静态“全零字按气泡处理”**：`control.v` 的 `default` 必须例外，`if_id_valid` 用它判真指令（否则中断拿气泡 `id_ex_pc=0` 写 mepc）。
- **CSR 写从 EX 级提交**（WB 提交会让 `csrw mepc` 后的 `mret` 读到 0 → 跳回 `_start` → 全测试 TIMEOUT）。
- **trap 必须同时清 EX/MEM**（只清 ID/EX 会让肇事 store 既陷异常又改了内存）。
- **级间快照/前递的选源信号必须与服务的流水级同源**（`wb_rdata_snap` 事故：用 `ex_mem_*` 服务 MEM/WB 级，I-Cache 停顿时写下一条指令的值；判据——“信号名带 `ex_mem_` 就属于 EX/MEM 级”）。
- **[重点] 冻结拍上“只该发生一次”的东西，一律要问“它和谁同拍提交”**（2026-10-14，两条根因）：
  `mem_ready_int=0` 时整条流水线【保持】，但**级间寄存器的清零、CSR 写、mret 副作用、
  多拍单元使能**各有各的写法 —— 与"离开 EX/进入下一级"不同源的，都会在冻结期间**提前或重复**施加：
  * 级间寄存器的**清零**：`if (!resetn || trap || ((ex_flush||ex_mispred||stall_int) && mem_ready_int))`
    —— `ex_flush/ex_mispred/stall_int` 都是【EX 里那条指令自己】发出的，不门控就是"**把自己杀掉**"
    ⇒ `jal/jalr` 的链接值写回永久丢失（约定 56）。
  * **CSR 写**：`csr_wr_en = csr_wr_en_raw && !trap && mem_ready_int`；`mret` 送给 `csr_file` 的
    `.mret()` 同样要门控。不门控 ⇒ 冻结那一拍 CSR 已写、而指令还停在 EX ⇒ 下一拍
    `alu_result = csr_rdata` 取到**写后值** ⇒ `csrrw rd,csr,rs1` 的 **rd 变成新值而不是旧值**（约定 57）。
  * **多拍单元使能**：乘法器 `en` 接 `mem_ready_int`（约定 51），否则结果寄存器自己前进、标志位停住 ⇒ 错位。
  * `trap` 是唯一的例外：**保持无条件**（肇事指令必须死，约定 20）。

**编码规则：**
- iverilog 14 **先声明后使用**；**一信号一 always**；组合逻辑全分支赋值（禁锁存）。
- **外设任何时候不输出 X**（X 进分支比较会走错控制流；`uart_rx` 空 FIFO 坑过）。
- **Verilog 字符串转义没有 `\r`**，换行用 `16'h0D0A` 拼。
- 测试台驱动同步信号避开 posedge 竞态（**negedge 之后**驱动）；**悬空输入是 Z 不是 0**（漏接 `irq_timer`/`vid_*` 会让两颗测试台结论不一致——先怀疑接线）。
- **仿真不编 `rtl/mem/`**（tb 自带 `mem_model.vh`）；**PDS 循环展开上限 2000 次**（数组清零写仿真侧）。
- **承载 word 索引的线宽跟 `imem_addr` 一起走**（现 14 位；`addr_map.vh` 头部有“扩容要一起改哪几处”清单，测试台的 `imem_addr` 也要跟着改）。
- **parameter 开关（`DUAL_ISSUE` / `DCACHE_EN` / `ICACHE_EN` / `EARLY_LD`）改后，回归必须显式带全开关并核对 vvp 首行 `SIM CONFIG:`**——默认回归（`EARLY_LD=0`）盖不住 Cache corner，`wb_rdata_snap` bug 就这么漏过全部基线。

## 3. 仿真回归（每次改 RTL 后，判据是数字不是“过了”）

```powershell
scripts\run_riscv_tests.ps1                  # 49/1/0（默认双发射；-Single 出单发射）
scripts\run_riscv_tests.ps1 -DCache -ICache -EarlyLd   # Cache corner，也必须 49/1/0
scripts\run_coremark.ps1 -Iter 1 -EarlyLd    # +PROF：region cycles 必须 = 232,345（A1 口径）
scripts\run_coremark.ps1 -Iter 1             # EARLY_LD=0 口径 = 252,730
scripts\run_own_tests.ps1 -DCache -ICache -EarlyLd     # 自写汇编测试（异常/中断/AMO）2 PASS
scripts\rtthread\run_sim.ps1 -NoBuild                 # RT-Thread 五子棋（无 Cache）
scripts\rtthread\run_sim.ps1 -NoBuild -DCache -ICache # ← **Cache corner 的真回归**（四种配置都该 PASS）
scripts\rtthread\run_sim.ps1 -NoBuild -ICache -LdChk  # load 数据自检 + 规范化事件流（见 §10）
```

- **[!] 默认回归盖不住"有停顿"的配置**：`run_riscv_tests` 默认 `EARLY_LD=0` 且无 Cache；
  RT-Thread 线的 `run_sim.ps1` 默认也没有 `-D` 旗标。**动流水线/停顿逻辑后，四份 RT-Thread 配置
  （无Cache / 只D / 只I / I+D）是唯一能抓到冻结相关 bug 的组合**（约定 55/56/57 都是这么漏过去的）。

- **`ma_data` 必须是 FAIL（testnum 668）**——它是回归哨兵：若哪天 PASS 了，说明有人动了 load/store 字节抽取逻辑，属非预期改动。
- **CoreMark 计时区间一字不差**是“没碰坏流水线”的最灵敏探针；只有“目的就是改变它”的改动才允许它动。
- **`region cycles` 变成 1 = banner 误用了 `ee_printf`**（它忙等读 `0xFFF4`，会提前开关计时区间，而 `Total ticks` 仍是对的，从跑分上看不出来）。CoreMark 的版本自证行必须**直写 UART 口、不忙等**。
- `ITER=1` 报 `ERROR! Must execute for at least 10 secs` 是**正常现象**，判据看 ticks 和四个 CRC。

## 4. CoreMark 口径（报错数高发区）

- **`HAS_FLOAT=0`**：`Total time (secs)` 整数截断、`Iterations/Sec = ITER ÷ 截断秒`。真实秒数 = `Total ticks ÷ 时钟`（时钟用 PDS 报告实测值，不用标称）。
- **ticks 就是 CPU 周期**（读 MMIO `0xFFF4` = mtime，跟系统时钟自由跑）。
- **板/仿真每迭代差 ±0.04% 是模型抖动**（方向会反），不是趋势，别追。
- **别用 ITER=1 的测试台总周期算迭代成本**（含 ~108 万拍的一次性打印开销）；也别把提频收益与效率优化收益混乘（两笔独立账）。
- 各时钟/配置的拍/迭代与 ITER 对照见 §1 表；**换任何一样都要重算 ITER**。

## 5. PDS 综合与上板

- **`mem.hex` 两个坑**：① 缺失 → 只报一行 `Cannot open specified data file` 然后照常出空 BRAM 位流；② **过期更隐蔽**——文件在、大小正常，内容是上次的镜像，PDS 从不比时间戳。判据：`pds.log` 里 `Loading memory data from file ... mem.hex` + 核对字数（CoreMark ≈4209 字；demo 约 101 字）。**纪律：每次上板前重跑 `build_bitstream.ps1`，别凭“上次同步过了”。**
- **`.fdc` 里只有 27MHz 输入晶振的 `create_clock`**；85.0051MHz 是 PDS 从 **PLL IP 自动推导**的，别手动改那句约束，也别以为没生效。
- **改频率 = 三处联动 + 事后全部还原**：`pll.idf` 的 `STATIC_RATIO0` → `ip_generate.exe -i pll.idf`（**不是**改 `CLKOUT0_REQ_FREQ`）→ `cpu_top_board.v` 的 `UART_DIV = f÷115200` → `core_portme.c` 的 `EE_TICKS_PER_SEC` → 重算 ITER。不还原 = 下次跑分位流时钟口径错且看不出来。
- **`.sbit` / `.smsk` 大小和文件头一样，别点错**；Programmer 会记住上次文件，**每次重新 `Assign New Configuration File`**；**Jtag 与 USB-UART 是两块接口，两根 USB 线都要插**；**板子断电即丢配置**（两灯不亮先问是不是没重烧，别怀疑设计）。
- **`Estimated Frequency` 是“这次被要求跑多快”，不是设计上限**（真实上限 ≈90MHz；请求 99.79 失败过）。
- **降频演示这条路对带 Cache 的设计是坏的**（请求 71.72 只做出 61.92，slack 比请求 85 还差）；同一 RTL 两次布局的“真实 Fmax”可差 0.42ns——**引用余量必须说明是哪一次跑的**。
- **位流归档纪律**：文件名带 `_dual_`/`_single_`（两者字节数一样，烧错只表现为分数差 15.8%，比烧错固件更难发现）；**带 parameter 开关的位流必须验网表**（`grep -aic dcache ...pnr.netlist` + DRM 数 + slack），脚本打印和文件名都不可信；`.sbit` md5 **只在同一仓库内可比**（内嵌工程路径）。
- **判"烧的是哪颗位流"只认 RTL 侧的 `mimpid`**（串口 `[build] ... RTL=0x…` 行，约定 42/58）；
  横幅里那句主频/版本如果与位流不符，先怀疑**固件里写死了字面量**（2026-10-14 实踩：
  76.5052 的位流打出 `@85.0051MHz`，看着像烧错位流）。**⇒ 由 RTL / 编译宏决定的数字，一律算出来。**
- **`build_bitstream.ps1` 的 `expectLines` 守卫拦住了就别放宽**：它比的是同步进 PDS 的 `mem.hex`
  行数（`rtthread = 20276` / `10138 字`，2026-10-14 更新）。它拦下来的正是"源码改了、固件变了、
  但你不知道"这一类 —— 改过编译期常量/固件源码后，**确认新行数合理再更新这张表**。
- `DEBUG_LED` 参数决定 `led[2:0]` 是调试信号还是 GPIO；PDS 取默认值、命令行传不了 `-D`，`build_bitstream.ps1` 已按变体自动改并还原。

## 6. ILA / 硬件调试（如需要）

- 探针属性 **`PAP_MARK_DEBUG` 与 `syn_keep` 两个都写**，挂**声明**上、**分号之前**；**多比特线会被整条丢弃，必须拆成一位一根**。
- **Inserter 选不到模块端口**（`pc`/`mem_we`）→ 在 RTL 里建内部 wire 别名再标记；PC 在网表里叫 `pc` 不叫 `pc_r`。
- **Fabric Debugger 先连 JTAG Server**（`127.0.0.1:65420`），不连只看到空树标题。
- **抓 CoreMark 波形必须先按复位键**（程序 11.7s 后进停机自旋，无条件分支，触发永远等不到）。
- `.fic` 与 `.sbit` **同批成对**；抓完立刻存 `.dprj`（视图会丢，波形在 `data.wf` 不丢）。

## 7. 文档与会话纪律

- **数字口径唯一真相**：`doc/paper/论文框架_v1_20261012.md` §0；历史报告里的旧数**留原样 + 加横幅指向**，不要逐个改写历史。
- **`ma_data` / Cache / mtime 的说法按 §8 口径统一**，别混用新旧结论。
- **一个会话只干一个里程碑**；盯 ctx 用量，**65% 收尾**（写状态 + commit），75% 不开新任务线；结论**立刻落盘**（进度在 git 里不在对话里）。
- **`.ps1` 必须带 UTF-8 BOM**（PS 5.1 无 BOM 按 GBK 读，中文注释会吃掉引号配对报假语法错）；外部 GBK 文件别覆盖保存；源码统一 UTF-8；交流用简体中文。
- 提交按里程碑拆、信息写清；**不自动 push**；推 `dualissue`。

## 8. 设计取舍与答辩口径（这些不是 bug，别去“修”）

- **`ma_data` FAIL（49/50）**：规范允许“硬件支持 **或** 陷异常”二选一，本设计选陷异常（cause 4/6、mtval=出错地址、mepc=出错 PC、mret 可恢复）。已反汇编证实官方 `ma_data` 测试**要求硬件支持、不接受陷阱路径**，故 49/50 是该路线下的预期上限。软件栈（GCC ilp32）不发非对齐访问，零实际影响。
- **I/D Cache 对分数贡献 = 0**（后端单周期 BRAM，命中 1 拍零收益、缺失 2 拍纯亏）：已实现（4KB/侧、2 路）、已上板实测（I 98.985% / D 99.929%），**默认关**。I+D 全开必须降到 76.5MHz（I-Cache 在取指关键链上，布局拥塞非逻辑量）。
  * **答辩口径（2026-10-14 更新，比原来更硬）**：不只是"贡献 0" —— 它在非 CoreMark 负载
    （RT-Thread / 五子棋）上**曾确定性挂死**，根因是**流水线在访存冻结拍上的两处门控缺陷**
    （约定 56 / 57，§10 事故复盘），**已修复并上板验证**（位流 `90944754`，`RTL=0x20261019`）。
    所以正确说法是：**"Cache 功能上已可用（两条缺陷已定位修复、上板验证），但在本设计里是
    负收益：分数贡献 ≈0，却要求把主频从 85.0 降到 76.5 MHz ⇒ 默认关"**。
    **别说"Cache 有 bug 所以没用"**（那是修复前的状态），也**别说"Cache 能提分"**。
- **mtime 是 32 位**：85MHz 下 **≈50.5s 回绕**（76.5MHz 下 ≈56s）。RT-Thread tick 用“每次重写 mtimecmp = 当前 mtime + 周期”天然安全；别把 mtime 当绝对 uptime。
- **MEIP 外部中断只有通路无测试**，不得对外承诺；**自修改代码有理论窗口**（改写自己取指窗口内的指令，无 I-Cache 简单核的固有性质）；**RVC 已评估收益≈0，不做**。
- **边缘 AI 硬件不可行**（64KB 内存无片外存储），写“后续工作/不做”并给理由。

## 9. 环境与仓库速查

- 工具链：`riscv-none-elf-gcc 15.2.0`（`D:\riscv-toolchain\xpack-...\bin`）；iverilog 14 + GTKWave；PDS 2022.2-SP6.4（**不是 Vivado**）。
- 上板顶层 `rtl/top/cpu_top_board.v`（仿真用 `cpu_top.v`）；**统一存储器** `rtl/mem/unified_mem.v`（承重，永删不得——注意与队友导出目录里同名 IP 失败产物区分，转述必带路径）。
- 地址映射唯一定义在 `rtl/bus/addr_map.vh`（RAM 64KB：`0x0~0xFFEF`，可用 `0x0~0xEFFF`，栈顶 `0xF000`，兼容区 `0xFFF0~0xFFFF`）；改它要三处同步（RTL + `scripts/demo/addr_map.h` + `doc/spec.md`）。
- 基线 ELF 金标准：`third_party/riscv-tests-elf/`（上游会变，回归以入库这批为准）。
- 关键脚本：`build_bitstream.ps1`（上板唯一入口）、`sync_firmware.ps1`、`serial_monitor.ps1`（落盘 `doc/board/uart_<时间戳>.txt`）、`elf2mem.py`、`trace2svg.py`、`pair_analyze.py`。
- 交接打包：`scripts/pack_for_teammate.ps1`（含 `.git`；`.sbit` 不入库，队友自行综合）。

## 10. 事故复盘：Cache + RT-Thread 确定性挂死（2026-10-14 定位、修复、上板验证）

**这是本项目最贵的一次线上排查**（跨 3 个会话），两条根因都在 `core.v` 的**同一类缺陷**上。
逐字证据链：`doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`（归因）→
`..._cache_fix_bug1.md`（#1）→ `..._cache_fix_bug2.md`（#2）。

### 10.1 症状是怎么一步步显现的

| 阶段 | 现象 | 当时的错误判断 |
|---|---|---|
| 板上 | rtthread + **I+D Cache** @76.5（`c10a2478`）只有一行 `?? turn=WHITE`（原始字节是固件实发的损坏数据），死在"AI 第一手后第一张棋盘快照"；**同一固件在无 Cache 位流上完全正常** | 疑 Cache 布局/时序（**实际是功能 bug**，网表与时序都是干净的） |
| 仿真 | `-ICache` **13 字节**就挂 | 疑 trap 路径 |
| 修 #1 后 | 能完整启动（两条线程 + 心跳），**跑远仍挂** | 看到 `trap_tval` 像**指令字/ASCII** ⇒ 断定"**某次 load 返回了隔壁的数据**" ← **这个判断是错的** |
| 修 #2 后 | rtthread **四种配置全 PASS**；板上串口侧通过 | — |

### 10.2 两条根因（都在"冻结拍"上）

1. **#1 · ID/EX 清零漏 `mem_ready_int`**（约定 56）：`ex_flush/ex_mispred/stall_int` 是【EX 里那条
   指令自己】发出的，冻结时清 ID/EX = **把发跳转的那条指令自己杀掉** ⇒ `jal/jalr` 链接值永久丢失。
2. **#2 · CSR 写（EX 级提交）漏 `mem_ready_int`**（约定 57）：冻结那拍 CSR 已写、指令却还停在 EX
   ⇒ 下一拍 `alu_result = csr_rdata` 是**写后值** ⇒ `csrrw rd,csr,rs1` 的 **rd 拿到新值**。
   RT-Thread 中断入口/出口各有一条 **`csrrw sp, mscratch, sp`（rd 就是 sp）** ⇒ 冻结撞上它时
   **sp 不切到中断栈**、处理函数跑在线程栈上；出口那条再把 `mscratch` 写坏 ⇒ 之后**每次中断的 sp
   都在漂移** ⇒ 128 B 存帧写到半随机位置 ⇒ **踩坏内核链表** ⇒ `_timer_remove` 的 `sw a4,4(a3)`
   未对齐 ⇒ `cause=6` 死循环转储。

**决定性证据**（处理函数 C 帧落点，`-LdChk` 事件流里的 store 地址）：
无 Cache 金标准 `0xffec`（中断栈）/ `-ICache` 修前 **`0xb490`（线程栈！）** / 修后 `0xffec`。

### 10.3 为什么四条基线**全都**盖不住（最该记住的一节）

| 回归 | 为什么盖不住 |
|---|---|
| `run_riscv_tests` 默认 | 无 Cache ⇒ **`mem_ready_int` 恒 1** ⇒ 两条 bug 都**不触发** |
| `run_coremark` 默认 | 同上；且 CoreMark **不写 CSR、不 trap** ⇒ 即使有停顿也碰不到 #2 |
| riscv-tests + Cache | 代码只有 1~2 KB ⇒ 缺失少、冻结稀疏；**不 trap** ⇒ 碰不到 #2 |
| 自写 `exceptions`/`timer_irq` | 有 trap 但代码极小 ⇒ 撞上冻结的概率≈0 |

**⇒ 唯一能抓到它们的是 RT-Thread 五子棋（大固件 + 1 ms 定时器中断）跑在 [有停顿的配置] 上。**
而 rtthread 线的 `run_sim.ps1` 当时**一个 `-D` 都不传**（约定 55）——**没有那份仿真覆盖，这条线就是盲区**。

### 10.4 可复用的定位方法（#2 就是靠这个把范围缩小的）

1. **先给"最像的原因"做一个可判定的自检，把它证伪**：本轮给 `tb_rtthread` 加 `-LdChk`
   —— 影子寄存器与 MEM/WB **同门控**镜像、期望值取存储器真值 `mem0[addr]` 按 funct3 解包。
   结果 **297,379 条 RAM load 一条不错** ⇒ "load 返回错数据"**被证伪**，嫌疑才转到中断/副作用上。
   *（上一轮从 `trap_tval` 反推"load 读错"是**合理的猜测**，但**没有判据** —— 这就是多花一个会话的代价。）*
2. **用规范化事件流对拍**两份日志（`rtthread_ldtrace.txt`：load 记 WB 沿、store 记 MEM 沿、
   停顿折叠）⇒ 首处分叉 = event 33656 = **第一次撞上冻结的定时器中断**。
   - [!] **中断落在哪条指令上是随机的、无害的**；**"被冻结的中断"才是有害的** —— 别把前者当 bug。
3. **盯"冻结拍"这个隐藏状态机**：把所有 EX 级副作用列一遍，逐个问"它和谁同拍提交"。

### 10.5 教训（可迁移，按代价排序）

1. **"仿真过了"只在配置打印全对时才成立**；**没有停顿的配置测不出停顿相关的 bug** ——
   改动停顿逻辑后，回归必须**显式**带 `-DCache -ICache -EarlyLd`（和 `+MEMWAIT`）。
2. **冻结拍是"隐藏状态机"**：级间清零 / CSR 写 / mret / 多拍使能 / 快照选源 / 外设写选通，
   一律要求"**只发生一次，且与离开该级同拍**"；`trap` 是唯一例外（无条件）。
3. **别让"症状"直接变成"根因"**：`tval` 看着像隔壁内存 ⇒ 不等于 load 读错。**先造判据再下结论。**
4. **同一类缺陷会重复出现**：#1 和 #2 是同一个"漏门控"的两个实例。修完一处要**横向搜一遍同类**。
5. **位流身份只认 `mimpid`（`RTL=` 行）**；固件里由 RTL/编译宏决定的数字**一律算出来**（约定 58）。
6. **仿真定位、板上定案**：两条根因的最终确认（含"上板跑通"）才是闭环；
   上板前先把仿真开关补齐（约定 55 的教训反着用）。
7. **大固件（RT-Thread/五子棋）才是硬件 bug 的照妖镜**：CoreMark 这类"小而纯"的负载
   会**系统性地漏掉** trap/中断/调度路径上的缺陷。
8. **[!] 功能修复 ≠ 能塞进主频 —— 必须分两笔账量**（2026-10-14 实测）：
   这两处修复都是一句 `&& mem_ready_int`，而 **`mem_ready_int` 是本设计里【最晚】的使能信号之一**
   （ID/EX、EX/MEM、MEM/WB、乘法器共用；带 Cache 时它还要等取指缺失/tag 比较）。
   实测代价：**85 MHz 的 Cache-全关生产档从 `+0.068 ns / 0 失败端点` 掉到 `−0.153 ns / 16 端点`**
   ⇒ 重出后**时序不过**（两次独立运行逐位相同，确定性）。而 **76.5052 MHz 的带 Cache 档仍有
   `+0.534 ns / 0`** ⇒ **最终分工 = 生产档留 rev1017（功能等价已证）、带 Cache 档用 rev1019**。
   **⇒ 规矩**：给一条**已经很晚**的信号加逻辑（尤其是加扇出）之后，**必须重新量时序**，
   不能只看"功能仿真过了"；余量只有 0.068 ns 时，一句 AND 就可能吃穿。

### 10.6 判据与工具速查（这次新增的）

| 工具 | 用途 | 关键读法 |
|---|---|---|
| `scripts\rtthread\run_sim.ps1 -DCache -ICache` | **Cache corner 真回归** | 必须 PASS（两条线程 + 心跳） |
| `... -LdChk` | load 数据自检 + 规范化访存事件流 | `0` 条错 load；两份日志逐行 diff 找首处分叉 |
| `... -TrapTrace` / `-ITrace` / `-LTrace` / `-PcTrace` | 归因（trap/指令流/访存/PC） | 见 `..._bisect.md` |
| `scripts\itrace_stream_diff.py` | 指令流对拍（**配对感知**） | `pc` 流在双发射下会因配对差异假分叉 |
| 中断栈落点（本报告 10.2） | **一眼判"中断处理函数有没有跑在正确栈上"** | 无 Cache 金标准 `0xffec`；跑在线程栈（`0xb4xx`）= 坏 |

> **收尾口径**：rtthread + I+D @76.5052 MHz 位流 `90944754`（`RTL=0x20261019`）已上板：
> 两条线程 + `[hb]` 无断 + **接屏下棋正常**；生产/交付仍用 Cache 全关（`bcd8fdd2` / `8894cdcb`）。
