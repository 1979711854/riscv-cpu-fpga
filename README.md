# 基于紫光同创 FPGA 的 RISC-V 五级流水线 CPU

> 全国大学生嵌入式芯片与系统设计竞赛 —— FPGA 赛道 · 紫光同创选题

器件：紫光同创 **Logos2 PG2L200H-6FBB676**　工具：**Pango Design Suite 2022.2-SP6.4**
处理器：**RV32I + M 扩展**，5 级流水线（IF/ID/EX/MEM/WB）

## 当前成绩

| 项目 | 结果 |
|---|---|
| riscv-tests（rv32ui + rv32um，50 项） | **49 PASS / 1 FAIL / 0 TIMEOUT** |
| 动态分支预测 | [OK] **已实现**（256 项、2 位饱和计数器、带 tag 的 BHT，只预测条件分支方向，2026-09-25）—— 高阶任务②（动态分支预测 + 完整异常/中断）**已完整** |
| CoreMark 效率 | **2.751 CoreMark/MHz**（每迭代 **363,515** 周期，与时钟无关）<br>历史：2.824（BHT 后）→ 2.787 → 2.611 → 2.380 |
| CoreMark **板上实测** | **62.0309 MHz / ITER=2000 → 11.7203 秒**（**170.64 CoreMark**，2026-09-28）<br>历史：49.89 MHz → 11.8031 秒 / 140.89；45 MHz → 11.9619 秒 / 125.40；27 MHz → 10.898 秒 / 75.24 |
| 时序（62.0309 MHz，PLL 倍频） | 约束 **62.0309 MHz** / Estimated **67.78 MHz**，Setup **+1.368 ns**，**失败端点 0**<br>[!] 这是**未带 PPU 的 CPU 线**数字；本工程合并 PPU 后必须重新综合实测（见下） |
| 资源（新设计） | LUT **3,767**、FF 2,508、DRM 16、**APM 4**（两拍乘法器重构后从 11 降下来）、分布式 RAM 336<br>[!] **未含 PPU 视频资源**，合并后需重测 |
| 实际得分 | **170.64 CoreMark** @62.0309 MHz（**板上实测**）<br>历史：49.89 MHz 板测 140.89；45 MHz 板测 125.40；27 MHz 板测 75.24 —— **累计 +126.8%** |
| ILA 硬件波形 | [OK] **已抓齐**（`doc/board/ila_hw_*.vcd`，86 探针调试版比特流 md5 `96ee7877`）—— 逐拍证据见 `doc/ila_analysis.md` |

> [CPU 线已板上实测] **62.0309 MHz 版**（2026-09-28 21:24）：`Total ticks 727,018,199` ÷ 62,030,900 =
> **11.7203 s / 170.64 CoreMark**，`Iterations 2000`，**363,509 拍/迭代**（仿真 363,515，差 −0.0016%）。
> 累计：75.24（27MHz）→ 125.40（45MHz）→ 140.89（49.89MHz）→ **170.64（62.03MHz）= +126.8%**。
>
> [重点] **本工程 = CPU 优化线（62.03MHz + 两拍乘法器）+ 视频线（PPU/HDMI）合并**。
> 上面 CoreMark 周期（363,515）与得分（170.64）是**纯 CPU 域口径**，与视频无关、直接可用；
> 但**资源/时序两行是 CPU 线未带 PPU 的数字** —— 合并 PPU 后必须重新综合 + 上板实测，
> 别照抄（见 `doc/reports/2026-09-28_cpu_opt_handoff.md` §5）。
>
> [重点] 两拍乘法器把关键路径上的单拍乘法（占 56% ≈ 10.05 ns）摘成独立两拍单元，
> 换来主频 49.89 → 62.03 MHz；代价是每迭代 +9,396 拍（+2.65%）。
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
scripts\build_bitstream.ps1 coremark    # 跑分版（ITER=1663，板上约 11.8 秒）
scripts\build_bitstream.ps1 demo        # 演示版（读按键 → 写 LED → 串口打印）
```

想分步走也可以（**但别漏第 2 步**）：

```powershell
scripts\run_coremark.ps1 -Iter 2000 -SkipSim  # 跑分用：62.03MHz 下约 11.7 秒，满足 ≥10s
scripts\run_demo.ps1 -SkipSim                 # 演示用
scripts\sync_firmware.ps1                     # 必须！同步到 PDS 工程目录
```

然后回 PDS 重新 compile → … → bitstream。

> `-SkipSim` = 只生成固件、不跑仿真。**上板流程只需要 `mem.hex`**，加上这个开关
> 从十几分钟降到几秒。想去掉它跑完整仿真（核实 CoreMark 数值）也可以，要跑十几分钟。
>
> **ITER 的分子是你往哪儿烧的那个时钟，改流水线或换平台都要重算。**
> 当前设计每迭代 **363,515** 周期（与时钟无关；两拍乘法器之前是 354,119）：
> * **板上 62.0309 MHz：ITER=2000 → 11.72 秒**（余量 17%）
> * 仿真 / 远程平台 27 MHz：`270,000,000 ÷ 363,515 ≈ 743`；27 MHz 时代用的是 **ITER=820**
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
> 核对：`mem.hex` 字数应与 ELF 的 `.text` 规模相当 —— CoreMark 固件 = **4209 字**。

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
│   └── top/cpu_top_board.v [重点] 上板顶层（PDS 的 top）：PLL 27→62.03MHz + 裁剪调试端口 + HDMI
│
├── pds/RV32I_1/ [重点] PDS 工程（源文件指向 ../../rtl/**）
│   ├── RV32I_1.pds          工程文件
│   ├── RV32I_1.fdc          引脚/时钟约束（只有 27MHz 输入晶振；62.03MHz 由 PLL IP 推导）
│   ├── ipcore/pll/          Pango PLL IP（27MHz→62.03MHz），必须以 IP 源形式引用
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

##  可选：命令行仿真与回归

改 RTL 后建议跑一遍，比上板快得多：

```powershell
scripts\run_riscv_tests.ps1     # 49 PASS / 1 FAIL / 0 TIMEOUT（不需联网）
scripts\run_sim.ps1             # 6 个模块单元测试
scripts\run_coremark.ps1 -Iter 1
scripts\run_demo.ps1            # 演示程序端到端 7/7 PASS
```

**回归纪律**：改动 RTL 后，下面两条必须同时保持不变（除非本次改动就是要改变某一项）：

1. riscv-tests 的 **49/1/0**
2. CoreMark 计时区间 **363,515 拍**（测试台总周期 1,467,276）← "没碰坏流水线"最灵敏的探针
   （历史基线：358,846 / 1,462,898 → 382,972 → 420,070）

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

---

##  Git 协作

```powershell
git pull origin main                    # 开始工作前
git add .
git commit -m "feat: 描述你做了什么"
git push origin main
```

提交信息前缀：`feat:` 新功能 · `fix:` 修复 · `docs:` 文档 · `refactor:` 重构

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

**Q：烧录提示"设备唤醒失败"？**
A：远程平台偶发问题，**多烧录几次即可**，不是设计问题。

**Q：改了 RTL，板上行为没变？**
A：PDS 里的 compile 是不是没重跑？另外确认 PDS 打开的是 `pds/RV32I_1/` 而不是旧副本。

**Q：板子跑起来了，但输出的是**上一次**的程序（比如 demo），不是刚编的那个？**
A：**`pds/RV32I_1/mem.hex` 过期了。** PDS 综合读的是工程目录里那一份，不看时间戳，
也**不会**自动从 `sim/programs/` 取新固件。重跑 `scripts\sync_firmware.ps1` 再综合。
排查方法：对 `mem.hex` 的字数 —— CoreMark 固件 **4209 字**，demo 只有 **101 字**，
riscv-test 约 **431 字**；数字对不上就是拿错镜像了。
