# 归档比特流（.sbit 本身不入库，只入库这份索引）

> `.sbit` 被 `.gitignore` 排除（9 MB/个）。**别人 clone 下来一个都没有，必须自己综合。**

| 文件 | 内容 | md5 |
|---|---|---|
| `video_colorbar_pll62mhz_75871d8a.sbit` | **HDMI 彩条版**（首次上板用）—— `build_bitstream.ps1 video` 产物 | `75871d8a` |

**怎么生成 / 怎么确认是哪一版**（2026-10-01 首次成功综合）：

```powershell
scripts\build_bitstream.ps1 video     # 一条命令：固件 -> 同步 -> 综合，并打印 md5
```

> [!] **`generate_bitstream\cpu_top_board.sbit` 这个固定名字看不出里面是哪一版** ——
> 它只代表"最后一次综合的那版"，而且**任何一次综合都会覆盖它**（包括临时探针）。
> 别靠文件名猜，看 md5。要留档就复制到这里并改名。

## 这一版（2026-10-01）的实测状态

**首次综合通过。** 三个时钟域 slack 全正：

| 时钟域 | Requested | Estimated | Slack |
|---|---|---|---|
| `clk_sys`（CPU / 显存 A 口） | 62.0309 MHz | 66.87 MHz | **+1.167 ns** |
| `pix_clk`（PPU / 显存 B 口） | 25.5004 MHz | 176.6 MHz | **+33.554 ns** |
| `ser_clk`（TMDS 并串） | 127.5022 MHz | — | **+6.856 ns** |

资源：LUT 4,003（2.51%）/ FF 2,849（0.89%）/ **DRM 53.5（12.89%）** / APM 4。
（DRM 从 16 涨到 53.5 是视频显存 73 KB —— 与 CPU 的 32 KB 统一存储器**是分开的两块**。）

**`Design Summary` 显示 `Some Constraints Violated`，但那 22 条全是跨域建模假象：**

| 起点 → 终点 | WNS | 失败端点 |
|---|---|---|
| `clk_sys → clk_sys` | +1.167 | **0** |
| `pix_clk → pix_clk` | +33.554 | **0** |
| `ser_clk → ser_clk` | +6.856 | **0** |
| `clk_sys → pix_clk` | −4.207 | 21 |
| `pix_clk → clk_sys` | −4.049 | 1 |

21 + 1 = 22，与 `RV32I_1.fdc` 里预测的"恒报 21 条 clk_sys→pix_clk + 1 条 pix_clk→clk_sys"
**一字不差**。原因：`.fdc` 执行时机早于 PLL 时钟创建，`set_clock_groups` / `set_false_path`
试过 4 种写法全失败，所以这两个域**无法被判为异步**，STA 就按一个 pix_clk 周期
(39.215 ns) 去算那 12+9 位同步器。**读报告必须按 path group 分开看。**

> [!] 残留风险（已知、已接受）：PDS 不知道那两条路径是同步器，布局时不会特意把
> 两级 flop 放近。最坏表现是**偶发一帧滚动位置错一下**（scroll/vblank 都是准静态量），
> 不会死机。**五子棋不用滚动，影响面更小。**

## 上板判据（HDMI 特有）

1. **`led[0] = pll_locked`、`led[1] = video_locked`** —— **led[1] 不亮先查视频 PLL，别去看 HDMI**
2. 串口应打印 banner + 各读回值 + **`SELFCHECK OK`**（共 187 字节，一次性）
   —— `SELFCHECK FAIL` 说明问题在 CPU 侧写/读显存，与 TMDS 无关
3. 显示器应出 **8 条等宽竖条**，从左到右：白 黄 青 绿 品红 蓝 黑
4. 黑屏/无信号/雪花 的排查顺序见 `rtl/video/video_top.v` 文件头那 5 条
