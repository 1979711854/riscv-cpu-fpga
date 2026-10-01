# 本地板实测证据（盘古 MES2L676-200HP）

> 采集方式：`scripts\serial_monitor.ps1 -Port COM4`
> （COM4 = `Silicon Labs CP210x USB to UART Bridge`，板载 USB-UART；COM12/COM13 是 JTAG 下载器的 FTDI 通道）
>
> 板上资源：`clk=D18`(27MHz 晶振)、`resetn=C22`、`UART=B24/C24`、LED/KEY 见
> `pds/RV32I_1/RV32I_1.fdc` 头部注释。

## 当前设计：**49.8927 MHz（PLL 倍频）+ 动态分支预测**，2026-09-25 板上实测通过 [OK]

2026-09-25 起板上时钟为 **49.8927 MHz**（板载 27MHz 经 PLL 倍频，`RATIO0=23`），
并在同一天加了 **256 项带 tag 的 BHT**（动态分支预测）。
**已验证通过**，日志 `uart_20260925_172318.txt`（30 秒内跑 2 轮，`Total ticks` 逐位相同）。

| | 27 MHz | 45 MHz | **49.89 MHz（当前）** |
|---|---|---|---|
| ITER | 820 | 1500 | **1663** |
| `Total ticks` | 294,262,913 | 538,285,445 | **588,890,651** |
| 时长算法 | ÷27e6 = 10.898 s | ÷45e6 = 11.9619 s | **÷49,892,700 = 11.8031 s** |
| 每迭代周期 | 358,857 | 358,857 | **354,113** |
| 得分 | 75.24 | 125.40 | **140.89** |
| 板上证据 | [OK] | [OK] | [OK] |

> **累计提升：75.24 → 140.89 CoreMark = +87.3%**（vs 45 MHz 那版 +12.36%）。
>
> **每迭代周期 358,857 → 354,113** 是 2026-09-25 加 BHT 的收益（省 4,727 拍 = 1.32%）。
> 而 27/45 MHz 两代**逐位相同**（都是 358,857）—— 那两代的时钟翻倍而周期数不动，
> 正是"周期数与时钟无关"的直接证据（45 MHz 时用于验证；49.89 MHz 这代因为
> 加了 BHT，周期数才变了，属设计改动而非时钟效应）。

> [!] **板/仿真差会双向抖动**：27/45 MHz 两代是 **+0.0031%**（板上慢 11 拍），
> 49.89 MHz 这代是 **−0.0016%**（板上快 6 拍）。方向相反、量级相同，
> 是仿真模型的抖动范围，**不是趋势**。别拿单次差值下结论。

---

## 历史：**45 MHz（PLL 倍频）**，2026-09-25 上午板上实测通过 [OK]

2026-09-25 上午起板上时钟一度改为 **45 MHz**（板载 27MHz 经 PLL 倍频，见 `doc/board_bringup.md` §2），
当天下午进一步提频到 49.8927 MHz（见上一节）。
**已验证通过**，日志 `uart_20260925_005201.txt`。

| | 27 MHz（历史） | **45 MHz（历史）** |
|---|---|---|
| ITER | 820 | **1500** |
| 每迭代周期 | 358,857（实测） | **358,857（实测，与 27MHz 逐位相同的口径）** |
| `Total ticks` | 294,262,913 | **538,285,445** |
| 时长算法 | ÷ 27e6 = 10.898 s | **÷ 45e6 = 11.9619 s** |
| 得分 | 75.24 CoreMark | **125.40 CoreMark（+66.7%）** |
| 板上证据 | [OK] | [OK] **已完成** |

> **"每迭代周期"在两个时钟下逐位相同（都是 358,857）** —— 这正是
> "周期数与时钟无关"的直接证据，也让"仿真数据可外推到板上"这条推论站得住。

## 证据清单

| 文件 | 内容 | 用途 |
|---|---|---|
| `uart_20260923_200337.txt` | 演示程序首次跑通：4 个开关分别给出 `0x01/0x02/0x04/0x08`，复位键重启程序 | GPIO/UART/时钟全链路的首次验证 |
| `uart_20260923_200737.txt` | **从左到右**依次按 4 个开关 → `0x01 → 0x02 → 0x04 → 0x08` | 证明 `key[0..3]` 与开关左右顺序一致 |
| `uart_20260923_201540.txt` | CoreMark v1.0（ITER=820，**27 MHz**） | 27 MHz 时代的板上证据 |
| `uart_20260923_202257.txt` | CoreMark 第二次跑（按复位键重跑，未重烧） | **复现性**：`Total ticks` 与第一次逐位相同（都是 294262913） |
| `uart_20260925_005201.txt` | CoreMark v1.0（ITER=1500，45 MHz） | 45 MHz 时代的板上证据；30 秒内跑了 2 轮，`Total ticks` 逐位相同 |
| **`uart_20260925_172318.txt`** | [重点] **CoreMark v1.0（ITER=1663，49.8927 MHz + BHT）** | **当前设计的板上证据**；30 秒内跑了 2 轮，`Total ticks` 逐位相同（588,890,651）|
| **`ila_hw_exflush_coremark.vcd`** | ILA 硬件在环抓的逐拍波形（2026-09-25，1024 拍）：CoreMark 里一次分支冲刷，**三种 BHT 行为全在这一份里** | 赛题点名的 ILA 评分项 —— **已完成**（不再是待办）；`.dprj`/`.wdf` 是配套的工程与波形文件 |
| **`ila_hw_halt_loop.vcd`** | ILA 硬件在环抓的逐拍波形：固件停机自旋 `j 38`（`while(1)`） | 验证"预测中的跳转不冲刷" |

## CoreMark 关键数据

### 49.8927 MHz / ITER=1663（**当前设计**，`coremark_iter1663_pll49mhz_localboard.sbit`）

```
Total ticks      : 588890651
Total time (secs): 11
Iterations/Sec   : 151
Iterations       : 1663
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
crcfinal         : 0x81c9
Correct operation validated.
```

| 指标 | 数值 |
|---|---|
| 实际运行时长 | 588,890,651 ÷ **49,892,700** = **11.8031 s**（>=10 s 达标）|
| 每迭代周期 | 588,890,651 ÷ 1663 = **354,113** |
| 与仿真（354,119）偏差 | **-6 拍/迭代 = -0.0016%**（板上略快）|
| CoreMark 分数 | 1663 ÷ 11.8031 = **140.89 iterations/s** |
| CoreMark/MHz | 140.89 ÷ 49.8927 = **2.824**（与仿真口径一致）|
| 对比 45 MHz 板 | 125.40 → **140.89 = +12.36%** |
| 对比 27 MHz 板 | 75.24 → **140.89 = +87.3%** |

> 推算值 588,900,000 / 140.89，实测 588,890,651 / 140.89 —— **得分精确命中**。

### 45 MHz / ITER=1500（历史，`coremark_iter1500_pll45mhz_localboard.sbit`）

```
Total ticks      : 538285445      ← 538,285,445 拍 @45MHz
Total time (secs): 11             ← 打印是整数截断，实际 11.9619 s
Iterations/Sec   : 136            ← 同上，136 = 1500/11 的废数，实际 125.40 iter/s
Iterations       : 1500
Correct operation validated.
[0]crclist 0xe714  [0]crcmatrix 0x1fd7  [0]crcstate 0x8e3a   seedcrc 0xe9f5
```

| 指标 | 数值 |
|---|---|
| 实际运行时长 | 538,285,445 ÷ 45 MHz = **11.9619 s**（≥10 s 达标）|
| 每迭代周期 | 538,285,445 ÷ 1500 = **358,857** |
| 与仿真（358,846）偏差 | **+11 拍/迭代 = +0.0031%**（与 27MHz 那次**完全相同**）|
| CoreMark 分数 | 1500 ÷ 11.9619 = **125.40 iterations/s** |
| CoreMark/MHz | 125.40 ÷ 45.0005 = **2.787**（与仿真口径一致）|
| 对比 27 MHz 板 | 75.24 → **125.40 = +66.7%**（= 纯时钟比 45.0005/27）|

### 27 MHz / ITER=820（历史，`coremark_iter820_localboard.sbit`）

```
Total ticks      : 294262913
Iterations       : 820
Correct operation validated.
[0]crclist 0xe714  [0]crcmatrix 0x1fd7  [0]crcstate 0x8e3a   seedcrc 0xe9f5
```

时长 = 294,262,913 ÷ 27e6 = **10.898 s**；每迭代周期 358,857；得分 75.24 CoreMark。

### [!] CRC 怎么比才对：**别拿 `crcfinal` 当判据**

| CRC | 随 ITER 变吗 | 能不能用来比对 |
|---|---|---|
| `seedcrc` / `crclist` / `crcmatrix` / `crcstate` | **不变** | [OK] **这才是判据**，跨 ITER、跨时钟都必须逐位相同 |
| `crcfinal` | **变** | [X] 不能比 |

**依据（读 CoreMark 源码确认，`third_party/coremark/core_main.c` 的 `iterate()`）：**

```c
res->crc = 0;
for (i = 0; i < iterations; i++) {
    crc      = core_bench_list(res, 1);
    res->crc = crcu16(crc, res->crc);      // ← crcfinal 是【跨迭代累加】的
    crc      = core_bench_list(res, -1);
    res->crc = crcu16(crc, res->crc);
    if (i == 0) res->crclist = res->crc;   // ← 子 CRC 只在第 0 轮快照一次
}
```

`[0]crcfinal` 打印的是 `results[0].crc`，即上面那个**累加器** —— 它必然随 ITER 变：

| 运行 | ITER | crcfinal |
|---|---|---|
| 仿真 | 1 | `0xe714` |
| 27 MHz 板 | 820 | `0xbd59` |
| 45 MHz 板 | 1500 | `0x25b5` |
| **49.89 MHz 板** | **1663** | **`0x81c9`** |

**四个都不同，但四个都是正确的。** 判"CPU 算得对"只看
`seedcrc/crclist/crcmatrix/crcstate` 四个 —— 那四个跨 ITER、跨时钟逐位一致。
（CLAUDE.md 早先写"四个 CRC 与仿真逐位一致"措辞不严，已一并更正。）
| **复现性** | 按复位键重跑一次（未重烧），`Total ticks` **逐位相同** —— 板上跑分是确定性的 |

> [!] `Total time (secs)` 与 `Iterations/Sec` 是**整数截断**打印的
> （`HAS_FLOAT=0`，见 `scripts/coremark_port/core_portme.h`），
> 报告里引用请用 `Total ticks ÷ EE_TICKS_PER_SEC` 自己算
> （**当前板上 = 49,892,700**；仿真 = 27,000,000），
> 别直接用打印的 `11` / `151`（45 MHz 时代那版打印的是 `11` / `136`）。

## 硬件现状说明（写报告时用得着）

* **手册是 0 起编号，板上丝印是 1 起编号**：手册 `KEY0..KEY4` = 丝印 `KEY1..KEY5`。
* **LED 丝印相对开关是错位的**，这是板卡硬件现状，不是映射错误：

  | 手册 | FPGA 管脚 | 板上丝印 | 位置 |
  |---|---|---|---|
  | LED0 | A20 | D17 | SW3 下面 |
  | LED1 | C18 | D18 | SW5 下面 |
  | LED2 | C19 | D19 | SW4 下面 |
  | LED3 | E18 | D13 | SW6 下面 |
  | LED4 | A17 | D14 | SW7 下面 |
  | LED5 | A18 | D15 | — |
  | LED6 | C17 | D16 | — |
  | LED7 | B17 | D12 | — |

  所以演示程序（`LED = KEY`）按某个开关时，亮的是**该开关隔壁**的灯，
  而非正下方那个 —— 串口日志里 `KEY=0x08 LED=0x08` 证明写入字节与读到字节
  完全一致，映射本身正确。
