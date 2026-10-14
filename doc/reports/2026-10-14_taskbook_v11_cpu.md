# RISC-V CPU 优化任务书 v11（2026-10-14 立）

> 接 **v10**（`doc/reports/2026-10-13_taskbook_v10_cpu.md`）。
> **本文只写"v10 之后发生了什么 + 你的任务表怎么变"**；每条任务的详细设计、接法、坑
> **仍在 v10 里**（B1-RAS 见 v10 §5、BTB 见 §6、目标校验见 §7、代码勘察见 §8）——**别丢 v10**。
>
> 一句话：**v10 的 P0 缺陷（Cache 挂死）已经修完并上板验证了，不占你的时间**；
> 你的任务表回到 覆盖 A/B → RAS → BTB，但**多了一条必须遵守的回归义务**（见 §4）。

---

## 0. 三十秒版

1. **[已完成·别重做]** v10 §3.1 的"Cache 在 RT-Thread 上会挂"**已定位到两条根因并修复**，
   上板验证通过（位流 `90944754` / 横幅修正版 `53b81dfe`，`RTL=0x20261019`）。**结论与教训必须记住**（§2），因为它是
   一条**通用纪律**：改 `core.v` 时你会再遇到它。
2. **你的任务表**：`覆盖 A` → `覆盖 B` → `B1-RAS` → `B1-BTB`。**前四项只剩 B1-BTB。**
   （覆盖 A/B、B1-RAS 均已完成 2026-10-14。）**Cache 不再占你时间。**
3. **新增义务（很重要）**：改完 RTL 的回归里，**RT-Thread 四种配置也要跑**（`-DCache -ICache` 等）
   —— 它是**唯一**能抓到"停顿相关"缺陷的组合（v10 §3.1 就是这么漏过去的）。
4. **基线已推进（B1-RAS）**：双发射+`EARLY_LD` **232,345 → 229,597** 拍/迭代（−2,748 / −1.18%），
   `region commit` 逐位不变 214,703；板上预计 **≈370.2 分**（旧 365.93 分，**需重出位流**）；
   `DESIGN_REV` 从 `0x2026_1019` 走到 **`0x2026_1021`**（覆盖 A = `_1020`、B1-RAS = `_1021`）。
5. **第一约束仍是时序**：B1-RAS 后 CPU 域余量 **+0.311 ns / 0 失败端点（18,122）**（RAS 前 +0.068/17,216）。

---

## 1. 当前基线（B1-RAS 落地后；旧数（RAS 前）保留标注）

| 配置 | 怎么跑 | 每迭代周期 | CoreMark/MHz |
|---|---|---|---|
| **双发射 + `EARLY_LD` + `B1-RAS`（当前，板上口径）** | `run_coremark.ps1 -Iter 1 -EarlyLd` | **229,597** | **4.355** |
| 双发射 + `EARLY_LD`（RAS 前，历史） | 同上（回退 RAS） | 232,345 | 4.304 |
| 双发射 + `EARLY_LD=0` | 去掉 `-EarlyLd` | 252,730 | 3.957 |
| 单发射 | 加 `-Single` | 303,140 | 3.299 |
| 双发射 + I+D Cache | 加 `-DCache -ICache -EarlyLd` | 235,628 | 4.244 |

* `DESIGN_REV` = **`0x2026_1021`**（`rtl/core/csr_file.v`）。**你改 RTL 必须再递增**（约定 42）。
* riscv-tests 判据不变：**49 PASS / 1 FAIL / 0 TIMEOUT**，唯一 FAIL = `ma_data`（**别修**）。
* 板上实测（RAS 前）：365.93 分 @85.0051 MHz（ITER=4280，位流 `bcd8fdd2` / `RTL=0x20261017`）。
  B1-RAS 省 2,748 拍/迭代 ⇒ 预计 **≈370.2 分**（上一版位流未含 RAS，**上板前必须重出位流**）。
* 时序唯一口径：`report_timing/cpu_top_board.rtr` 的 Setup Summary，只看 `u_pll→u_pll` 那行
  —— B1-RAS 后 **+0.311 ns / 0 失败端点（18,122）**（RAS 前为 +0.068 ns / 17,216）。别拿 pnr 每个 seed
  打的 `Setup(Slow): −1.1xx` 当 CPU 时序（那是被 21 条跨域建模假象主导的全设计最差值，对 CPU 侧改动**完全不敏感**）。

---

## 2. 【已完成·别重做】Cache + RT-Thread 挂死：两条根因

**这个 bug 值一个会话以上**，而且它的教训直接适用于你接下来要动的东西（分支预测/取指/前递）。
完整证据链：`doc/reports/2026-10-14_cache_rtthread_sim_bisect.md` → `..._cache_fix_bug1.md` → `..._cache_fix_bug2.md`。

### 2.1 现象（三步才见底，**别只看第一步就下结论**）

1. 板上：rtthread + **I+D Cache** 确定性挂死（只有一行 `?? turn=WHITE`）；**同一固件无 Cache 完全正常**。
2. 仿真：`-ICache` **13 字节**就挂 → 修完 #1 能完整启动，**但跑远仍挂**（`cause=6` 死循环转储）。
3. `trap_tval` 看着像"**隔壁的内存内容**"（指令字 / ASCII `vend`）⇒ 上一轮**猜**是"某次 load 返回错数据"。
   **这个猜测是错的** —— 用下面的自检证伪了它，才找到真身。

### 2.2 两条根因（同一个"漏门控"的两个实例）

| # | 位置 | 不门控的后果 |
|---|---|---|
| **#1** | ID/EX 寄存器**清零**（`core.v`） | `ex_flush/ex_mispred/stall_int` 是【EX 里那条指令自己】发的 ⇒ 冻结拍清 ID/EX = **把发跳转的指令自己杀掉** ⇒ `jal/jalr` 链接值**永久丢失**（约定 56）|
| **#2** | **CSR 写**（EX 级提交）+ `mret` 的 mstatus（`core.v`） | 冻结拍 CSR 已写、指令却还停在 EX ⇒ 下一拍 `alu_result = csr_rdata` 是**写后值** ⇒ `csrrw rd,csr,rs1` 的 **rd 拿到新值**。RT-Thread 中断入口/出口各有一条 **`csrrw sp, mscratch, sp`（rd=sp）** ⇒ sp 不切中断栈 ⇒ 出口把 `mscratch` 写坏 ⇒ 之后**每次中断的 sp 都漂移** ⇒ 踩坏内核链表 ⇒ `sw a4,4(a3)` 未对齐（约定 57）|

修法都是**加 `&& mem_ready_int`**，且**`trap` 保持无条件**。`trap` 是唯一例外（肇事指令必须死）。

### 2.3 为什么**四条基线全都盖不住**（这决定了你的回归清单）

| 回归 | 为什么漏 |
|---|---|
| `run_riscv_tests` 默认 | **无 Cache ⇒ `mem_ready_int` 恒 1** ⇒ 两条 bug 都不触发 |
| `run_coremark` 默认 | 同上；且 CoreMark **不写 CSR、不 trap** ⇒ 即使有停顿也碰不到 #2 |
| riscv-tests + Cache | 代码 1~2 KB ⇒ 缺失少、冻结稀疏；**不 trap** |
| 自写 `exceptions`/`timer_irq` | 有 trap 但代码极小 ⇒ 撞上冻结概率≈0 |

**⇒ 唯一抓到它的是"大固件 + 1 ms 定时器中断"（RT-Thread 五子棋）跑在 [有停顿的配置] 上。**

### 2.4 上板结论（2026-10-14）

位流 `90944754`（rtthread + I+D @76.5052 MHz，`RTL=0x20261019`）：两条线程 + `[hb]` 无断 +
**真按键下完一局判出 `WHITE wins`** + **接屏下棋正常**。（未修前那两颗：`c10a2478` 死在 AI 第一手后的
棋盘快照、`9feaa089` 卡在 `heap = 9368 bytes` 循环重启。）

---

## 3. 你的任务表（v11）

| # | 任务 | 优先级 | 验收（一句话） |
|---|---|---|---|
| **覆盖 A ✅已完成** | `tb_amo_cpu.S` 转 tohost 判分 + 从 `$skipThese` 摘出 + **"弄坏 `amo_unit` 能 FAIL"** 验证 | **P0（热身）** | 加进回归、能 FAIL、且弄坏能抓到 |
| **覆盖 B ✅已完成** | `sim/tests/hi_fetch.S`（代码 > 32 KB 取指）+ **"把 `imem_addr2` 截位改回去能 FAIL"** 验证 | **P0（热身）** | 加进回归、能 FAIL、且弄坏能抓到 |
| **B1-RAS ✅已完成** | 返回地址栈（**真正拿分的**） | **P0** | 见 v10 §5；`+PROF` 看 `region cycles` 下降 |
| **B1-BTB** | BTB（赛题点名） | **P1** | 见 v10 §6，**排在 RAS 之后**；必须配"预测目标校验"（v10 §7）|

**顺序：覆盖 A/B → RAS → BTB**（覆盖 A/B 是 2026-10-12 就分给你的，一直没人做；
它们也是建立"**弄坏了能 FAIL**"这套纪律的最好热身）。**覆盖 A/B 均已完成（2026-10-14）**。

> **覆盖 A（2026-10-14 完成）顺手抓到一个真 bug（含在约定 56/57 那一族）**：
> `tb_amo_cpu.S` 首次端到端跑就 **FAIL(testnum 9)**。根因不在测试，在 RTL：`ex_flush`/`ex_mispred`
> 的**源**没门控 `mem_ready_int` —— AMO/LR/SC 占住 MEM 的 4 拍里，前递的 `amo_wb_data` 还是
> **上一条** AMO 的陈旧值，紧跟其后的分支据此解析出错误方向；而 `ex_flush` 在 `fetch_addr` 里
> 优先级高于冻结兜底、IF/ID 冲刷又没门控 ⇒ **错误路径被提交**（`bnez` 后跟的 `li gp,9` 落了地）。
> 修法：`core.v` 的 `ex_flush`/`ex_mispred` 各加一个 `&& mem_ready_int`（与 #1/#2 同族，但这次
> 门控的是**源**而非某个消费者）。数据面消费者（ALU）不受影响（它被冻在 ID/EX、放开那拍重算），
> 只有**控制面**（分支/跳转）会踩。四条基线**一条 AMO 都没有** ⇒ 此前完全不可达。
> `DESIGN_REV → 0x2026_1020`（**改过 RTL，上板前必须重出位流**）。
> 详见 `doc/reports/2026-10-14_session_state.md`。

> **覆盖 B（2026-10-14 完成）没能抓到新 bug（符合预期——`imem_addr2` 早已修，只是通路零覆盖）**：
> `sim/tests/hi_fetch.S` 运行时把一段 `addi t2,t2,1`×2048 的代码【拷到 0x9FFC】(≥0x8000) 再跳过去执行，
> 低地址 0x2000 放 `addi s0,s0,1`×2048 毒丸；判据 `s0==0 && t2==2048`。修好后 lane B 取到真正的下一条
> `addi t2,t2,1` ⇒ `rd_a==rs1_b` ⇒ **不配对** ⇒ 单发射执行、`s0` 恒 0。**弄坏能 FAIL 已验证**：把
> `core.v` 的 `imem_addr2` 临时掩成 `[12:0]`（**只掩码、不改宽度**，故不触发 `run_own_tests.ps1` 的
> 宽度守卫）→ `hi_fetch` 立刻 **FAIL(testnum 1)**（截位的 lane B 取到毒丸并配对执行 ⇒ `s0!=0`）；
> **同一条弄坏**下低地址测试 `tb_amo_cpu` 仍 PASS（证明是"≥0x8000 取指"专属）。**本任务未动 RTL**：
> 弄坏是临时改 `core.v` 再**精确 Edit 还原**（**没敢 `git checkout core.v`**——它含覆盖 A 未提交的修复），
> `git diff rtl/core/core.v` 核对只剩覆盖 A 那两行。文档里 §7 给的 `N=8191` 放不下 64 KB（需 `N≤6142`），
> 实取 **2048**。详见 `doc/reports/2026-10-14_session_state.md`。

> **B1-RAS（2026-10-14 完成）—— 本轮真正拿分的一项**：
> 16 项返回地址栈（`RAS_DEPTH=16`）。`call`（`jal`/`jalr` 且 `rd∈{x1,x5}`）在 **EX 级提交那拍**
> push `id_ex_pc+4`；`ret`（`jalr x0,0(x1|x5)`，opcode `1100111`/f3=000/rd=x0/rs1∈{x1,x5}）在
> **到达级** 命中即当场 `p_target = ras_top`、`p_pred_taken=1` ⇒ 经**既有的** `p_redirect` 腿同拍重定向，
> **不新增 `fetch_addr` 的腿**（v10 §5 的硬约束，`fetch_addr` 是 Fmax 第一风险点）。
> **`region commit` 逐位不变 214,703**（最灵敏探针：提交的指令数一条不差 ⇒ 省下的全是冲刷气泡），
> `region flush 2,452`（RAS 前 5,645），`region cycles 229,597`（RAS 前 232,345，**−2,748 / −1.18%**），
> 四 CRC 全对。配套 **v10 §7 预测目标校验**：`ret` 的预测目标与真实 `jalr_target` 不符即并入 `ex_flush`
> 纠正（**功能正确性靠它兜底**——RAS 预测错会被静默纠正，功能测试抓不到"预测错但被纠正"，故
> 必须靠"commit 不变 + CRC"证明没算错）。`DESIGN_REV → 0x2026_1021`。
> **[坑·本项实测]** §7 若直接比 `ex_target != id_ex_pred_target`，会把 ~2 ns 的 `ex_target` 加法器
> 拽进取指临界路径 ⇒ 时序 **−0.271 ns / 66 失败端点**（基线 +0.068/0）。改法：**只对 `ret` 比对**、
> 且直接用 `rs1_val`（`(rs1_val & ~1) != id_ex_pred_target`）、`imm≠0` 强制冲刷，**绕开 `ex_target` 加法器**
> ⇒ 时序回到 **+0.311 ns / 0 失败端点**。详见 `doc/reports/2026-10-14_session_state.md`。

**明确不做**（见 v10 §2）：A3 BHT 加大（实测 +0.10%，已回退）、A0 修 CDC（死胡同）、
A2 剩余 load-use（要 ≈0.43 ns，余量只有 0.068）。**Cache 相关的事一件都不用做。**

---

## 4. 新增纪律（本轮产生，改 `core.v` 前对着过一遍）

### 4.1 冻结拍自查清单（**每个改动都要过**）

`mem_ready_int=0` 时整条流水线【保持】。请对每个你会碰的信号问：

1. 它**服务的**是哪一级？（判据：名字带 `ex_mem_` 就属于 EX/MEM 级）
2. 冻结时它该**保持**还是该**清**？**清零/写使能是否和"离开该级"同拍**？
3. 它是不是**只该发生一次**的副作用？（CSR 写、`mret`、多拍单元 `en`、外设写选通、快照选源）
4. **`trap` 是否仍然无条件**？（它必须无条件）

**已知的四条同族先例**：级间清零（约定 56）、CSR 写/`mret`（约定 57）、乘法器 `en`（约定 51）、
`wb_rdata_snap` 选源（约定 47）。**你改分支预测/取指/前递时，最像再踩的是"p_redirect/BHT 更新/
预测标志锁存"那一族** —— 它们的门控已经写得很细（`core.v` 的注释把每一条的理由都写了），
**动之前先把那段注释读完**。

### 4.2 回归清单（改 RTL 后**必须全跑**）

```powershell
scripts\run_riscv_tests.ps1                              # 49/1/0
scripts\run_riscv_tests.ps1 -DCache -ICache -EarlyLd     # Cache corner，也必须 49/1/0
scripts\run_coremark.ps1 -Iter 1 -EarlyLd                # B1-RAS 后 region cycles 必须 = 229,597（且 commit = 214,703 不变）
scripts\run_own_tests.ps1 -DCache -ICache -EarlyLd       # 4 PASS
scripts\rtthread\run_sim.ps1 -ICache                     # RT-Thread：**停顿相关 bug 的唯一探针**
```

> [!] **RT-Thread 这一条是本轮新增的强制项**。改流水线/停顿/前递/预测，**不跑它就等于没验**。
> `run_sim.ps1` 默认不传任何 `-D`（= 无 Cache），所以**必须显式带 Cache 开关**，并核对 vvp 首行
> `SIM CONFIG:`（约定 37/55）。

### 4.3 其它两条

* **别在源码里写死"由 RTL/编译宏决定的数字"**（频率、版本号）—— 一律算出来。
  位流身份**只认 `mimpid`（串口 `RTL=` 行）**（约定 58）。
* **`build_bitstream.ps1` 的 `expectLines` 守卫拦下你别放宽**：它比的是同步进 PDS 的 `mem.hex`
  行数，抓的是"源码改了、固件变了、你不知道"。

---

## 5. 文件边界（和五子棋线并行，**别越界**）

| 你（CPU/RTL 线） | 五子棋/应用线 | 视频/显示线 |
|---|---|---|
| `rtl/core/**`、`rtl/mem/**`、`rtl/bus/**` | `scripts/gomoku/**`、`scripts/rtthread/{app,bsp}/**` | `rtl/video/**` |
| `sim/tb_*.v`（CPU 侧）、`sim/tests/**` | 五子棋固件、任务书里的 T2~T5 | HDMI/PPU/显存 |

* **五子棋线不碰 `rtl/`**；你**不要碰 `scripts/gomoku` 与 `rtl/video`**（发现异常走反馈，别自己改）。
* 需要改 `rtl/bus/addr_map.vh`（地址映射）⇒ 先申请（三处同步：RTL + `scripts/demo/addr_map.h` + `doc/spec.md`）。

---

## 6. 怎么跑（速查）

```powershell
# ---- 回归（见 §4.2；四条基线 + RT-Thread）----
# [!] 跑 CoreMark 前先 -SkipSim 重生成固件：run_riscv_tests / run_own_tests 会覆盖 sim\programs\
scripts\run_coremark.ps1 -Iter 1 -EarlyLd -SkipSim

# ---- 剖析（脚本不带 +PROF，要自己调 vvp）----
# ---- 时序（权威口径，约 6 分钟；每个 -run 都会重跑前面所有步骤）----
#   只看 report_timing\cpu_top_board.rtr 的 u_pll → u_pll 那行
#   [!] 跑完 git checkout pds/RV32I_1/RV32I_1.pds（纯时间戳 churn）

# ---- 上板（唯一入口；队友自己综合，.sbit 不入库）----
scripts\build_bitstream.ps1 coremark          # 85.0051 MHz 生产档
scripts\serial_monitor.ps1 -Port COM4 -Seconds 60
```

---

## 7. 纪律

* **一个会话只干一个里程碑**；盯 ctx，**65% 收尾**（写状态 + commit），75% 不开新任务线。
* **结论立刻落盘**（进度在 git 里，不在对话里）；**提交按里程碑拆**、信息写清楚；**不自动 push**。
* `.ps1` 必须带 **UTF-8 BOM**；`.c/h/.v/.md` 统一 UTF-8；交流用简体中文。
* 数字口径**唯一真相**在 `CLAUDE.md` + `doc/paper/论文框架_v1_20261012.md` §0；**历史报告里的旧数留原样 + 加横幅**。
* **别把"仿真过了"当结论** —— 只有配置打印全对、且跑过 §4.2 全部配置，才算过。
