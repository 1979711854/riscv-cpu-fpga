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

⚠️ **只插 Jtag 那根，串口是不会有任何输出的** —— 这是最容易卡住的一步。

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

器件与远程平台是同一颗，所以时钟约束仍是 **27 MHz / 37.037 ns**，不用改。

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

## 3. 流程 A：烧现成比特流（最常用）

已经归档好的比特流在 `pds/RV32I_1/bitstreams/`：

| 文件 | 固件 | 用途 |
|---|---|---|
| `demo_led_remap_localboard.sbit` | 演示程序（读按键→写 LED→串口打印） | 现场演示、录像 |
| `coremark_iter820_localboard.sbit` | CoreMark v1.0，ITER=820 | 跑分 |

> `.sbit` 被 `.gitignore` 排除（每个 9 MB），**不进仓库**；同目录 `README.md` 写了怎么重新生成。

烧录：

```
PDS → TOOL → Programmer（下载）
  器件：PG2L200H
  配置文件：pds\RV32I_1\generate_bitstream\cpu_top_board.sbit
```

⚠️ **文件名是 `cpu_top_board.sbit`**（不是 `cpu_top.sbit`），别误选 `generate_bitstream/bak/` 里的旧文件。

烧完立刻看串口（CoreMark 一轮约 11 秒，慢一拍就错过了）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60
```

---

## 4. 流程 B：从零重新生成比特流

**什么时候必须走这一步**：改了 `rtl/**`、改了 `RV32I_1.fdc`、或者换了固件（CoreMark ↔ 演示程序）。

```powershell
# ① 生成固件（二选一）
scripts\run_coremark.ps1 -Iter 820 -SkipSim      # 跑分版
scripts\run_demo.ps1 -SkipSim                    # 演示程序版

# ② 把固件同步进 PDS 工程目录（PDS 读的是 pds\RV32I_1\mem.hex，不是 sim\programs\mem.hex）
scripts\sync_firmware.ps1

# ③ 命令行综合布线出比特流（约 5 分钟）
cd pds\RV32I_1
D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe -project RV32I_1.pds -run gen_bit_stream
```

也可以在 PDS GUI 里逐个点 Compile / Synthesize / Device Map / Place & Route / Generate Bitstream。

**几个关于 PDS 命令行的实测事实**：

* `pds_shell -project X.pds -run <action>` 可用的 action：`compile` `synthesize` `dev_map`
  `pnr` `report_timing` `gen_bit_stream`。
* **每个 `-run` 都会把前面的步骤重跑一遍** —— 所以 `-run gen_bit_stream` 实际会跑完整条链，
  约 5 分钟，不是 1 分钟。
* `-file <tcl>` 与 `-project` **不能同时用**（会报 `Only one of '-file' or '-project' can be specified`）。
* **PDS 每次 `gen_bit_stream` 都会先清空 `generate_bitstream/`**，上一版被挪进 `bak/`。
  所以重要的比特流要及时归档到 `bitstreams/`。

---

## 5. 上电后该看到什么

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

约 11 秒后打印：

```
CoreMark Size    : 666
Total ticks      : 294262913
Total time (secs): 10
Iterations       : 820
Compiler flags   : -O2 -march=rv32im -mabi=ilp32
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
Correct operation validated.
```

⚠️ **`Total time (secs)` 和 `Iterations/Sec` 是整数截断打印的**（`HAS_FLOAT=0`）。
真实时长要自己算：`Total ticks ÷ 27,000,000`。294,262,913 → **10.898 s**。

---

## 6. 排障速查

| 现象 | 最可能原因 |
|---|---|
| **串口乱码** | 时钟不是 27 MHz（波特率是按 27MHz 分频的）—— 这是判断时钟最快的方法 |
| 完全没输出 | ① 板子没配置（掉电/拔过 USB → 重烧）② 只插了 Jtag 没插 USB-UART ③ 读错 COM 口（读成 FTDI 那个）④ UART 引脚 |
| 串口正常但按键没反应 | `key[]` 引脚（C23/B22/A22/B20） |
| 灯不亮 / 恒亮 | LED 引脚或极性（本板**输出高电平点亮**） |
| 按键→LED 关系不对 | 检查 `led[]` 是否被改回手册顺序（见 §2 第 2 条） |
| 烧录后设备唤醒失败 | 远程平台那套"多烧几次就好"的经验**不适用本地板** —— 出现就是真问题 |

**FPGA 掉配置的判据**：按键完全没反应 + 串口没输出。板子断电或拔过 USB 就会这样（比特流是烧进 SRAM 的）。
**不用重烧的情况**：只要没断电、没重生成比特流，按一下复位键（SW3）就能让程序从头再跑一轮。

---

## 7. 已知的坑（都踩过）

1. **PDS 不检查 `mem.hex` 的时间戳**。跑过 `run_riscv_tests.ps1` 或 `run_demo.ps1` 之后再
   `sync_firmware.ps1`，工程里就留下别的程序的镜像；此后无论怎么改 RTL、重新综合，
   **板上跑的都还是那个旧程序，而 PDS 全程零报错**。
   判据：核对 `pds\RV32I_1\mem.hex` 的字数与预期是否相当（CoreMark = 4209 字，演示程序 = 163 字）。
2. **上板的 top module 是 `cpu_top_board`，不是 `cpu_top`** —— 前者把 `pc[31:0]` / `done`
   挡在外面。原因见 §8。
3. **`.fic` 与 `.sbit` 必须来自同一次综合布线**（做 ILA 时）。RTL 一变，旧 `.fic` 就作废。
4. **未在 `.fdc` 里指定 LOC 的输出端口会被 PDS 自动布到 BANKR5 的任意引脚**上
   （实测 `pc[0]→M2`）。BANKR5 接的是 SFP/HSST，所以上板顶层不引出这类端口。

---

## 8. 为什么有 `cpu_top_board` 这一层

`rtl/top/cpu_top_board.v` 只做一件事：**包住 `cpu_top`，不引出 `pc[31:0]` 和 `done`**，
并把 `key[7:4]` 恒定接 1。

* **为什么不在 `cpu_top` 里直接删端口**：`pc` 是**仿真侧的分析数据源** ——
  `tb_coremark` 的 `+TRACE`/`+PROF` 逐拍 dump 和各测试台的 TIMEOUT 诊断
  （`$display("TIMEOUT (pc=0x%h)", pc)`）都依赖它。删掉会废掉
  `doc/ila_analysis.md` 里那套分析方法。
* **为什么要挡在外层**：见 §7 第 4 条。

所以：**仿真继续用 `cpu_top`，上板用 `cpu_top_board`**。两者行为完全一致，只是端口裁剪不同。
