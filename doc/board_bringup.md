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

### 时钟：板载 27 MHz 经 PLL 倍频到 **85.01 MHz**（2026-10-04 起）

系统时钟不是晶振直连，而是走 PLL：

```
clk(D18, 27MHz 晶振) ──> pll IP ──> clk_sys(85.01MHz) ──> cpu_top
                          └─> lock ──> 门控 resetn（锁定前一直复位 CPU）
```

> [!] **先说清楚 85 是怎么定的 —— 别再用"Estimated Frequency 是设计上限"那套推理。**
> PDS 的 P&R 是**满足约束即收敛**：约束给多高，它就优化到多高就停手。
> 2026-10-04 用同一份 RTL、只改 `STATIC_RATIO0` 实测：
>
> | 请求频率 | 实际达到 | CPU 域 Slack |
> |---|---|---|
> | 62.03 MHz | 66.87 MHz | +1.167（**旧设计，被自己卡住**）|
> | 71.72 MHz | 73.26 MHz | +0.293 |
> | **85.01 MHz** | **91.87 MHz** | **+0.879** ← 本次采用 |
> | 99.79 MHz | 89.21 MHz | −1.188（失败，282 端点）|
>
> **真实上限 ≈90 MHz**；取 85 是留 ~7% 余量，与旧设计 62.03/66.87 的 7.8% 同一风险档。
>
> [!] 上表是**探针运行**（只跑到 `report_timing`）的数字。**单发射**正式构建
> （coremark 与 gomoku，走完整 P&R 并出 `.sbit`）实测为
> `Requested 85.0051 / Estimated **91.3993 MHz** / Slack **+0.823 ns**，CPU 域失败端点 0`
> （归档位流 md5 `ae4deea9` / `f4e78dc6` 出自同一网表）。
> **双发射**（2026-10-06 起，当前）同一约束下为
> `Requested 85.0051 / Estimated **87.0019 MHz** / Slack **+0.270 ns**，CPU 域失败端点 0`
> （位流 md5 `5c4893de` / `3976aebd`）—— Fmax 比单发射低 4.8%、余量只剩 2.3%，是换效率的代价。
> **引用时序余量时按配置取对应那一组数字**（与探针都同档，差 <1%）。

* `.fdc` 里只有输入晶振的 `create_clock ... -period 37.037`（27 MHz），**这句别改**。
  PLL 输出的约束由 **PDS 从 PLL IP 自动推导**，只在时序报告里显示
  （当前 `clk 85.0051 MHz`）。**别以为约束没生效。**
* PLL 是 Pango IP，在工程里以 `wgt_my_ips_src` 引用（`ipcore/pll/`）。
  **不能只把 `pll.v` 当普通源文件加进去** —— 那样综合会报 `pll` 是黑盒。
* **由此产生的连带改动**：UART 分频 **738**（`cpu_top_board` 传 `UART_DIV`）、
  CoreMark 的 `EE_TICKS_PER_SEC = 85005100`、`addr_map.h` 的 `CPU_HZ = 85005100u`、
  rtthread 的 `BOARD_SYSTEM_CLOCK_HZ = 85005100u`，外加 CoreMark 的 ITER 重算。
* [!] **仿真仍然是 27 MHz**（测试台例化 `cpu_top`，不传参数 → 分频 234）。
  所以：**仿真 27 MHz / 上板 85.01 MHz**，两套口径别混。
  远程 FPGA 平台**没有 PLL，也是 27 MHz**。
* **降频的出路**（若板上不稳 / 要开 I+D Cache）：改 `ipcore/pll/pll.idf` 的 `STATIC_RATIO0` 再跑
  `ip_generate.exe -i pll.idf`，然后同步上面 4 处常量重算 ITER。
  `CLKOUT0 = 1147.5 ÷ STATIC_RATIO0`：`16.0 → 71.72`、**`15.0 → 76.5052`（I+D Cache 用的档）**、
  `14.5 → 79.14`、**`13.5 → 85.0051`（当前跑分档）**。
  > [!] **I+D Cache 全开在 85 MHz 塞不进**（CPU 域 −1.143 ns / 343 失败端点）⇒ 必须降频；
  > 76.5052 MHz 收敛（setup +0.589 / hold +0.147 / 0 端点），板上实测 313.63 分（**A1 前口径**）。
  > **改完频率必须全部还原**（见 `CLAUDE.md` 约定 50）。

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
scripts\build_bitstream.ps1 coremark            # 跑分版（双发射+EARLY_LD，ITER=4280，板上约 11.7 s）
scripts\build_bitstream.ps1 coremark -DCacheOnly # 同上 + 只开 D-Cache（**推荐提交档**：分数不变）
scripts\build_bitstream.ps1 demo        # 演示程序版（读按键 → 写 LED → 串口打印）
scripts\build_bitstream.ps1 rtthread    # RT-Thread Nano 版（banner + 两个线程交替打印）
scripts\build_bitstream.ps1 video       # HDMI 彩条版（填显存画 8 条竖条 + 串口读回自检）
# 任一变体加 -Single 出【单发射】回退版位流（期望值按 DUAL_ISSUE 自动算）
```

脚本做三件事：生成固件 → 同步进 PDS 工程并**校验 `mem.hex` 字数** → 综合布线出比特流。
约 5 分钟，产物固定是：

```
pds\RV32I_1\generate_bitstream\cpu_top_board.sbit
```

然后烧它。

**Programmer = Pango 的「Fabric Configuration」工具**（`bin\cdt_cfg.exe`），
PDS 里 **TOOL → Programmer** 打开的就是它。**烧录是三步，不是一步**：

```
1) Operations → Scan Device          扫描 JTAG 链，认出 PG2L200H
2) Operations → Assign New Configuration File   ← 这一步就是"Browse"
     选中要烧的 .sbit
3) Operations → Program...            真正烧写
```

> [!] **第 2 步每次都要重做，这就是"要重新 Browse"的意思。**
> Fabric Configuration **会把上次分配的那份文件记在器件节点上**，而且是在
> **分配时**读进内存的，不是烧写时现读。所以如果你只点第 3 步 `Program...`，
> 烧的是**上次分配的那份**，跟你刚生成的那份无关。
>
> 换句话说：**改了比特流之后，"Scan Device + Program" 是不够的，中间那次
> `Assign New Configuration File` 不能省。**
>
> **2026-09-23 实踩**：想烧 CoreMark 跑分版，只点了 Program、没重新分配文件，
> 结果烧成了上一版的**演示程序**。现象：烧完按按键有反应，串口打印
> `KEY=0x.. LED=0x..`，完全没有跑分输出。文件名都叫 `cpu_top_board`，
> 看着像"当前设计"，**完全看不出来是哪个固件**。

### 根治办法：把烧录录成 TCL 脚本

Fabric Configuration **自带操作录制与 TCL 执行**（官方手册《Fabric Configuration
User Guide》第 4 章）：

| 界面操作 | 对应 TCL 命令 |
|---|---|
| Scan Device | `cfg_add_device` |
| **Assign New Configuration File** | **`cfg_assign_file`** |
| **Program...** | **`cfg_program`** |
| Verify / Erase / Readback | `cfg_verify` / `cfg_flash_erase` / `cfg_readback` |

**用法**：

1. 先在 GUI 里正常烧一次，同时用 **`Operations → Create Tcl Record File...`**
   把操作录下来 —— 它会生成一个 `.tcl`，**并把比特流复制到它旁边的
   `tcl_bit_file\` 目录**，所以录出来的脚本可以整体搬走，路径不会失效。
2. 此后每次烧板，只要 **`Operations → Execute Tcl File...`** 选那个 `.tcl` 就行 ——
   文件路径写在脚本里，**不可能再烧错版本**。

> 这也是个无头路径：`bin\cdt_cfg_shell.exe` 能直接跑 tcl
> （`-file <目录|*.tcl>`，`-args {参数}` 可做参数替换，手册 §4）。
> 想做成 `scripts\flash.ps1` 一条命令烧板的话，先录一份 `.tcl` 出来做底子。

** [OK] 已经写好了：`scripts\flash.tcl`**（2026-10-13，语法取自官方
《Fabric Configuration User Guide》§4.5.1/§4.5.2/§4.6，不必再自己录一份）。

```powershell
# ① 先起 JTAG Server（不连的话 cdt_cfg_shell 报 "the connection is disconnected"）
Start-Process "D:\pango\PDS_2022.2-SP6.4\bin\cdt_js.exe" -ArgumentList "-port","65420"

# ② 再烧（把路径换成要烧的那份 .sbit，正斜杠）
& "D:\pango\PDS_2022.2-SP6.4\bin\cdt_cfg_shell.exe" -file scripts\flash.tcl `
    -args { D:/riscv-cpu-fpga_merged/pds/RV32I_1/generate_bitstream/cpu_top_board.sbit }
```

脚本干的事：`cfg_connect`（连 65420）→ `cfg_scan_chain` → `cfg_add_device -file <sbit>`
→ **`cfg_assign_file -file <sbit>`** → `cfg_program` → `cfg_verify` → `cfg_disconnect`。

> [!] **`cfg_program` 不带文件参数** —— 它烧的是 `cfg_assign_file` 刚分配的那份。
> 所以那条 `cfg_assign_file` 就是 GUI 里的"重新 Browse"，**不能省**（省了就烧上一版）。

还有一个更隐蔽的：**PDS 不检查 `mem.hex` 的时间戳**。固件没同步过去（或同步的是别的程序），
它照样综合出一个"能烧、但板上跑的是旧程序"的比特流，全程零报错。
`build_bitstream.ps1` 里那道 `mem.hex` 字数校验就是挡这个的。

### 想自己一步步来？

```powershell
# ① 生成固件（二选一）
scripts\run_coremark.ps1 -Iter 4280 -SkipSim     # 跑分版（双发射+EARLY_LD，85.0051 MHz 的取值）
scripts\run_demo.ps1 -SkipSim                    # 演示程序版

# ② 同步进 PDS 工程目录（PDS 读的是 pds\RV32I_1\mem.hex，不是 sim\programs\mem.hex）
scripts\sync_firmware.ps1
# 校验：CoreMark = 17,104 行（8,552 字）；演示程序 = 326 行（163 字）

# ③ 综合布线出比特流（约 5 分钟）
cd pds\RV32I_1
D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe -project RV32I_1.pds -run gen_bit_stream
```

也可以在 PDS GUI 里逐个点 Compile / Synthesize / Device Map / Place & Route / Generate Bitstream。

### `DEBUG_LED`：`led[1:0]` 是调试信号还是 GPIO

`cpu_top_board` 有个参数开关（`rtl/top/cpu_top_board.v`）：

| 值 | `led[2:0]` | `led[7:3]` | 用途 |
|---|---|---|---|
| **1（默认）** | `led[0]=pll_locked`、`led[1]=video_locked`、`led[2]=done` | GPIO | 上板调试 —— 一眼看出两个 PLL 锁没锁、程序跑完没 |
| 0 | GPIO | GPIO | 现场演示 —— 恢复"按开关位置重排"的 LED=KEY 映射 |

> [!] **`led[1]` 是 `video_locked`、`done` 在 `led[2]`** —— 视频并入后 `done` 往后挪了一位
> （见 `rtl/top/cpu_top_board.v` 的 `generate` 块）。旧文档写的是 `led[1]=done`，已过时。

> **`led[0]` 是排障利器**：灯亮 = CPU PLL 锁定成功；**不亮 = PLL 没锁，CPU 被一直复位**
> （那时串口必然是死的）。`led[1]` 亮 = **视频 PLL 已锁定**，HDMI 黑屏先看这一颗。
> `led[2]` 亮 = CoreMark 已写 0x7FF8 收尾。

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

**A1 前跑分档（85.0051 MHz，双发射 + 任务C `EARLY_LD`，ITER=4116）的板上实测原始输出**（A1 后 ITER=4280、每迭代 232,345 拍 ⇒ [OK] 已板上实测 **365.93 分**，日志 `doc/board/uart_20261013_184111.txt`）
（日志 `doc/board/uart_20261012_002541.txt`，2026-10-12；只开 D-Cache 的 `2f7a4d0a` 分数完全相同）：

```
CoreMark Size    : 666
Total ticks      : 994386960
Total time (secs): 11
Iterations/Sec   : 374      ← 整数截断，不是得分（见下）
Iterations       : 4116
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
Correct operation validated.
```

实测：994,386,960 ÷ 85,005,100 = **11.69797 s** → **351.86 CoreMark**（满足赛题 ≥10 s；**A1 前板上值**，A1 后已板上实测 **365.93 分**，见 `uart_20261013_184111.txt`）。

**I+D Cache 版（76.5052 MHz，ITER=3668；A1 前口径）**（日志 `doc/board/uart_20261012_155934.txt`）：
首行 `[build] FW=COREMARK RTL=0x20261016`，`Total ticks 894,745,801` →
**11.6952 s → 313.63 CoreMark**；`[cache] I` 98.985% / `[cache] D` 99.929%。

**历史（单发射 85.0051 MHz / ITER=2740）**：`Total ticks 996,015,474` ÷ 85,005,100 =
**11.7171 s / 233.85 CoreMark**（日志 `doc/board/uart_20261004_114730.txt`）。

**45 MHz 版（ITER=1500）的板上实测原始输出（历史，留作对照）**（已确认，
日志 `doc/board/uart_20260925_005201.txt`）：

```
Total ticks      : 538285445
Iterations       : 1500
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
Correct operation validated.
```
实测 538,285,445 ÷ 45,000,000 = **11.9619 s** → **125.40 CoreMark**。

[!] **`Total time (secs)` 和 `Iterations/Sec` 是整数截断打印的**（`HAS_FLOAT=0`）：
当前这版（A1 前跑分档 4116）显示 `11`（实际 11.69797）、`374`（= 4116 ÷ 11 的截断值，**真实 351.86**，A1 前板上值；A1 后用 ITER=4280 ⇒ 显示 `4280 ÷ 11 ≈ 389`、**真实 365.93**）；
**历史**纯双发射 3170 那版显示 `11`（实际 11.7050）、`270`（**真实 270.82**）；
历史单发射 85 MHz 那次显示 `11`（实际 11.7171）、`249`（**真实 233.85**）。
**真实时长一定要自己算：**

```
板上时长 = Total ticks ÷ 85,005,100      <- 当前板上时钟
```

> 历史口径：`÷62,030,900`（62.03 MHz）、`÷49,892,700`（49.89 MHz）、`÷45e6`（45 MHz）、`÷27e6`（27 MHz）。
> **一律以 PDS 时序报告里 `Requested Frequency` 的实际值为准**，不要用标称值。

`seedcrc / crclist / crcmatrix / crcstate`（`0xe9f5 / 0xe714 / 0x1fd7 / 0x8e3a`）
与仿真逐位一致 —— 这是"CPU 真机算得对"的判据，**换时钟、换 ITER 都不该改变它们**。

[!] **`crcfinal` 不能拿来比对** —— 它跨迭代累加、**随 ITER 变**：
ITER=1 → `0xe714`、820 → `0xbd59`、1500 → `0x25b5`、1663 → `0x81c9`，**四个都正确**。

---

## 5. 排障速查

| 现象 | 最可能原因 |
|---|---|
| **串口乱码** | 时钟不是 85.0051 MHz（波特率是按时钟分频的）—— 这是判断时钟最快的方法。先看 `led[0]`（`pll_locked`）亮不亮。**也可能是固件是别的时钟口径那版**（`EE_TICKS_PER_SEC`/`UART_DIV` 不对） |
| **串口完全没输出 + `led[0]` 不亮** | **PLL 没锁定** → CPU 一直被 `sys_resetn` 复位。检查 `ipcore/pll/` 是否在工程里、`pll.v` 是否经 IP 源引用（§6 第 5 条） |
| 完全没输出（`led[0]` 亮） | ① 板子没配置（掉电/拔过 USB → 重烧）② 只插了 Jtag 没插 USB-UART ③ 读错 COM 口（读成 FTDI 那个）④ UART 引脚 |
| 串口正常但按键没反应 | `key[]` 引脚（C23/B22/A22/B20） |
| 灯不亮 / 恒亮 | LED 引脚或极性（本板**输出高电平点亮**） |
| 按键→LED 关系不对 | ① `DEBUG_LED` 是不是 1（那样 `led[2:0]` 被 `pll_locked`/`video_locked`/`done` 占了，见 §3）② `led[]` 是否被改回手册顺序（见 §2 第 2 条） |
| **`Iterations/Sec` 显示 374 / 333** | **正常，不是错误** —— 它是 `Iterations ÷ Total time(secs)` 用**截断后**的整数秒算的（4116 ÷ 11 ≈ 374；I+D 版 3668 ÷ 11 ≈ 333）。**真实得分要自己算**：85 MHz 跑分档 = `4116 ÷ 11.69797` = **351.86**（A1 前）；**A1 后**用 ITER=4280，显示值 ≈ `4280 ÷ 11` = 389、**真实 365.93**；I+D 版 = `3668 ÷ 11.6952` = **313.63**。历史：双发射 3170 显示 `270` / 真实 270.82；单发射 85 MHz 显示 `249` / 真实 233.85。见 §4 的说明 |
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
6. **`.fdc` 里看不到 85.0051 MHz 是正常的**，别去"修" —— 见 §2 的时钟说明。

---

## 7. 为什么有 `cpu_top_board` 这一层

`rtl/top/cpu_top_board.v` 做三件事：

1. **包住 `cpu_top`，不引出 `pc[31:0]` 和 `done`**，并把 `key[7:4]` 恒定接 1；
2. **例化 PLL**（27 MHz → 85.0051 MHz），并用 `lock` 门控 `resetn`；
3. **按 `DEBUG_LED` 决定 `led[1:0]` 的归属**（见 §3）。

* **为什么不在 `cpu_top` 里直接删端口**：`pc` 是**仿真侧的分析数据源** ——
  `tb_coremark` 的 `+TRACE`/`+PROF` 逐拍 dump 和各测试台的 TIMEOUT 诊断
  （`$display("TIMEOUT (pc=0x%h)", pc)`）都依赖它。删掉会废掉
  `doc/ila_analysis.md` 里那套分析方法。
* **为什么 PLL 不放进 `cpu_top`**：仿真测试台例化的是 `cpu_top`，
  放进去就得在仿真里也跑 PLL（Pango 原语仿真模型、锁定延时……纯属负担）。
  挡在板级这一层，**仿真就天然是 27 MHz，上板才是 85.0051 MHz**。
* **为什么要挡在外层**：见 §6 第 4 条。

所以：**仿真继续用 `cpu_top`（27 MHz），上板用 `cpu_top_board`（85.0051 MHz）**。
除时钟与端口裁剪外，两者行为完全一致。
