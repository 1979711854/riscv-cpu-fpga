# 上板教程（本地盘古 MES2L676-200HP）

> 面向：第一次给这块板上电跑程序的人（队友 / 未来的会话）。
> 目标板：**盘古 MES2L676-200HP**，核心板 `PG2L200H-6IFBB676`（与远程 FPGA 平台同型号器件）。
> 工具：Pango Design Suite 2022.2-SP6.4（**不是** Vivado）。
>
> 首次跑通记录与实测数据见 `doc/board/README.md`；引脚出处见 `pds/RV32I_1/RV32I_1.fdc` 头部注释。

---

## 1. 接线：这块板要插**两根** USB 线

板上 `Jtag` 和 `USB UART` 是**两个独立接口**（《MES2L676-200HP硬件使用手册》1.2.1 板载资源表）：

| 接口 | 芯片 | 插上后设备管理器出现 | 用途 |
|---|---|---|---|
| **Jtag ×1** | FTDI（双通道） | **两个** `USB Serial Port (COMxx)` | 烧比特流（PDS Programmer） |
| **USB UART ×1** | **CP2102** + USB Type-C | **一个** `Silicon Labs CP210x USB to UART Bridge (COMxx)` | 看 CPU 的串口输出 |

[!] **只插 Jtag 那根，串口是不会有任何输出的** —— 这是最容易卡住的一步。

用一下命令认哪个是真串口：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1
```

不带 `-Port` 时会列出全部串口。想进一步确认设备名：

```powershell
powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object { \$_.Name -match '\(COM' } | Select-Object Name | Sort-Object Name"
```

**认准 `Silicon Labs CP210x` 那个口**（FTDI 的那些是 JTAG 通道，读它们永远没输出）。

---

## 2. 引脚表（`.fdc` 里生效的约束）

### 时钟：板载 27 MHz 经 PLL 倍频到 **49.89 MHz**（2026-09-25 起）

系统时钟不是晶振直连，而是走 PLL：

```
clk(D18, 27MHz 晶振) ──> pll IP ──> clk_sys(49.89MHz) ──> cpu_top
                          └─> lock ──> 门控 resetn（锁定前一直复位 CPU）
```

* `.fdc` 里只有输入晶振的 `create_clock ... -period 37.037`（27 MHz），**这句别改**。
  PLL 输出的约束由 **PDS 从 PLL IP 自动推导**，只在时序报告里显示
  （当前 `clk 49.8927 MHz，可达 54.0745 MHz`）。**别以为约束没生效。**
* PLL 是 Pango IP，在工程里以 `wgt_my_ips_src` 引用（`ipcore/pll/`）。
  **不能只把 `pll.v` 当普通源文件加进去** —— 那样综合会报 `pll` 是黑盒。
* **由此产生的连带改动**：UART 分频 **433**（`cpu_top_board` 传 `UART_DIV`）、
  CoreMark 的 `EE_TICKS_PER_SEC = 49892700`、`addr_map.h` 的 `CPU_HZ = 49892700u`。
* [!] **仿真仍然是 27 MHz**（测试台例化 `cpu_top`，不传参数 → 分频 234）。
  所以：**仿真 27 MHz / 上板 49.89 MHz**，两套口径别混。
  远程 FPGA 平台**没有 PLL，也是 27 MHz**。

| 信号 | 管脚 | 板上丝印 | 说明 |
|---|---|---|---|
| `clk` | **D18** | 27MHz 晶振（U11） | 手册 2.2.3 `FPGA_GCLK_27M` |
| `resetn` | **C22** | **SW3**（最左） | 按键低有效；本板**无独立复位引脚**，用按键兼作 |
| `uart_tx` | **C24** | USB-UART TXD | 经 CP2102 |
| `uart_rx` | **B24** | USB-UART RXD | 经 CP2102 |
| `led[0]` | C19 | D19 | 输出高电平点亮 |
| `led[1]` | C18 | D18 | |
| `led[2]` | E18 | D13 | |
| `led[3]` | A17 | D14 | |
| `led[4]` | A20 | D17 | |
| `led[5..7]` | A18 / C17 / B17 | D15 / D16 / D12 | |
| `key[0]` | **C23** | SW4 | 按下 = 0 |
| `key[1]` | **B22** | SW5 | |
| `key[2]` | **A22** | SW6 | |
| `key[3]` | **B20** | SW7 | |

**两条容易搞错的对应关系**：

1. **手册 0 起编号、板上丝印 1 起编号**：手册 `KEY0..KEY4` = 丝印 `SW3..SW7`。
2. **`led[]` 已按"开关正下方"重排**（不按手册 `LED0..LED7` 顺序）。原因：板上 LED 的
   引脚是按布线就近分配的，丝印 `D12..D19` 相对开关是乱序的，直接用手册顺序会出现
   "按某个开关、亮隔壁那个灯"。重排后：**按 SW4 → 正下方 D19 亮**，以此类推。
   详见 `.fdc` 头部"LED 重排"一节。

---

## 3. 生成要烧的比特流：**一条命令**

[!] **仓库里没有任何 `.sbit` 文件**（被 `.gitignore` 排除，每个 9 MB）。
**队友 clone 下来必须自己生成一次**，不存在"现成可烧"的比特流。

```powershell
scripts\build_bitstream.ps1 coremark    # 跑分版（ITER=1663，板上约 11.8 s）
scripts\build_bitstream.ps1 demo        # 演示程序版（读按键 → 写 LED → 串口打印）
```

脚本做三件事：生成固件 → 同步进 PDS 工程并**校验 `mem.hex` 字数** → 综合布线出比特流。
约 5 分钟，产物固定是：

```
pds\RV32I_1\generate_bitstream\cpu_top_board.sbit
```

然后烧它：

```
PDS → TOOL → Programmer（下载）
  器件：PG2L200H
  配置文件：<上面那个路径>
```

### [!] 为什么必须用脚本，而不是"直接烧 generate_bitstream 里现成的"

**那个文件名看不出里面是哪个固件** —— 它只代表「最后一次综合的那版」。

> **2026-09-23 实踩**：想烧 CoreMark 跑分版，在 Programmer 里**只点了 Program、
> 没重新浏览文件**（它沿用了上次的路径 `generate_bitstream\cpu_top_board.sbit`），
> 而那份是上一版的**演示程序**。现象：烧完按按键有反应，串口打印 `KEY=0x.. LED=0x..`，
> 完全没有跑分输出。文件名叫 `cpu_top_board` 看着像"当前设计"，**完全看不出来是哪个固件**。

还有一个更隐蔽的：**PDS 不检查 `mem.hex` 的时间戳**。固件没同步过去（或同步的是别的程序），
它照样综合出一个"能烧、但板上跑的是旧程序"的比特流，全程零报错。
`build_bitstream.ps1` 里那道 `mem.hex` 字数校验就是挡这个的。

### 想自己一步步来？

```powershell
# ① 生成固件（二选一）
scripts\run_coremark.ps1 -Iter 1500 -SkipSim     # 跑分版
scripts\run_demo.ps1 -SkipSim                    # 演示程序版

# ② 同步进 PDS 工程目录（PDS 读的是 pds\RV32I_1\mem.hex，不是 sim\programs\mem.hex）
scripts\sync_firmware.ps1
# 校验：CoreMark = 8418 行（4209 字）；演示程序 = 326 行（163 字）

# ③ 综合布线出比特流（约 5 分钟）
cd pds\RV32I_1
D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe -project RV32I_1.pds -run gen_bit_stream
```

也可以在 PDS GUI 里逐个点 Compile / Synthesize / Device Map / Place & Route / Generate Bitstream。

### `DEBUG_LED`：`led[1:0]` 是调试信号还是 GPIO

`cpu_top_board` 有个参数开关（`rtl/top/cpu_top_board.v`）：

| 值 | `led[1:0]` | `led[7:2]` | 用途 |
|---|---|---|---|
| **1（默认）** | `led[0]=pll_locked`、`led[1]=done` | GPIO | 上板调试 —— 一眼看出 PLL 锁没锁、程序跑完没 |
| 0 | GPIO | GPIO | 现场演示 —— 恢复"按开关位置重排"的 LED=KEY 映射 |

> **`led[0]` 是排障利器**：灯亮 = PLL 锁定成功；**不亮 = PLL 没锁，CPU 被一直复位**
> （那时串口必然是死的）。`led[1]` 亮 = CoreMark 已写 0x7FF8 收尾。

[!] **PDS 综合取的是参数默认值，命令行传不了 `-D` 宏**，所以切换必须改参数再重新综合：

* 用 `build_bitstream.ps1` 时**脚本会自动设置**（coremark→1、demo→0），综合完还原源文件，
  不用管；
* 手工在 GUI 里综合时，**要自己把 `parameter DEBUG_LED = 1` 改成 `0`**（反之亦然），
  综合完记得改回来。

> 注意 `DEBUG_LED=1` 时演示程序也有影响：`led[1:0]` 不再跟随开关，演示录像前记得用 `demo` 变体。

**什么时候必须重新生成**：改了 `rtl/**`、改了 `RV32I_1.fdc`、或者换了固件（跑分 ↔ 演示）。

**几个关于 PDS 命令行的实测事实**：

* `pds_shell -project X.pds -run <action>` 可用的 action：`compile` `synthesize` `dev_map`
  `pnr` `report_timing` `gen_bit_stream`。
* **每个 `-run` 都会把前面的步骤重跑一遍** —— 所以 `-run gen_bit_stream` 实际会跑完整条链，
  约 5 分钟，不是 1 分钟。
* `-file <tcl>` 与 `-project` **不能同时用**（会报 `Only one of '-file' or '-project' can be specified`）。
* **PDS 每次 `gen_bit_stream` 都会先清空 `generate_bitstream/`**，上一版被挪进 `bak/`。

---

### 烧完立刻开串口

```powershell
# CoreMark 一轮约 12 秒，慢一拍就错过了，所以要带时长
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60

# 演示程序可以一直挂着，Ctrl+C 停
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4
```

> **提交比赛作品时**：`.sbit` 走 git 进不了仓库（被 gitignore），要作为**离线交付物**
> 单独打包 —— 用 `build_bitstream.ps1` 生成一份干净的、记下它的 md5。

---

## 4. 上电后该看到什么

### 演示程序版

串口（115200 8N1）反复打印：

```
KEY=0x00 LED=0x00
```

按开关（一个一按，松开再按下一个）：

| 操作 | 期望 |
|---|---|
| 按 **SW4** | `KEY=0x01 LED=0x01`，**正下方 D19 亮** |
| 按 **SW5** | `KEY=0x02 LED=0x02`，**正下方 D18 亮** |
| 按 **SW6** | `KEY=0x04 LED=0x04`，**正下方 D13 亮** |
| 按 **SW7** | `KEY=0x08 LED=0x08`，**正下方 D14 亮** |
| 按 **SW3** | 复位，重新打印 `RV32I SoC demo ready` |

### CoreMark 版

**约 12 秒后**打印。

**当前设计（49.8927 MHz / ITER=1663）的板上实测原始输出**
（日志 `doc/board/uart_20260925_172318.txt`，2026-09-25 17:23）：

```
CoreMark Size    : 666
Total ticks      : 588890651
Total time (secs): 11
Iterations/Sec   : 151
Iterations       : 1663
Compiler flags   : -O2 -march=rv32im -mabi=ilp32
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
Correct operation validated.
```

实测：588,890,651 ÷ 49,892,700 = **11.8031 s** → **140.89 CoreMark**（满足赛题 ≥10 s）。
推算值 588,900,000 / 140.89 与实测**分毫不差**。

**45 MHz 版（ITER=1500）的板上实测原始输出**（已确认，留作对照，
日志 `doc/board/uart_20260925_005201.txt`）：

```
Total ticks      : 538285445
Iterations       : 1500
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
Correct operation validated.
```
实测 538,285,445 ÷ 45,000,000 = **11.9619 s** → **125.40 CoreMark**。

[!] **`Total time (secs)` 和 `Iterations/Sec` 是整数截断打印的**（`HAS_FLOAT=0`）：
45 MHz 那次显示 `11`（实际 11.9619）、`136`（= 1500 ÷ 11 的截断值，**真实 125.40**）。
**真实时长一定要自己算：**

```
板上时长 = Total ticks ÷ 49,892,700      <- 当前板上时钟
```

> 历史口径：`÷27e6`（27 MHz 时代）、`÷45e6`（45 MHz 时代）。
> **一律以 PDS 时序报告里 `Requested Frequency` 的实际值为准**，不要用标称值。

`seedcrc / crclist / crcmatrix / crcstate`（`0xe9f5 / 0xe714 / 0x1fd7 / 0x8e3a`）
与仿真逐位一致 —— 这是"CPU 真机算得对"的判据，**换时钟、换 ITER 都不该改变它们**。

[!] **`crcfinal` 不能拿来比对** —— 它跨迭代累加、**随 ITER 变**：
ITER=1 → `0xe714`、820 → `0xbd59`、1500 → `0x25b5`，**三个都正确**。

---

## 5. 排障速查

| 现象 | 最可能原因 |
|---|---|
| **串口乱码** | 时钟不是 49.89 MHz（波特率是按时钟分频的）—— 这是判断时钟最快的方法。先看 `led[0]`（`pll_locked`）亮不亮。**也可能是固件是 27 MHz 那版**（`EE_TICKS_PER_SEC`/`UART_DIV` 口径不对） |
| **串口完全没输出 + `led[0]` 不亮** | **PLL 没锁定** → CPU 一直被 `sys_resetn` 复位。检查 `ipcore/pll/` 是否在工程里、`pll.v` 是否经 IP 源引用（§6 第 5 条） |
| 完全没输出（`led[0]` 亮） | ① 板子没配置（掉电/拔过 USB → 重烧）② 只插了 Jtag 没插 USB-UART ③ 读错 COM 口（读成 FTDI 那个）④ UART 引脚 |
| 串口正常但按键没反应 | `key[]` 引脚（C23/B22/A22/B20） |
| 灯不亮 / 恒亮 | LED 引脚或极性（本板**输出高电平点亮**） |
| 按键→LED 关系不对 | ① `DEBUG_LED` 是不是 1（那样 `led[1:0]` 被 `pll_locked`/`done` 占了，见 §3）② `led[]` 是否被改回手册顺序（见 §2 第 2 条） |
| **`Iterations/Sec` 显示 136** | **正常，不是错误** —— 它是 `Iterations ÷ Total time(secs)` 用**截断后**的 11 算的（1500 ÷ 11 ≈ 136）。**真实得分是 125.40 CoreMark**（= 1500 ÷ 11.9619）。见 §4 的说明 |
| 烧录后设备唤醒失败 | 远程平台那套"多烧几次就好"的经验**不适用本地板** —— 出现就是真问题 |

**FPGA 掉配置的判据**：按键完全没反应 + 串口没输出。板子断电或拔过 USB 就会这样（比特流是烧进 SRAM 的）。
**不用重烧的情况**：只要没断电、没重生成比特流，按一下复位键（SW3）就能让程序从头再跑一轮。

---

## 6. 已知的坑（都踩过）

1. **PDS 不检查 `mem.hex` 的时间戳**。跑过 `run_riscv_tests.ps1` 或 `run_demo.ps1` 之后再
   `sync_firmware.ps1`，工程里就留下别的程序的镜像；此后无论怎么改 RTL、重新综合，
   **板上跑的都还是那个旧程序，而 PDS 全程零报错**。
   判据：核对 `pds\RV32I_1\mem.hex` 的字数与预期是否相当（CoreMark = 4209 字，演示程序 = 163 字）。
2. **上板的 top module 是 `cpu_top_board`，不是 `cpu_top`** —— 前者把 `pc[31:0]` / `done`
   挡在外面。原因见 §7。
3. **`.fic` 与 `.sbit` 必须来自同一次综合布线**（做 ILA 时）。RTL 一变，旧 `.fic` 就作废。
4. **未在 `.fdc` 里指定 LOC 的输出端口会被 PDS 自动布到 BANKR5 的任意引脚**上
   （实测 `pc[0]→M2`）。BANKR5 接的是 SFP/HSST，所以上板顶层不引出这类端口。
5. **PLL IP 必须以"IP 源文件"的形式加进工程** —— `.pds` 里要有
   `wgt_my_ips_src` 下的 `(_ip "ipcore/pll/pll.idf")` + `(_ip_source_item "ipcore/pll/pll.v")`。
   只把 `pll.v` 当普通 Verilog 源文件添加，综合会报 `pll` 是黑盒。
   队友 clone 后若工程里缺这条，从 `pds/RV32I_1/ipcore/pll/` 补齐 `.idf` 与 `.v` 两个文件。
   （`.pds` 已入库并带着这条引用，正常不会缺。）
6. **`.fdc` 里看不到 49.89 MHz 是正常的**，别去"修" —— 见 §2 的时钟说明。

---

## 7. 为什么有 `cpu_top_board` 这一层

`rtl/top/cpu_top_board.v` 做三件事：

1. **包住 `cpu_top`，不引出 `pc[31:0]` 和 `done`**，并把 `key[7:4]` 恒定接 1；
2. **例化 PLL**（27 MHz → 49.89 MHz），并用 `lock` 门控 `resetn`；
3. **按 `DEBUG_LED` 决定 `led[1:0]` 的归属**（见 §3）。

* **为什么不在 `cpu_top` 里直接删端口**：`pc` 是**仿真侧的分析数据源** ——
  `tb_coremark` 的 `+TRACE`/`+PROF` 逐拍 dump 和各测试台的 TIMEOUT 诊断
  （`$display("TIMEOUT (pc=0x%h)", pc)`）都依赖它。删掉会废掉
  `doc/ila_analysis.md` 里那套分析方法。
* **为什么 PLL 不放进 `cpu_top`**：仿真测试台例化的是 `cpu_top`，
  放进去就得在仿真里也跑 PLL（Pango 原语仿真模型、锁定延时……纯属负担）。
  挡在板级这一层，**仿真就天然是 27 MHz，上板才是 49.89 MHz**。
* **为什么要挡在外层**：见 §6 第 4 条。

所以：**仿真继续用 `cpu_top`（27 MHz），上板用 `cpu_top_board`（49.89 MHz）**。
除时钟与端口裁剪外，两者行为完全一致。
