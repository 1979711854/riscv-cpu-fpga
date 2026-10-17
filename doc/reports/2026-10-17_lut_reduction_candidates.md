# 减 LUT 候选清单（指标③ = 主分 ÷ LUT）· 2026-10-17

> 用途：`feat/perf-opt` 分支的性能线已被 PDS 判死（见 `2026-10-17_p1_ab_bypass.md` §6），
> 但 **"把分母做小"这条路没死** —— 主分不变、指标③ 直接变大，而且更少 LUT 对布线是正向的
> （本设计 route 占关键路径时延 ~70%，减 LUT 有机会把 76.5 档余量找回来一点）。
>
> [!] **前置条件（硬）**：任何 RTL 改动都要重出位流 ⇒ ILA 的 `.fic` 与演示视频必须重做。
> **先做完 ILA + 视频 + 报告，再动这份清单。** 否则得不偿失。

---

## 0. 分母到底是多少（先统一口径）

| 口径 | LUT | 出处 | 状态 |
|---|---|---|---|
| 交付页 `delivery_rev1028.md` | **7,740**（÷159,800 = 4.84%） | 出 b45941d6 时的人工摘录 | **唯一对外口径，暂不动** |
| 2026-10-17 复现冻结网表 | **8,762** = CLMA 6,497 + CLMS 2,265 | `pds/RV32I_1/run.log` | 与交付页差 1,022，**口径待核**（`p1_ab_bypass.md` §6.3） |

**本清单内部一律用"同一次构建的前后差"做判据**（ΔLUT），不依赖上面哪个绝对值。
对外换算指标③ 时沿用交付页 7,740。

**收益换算**（供心里有数）：减 350 LUT ≈ 指标③ **+4.5%**（8,762→8,412，或 7,740→7,390）。

---

## 1. 先量再改：per-module 面积怎么拿

1. **不用重跑**：`pds/RV32I_1/synthesize/apm_drm_lutram_utilization.log` 已经有
   **全部 LUT-RAM 阵列的实例名/深度/位宽/原语数**（下表就是从这里抄的）。
2. **要 per-module LUT**：PDS GUI → `Tools → Report Area`（工程 `pds/RV32I_1`），
   把 `u_soc` / `u_soc/u_core` / `u_soc/u_bus` / `u_video` 四行的 LUT 数贴回本文件 §2.1。
   这一步约 2 min，**是所有后续判断的分母，先做**。
3. 现在的已知分布（LUT-RAM 部分，硬数字，合计 **494**，占 `Distributed RAM 572` 的 86%）：

| 阵列 | 尺寸 | 原语 | LUT | 备注 |
|---|---|---|---|---|
| `u_soc/u_core/bht_tag` | 256×24 | 24×RAM256X1 + 96×RAM64X1 | **120** | 条件分支预测器 tag |
| `u_soc/u_core/btb_tag` | 256×24 | 96×RAM64X1 | **96** | 间接跳转 BTB tag |
| `u_soc/u_core/btb_target` | 256×31 | 124×RAM64X1 | **124** | 间接跳转目标 |
| `u_soc/u_core/bht_ctr` | 256×2 | 2×RAM256X1 + 4×RAM128X1 | 6 | 2 位计数器 |
| `u_soc/u_core/ras_mem` | 16×32 | 16×RAM32X2 | 16 | 返回地址栈 |
| `u_soc/u_uart_tx/fifo` | **1024×8** | 128×RAM64X1 | **128** | 串口发送缓冲 |
| `u_soc/u_uart_rx/fifo` | 16×8 | 4×RAM32X2 | 4 | 串口接收缓冲 |

---

## 2. 候选清单（按"收益 ÷ 风险"排序）

判据统一写成 **[省] / [损] / [验]** 三行：
**[省]** = 预期 LUT 净减；**[损]** = 允许的拍数/功能代价上限；**[验]** = 验收动作。

### L1 · UART 发送 FIFO 1024 → 512（**首推，零 CPU 风险**）

- **改什么**：`rtl/periph/uart_tx.v` 的 `fifo[0:1023]` 与 11 位指针改 10 位（512 深）。
  `busy` 语义不变。
- **[省] −64 LUT**（128→64 个 RAM64X1）。
- **[损]** 要求：**CoreMark 拍数 0 变化**。依据：CoreMark 的 report 是**计时结束后**才打印，
  背压不影响 `Total ticks`；RT-Thread/五子棋的串口输出每回合几十字节，512 足够。
- **风险**：极低。唯一可见变化是连续大段 printf 时 CPU 多在 `busy` 上等几毫秒。
- **[验]** ① `Total ticks` 仍是 207,611；② 跑一遍五子棋串口日志，确认**无丢字符、无 FIFO 溢出**；
  ③ riscv-tests 49/1/0 + own_tests 8/0；④ 3 个 seed 读 CPU 域 WNS。
- **可选加码**：→ 256（省 −96），代价是 CoreMark 报告会分几次阻塞写完（不影响分数）。

### L2 · BTB 256 → 32 项（**第二推，纯预测器**）

- **改什么**：`core.v` 的 `btb_tag[0:255] / btb_target[0:255] / btb_valid[255:0]`
  → `[0:31]`，`btb_idx_p/w` 从 `if_addr_d[9:2]` 改 `[6:2]`，tag 位宽保持 24（或顺带收窄，见 L3）。
- **[省] −192 LUT**（`btb_tag` 96→12、`btb_target` 124→16）。
- **[损]** 允许 **拍数 ≤ +0.3%（≤600 拍）**。依据：CoreMark 里间接跳转极少，
  BTB 命中率对总分贡献很小；五子棋的 AI 里函数指针也不多。
- **风险**：低（预测器，猜错由 EX 级 §7 目标校验兜底，**不影响正确性**）。
- **[验]** ① `Total ticks` ≤ 208,200；② `own_tests` 的 `btb_indirect` **必须 8/0**；
  ③ riscv-tests 49/1/0；④ 拍数若超 +600，回退到 64 项（省 −144）。

### L3 · BHT tag 24 → 10 位 + 深度 256 → 128（**顺带帮时序**）

- **改什么**：`bht_tag` 存 `id_ex_pc[17:8]`（10 位）而不是 `[31:8]`；
  `bht_tag[0:127]`、`bht_idx` 取 `pc[8:2]`。**必须同时改 `bht_hit_p/w` 两侧的比较**。
- **[省] −100 LUT**（tag 120→20 附近），**且 `bht_hit_p` 的 24 位比较缩成 10 位** ——
  这个比较在 `p_pred_taken → fetch_addr` 的**取指关键路径**上，有额外的小幅时序收益。
- **[损]** 允许 **拍数 ≤ +0.3%**。风险点：tag 变短 + 表变小 ⇒ 别名增多、预测率下降。
  CoreMark 的循环体很小（BHT 工作集 < 64 项），预期影响很小但要实测。
- **风险**：中低（纯预测器，不影响正确性）。**`p_branch && bht_hit_p` 那一路要逐位同源**，
  漏改会出现"命中但取错 counter"的静默错误（只掉性能）。
- **[验]** 同 L2；另加 ④ 看 `+PROF` 里 `mispredict` 计数（基线 1,543）—— 若 mispredict 涨 >300，
  回退 tag 到 16 位（省 −56）。

### L4 · 视频侧（**先量再定，可能是最大的一块**）

- **现状**：`u_video` 一个模块，含 `video_core / ppu / tmds_encoder×3 / outputserdes / sync_vg /
  vram_b32 / vram_dp / vram_pal`，显存 73 KB（DRM）。**LUT 数还没有**。
- **先做**：§1 的 `Report Area`，拿到 `u_video` 的 LUT 数。
- **候选**（按风险从低到高）：
  1. `vram_pal` 调色板 256×24 → 16×24（若 UI 实际只用少数色）——**先统计 `colorbar_gen`/五子棋
     实际用色数**，改完必须 HDMI 实拍对比；
  2. 精灵元数据 FIFO 深度、双缓冲级数（`sx_meta/sy_meta` 那组寄存器）——注意它们是**时序违规
     端点**（今天有 40 条 `u_video` 违规路径落在这些寄存器上），动它们可能同时改善时序；
  3. `tmds_encoder` 三通道能否复用（**不建议**：TMDS 是纯组合 + 高速路径，复用会毁 Fmax）。
- **[损]** 硬门槛：**HDMI 画面逐像素不变**（截图对比）、五子棋可玩、无 vblank timeout。
- **[验]** ① 上板截图对比；② 串口无 `[!] vblank timeout`；③ ΔLUT 记账。

### L5 · CPU 侧其它（**不建议先做，做也收益小、风险高**）

| 候选 | 估算 | 为什么不先做 |
|---|---|---|
| 4 个 `imm_gen` 合并成 2 个 | −40 | 到达级那两个在取指锥上，共享会插 mux |
| 前递 mux 降源（去掉几乎不命中的 WB 级） | −60 | 32 位 × 4 读口，改错就是静默错值 |
| `regfile` 4R2W 降 3R2W | −80 | 双发射要 4 个源，架构不允许 |
| `DIV` 迭代器换成串行移位复用 ALU | −80 | 碰多拍单元，`mc_stall` 死锁风险（约定 45） |

### 明确不做

- 关 BTB / 关 RAS 换面积：CPI 掉得比指标③ 赚得多（上次已实测否证）。
- 降分辨率 / 去 HDMI：场景指标（R104 第一顺位）直接崩。
- 开 Cache 换面积：方向反了。

---

## 3. 统一验收门槛（每项都要过）

| # | 门槛 | 命令 / 出处 |
|---|---|---|
| 1 | ΔLUT **净减 ≥50**（否则不值得扰动布局） | `run.log` 的 `CLMA LUT + CLMS LUT` 前后对比 |
| 2 | `Total ticks` **≤ 207,611 × 1.003**（≤208,200） | `scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem` |
| 3 | 四 CRC 逐位不变 | `e9f5 / e714 / 1fd7` |
| 4 | `riscv-tests 49/1/0`（默认 + `+MEMWAIT=2` + `I+D Cache` 三组） | `scripts\run_riscv_tests.ps1 -EarlyLd -LanebMem ...` |
| 5 | `own_tests 8/0`（含 `btb_indirect`、`hi_fetch_128k`、`timer_irq`） | `scripts\run_own_tests.ps1 -EarlyLd -LanebMem` |
| 6 | 单发射 `300,392` 逐位不变 | `-Single` |
| 7 | **76.5 档 3 个 seed 至少 1 个 WNS ≥ +0.2 ns**（目标是找回余量，不是只减面积） | 见 §4 |

> 只要有一项不过，就回退该项 —— 这份清单的每一项都是**独立提交**，可单点 revert。

## 4. 出流与读数（每次改动后照抄）

```powershell
# [!] 先在独立 worktree 里做，别动主工作树（会与别人切的 branch 打架）
git worktree add D:\_lut feat/perf-opt
cd D:\_lut
git branch --show-current          # 必须是 feat/perf-opt
scripts\build_bitstream.ps1 combined -Iter 3900
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\cpu_top_board.rtr
# 资源：run.log 的 "Device Utilization Summary" 里 CLMA LUT + CLMS LUT
# 换 seed：改 pds/RV32I_1/RV32I_1.pds 的 (_option gplace_seed (_integer N))，清空流程目录后重跑
git worktree remove D:\_lut --force
```

## 5. 建议顺序与工时

| 轮次 | 内容 | 单项机器时间 | 累计收益（估算） |
|---|---|---|---|
| 第 0 步 | `Report Area` 拿 `u_soc / u_video` 的分母 | 2 min | 0（但决定后面怎么做） |
| 第 1 轮 | L1（UART 512） | 10 min 出流 | ΔLUT −64，指标③ +0.8% |
| 第 2 轮 | L2（BTB 32） | 10 min | ΔLUT −192，指标③ +2.4% |
| 第 3 轮 | L3（BHT 128×10） | 10 min | ΔLUT −100，指标③ +1.3%，兼小幅帮时序 |
| 第 4 轮 | L4（视频侧，视 §1 结果定） | 半天起 | 未知，可能最大 |

三轮 L1~L3 合计 **−356 LUT ≈ 指标③ +4.5%**，且不碰 CPU 关键锥（L3 还略帮时序）。
工时：**半天（含回归）**。

## 6. 坑（这批改动特有的）

1. **改 LUT-RAM 阵列必须同时改 tag 比较两侧**（`bht_hit_p` 与 `bht_hit_w`、`btb_hit_p` 与
   `btb_tag` 写侧）。只改一侧 ⇒ 静默错预测，拍数暴涨但 CRC 还是对的，很难查。
2. **`bht_valid`/`btb_valid` 是 256 位向量**（不是数组）：改深度要一起改位宽和 `..._valid[idx]`
   的所有引用，否则 iverilog 只报 warning（位选越界返回 x）。
3. **UART FIFO 的指针是 `2^N + 1` 位**（多一位区分空满）：1024→512 是把 11 位改 10 位，
   `fifo_full/fifo_empty` 的比较式要同步改，别只改数组。
4. **不要一次改两项再量** —— 布局扰动会互相掩盖，必须一项一提交一出流。
5. **指标③ 对外换算之前**，先把 §0 的 7,740 / 8,762 口径核对完（`p1_ab_bypass.md` §6.3），
   否则答辩现场分母说不清。
