# 会话状态 —— 2026-10-13（A1 集成 + 板上验证 + Cache 实验 + BTB/RAS 勘察）

> 接 `2026-10-12_session_state.md`。**本会话的里程碑已收口**：A1 集成、板上实测通过、
> Cache 两版上板、BTB/RAS 前置勘察全部完成并 push（`aaee550`，与 origin 一致）。
> ~~未完成的是 BTB/RAS 任务书 + 交接压缩包~~ —— **当晚会后已补完，且多做了一件计划外的
> （队友 T1/G3 五子棋包的验证 + 整合 + 首次上板），见 §5**。

---

## 1. 一句话

**把队友 2026-10-13 的交接包（A1 乘法器 II=1 流水线）并进主线并板上验证通过 ——
365.93 CoreMark（较 A1 前 +4.00%）；顺手把 Cache 两版也上了板，并且查清了
"BTB 该怎么做"这个之前只有估算的问题（答案是：RAS，不是 BTB）。**

---

## 2. 本次会话做了什么

| # | 事项 | 结果 |
|---|---|---|
| 1 | 并入队友交接包（`022cafe` 分叉，11 commit，RTL 只动 `multiplier.v`/`core.v`/`csr_file.v`）| 合并提交 `b594f7b`；校验 `rtl/` 与交接包**逐字节一致** |
| 2 | 板上实测 A1 | **365.93 分**（位流 `bcd8fdd2`，`RTL=0x20261017`），提交 `2b99887` |
| 3 | 全仓口径同步到 A1 之后 | 26 文件；`365.85/板级待验` 清零 |
| 4 | 新增 `scripts/flash.tcl`（无头烧录）+ 写进 `board_bringup.md` | 语法取自官方《Fabric Configuration User Guide》§4.5.1/4.5.2/4.6 |
| 5 | **Cache 两版上板**（D-only @85MHz / I+D @76.5MHz）| 提交 `6e90b66` —— 见 §4.1 |
| 6 | **BTB/RAS 前置勘察**：`+JALRTRACE` 探针 + 局部性分析 | 提交 `aaee550` —— 见 §4.2 |

---

## 3. 当前口径（A1 之后）

### 四条并列基线（计时区间拍/迭代，仿真）

| 配置 | 拍/迭代 | 效率 CoreMark/MHz | 怎么跑 |
|---|---|---|---|
| **双发射 + `EARLY_LD`（默认 = 板上口径）** | **232,345** | **4.304** | `run_coremark.ps1 -Iter 1 -EarlyLd` |
| 双发射 + `EARLY_LD=0` | 252,730 | 3.957 | 去掉 `-EarlyLd` |
| 单发射 | 303,140 | 3.299 | 加 `-Single` |
| 双发射 + I+D Cache | 235,628 | 4.244 | 加 `-DCache -ICache -EarlyLd` |

### 板上实测（都是 2026-10-13）

| 配置 | 时钟 | 位流 md5 | ITER | 拍/迭代 | 得分 |
|---|---|---|---|---|---|
| **无 Cache** | 85.0051 MHz | `bcd8fdd2` | 4280 | 232,296.6 | **365.93** |
| **D-Cache only** | 85.0051 MHz | `56374a08` | 4280 | 232,302.6 | **365.92** |
| **I+D Cache 全开** | 76.5052 MHz | `da8ffd31` | 3800 | 234,706.8 | **325.96** |

日志：`doc/board/uart_20261013_184111.txt`（无 Cache）、`_195230.txt`（两段：I+D 在前、
D-only 在后）、`_203927.txt`（I+D 连跑 23 次）、`_204708.txt`（D-only 连跑 22 次）。

**时序（只认 `report_timing/cpu_top_board.rtr` 的 `u_pll→u_pll` 那行）**：
- 85 MHz 无 Cache：**+0.068 ns**
- 76.5 MHz I+D：**+0.015 ns**（8 seed 散布 −0.596…+0.015）—— **板上连跑 25 次零失败，稳**

**稳定性**：两配置各自连跑 20+ 次，`Total ticks` **逐位相同**、零失败。
⇒ 板上是逐位确定的；文档里那条"板/仿真 ±0.04% 抖动"是**仿真模型**的抖动，不是板上的。

---

## 4. 两条本次挖出来的关键结论

### 4.1 Cache：D-Cache 几乎零代价；仿真的 `ITER=1` 会高估 Cache 代价

- **D-Cache 只多 6.0 拍/迭代（+0.003%），得分只掉 0.01** ⇒ 可以作为常规配置开着，
  高阶任务① 的 D 侧不损失分数。
- **`ITER=1` 的仿真会高估 Cache 代价一个数量级**：仿真说 D-Cache +365 拍、I+D +3,283 拍；
  板上只有 **+6.0 / +2,410**。**根因：`ITER=1` 时 Cache 是冷的**，缺失全被计进周期；
  板上几千次迭代把缺失摊薄了。⇒ **判带 Cache 的配置，仿真必须多迭代，否则只认板上数。**
- 命中率：D **99.929%** / I **98.944%**。

### 4.2 [核心] BTB/RAS：这个 workload 上"BTB 记目标"是错的解法

`+PROF` 实测（ITER=1，A1 之后）：

```
region cycles    : 232,345        region commit : 214,703   CPI 1.0822
region noretire  :  17,642 (7.59%)   ← 七桶之和自检 = 17,642 ✓
  ├ 分支代价      :   5,645 (2.43%)  ← B1 的全部靶子
  │    其中 jalr  :   1,374 条       ← BTB/RAS 唯一能救的
  ├ load-use 停顿 :   6,171 (2.66%)  ← A2，已出局
  ├ 预测重定向后  :   3,095 (1.33%)  ← [!] 见下
  └ 残余          :   2,731 (1.18%)
cond branches    : 49,048 (taken 18,468 / not-taken 30,580)
jal : 4,743      jalr : 1,374
```

> [!] **顺带记一笔文档与实测不符**：测试台那行自己标着「预测重定向后 **应为 0**」，
> 实测是 **3,095**；而交接文档的分项（5,645 + 6,171 + 2,731 = 14,547）**加起来不等于
> 17,642**，差的正好是这 3,095。不是 A1 引入的，但**写任务书时要说明**，别让队友
> 照着一份对不上账的分解干活。

**jalr 局部性（`+JALRTRACE` 探针实测，1,374 条/迭代）**：

```
jalr 中 ret 形态（rd=x0 & rs1=ra）: 1374 条 = 100.0%   ← 全都是函数返回
静态点位 14 个；最热的 0x4af0 有 8 个目标、执行 912 次（占 66%）
```

| 结构 | jalr 捕获率 |
|---|---|
| **直接映射 BTB（16 ~ 16384 项，1/2/4 路组相联）** | **6.40%** |
| 每点位记最近 2 / 4 / 8 个目标 | 22.7% / 85.9% / 94.6% |
| **RAS 4 项** | **99.78%** |
| **RAS 8 / 16 / 32 项** | **99.93%**（1373/1374）|

**⇒ 结论**：
1. **加组相联没用** —— 不是冲突问题，是**单个点位自己就有 8 个目标**（那是个被 8 个调用点
   调用的函数的返回）。
2. **正解是 RAS（返回地址栈）**，8 项就到 99.93%。**BTB 的性能贡献 ≈ +0.04%（等于没做）；
   BTB + RAS ≈ +0.59%**（= 1373 拍/迭代，即理论上限）。
3. **RAS 在关键路径上比 BTB 还便宜** —— BTB 是"PC 索引的存储器读"（又一条一拍串两个 RAM
   的路径）；RAS 只是"栈顶指针索引的 8 选 1 小 mux"。
4. BTB 的价值在**赛题措辞/功能分**（高阶② 原文点名"如 BTB"），不在分数。**用户已确认
   这个定位**。
5. 条件分支误判 ≈3,995 拍是 2 位计数器固有的，**扩表学不会**（A3 的 BHT 1024 项实测只值
   −233 拍，已回退）⇒ **做完 RAS 之后分支线真的到顶**。

**代码勘察（给任务书用，行号都在 `rtl/core/core.v`）**：

| 项 | 位置 |
|---|---|
| `fetch_addr` 重定向 mux（**Fmax 关键点**）| 330-335 |
| `p_target` / `p_redirect` | 615 / 616 |
| BHT 声明 / 读侧 / 训练侧 | 501-503 / 604-606 / 996-1013 |
| `p_branch` / `p_jump`（jalr 不在此列）| 602 / 603 |
| EX：`branch_target` / `jalr_target` / `ex_target` | 970 / 971 / 976-977 |
| `ex_resolve_taken` / `ex_flush` / `ex_mispred` | 981-982 / 984 / 986 |
| `id_ex_pred_taken <= if_id_pred_taken` / `if_id_pred_taken <= p_redirect` | 1416 / 1311 |

> [!] **必须补目标校验**：今天 jalr 的 `ex_resolve_taken` 恒 1 ⇒ `ex_mispred` 恒 0 ⇒
> **预测了就没法纠错**（会一路跑向错目标）。要把预测目标随指令带到 EX 比对。
> 当年特意做"保守版 BHT 只预测方向"绕开的正是这个坑，**别把它重新挖开**。

> [!] 源码里两条关于时序的原话：`fetch_addr` 的组合路径是 "Stage B/C 的 Fmax 风险点"；
> MRET 被折进 `ex_flush` 就是**为了不给 `fetch_addr` 再加腿**（"那条路径在 `pc_r` 的关键
> 路径上，直接影响 Fmax 和 CoreMark/LUTs"）。⇒ **BTB 的目标 mux 应折进 `p_target`，
> 而不是新增 `fetch_addr` 的腿。**

---

## 5. [OK] 已完成（2026-10-13 会后续做，另加一件计划外的）

1. **[OK] BTB/RAS 任务书 + 交接压缩包** —— 任务书 `doc/reports/2026-10-13_handoff_btbras.md`
   （**本文 §4.2 的勘察是它的依据；它取代 `handoff_pathB.md` 的 §5-B1**）。
   出包走 `pack_for_teammate.ps1 -Tag btbras`（**脚本新增 `-Tag` 参数**，躲开与
   `riscv-cpu-fpga_dualissue_20261013.zip` 同名）→ `..._20261013_btbras.zip`。
2. **[OK] 队友 T1/G3 五子棋包：验证 + 整合 + 首次上板** ——
   `riscv-cpu-fpga_dualissue_20261013（t1).rar`。**注意：`rtl/` 一行未动，是纯固件包**
   （fork 自 `20ecd0e`，改动**未提交**）。
   * 验证：队友 x86 单测 138 项 + 我另写的独立 API 复核 28 项 + RV32 交叉编译无警告
     + `tb_rtthread` 仿真 PASS；**弱符号绑定**用 `nm` 确认 ELF 里只剩强定义（app/main.c）。
   * 整合提交 `1644197`；补齐队友留的尾巴：`build_bitstream.ps1` 的
     `expectLines['rtthread']` **19124 → 20270**（10135 字；**必须用非 `-Sim` 的构建量**，
     `-Sim` 会让 `.text` 差 8 字节、行数差 4）+ `rtthread/README.md` 口径同步。
   * **首次上板**（位流 `8894cdcb`，日志 `doc/board/uart_20261013_224652.txt`）：
     **两线程邮箱往返真通**（`AI moved, nodes=10592 depth=6 t=5068ms`）—— 这正是仿真
     验不到的那一段（tb 不驱动按键）。

   > [!] **两处遗留，别当已验证**：
   > 1. **`[!] vblank timeout`** —— `doc/board/` 23 份裸机五子棋日志一份都没有。
   >    T1 新加的 `video_vblank_yield()` = `rt_thread_mdelay(1)`，即**每 ~1 ms 看一次状态位**；
   >    而 RTL 里那是 `V_SYNC = 2` 行的脉冲（`H_TOTAL=810`、pix clk 25.5 MHz ⇒ **≈63 µs**，
   >    `video_core.v:133` 注释自称 "62.7us"）。**1 ms 采样看 63 µs 脉冲，粒度差 16 倍。**
   >    定案一步：看 led[1]（丝印 **D18**）=video_locked。详见 `doc/board/README.md`。
   > 2. **G3 的正题"AI 思考期间画面不卡"没验** —— 那次上板**没接显示屏**。

### 仍未做

* **BTB / RAS 本身**（任务书已出，代码没写）。
* G3 的显示侧验收（要接一块显示器）。
* 录像/照片（`doc/board/` 只有串口文本与 ILA 波形）。

---

## 6. 下次怎么起手

```powershell
# 三个仓的状态
cd D:\riscv-cpu-fpga_merged ; git log --oneline -3 ; git status   # 主线 dualissue
# 先读本文件，再读 doc/reports/2026-10-13_handoff_pathB.md（上一轮给队友的路径B任务书）

# 重跑 jalr 局部性（本会话的结论怎么复现）
cd sim
vvp tb_coremark_dual_earlyld.vvp "+ITER=1" "+IMEM=programs/imem.hex" `
    "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+JALRTRACE"
python ..\scripts\analyze_jalr_locality.py programs/jalrtrace.txt
# [!] 跑之前先 run_coremark.ps1 -Iter 1 -EarlyLd -SkipSim 重新生成固件 ——
#     run_riscv_tests.ps1 / run_own_tests.ps1 会把 sim/programs/ 覆盖掉，那样会 TIMEOUT。
```

**本会话新增/改动的工具**：`scripts/flash.tcl`（无头烧录）、`scripts/analyze_jalr_locality.py`
（局部性分析）、`sim/tb_coremark.v` 的 `+JALRTRACE` 探针（被动，不改周期数，已验证）。
