# 交接 · 2026-10-18 → 下一个会话（rev1029 收尾 / 五子棋新版待接）

> 本文写给**零上下文**的下一个会话。先读 §1 三句话，再按 §4 的任务表干活。
> 本文件在 **`feat/lut`** 与 **`feat/mem128k`** 两条分支上**内容逐字相同**（保证日后 `--no-ff` 合并不冲突）；
> 若只在一侧看到，用 `git --no-pager show <branch>:doc/reports/2026-10-18_handoff_next.md` 取另一侧。

---

## 1. 三句话

1. **交付线（`feat/mem128k`）当前交付物仍是 rev1028 `b45941d6`**（76.5052 MHz、LUT 7,740、主分 4.6075、Fmax 78.3269）。
2. **rev1029 候选已换成 `273f6c5a`（seed 29）并上板通过**：LUT **6,932**（−10.4%）、指标③ **0.6647（+11.7%）**、
   ② **78.6596（+0.37%）**、① 逐位不变（`Total ticks 846,440,591`、四 CRC 全对）。**只差四项板级收尾才能合并。**
3. **CPU 性能已封顶**：① 4.6075（两张网表 + 5 seed 实测）、② 78.6596（40 seed 全采）、③ 0.6647（低风险额度用完）。
   别再在 CPU 上花机器时间。

---

## 2. 分支 / 提交 / 位流（唯一身份表）

| 分支 | tip | 角色 |
|---|---|---|
| `feat/mem128k` | `8a60d01` | **交付线**：rev1028 `b45941d6`（RTL 与归档位流一一对应，**不许切分支/跑 PDS/`git checkout` `.pds`**） |
| `feat/lut` | `319b59a` | **候选线**：rev1029 `273f6c5a`；`doc/reports/2026-10-17_delivery_rev1029.md` 是该校数字源 |
| `dualissue` | `e78c0e5` | 应用/界面线（RTL 停在 rev1027，队友在改 `scripts/gomoku/**`） |
| tag `deliver-b45941d6` | `bd59ce3` | rev1028 交付锚点（**合并时从这里 checkout 出交付树**） |
| tag `archive/perf-opt` | `6c3d375` | P1/P1b 性能实验（已判死，分支已删） |
| tag `archive/lut-perf` | `18f79eb` | 减 LUT × P1+P3a 交叉实验（已判死，分支已删） |
| `origin/main` | — | 远古无关历史，只读，**禁强推** |

| 位流 md5 | 名称 | 状态 |
|---|---|---|
| `b45941d6` | rev1028 单一位流 | **当前交付**（已上板双路径） |
| `c642c0ac` | rev1029 seed 10 | 前一候选（已上板；被 273f6c5a 取代） |
| **`273f6c5a`** | **rev1029 seed 29** | **新候选，已上板**（`bitstreams/lut_combined_76mhz_seed29_273f6c5a.sbit`） |
| `bacbcaee` | perf-opt P1+P3a | 技术储备，WNS −0.318，**勿烧** |

工作树：主 `d:\riscv-cpu-fpga_merged`（= `feat/mem128k`）、`D:\_lut`（= `feat/lut`）、
`D:\_lut_base`（detached 干净基线）。`D:\_lut_perf`、`D:\_wt_*` 已删除。

**[!] 目录陷阱（2026-10-18 复核）**：
- `273f6c5a` 的 `.sbit` **只在 `D:\_lut\pds\RV32I_1\bitstreams\`**，`d:\riscv-cpu-fpga_merged` 工作树里**没有这个文件**
  （`.sbit` 不入库，随分支工作树走）。烧候选流前先确认路径，别在 merged 树里空找。
- `scripts\_seed_sweep_40.ps1`（40 seed 初筛脚本）**只在 `feat/lut`**，merged 树里没有。
- `d:\riscv-cpu-fpga_merged` 工作树常驻一个 `.pds` 脏改动（PDS 跑完重写的时间戳/注释，55+/56−）。
  **提交任何东西之前先 `git restore pds/RV32I_1/RV32I_1.pds`**，别把它顺手带进 commit。

---

## 3. 数字口径（不许混用）

| 指标 | rev1028 交付 | rev1029 候选（`273f6c5a`） | 来源 |
|---|---|---|---|
| ① 主分 / 经典分 | **4.6075 / 352.5** | 同（逐位不变） | `Total ticks 846,440,591` ÷ 3,900 ÷ 76.5052 |
| 每迭代拍数 | 217,036（仿真 217,088） | 同 | 板 / 仿真 |
| ② CPU 域 WNS | +0.304 ns / 0 EP / 21,135 | **+0.358 / 0 / 16,703** | `.rtr` 慢角 CPU 行 |
| ② Fmax | 78.3269 | **78.6596（+0.37%）** | 同 |
| ③ 主分÷千LUT | 0.5953（LUT 7,740） | **0.6647（LUT 6,932，+11.7%）** | 报道口径 A；B 口径 50.85 |
| 资源 | LUT 7,740 / FF 3,692 / DRM 165.5 | LUT 6,932（6,744+188）/ FF 3,466 / DRM 165.5 | `run.log` 的 `Total LUTs` |
| 板上日志 | `doc/board/uart_20261017_190201.txt` | `doc/board/uart_20261018_144114.txt` | — |

陷阱：串口打的 `Iterations/Sec 354` 是整数秒截断，**报告一律写 352.5 / 4.6075**；
`CLMA+CLMS` 是物理站点口径，**资源只认 `Total LUTs`**。

---

## 4. 剩余任务（合并前必须全绿）

| 优先级 | 任务 | 状态 | 谁做 |
|---|---|---|---|
| **P0** | 五子棋**整局**（人机 / 对战各一局） | ⛔ **等队友新版**（当前板上流只验到 banner + `menu=HUMAN`） | 人 + 板 |
| **P0** | HDMI 实拍 | ⬜ 串口反复出 `[!] vblank timeout`（rev1028 起就一直在），**必须眼见为实** | 人 + 相机 |
| **P1** | ILA `.fic`（必须与 `273f6c5a` 同源） | ⬜ 探针清单需按 **128 KB / 17 位 PC** 重排（`ila_analysis.md` 仍是 32 KB / 15 位） | 我出清单 + GUI 生成 |
| **P1** | 演示视频 | ⬜ 一颗流：五子棋 → 复位+按住 SW6 → 11.06 s 跑分 → 回五子棋 | 人 |
| **P2** | 队友新版五子棋接入 → **重出一颗新流** | ⬜ 见 §5 | 我 |

**合并动作（四项全绿后一次做完，别顺手做一半）**

```powershell
git tag deliver-273f6c5a feat/lut
git merge --no-ff feat/lut -m "merge feat/lut: rev1029（LUT -808, 指标③ +11.7%, Fmax +0.37%, 拍数不变）"
# 合并后：delivery_rev1029.md 成为本线唯一数字源；rev1028 页标历史；README rev1029 章节随分支进来
```

---

## 5. 队友五子棋新版到了以后（重要：会换位流）

1. 只在 `dualissue`（或队友给的分支）上拉取 `scripts/gomoku/**`，**不要动 `rtl/`**；
2. 把 gomoku 源码合到 `feat/lut`，跑 `scripts/gomoku/build.ps1` → 生成新 `mem.hex`；
3. **必须重出位流**（`scripts\build_bitstream.ps1 combined -Iter 3900`，`gplace_seed` 保持 **29**）：
   `mem.hex` 变 ⇒ md5 必变；**布局与时序应不变**（RAM 内容不影响网表），但仍要读一次 `.rtr` 确认；
4. 新 md5 / 新 FW 时间戳写进交付页与位流索引；**旧 `273f6c5a` 仍保留归档**；
5. 重跑 CoreMark（`ITER=1` 四 CRC + 拍数 217,088）+ `own_tests` 8/0，再上板验双路径；
6. **此时 `.fic` 必须重做**（与最终位流同源）——所以 ILA 最好排在五子棋定稿之后再定稿。

---

## 6. 本轮新增的 8 条坑（都踩过，别再踩）

1. **多 seed PDS 只 route 被选中的那颗**：落选 `seed_N/` 里没有 `cpu_top_board.rtr`；每 seed 的
   `run.log` 里有 `Worst slack is N`（placement 后），但要**始终覆盖**地抢拷，按 tag 只拷一次会拿到半截文件。
2. **placement slack ≠ WNS**：拟合斜率 ≈ 0.15 ps/ps（898 ps → +0.358；575 → +0.311）。只用于排序。
3. **`DESIGN_REV` 每 +1 都可能吃掉 0.35 ns**：实测 `0x20261028 → 2029`（只差 1 个 LUT）把 +0.358 打到 +0.005，
   把 seed 10 的 +0.311 打到 −0.012。**永远不要为了 banner 好看去动这个常量。**
4. **位流身份 = md5 + 固件内嵌时间戳**：banner 的 `RTL=0x20261028` 对新旧流是同一个值，**分不出来**。
5. **`generate_bitstream/cpu_top_board.sbit` 只代表"最后一次综合的那版"**：做 seed 试验会把它覆盖
   （现在里面是 seed 3 的 `ff99f52b`）。**烧板只从 `pds/RV32I_1/bitstreams/*.sbit` 拿。**
6. **同一 netlist + 同一 seed，WNS 可复现**（两次出流逐位相同）；但 **md5 会因固件重新构建而变**。
7. **`.pds` 的 seed 选项要文本替换、不要 `git checkout` 该文件**；PDS 跑完会重写 `.pds`，实验后记得复原。
8. **`bitstreams/README.md` 是 UTF-8 无 BOM / CRLF**（不是 GBK）；按 UTF-8 编辑安全，做 GBK 转码才会写坏。

---

## 7. 常用命令

```powershell
# 出流（标准流程；会重编固件，md5 必变）
scripts\build_bitstream.ps1 combined -Iter 3900

# 读 CPU 域时序（唯一判据行）
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\cpu_top_board.rtr

# 功能（改 RTL 后必跑）
powershell -File scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem
cd sim; vvp tb_coremark_dual_earlyld_lanebmem.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+PROF"
powershell -File scripts\run_own_tests.ps1 -EarlyLd -LanebMem     # 期望 8/0

# 上板抓日志（60~300 s）
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60

# 40 seed 初筛（只在 feat/lut 有该脚本；已做完，除非换网表否则不用再跑）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\_seed_sweep_40.ps1 -StartSeed 1 -Batches 5 -Times 8
```

---

## 8. 已冻结的决定（不要重新讨论）

1. **不换回 85.0051 MHz**（8 seed 已证伪，−0.796 ns 收敛不了）。
2. **不做 Cache**（评估档主分 4.291 / 经典分 325.96，均低于现交付）。
3. **不做 P3b / 双 load / 取指单加法器**（判死，见 `2026-10-17_p1_ab_bypass.md`）。
4. **不升 `DESIGN_REV`**（见坑 3）。
5. **CPU 性能不再投入**（三项都到顶）。
6. **两线未合并前，对外只说交付 = rev1028 `b45941d6`**；rev1029 是"已过板测的候选"。
