# RISC-V CPU 优化任务书（v10 · 2026-10-13 立，**2026-10-14 补：Cache 挂死列为 P0 §3.1**）

> **读者：乙（CPU 优化 / RTL 线）。** 本文**自包含**，不需要先读旧文档。
> 分支 `dualissue`（本地仓库 `D:\riscv-cpu-fpga_merged`）。
> 开工前读工程根 `CLAUDE.md`（关键约定全是踩过的坑）与 `doc/board_bringup.md`。
>
> **本文取代 v8 / v9 的"路径 B / B1"部分。** 那两版写的"直接做 BTB（目标预测）"，
> **已被 2026-10-13 的 `+JALRTRACE` 实测推翻** —— 正解是 **RAS**，理由见 §4。
> 仓库侧权威技术记录：`doc/reports/2026-10-13_handoff_btbras.md`（全套实测 + 代码勘察）。

---

## 0. 三十秒版

| | 状态 |
|---|---|
| 性能线（路径 A）| **已收官** —— A1 乘法器去阻塞（II=1），板上 **365.93 CoreMark**（85.0051 MHz）|
| 功能线 B1（分支目标预测）| **勘察完成，方向改了**：不是 BTB，是 **RAS** |
| 你的活 | **① 覆盖 A/B 两件热身 → ② B1-RAS → ③ B1-BTB** |
| 关键约束 | 0.6% 时序余量（+0.068 ns）——**别加深 `fetch_addr` 那条关键路径**；① 的明文措辞缺口要补 |

> [!] **先纠正一个仓库里到处都在的误解**：本仓多处写着"BTB/BHT 已完成"，
> 但**设计里根本没有 BTB**。有的是 **BHT**：256 项、2 位饱和计数器、带 tag，
> **只预测条件分支方向**（`jal` 走静态预测、**`jalr` 完全不预测**）。
> 赛题原文点名的是"动态分支预测器（**如 BTB**）"—— **这是明文措辞缺口，得补。**

---

## 1. [!] 开工前必读：当前基线（别用旧数字）

### 四条并列基线（计时区间拍/迭代，仿真）

| 配置 | 怎么跑 | 每迭代周期 | 效率 CoreMark/MHz |
|---|---|---|---|
| **双发射 + `EARLY_LD`（板上口径）** | `run_coremark.ps1 -Iter 1 -EarlyLd` | **232,345** | **4.304** |
| 双发射 + `EARLY_LD=0` | 去掉 `-EarlyLd` | 252,730 | 3.957 |
| 单发射 | 加 `-Single` | 303,140 | 3.299 |
| 双发射 + I+D Cache | 加 `-DCache -ICache -EarlyLd` | 235,628 | 4.244 |

* **旧数字作废**：241,633 / 262,018 / 312,428 / 243,933（那是 A1 之前的）。
* **riscv-tests 判据**：**49 PASS / 1 FAIL / 0 TIMEOUT**。唯一 FAIL 是 `ma_data`
  （未对齐访存），**规范允许的架构取舍，别去修**。
* **板上实测**：365.93 CoreMark @85.0051 MHz（ITER=4280，位流 `bcd8fdd2` / `RTL=0x20261017`）。

### 时序 —— **只认这一个口径**

`pds_shell -run report_timing` → `pds/RV32I_1/report_timing/cpu_top_board.rtr` 的
Setup Summary，**只看 `clk|u_pll/u_gpll/CLKOUT0_Inferred → 自己` 那一行**：

| | WNS | 失败端点 |
|---|---|---|
| **CPU 域（唯一指标）** | **+0.068 ns** | **0 / 17,216** |
| CPU → 视频 | −1.137 | 21（**建模假象，修不了**，别碰）|

> [!] `pds_shell -run pnr` 每个 seed 打的 `Setup(Slow): -1.1xx` 是**全设计最差**，
> 被那 21 条跨域路径主导，**对 CPU 侧改动完全不敏感** —— 拿它判 CPU 时序会得出完全错误的结论。

**⇒ CPU 域余量只有 +0.068 ns（≈0.6%）。经验常数：往关键路径插一级 32 位逻辑 ≈ 0.43 ns。**
**⇒ 这是本任务书的第一约束。**

---

## 2. 已完成（**别重做**）

| 项 | 结果 |
|---|---|
| A1 乘法器去阻塞（II=1 流水线）| 241,633 → **232,345** 拍（+3.97%），板上 365.93 分 |
| A3 BHT 256 → 1024 | **实测只值 −233 拍（+0.10%），已回退** —— 条件分支这条线已榨干 |
| A0 修 CDC 约束 | **死胡同**（`.fdc` 里已四次否证）|
| A2 剩余 load-use | **出局**（要 ≈0.43 ns，余量只有 0.068）|
| I/D Cache | 已实现并上板；对分数贡献 0（后端是单周期 BRAM），**价值在功能条目** |
| 顺序双发射 / `EARLY_LD` / A 扩展 / RT-Thread BSP / 五子棋 / HDMI | 都已上板 |

---

## 3. 你的任务表

| # | 任务 | 优先级 | 说明 |
|---|---|---|---|
| **Cache 挂死** | **I/D Cache 在 RT-Thread 五子棋固件上会挂** —— 已仿真复现，待定位 | **P0（缺陷）** | 见 §3.1，**这是"已交付功能里的正确性 bug"，排在最前** |
| **覆盖 A** | `tb_amo_cpu.S` 转 tohost 判分 + 从 `$skipThese` 摘出 + "弄坏 `amo_unit` 能 FAIL" 验证 | **P0（热身）** | 低风险、验收明确，先做 |
| **覆盖 B** | `sim/tests/hi_fetch.S`（代码 >32 KB 取指）+ "把 `imem_addr2` 截位改回去能 FAIL" 验证 | **P0（热身）** | 同上 |
| **B1-RAS** | 返回地址栈（真正拿分的） | **P0** | 见 §5 |
| **B1-BTB** | BTB（赛题点名的功能分） | **P1** | 见 §6，**排在 RAS 之后** |

**顺序：覆盖 A/B → RAS → BTB。**

### 3.1 [P0 · 缺陷] Cache 在 RT-Thread 固件上会挂（**先修这个**）

2026-10-14 已用仿真**完整复现**（100 MHz，时序不参与，所以是纯功能 bug）：

| 配置 | 结果 |
|---|---|
| 无 Cache | **PASS** |
| **只开 D** | **崩**（走得较远：两条线程都起来了，之后寄存器转储）|
| **只开 I** | **崩得早**（串口只有 13 字节，banner 都没出来）|
| D + I | **崩得早**（同上 13 字节）|

⇒ **两个 Cache 都能打挂 RT-Thread 五子棋固件**；CoreMark（裸机、不开定时器中断）从来
没暴露过，所以以前一直以为"Cache 是好的"。

**已经排除的**（别重复查）：trap 路径本身（`exceptions`/`timer_irq` 在 `-ICache` 下都 PASS）、
地址截位（`imem_addr` 是 14 位字地址，覆盖完整 64 KB）、MMIO 被缓存（`ram_hit` 门控，
显存在 `0x8003_xxxx`）。

**最强怀疑（未证实）**：两个 Cache **没有任何流水线重定向输入**，而 `cache_i.v` 头注释把
正确性建立在"**停顿期间地址被冻在 A**"上；可 `core.v:330` 的 `fetch_addr` 优先级里
`trap` / `ex_flush` / `ex_mispred` / `p_redirect` **全排在停顿回退之上**。
**证实方法**（很便宜，加到测试台或 RTL 里只报不改）：

```verilog
// 停顿期间 fetch_addr 若发生变化 → 打印告警
if (stall_active && (fetch_addr !== fetch_addr_d1)) $display("REDIRECT-DURING-STALL @%0t", $time);
```

无 Cache 跑同一条固件应当**一次都不报**；带 Cache 跑应当**报**。

* **复现**：`scripts\rtthread\run_sim.ps1 -DCache` / `-ICache` / `-DCache -ICache`
  （各约 5~6 分钟；**每次核对 vvp 首行 `SIM CONFIG`**）。
* **归因全文**：`doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`。
* **验收**：种上断言 → 定位 → 修 → 上面四种配置**全部 PASS**，且 `run_riscv_tests.ps1`
  保持 49/1/0、四条并列基线**逐位不变**。
* **[!] 修好前**：`c10a2478`（I+D @76.5）与 10-14 00:57 那颗（D-only @85）**都标了"勿烧"**；
  **提交档一律 Cache 全关**。顺带一提，那颗 D-only @85 还有个**独立**问题：
  CPU 域 **−0.177 ns / 13 失败端点**（A1 之后"只开 D @85"也塞不进去了）。

> [!] **覆盖 A/B 是 2026-10-12 就分给你的**（原文：`tb_amo_cpu.S`、`hi_fetch.S`），
> 一直没人做。两项都动 `rtl/` 与 `sim/`，**归 CPU 线**（给五子棋线会踩 CPU 线）。
> 它们也是**建立"弄坏了能 FAIL"这套纪律**的最好热身 —— 后面改流水线时全靠它。

---

## 4. B1 为什么"直接做 BTB"是错的（实测，别跳过）

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

> [!] **这份分解和旧文档对不上账，别照旧口径干活**：测试台那行自己标着
> "预测重定向后**应为 0**"，**实测是 3,095**；而 `handoff_pathB.md` 的分项
> （5,645 + 6,171 + 2,731 = 14,547）**加起来不等于 17,642**，差的正是这 3,095。
> **不是 A1 引入的**，但要对着一份对得上账的分解干活。

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

**三条推论**：

1. **加组相联没用** —— 不是冲突问题，是**单个点位自己就有 8 个目标**
   （`0x4af0` 是个被 8 个调用点调用的函数的返回）。
2. **正解是 RAS**，8 项就到 99.93%，8 或 16 项足够。
3. **RAS 在关键路径上比 BTB 还便宜** —— BTB 是"PC 索引的存储器读"（又一条一拍串两个 RAM
   的路径）；RAS 只是"栈顶指针索引的 8 选 1 小 mux"。

**⇒ 性能账：BTB ≈ +0.04%（等于没做）；BTB + RAS ≈ +0.59%（= 1,373 拍/迭代，理论上限）。
⇒ BTB 的价值在赛题措辞/功能分，不在分数。两句都要写进报告，别只写一句。**

---

## 5. B1-RAS —— 返回地址栈（**真正拿分的**）

### 语义（RISC-V 标准返回地址预测）

* **push**：`jal` / `jalr` 且 **rd ∈ {x1, x5}**（是"调用"，会写链接寄存器），压入 `pc+4`。
* **pop**：`jalr` 且 **rs1 ∈ {x1, x5} 且 rd = x0**（是"返回"），弹出栈顶当预测目标。
* 栈空时不预测（让它走原来的 EX 冲刷路径）。

**规模：8 或 16 项。** 实测 8 项和 16 项都是 99.93%，再加没意义。

### 接在哪

和 BHT 完全同构 —— **到达级（`if_addr_d`）**。`ret` 的判据**只依赖指令编码**
（opcode `1100111`、f3=`000`、rd=`x0`、rs1=`x1/x5`），**不需要 rs1 的值** ——
预测目标就是栈顶。所以 RAS 能像 BHT 一样在到达级当场出目标、当场重定向。

**目标 mux 折进 `p_target`，不要新增 `fetch_addr` 的腿**：

```
p_target = is_ret_p ? ras_top : (if_addr_d + p_imm);
```

> [!] 源码里两条原话别绕过：`fetch_addr` 的组合路径是 **"Stage B/C 的 Fmax 风险点"**；
> 当年 MRET 被折进 `ex_flush` 分支就是**为了不给 `fetch_addr` 再加腿**（"那条路径在
> `pc_r` 的临界路径上，直接影响 Fmax 和 CoreMark/LUTs"）。RAS 走 `p_target` 这条**已有的**腿。

### 两个必须小心的坑

1. **栈必须按程序序更新。** 预测在【到达级】读栈顶，而 push/pop 的"真值"要到 EX 才确定。
   EX 比到达级**老**（同一拍 EX 里的是更老的指令），所以"EX 更新、到达级读"的先后天然
   是对的 —— **但别把 push 放在到达级或预解码级**（那会被误预测路径污染栈）。
2. **RAS 的预测同样要过 `p_redirect` 的门控**（`!ex_flush && !stall_int && !mc_stall
   && mem_ready_int`）。理由与 BHT 那段注释写的完全一样 —— **`mem_ready` 那条是承重的**，
   不加会静默破坏"预测一致性"。照抄 BHT 的门控。

---

## 6. B1-BTB —— 赛题点名，**必须做，但要做得不亏**

**为什么做**：赛题原文点名"动态分支预测器（**如 BTB**）"。报告里必须有这个东西。
**为什么难**：实测 BTB 单独只用 +0.04%，而它要新增一条"PC 索引的存储器读"路径，
**大概率吃掉那 0.6% 的时序余量**。

**做法建议（按顺序）**：

1. **先做 RAS，测出净收益，归档位流** —— BTB 是在这个基础上加。
2. BTB **只存 jal/jalr 这类"目标不固定"的跳转**，不要重复 BHT 已经在做的方向预测。
   条件分支的目标 `PC+imm` 由 `p_target` 现算，**已经是对的**，不会互相打架。
3. **表和 BHT 共用索引 / tag 的组织方式**（`pc[9:2]` 索引、`pc[31:8]` tag），照抄 BHT 的代码形态。
4. `p_target` 的 mux 优先级建议 `ret(RAS) > BTB 命中 > PC+imm`。
5. **量力而行**：如果综合后 CPU 域 WNS 变负、或收益为负，**就把它做成"仅功能展示"的开关**
   （parameter 默认关），报告里如实写"实现了但默认关闭"。**不要为了塞进 BTB 而牺牲 85 MHz。**

---

## 7. [!] 必做的配套：**预测目标校验**

现在的设计只预测方向，`jal` 走静态预测、`jalr` 完全不预测，于是：

```
ex_resolve_taken = 方向/是否跳转                        （core.v:981-982）
ex_flush         = ex_resolve_taken && !id_ex_pred_taken （984）
ex_mispred       = !ex_resolve_taken &&  id_ex_pred_taken（986）
```

**`ex_mispred` 只在"预测了 taken、实际 not-taken"时触发，完全没有"目标对不对"这一维。**
当年特意做成"保守版只预测方向"绕开的正是这个坑 —— **加了 RAS/BTB 就直接踩进去**：
一旦预测了 `ret` 的目标却不校验，**预测了就再也纠不回来，会一路跑向错目标**。

**必须补**：把**预测目标**随指令带到 EX 比对：

```verilog
// ID/EX 里新增：id_ex_pred_target（只有 id_ex_pred_taken=1 才有意义）
wire ex_target_wrong = id_ex_pred_taken && (ex_target != id_ex_pred_target);
// 并入冲刷条件：
assign ex_flush = (ex_resolve_taken && !id_ex_pred_taken) || ex_target_wrong;
```

---

## 8. 代码勘察（行号都在 `rtl/core/core.v`，A1 之后）

| 项 | 位置 | 说明 |
|---|---|---|
| `fetch_addr` 重定向 mux（**Fmax 关键点**）| **330-335** | trap / ex_flush / ex_mispred / p_redirect / stall / +4 的优先级链 |
| `p_target` / `p_redirect` | **615 / 616** | 到达级预测目标与重定向门控；**RAS 目标折进这里** |
| BHT 声明 | 501-503 | `bht_tag[256]` / `bht_ctr[256]` / `bht_valid` —— **RAS 数组照这个格式加** |
| BHT 读侧（到达级）| 604-606 | `bht_idx_p` / `bht_hit_p` / `bht_taken_p` |
| `p_pred_taken` 静态兜底 | 607-608 | BHT 未命中时后向分支 / `jal` 预测跳转 |
| `p_branch` / `p_jump`（**jalr 不在此列**）| 602 / 603 | |
| BHT 训练（EX 级）| 996-1012 | 读写同拍无转发、读旧值可接受 |
| EX：`branch_target` / `jalr_target` / `ex_target` | 970 / **971** / 976-977 | |
| EX：`ex_resolve_taken` / `ex_flush` / `ex_mispred` | 981-982 / **984** / **986** | **§7 改这里** |
| `ex_mispred_target = id_ex_pc + 4` | 987 | 误判恢复回到 fall-through |
| `if_id_pred_taken <= p_redirect` | 1311 | |
| `id_ex_pred_taken <= if_id_pred_taken` | 1416 | **新目标字段照这里锁存** |

---

## 9. 验收判据

| # | 判据 | 期望 |
|---|---|---|
| 1 | `scripts\run_riscv_tests.ps1` | **49 PASS / 1 FAIL / 0 TIMEOUT**（FAIL 恒为 `ma_data`）|
| 2 | `run_coremark.ps1 -Iter 1 -EarlyLd` 计时区间 | **RAS 后 ≈231,000**（省 ≈1,373）；**`region commit` 逐位不变 214,703** |
| 3 | `+PROF` 分支代价 | 5,645 → **≈4,272** |
| 4 | `scripts\run_own_tests.ps1`（异常/中断）| **不过 = 你把 trap/mret 通路碰坏了** |
| 5 | `scripts\run_sim.ps1 -NoWave`（单测）| 全过（含 `tb_multiplier` 840 项）|
| 6 | **时序**：`report_timing` 的 CPU 域 WNS | **不得变负**；RAS 应几乎不动，BTB 才是风险 |
| 7 | 上板 | `build_bitstream.ps1 coremark` → 烧板 → 四个 CRC 逐位一致 + `Correct operation validated` |

> [!] **第 2 条的 `region commit` 不变是最灵敏的探针** —— 它是"有没有执行错指令"的直接证据，
> 比总分敏感得多。**总分涨了但 commit 变了 = 你算错了**，别高兴太早。
> **第 4/5 条是"没碰坏别的东西"的探针** —— 改流水线控制必须每次全跑。

---

## 10. 纪律（改 RTL）

1. **不 push `main`，push 你的特性分支**（见 §11）。
2. **`DESIGN_REV` 必须递增**（`rtl/core/csr_file.v`）：改了 RTL、综合前改它，
   否则两版位流的串口日志一模一样、事后分不出烧的是哪版。同一天改多次用最低字节序号。
3. **新增 RTL 文件必须手工登记进 `.pds`**（`wgt_my_design_src` 加一条 `(_file ...)`）——
   仿真脚本是**通配扫描**，`.pds` 是**显式枚举**：**仿真全过、综合报错**（2026-09-28 实踩）。
4. **上板前必须 `scripts\build_bitstream.ps1 coremark`**，并核对：
   * `report_timing/cpu_top_board.rtr` 里 CPU 域 WNS 与已知基线一致；
   * `pds/RV32I_1/mem.hex` 行数与 `sim/programs/mem.hex` 一致。
5. **位流归档是硬纪律**：每次上板实测的 `.sbit` 归档到 `pds/RV32I_1/bitstreams/`
   并在其 `README.md` 登记（md5 + 口径 + 日志名）。
6. **跑过任何非生产综合（临时探针）之后，必须重跑一次 `build_bitstream.ps1 <变体>`**
   把标准路径上的 `.sbit` 盖回来 —— 名字固定、大小一样，唯一区别是烧上去**什么都不跑**。
7. **iverilog 14 严格要求"先声明后使用"**；**Verilog 字符串转义里没有 `\r`**。
8. **交流与文档默认简体中文**；提交按里程碑拆分。

---

## 11. 和甲（五子棋/RTL 之外）并行 —— 文件划分

**你们俩同时改同一个仓库，撞文件就等于白干。** 按这个划：

| | 乙（你，CPU/RTL 线）| 甲（五子棋线）|
|---|---|---|
| **你的文件** | `rtl/core/**`、`rtl/bus/**`、`rtl/mem/**`、`rtl/video/**`、`sim/tb_*.v`（CPU/视频侧）、`sim/tests/**` | `scripts/gomoku/**`、`scripts/rtthread/**`、`sim/tb_rtthread.v`、`sim/tb_gomoku.v` |
| **别碰** | `scripts/gomoku/**`、`scripts/rtthread/**` | `rtl/**`（**包括 `rtl/video/`**）|

**共用的东西，约定如下：**

1. **`scripts/build_bitstream.ps1` 的 `expectLines` / `expectDesc` —— 归甲。**
   理由：**RTL 改动不改变固件体积**，只有改固件源码才会变。你不用动它。
2. **`pds/RV32I_1/mem.hex` 和 `RV32I_1.pds`** —— 每次综合都会改写（`mem.hex` 是**被 git 跟踪**的，
   内容固定是**生产固件 = CoreMark**）。**提交前一律
   `git checkout -- pds/RV32I_1/mem.hex pds/RV32I_1/RV32I_1.pds` 还原。**
3. **`pds/RV32I_1/bitstreams/README.md`** —— 两人都会加行。你的都在 `coremark_*` 区块，
   冲突了就把两行都留下。
4. **`CLAUDE.md`** —— **别两人都改**。你要沉淀结论就写进
   `doc/reports/<日期>_session_state.md`，由集成方统一并进 `CLAUDE.md`。
5. **`doc/board/`** —— 文件名带时间戳，天然不冲突。
6. **[!] 板子只有一块、JTAG Server 只有一个** —— 谁要上板先打招呼；烧完**立刻归档位流**并记 md5。

**Git**：**各开自己的特性分支**（如 `feat/cpu-ras`），别两人直推 `dualissue`。
完成一个里程碑 → 推分支 → 由集成方合并。

---

## 12. 怎么跑（速查）

```powershell
# ---- 仿真回归（四条并列基线）----
scripts\run_riscv_tests.ps1                      # 49/1/0
scripts\run_coremark.ps1 -Iter 1 -EarlyLd        # 232,345（板上口径）
scripts\run_coremark.ps1 -Iter 1                 # 252,730
scripts\run_coremark.ps1 -Iter 1 -Single         # 303,140
scripts\run_coremark.ps1 -Iter 1 -DCache -ICache -EarlyLd   # 235,628
scripts\run_own_tests.ps1                        # 异常/中断（2/0）
scripts\run_sim.ps1 -NoWave                      # 单元台

# ---- 剖析（脚本不收 +PROF，要自己调 vvp）----
# [!] 跑之前先 run_coremark.ps1 -Iter 1 -EarlyLd -SkipSim 重新生成固件 ——
#     run_riscv_tests.ps1 / run_own_tests.ps1 会把 sim\programs\ 覆盖掉，那样会 TIMEOUT。
cd sim
vvp tb_coremark_dual_earlyld.vvp "+ITER=1" "+IMEM=programs/imem.hex" `
    "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+PROF"
# 重跑 jalr 局部性（§4 的结论怎么复现）：
vvp tb_coremark_dual_earlyld.vvp "+ITER=1" "+IMEM=programs/imem.hex" `
    "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+JALRTRACE"
python ..\scripts\analyze_jalr_locality.py programs/jalrtrace.txt

# ---- 时序（权威口径，约 6 分钟；每个 -run 都会重跑前面所有步骤）----
cd pds\RV32I_1
& "D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe" -project RV32I_1.pds -run report_timing
# 只看 report_timing\cpu_top_board.rtr 的 Setup Summary 里 u_pll → u_pll 那行
# [!] 跑完记得 git checkout pds/RV32I_1/RV32I_1.pds（纯时间戳 churn）

# ---- 上板 ----
scripts\build_bitstream.ps1 coremark             # 唯一入口：固件→同步→校验行数→综合
```

**该读的**：`doc/reports/2026-10-13_handoff_btbras.md`（RAS/BTB 全套）、
`doc/reports/2026-10-12_taskbook_v9.md`（A+B 总任务书）、
`doc/ila_analysis.md`（`+PROF` / ILA 抓波形的做法）、
`doc/reports/2026-10-11_taskC_agu_probe.md`（**假路径探针的标准做法** —— BTB 评估要照它做）。

---

> **最后一句**：这条线的**性能收益上限是 0.59%**（1,373 拍/迭代），**改动量却不小**，
> 而且有把 CPU 域那 0.6% 时序余量吃光、掉主频的风险。
> **先做 RAS → 测 → 归档位流 → 再评估 BTB 值不值得。别一口气两个一起上。**
