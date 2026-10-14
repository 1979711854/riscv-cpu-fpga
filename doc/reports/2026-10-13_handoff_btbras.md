# 交接说明 · BTB / RAS（分支目标预测线）—— 2026-10-13

> [!] **数字口径提示**：本文是 **2026-10-13** 时点的记录，其中的分数/拍数/位流是**当时口径**，**可能与当前不一致**。**当前唯一口径见 `doc/paper/论文框架_v1_20261012.md` §0（+ §0.1 提交档声明）**；本文数字**保留原样、不逐个改写**（历史可追溯）。

> **给接手 B1 的队友。** 本文**取代 `2026-10-13_handoff_pathB.md` §5 里的 B1 一节** ——
> 那一节写的是"直接做 BTB（目标预测）"，本会话用 `+JALRTRACE` 探针实测后**推翻了它**：
> 在这个 workload 上 BTB 记目标几乎拿不到分，**正解是 RAS**。
> 本文是 B1 的**唯一现行口径**，按它做。
>
> 作者：2026-10-13 会话（A1 集成 + Cache 两版上板 + BTB/RAS 勘察）。
> 分支 `dualissue`，会话结束时 `git log` 最新是 `c859b04`（**已 push**）。

---

## 1. 一句话

`+PROF` 实测：**分支代价 5,645 拍/迭代（2.43%）**，其中 **jalr 只有 1,374 条**，而这
1,374 条 **100% 是函数返回（`ret`）**。直接映射 BTB（16 ~ 16384 项、1/2/4 路）捕获率
**恒为 6.40%**；**RAS 8 项就到了 99.93%**。

⇒ **性能账**：**BTB ≈ +0.04%（等于没做）；BTB + RAS ≈ +0.59%（= 1,373 拍/迭代，就是理论上限）**。
⇒ **BTB 的价值在赛题措辞 / 功能分**（高阶② 原文点名"动态分支预测器（如 BTB）"），**不在分数**。
**两句都要写进报告，不要只写其中一句。** 这个定位用户已确认。

**结论：先做 RAS（真拿分、且在关键路径上比 BTB 便宜），再做 BTB（为功能分）。**

---

## 2. [!] 开工前必读：当前基线（别再用旧数字）

`CLAUDE.md` 里的四条并列基线（**计时区间拍/迭代，仿真**）：

| 配置 | 怎么跑 | 每迭代周期 | 效率 CoreMark/MHz |
|---|---|---|---|
| **双发射 + `EARLY_LD`（板上口径）** | `run_coremark.ps1 -Iter 1 -EarlyLd` | **232,345** | **4.304** |
| 双发射 + `EARLY_LD=0` | 去掉 `-EarlyLd` | 252,730 | 3.957 |
| 单发射 | 加 `-Single` | 303,140 | 3.299 |
| 双发射 + I+D Cache | 加 `-DCache -ICache -EarlyLd` | 235,628 | 4.244 |

* **riscv-tests 判据**：**49 PASS / 1 FAIL / 0 TIMEOUT**。唯一 FAIL 是 `ma_data`
  （未对齐访存，**规范允许的架构取舍**，**别去修**）。
* 板上实测：**365.93 CoreMark @ 85.0051 MHz**（位流 md5 `bcd8fdd2`）。
* **板上 ITER = 4280**；`build_bitstream.ps1` 的默认值若还是 4116，出跑分位流前要改。

### 时序（**只认这一个口径**）

`pds_shell -run report_timing` → `pds/RV32I_1/report_timing/cpu_top_board.rtr` 的
Setup Summary，**只看 `clk|u_pll/u_gpll/CLKOUT0_Inferred → 自己` 那一行**：

| | WNS | 失败端点 |
|---|---|---|
| **CPU 域（唯一指标）** | **+0.068 ns** | **0 / 17,216** |
| CPU → 视频 | −1.137 | 21（**建模假象，修不了**，别碰）|

> [!] `pds_shell -run pnr` 每个 seed 打的 `Setup(Slow): -1.1xx` 是**全设计最差**，
> 被那 21 条跨域路径主导，**对 CPU 侧改动完全不敏感** —— 拿它判 CPU 时序会得出完全错误的结论。

**⇒ CPU 域余量只有 +0.068 ns（≈0.6%）。经验常数：往关键路径插一级 32 位逻辑 ≈ 0.43 ns。**
**⇒ 这是 B1 的第一约束：RAS 和 BTB 都必须"不加深 `fetch_addr` 那条关键路径"。**

---

## 3. 实测数据（决定 B1 值多少 —— 别跳过）

`+PROF` 实测（ITER=1，A1 之后，双发射 + `EARLY_LD`）：

```
region cycles    : 232,345        region commit : 214,703   CPI 1.0822
region noretire  :  17,642 (7.59%)   ← 七桶之和自检 = 17,642 [OK]
  ├ 分支代价      :   5,645 (2.43%)  ← B1 的全部靶子
  │    其中 jalr  :   1,374 条       ← BTB/RAS 唯一能救的
  ├ load-use 停顿 :   6,171 (2.66%)  ← A2，已出局
  ├ 预测重定向后  :   3,095 (1.33%)  ← [!] 见下
  └ 残余          :   2,731 (1.18%)
cond branches    : 49,048 (taken 18,468 / not-taken 30,580)
jal : 4,743      jalr : 1,374
```

> [!] **文档与实测不符，写报告/任务书时别照抄旧分解**：测试台那行自己标着
> 「预测重定向后**应为 0**」，**实测是 3,095**；而 `handoff_pathB.md` 里的分项
> （5,645 + 6,171 + 2,731 = 14,547）**加起来不等于 17,642**，差的正好是这 3,095。
> **不是 A1 引入的**（A1 之前就有），但**要对着一份对得上账的分解干活**，别被它带偏。

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

**三条推论，都要写进报告**：

1. **加组相联没用** —— 不是冲突问题，是**单个点位自己就有 8 个目标**
   （`0x4af0` 是个被 8 个调用点调用的函数的返回）。
2. **正解是 RAS**，8 项就到 99.93%，再扩到 16/32 项只多 2 条，**8 或 16 项就够**。
3. **RAS 在关键路径上比 BTB 还便宜** —— BTB 是"PC 索引的存储器读"（又一条"一拍串两个
   RAM"的路径）；RAS 只是"栈顶指针索引的 8 选 1 小 mux"。**这正是先做 RAS 的另一个理由。**

**条件分支那条线已经到顶**：误判 ≈3,995 拍是 2 位饱和计数器固有的，**扩表学不会**
（A3 的 BHT 256→1024 实测只值 −233 拍 = +0.10%，**已回退** —— 见 `da45e41`）。
**⇒ 做完 RAS 之后，分支预测这条线就真的榨干了，别再指望 BHT。**

---

## 4. 要做的事

### 4.1 第一步 · RAS（返回地址栈）—— **真正拿分的**

**语义（RISC-V 标准返回地址预测）**：

* **push**：`jal` / `jalr` 且 **rd ∈ {x1, x5}**（是"调用"，会写链接寄存器），压入 `pc+4`。
* **pop**：`jalr` 且 **rs1 ∈ {x1, x5} 且 rd = x0**（是"返回"），弹出栈顶当预测目标。
* 栈空时不预测（让它走原来的 EX 冲刷路径）。

**规模**：**8 或 16 项**。实测 8 项 99.93%、16 项 99.93%，再加没意义。

**接在哪**：和 BHT 完全同构 —— **到达级（`if_addr_d`）**。
`ret` 的判据**只依赖指令编码**（opcode `1100111`、f3=`000`、rd=`x0`、rs1=`x1/x5`），
**不需要 rs1 的值** —— 预测目标就是栈顶。所以 RAS 能像 BHT 一样在到达级当场出目标、
当场重定向，被预测中的 `ret` 不再付那 1 拍取指气泡。

> [!] **两个必须小心的坑**：
> 1. **栈必须按程序序更新**。预测在【到达级】读栈顶，而 push/pop 的"真值"要到 EX 才
>    确定。EX 比到达级**老**（同一拍 EX 里的是更老的指令），所以"EX 更新、到达级读"
>    的先后天然是对的 —— 但**别把 push 放在到达级或预解码级**（那会被误预测路径污染栈）。
> 2. **RAS 的预测同样要过 `p_redirect` 的门控**（`!ex_flush && !stall_int && !mc_stall
>    && mem_ready_int`），理由与 BHT 那段注释里写的完全一样（`mem_ready` 那条是**承重的**，
>    不加会静默破坏"预测一致性"）。照抄 BHT 的门控即可。

**目标 mux 折进 `p_target`，不要新增 `fetch_addr` 的腿**：

```
p_target = is_ret_p ? ras_top : (if_addr_d + p_imm);
```

**理由（源码里的两条原话，别绕过）**：`fetch_addr` 的组合路径是 **"Stage B/C 的 Fmax 风险点"**；
当年 MRET 被折进 `ex_flush` 分支就是**为了不给 `fetch_addr` 再加腿**（"那条路径在 `pc_r`
的临界路径上，直接影响 Fmax 和 CoreMark/LUTs"）。RAS 走 `p_target` 这条**已有的**腿，不新增。

### 4.2 第二步 · BTB（赛题点名，**必须做，但要做得不亏**）

**为什么做**：高阶② 原文点名"**动态分支预测器（如 BTB）**"。报告里必须有这个东西，
否则功能分拿不到。**为什么"不亏"很难**：实测 BTB 单独只用 +0.04%，而它要新增一条
"PC 索引的存储器读"路径，**大概率吃掉那 0.6% 的时序余量**。

**做法建议（按顺序）**：

1. **先做 RAS，测出净收益，归档位流** —— BTB 是在这个基础上加。
2. BTB **只存 jal/jalr 这类"目标不固定"的跳转**，不要重复 BHT 已经在做的条件分支方向预测。
   这样 BTB 的查表结果对**条件分支**是空的（条件分支的目标 `PC+imm` 由 `p_target` 现算，
   **已经是对的**），不会互相打架。
3. **表和 BHT 共用索引 / tag 的组织方式**（`pc[9:2]` 索引、`pc[31:8]` tag），照抄 BHT 的代码形态。
4. **优先级**：`p_target` 的 mux 选择顺序建议 `ret(RAS) > BTB 命中 > PC+imm`。
5. **量力而行**：如果 BTB 综合后 CPU 域 WNS 变负、或者收益为负，**就把它作为"仅功能展示"
   的开关（`define`/参数默认关）**，报告里如实写"实现了但默认关闭"。
   **不要为了塞进 BTB 而牺牲 85 MHz。**

### 4.3 [!] **必做的配套：预测目标校验** —— 别把绕过的坑重新挖开

现在的设计**只预测条件分支方向**，`jal` 走静态预测、`jalr` **完全不预测**，于是：

```
ex_resolve_taken = 方向/是否跳转          （line 981-982）
ex_flush         = ex_resolve_taken && !id_ex_pred_taken   （984）
ex_mispred       = !ex_resolve_taken &&  id_ex_pred_taken  （986）
```

**`ex_mispred` 只在"预测了 taken、实际 not-taken"时触发，完全没有"目标对不对"这一维。**
当年特意做成"保守版只预测方向"绕开的正是这个坑 —— **加了 RAS/BTB 就直接踩进去**：
一旦预测了 `ret` 的目标却没校验，**预测了就没法纠错，会一路跑向错目标**。

**必须补**：把**预测目标**随指令带到 EX 比对：

```
// ID/EX 里新增：id_ex_pred_target（只有 id_ex_pred_taken=1 才有意义）
wire ex_target_wrong = id_ex_pred_taken && (ex_target != id_ex_pred_target);
// 并入冲刷条件：
assign ex_flush = (ex_resolve_taken && !id_ex_pred_taken) || ex_target_wrong;
```

**验收**：RAS 做对之后，`+PROF` 的**分支代价应从 5,645 降到 ≈4,272**（省 1,373 拍），
而 **`region commit` 应逐位不变（214,703）** —— commit 变了就是你把指令执行错了。

---

## 5. 代码勘察（行号都在 `rtl/core/core.v`，A1 之后）

| 项 | 位置 | 说明 |
|---|---|---|
| `fetch_addr` 重定向 mux（**Fmax 关键点**）| **330-335** | trap / ex_flush / ex_mispred / p_redirect / stall / +4 的优先级链 |
| `p_target` / `p_redirect` | **614-616** | 到达级预测目标与重定向门控；**RAS 目标折进这里** |
| BHT 声明 | 501-503 | `bht_tag[256]` / `bht_ctr[256]` / `bht_valid` —— **RAS 数组照这个格式加** |
| BHT 读侧（到达级）| 604-606 | `bht_idx_p` / `bht_hit_p` / `bht_taken_p` |
| `p_pred_taken` 静态兜底 | 607-608 | BHT 未命中时后向分支 / `jal` 预测跳转 |
| `p_branch` / `p_jump`（**jalr 不在此列**）| 602 / 603 | |
| BHT 训练（EX 级）| 996-1013 | 读写同拍无转发、读旧值可接受 |
| EX：`branch_target` / `jalr_target` / `ex_target` | 970 / **971** / 976-977 | |
| EX：`ex_resolve_taken` / `ex_flush` / `ex_mispred` | 981-982 / **984** / **986** | **4.3 改这里** |
| `ex_mispred_target = id_ex_pc + 4` | 987 | 误判恢复回到 fall-through |
| `if_id_pred_taken <= p_redirect` | 1311 | |
| `id_ex_pred_taken <= if_id_pred_taken` | 1416 | **新目标字段照这里锁存** |

---

## 6. 验收判据

| # | 判据 | 期望 |
|---|---|---|
| 1 | `scripts\run_riscv_tests.ps1` | **49 PASS / 1 FAIL / 0 TIMEOUT**（FAIL 恒为 `ma_data`）|
| 2 | `run_coremark.ps1 -Iter 1 -EarlyLd` 计时区间 | **RAS 后 ≈231,000**（省 ≈1,373）；`region commit` **逐位不变 214,703** |
| 3 | `+PROF` 分支代价 | 5,645 → **≈4,272** |
| 4 | `run_own_tests.ps1`（异常/中断）| **不过 = 你把 trap/mret 通路碰坏了** |
| 5 | `run_sim.ps1 -NoWave`（单测）| 全过 |
| 6 | **时序**：`report_timing` 里 CPU 域 WNS | **不得变负**；RAS 应几乎不动（小 mux），BTB 才是风险 |
| 7 | 上板 | `build_bitstream.ps1 coremark` → 烧板 → 串口 CRC 四个逐位一致 + `Correct operation validated` |

> [!] **第 2 条的 `region commit` 不变是最灵敏的探针** —— 它是"有没有执行错指令"的直接证据，
> 比总分敏感得多。**总分涨了但 commit 变了 = 你算错了**，别高兴太早。

---

## 7. 纪律（改 RTL 前先看）

1. **不 push `main`，push `dualissue`。**
2. **改了 `core.v` 的流水线控制，必须重跑全部五个探针**（见 §6 第 1/2/4/5 条 + 时序）。
3. **上板前必须 `build_bitstream.ps1 <变体>`** —— 它会生成固件 → 同步 → 校验 `mem.hex`
   字数 → 综合，并把 md5 打出来。**别靠文件名猜是哪个固件。**
4. **跑过任何非生产综合（临时探针）之后，必须重跑一次 `build_bitstream.ps1`** 把标准路径上的
   `.sbit` 盖回来 —— 它名字固定、大小一样，唯一的区别是烧上去什么都不跑。
5. **位流归档是硬纪律**：每次上板实测的 `.sbit` 必须归档到 `pds/RV32I_1/bitstreams/`
   并在其 `README.md` 登记（md5 + 口径 + 日志名）。
6. **新增 RTL 文件必须在 `.pds` 里手工登记**（`wgt_my_design_src` 加一条 `(_file ...)`），
   **仿真会通、综合才报错** —— 别指望 PDS 自动发现新文件。
7. **iverilog 14 严格要求"先声明后使用"**；**Verilog 字符串转义里没有 `\r`**。
8. 交流与文档默认**简体中文**；提交按里程碑拆分。

---

## 8. 怎么跑（备忘）

```powershell
# ---- 仿真回归（四条并列基线）----
scripts\run_riscv_tests.ps1                      # 49/1/0
scripts\run_coremark.ps1 -Iter 1 -EarlyLd        # 232,345（板上口径）
scripts\run_coremark.ps1 -Iter 1                 # 252,730
scripts\run_coremark.ps1 -Iter 1 -Single         # 303,140
scripts\run_coremark.ps1 -Iter 1 -DCache -ICache -EarlyLd   # 235,628

# ---- 剖析（脚本不收 +PROF，要自己调 vvp）----
# [!] 跑之前先 run_coremark.ps1 -Iter 1 -EarlyLd -SkipSim 重新生成固件 ——
#     run_riscv_tests.ps1 / run_own_tests.ps1 会把 sim\programs\ 覆盖掉，那样会 TIMEOUT。
cd sim
vvp tb_coremark_dual_earlyld.vvp "+ITER=1" "+IMEM=programs/imem.hex" `
    "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+PROF"
# 重跑 jalr 局部性（本文 §3 的结论怎么复现）：
vvp tb_coremark_dual_earlyld.vvp "+ITER=1" "+IMEM=programs/imem.hex" `
    "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+JALRTRACE"
python ..\scripts\analyze_jalr_locality.py programs/jalrtrace.txt

# ---- 时序（权威口径，约 6 分钟；每个 -run 都会重跑前面所有步骤）----
cd pds\RV32I_1
& "D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe" -project RV32I_1.pds -run report_timing
# 只看 report_timing\cpu_top_board.rtr 的 Setup Summary 里 u_pll → u_pll 那行
```

> [!] **跑完 PDS 记得 `git checkout pds/RV32I_1/RV32I_1.pds`** ——
> 每次综合都会把它的时间戳改写一遍（纯 churn，内容等价），不还原会一直挂在工作区。

---

## 9. 该读哪几份文档

| 文档 | 用途 |
|---|---|
| **`doc/reports/2026-10-13_session_state.md`** | **本线的全部实测依据**。§3 四条基线 + 板上实测 / **§4.2 BTB/RAS 勘察全文**（含捕获率表与本文的原始推导）/ §6 复现命令 |
| `doc/reports/2026-10-13_handoff_pathB.md` | 上一轮给队友的路径 B 任务书。**§5-B1 已被本文取代**，其余（B2 总线突发 / B3 应用场景）仍有效 |
| **`CLAUDE.md`** | 50+ 条关键约定（**都是踩过的坑**）；四条并列基线；ITER 速算式 |
| `doc/reports/2026-10-12_taskbook_v9.md` | 总任务书（A+B 计划）；§1 赛题原文六处发现 |
| `doc/ila_analysis.md` | `+PROF` / ILA 逐拍抓波形的做法 |
| `scripts/analyze_jalr_locality.py` | §3 那张捕获率表的生成脚本 |
| `doc/board_bringup.md` | 上板教程 |

---

> **最后一句**：这条线的**性能收益上限是 0.59%**（1,373 拍/迭代），**改动量却不小**，
> 而且有把 CPU 域那 0.6% 时序余量吃光、掉主频的风险。
> **先做 RAS → 测 → 归档位流 → 再评估 BTB 值不值得。** 别一口气两个一起上。
