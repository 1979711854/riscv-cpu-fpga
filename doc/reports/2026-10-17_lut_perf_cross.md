# 交叉实验：减 LUT 网表 × P1+P3a（CPI −4.58%）· 2026-10-17 深夜

> 分支 **`feat/lut-perf`**（从 `feat/lut` @ `22ea277` 拉出；`feat/lut` 本身**一字未动**，
> 仍与已上板的 `c642c0ac` 一一对应）。
> 目的：回答"**同一颗 4.8% 的 CPI 优化，在少了 808 LUT 的网表上能不能塞进 76.5052 MHz**"。
> 结论先说：**不能，差 0.449 ns（176 个失败端点），Fmax 只有 73.96 MHz。**

---

## 0. 一句话

`feat/lut`（LUT 6,932 / +0.311 ns）+ P1+P3a（拍数 −4.58% / 板上已验证收益真实）
⇒ **拍数 207,155 拿到了，但时序从 +0.311 掉到 −0.449**（Δ −0.76 ns），
LUT 也从 6,932 涨到 7,305（**+373**）。**① 的 +4.8% 仍然拿不到，且这次比在旧网表上更差**
（旧网表 P1+P3a 是 −0.318）。

---

## 1. 做了什么

```powershell
git worktree add D:\_lut_perf -b feat/lut-perf feat/lut
cd D:\_lut_perf
git cherry-pick fa9125a      # P1：A→B 同拍旁路 + 放开同对同址写回
git cherry-pick 27ee172      # P3a：lane B 放 JAL（取指改道 + RAS call）
# 两处都 auto-merge 成功，无冲突
# DESIGN_REV：0x2026_1030（P3a 自带的）→ 改为 0x2026_1032，避免与 perf-opt 旧网表的 1030 撞号
scripts\build_bitstream.ps1 combined -Iter 3900     # 9 min 21 s
```

**为什么不取 P1b**：P1b 是"lane B 是 load 时不旁路"，在旧网表上用 −0.22% 拍数换时序，
但实测 WNS 反而更差（−0.318 → −0.593），本次不叠加它。

---

## 2. 结果

### 2.1 功能（先过功能再出流，避免白跑 10 分钟）

| 判据 | 结果 |
|---|---|
| `region cycles`（`+PROF`，ITER=1） | **207,155**（= perf-opt 的 P1+P3a，逐位相同） |
| 四 CRC | `e9f5 / e714 / 1fd7 / 8e3a` **全对**，`Correct operation validated` |
| 拍数收益 | 217,088 → 207,155 = **−4.58%**（主分 4.6075 → **4.8287**） |
| `region IPC` | 1.265 → **1.326** |
| mispredict | 1,543（与基线相同，缩 BTB 没伤命中率） |
| `own_tests` | **8 / 0**（含 `btb_indirect`、`hi_fetch_128k`、`timer_irq`） |

⇒ **CPI 收益与"减 LUT"完全兼容**：两个改动的功能面不打架。

### 2.2 时序 / 资源（PDS，76.5052 MHz，`gplace_seed 10`，**后来扫到 seed 5 更好，见 §2.3**）

| 项 | `feat/lut`（c642c0ac） | 本次 `feat/lut-perf` | Δ |
|---|---|---|---|
| CPU 域 WNS（Slow） | **+0.311** | **−0.449** | **−0.760** |
| 失败端点 / 总端点 | 0 / 16,670 | **176 / 16,949** | +176 |
| Fmax | 78.3699 | **73.9645** | −4.41 |
| Total LUTs | 6,932（6,744 + 188） | **7,305（7,117 + 188）** | **+373** |
| FF | 3,466 | 3,466 | 0 |
| 约束总判 | All Constraints Met | **Some Constraints Violated** | — |

位流 md5 **`a76bd290d692ca4cd202369873285b7a`**（8.76 MB，2026-10-18 00:07:49）—— **不上板**。

### 2.3 seed 采样（4 个点，赌 0.449 的结果）

`gplace_seed` 逐个改（文本替换，**不要 `git checkout` 该 `.pds`**），每次完整 `gen_bit_stream` 约 10 min：

| seed | WNS（CPU 域 Slow） | failEP | totalEP | Fmax | 判定 |
|---|---|---|---|---|---|
| **5** | **−0.259** | — | 16,960 | **75.0188** | ✅ **本区间最优，但仍差 0.259** |
| 10 | −0.449 | 176 | 16,949 | 73.9645 | 差 |
| 8 | −0.613 | — | 16,956 | 73.0780 | 差 |
| 16 | −0.674 | — | 16,940 | 72.7537 | 差 |

**排序与旧网表完全一致**（旧网表 40 seed 的最优也是 seed 5，其次 10、8、16）⇒ 布局质量是**设计形状**决定的，
换网表后"哪个 seed 好"高度可复用，**靠扫 seed 补 0.449 ns 不现实**：本区间最优点仍差 0.259，
而 40 seed 在旧网表上的全距只有 0.26 ns。

⇒ **种子路到此为止**（共 4 次出流 ≈ 40 min 机器）。.pds 已复原为 `gplace_seed 10`（保持与本报告 §2.2 一致）。

---

## 3. 为什么失败（比"没收敛"更有信息量的三条）

1. **P1/P3a 的代价不是 LUT 数量，是"取指环上的新腿"**。这两项改的都是"谁来改 `fetch_addr` / `if_addr_d`"：
   P1 让 lane B 的操作数能来自 `alu_result`，P3a 让 lane B 的 JAL 直接改道。**减 LUT 减的是预测器 RAM 和 UART FIFO，
   跟这条腿无关** ⇒ 减下来的 808 LUT 一点忙都帮不上，实测反而因为布局重排更差 0.13 ns。
2. **"减 LUT 帮时序"这个预期在 L2 就已经被证伪过一次**：L2 减 566 LUT，WNS 从 +0.460 掉到 −0.099。
   这次的 Δ −0.76 ns 是同一现象的第二次实例，别再把它当"顺带好处"。
3. **P3a 在旧网表上"时序免费"（P1 −0.318 / P1+P3a −0.318），在新网表上未必**：
   BTB 缩到 32 项后索引只用 `PC[6:2]`，JAL 改道与它的交互改变了关键路径形状。**跨网表结论不可迁移。**

---

## 4. 还剩什么路（按性价比）

| 方案 | ① | ② | ③ | 成本 | 判断 |
|---|---|---|---|---|---|
| **维持现状**（rev1028/rev1029） | 4.6075 | 78.37 | 0.6647 | 0 | **推荐** |
| 扫 seed 救本次结果（8/16/5…，每点 9 min） | 4.8287 | ~74~75 | 0.6647 | 30~45 min | 需要补 0.449 ns，历史 seed 极差 0.24~0.5 ⇒ **大概率还是负**，可赌一次 |
| 降到 ~74 MHz 上板 | **4.8287（+4.8%）** | **≈74（−5.2%）** | 0.6647 | 1 次出流 + 板测 | ① 与 ② 对冲；按 R104"资源/时序优先"**不划算** |
| 只取 P1（不取 P3a）再出流 | 4.7801 | ? | 0.6647 | 9 min | 旧网表上 P3a 时序免费，预计这里也一样 ⇒ 期望低 |
| 结构级改取指（IF 加一级 / 预取队列） | 才能进 90+ MHz | ↑ | — | 3~5 天 | 本届不做 |

**结论**：`feat/perf-opt` 的判死在新网表上依然成立，而且差额更大。
**① 这条线的现实天花板就是 4.6075**，除非重写取指级 —— 这一点现在有两张网表的实测支撑。

---

## 5. 复现

```powershell
git worktree add D:\_lut_perf -b feat/lut-perf feat/lut
cd D:\_lut_perf
git cherry-pick fa9125a 27ee172
# 功能（必须先过）
powershell -File scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem
cd sim; vvp tb_coremark_dual_earlyld_lanebmem.vvp "+ITER=1" "+IMEM=programs/imem.hex" `
        "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+PROF"        # region cycles 必须 207,155
cd ..
powershell -File scripts\run_own_tests.ps1 -EarlyLd -LanebMem  # 8/0
# 时序
scripts\build_bitstream.ps1 combined -Iter 3900
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\cpu_top_board.rtr
```

> [!] 读 `.rtr` 别只看第一个 `Setup Summary`：本文件的慢角 CPU 行是
> `clk|u_pll/u_gpll/CLKOUT0_Inferred → 自身` 那一行（本次 −0.449 / 176 / 16,949），
> 用 `capture_seed_timing.ps1` 读最稳；手抄容易抓到跨域或快角那几行。
