# rev1029 网表 40 seed 采样（指标② Fmax 空间）· 2026-10-18

> **状态：⏳ 进行中**（5 批 × 8 seed，第 2 批跑到一半）。本文件先立骨架，
> §3 的 40 行排名与 §4 的真实 WNS 等跑完再填。
>
> 网格 = **`feat/lut` 的 rev1029**（`c642c0ac`，LUT 6,932）——**只改 `pds` 的 `gplace_seed`，RTL 一字不动**。

---

## 0. 一句话（待填）

> 40 个布局 seed 的 CPU 域软顶是 **____ ns**（seed ___），对应 Fmax **____ MHz**；
> 相对 seed 10 的 +0.311 ns / 78.3699 MHz 是 **+____ ns / +____%**。
> 判定：**（能 / 不能）推到 +0.5 ns（Fmax ≥ 80.2）**。

---

## 1. 目的与判据

| 项 | 现在（rev1029，seed 10） | 本轮目标 |
|---|---|---|
| CPU 域 WNS | **+0.311 ns**（0 失败端点 / 16,670） | **≥ +0.5 ns** |
| Fmax | **78.3699 MHz** | **≥ 80.2 MHz（+2.4%）** |
| 指标③ | 0.6647 | 不变（换 seed 只动布局，不动 LUT/FF） |
| 指标① | 217,088 拍 / 4.6075 | 不变（功能与拍数必须逐位一致） |

**判据**：只认 `.rtr` 里 **Slow Corner、`clk|u_pll/u_gpll/CLKOUT0_Inferred → 自身`** 那一行；
`totalEP` 必须仍在 16.7k 量级（说明网表没变）；上板前还要复跑 CoreMark 拍数与四 CRC。

---

## 2. 方法（两个已踩的坑，别再踩）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\_lut\scripts\_seed_sweep_40.ps1 -StartSeed 1 -Batches 5 -Times 8
```

- `.pds` 里写 `gplace_times 8` + `parallel 4` + `gplace_seed S`，5 批覆盖 **seed 1~40**；**实测 ~20 min/批**（不是 6 min）。
- **坑 1**：`gplace_times > 1` 时，PDS **只对被选中的布局做 route**，落选 seed 目录里**没有 `cpu_top_board.rtr`**
  ⇒ 想"抢拷每 seed 的 .rtr"会抓空（第一版就是这么废掉的）。
- **坑 2**：每 seed 的 `run.log` 里有 `Worst slack is N`（detailed placement 后），**但必须"始终覆盖"地抢拷**；
  按"每个 tag 只拷一次"会拷到刚建目录时的半截文件（没有 slack 行，全是 `none`）。
- **placement slack 只能排序，不能当 WNS**（不含布线寄生）：已知 seed 10 是 575 ps → 实际 +0.311；
  seed 16 是 311 ps → 实际 +0.069；seed 8 是 247 ps → 实际 +0.147（**非严格单调**）。
- 种子的"好坏次序"跨网表可复用（旧网表 40 seed 的次序是 5 > 10 > 8 > 16，与本次一致）。

---

## 3. 初筛结果（placement worst slack，ps）

> 自动产物：`pds/_capture_40seed/slack_ranking.txt`；下表**跑完后按 Slack 降序补齐 40 行**。

| 排名 | seed | slack (ps) | 备注 |
|---|---|---|---|
| 1 | `seed_12` | **831** | 批 1；若 slope 成立，预计真实 WNS ≈ +0.54（**优先验证**） |
| 2 | `seed_3` | 755 | 批 0 |
| 3 | `seed_6` | 670 | 批 0 |
| 4 | `seed_14` | 658 | 批 1 |
| 5 | `seed_10` | 575 | **当前交付 seed，实测 +0.311**（校准点） |
| 6 | `seed_7` | 574 | 批 0/1 都在榜（同名不同批，注意去重） |
| 7 | `seed_13` | 537 | 批 1 |
| 8 | `seed_1` | 511 | 批 0 |
| 9 | `seed_2` | 506 | 批 0 |
| 10 | `seed_15` | 473 | 批 1 |
| 11 | `seed_9` | 332 | 批 1 |
| 12 | `seed_16` | 311 | 实测 **+0.069**（校准点） |
| 13 | `seed_8` | 247 | 实测 **+0.147**（校准点） |
| 14 | `seed_5` | 229 | 批 0 |
| 15 | `seed_11` | −60 | 批 1 |
| 16 | `seed_4` | −182 | 批 0 |

（共 16 个点已入账，剩 seed 17~40。）

---

## 4. 验证：top N 单独 route 的真实 WNS（待填）

| seed | WNS (ns) | 失败端点 | Fmax | 位流 md5 | 是否 ≥ +0.5 |
|---|---|---|---|---|---|
| 12 | | | | | |
| 3 | | | | | |
| 6 | | | | | |

验证命令（每点约 6 min，`gplace_times` 删掉、只留 `gplace_seed`）：

```powershell
# 改 .pds：删除 (_option gplace_times ...)，保留 (_option gplace_seed (_integer 12))
pds_shell.exe -project RV32I_1.pds -run gen_bit_stream
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\cpu_top_board.rtr
```

---

## 5. 结论与后续动作

- **若最高 ≥ +0.5 ns**：用该 seed 重出 `combined` 位流 → 复跑 CoreMark（拍数必须仍 217,088、四 CRC 全对）
  → 上板复测（`Total ticks 846,440,591` + 四 CRC）→ 更新 `2026-10-17_delivery_rev1029.md` 的 ② 与 md5
  → 旧 `c642c0ac` 降为历史档。**RTL 不变，DESIGN_REV 仍是 `0x20261028`，身份只能靠 md5 区分（注意）。**
- **若最高仍 ~+0.3x**：② 收口，写明"40 seed 软顶 +0.__ ns"，Fmax 78.4 定稿，不再花机器时间。
- 纪律：全过程**不碰 `feat/lut` 的 RTL**；只改 `.pds` 的 `gplace_seed`（文本替换，**不要 `git checkout` 该 `.pds`**）。

---

## 6. 复现要点

- 采样脚本：`scripts/_seed_sweep_40.ps1`（v2，始终覆盖抢拷 `seed_N/run.log`）
- 排名：读每个 log 里**最后一次** `Worst slack is N`
- 判定：`capture_seed_timing.ps1 -Parse <rtr>` 输出的 **CPU 域那一行**（不是视频、不是快角）
