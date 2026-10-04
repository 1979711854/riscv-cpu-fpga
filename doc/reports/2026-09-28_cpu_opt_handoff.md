# 交接：CPU 侧优化（两拍乘法器 + 提频 62.03 MHz）

> 日期：2026-09-28　来源：`D:\riscv-cpu-fpga`（CPU 优化线）
> 去向：带 PPU 视频子系统的那份工程（应用场景线）
> 配套包：`riscv-cpu-fpga_cpuopt_62mhz_20260928.zip`（= commit `8f790d7`）

> [!] 本文写于 2026-09-28，当时主频是 **62.03 MHz**。2026-10-04 已提频到 **85.0051 MHz**
> （PLL `STATIC_RATIO0` 18.5 → 13.5）。文中的频率/常量（`62030900`、`UART_DIV=538`、
> `ITER=2000` 等）按**历史**理解，勿当当前值引用。

---

## 0. 这个包里有什么、没有什么

| | |
|---|---|
| **有** | CPU 域的全部优化成果 + 完整文档 + 板上实测证据 |
| **没有** | **PPU / `rtl/video/` / `scripts/video/`** —— 那些在你的工程里，本仓库从来没有过 |
| **没有** | 比特流（`.sbit` 9MB/个，被 gitignore；且你的工程带 PPU，我们的位流对你没用）|

> 所以这个包是**给你合并用的**，不是替换用的。**别整体覆盖你的工程。**

---

## 1. [!] 合并只要三步，但第三步最容易出事

### 第 1 步：拷 RTL 与仿真源码

```
rtl/core/multiplier.v      <- 新增
rtl/core/alu.v             <- 改写
rtl/core/core.v            <- 改写
rtl/top/cpu_top_board.v    <- 时钟/波特率常量
sim/tb_multiplier.v        <- 新增
sim/tb_coremark.v          <- 改（影子流水线用 mc_stall）
sim/tools/tb_debug_trap.v  <- 改
```

### 第 2 步：拷工程侧与固件侧

```
pds/RV32I_1/ipcore/pll/pll.idf + pll.v   <- 62.03 MHz
pds/RV32I_1/mem.hex                      <- CoreMark ITER=2000 快照（可覆盖，见第 5 节）
scripts/build_bitstream.ps1              <- ITER 默认值与校验
scripts/coremark_port/core_portme.c      <- EE_TICKS_PER_SEC
scripts/demo/addr_map.h                  <- CPU_HZ
scripts/rtthread/bsp/board.h             <- BOARD_SYSTEM_CLOCK_HZ
scripts/run_sim.ps1                      <- 排除名单修复
```

### 第 3 步：[重点] **改 `.pds`，不要覆盖 `.pds`**

我们的 `pds/RV32I_1/RV32I_1.pds` 里的源文件清单是**显式枚举**的，**它不包含你的 `ppu.v`**。
**整体覆盖 = PPU 直接从工程里消失**，而且 PDS 可能不报错。

正确做法：在**你的** `RV32I_1.pds` 里，往 `wgt_my_design_src` 的 `(_file ...)` 列表里
**手工补一条**：

```
(_file "../../rtl/core/multiplier.v"
    (_format verilog)
    (_timespec "2026-09-28T20:36:19")
)
```

> [!] **这个坑我们刚踩过，症状是"仿真全过、综合报错"**：
> 仿真脚本是通配扫描 `rtl/core/*.v`（新文件自动进），
> 而 **PDS 只认 `.pds` 里显式列出的文件**。
> 症状：`Verilog-4072: multiplier is referenced to undefined module`。
> 修法就是上面这一条。详见工程根 `CLAUDE.md` 约定 37。

---

## 2. 这次改了什么（一句话版）

**把 M 扩展乘法从「单拍组合」改成「两拍独立单元」，用它换来的时序余量把主频从 49.89 推到 62.03 MHz。**

| | 改前 | 改后 |
|---|---|---|
| 时钟（板上） | 49.8927 MHz | **62.0309 MHz** |
| CoreMark 每迭代周期 | 354,119 | 363,515（**+2.65%**，乘法的代价）|
| CoreMark 得分（板上实测） | 140.89 | **170.64（+21.1%）** |
| Estimated Fmax | 54.07 MHz | **67.78 MHz** |
| Slack | +1.550 ns | +1.368 ns |
| APM / LUT / FF | 11 / 3,721 / 2,441 | **4** / 3,767 / 2,508 |

**动机**：综合报告显示单拍组合乘法占关键路径 **56%（10.05 ns）**，而且那条路径的
起点是 BRAM —— 也就是 `lw` 之后紧跟一条 `mul` 时，访存数据要在一个周期里
穿过按字节解包、前递 mux、再走完 4 级 APM 乘法链。摘出来单独占两拍，那 10 ns 就没了。

**代价很小**：CoreMark 每迭代执行 9,396 条 mul，每条多 1 拍 = +2.65%。

> [!] **别用静态条数估这个代价。** `core_bench_matrix` 不是每迭代调一次，
> 它是被 `core_list_join.c` 的 `calc_func` 在链表遍历里按数据相关次数调用的。
> 按静态推算会得到 1,620 条，**比真值小 5.8 倍**。以 `+PROF` 的 `c_mul` 为准。

---

## 3. [重点] 合并后必须跑的三条判据

```powershell
scripts\run_riscv_tests.ps1     # 必须 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_coremark.ps1 -Iter 1 # 必须 Total ticks = 363,515
scripts\run_own_tests.ps1        # 必须 2 PASS / 0
```

| 指标 | 新基线 |
|---|---|
| CoreMark 计时区间 | **363,515** 拍 |
| 测试台总周期 | **1,467,276** |
| 四个 CRC | `e9f5 / e714 / 1fd7 / 8e3a` 逐位一致 |
| 精确闭合式 | `288,056（提交）+ 20,720（load-use）+ 9,396（mul）+ 45,343（分支）= 363,515` |

> 这条闭合式是**最灵敏的探针**：改完如果只有某一项变了、其他三项不动，说明改动是隔离的；
> 如果分支损失（45,343）变了，那一定是碰坏了重定向逻辑。

---

## 4. 时钟相关的常量要同步 **4 处**（别只改 3 处）

| 文件 | 常量 | 值 |
|---|---|---|
| `rtl/top/cpu_top_board.v` | `UART_DIV` | `10'd538` |
| `scripts/coremark_port/core_portme.c` | `EE_TICKS_PER_SEC` | `62030900` |
| `scripts/demo/addr_map.h` | `CPU_HZ` | `62030900u` |
| **`scripts/rtthread/bsp/board.h`** | `BOARD_SYSTEM_CLOCK_HZ` | `62030900u` |

外加：ITER 重算、`build_bitstream.ps1` 的 `expectLines`（常量除法会让 `.text` 差 1 字）。

> **改频率的完整做法**（可命令行完成，不必开 IP Compiler GUI）：
> 改 `pds/RV32I_1/ipcore/pll/pll.idf` 的 `STATIC_RATIO0`，然后
> `D:\pango\PDS_2022.2-SP6.4\bin\ip_generate.exe -i pll.idf`。
> 本设计 `VCO = 27 x RATIOM(2) x RATIOF(21.25) = 1147.5 MHz`，`CLKOUT0 = VCO / RATIO0`。
> 可选档位：`18.5 -> 62.031`（当前）、`19.0 -> 60.395`、`18.0 -> 63.750`。
> [!] 改 `CLKOUT0_REQ_FREQ_basicPage` **无效**，生成器只认 `STATIC_RATIO*`。

---

## 5. 你那边要重新做的事

1. **重跑 PDS 综合**。你的工程带 PPU，资源与时序都和我们不同；我们的 `mem.hex`
   （CoreMark ITER=2000）你大概率要换成游戏固件。
2. **[重点] 重新确认时序余量**。你们的 PPU 当时把 CPU 域的余量吃到只剩 66 ps
   （见 `棋类AI游戏_任务书.md` §3.5）。这次 CPU 侧的改动**净赚了时序**：
   Estimated 54.07 -> 67.78 MHz，所以你们那 66 ps 大概率会大幅缓解。
   **但这必须实测**，别按我们的数字推。
3. **别忘了游戏有独立的固件变体**，别覆盖 CoreMark 那条链（那是性能评分依据）。

---

## 6. 关于"7 级流水线 / 双发射"

2026-09-28 用**探针综合**（临时在关键路径上插寄存器，只做 STA、测完还原）实测过：

| 切法 | Estimated Fmax | 代价 | 结论 |
|---|---|---|---|
| 现状 | 67.78 MHz | — | — |
| 取指地址寄存一拍 | **76.38 MHz（+12.7%）** | 分支惩罚 +1（**+12.5% 周期**）| **打平** |
| 再寄存 ALU 操作数（两刀） | 72.42 MHz | 再 +5.7% | **负** |

**结论：不做。** 第一刀的频率增益刚好被它引入的冒险惩罚吃掉；第二刀没有频率增益，
因为剩下的墙变成了**控制链的高扇出**（`id_redirect` fanout=124、`ex_resolve_taken` 66、
ID/EX 使能网 97/100）——**那是物理问题，跟 ALU 深度无关，插流水级治不了。**

> [!] **方法论警告**：同一份 RTL 两次综合的 Estimated Fmax 差过 **5.7%**（67.78 vs 71.62）。
> **任何小于 ~6% 的"提升"都不可信**，要多次综合取中位数。

**下一步真正对症的是修高扇出**（寄存器/逻辑复制），零语义风险。

---

## 7. 拿不走的

`.sbit` 不入库（9MB/个），所以包里一个比特流都没有。要上板就自己综合：

```powershell
scripts\build_bitstream.ps1 coremark   # 跑分版，会打印 md5
```

**别靠 `generate_bitstream/cpu_top_board.sbit` 这个文件名猜里面是哪一版** ——
它只代表"最后一次综合的那版"，而且**任何一次综合（包括临时探针）都会覆盖它**。
本仓库为此归档了带 md5 的命名版本在 `pds/RV32I_1/bitstreams/`（同样不入库，需自建）。
