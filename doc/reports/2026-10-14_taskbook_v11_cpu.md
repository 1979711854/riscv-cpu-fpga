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
2. **你的任务表（不变）**：`覆盖 A` → `覆盖 B` → `B1-RAS` → `B1-BTB`。**Cache 不再占你时间。**
3. **新增义务（很重要）**：改完 RTL 的回归里，**RT-Thread 四种配置也要跑**（`-DCache -ICache` 等）
   —— 它是**唯一**能抓到"停顿相关"缺陷的组合（v10 §3.1 就是这么漏过去的）。
4. **基线数字没变**（A1 口径）：双发射+`EARLY_LD` **232,345** 拍/迭代、板上 **365.93 分**；
   `DESIGN_REV` 从 `0x20261018` 走到 **`0x2026_1019`**。
5. **第一约束仍是时序**：CPU 域余量 **+0.068 ns / 0 失败端点（17,216）**。

---

## 1. 当前基线（同 v10 §1，唯一更新 = `DESIGN_REV`）

| 配置 | 怎么跑 | 每迭代周期 | CoreMark/MHz |
|---|---|---|---|
| **双发射 + `EARLY_LD`（板上口径）** | `run_coremark.ps1 -Iter 1 -EarlyLd` | **232,345** | **4.304** |
| 双发射 + `EARLY_LD=0` | 去掉 `-EarlyLd` | 252,730 | 3.957 |
| 单发射 | 加 `-Single` | 303,140 | 3.299 |
| 双发射 + I+D Cache | 加 `-DCache -ICache -EarlyLd` | 235,628 | 4.244 |

* `DESIGN_REV` = **`0x2026_1019`**（`rtl/core/csr_file.v`）。**你改 RTL 必须再递增**（约定 42）。
* riscv-tests 判据不变：**49 PASS / 1 FAIL / 0 TIMEOUT**，唯一 FAIL = `ma_data`（**别修**）。
* 板上实测：365.93 分 @85.0051 MHz（ITER=4280，位流 `bcd8fdd2` / `RTL=0x20261017`）。
* 时序唯一口径：`report_timing/cpu_top_board.rtr` 的 Setup Summary，只看 `u_pll→u_pll` 那行
  —— **+0.068 ns / 0 失败端点（17,216）**。别拿 pnr 每个 seed 打的 `Setup(Slow): −1.1xx` 当 CPU 时序
  （那是被 21 条跨域建模假象主导的全设计最差值，对 CPU 侧改动**完全不敏感**）。

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

### 2.4 [!] 这两处修复**吃掉了 85 MHz 的余量**（2026-10-14 实测，**和你直接相关**）

修完功能后把 85 MHz 生产档（Cache 全关）重出，**时序不过**：

| 位流 | CPU 域 `u_pll→u_pll` | 失败端点 | 结论 |
|---|---|---|---|
| rev1017 `bcd8fdd2`（旧生产档）| **+0.068 ns** | 0 / 17,216 | 达标（已板级验证 365.93）|
| rev1019 `aad1e2ac`（CoreMark 重出）| **−0.153 ns** | **16 / 16,581** | `Some Constraints Violated` ✗ |
| rev1019 `382ce876`（rtthread 重出）| **−0.153 ns** | **16 / 16,581** | 同上（两次独立运行**逐位相同** ⇒ 确定性）|

**成因**：那两处修复都是 `&& mem_ready_int`，而 **`mem_ready_int` 是本设计里最晚的使能信号之一**
（ID/EX、EX/MEM、MEM/WB、乘法器共用；带 Cache 时它还要等取指缺失/tag 比较）—— 给**已经很晚**的
信号加扇出（这次多了 CSR 文件那十几个 FF），就把只剩 0.068 ns 的余量吃穿了。

**⇒ 你要记住两件事**：
1. **功能修复与"能不能塞进主频"是两笔账**：改完功能必须**重量时序**，别只跑仿真；
2. 如果将来真要"85 MHz + rev1019"，那要先做一笔**独立的时序优化**：给 `mem_ready_int` 这条
   使能路径减负（例如在源头加一级缓冲、或把它拆成"早/晚"两档供不同消费者用）——
   **这正好是你 B1-RAS/BTB 之外的候选题目**，且验收判据明确（CPU 域回到正 slack）。

### 2.5 上板结论（2026-10-14）

位流 `90944754`（rtthread + I+D @76.5052 MHz，`RTL=0x20261019`）：两条线程 + `[hb]` 无断 +
**真按键下完一局判出 `WHITE wins`** + **接屏下棋正常**。（未修前那两颗：`c10a2478` 死在 AI 第一手后的
棋盘快照、`9feaa089` 卡在 `heap = 9368 bytes` 循环重启。）

---

## 3. 你的任务表（v11）

| # | 任务 | 优先级 | 验收（一句话） |
|---|---|---|---|
| **覆盖 A** | `tb_amo_cpu.S` 转 tohost 判分 + 从 `$skipThese` 摘出 + **"弄坏 `amo_unit` 能 FAIL"** 验证 | **P0（热身）** | 加进回归、能 FAIL、且弄坏能抓到 |
| **覆盖 B** | `sim/tests/hi_fetch.S`（代码 > 32 KB 取指）+ **"把 `imem_addr2` 截位改回去能 FAIL"** 验证 | **P0（热身）** | 同上 |
| **B1-RAS** | 返回地址栈（**真正拿分的**） | **P0** | 见 v10 §5；`+PROF` 看 `region cycles` 下降 |
| **B1-BTB** | BTB（赛题点名） | **P1** | 见 v10 §6，**排在 RAS 之后**；必须配"预测目标校验"（v10 §7）|

**顺序：覆盖 A/B → RAS → BTB**（覆盖 A/B 是 2026-10-12 就分给你的，一直没人做；
它们也是建立"**弄坏了能 FAIL**"这套纪律的最好热身）。

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
scripts\run_coremark.ps1 -Iter 1 -EarlyLd                # region cycles 必须 = 232,345
scripts\run_own_tests.ps1 -DCache -ICache -EarlyLd       # 2 PASS
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
