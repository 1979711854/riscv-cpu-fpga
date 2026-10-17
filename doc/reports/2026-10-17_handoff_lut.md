# 交接 · 指标③ 减 LUT（`feat/lut`）→ 下一个会话

> **一句话**：在交付锚点 `deliver-b45941d6` 上把 LUT 从 **7,740 减到 6,932（−10.4%）**，
> 指标③ **+11.7%**、拍数与四 CRC 逐位不变、时序 +0.304→**+0.311**；候选位流 **`c642c0ac`** 已出、已归档，
> **只剩上板验证 → 改交付页 → 重做 ILA/视频/报告**。
>
> 过程与全部数据见 `doc/reports/2026-10-17_lut_rounds.md`（含失败记录与门禁）。
> 交付页 `2026-10-17_delivery_rev1028.md` 仍是旧位流的数字，**上板通过前不许改**。

---

## 1. 现在在哪

| 项 | 值 |
|---|---|
| 分支 | **`feat/lut`**（从 `deliver-b45941d6` = `bd59ce3` 拉出；交付线 `feat/mem128k` 一字未动） |
| 提交 | `1548b7a`（文档+工具）← `e7c35a2`（L2+L3）← `5f94fe9`（L1）← `bd59ce3` |
| 工作树 | 主工作树 `d:\riscv-cpu-fpga_merged`（仍在 `feat/mem128k`，**干净**）；`D:\_lut`（= `feat/lut`）；`D:\_lut_base`（detached，干净基线用） |
| 候选位流 | `D:\_lut\pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`，md5 **`c642c0ac603fcdc677941ae8f0241a7e`**（9,188,552 B，2026-10-17 23:27:50） |
| 归档副本 | `D:\_lut\pds\RV32I_1\bitstreams\lut_combined_76mhz_seed10_c642c0ac.sbit`（+ 同名 `_timing.rtr`；`.sbit` 被 gitignore） |
| 状态 | **仍未上板**。2026-10-17 23:33 那份板上日志（`Total ticks 807,669,047`）来自**另一颗位流** `bacbcaee`（perf-opt 的 P1+P3a 档），**不是** `c642c0ac` —— 判据见 §8 |

---

## 2. 数字（唯一口径）

| 量 | 旧交付 `b45941d6` | 候选 `c642c0ac` | Δ |
|---|---|---|---|
| LUT（logic + LUT-RAM） | 7,740（7,168 + 572） | **6,932（6,744 + 188）** | **−808（−10.4%）** |
| FF | 3,692 | **3,466** | −226 |
| DRM | 165.5 | 165.5 | 0 |
| WNS（CPU 域，seed 10） | +0.304 | **+0.311** | +0.007 |
| Fmax | 78.3269 | **78.3699** | +0.043 |
| totalEP / failEP | 21,135 / 0 | **16,670 / 0** | −4,465 |
| 每迭代拍数（`+PROF`） | 217,088 | **217,088** | **0** |
| 指标③-A（主分 ÷ 千 LUT） | 0.5953 | **0.6647** | **+11.7%** |
| 指标③-B（完整分 ÷ 千 LUT） | 45.54 | **50.85** | **+11.7%** |
| 四 CRC | `e9f5 / e714 / 1fd7 / 8e3a` | 同 | 0 |

三段改动：L1 `uart_tx` FIFO 1024→512（−82）；L2 BTB 256→32 项（−566，**单独不收敛**）；L3 BHT tag 24→8 位、深度仍 256（−160，把时序救回 +0.311）。

---

## 3. 已冻结的决定

| 决定 | 值 |
|---|---|
| 减 LUT 到此为止 | 低风险额度已用完；再挖要动 `u_core` 胶合（6,100）或 `regfile`（1,256），风险不划算 |
| 不换 seed | 8 / 10 / 16 三点实测：**+0.147 / +0.311 / +0.069** ⇒ seed 10 仍最优，`RV32I_1.pds` 已复原为 10 |
| 不抬频 | 保持 76.5052 MHz（80/85 历史上已证伪；抬频要重算 ITER + 重出流 + 重板测，收益 +2~5% 不值得在本轮再赌） |
| L2+L3 是一个交付单元 | 只回退 L3 会回到 L2 单独的 **−0.099 / 11 失败端点**，不可交付 |
| 视频侧不动 | `u_video` 只占 343 LUT（4.4%），TMDS 改动会毁 HDMI/Fmax |

---

## 4. 剩余任务（按依赖排序）

| 优先级 | 任务 | 产出 | 备注 |
|---|---|---|---|
| **P0** | **上板验证 `c642c0ac`** | 串口日志落到 `doc/board/uart_*.txt` | 清单见 `2026-10-17_lut_rounds.md` §11.3；期望 `Total ticks 846,440,591`、四 CRC 不变 |
| **P0** | 五子棋 + HDMI 板测 | 两条路径都通 | 预测器缩表只应影响命中率 |
| **P1** | 更新交付页 | `delivery_rev1028.md` → 新 LUT/③/Fmax/md5 | **必须在上板通过之后**；同时改名/新增 rev1029 归档章节 |
| **P1** | ILA `.fic` + 演示视频 | 绑定新位流 | 旧的全部作废（RTL 变了） |
| **P2** | 报告/PPT 正文 | 按 R104 顺序 | ③ 的叙事：`7,740→6,932, +11.7%`，并如实给"拍数不变" |

---

## 5. 硬约束与陷阱（本分支新增，排在旧 12 条之前看）

1. **减 LUT 与时序非单调**：L2 减了 566 个 LUT，WNS 反而从 +0.460 掉到 **−0.099（11 个失败端点）**；再叠一个 −160 的 L3 才回到 +0.311。**任何一轮都必须实测**，不能推。
2. **`pds/` 目录里的历史产物会骗人**：主干工作树里的 `8,133 / 8,762` 就是非冻结构建的残留。**引用任何资源/时序数字前，先确认这份 `run.log` / `.rtr` 是哪次、哪份 RTL 跑出来的。**
3. **交付页分母 7,740 是对的**（= logic 7,168 + LUT-RAM 572），已在干净工作树复现并对齐交付页四个数（+0.304 / 0 / 78.3269 / 21,135）。
4. **深层 LUT-RAM 的真实成本 ≈ RAM 单元 × 2**：256 深的表每位要"4×RAM64X1 + 16:1 mux + 译码"，mux/译码会变成逻辑 LUT。缩深度比缩宽度贵（L3 的 128 项版就是因此多掉 804 拍）。
5. **改 BHT/BTB 必须两侧同改**（`*_hit_p` / `*_hit_w` 或 `*_idx_p` / `*_idx_w`），只改一侧 = 静默错预测（拍数暴涨、CRC 仍对）。
6. **别再 git checkout `pds/RV32I_1/RV32I_1.pds`**（会把 `gplace_seed` 退回 5）；改 seed 用文本替换该行。
7. **烧之前先核 `md5`，上电先核 banner 的 `RTL=`**：`generate_bitstream\cpu_top_board.sbit` 只代表"最后一次综合的那版"。本次已实际踩中——2026-10-17 23:33 的板上日志是主干工作树里 perf-opt 的 `bacbcaee`（`RTL=0x20261030` / WNS −0.318），不是候选流 `c642c0ac`（`RTL=0x20261028`）。详见 §8。
8. 旧 12 条（`2026-10-17_handoff_next_session.md` §5）继续有效：固件冻结窗口、Fmax 只认 CPU 域那一行、分数口径 352.5/4.6075、资源两个口径、PS 5.1 的 BOM/EAP、同一 PDS 工程不能并发等。

---

## 6. 常用命令

```powershell
# 上板
scripts\serial_monitor.ps1 -Port COM4 -Seconds 60

# 重出候选流（seed 10 已钉在 .pds；combined = boot + CoreMark(ITER=3900) + RT-Thread）
cd D:\_lut; scripts\build_bitstream.ps1 combined -Iter 3900

# 读时序（只认 CPU 域那一行）
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\cpu_top_board.rtr

# 资源（逻辑口径）与分模块
Select-String -Path pds\RV32I_1\run.log -Pattern "Total LUTs|LUTs as logic"
python scripts\lut_breakdown.py pds\RV32I_1\synthesize\cpu_top_board_syn.vm --depth 2

# 只量 ΔLUT（1 分钟，不布线）
pds_shell.exe -project RV32I_1.pds -run dev_map

# 功能回归三件套
powershell -File scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem   # 后再手动 +PROF 读 region cycles
powershell -File scripts\run_own_tests.ps1 -EarlyLd -LanebMem          # 8/0
powershell -File scripts\run_riscv_tests.ps1 -EarlyLd -LanebMem        # 49/1/0
```

---

## 7. 需要人确认 / 收尾事项

1. **上板**：需要人拿板子烧 `c642c0ac`（我无法操作硬件）。
2. **工作树清理**（确认不再迭代后）：
   ```powershell
   git worktree remove D:\_lut --force
   git worktree remove D:\_lut_base --force
   ```
   `D:\_lut` 里有两处未提交的构建副产物：`pds/RV32I_1/RV32I_1.pds`（时间戳）、`pds/RV32I_1/mem.hex`（固件内嵌版本串 2 行，行数仍 39,420）—— 随工作树删除即可。
3. **seed 继续扫**：只跑了 8/10/16 三点。若之后想追指标②，可再扫 5/24 等（每点 10 分钟），但按现在数据期望很低。

---

## 8. 上板记录：2026-10-17 23:33 的日志**不属于本候选流**（重要）

`doc/board/uart_20261017_233332.txt` 抓到的是：

```
[build] FW=COREMARK RTL=0x20261030      <-- [!] 不是 0x20261028
Total ticks      : 807669047            <-- 每迭代 207,094
[0]crcfinal      : 0xbd59               <-- 与 c642c0ac 无关
Correct operation validated
```

**证据链（三条独立判据同时指向同一颗流）**：

| 判据 | 板测日志 | 主干工作树里那颗 `bacbcaee` | 本候选流 `c642c0ac` |
|---|---|---|---|
| `mimpid` 的 `RTL=` | **0x20261030** | 0x20261030（perf-opt P3a 起的 rev） | **0x20261028** |
| 每迭代拍数 | **207,094** | 207,155（仿真，P1+P3a） | **217,088** |
| 其他 | — | WNS **−0.318** / Fmax 74.69 / LUT 8,133 | WNS **+0.311** / 78.37 / LUT 6,932 |

⇒ 烧的是 **`d:\riscv-cpu-fpga_merged\pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`（md5 `bacbcaee…`，20:05:16）**，
即性能线**已判死**（时序不收敛）的那颗 P1+P3a 位流；`D:\_lut` 下 23:27:50 出的 `c642c0ac` **没被烧过**。

**这次日志唯一能用的结论**（可写进报告附录，必须标"非交付"）：
P1/P3a 的 CPI 收益在板上是真的 —— 807,669,047 拍 = 10.5571 s，经典分 **369.4**、主分 **4.8287 CoreMark/MHz**，
四 CRC 全对；但那张网表 **WNS −0.318 ns（11 个 seed 上都出不了收敛域）**，所以只能作技术储备。

**教训（已并入 §5 陷阱）**：
`generate_bitstream\cpu_top_board.sbit` 这个名字只代表"最后一次综合的那版"，
主工作树里现在躺着的是 perf-opt 的产物。**烧之前必须对两件事**：
① `md5`（本次应为 `c642c0ac603fcdc677941ae8f0241a7e`）；
② 上电后串口 banner 的 **`RTL=0x20261028`** —— 这一行是最便宜、最不会骗人的自证。

### 8.1 待办（顺序）

1. 烧 `D:\_lut\pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`（`c642c0ac`，23:27:50）；
2. 上电先看 banner：`RTL=0x20261028` 才算对；
3. 按住 SW6 + SW3 跑 CoreMark，期望 **`Total ticks 846,440,591`**（±0）、四 CRC `e9f5/e714/1fd7/8e3a`；
4. 松开 SW6 复位进五子棋，确认 heap 4840 / `[hb] alive` / HDMI 正常；
5. 过了再动交付页。
