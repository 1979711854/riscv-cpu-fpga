---
name: riscv-cpu-fpga
description: >-
  紫光同创 PDS + RV32IMA 顺序双发射 CPU 竞赛项目（riscv-cpu-fpga）的避坑与工作流技能。
  当在本仓库（含 _merged / _ac 副本）编写或修改 Verilog RTL、跑 riscv-tests / CoreMark 回归、
  用 PDS 综合与上板、报告性能数字、抓 ILA 波形、或更新项目文档时使用。
  内容 = 50 条已踩坑的口径判据 + 当前唯一数字口径 + 提交纪律。
  触发词：RISC-V、Verilog、riscv-tests、CoreMark、PDS、紫光同创、上板、位流、ITER、
  DESIGN_REV、回归基线、双发射、Cache、分支预测、ma_data。
---

# riscv-cpu-fpga 项目技能

> 本技能是**避坑地图与判据速查**，不是权威文档。细节以仓库为准：
> `CLAUDE.md`（50 条约定）、`doc/spec.md`（架构）、`doc/reports/2026-10-12_taskbook_v8.md`（当前方针）、
> `pds/README.md`（工程坑）、`doc/paper/论文框架_v1_20261012.md` §0（数字口径）。
> **本技能与仓库文档冲突时，以仓库文档为准**，并顺手更新本技能。

## 0. 三十秒版（最高频 8 条）

1. **改 RTL → 递增 `DESIGN_REV`（`csr_file.v`）→ 跑四条基线回归 → 同步文档口径**，三步缺一不可。
2. **CoreMark 得分只认 `ITER × 时钟 ÷ Total ticks`**；串口日志里的 `Iterations/Sec` 是 `HAS_FLOAT=0` 的**整数截断假值**（如日志打 374，真实 351.86）。
3. **`ITER = 时钟 × 10s ÷ 每迭代拍数`**；动流水线 / 动时钟 / 换配置**必须重算**，否则跑不满 10s 被 CoreMark 判 invalid（提频同样会令旧 ITER 失效，两个方向都踩过）。
4. **CRC 只比 `seedcrc / crclist / crcmatrix / crcstate` 四个**；`crcfinal` 是跨迭代累加器，必然随 ITER 变，**不比**。
5. **上板唯一入口 `scripts\build_bitstream.ps1 coremark|demo`**；PDS **不校验 `mem.hex` 时间戳**——缺失和过期都静默产出错误位流、零报错。
6. **`.sbit` 文件名认不出版本**；烧完先看串口首行 `[build] ... RTL=0x...`（= `DESIGN_REV`）对版。
7. **iverilog 报“端口宽度不一致”是静默截位**（32KB 边界回绕、编译零报错、测试全过），脚本已把它当**硬错误**——报错别改脚本，去对齐宽度。
8. **主线分支是 `dualissue`**；`main` 是无关历史的“原始 CPU 线”存档，**禁强推**。

## 1. 当前口径速查（2026-10-13，A1 之后；**唯一准入口径**）

| 项 | 值 |
|---|---|
| 设计 | RV32IMA + Zicsr/Zifencei，5 级流水线，**顺序双发射**（`DUAL_ISSUE=1`）+ `EARLY_LD=1` |
| 平台 | 紫光同创 Logos2 PG2L200H（-6）；PDS 2022.2-SP6.4；盘古板 27MHz 晶振 → PLL（`RATIO0=13.5`）→ **85.0051 MHz** |
| **跑分档** | **[OK] 板上实测 365.93 CoreMark** @85.0051MHz，ITER=4280，ticks 994,229,330，232,296.6 拍/迭代（**A1 后当前最好成绩**；位流 `bcd8fdd2`、`RTL=0x20261017`，日志 `doc/board/uart_20261013_184111.txt`）。**A1 前**：351.86 分 / ITER=4116 / 241,633 拍 |
| 功能完整档 | I+D Cache 全开 @76.5052MHz，ITER=3668，**313.63 分**，243,933 拍/迭代（`RTL=0x20261016`，**A1 前口径**） |
| 效率 | **4.304 CoreMark/MHz**（每迭代 232,345 拍，**A1 后当前值**）；I+D 版 4.244/235,628。A1 前 4.139/241,633（I+D 4.099/243,933）。Fmax 87.00MHz（双发射），真实上限 ≈90MHz |
| 回归 | riscv-tests **49 PASS / 1 FAIL / 0 TIMEOUT**（唯一 FAIL = `ma_data`，**必须是 FAIL**，见 §8） |
| 四条基线（计时区间拍/迭代） | 双发射+`EARLY_LD` **232,345**（默认）/ `EARLY_LD=0` **252,730** / 单发射 **303,140** / 带 Cache **235,628** |
| 资源 | LUT 7,482（A1 后双发射，A1 前 6,909 —— 乘法器流水化 +228）/ 7,896（I+D，4.94%）；DRM ~106；APM 4 |
| RTL 规模 | 31 文件 6,106 行（CPU 侧 19 模块 + 视频 PPU 11 模块） |

> 旧→新映射（文档里见到即换算）：270.82→**351.86**；3.186→**4.139**；313,886/313,876→**241,633/241,604**；
> ITER=3170→**4116**；单发射 363,515→**312,428**；“Cache 未做”→“已实现、贡献 0、默认关”；“32KB”→“**64KB**”。
> **A1 那一档（2026-10-13）**：241,633→**232,345**；4.139→**4.304**；ITER 4116→**4280**；
> 262,018→**252,730**；312,428→**303,140**；243,933→**235,628**；351.86→**365.93**（已验证）；
> `DESIGN_REV` 0x2026_1016→**0x2026_1017**。

## 2. RTL 开发纪律（改 `core.v` / `mem_bus.v` 前必读）

**承重逻辑，不许“顺手改”（改了会静默出错）：**
- **取指补偿**：stall 时是 `imem_addr` 退回 `if_addr_d`，**不是 `pc_r` 后退**——搞反会复现“指令被复制执行”老 bug；跳转重定向的 `+4` 同理。
- **写通路零寄存器**（`mem_bus`）：否则“存完立刻读回”读到旧值（`st_ld`/`ld_st` FAIL）。
- **读数据与读选择位在 MEM→WB 沿寄存**，所有地址源统一 1 拍延迟。
- **静态“全零字按气泡处理”**：`control.v` 的 `default` 必须例外，`if_id_valid` 用它判真指令（否则中断拿气泡 `id_ex_pc=0` 写 mepc）。
- **CSR 写从 EX 级提交**（WB 提交会让 `csrw mepc` 后的 `mret` 读到 0 → 跳回 `_start` → 全测试 TIMEOUT）。
- **trap 必须同时清 EX/MEM**（只清 ID/EX 会让肇事 store 既陷异常又改了内存）。
- **级间快照/前递的选源信号必须与服务的流水级同源**（`wb_rdata_snap` 事故：用 `ex_mem_*` 服务 MEM/WB 级，I-Cache 停顿时写下一条指令的值；判据——“信号名带 `ex_mem_` 就属于 EX/MEM 级”）。

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
scripts\run_coremark.ps1 -Iter 1             # +PROF：region cycles 必须 = 232,345（ITER=1 默认口径，A1 后）
scripts\run_own_tests.ps1                    # 自写汇编测试（异常/中断/AMO）
```

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

- **`mem.hex` 两个坑**：① 缺失 → 只报一行 `Cannot open specified data file` 然后照常出空 BRAM 位流；② **过期更隐蔽**——文件在、大小正常，内容是上次的镜像，PDS 从不比时间戳。判据：`pds.log` 里 `Loading memory data from file ... mem.hex` + 核对字数（**CoreMark 8,552 字 / 17,104 行**；demo 163 字；rtthread 9,562 字；gomoku 5,634 字；video 379 字 —— 权威值在 `build_bitstream.ps1` 的 `$expectLines`/`$expectDesc`）。**纪律：每次上板前重跑 `build_bitstream.ps1`，别凭“上次同步过了”。**
- **`.fdc` 里只有 27MHz 输入晶振的 `create_clock`**；85.0051MHz 是 PDS 从 **PLL IP 自动推导**的，别手动改那句约束，也别以为没生效。
- **改频率 = 三处联动 + 事后全部还原**：`pll.idf` 的 `STATIC_RATIO0` → `ip_generate.exe -i pll.idf`（**不是**改 `CLKOUT0_REQ_FREQ`）→ `cpu_top_board.v` 的 `UART_DIV = f÷115200` → `core_portme.c` 的 `EE_TICKS_PER_SEC` → 重算 ITER。不还原 = 下次跑分位流时钟口径错且看不出来。
- **`.sbit` / `.smsk` 大小和文件头一样，别点错**；Programmer 会记住上次文件，**每次重新 `Assign New Configuration File`**；**Jtag 与 USB-UART 是两块接口，两根 USB 线都要插**；**板子断电即丢配置**（两灯不亮先问是不是没重烧，别怀疑设计）。
- **`Estimated Frequency` 是“这次被要求跑多快”，不是设计上限**（真实上限 ≈90MHz；请求 99.79 失败过）。
- **降频演示这条路对带 Cache 的设计是坏的**（请求 71.72 只做出 61.92，slack 比请求 85 还差）；同一 RTL 两次布局的“真实 Fmax”可差 0.42ns——**引用余量必须说明是哪一次跑的**。
- **位流归档纪律**：**每块上板实测过的位流都要归档 + 登记** —— 复制 `generate_bitstream/cpu_top_board.sbit` 到 `pds/RV32I_1/bitstreams/`，**改名**为 `<变体>_<配置>_<时钟>_<rev|日期>_<md5前8>.sbit`，并在该目录 `README.md` 的表格**加一行**（写清：测到什么、`RTL=0x…`、`Total ticks`、CRC、拍/迭代、日志文件名）。**`generate_bitstream/` 每次综合都会被清空，不归档就等于没有。** 文件名带 `_dual_`/`_single_`（两者字节数一样，烧错只表现为分数差 15.8%，比烧错固件更难发现）；**带 parameter 开关的位流必须验网表**（`grep -aic dcache ...pnr.netlist` + DRM 数 + slack），脚本打印和文件名都不可信；`.sbit` md5 **只在同一仓库内可比**（内嵌工程路径）。
- **PLL IP 必须以 IP 源文件形式（`wgt_my_ips_src`）加入**，当普通 `.v` 加会报黑盒；**别往 `pds/` 拷 RTL 副本**（工程指向 `../../rtl/**`）。
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
- **I/D Cache 对分数贡献 = 0**（后端单周期 BRAM，命中 1 拍零收益、缺失 2 拍纯亏）：已实现（4KB/侧、2 路）、已上板实测（I 98.985% / D 99.929%），**默认关**。答辩口径 = “实现并量化评估后判定负收益，价值在功能条目”。I+D 全开必须降到 76.5MHz（I-Cache 在取指关键链上，布局拥塞非逻辑量）。
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
