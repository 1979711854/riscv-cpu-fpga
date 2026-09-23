# 本地板实测证据（盘古 MES2L676-200HP）

> 采集方式：`scripts\serial_monitor.ps1 -Port COM4`
> （COM4 = `Silicon Labs CP210x USB to UART Bridge`，板载 USB-UART；COM12/COM13 是 JTAG 下载器的 FTDI 通道）
>
> 板上资源：`clk=D18`(27MHz)、`resetn=C22`、`UART=B24/C24`、LED/KEY 见
> `pds/RV32I_1/RV32I_1.fdc` 头部注释。

## 证据清单

| 文件 | 内容 | 用途 |
|---|---|---|
| `uart_20260923_200337.txt` | 演示程序首次跑通：4 个开关分别给出 `0x01/0x02/0x04/0x08`，复位键重启程序 | GPIO/UART/时钟全链路的首次验证 |
| `uart_20260923_200737.txt` | **从左到右**依次按 4 个开关 → `0x01 → 0x02 → 0x04 → 0x08` | 证明 `key[0..3]` 与开关左右顺序一致 |
| `uart_20260923_201540.txt` | **CoreMark v1.0 本地板实测（ITER=820）** | 赛题硬指标「运行 ≥10 s」的板上证据 |
| `uart_20260923_202257.txt` | **CoreMark 第二次跑**（按复位键重跑，未重烧） | **复现性**：`Total ticks` 与第一次**逐位相同**（两次都是 294262913） |

## CoreMark 关键数据（ITER=820）

```
Total ticks      : 294262913       ← 294,262,913 拍 @27MHz
Total time (secs): 10              ← 打印是整数截断，实际 10.898 s
Iterations/Sec   : 82              ← 同上，实际 75.24 iter/s
Correct operation validated.
[0]crclist 0xe714  [0]crcmatrix 0x1fd7  [0]crcstate 0x8e3a   seedcrc 0xe9f5
```

| 指标 | 数值 |
|---|---|
| 实际运行时长 | 294,262,913 ÷ 27 MHz = **10.898 s**（≥10 s 达标） |
| 每迭代周期 | 294,262,913 ÷ 820 = **358,857** |
| 与仿真（358,846）偏差 | **+11 拍/迭代 = +0.0031%** |
| CoreMark 分数 | 820 ÷ 10.898 = **75.24 iterations/s** |
| CoreMark/MHz | 75.24 ÷ 27 = **2.787**（与仿真口径完全一致） |
| 四个 CRC | 与仿真基准**逐位一致**（对照 `doc/reports/2026-09-21_branch_opt_verify.md` §CRC 表） |
| **复现性** | 按复位键重跑一次（未重烧），`Total ticks` **逐位相同** —— 板上跑分是确定性的 |

> ⚠️ `Total time (secs)` 与 `Iterations/Sec` 是**整数截断**打印的
> （`HAS_FLOAT=0`，见 `scripts/coremark_port/core_portme.h`），
> 报告里引用请用 `Total ticks ÷ EE_TICKS_PER_SEC(=27,000,000)` 自己算，
> 别直接用打印的 `10` / `82`。

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
