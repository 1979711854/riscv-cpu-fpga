# 比特流归档（本地盘古板 MES2L676-200HP）

## [!] 仓库里没有 `.sbit` —— 队友 clone 下来必须自己生成

`.sbit` 被 `.gitignore` 排除（每个 9 MB，且每次综合都变），**不进仓库**。
所以这个目录在别人的机器上是**空的**（只有本 README）。

**想烧哪一版，就用一条命令生成哪一版：**

```powershell
scripts\build_bitstream.ps1 coremark    # 跑分版（ITER=1663，板上 49.8927MHz → 约 11.80 s）
scripts\build_bitstream.ps1 demo        # 演示程序版
```

产物固定落在 `pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`，在 PDS Programmer
里烧它即可。详细步骤见 **`doc/board_bringup.md` §3**。

## [!] 不要"直接烧 `generate_bitstream\` 里现成的那个"

`generate_bitstream\cpu_top_board.sbit` 这个名字**看不出里面是哪个固件** ——
它只代表「最后一次综合的那版」。PDS 的 Programmer 会记住上次用过的路径，
所以"只点 Program 不重新浏览文件"很容易烧到上一版。

> **2026-09-23 实踩**：想烧 CoreMark 跑分版，结果烧成了演示程序版 ——
> 烧完按按键有反应、串口打印 `KEY=0x.. LED=0x..`，完全没有跑分输出。

**判据**：用 `build_bitstream.ps1` 生成时它会打印 md5；也可以比对文件的
`LastWriteTime`。别靠文件名猜。

## 归档说明（仅本机有意义）

本机额外归档了几份 `.sbit` 方便快速切换（PDS 每次 `gen_bit_stream` 都会清空
`generate_bitstream/`，旧版被挪进 `bak/`，容易丢）：

| 文件 | 固件 / 时钟 | 用途 |
|---|---|---|
| `coremark_iter1663_pll49mhz_localboard.sbit` | CoreMark v1.0，ITER=1663，**49.8927 MHz**（PLL）+ BTB/BHT | **当前跑分版**。md5 `c4e2c4d2…`，综合 2026-09-25 14:29，slack +1.550 ns。**[OK] 已板上实测通过**：`Total ticks 588,890,651` ÷ 49,892,700 = 11.8031 s / **140.89 CoreMark**（日志 `doc/board/uart_20260925_172318.txt`）|
| `coremark_iter1500_pll45mhz_localboard.sbit` | CoreMark v1.0，ITER=1500，45 MHz（PLL） | 上一版跑分。md5 `36d2687d…`，slack +2.812 ns。**已板上实测通过**：`Total ticks 538,285,445` ÷ 45e6 = 11.9619 s / 125.40 CoreMark（日志 `doc/board/uart_20260925_005201.txt`）|
| `coremark_iter820_localboard.sbit` | CoreMark v1.0，ITER=820，27 MHz | 跑分（板上 10.898 s，见 `doc/board/uart_20260923_201540.txt`）。**旧时钟口径，留着做对照** |
| `demo_led_remap_localboard.sbit` | 演示程序（LED 已按开关位置重排），27 MHz | 现场演示、录像。**注意也是 27 MHz 版** |

这些**只在你自己机器上有**，不要指望队友那里也有。

> [!] 归档的这份 45 MHz 跑分版是 `DEBUG_LED=1`（`led[0]=pll_locked`、`led[1]=done`）。
> 27 MHz 那两份是**加 PLL 之前**的综合产物，板上跑起来仍按 27 MHz 分频 ——
> 要现跑现的，用 `build_bitstream.ps1` 重新生成，别混用。

## [!] ILA 调试版（不用于提交）—— 与 `.fic` 成对

| 文件 | md5 | 说明 |
|---|---|---|
| **`debug_ila_86probe_localboard.sbit`**（**已归档**）| `96ee7877` | **调试版**：含 DebugCore + JTAG Hub + 86 位探针。LUT 4,200 / FF 3,394 / DRM 19 / APM 11，slack **+1.329 ns**，`All Constraints Met`。综合 2026-09-25 18:30 |

> [重点] **想再抓波形，直接烧 `debug_ila_86probe_localboard.sbit` 就行，不用重跑 Inserter/P&R。**
> 调试核和 86 个探针都在这个比特流里，配合 `pds/RV32I_1/cpu_top_board.fic` 使用。
> RTL 里的探针束已经删掉了（收尾时删的），但**这不影响补抓** —— 探针是固化在
> 这份比特流里的。
>
> 换触发信号记得**改两处**：`dbg_set_unit -unit N ...` 改 TU 的值，
> 还要 `dbg_set_condition -select 0 -set "TUN"` 把条件公式指过去 ——
> 只改 `-unit` 的话条件仍指向 TU0（2026-09-25 实踩，见 `doc/ila_analysis.md` §7.6）。
| `pds/RV32I_1/cpu_top_board_ila.fic`（**已入库**）| `178d8aad` | 探针通道映射。`clockChannel=clk_sys`，dataChannel 86 条（0..85），4 个 1 位触发端口 = `ex_flush`/`stall`/`bht_hit`/`mispred` |

> [!] **这两份必须同批用**。重新综合/布线后旧 `.fic` 作废 —— 通道映射会整体错位，
> 现象是"有信号但全不对"。`.sbit` 是调试版、**别拿去当比赛提交版**。

**怎么确认调试核真进去了**：看 DRM —— 生产版 16、调试版 **19**（+3 = 1024×86bit 的采集 RAM）。
DRM 没变就是没插进去（多半是 `.fic` 没登记进 `.pds` 的 `wgt_my_fic_src`）。
详见 `doc/ila_analysis.md` §7.6 第 6b/6c 步。

**抓完波形要收尾**：删掉 `core.v` 末尾的探针束、撤掉 `.pds` 里的 `.fic` 登记，重新综合，
核对回到生产版基线 **LUT 3,721 / DRM 16 / slack +1.550 ns**。

## 提交比赛作品

比特流要作为**离线交付物**单独打包（走 git 进不去）。用 `build_bitstream.ps1`
生成一份干净的、**记下它的 md5**，连同 `doc/board_bringup.md` 一起交付。
