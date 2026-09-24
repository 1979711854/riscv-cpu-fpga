# 比特流归档（本地盘古板 MES2L676-200HP）

## ⚠️ 仓库里没有 `.sbit` —— 队友 clone 下来必须自己生成

`.sbit` 被 `.gitignore` 排除（每个 9 MB，且每次综合都变），**不进仓库**。
所以这个目录在别人的机器上是**空的**（只有本 README）。

**想烧哪一版，就用一条命令生成哪一版：**

```powershell
scripts\build_bitstream.ps1 coremark    # 跑分版（CoreMark ITER=820）
scripts\build_bitstream.ps1 demo        # 演示程序版
```

产物固定落在 `pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`，在 PDS Programmer
里烧它即可。详细步骤见 **`doc/board_bringup.md` §3**。

## ⚠️ 不要"直接烧 `generate_bitstream\` 里现成的那个"

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

| 文件 | 固件 | 用途 |
|---|---|---|
| `coremark_iter820_localboard.sbit` | CoreMark v1.0，ITER=820 | 跑分（板上 10.898 s，见 `doc/board/uart_20260923_201540.txt`）|
| `demo_led_remap_localboard.sbit` | 演示程序（LED 已按开关位置重排） | 现场演示、录像 |

这些**只在你自己机器上有**，不要指望队友那里也有。

## 提交比赛作品

比特流要作为**离线交付物**单独打包（走 git 进不去）。用 `build_bitstream.ps1`
生成一份干净的、**记下它的 md5**，连同 `doc/board_bringup.md` 一起交付。
