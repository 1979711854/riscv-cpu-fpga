# 归档比特流（.sbit 本身不入库，只入库这份索引）

> `.sbit` 被 `.gitignore` 排除（9 MB/个）。**别人 clone 下来一个都没有，必须自己综合。**

| 文件 | 内容 | md5 |
|---|---|---|
| `gomoku_pll62mhz_2cee98c9.sbit` | 五子棋版（62 MHz 时代）—— 提频出问题时的回退版 | `2cee98c9` |
| `coremark_pll85mhz_ae4deea9.sbit` | **单发射** CoreMark @ 85 MHz —— **已板上实测 233.85 分**（ITER=2740）| `ae4deea9` |
| `gomoku_pll85mhz_f4e78dc6.sbit` | **单发射** 五子棋 @ 85 MHz —— 已上板跑通（含串口棋盘快照等）| `f4e78dc6` |
| `gomoku_dual_85mhz_3976aebd.sbit` | **双发射** 五子棋 @ 85 MHz（无 HUD 的上一版）—— 已板上跑通 | `3976aebd` |
| `gomoku_dual_hud_85mhz_e5bc227a.sbit` | 双发射 + HUD @ 85 MHz（**60.71Hz 刷新**，画面会抖/撕裂）| `e5bc227a` |
| **`gomoku_dual_hud_60hz_50c4e364.sbit`** | 双发射 + HUD @ **标准 60Hz**（刷新率修正，屏幕正常）—— 有一处 HUD 残字 bug | `50c4e364` |
| `gomoku_dual_hud_60hz_rv32a_8c229a21.sbit` | 双发射 + HUD + **A 扩展** @85MHz —— **时序 −0.096 ns，不可用**（留作"单 seed 不收敛"的证据）| `8c229a21` |
| `gomoku_dual_aext_ms_85mhz_3418c5fc.sbit` | 双发射 + HUD + **A 扩展** + **多 seed 布局** —— slack +0.064 ns | `3418c5fc` |
| `gomoku_dual_aext_ms_85mhz_addrfix_f00c6659.sbit` | 上面那版 + **`imem_addr2` 截位修复**（约定 40）—— slack +0.236 ns。**已上板**（2026-10-10，两局五子棋正常，屏幕正常）| `f00c6659` |
| **`coremark_dual_aext_ms_stage01_earlyld_dcache_2f7a4d0a.sbit`** | **带 D-Cache 的一版（2026-10-12）**：`2ddaf32f` + **`DCACHE_EN=1`（只开 D-Cache）**。CPU 域 slack **+0.151 ns / 失败端点 0**，DRM **105.5/415**；网表已验（`dcache` 653 处、`tag0` 100 处、`icache` 0 处）。ITER=4116，**[OK] 已上板（2026-10-12，日志 `doc/board/uart_20261012_002541.txt`）**：`Total ticks 994,386,960` → **11.69797 s** → **351.86 分**；`[cache] D hits=35,341,114 / miss=25,081`（**命中率 99.929%**）；**四个 CRC 与关 Cache 时逐位相同**；拍/迭代 241,590.6（关 Cache 版 +6.0 拍）| `2f7a4d0a` |
| **`coremark_dual_aext_ms_stage01_earlyld_2ddaf32f.sbit`** | **跑分版（2026-10-11 晚）**：在 `03d8a7eb` 之上加**任务 C 的 `EARLY_LD`（load 地址提前到 ID + 专用读口）** —— 每迭代 **241,633** 拍（原 262,018，**−7.79%**），ITER=**4116**，CPU 域 slack **+0.045 ns**、失败端点 **0**（16,484 端点）。预期板上 11.70 s / **≈352 分**。**尚未上板**。四条基线全过（riscv-tests 49/1/0、自写 2/0、AMO T0 PASS、RT-Thread SoC PASS、CoreMark 四 CRC 逐位一致）| `2ddaf32f` |
| `coremark_dual_aext_ms_stage01_a0cache_03d8a7eb.sbit` | **上一版（2026-10-11）**：`4f1b0977` + **A.0（`mem_ready`/访存停顿收尾）+ I/D Cache 骨架（默认关，等于没有）+ 外设 one-shot 门控**。slack **+0.578 ns**（89.40 MHz），失败端点 0，ITER=3796。**串口日志与 `4f1b0977` 逐位应一致**（Cache 关时功能逐位不变）| `03d8a7eb` |
| `coremark_dual_aext_ms_stage01_4f1b0977.sbit` | **当前最新（2026-10-10）**：`imem_addr2` 修复 + 版本自证 + **阶段0（-O3 编译选项）+ 阶段1（到达级分支重定向）** —— CoreMark **ITER=3796** @85MHz，slack **+0.544 ns**（89.13 MHz），失败端点 0。预期板上 ~11.70 s / **324 分**。**尚未上板** | `4f1b0977` |
| `coremark_dual_aext_ms_85mhz_mimpid_492714a8.sbit` | `imem_addr2` 修复 + **版本自证**（`mimpid` 打出 `RTL=`，约定 42）—— CoreMark ITER=3170 @85MHz，slack +0.525 ns，失败端点 0。**已板上实测 270.82** | `492714a8` |
| **`gomoku_dual_hud_60hz_074a0e11.sbit`** | **当前最新**：60Hz + **HUD 残字修复**。已板上可玩 | `074a0e11` |
| **`coremark_dual_85mhz_5c4893de.sbit`** | **双发射** CoreMark @ 85 MHz —— **已板上实测 270.82 分**（ITER=3170，`Total ticks 994,988,178` / 11.7050 s）| `5c4893de` |

> [!] 旧的 `gomoku_dual_hud_85mhz_e5bc227a.sbit`（60.71Hz）保留作对照 ——
> **它能复现"画面抖动/撕裂"那个症状**，是刷新率那条结论的证据。

> [!] **2026-10-11 起"当前源码"对应的是 `03d8a7eb`**（A.0 + Cache 骨架，Cache 默认关）。
> `4f1b0977` 保留作它的对照。
>
> [!] **`4f1b0977` 才是"当前源码"对应的位流**（2026-10-10，阶段0+1）——
> 串口第一行应为 `[build] FW=COREMARK RTL=0x2026_1011`（`DESIGN_REV` 已递增，
> **自证是阶段1 之后的网表**；`492714a8` / `7b6e5e05` 读出来的都是 `0x2026_1010`）。
> **`7b6e5e05` 是复核阶段的中间产物（ITER=3518，板上只有 10.84 s），别烧它。**

> [!] **`492714a8` 是阶段0/1 之前的 CoreMark 位流**（2026-10-10，已板上实测 **270.82**）——
> `imem_addr2` 宽度修复 **+** 版本自证（`mimpid`）。烧上去串口第一行是：
> ```
> [build] FW=COREMARK RTL=0x20261010
> ```
> **看到 `RTL=` 就是"有版本自证的那一代"**；更早的位流没有这一行（那时 `mimpid`
> 恒 0，固件也还没读它）。判分看 `Total ticks`（ITER=3170 约 994,9xx,xxx，
> ÷85,005,100 ≈ 11.7 s）+ 四个 CRC。
>
> **`RTL=` 的值可以一眼分辨网表代次**：`0x2026_1011` = 含阶段1（当前）；
> `0x2026_1010` = 阶段1 之前；无此行 = 更早。
>
> [!] 因为加了这一行，CoreMark 镜像从 4208 字涨到 **4228 字**
> （`build_bitstream.ps1` 的 `expectLines` 表已实测更新）。

> [!] **`f00c6659` 与 `3418c5fc` 的差别只在 RTL 的一个宽度**（2026-10-10）：
> `imem_addr2` 从 13 位改回 14 位（64KB 扩容时漏改的那处）。
> 现代码都 < 32KB，所以**两者功能上应当逐位相同** —— 但它**换了网表**，
> 时序是重新跑多 seed 布局得到的（+0.064 → **+0.236 ns**，CPU 域失败端点仍是 0）。
> **没上板验过，别当"已验"。** 想最保险就继续用 `3418c5fc`（已板上跑通的那版）——
> 前提是程序代码不越过 32KB。

> [!] **"单发射 / 双发射"现在是位流名字的一部分**（2026-10-06 起）。两者文件名与字节数
> 完全一样，**不标配置就分不出来** —— 而烧错的表现是"分数差 15.8%"这种不显眼的差别，
> 比烧错固件更难发现。**归档时一律带上 `_dual_` / `_single_`。**
>
> 两块 `coremark_*` 都**已板上实测**（2026-10-06 补齐）：
> - `ae4deea9`（单发射）**233.85 分**，slack +0.823 ns
> - `5c4893de`（双发射）**270.82 分**，slack +0.270 ns —— **薄余量扛住了**
>
> 双发射这一版**只是多出 15.8% 的分**，功能上四个 CRC 与单发射逐位一致。
> **若它在别的场景出问题，一键回退 `ae4deea9`**（不用重新综合）。
>
> **[OK] 双发射的应用侧也已验证**（2026-10-06，日志 `doc/board/uart_20261006_172315.txt`）：
> 五子棋启动、按键、难度切换、落子、AI 应手、棋盘状态全部正常。
> **AI 一手从平均 553 ms 降到 486 ms（−18%）** —— 与 CoreMark 的 +15.8% 吻合，
> 说明双发射的收益不只是跑分数字，应用侧也真的更跟手。
> **唯一还没验的是 HDMI 画面**（缺显示器）。

> [!] **两块 85 MHz 位流的区别只在固件**（同一个网表、同一份 RTL）：
> `coremark_*` 是跑分固件，`gomoku_*` 是五子棋固件。**烧错的现象是完全相反的两件事** ——
> 烧成 coremark 版：串口打 CoreMark 报告、按键无反应；烧成 gomoku 版：串口打棋盘、不跑分。
> **`generate_bitstream\cpu_top_board.sbit` 永远只代表"最后一次综合的那版"**，别靠它猜。

**怎么生成 / 怎么确认是哪一版**（2026-10-01 首次成功综合）：

```powershell
scripts\build_bitstream.ps1 video     # 一条命令：固件 -> 同步 -> 综合，并打印 md5
```

> [!] **`generate_bitstream\cpu_top_board.sbit` 这个固定名字看不出里面是哪一版** ——
> 它只代表"最后一次综合的那版"，而且**任何一次综合都会覆盖它**（包括临时探针）。
> 别靠文件名猜，看 md5。要留档就复制到这里并改名。

> [!] **2026-10-01 实踩（第二次）：烧成了上一次分配的位流。**
> 当时想测视频彩条，烧完抓串口却打出 **CoreMark**（`Total ticks 727,018,199` /
> `Iterations 2000`）—— 说明烧的是 **`D:\riscv-cpu-fpga`（CPU 单仓）那份 CoreMark 位流**
> （md5 `3f76e554`），不是本工程的视频位流（md5 `75871d8a`）。
> **两个位流的文件名完全相同、字节数也完全相同（9,188,552）**，只看文件名/大小
> 永远分不出来。
> **根因**：Fabric Configuration 会把上次分配的文件记在器件节点上，而且是在
> **分配时**读进内存的 —— 只点 `Program` 就会重烧上次那份。
> **纪律**：`Scan Device → `**`Assign New Configuration File`**` → Program` 三步走全，
> 中间那次 Browse 不能省；烧完**先对 md5**再下结论。

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
