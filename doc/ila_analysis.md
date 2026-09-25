# ILA 波形分析与流水线效率报告

> 对应赛题《FPGA 创新设计赛道选题指南（紫光同创）》选题一「性能测评标准 · 3. 技术实现与文档 (2)」：
> 「需提交详细的性能分析文档。利用 ILA 抓取的波形图，分析 CPU 在执行 CoreMark 关键算法时的流水线效率。」
> 编制日期：2026-09-21

## 0. 先说清楚数据来源边界

这份文档分三块，**状态不同，不要混淆**：

| 部分 | 内容 | 状态 | 证据形态 |
|---|---|---|---|
| **A** | 流水线效率量化分析（停顿/冲刷/前递占比、CPI） | **已完成** | 仿真逐拍观测，全量统计 |
| **B** | 流水线时序波形图（2 张） | **已完成** | `doc/figures/pipeline_*.svg` / `.png`，仿真时序图（非 ILA 截图）。取自 `core_bench_list` 的两个热循环，见 §3/§4 |
| **C** | 硬件在环 ILA 抓取 | **部分完成** | 分支冲刷那一例已抓到真实硬件波形（`doc/figures/ila_capture_branch.svg`，来源是平台 Debugger 导出的 CSV）；`.fic` 与 `.sbit` 生成流程已跑通。**load-use 停顿 / 前递两个窗口尚未抓**（需把触发条件改为 `id_ex_mem_read` 上升沿再抓一次）。步骤见 §7 |

**为什么可以先做 A/B**：ILA 抓的是「有限深度的窗口 + 真实硬件凭证」，而效率分析
需要的是「全量、可复现的统计」。两者信号同名、定义同源（都取自 `rtl/core/core.v`
的同一批内部信号），因此仿真结论与 ILA 波形可以互相印证 —— 仿真给结论，ILA 给凭证。

**B 部分的图是仿真时序图，不是 ILA 截图**，报告中引用时必须如实标注。
真正的 ILA 截图请在 §7 流程跑完后替换或补充。

---

## 1. 分析口径：CoreMark 计时区间

> [!] **口径提醒（2026-09-25 补）**：**§1 ~ §6 的全部数字都是 2026-09-23
> 「BTB/BHT 之前」那一版的实测剖析结果，基准是 358,846 拍。**
> 加 BHT 之后当前基准是 **354,119 拍**（`+PROF` 可复现，见 §8）。
> 这两套数字**不要混用**：
> * §1~§6 的分项（load-use 20,720 / 分支 50,070 等）是**旧版**的，
>   它们精确闭合于 358,846 —— 想更新到 BHT 之后需要重跑一次 `+PROF`。
> * §7 及本章末尾用的基线是**当前值 354,119**。
>
> 保留旧数字的理由：它是"加 BHT 省了 4,727 拍"这个结论的**对照基线**，
> 删掉就没法复核了。CLAUDE.md「当前进度」里记的是新基线。

CoreMark 的 `start_time()` / `stop_time()` 各是一次读 MMIO `0x7FF4`
（`scripts/coremark_port/core_portme.c`）。对应的读指令在 ELF 里是
**PC `0x2908`（start_time）/ `0x2920`（stop_time）的 `lw a5,0(a5)`**，
进入 MEM 级时 `mem_re=1` 且地址为 `0x7FF4`，可直接观测，因此能**精确框出计时区间**，
把「纯 CoreMark 算法」与「UART 打印轮询」区分开。

```
计时区间长度     : 358,846 拍   ← 与 CoreMark 自报 Total ticks 逐位一致
```

> **关于起止周期号**：本次逐拍 trace 直接看到 `stop_time` 的读指令（PC 0x2920）
> 在第 **402,182** 拍进入 MEM 级；`start_time` 在那之前（早于本次 trace 窗口起点
> 第 21,000 拍），所以本文档只报**实测过的区间长度 358,846 拍**，不去猜一个
> 没测到的起点值。需要绝对起止号时跑一次 `+PROF`，它会打印
> `start_time cycle` / `stop_time cycle`。

> 口径提醒：整场仿真总周期是 **1,462,898** 拍，其中约 108 万拍是一次性 UART 打印
> 轮询开销（打印区间 CPI 约 2.3，纯属轮询循环，不能混进算法效率统计）。
> **效率分析必须只用 358,846 拍这个区间**。

> **§3/§4 波形图的口径**：两张图取自一次覆盖 **386,000 拍**的逐拍 trace
> （起点第 21,000 拍），比计时区间**略宽**（区间前 1,790 拍不在窗口内）。
> 所以图里引用的"冲刷次数"都注明是**窗口内**计数，与 §2.2 的区间口径
> （37,098 次）不是同一个分母 —— 引用时不要混。

---

## 2. 流水线效率实测结果

### 2.1 总体

| 指标 | 数值 |
|---|---|
| 计时区间周期数 | **358,846** |
| 提交指令数 | **288,056** |
| **CPI** | **1.2458** |
| 流水线效率（理想 CPI=1） | 75.2% |

> 改造前（取指重定向之前）为 420,070 拍 / CPI 1.4583 / 效率 68.6%。
> **提交指令数改造前后完全相同**（都是 288,056）—— 说明只改了时序、没改行为。

提交指令数的测法：在测试台里搭一条**影子流水线**，逐级镜像 `core.v` 中
`IF/ID`、`ID/EX`、`EX/MEM`、`MEM/WB` 四个级间寄存器的清零/暂停条件，
从而数出真正流过 WB 的指令条数。不能直接用 `mem_wb_reg_write` 计数 ——
store / branch / jump 不回写寄存器，会被漏掉。

### 2.2 效率损失分解

| 损失来源 | 发生次数 | 每次代价 | 损失周期 | 占计时区间 |
|---|---|---|---|---|
| **分支/跳转** | 37,098 | **1 或 2 拍**（见下） | **50,070** | **13.95%** |
| load-use 停顿 | 20,720 | 1 拍 | 20,720 | 5.41% |
| 除法停顿（多拍除法器） | 0 | — | 0 | 0.00% |
| **合计** | | | **94,916** | **24.78%** |

自洽性校验：`288,056（有效）+ 94,916（损失）= 358,846` [OK]

**结论：控制冒险（分支/跳转）仍是第一瓶颈，单项占掉 14.0% 的周期，是 load-use
停顿的 3.6 倍。**

> **三轮演进**：分支损失 111,294（3 拍）→ 74,196（取指重定向，2 拍）→ **50,070**
> （ID 级静态预测，命中 1 拍）。计时区间 420,070 → 382,972 → **358,846**。
> 冲刷**次数**与 load-use 停顿**次数**全程都没变 —— 变的只是每次冲刷的代价。
> 明细：命中 28,860×1 + 误判 2,367×2 + 未预测 8,238×2 = 50,070。

### 2.3 前递的贡献（正向数据）

| 事件 | 次数 |
|---|---|
| 从 EX/MEM 前递 | 56,540 |
| 从 MEM/WB 前递 | 83,845 |
| 合计前递 | 140,385 |

前递没有直接"节省"周期，但它把大量 RAW 相关在 1 拍内解决掉了。
反证：如果把这些相关全部退化成停顿，按 140,385 次、每次至少 1 拍估算，
将额外增加约 14 万拍 —— 相当于计时区间的 **37%**。**前递是当前效率的主要贡献者。**

### 2.4 分支事件构成

计时区间（358,846 拍）内的分支/跳转统计：

| 类型 | 次数 |
|---|---|
| 条件分支总数 | 53,173 |
| ├ taken | 29,398 |
| └ not taken | 23,775 |
| 条件分支中 **后向** | **25,664**（其中 taken **23,297 = 90.8%**） |
| 条件分支中 前向 | 27,509（其中 taken 6,101） |
| `jal` / `jalr` | 5,563 / 2,137 |
| **冲刷事件合计** | **37,098** |

**冲刷数精确闭合**：`29,398（条件分支 taken）+ 5,563（jal）+ 2,137（jalr）= 37,098` [OK]
—— 也就是"凡是真正跳转的分支/跳转指令都产生一次冲刷"，与设计行为完全一致。

> **后向分支 90.8% 都跳转** 是原始计数，不掺任何"预测器能省多少拍"的假设
> （那取决于具体实现）。但它直接支撑了 §6 的判断：**"后向分支预测跳转"这类
> 静态规则就能覆盖绝大部分循环回边**，是加分支预测时成本最低的方案。

---

## 3. 关键算法波形一：`core_bench_list` 内层循环

`core_bench_list` 是**最热**的函数：它的一条回跳分支 `0x0d04` 在本次 386,000 拍的
trace 窗口内触发了 **5,780 次冲刷**，是窗口内单项第一。反汇编（`riscv-none-elf-objdump -d`）：

```
cf4:  mv   s0,a4
cf8:  lw   a4,0(s0)        ; 访存
cfc:  sw   a3,0(s0)
d00:  mv   a3,s0
d04:  bnez a4,cf4          ; ← 回跳分支，本循环几乎必然跳转
```

实测：**5 条指令 / 7 拍 → 本循环 CPI 1.4**，其中 **2 拍耗在 `0x0d04` 的回跳冲刷上**。
7 拍 = 5 拍发射 + **2 拍**冲刷空缺。这同时也是"分支惩罚 = 2 拍"的**独立实测证据**
（改造前是 3 拍，即 5+3=8 拍）。

![core_bench_list 内层循环流水线时序](../figures/pipeline_matrix_loop.svg)

**读图要点**（信号名与 §7 的 ILA 探针一一对应）：

- 上半部分是五级流水占用格。`IF 取指` 一格中是 `pc_r`（本拍发出的取指地址，
  也是顶层端口 `pc`）；`ID/EX/MEM` 是各级 PC；`WB 写回` 是目的寄存器号
- 浅红色整列 = 分支冲刷周期；浅黄色整列 = load-use 停顿周期
- 每 7 拍重复一次（图中显示两轮：335224→335231、335231→335238）；
  第 335230 拍 `分支指令 (EX)` 与 `分支 taken` 同时拉高（`EX` 里是 `0x0d04`），
  `分支/跳转冲刷` 也在该拍拉高，`ID`/`EX` 两行出现虚线空格
- `分支 taken` 已与 `id_ex_branch` **相与**：`branch_taken` 是比较器的裸结果，
  非分支指令上也可能为 1，不相与会多出假跳转（`scripts/trace2svg.py` 的 `lane_state`）
- 本循环 `load-use 停顿` 一栏全程为低 —— `lw a4,0(s0)` 与 `bnez a4` 之间的间隔
  由**前递**消化，不需要停顿。这是前递生效的直接证据
- `前递 EX/MEM`、`前递 MEM/WB` 两栏在本循环里每 7 拍各拉高一次

> 口径提醒：图里 `IF 取指` 行是 `pc_r`。冲刷后本设计用 `pc_r <= ex_target + 4`
> 重定向（目标地址已在冲刷当拍发出），所以 `pc_r` 会**跳过目标指令本身** ——
> 判断循环边界请看 `ID 译码` 行，那里才是完整的指令序列。

---

## 4. 关键算法波形二：停顿与冲刷叠加

同一个 `core_bench_list` 里另一条回跳分支 `0x0dbc`（窗口内冲刷 **2,778 次**），
它所在的内层循环**同时**受 load-use 停顿与分支冲刷影响：

```
dac:  lw   a5,0(a5)        ; 访存
db0:  beqz a5,de8
db4:  lw   a4,4(a5)
db8:  lbu  t1,0(a4)        ; ← 紧跟上一拍的 lw，load-use 相关
dbc:  bne  t1,a3,dac       ; ← 回跳分支
```

实测：**5 条指令 / 10 拍 → CPI 2.0**。10 拍 = **5 拍发射 + 3 拍 load-use 停顿
+ 2 拍分支冲刷** —— 两类冒险的代价在同一个循环里可以直接对比。

![停顿与冲刷叠加的流水线时序](../figures/pipeline_hazard_mix.svg)

**读图要点**：

- 第 333854 拍 `分支/跳转冲刷` 拉高 → 该拍 `EX` 中是 `0x0dbc` 的 taken 分支
  （`分支指令 (EX)` 与 `分支 taken` 同时为高）
- 冲刷后 `EX` 级**连续 2 拍为空**（333855、333856）—— 这就是 2 拍惩罚的可视化。
  `fl` 只在第 1 拍拉高，第 2 拍是同步读 BRAM 的取指延迟，不单独置位
- 第 333847、333850、333852 拍 `load-use 停顿` 拉高；停顿期间 `IF`/`ID` 保持不动
  （重读同一 word，见 `core.v` PC 段注释），`ID 译码` 行出现虚线空格
- `MEM 读` 与 `前递 MEM/WB` 两栏在这个循环里几乎每拍都在动 —— 访存密集

---

## 5. 分支惩罚：当前 **2 拍**（这段更正过两次，记清楚免得再乱）

**当前设计**：分支在 EX 级解析后，`ex_flush` 只清 IF/ID **一拍**，同时把跳转目标地址
**当拍**旁路给取指端。因为取指是同步读 BRAM（1 拍延迟），目标指令在冲刷后第 2 拍
就能进 IF/ID —— 所以吞吐损失是 **2 拍**。

### 证据一：逐拍提交缺口（7 拍里只有 5 拍提交）

§3 那个 7 拍循环的 `影子流水线` WB 有效位（`vwb`）：

```
cyc 335224: v_wb=1   ← 循环体第 1 条
cyc 335225: v_wb=1
cyc 335226: v_wb=0   ┐ 2 拍气泡
cyc 335227: v_wb=0   ┘
cyc 335228: v_wb=1
cyc 335229: v_wb=1
cyc 335230: v_wb=1   ← 分支指令自身提交，同拍 fl=1（冲刷拍）
（335231 起进入下一轮，序列重复）
```

**7 拍 = 5 条指令 + 2 拍气泡** —— 与"分支惩罚 2 拍"一致。

> 注意气泡出现在第 335226–335227 拍，而**冲刷发生在第 335230 拍**，差 3~4 拍。
> 这是五级流水线的深度造成的：分支在 EX 级解析时取指端已多推进了几拍，
> 被冲掉的那 2 拍空档要过几拍才体现在 WB 的提交位上。
> **别指望"冲刷拍紧跟着两拍无提交"** —— 在流水线填满的热循环里不是这样；
> 只有在循环刚进入/退出时才会看到紧邻的空档。

### 证据二：区域自洽

```
288,056（提交）+ 20,720（load-use 停顿）+ 50,070（分支）= 358,846 [OK] 精确闭合
```

且 `420,070（改造前）− 382,972（改造后）= 37,098`，**恰好等于冲刷事件数** ——
与"每次冲刷省 1 拍"完全吻合。

### 历史沿革（两次更正都不矛盾，是设计变了）

| 时间 | 实现 | 文档结论 |
|---|---|---|
| 改造前（长期） | `ex_flush` + `ex_flush_d` 双拍冲刷 | 文档写"惩罚 2 拍"，**与实际不符** |
| 2026-09-21 上午 | 同上 | 逐拍实测 + 全区间自洽校验证明实际吞吐损失是 **3 拍**（冲刷 2 拍 + 1 拍等取指数据回填），文档更正 |
| 2026-09-21 下午 | **取指重定向**：删掉 `ex_flush_d`，目标地址改为冲刷当拍旁路给取指端 | 惩罚降到 **2 拍**，设计被真正修好；文档再次更正为本节内容 |

改造前那套推导（全区间 `3 × 193,698 + 174,890 + 2,013 + 4` 才闭合）**是正确的**，
它描述的是当时的实现；改造后换成上面的区域自洽式。

### 根因（为什么改造前是 3 拍、改造后是 2 拍）

本设计取指用**同步读 BRAM**（1 拍延迟），并靠 `if_addr_d` 做取指补偿。

- **改造前**：拍 T 置 `ex_flush`，拍 T+1 再置 `ex_flush_d` 补第二道冲刷，
  到拍 T+2 才锁存目标指令 → 3 拍空缺
- **改造后**：拍 T 置 `ex_flush` 的**同时**把 `ex_target` 直接送进 `imem_addr` 的 mux
  （`pc_r <= ex_target + 4`，因为地址已在当拍发出），数据正好在拍 T+1 回来、
  拍 T+1 就锁存目标指令 → 2 拍空缺

> 一句提醒：**别再用"文档写几拍"来判断，用自洽校验式实测。**
> 判据是 `提交 + 停顿 + 惩罚 × 冲刷数 = 计时区间`，改流水线后这个式子必须能闭合。
> 另外 §7.3 那个 7 拍循环本身就是最直接的实测：**5 条指令 / 7 拍**，
> 2 拍空缺只可能来自分支（该循环无 load-use 停顿）。

---

## 6. 优化建议（按收益排序）

| 优先级 | 措施 | 预期收益 | 代价 |
|---|---|---|---|
| ~~P0′~~ | ~~缩短分支惩罚~~ —— **已做**：取指重定向（删 `ex_flush_d`，目标地址同拍旁路给取指） | 分支惩罚 **3 拍 → 2 拍**，分支损失 111,294 → **74,196** 拍，计时区间 −8.83% | 已完成并验证（见 `doc/reports/2026-09-21_branch_opt_verify.md`） |
| **P0** | **加分支预测（BHT / BTB）** | 最直接的场景是 `matrix_test` 这类**后向循环分支**（几乎必然跳转）。实测区域内后向分支 25,664 条中 **90.8% 都跳转** —— 「后向分支预测跳转」这种静态规则即可命中绝大多数。若把未命中率降到 10%，剩余冲刷损失约 7,400 拍，可省约 **6.7 万拍 ≈ 17.4%** | LUT 余量 98%，资源不是约束；属承重改动，必须完整回归 |
| P1 | load-use 停顿消除 | 若能靠增加前递路径 / 编译器调度消化，可省约 **2.07 万拍（5.8%）** | 改动风险较高，收益中等 |
| P2 | 分支解析提前到 ID 级 | 可再省 1 拍惩罚（2 拍 → 1 拍） | 需额外比较器与前递，时序压力上升，改动大 |
| ~~P3~~ | ~~提升 Fmax~~ —— **已做（2026-09-25）**：板载 27MHz 经 PLL 倍频到 **45 MHz**，并按报告的分析切掉 `addr_result` 假路径 | 得分按频率线性提升：同一设计 27 MHz 下 75.25 → **45 MHz 下 125.42 CoreMark（+66.7% = 纯时钟比）** | ~~受平台固定 27 MHz 时钟限制~~ 该限制**已被 PLL 绕开**。实测约束 45.0005 MHz、可达 51.5198 MHz（见 `doc/resource_efficiency.md` §10） |

**理论天花板**：若两类损失全部消除，`10^6 / 288,056 = 3.472 CoreMark/MHz`
（当前 **2.787**）。这是报告里可以做「优化闭环」叙事的抓手 ——
已经拿到的一环是 2.380 → 2.787，下一环是预测器。

---

## 7. 硬件在环 ILA 抓取方案（待执行）

> [!] **本章 2026-09-25 更新**：原来按"远程 FPGA 平台"写的，
> 现在**比赛已确认用本地盘古板**，所以**本地 PDS Debugger 那条路变成主路径**
> （原 §7.3 的"备选路径"升为主路径），远程平台那条降为备选。
> 另：时钟已到 49.8927 MHz、RTL 加了 BHT，探针清单与采窗都相应更新。

### 7.0 结论：平台出 JTAG 和波形界面，PDS 出 `.fic` 和比特流

**查证结果（2026-09-21，实读远程平台前端 + 本机 PDS 安装目录）**

`http://www.logicmatrixsemi.com:5174/` 是「FPGA LAB 远程 FPGA 实验平台」，
开发者工作区侧边栏包含：

```
设备管理 · 固件烧录 · 工作区 · 示波器 · 信号发生器 ·
逻辑分析仪 · 串口通信 · 摄像头 · 数字孪生 · ILA
```

即 **平台自带一个名为 "ILA" 的模块**。它的面板有一条按钮叫
**「导入fic文件」**（Xilinx 板子则显示「导入LTX文件」，文件过滤器是 `.ltx`）。
抓取时调用的接口是 `POST /modules/debugger/jtag-ila/config`，参数含
`deviceId / ilaChannelCount / sampleDepth / triggerConditions / mode / ilaIndex / coreName`。

**所以分工是这样的**：

| 环节 | 谁负责 |
|---|---|
| 把 debug 核插进设计、生成**探针描述文件 `.fic`** | **本地 PDS（Fabric Inserter）** |
| 生成含 debug 核的比特流 `.sbit` | **本地 PDS** |
| 烧写比特流 | 平台「固件烧录」（也支持本地上传 `.sbit`） |
| **JTAG 在环抓取 + 波形显示** | **平台 ILA 模块** |

也就是说：**不需要**在自己电脑上把 PDS Debugger 连到板子（本地也没有那条 JTAG 通路），
但**仍然需要本地 PDS 走一遍 Fabric Inserter**，因为 `.fic` 只有 PDS 能生成。
平台负责的是 JTAG 通道和波形界面这两件本地做不到的事。

> 一句话：**平台要你上传的那个 `.fic`，是你自己在 PDS 里做出来的。**

`.fic` 的真实身份（读 PDS 自带例程 `example/PG2L100H_adc_test/pnr/adc_ctrl_demo_syn.fic` 确认）：

```
#Fabric Core Inserter Project File
#Generated by Fabric Inserter (version 2020.3-rc3 build 62368) at ...
Project.device.designInputFile=.../pnr/synthesize/adc_ctrl_demo_syn.adf
Project.device.deviceFamily=Logos2
Project.device.deviceModel=PG2L100H
Project.device.devicePackage=FBG676
Project.unit<0>.clockChannel=nt_clk
Project.unit<0>.dataDepth=1024
Project.unit<0>.triggerChannel<0><1>=pdata[0]
Project.unit<0>.triggerChannel<0><2>=pdata[1]
...
```

即 **Fabric Inserter 工程文件**，核心内容是**「第 N 号采集通道 ↔ 设计里的哪个信号」的映射表**，
外加器件型号、采样时钟、采样深度。平台的波形软件就是靠它把 JTAG 读回的裸比特流
翻译成有名有姓的波形 —— **没有它，抓回来的数据没法解读**。

**要注意的一点**：平台有一句提示文案「当前设备配置未启用该仪器」——
说明**仪器是按设备逐个配置启用的**。你预约到的那台设备可能开了逻辑分析仪但没开 ILA。
申请设备前先确认，或直接找赛方技术支持问（QQ 群见赛题指南第五节）。

### 7.1 ILA 探针清单与位宽预算

**先看硬限制**。DebugCore IP 的官方能力说明（`ip/system_ip/ips_debug_core/.../info.html`）写着：

- 数据缓存深度 **64 ~ 128k**（2 的整数幂）
- 数据缓存位宽 **1 ~ 4096**
- **Trig Match Unit 信号位宽 1 ~ 256** ← 触发比较单元的位宽上限
- Trigger Port 个数 1~16，Trig Match Unit 总数不超过 16

对应到 RTL 就是 `ips_dbc_compare_256b_v1_0.v`。平台的校验规则
`maxTotalChannelBits: 256`、`maxSignalsPerIla: 32`、`maxIlaCores: 16` 与之吻合。

**结论：256 位是触发比较单元的位宽上限**（采集缓存本身可以更宽，到 4096），
而平台又把它作为总通道位宽的硬性校验，所以实际按 **不超过 256** 来做。

所以探针要**精打细算**。下表按「能讲清流水线故事」裁剪，并给出位宽预算与通道分配：

| 通道位 | 信号 | 位宽 | 取法 / 说明 |
|---|---|---|---|
| `[14:0]` | `pc[14:0]` | 15 | 取指 PC。**网表里叫 `pc`，不叫 `pc_r`**，且在 `u_core` 里（顶层 `cpu_top_board` 没有）；内存 32KB，PC < 0x8000 |
| `[29:15]` | `if_id_pc[14:0]` | 15 | ID 级 PC |
| `[44:30]` | `id_ex_pc[14:0]` | 15 | EX 级 PC |
| `[59:45]` | `ex_mem_pc[14:0]` | 15 | MEM 级 PC |
| `[66:60]` | `if_id_instr[6:0]` | 7 | 只取 opcode，看指令类别 |
| `[67]` | `stall` | 1 | load-use 停顿（**触发信号候选**） |
| `[68]` | `div_stall` | 1 | 多拍除法停顿 |
| `[69]` | `ex_flush` | 1 | 分支/跳转冲刷（**首推触发信号**） |
| `[70]` | `id_ex_mem_read` | 1 | EX 级是 load（`stall` 的来源，便于解释停顿成因） |
| `[71]` | `fwd_a_ex` | 1 | 从 EX/MEM 前递（rs1） |
| `[72]` | `fwd_b_ex` | 1 | 从 EX/MEM 前递（rs2） |
| `[73]` | `fwd_a_wb` | 1 | 从 MEM/WB 前递（rs1） |
| `[74]` | `fwd_b_wb` | 1 | 从 MEM/WB 前递（rs2） |
| `[75]` | `id_ex_branch` | 1 | EX 级是否分支指令 |
| `[76]` | `branch_taken` | 1 | 分支条件结果 |
| `[77]` | `mem_we` | 1 | 访存写使能 |
| `[78]` | `mem_re` | 1 | 访存读使能 |
| `[79]` | `mem_wb_reg_write` | 1 | WB 是否回写寄存器 |
| `[80]` | `bht_hit` | 1 | **BHT 查表命中**（2026-09-25 新增，下同）|
| `[81]` | `bht_taken` | 1 | BHT 预测的方向（计数器高位）|
| `[82]` | `id_pred_taken` | 1 | ID 级最终预测：跳 or 不跳 |
| `[83]` | `id_redirect` | 1 | ID 级**实际生效**的重定向（与 `id_pred_taken` 在 stall/flush 时会分叉）|
| `[84]` | `ex_mispred` | 1 | 预测 taken 但实际 not-taken（误判恢复）|
| `[85]` | `id_ex_pred_taken` | 1 | 该指令在 ID 级**实际发生过**预测重定向（寄存的是 `id_redirect`）|
| **合计** | | **86 位** | 远低于 256，余量充足 |

> [重点] **`[80]`~`[85]` 这 6 位是本次（BHT 之后）新增的**，也是抓波形的**新看点**：
> 加 BHT 之前分支只有"冲刷/不冲刷"两种状态，现在能直接看到
> **查表命中、预测方向、实际重定向、误判恢复**这四件事的先后关系 ——
> 这正是"动态分支预测"这个评分项最直观的证据。
>
> ⚠️ 抓 `[83]`/`[85]` 时注意：**必须看 `id_redirect`，不能看 `id_pred_taken`**
> （`core.v` 有注释：两者在 stall / `ex_flush` / `div_stall` 时会分叉，
> 寄存错了会让 EX 级误判"预测正确"而不冲刷）。

> [!] **`ex_flush_d` 已从设计中删除**（2026-09-21 取指重定向改造），探针里不能再引用它
> —— 旧版本文档的 `[70]` 原本就是它。这一位改接 `id_ex_mem_read`，位宽预算不变。
> 若在 Inserter 里选不到某个信号，先确认它在当前 RTL 里还存在。

> **省位宽的关键**：PC 只取低 15 位。若按 32 位传，四个 PC 就吃掉 128 位，
> 加上其他信号直接顶到 256 上限。地址总线是位宽预算里最贵的东西。

采样深度取 **1024**：**`1024 / 49.8927MHz = 20.5 µs`**
（27 MHz 时代 37.9 µs、45 MHz 时代 22.8 µs —— ILA 采的是系统时钟，
PLL 提频后窗口按比例缩短）。若要看更长的窗口，把深度调到 4096（= 82 µs）。
DebugCore 的缓存深度范围是 **64 ~ 128k**（2 的整数幂），要抓更长的窗口可以调大，
但要注意 BRAM 占用。

### 7.1.1 [!] 三个设置项到底在哪个界面（2026-09-25 查官方手册更正）

**这一节是实机操作时最容易卡住的地方。** 本章此前把"采样时钟 / 触发条件 / 触发位置"
三样**都写在 Inserter 的 `Trigger Parameters` 里**，**那是错的** —— 依据后续实机反馈
与官方手册更正（`D:\pango\PDS_2022.2-SP6.4\doc\Fabric_Inserter_User_Guide.pdf`、
`Fabric_Debugger_User_Guide.pdf`）。

**Fabric Inserter 的 DebugCore 对话框只有三个标签页**：
`Trigger Parameters` / `Net Connections` / `PowerOn Init Parameters`。

| 要配的东西 | 在哪个界面 | 说明 |
|---|---|---|
| **采样时钟** | **Net Connections → Modify Connection → Select Net → 右侧 Channel View 的 `Clock Port` 页签** | **不在 Trigger Parameters 里。** Channel View 每个页签 = 一个 Port：`Trigger Port`(256 ch) / `Data Port`(4096 ch) / **`Clock Port`(仅 1 ch)** / `Reset Port`(仅 1 ch)。手册明确：Clock/Reset "必须连接至对应的时钟信号和复位信号上，如果时钟端口和复位端口连接不正确将导致 debug Core 无法正常工作" |
| 采样**沿** | Trigger Parameters → 数据捕获及存储设置 → `Sample On` | 这只是 **Rising / Falling**，是"沿"不是"源"，极易看错 |
| **最大采样深度** | Trigger Parameters → 数据捕获及存储设置 → `Sample Depth` | 范围 **64 ~ 131072**（2 的整数幂）。这是**上限**，运行时只能调小、不能超过 |
| 匹配单元数 / Match Type | Trigger Parameters → 触发端口及匹配单元设置 | `Match Type` 要选 **`Basic w/edges`** —— 只有带 edges 的才能在运行时把 Value 填成 **`R`（上升沿）**。选 `Basic` 只能比电平 |
| **触发条件** | **Fabric Debugger → Trigger Setup（运行时）** | **不用在 Inserter 里配，也不用重新综合** |
| **触发位置 `Position`** | **Fabric Debugger → Trigger Setup → Capture Settings** | 仅当 `Type = Windows` 时可用，取值 **0 ≤ N ≤ Depth−1** |

> [重点] **官方手册原文**（`Fabric_Debugger_User_Guide.pdf` §5.3）："下载包含 Debugger Core
> 位流的器件，双击器件栏中的 'Trigger Setup' 叶节点，打开 Debugger Core 图形配置对话框，
> **实时配置 Debugger Core 无需重新编译**"。
>
> **所以触发条件、采样深度、触发位置这三样都是运行时配的** —— 改触发条件**不会**让你
> 重跑综合/布线/烧板。调试时省下的时间非常可观：想换触发信号、想看触发前后的不同窗口，
> 改了直接 Run。
>
> 只有 **通道连线**、**端口/匹配单元数量**、**Match Type**、**最大 Sample Depth**
> 这几样是综合期定死的 —— 改了就得重走 Inserter → P&R → 出比特流 → 烧板。

**运行时的 Trigger Setup 分三块**（与 Inserter 里那三块同名，别搞混）：

* `Match Function` —— 给每个 Trigger Unit 定一个比较式。**信号的值在这里填**，
  例如把 `ex_flush` 那一行的 Value 填 `R`（上升沿）。
  Function 可选 `==` / `<>` / `>=` / `>` / `<` / `<=` / `In Range` / `Out of Range`；
  Value 在 Binary 进制下可接受 `X`（不关心）、`0`、`1`、`R`（上升沿）、`F`（下降沿）、
  `B`（任意翻转）、`N`（不翻转）。
* `Trigger Condition` —— 多个 Trigger Unit 的与/或/非组合（Boolean 页签），
  或顺序触发（Sequencer 页签，级数 ≤ 16）。表达式写法如 `!TU1&&TU2`。
* `Capture Settings` —— **`Type`**（`Windows` / `N Samples`）、窗口数、每窗口深度、
  **触发位置 `Position`**。手册：`Type=Windows` 时"每个窗口中捕捉的采样点数必须为 2 的幂，
  触发点可以是窗口中的任何位置"。

配好后点 **`Trigger Setup → Run`** 下发；强制触发用 **`Trigger Immediate`**
（忽略触发条件，窗口从 sample 0 开始）；卸载用 **`Stop Acquisition`**。

> [!] **`Position` 怎么理解**：它定义**触发点在窗口内的位置**，取值 `0 ~ Depth−1`。
> `0` = 触发点在最前（只看得到触发**之后**），`Depth−1` = 触发点在最后
> （只看得到触发**之前**）。**要看"前因后果"，取中点**（`Position = Depth/2`）。

> [!] **`Enable Multi-windows and NSample` 保持【不使能】** —— 手册原文："使能该功能会对
> Debug Core 的时序性能造成一定的影响，如果需要 Debug Core 工作在较高频率时，不建议使能
> 该功能"。我们 slack 只有 **+1.550 ns**，别开。单窗口下 `Type` 仍可选 `Windows`
> 并把窗口数填 **1**，`Position` 照样可用。

> [!] **ILA 的时钟域**：`Clock Port` 要接 **PLL 输出的 `clk_sys`（49.8927 MHz）**，
> 不是板载 27 MHz 晶振 —— 抓的是 CPU 那条流水线。接错域抓到的全是亚稳态。
> 在网表里这个信号就叫 **`clk_sys`**，位于**顶层 `cpu_top_board`**
> （是 `pll u_pll` 的 `clkout0`，实测网表 `cpu_top_board_syn.vm` 里有 `wire clk_sys;`）。

### 7.1.2 信号在哪个模块里找（`cpu_top_board` → `u_soc` → `u_core`）

Inserter 的 **Select Net** 对话框里：左上 `Schematic View`（图形）、右侧
**`Channel View`**（要连的 channel，按 Port 分页签）、左下 **`Module View`**（层次树）、
下中 **`Net View`**（当前选中模块的网线/总线）。设计的层次是：

```
cpu_top_board            <- 顶层（.pds 的 top module）
 ├── u_pll  (pll)         <- 里面不用选任何信号
 └── u_soc  (cpu_top)
      └── u_core (core)   <- [重点] 探针信号全在这里
```

* **数据/触发信号全部在 `u_core` 里** —— §7.2 的 14 个探针属性都加在 `module core` 内，
  实测综合后它们确实作为 `module core` 的局部网线存在。
* **`Clock Port` 要在顶层 `cpu_top_board` 选 `clk_sys`** —— 它在 `u_core` 里看不到。

**为什么搜不到 `pc` / `pc_r`（2026-09-25 实测）**：

1. **顶层 `cpu_top_board` 里【故意没有】`pc`。** `cpu_top_board.v` 的设计目的就是把
   `pc[31:0]` / `done` 挡在板外（原因见 CLAUDE.md 关键约定 16：PDS 会把未约束的输出
   自动布到 BANKR5 的 SFP/HSST 真实引脚上）。所以在顶层搜 `pc` **必然搜不到**，
   这是预期行为，不是 bug。
2. **PC 在网表里的名字是 `pc`，不是 `pc_r`。** `core.v` 里是 `assign pc = pc_r;`，
   综合后两者合并 —— 触发器实例名还是 `\pc_r[0]`，但**它输出的网线叫 `pc[0]`**
   （实测网表 `synthesize/cpu_top_board_syn.vm`：
   `GTP_DFF_CE /* \pc_r[0] */ ... .Q (pc[0])`）。所以要在 `u_core` 里找总线 **`pc[31:0]`**。

**实用技巧**（界面文字摘自 Inserter 程序自身的 UI 字符串表，比手册准确）：

* 勾上 Filter ToolBar 左下方的 **`Show All Nets In The Net Tree View`**
  （提示文字："Show all nets in the Net Tree View without classifying according to module"）
  —— 勾上后 Module View 会被冻结，Net View 把**整个设计**的网线/总线全列出来，
  找 `clk_sys` 这种顶层网线时用它最快。
* 勾上 **`Show Complete Net Name`**
  （提示文字："Show complete net name in the format: **top_module/sub_module/sub_module/net**"）
  —— **强烈建议一直开着**：网线名会显示成 `cpu_top_board/u_soc/u_core/pc` 这种全路径，
  一眼就能看出它在哪一层，不用猜自己在看哪个模块。
* Filter ToolBar 的 **`Key Word`** 框是**模糊匹配、不区分大小写**的
  （模式下拉框选 `Net Name` 就只匹配网线名）。输入完按 **Enter** 才开始筛选。
* **Channel View 的实际结构**（手册只说"页签"，实际是带分组节点的树）：
  顶层分组节点是 **`TRIGGER PORTS`** / **`CLOCK PORT`** / **`RESET PORT`** / **`DATA PORT`**；
  通道条目的显示格式是 `CH0:<网线名>`（单通道端口）和 `CH<序号>:<网线名>`（数据端口），
  总线显示为 `Bus:<名字>`。

> [!] **连线时别点 `Schematic View` 那张图 —— 会弹 `Select Page`。**
> Select Net 对话框左上角默认勾着 **`Show Schematic Graph`**，它打开的是一个
> **分页（page）的原理图查看器**（菜单里有 `View → Page Up / Page Down`、
> `Descend` / `Return to Top`、`Mark Debug...`、`Flatten...`）。
> 因为设计是分页画的，**点击不在当前页上的网线时，查看器会弹 `Select Page`
> 让你先选页**，点击就被打断了 —— 症状是"点一下就弹框，连不上"。
>
> **两个解法**：
> 1. **把 `Show Schematic Graph` 取消勾选**（推荐）—— 整块图直接隐藏，
>    只用 `Module View` + `Net View` + `Channel View`，再不会弹页选择框。
> 2. 或把 `Select Page` 选成 **`u_core` 所在的那一页**再点。
>
> **正确连线姿势**（不依赖原理图）：在 `Channel View` 里**单击选中目标 channel 行**
> → 在 `Net View` 里**单击选中网线**（多选用 Shift / Ctrl）→ 按 **`Make Connections`**
> （快捷键 **Ctrl+M**）。「选中 + 按钮」是主路径；拖放是备选（拖放是**插入**，
> 按钮是**覆盖**，手册明确区分过）。
>
> [!] 数据端口的 channel **必须连续填**（程序里有
> "The data ports must be connected in sequence" 的检查）。
> 另外选中整条 `pc[31:0]` 会一次吃掉 32 个 channel ——
> 要只连低 15 位，得在 `Net View` 里**展开总线**再逐位选，
> 或者干脆在 RTL 里做一个 15 位的专用调试总线（见 §7.7）。

> [!] **"与用户设计端口相连的信号"连不上**：手册原文"与用户设计端口相连的信号无法与
> debug core 相连进行观测"。所以顶层端口本身（`clk`/`resetn`/`led`/`key`/`uart_*`）
> 选不了 —— 要选它们**在内部对应的网线**（如 `clk_sys`）。

**[!] 但"能选到"和"选得动"是两件事 —— 后者才是真麻烦。**

2026-09-25 实机操作时连撞三次墙，根因都是同一个：

| 试过的信号 | 结果 | 根因 |
|---|---|---|
| `pc` | 搜不到 | 它在 `u_core` 里，且顶层 `cpu_top_board` 故意没有它 |
| `pc_r` | 搜不到 | 网表里 PC 叫 `pc`（`assign pc = pc_r` 被合并）|
| `mem_re` / `mem_we` | 搜不到 | **它们是 `module core` 的输出端口**，而 **Inserter 的网线树不列模块端口的网线** |

`mem_we`/`mem_re` 在 `core.v` 里只是端口的别名（`assign mem_we = ex_mem_mem_write;`），
综合后触发器 `.Q(mem_re)` 直接就叫这个名字 —— **根本没法和端口分开选**。

再加上一个更烦的：**选中整条 `pc[31:0]` 会一次占掉 32 个数据通道**，
想只要低 15 位得展开总线逐位勾 —— 4 个 PC × 15 位 = 60 次点击。

### 7.2 探针束：把"手点连线"整个绕开

**结论：不再手点连线，改成在 RTL 里放一个探针束，用【精确标记】直接指定通道。**

依据：Fabric Inserter 手册 §4「RTL 级插核」——在 RTL 里标记信号，综合会保留它们，
**"如果 PDS 工程中没有添加 fic 文件，或添加了空的 fic 文件，那么 Inserter 打开后，
会根据 RTL 中标记的信息自动进行信号连接"**。

属性分工（查 Pango 自带例程 `example/PG2L100H_adc_test/` 确认）：

| 例程文件 | 属性 | 是否出现在 `.fic` 里 |
|---|---|---|
| `rtl/adc.v` | `wire prdata /* synthesis syn_keep = 1 */;` | **不在** |
| `rtl/adc_crtl_demo.v` | `wire pdata/*synthesis PAP_MARK_DEBUG="1"*/;` | **在**（`triggerChannel<0><1>=pdata[0]`）|

即 **`syn_keep` 只防优化，`PAP_MARK_DEBUG` 才是让 Inserter 把它列出来的那个**。
两个都写。

标记值有两种形式：

| 形式 | 写法 | 含义 |
|---|---|---|
| 模糊 | `PAP_MARK_DEBUG="true"` / `="1"` | 只标记，Inserter 自动往 **Trigger Port** 上依次挂 |
| **精确** | `PAP_MARK_DEBUG="<核号/端口/通道号>"` | **直接指定连到哪个端口的哪个 channel** |

端口字母：`t` = Trigger Port、`d` = Data Port、`c` = Clock Port、`r` = Reset Port。
同一信号连多处用逗号分隔（如 `"<0/d0/69>,<0/t0/0>"`）。

> [!] **每个标记只能作用于【1 位】—— 多比特 wire 上的标记会被综合丢掉。**
>
> 手册的例子里有 `wire [7:0] debug_this_bus /* synthesis PAP_MARK_DEBUG="<0/t1/12>" */;`，
> 看着像是"总线占连续 8 个 channel"。**在 PDS 2022.2-SP6.4 上实测这个不成立**：
>
> ```
> (* PAP_KEEP="TRUE", PAP_MARK_DEBUG="<0/d0/77>" *)    wire dbg_mem_we;   <- 1 位：属性保留
>     wire [14:0] dbg_pc;                                                <- 总线：属性整条丢失
> ```
>
> **所以 PC / opcode 必须逐位标记。** 这是本项目踩到的第 4 个 Inserter 坑
> （前三个：`pc` 搜不到、`pc_r` 名字不对、`mem_re`/`mem_we` 是端口选不到）。

**当前实现**（分支 `feat/ila-probe`，全部在 `core.v` 末尾一个块里，共 86 个标记）：

```verilog
// rtl/core/core.v 末尾（endmodule 之前）—— ILA 调试探针束
// 每个探针都是本块【新建的 wire】，是原信号的纯别名。
// 新建而不是直接标记原信号，是为了绕开"模块端口网线选不到"：
// mem_we / mem_re / pc 都是 module core 的输出端口，直接标记照样选不到。
//
// [!] 总线必须拆成一位一根：多比特 wire 上的 PAP_MARK_DEBUG 会被综合丢弃。
wire dbg_pc0      /* synthesis PAP_MARK_DEBUG="<0/d0/0>"  syn_keep=1 */ = pc[0];
wire dbg_pc1      /* synthesis PAP_MARK_DEBUG="<0/d0/1>"  syn_keep=1 */ = pc[1];
// ... dbg_pc0..dbg_pc14  -> <0/d0/0>  .. <0/d0/14>
wire dbg_ifidpc0  /* synthesis PAP_MARK_DEBUG="<0/d0/15>" syn_keep=1 */ = if_id_pc[0];
// ... dbg_ifidpc0..14 -> 15..29；dbg_idexpc0..14 -> 30..44；dbg_exmem_pc0..14 -> 45..59
wire dbg_op0      /* synthesis PAP_MARK_DEBUG="<0/d0/60>" syn_keep=1 */ = if_id_instr[0];
// ... dbg_op0..6 -> 60..66
wire dbg_stall    /* synthesis PAP_MARK_DEBUG="<0/d0/67>,<0/t1/0>" syn_keep=1 */ = stall;
wire dbg_ex_flush /* synthesis PAP_MARK_DEBUG="<0/d0/69>,<0/t0/0>" syn_keep=1 */ = ex_flush;
wire dbg_mem_we   /* synthesis PAP_MARK_DEBUG="<0/d0/77>" syn_keep=1 */ = mem_we;
// ... 19 个 1 位信号 -> 67..85，完整表见 core.v 里的块头注释或 §7.1
```

外加时钟端口标记在 `cpu_top_board.v`：

```verilog
wire clk_sys /* synthesis PAP_MARK_DEBUG="<0/c0/0>" syn_keep=1 */;
```

**这样做的三个好处**：

1. **不用手点连线** —— 工程里没有 `.fic` 时打开 Inserter 会自动全部连好，
   核对一眼存盘即可。所有"搜不到/选不动/弹 Select Page"的问题一次性消失。
2. **端口网线问题被绕开** —— 探针全是内部 wire，不依赖端口是否可选。
3. **清理变成删一块** —— 整块自包含，抓完直接删掉那一段（本节末尾有命令），
   不用在 700 行里找散落的注释。

**综合后已逐项核对通过**（2026-09-25，`synthesize/cpu_top_board_syn.vm`）：

| 项 | 结果 |
|---|---|
| 数据通道 | **86/86**，正好 `0..85`，无缺口无重复 |
| 触发端口 | `t0`/`t1`/`t2`/`t3` 各 1 位，分别对应 `ex_flush`/`stall`/`bht_hit`/`ex_mispred` |
| 时钟端口 | `<0/c0/0>` 在，落在 `clk_sys` 上 |
| 通道↔信号对应 | `d0/0→dbg_pc0`、`d0/14→dbg_pc14`、`d0/15→dbg_ifidpc0`、`d0/60→dbg_op0`、`d0/85→dbg_pred_seen` … 全部与设计一致 |

> [OK] **触发端口序号基准已实机确认（2026-09-25）**：确实是 **4 个各 1 位的端口**，
> 序号从 `t0` 起。Inserter 自动连线生成的 `.fic` 里
> `triggerPortCount=4`、`triggerPortWidth<0..3>=1`、
> `triggerChannel<0><0>=dbg_ex_flush` / `<1><0>=dbg_stall` / `<2><0>=dbg_bht_hit` /
> `<3><0>=dbg_mispred` —— 与 RTL 标记**逐条吻合**，不需要改。
>
> 顺带确认 `Match Type` 也按预期落成了 **`Basic W/Edges`**（`triggerMatchType<0..3>=1`），
> 运行时可以在 Trigger Setup 里把 Value 填成 **`R`（上升沿）**。

**回归已实测不变**（2026-09-25，逐位核对）：

| 回归项 | 结果 |
|---|---|
| CoreMark 计时区间 | **354,119 拍**（不变）|
| 测试台总周期 | **1,457,776**（不变）|
| 四个 CRC | `e9f5 / e714 / 1fd7 / 8e3a` **逐位一致** |
| riscv-tests | **49 PASS / 1 FAIL / 0 TIMEOUT** |
| `run_sim` 6 个单测台 | 全过 |
| `run_own_tests` | `exceptions` + `timer_irq` **2/2** |

**综合资源**（本次调试版综合，`synthesize/run.log`）：LUT **3,696** / 寄存器 **2,441** /
DRM 16 / APM 11。生产版（P&R 后）是 **LUT 3,721 / slack +1.550 ns / All Constraints Met**，
归档比特流 `bitstreams/coremark_iter1663_pll49mhz_localboard.sbit`（md5 `c4e2c4d2`）。
> [!] **`multiseed_summary.csv` 被这次综合运行清成了 NA** —— 它是 **P&R** 的产物，
> 只跑 `-run synthesize` 会把它重置。基线值（3,721 LUT / +1.550 ns）在
> `bitstreams/README.md` 与 CLAUDE.md 里都有记录，下次 P&R 会重新生成。
> 该文件本就在 `.gitignore` 里，不影响仓库。

> [!] **`ex_flush_d` 已从设计里删除**（2026-09-21 取指重定向改造），别再给它写属性 ——
> 综合会直接报 `Identifier ex_flush_d is not declared` 并中断整条流程。

**重要：这些属性和 DebugCore/JTAG Hub 两个 IP 都只能用于调试版本。**

- 它们会保留本可优化掉的逻辑，**LUT 用量会变化**，会破坏
  `doc/resource_efficiency.md` 中记录的**基线数据**（**当前 49.89 MHz 设计：3,721 LUT /
  可达 54.0745 MHz / slack +1.550 ns**；历史基线：45 MHz 时代 3,030 LUT / 51.52 MHz，
  27 MHz 时代 2,316 LUT / 47.81 MHz）
- `ips_debug_core`（含 256 位比较器 + `data_capture_mem`）与 `ips_jtag_hub` 自身也占 LUT 与 BRAM

**抓完波形、截图存档后必须移除，并重新综合一次，确认资源与时序回到原值。**

> **波形怎么保存**（Debugger 手册 §4.3 File 菜单 + §5.12）：
>
> | 目的 | 操作 | 产物 |
> |---|---|---|
> | 放进报告 | Waveform 窗口截图（`Win+Shift+S` / `Alt+PrintScreen`）| PNG |
> | 存档 / 逐拍核对 | **`File → Export sample data`** → VCD（或 TXT）| `.vcd` / `.txt` |
> | 下次打开还在 | `File → Save Project As` | `.dprj` + `.wdf` |
>
> * `Export sample data` 支持 **ASCII / WDF / FIC / VCD / TXT**。
>   **VCD** 是标准格式，GTKWave 能开；**TXT** 可以只导出指定界面
>   （Waveform / Listing / BusPlot）上的 **Bus 值**，导出来是一张干净的数值表。
> * `File → Save Project As` 生成的 `.dprj` + `.wdf` 能把波形和全部设置原样恢复，
>   **不用重新抓**。TCL 等价：`dbg_save_project -file <路径>.dprj`。
> * 工具栏 **`TriggerMode`** 选 `Continuous` 会多出 **`EnabledOutPutFile`**，
>   勾上后**每次触发自动落盘**（VCD / ASCII / WDF）—— 抓四种触发时省事。
>   注意 `Single`（默认）**不保存**。
>
> [!] **Debugger 会自动在工程目录写两个工作文件**：
> `pds/RV32I_1/data.wf`（波形数据）与 `pds/RV32I_1/cur_project`（当前工程指针）。
> 抓完就自动落盘了，下次 `File → Open Project` 能直接恢复。这两个是工具产物，
> 已加进 `.gitignore`，**别当成要提交的成果**。
>
> **建议流程**：先导 VCD 存档并逐拍核对，确认无误**再**截图进报告 ——
> 免得截完写进报告才发现某处对不上。

> [!] **波形里会同时出现总线和 86 根裸位 —— 这是设计使然，不是 bug。**
> 手册 §5.2.1：组合成总线后"**一条新的总线被加入到 DataPort 的最上面**"，
> **原来的信号并不会被移除**，信号与总线在 SignalTree 里**并存**。
> 所以 `Add All to View` / `dbg_add_all_to_waveform` 会把两者都塞进波形。
>
> **正解：清空后只加要看的**（TCL 没有"只加某一根"的命令，这一步得在 GUI 点）：
> 1. 右键 SignalTree 的 **`DataPorts`** 节点 → **`Clear All`** → 选 `Waveform`
> 2. 在 SignalTree 里 **ctrl 点选**（或 shift 连续选）真正要看的信号
> 3. 任选中项右键 → **`Add to View`** → `Waveform`
>
> **建议只加这些**（13 根 + 5 条总线，其余 70 多根裸位不加）：
>
> | 用途 | 信号（通道）|
> |---|---|
> | 四条 PC + opcode | `PC` `IFID_PC` `IDEX_PC` `EXMEM_PC` `OPCODE`（总线）|
> | 冲刷（图 1）| `dbg_ex_flush`(69) `dbg_id_ex_br`(75) `dbg_btaken`(76) |
> | 停顿（图 3）| `dbg_stall`(67) `dbg_idex_ld`(70) |
> | BHT 证据（图 2/4）| `dbg_bht_hit`(80) `dbg_bht_taken`(81) `dbg_redirect`(83) `dbg_mispred`(84) |
>
> 加信号**不用重新抓**（`data.wf` 里数据都在），随时补看随时加。
>
> **总线的位序规则**（手册 §5.2.1 c，也把 TCL 的行为钉死了）：
> * GUI：**shift 选**→ 最上面的信号是**最低位**；**ctrl 选**→ **第一根被选的**是最低位
> * TCL `dbg_add_bus -channel 0-14`：`dbg_pc0` 在前 → 也是**第一根 = 最低位**
>   （实测证据：PC = `0x0018` 而不是 `0x1800`，位序正确）
> * 反了就**在总线节点上右键 `Reverse Bus Order`** —— 会同步更新所有窗口并重算数值

> [!] **抓 CoreMark 的波形必须先按复位键，否则永远等不到触发。**
> CoreMark 是**一次性程序**：板上电后跑 11.8 秒就结束，之后 CPU 进空闲循环。
> 而空闲循环里的跳转（`jal` 或向后分支）**全都是被预测中的** ——
> `core.v` 里 `ex_flush = ex_resolve_taken && !id_ex_pred_taken`，
> 预测中就不冲刷，于是 **`ex_flush` 恒为 0**，`TU0 == 1` 永远不成立。
>
> **表现**：`dbg_run` 之后波形一直显示 `waiting for trigger`。
> **这不是故障** —— 恰恰是"静态预测 + BHT 在空闲循环里 100% 命中"的侧面证据。
>
> **做法**：`dbg_run` 挂上触发 → **按板上丝印 `KEY1`（手册 KEY0 / 管脚 C22，本板复位键）**
> → CoreMark 重跑，11.8 秒里触发必然满足。
> 抓另外三种（stall / bht_hit / ex_mispred）同理：改完 `-unit` 就按一次 KEY1。
>
> **板级判据**：`led[1]` = `done` = **丝印 D18**，亮 = CoreMark 已跑完；
> `led[0]` = `pll_locked` = **丝印 D19**，亮 = PLL 已锁定。

> [OK] **2026-09-25 19:32 —— 第二份硬件波形：CoreMark 分支冲刷。**
> 证据 `doc/board/ila_hw_exflush_coremark.vcd`（1024 拍）。
> **触发点精确落在采样 512**（= 设定的 `Position=512`），PC 范围 `0x0018~0x2970`、
> 171 个不同取值 —— 确实是 CoreMark 在跑。**三种 BHT 行为全在这一个窗口里。**
>
> **窗口内统计**（可写进报告）：
>
> | 项 | 次数 |
> |---|---|
> | 条件分支进 EX（`dbg_id_ex_br`）| 151 |
> | ID 级重定向（`dbg_redirect`，含 `jal`）| 129 |
> | BHT 命中（`dbg_bht_hit`）| 138 |
> | **BHT 预测 taken 的事件** | **12** |
> | 　　其中预测对（实际 taken）| **11**（92%）|
> | 　　其中误判（实际 not-taken）| **1** |
> | `dbg_ex_flush`（冲刷）| 14 |
> | `dbg_stall`（load-use）| 17 |
> | `dbg_div_stall`（多拍除法）| 33 |
> | `dbg_mem_we` / `dbg_mem_re` | 180 / 26 |
>
> **【图 1】BHT 未命中 -> 静态兜底 -> 冲刷**（触发点，采样 512）
>
> 循环体 `0x14 bne / 0x18 sw / 0x1c addi / 0x20 jal`，5 拍一轮。
>
> | idx | PC | IFID | IDEX | OP | exfl | idbr | btkn | bhth | bhtt | pred |
> |---|---|---|---|---|---|---|---|---|---|---|
> | 511 | 001c | 0014 | 0000 | 63 | 0 | 0 | 1 | 1 | 0 | 0 |
> | **512** | 0020 | 0018 | **0014** | 23 | **1** | **1** | **1** | **0** | 0 | **0** |
> | 513 | 0028 | 0000 | 0000 | 13 | 0 | 0 | 1 | 0 | 0 | 0 |
> | 514 | 002c | **0024** | 0000 | 6f | 0 | 0 | 1 | 0 | 0 | 0 |
>
> `0x14` 处的前向分支在 EX 解析为 **taken**，但 `bht_hit=0`（未命中）-> 退回静态规则
> -> 前向分支预测 **not-taken** -> **冲刷**。513 拍 IF/ID 与 ID/EX 双双变气泡，
> 514 拍目标指令 `0x24` 进 ID。**惩罚 1 拍**（正常应在 513 进 ID）——
> 这就是文档里"分支惩罚 1 拍"的**板上直接证据**。
>
> **【图 2】BHT 命中且预测对 —— 省 1 拍**（采样 723）
>
> | idx | PC | IFID | IDEX | OP | exfl | idbr | btkn | bhth | bhtt | rdrc | pred |
> |---|---|---|---|---|---|---|---|---|---|---|---|
> | 722 | 0124 | 011c | 0118 | 13 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
> | **723** | 0128 | **0120** | 011c | **63** | 0 | 0 | 0 | **1** | **1** | **1** | **1** |
> | 724 | 027c | 0000 | **0120** | 13 | **0** | **1** | **1** | 0 | 0 | 0 | 0 |
> | 725 | 0280 | **0278** | 0000 | 33 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
>
> 723 拍分支在 **ID**，BHT 命中且预测 taken -> `id_redirect=1`，取指当拍改到 `0x278`。
> 724 拍该分支在 **EX**，`btaken=1`（实际也 taken），但 **`ex_flush` 仍为 0** ——
> 因为它是被预测的（`id_ex_pred_taken=1`）。725 拍目标指令 `0x278` 就进了 ID。
> **没有 BHT 的话要等到 726 拍才进 ID -> 省 1 拍。**
>
> **【图 3】BHT 误判恢复**（采样 751，全程 1024 拍里唯一一次 `dbg_mispred=1`）
>
> | idx | PC | IFID | IDEX | OP | exfl | idbr | btkn | bhth | bhtt | rdrc | mspd |
> |---|---|---|---|---|---|---|---|---|---|---|---|
> | 750 | 0130 | **0128** | 0124 | **63** | 0 | 0 | 0 | **1** | **1** | **1** | 0 |
> | **751** | 0118 | 0000 | **0128** | 13 | 0 | **1** | **0** | 0 | 0 | 0 | **1** |
> | 752 | 0130 | 0000 | 0000 | 13 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
>
> 750 拍 BHT 预测 taken（`bhtt=1`）-> ID 重定向到预测目标（`pc_r` 变 `0x118`）。
> 751 拍该分支在 EX 却 `btaken=0`（实际 not-taken）-> **`dbg_mispred=1`** ->
> 拉回 fall-through；752 拍 `PC=0x130` 正是 fall-through `0x12c + 4` ✓。
>
> **这三张图的价值**：把 `rtl/core/core.v` 里那三段分支逻辑
> （静态兜底冲刷 / BHT 命中省拍 / 误判恢复）**逐拍对上了硬件实测**，
> 而不再是仿真推算。**高阶任务②"动态分支预测"的评分证据就是它。**

> [OK] **2026-09-25 19:26 —— 第一份硬件波形解析完毕（停机自旋）。**
> 证据文件 `doc/board/ila_hw_halt_loop.vcd`（1024 拍，每拍 1 个 clk_sys 周期）。
>
> **这份抓的是固件的停机自旋**，反汇编 `sim/programs/coremark.elf` 证实：
>
> ```
> 30: li   a0,1
> 34: sw   a0,0(t0)     <- 写 done 标志（对应 led[1]=D18 常亮）
> 38: j    38           <- jal x0,0 = while(1) 自旋
> 3c: addi sp,sp,-128   <- main 开头（CoreMark 已跑完，不在执行）
> ```
>
> 所以 PC 只在 `0x003c`/`0x0040` 之间跳 —— `0x38+4`（重定向后 `pc_r = 目标+4`）
> 和顺着下去的 `main` 头两条（误取路径）。
>
> **[重点] 触发没满足，不是故障。** 三条硬证据（全程 1024 拍）：
>
> | 信号 | 值 | 含义 |
> |---|---|---|
> | `dbg_id_ex_br` | 恒 0 | **这条循环里没有任何条件分支** |
> | `dbg_ex_flush` | 恒 0 | 无条件分支可冲刷 -> `TU0 == 1` 永不成立 |
> | `dbg_bht_hit` | 恒 0 | BHT 只服务条件分支 |
>
> 即这份数据来自 `dbg_trig_immd`（立即触发**忽略**触发条件），不是 `dbg_run`。
>
> **[OK] 但它本身是一组有价值的"设计取舍被硬件验证"的证据：**
>
> 1. **`jal` 在 ID 级被预测并重定向，不需要 EX 级冲刷** —— `dbg_pred=1` 与
>    `dbg_redirect=1` 同拍，而 `dbg_ex_flush=0`。
> 2. **BHT 不参与 `jal`** —— `dbg_bht_hit` 恒 0 而 `dbg_redirect` 在动，
>    证明 BHT 只管条件分支，与设计取舍一致。
> 3. **气泡编码被实锤** —— `IFID_PC=0x0000` 配 `OPCODE=0x13` 占一半时间。
>    核 `core.v` 的 IF/ID 段：冲刷时 `if_id_pc <= 0`、`if_id_instr <= 32'h00000013`
>    （NOP），所以这是**气泡**不是真指令，不是 bug。
>    `j 38` 每次迭代插一个气泡 -> **2 拍/迭代**，正好印证"分支惩罚 1 拍"。
> 4. **流水线级间关系正确** —— `IFID -> IDEX -> EXMEM` 严格每拍推进一级
>    （逐拍核对过），四级 PC 的集合相同、只是逐级旋转一位。
>
> [OK] **2026-09-25 18:50 —— 硬件在环抓取首次跑通。** 全链路验证记录：
>
> | 步 | 证据 |
> |---|---|
> | 认核 | `dbg_list` → `Data sample width = 86` / `Sample buffer depth = 1024` / `Number of trigger ports = 4` / `TU0..TU3 Width=1 Type=Basic W/Edges` —— 与 Inserter 里配的逐项一致 |
> | 导探针 | `dbg_import_fic -file .../cpu_top_board.fic` → `Import Core: 0 OK` |
> | 触发 | `dbg_trig_immd` → `Core 0 trigger successful at Fri Sep 25 18:50:36 2026` |
>
> **唯一卡住过一次的地方是"没连 JTAG Server"** —— 那时器件栏只有
> `device - jtag chain` 这个空树标题，看着像已经扫到了，其实什么都没连。
> 详见 §7.6 第 9 步。
比赛提交的工程里绝不能留着调试核。

> 这些属性是**注释形式**（`/* synthesis ... */`），iverilog 会直接忽略，
> 所以不影响仿真，也不会破坏 `1,457,776` 的回归探针。但为保险，
> 改完仍应跑一次回归确认。

**抓完之后怎么安全地删干净 —— 推荐用 git 精确还原，不要用正则删注释。**

> [!] **首选：`git checkout <探针之前的 commit> -- rtl/`**
>
> 探针只由 `feat/ila-probe` 上的两个 commit 引入（`4bd5353`、`b3697d6`），
> 它们之前的 **`b8edd43`** 就是干净版。所以：
>
> ```bash
> # 探针之前那次提交（49.89 MHz 板上实测通过的那版 RTL）
> git checkout b8edd43 -- rtl/core/core.v rtl/top/cpu_top_board.v
> # 复查：应为 0，且与 b8edd43 逐字节一致
> grep -c "PAP_MARK_DEBUG\|dbg_pc" rtl/core/core.v rtl/top/cpu_top_board.v
> git diff --stat b8edd43 -- rtl/          # 空 = 一致
> ```
>
> **2026-09-25 实机验证**：还原后 CoreMark **354,119 拍 / 总时长 1,457,776**、
> 四个 CRC 逐位一致 —— 与加探针前完全相同。
>
> 好处：**精确、可复现、不碰编码**。RTL 里那两处被探针改写的声明
> （`id_ex_mem_read` 从合并声明里拆出、`clk_sys` 加属性）也一并还原。

**备选：正则删注释**（`core.v` 是 UTF-8 带中文注释，别用 sed / 别用文本编辑器批量替换，
容易把编码搞坏）。用 Python 按字节替换：

```powershell
# 先看有哪些（应为 14 条，与 §7.2 的属性清单一致）
Select-String -Path rtl\core\core.v -Pattern "synthesis"

# 一次性删除全部探针属性 —— 正则必须同时覆盖 PAP_MARK_DEBUG 和 syn_keep
python -c "import io,re; p=r'rtl/core/core.v'; s=io.open(p,encoding='utf-8').read(); pat=r' */\* *synthesis +[^*]*\*/'; n=len(re.findall(pat,s)); s=re.sub(pat,'',s); io.open(p,'w',encoding='utf-8',newline='').write(s); print('removed',n)"

# 复查：应为 0 条，且回归必须回到基线
(Select-String -Path rtl\core\core.v -Pattern "synthesis" | Measure-Object).Count
scripts\run_riscv_tests.ps1             # 期望 49/1/0
scripts\run_coremark.ps1 -Iter 1        # 期望计时区间 354,119 拍（测试台总周期 1,457,776）
```

> [!] **旧版这条删除命令只匹配 `syn_keep|syn_preserve`，删不掉 `PAP_MARK_DEBUG`** ——
> 照它跑完会留下 14 条 `PAP_MARK_DEBUG`，重新综合后资源/时序对不上基线，
> 而且比赛提交的工程里就留着调试标记了。2026-09-25 已改成匹配整条
> `/* synthesis ... */`（`[^*]*` 避免跨注释贪婪匹配）。

**[!] 还有一步不能漏：撤掉 `.pds` 里的 `.fic` 登记。**

只还原 RTL 是不够的 —— `.pds` 的 `wgt_my_fic_src` 还指向那份 `.fic`，
而 `.fic` 里的通道名（`dbg_pc0` 等）在没了探针的网表里**不存在**，
综合会直接报错。把那一节清空回：

```
(_widget wgt_my_fic_src
)
```

（Pango 自带例程 `example/PG2L100H_lvds4to1/pnr/lvds4to1.pds` 就是这个形态。）

删完重新综合，再用 `pds/RV32I_1/multiseed_summary.csv` 核对 LUT 是否回到**基线**：
当前 49.89 MHz 设计应为 **3,721**（45 MHz 时代的 3,030、27 MHz 时代的 2,316 都不是当前基线，别拿它们对照）。

### 7.3 操作步骤

**主路径（用平台 ILA）**

1. 按 §7.2 在 `rtl/core/core.v` 给要抓的信号加防优化属性。
2. 在 PDS 里 **Compile → Synthesize**，产出网表 `.adf`
   （本工程在 `pds/RV32I_1/synthesize/cpu_top_syn.adf`）。
3. PDS 菜单 **TOOL → Inserter** 打开 **Fabric Inserter**，在 **JtagHub** 目录下选 **DebugCore**。
   各设置项**具体在哪个界面见 §7.1.1**（[!] 采样时钟在 `Net Connections` 里，不在
   `Trigger Parameters`；触发条件/触发位置在运行时的 Fabric Debugger 里，这里配不了）：
   - **Trigger Parameters**：`Match Type = Basic w/edges`、`Sample Depth = 1024`、
     `Sample On = Rising`；`Enable Multi-windows and NSample` **保持不使能**；
     `PowerOn Init Parameters` 默认
   - **Net Connections → Modify Connection → Select Net**：
     `Clock Port` 连顶层 `cpu_top_board` 的 **`clk_sys`**；
     `Data Port` 按 §7.1 的 **86 位**清单连（信号都在 `u_core` 里，PC 只连低 15 位）；
     `Trigger Port` 连 1 根 `ex_flush`
4. **保存 Inserter 工程 → 这就是那个 `.fic` 文件**
   （PDS 例程里的命名是 `<顶层名>_syn.fic` / `<设计名>_debug.fic`，惯例放在布线输出目录）。
[!] **务必把 `.fic` 和随后生成的 `.sbit` 放在一起成对保存**。
5. 继续 **Place & Route → Generate Bitstream**，得到含 debug 核的 `.sbit`。
   - 别忘了 `mem.hex` 必须在工程目录，否则 BRAM 为空（见 `pds/README.md` 的坑）
6. 到平台「固件烧录」烧写这个 `.sbit`，确认设备唤醒成功。
7. 进平台的 **ILA** 模块 → 点 **「导入fic文件」** → 选第 4 步保存的 `.fic`。
8. 设触发条件 → **启动** → 抓波形 → 用 **导出** 按钮把波形存下来。
9. 截图至少覆盖三种情形：(a) 一次完整的分支冲刷，(b) 一次 load-use 停顿，
   (c) 一次前递生效。存到 `doc/reports/`。

> [!] **仓库里现在躺着两份【过期】的 .fic，别误用**：
> * `pds/RV32I_1/synthesize/cpu_top_syn.fic` —— 2026-09-21 生成，指向旧的
>   `cpu_top_syn.adf`（**那时顶层还是 `cpu_top`，也还没有 PLL**）
> * `pds/RV32I_1/bak_2026-09-21_ila/cpu_top_syn.fic` —— 同一份的归档
>
> 判据：打开 .fic 看 `Project.device.designInputFile` 指向的 `.adf` 是不是**本次**
> 综合产出的 `synthesize/cpu_top_board_syn.adf`（注意是 `cpu_top_board`，不是 `cpu_top`）。
> 名字对不上就是过期的，重做 B 段。

> **最大的坑**：`.fic` 与 `.sbit` **必须来自同一次综合布线**。
> 改了 RTL 重新生成比特流后，旧的 `.fic` 就作废了 —— 通道映射会整体错位，
> 波形看起来"有信号但全不对"，极难排查。每次重新生成比特流都要同批更新 `.fic`。

**备选路径（平台不给 ILA 时）**

走 §7.3 的 1–5 步之后，不开平台，改在本机：
6′. 直接用 PDS **Debugger** 连板子（**Scan JTAG**），能扫到器件与 `debug_core` 才可行。
7′. 点触发捕获，在波形窗口把总线信号 **Bus radix** 设为 Hex（PC）。
8′. 若 Scan JTAG 扫不到，说明没有 JTAG 通路，只能换成本地盘古 MES2L200HP 板
   （需先按 `RV32I_1.fdc` 中注释的引脚解锁 `led`/`key`/`uart_rx` 并改时钟约束）。

### 7.4 触发条件建议（与 §3/§4 的波形对应）

| 目的 | 触发条件 | 期望看到 |
|---|---|---|
| 分支惩罚 | `ex_flush == 1` | `ex_flush` 拉高 1 拍，`IF/ID` 清空；**同拍**取指地址已变成跳转目标。`EX` 级随后**连续 2 拍为空**（冲刷拍 + 1 拍取指延迟） |
| load-use | `stall == 1` | `stall` 拉高拍 `pc_r` 保持不动，下一拍 `ID/EX` 为气泡；同拍 `id_ex_mem_read` 应为 1 |
| 前递生效 | `fwd_a_ex == 1` | EX 级运算数取自 EX/MEM 而非寄存器堆 |
| **BHT 命中且预测跳转** | `bht_hit == 1 && bht_taken == 1` | ID 级提前重定向，`id_redirect` 同拍拉高；EX 级解析后**不冲刷** —— 这就是"预测对了省 1 拍"的直接证据 |
| **BHT 误判恢复** | `ex_mispred == 1` | 预测 taken 但实际 not-taken，EX 级把流水线拉回 fall-through（`ex_mispred_target = id_ex_pc + 4`）|
| **BHT 未命中** | `bht_hit == 0` 且 `id_ex_branch == 1` | 退回静态规则（后向才预测），可对照 `[82] id_pred_taken` 看兜底是否生效 |

触发位置建议设在缓冲区中点：这样触发条件满足**之前**的流水线状态也能看到，
才有"前因后果"而不只是"结果"。

### 7.5 待确认事项（执行前必须落实）

1. **你预约到的那台设备有没有启用 ILA。**
   平台文案「当前设备配置未启用该仪器」说明仪器是按设备逐个启用的。
   在「设备管理」里看设备详情，或直接问赛方技术支持（QQ 群见赛题指南第五节）。
2. **平台接受不接受 `.fic` 而不只是 `.ltx`。**
   从代码看：按钮文案在 Pango 板子上是「导入fic文件」、在 Xilinx 板子上是「导入LTX文件」，
   文件过滤器按板卡型号切换。所以**先确认你预约的设备是不是紫光同创的板子**——
   如果是 Xilinx 板，本项目的 Pango `.fic` 用不上。
3. 该设备的 `ilaChannelCount` / `ilaSampleDepth` 是多少（平台按设备下发这两个参数）。
   若通道数少于 §7.1 的 86 位计划，需要再裁剪探针。
4. 截图分辨率与报告排版要求（建议原图，不要压缩到看不清信号名）。
5. 抓完后**移除调试属性与调试核，重跑一次综合与回归**，确认
   `49/1/0`、计时区间 `354,119` 拍、**LUT / Fmax 都回到基线**（当前 49.89 MHz 设计：
   **3,721 LUT / 可达 54.0745 MHz / slack +1.550 ns**；更早的值都是历史）。

### 7.6 本地板执行清单（2026-09-25，当前状态的推荐路径）

> 前提：**RTL 已冻结**（49.89 MHz + BHT 都已验证通过、板上实测做过）。
> **加 ILA 探针属性和 DebugCore 本身都要改 RTL/网表，所以这一步必须排在最后** ——
> 否则队友一改 RTL，`.fic` 与 `.sbit` 双双作废。
>
> 分支：**`feat/ila-probe`**。探针束已加好并**实测 86/86 存活 + 通道号逐个核对**（见 §7.2）；
> `.fic` 也已生成并核对通过（`pds/RV32I_1/cpu_top_board_ila.fic`，md5 `178d8aad`）——
> 剩下的就是**把它登记进 PDS 工程**（第 6b 步，这一步最容易漏）然后跑 P&R。

**A. 准备（本地 PDS）**

1. 按 §7.2 在 `rtl/core/core.v` 末尾放好探针束
   （`/* synthesis PAP_MARK_DEBUG="<0/d0/N>" syn_keep=1 */`，**不是只写 `syn_keep`**；
   总线要一位一根，**多比特 wire 上的标记会被综合丢掉**）。
   > [OK] 这一步**已完成**（`feat/ila-probe`，**86/86 标记实测存活**、通道号已逐个核对）。
   > 除非要增删探针，否则直接从第 3 步开始。
2. `scripts\build_bitstream.ps1 coremark -NoBuild` —— 只生成并同步固件，
   确认 PDS 工程里的 `mem.hex` 是 **ITER=1663**（别用旧镜像）。
3. PDS 打开 `pds/RV32I_1/RV32I_1.pds` → **Compile → Synthesize**。
   产物：`pds/RV32I_1/synthesize/cpu_top_board_syn.adf`。
   > 本工程**已停在"综合完成"状态**（2026-09-25 17:36），可直接进第 4 步。

**B. 用 Fabric Inserter 生成 `.fic`（界面细节见 §7.1.1 / §7.1.2）**

4. PDS 菜单 **TOOL → Inserter**，在 **JtagHub** 目录下选 **DebugCore**。
5. 配三栏 —— **[!] 注意哪些在这里配、哪些要留到运行时**：
   * **Trigger Parameters**：`Match Type` 选 **`Basic w/edges`**（不然运行时没法用
     上升沿触发）；`Sample Depth = 1024`（≈20.5 µs，要看长窗口用 4096 ≈82 µs）；
     `Sample On = Rising`；`Enable Multi-windows and NSample` **不勾**；
     触发端口数/匹配单元数各 1
     > **采样时钟、触发条件、触发位置都不在这一栏** —— 前者的位置见下一条，
     > 后两者在 Fabric Debugger 里运行时配（§7.1.1），**不用重新综合**
   * **Net Connections → Modify Connection → Select Net**：
     * `Clock Port` 页签 ← 顶层 `cpu_top_board` 的 **`clk_sys`**
       （不是 27 MHz 晶振，也不是 `clk` 端口；找不到就勾 `Show All Nets In The Net Tree View`）
     * `Data Port` 页签 ← 按 §7.1 的 **86 位**清单连，**信号都在 `u_core` 里**
       （PC 只连低 15 位；`pc` 不叫 `pc_r`）
     * `Trigger Port` 页签 ← 1 根 **`ex_flush`**（触发信号先接它，运行时随时能换）
   * **PowerOn Init Parameters**：默认
6. **保存 Inserter 工程 —— 这个文件就是 `.fic`。**
   命名建议 `cpu_top_board_ila.fic`，**和随后的 `.sbit` 放一起成对保存**。
   > [!] **`synthesize/` 目录会被下次综合整个清掉**（PDS 只管把它挪进 `synthesize/bak/`）。
   > 保存完**立刻复制一份到 `pds/RV32I_1/` 下**，别留在 `synthesize/` 里。

6b. **[!] 必须把 `.fic` 加进 PDS 工程，否则 DebugCore 根本不会被插进去。**

   已保存 ≠ 已生效。`.fic` 是 **synthesis 任务的输入**（`.pds` 里的
   `wgt_my_fic_src` 部件），**没登记进去的话，综合/布线照跑、比特流照出，
   但里面一个调试核都没有** —— 症状是 Debugger「Scan JTAG」扫不到 `debug_core`，
   极难往"少登记了一个文件"上想。

   检查：打开 `.pds` 看 `wgt_my_fic_src`，对照 Pango 自带例程
   （`example/PG2L100H_adc_test/pnr/adc_module.pds`）的正确形态应该是：

   ```
   (_widget wgt_my_fic_src
       (_input
           (_file "cpu_top_board_ila.fic"
               (_format text)
               (_timespec "2026-09-25T18:22:55")
           )
       )
   )
   ```

   登记方法（二选一）：
   * **PDS 的 TCL 控制台**里敲（最省事，一条命令）：
     `add_fic d:/riscv-cpu-fpga/pds/RV32I_1/cpu_top_board_ila.fic`
     （见《PDS User Guide》§9.3 `add_fic` 指定约束文件；
     也可用 `add_sources -fic <文件>`）
   * 或在 PDS 里**添加资源文件**，把 `.fic` 作为 **FIC / 约束文件**加进去。

6c. **验证调试核真的进去了**（跑完 P&R 再看）：

   > [OK] **2026-09-25 已跑通并验证**：

   | 项 | 生产版（提交用）| 调试版 | 变化 |
   |---|---|---|---|
   | **DRM** | 16 | **19** | **+3** = 1024×86bit ≈ 3 块 DRM36K |
   | LUT | 3,721 | 4,200 | +479（调试核 + 86 根探针）|
   | FF | — | 3,394 | |
   | APM | 11 | 11 | 不变 |
   | slack（慢角）| +1.550 ns | **+1.329 ns** | 少 0.22 ns，仍 `All Constraints Met` |
   | 比特流 md5 | `c4e2c4d2` | **`96ee7877`** | |

   最硬的证据是 P&R 日志直接点名了调试核实例
   （`place_route/run.log`）：

   ```
   C: Route-2036: The clock path from clkbufg_4/gopclkbufg:CLKOUT to
      u_CORES/u_debug_core_0/u_Data_Capture_Memory/block_ram.ram_data_1_1/gopdrm_36k:CLKB[0] ...
   ```

   **DRM 一点没变 = 调试核没插进去**，回第 6b 步。

   **DRM 在哪看**（三个地方）：
   * 最快：`pds/RV32I_1/multiseed_summary.csv` 的 `Used` 行，列头就是 `LUT,FF,DRM,APM`
   * 详细：`pds/RV32I_1/place_route/run.log` 的 `Logic Utilization` 表
   * GUI：PDS 左侧 **Place & Route → Architecture Browser**

   调试核的采集 RAM 是实打实占 BRAM 的 —— 1024 采样 × 86 位 = 88,064 bit，
   约 3 块 DRM36K。所以 **DRM 用量应该从 16 涨到 ~19-20**。
   **DRM 一点没变 = 调试核没插进去**，回第 6b 步。
   （基线：生产版 LUT 3,721 / DRM 16 / slack +1.550 ns / All Constraints Met）

**C. 出比特流并烧写**

7. 继续 **Place & Route → Generate Bitstream**，得到含 DebugCore 的 `.sbit`。
   > [!] 这份是**调试版**，不是比赛提交用的那份。别覆盖 `generate_bitstream/` 里
   > 已经归档好的生产比特流 —— 建议先把它改名或归档到 `bitstreams/`。
8. PDS **TOOL → Programmer** 烧这份调试版。

**D. 抓波形（本地 PDS Debugger）**

9. PDS **TOOL → Debugger**。

   **[!] 第一件事是先连 JTAG Server，否则什么命令都跑不了。**
   （2026-09-25 实踩：不连就敲 `dbg_list`，报
   `Debugger-0015: ... the connection is disconnected, please connect to server first`；
   而器件栏那行 `device - jtag chain` 只是**空树的标题**，不是扫描结果 ——
   很容易误以为已经扫到了。）

   手册 §3.1：点工具栏 **`Connect to server`** 按钮 → 弹连接 Cable 的向导，三步：

   ```
   (1) IP + 端口：本地板填 127.0.0.1 + 65420，直接点连接
   (2) 选 Cable：列出当前可用电缆，选接板子那个；TCK 用默认
   (3) 总结页 → 点 Next 把配置下发给服务端
   ```

   > `65420` 是 Debugger 默认的 server 端口（`bin/cdt_dbg.exe` 里的默认值，
   > 与手册示例 `dbg_connect -ip 192.29.103.191 -port 65420` 一致）。
   > **本机 IP 时服务端由 PDS 负责**；万一连不上，手动起：
   > 到 `D:\pango\PDS_2022.2-SP6.4in\` 下开命令行跑 **`cdt_js.exe -port 65420`**。
   >
   > TCL 等价命令：`dbg_connect -ip 127.0.0.1 -port 65420`
   > （手册：`-ip`/`-port` 任一为空则用界面设置连）。

9b. **连上之后**再扫链、下位流。`dbg_list` 这时才有意义（见第 9 步下面的四步表）。

9c. **下载调试位流**（对应 GUI 的 `Configure Bitstream File`）：

   ```tcl
   dbg_scan_chain
   dbg_program -file D:/riscv-cpu-fpga/pds/RV32I_1/generate_bitstream/cpu_top_board.sbit -device 0
   ```

   > [!] `dbg_program -help` 明确警告：路径**可以用 `\` 或 `/` 分隔，
   > `\` 不能单独用** —— **一律用正斜杠 `/`**，否则路径解析会出问题。

9. PDS **TOOL → Debugger**。**注意 Debugger 不是"扫一下就有波形"** ——
   器件栏里那个 FPGA **只有在里面真的载入了 DebugCore 时才会展开出叶节点**。
   正确顺序是四步：

   ```
   (1) 工具栏 Search JTAG Chain            列出链上器件（这一步只列出器件）
   (2) 工具栏 Configure Bitstream File     选 .sbit 并【下载到 FPGA】
   (3) 导入 .fic                          手动：File → Import sample data
                                          自动：见下面的命名约定
   (4) 器件下出现 DebugCore 叶节点
         → 双击 "Trigger Setup" 配触发 → Run
   ```

   > [!] **只看到 `device - jtag chain`、展不开 = FPGA 里没有 DebugCore。**
   > 最常见的原因就是第 (2) 步烧的还是生产版比特流（`generate_bitstream/`
   > 里那个文件名不变，很容易烧成上一版）。**从 Debugger 里用
   > `Configure Bitstream File` 下载一次**最稳 —— 它既保证设计对，又会顺带
   > 触发 .fic 的自动导入。

   > [!] **GUI 的 `File → Import sample data` 会报 `please select a unit`** ——
   > 那个对话框要求先选中一个 **unit（= DebugCore 核）**，而**列表是空的**
   > 就选不了。列表空本身就说明 **Debugger 没看到核**，还是第 (2) 步的问题。
   >
   > **绕开办法：用 Debugger 自带的 TCLConsole**（就是底部信息打印区那个窗格，
   > `View → Console` 可显示/隐藏；输入的命令会记到 `log/TclCmd.tcl`）。
   > 里面的 `dbg_import_fic` **不需要选 unit**：
   >
   > ```tcl
   > dbg_list                                                    # 先看有没有核
   > dbg_scan_chain                                              # 扫 JTAG 链
   > dbg_program -help                                           # 看下载位流怎么传参
   > dbg_import_fic -file D:/riscv-cpu-fpga/pds/RV32I_1/cpu_top_board.fic
   > dbg_run                                                     # 配好触发后抓
   > ```
   >
   > **`dbg_list` 是这里最好用的诊断**：不带选项就会列出所有核及其 data_port /
   > trig_port / trig_unit。**什么都不列 = FPGA 里没有 DebugCore**，回去做第 (2) 步。
   >
   > 一整套命令都有：`dbg_scan_chain` / `dbg_program` / `dbg_run` / `dbg_stop` /
   > `dbg_trig_immd` / `dbg_set_unit` / `dbg_set_condition` / `dbg_set_capture` /
   > `dbg_get_cur_core` / `dbg_set_cur_core` / `dbg_add_all_to_waveform` /
   > `dbg_add_bus` / `dbg_add_to_bus` / `dbg_set_bus_radix` / `dbg_export_fic`。
   > **每条都支持 `-help`**（如 `dbg_program -help`），不确定就查。
   >
   > 另外 `dbg_add_bus` / `dbg_add_to_bus` / `dbg_set_bus_radix` 说明
   > **PC 那 15 根按位合成的总线也能用脚本建**，不用手点。

   > [!] **`.fic` 的自动导入有命名约定**（Debugger 手册 §3.5）：
   > 它会搜索**位流文件所在目录 + 上一层目录**，找与**位流文件同名**的 `.fic`
   > 或 `<位流名>_trs.fic`。位流叫 `cpu_top_board.sbit`，所以它找的是
   > **`cpu_top_board.fic`**（或 `cpu_top_board_trs.fic`）。
   >
   > 我们原来叫 `cpu_top_board_ila.fic` —— **名字对不上，自动导入找不到**。
   > 所以 `pds/RV32I_1/` 下同时放了两份同内容的：
   > * `cpu_top_board.fic` —— **给 Debugger 自动导入用**（与位流同名）
   > * `cpu_top_board_ila.fic` —— **`.pds` 的 `wgt_my_fic_src` 登记的那份**
   >
   > 两份内容必须一致（目前 md5 都是 `178d8aad`）。手工导入也用
   > `File → Import sample data` 选任意一份即可。
10. 双击器件栏里的 **`Trigger Setup`** 叶节点，配三块（**实时下发，不用重新综合**）：
    * **Match Function**：给 `ex_flush` 那一行的 Value 填 **`R`**（上升沿）
    * **Trigger Condition**：`Enable` 该 Trigger Unit
    * **Capture Settings**：`Type = Windows`、窗口数 `1`、
      **`Position = Depth/2`**（看到触发前后各一半）
    然后 **`Trigger Setup → Run`**。
11. 波形窗口把总线信号（`pc` / `id_ex_pc` 等）的 **Bus radix 设为 Hex**。
12. 至少抓这四种情形（对应 §3/§4 的分析 + BHT 的证据）——
    **每次只需回 Trigger Setup 改 Value，不用重烧板**：
    * (a) 一次**分支冲刷** —— `ex_flush` 上升沿
    * (b) 一次 **BHT 命中且预测跳转** —— 触发改成 `bht_hit` 上升沿，看同拍 `bht_taken`、
      `id_redirect` 是否也为 1，且 EX 级**不冲刷**（这就是"预测对了省 1 拍"的直接证据）
    * (c) 一次 **load-use 停顿** —— 触发改成 `stall` 上升沿
    * (d) 一次 **BHT 误判恢复** —— 触发改成 `ex_mispred` 上升沿
13. 导出波形 / 截图，存到 `doc/figures/`，并在 `doc/ila_analysis.md` 里补索引。

**E. 收尾（重要，别忘）**

14. **移除全部 `PAP_MARK_DEBUG` / `syn_keep` 属性与 DebugCore/JTAG Hub**，重新综合一次。
15. 核对回到基线：`riscv-tests 49/1/0`、CoreMark **354,119 拍**、
    **LUT 3,721 / 可达 54.0745 MHz / slack +1.550 ns**（§7.2 有删除命令）。
16. **比赛提交的工程里绝不能留着调试核。**

**卡住了怎么办**

| 现象 | 原因 |
|---|---|
| Inserter 里选不到某个信号 | ① 找错模块了 —— 信号在 `u_core` 里，不在顶层（§7.1.2）；② 名字不对（PC 叫 `pc` 不叫 `pc_r`）；③ 真被综合优化掉了 —— 回第 1 步确认 `PAP_MARK_DEBUG` 加了（**只加 `syn_keep` 不够**）|
| 找不到"采样时钟" | **它不在 `Trigger Parameters` 里** —— 在 `Net Connections → Modify Connection → Select Net → Channel View → Clock Port` 页签（§7.1.1）|
| 找不到"触发条件"/"触发位置" | 这两个**不在 Inserter 里**，在 **Fabric Debugger 的 `Trigger Setup`** 里运行时配（§7.1.1），不用重新综合 |
| Debugger Scan JTAG 扫不到器件 | JTAG 通路问题。本板 Jtag 是 **FTDI**（枚举成两个 COM 口），确认那根 USB 线插了 |
| 波形"有信号但全不对" | **`.fic` 与 `.sbit` 不是同一次综合的** —— 这是头号坑，重做第 3~7 步 |
| 触发一直不满足 | ① Clock Port 接错域（接成 27 MHz 晶振了，应接 `clk_sys`）；② Value 填成了电平 `1` 而 `ex_flush` 长期为高 —— 用 `R`（上升沿）；③ `Match Type` 当初选了 `Basic`，运行时没法填 `R` |

> 远程平台那条路（§7.0/§7.3）**仍然有效**，作为备选：平台出 JTAG 与波形界面，
> `.fic` 还是本地 PDS 生成。但既然本地板在手，走上面这条更直接。

### 7.7 完全脚本化的备选路径（RTL 精确标记 + Inserter TCL）

**2026-09-25 查手册时发现的**：Fabric Inserter 有一条**不用点 GUI**的路径，
对"要反复重做、要进版本库"的场合明显更好。记在这里备选，
**当前仍建议先走 §7.6 的 GUI 路径**（一次做通、心里有数），再考虑切换。

依据：`Fabric_Inserter_User_Guide.pdf` §4「RTL 级插核」与 §5「TCL 命令」。

**路子一：RTL 里用【精确标记】直接指定 channel**

`PAP_MARK_DEBUG` 的值有两种形式：

| 形式 | 写法 | 含义 |
|---|---|---|
| 模糊 | `PAP_MARK_DEBUG="true"` 或 `="1"` | 只标记；Inserter 自动依次往 Trigger Port 上挂 |
| **精确** | `PAP_MARK_DEBUG="<核号/port类型+序号/channel号>"` | **直接指定连到哪个 channel** |

port 类型字母：`t` = trigger port、`d` = data port、`c` = clock port、`r` = reset port；
Clock/Reset 只有 1 个 channel，port 序号和 channel 序号都写 `0`。例如：

```verilog
// 采样时钟：调试核 0 的 clock port
wire clk_sys /* synthesis PAP_MARK_DEBUG="<0/c0/0>" */;
// 数据通道：调试核 0 的 data port 的 channel 0
wire dbg_pc0 /* synthesis PAP_MARK_DEBUG="<0/d0/0>" */ = pc[0];
// 同一个信号要连多处时，用逗号分隔多个标记
wire dbg_ex_flush /* synthesis PAP_MARK_DEBUG="<0/t0/0>,<0/d0/69>" */ = ex_flush;
```

> [!] **手册这条例子是错的，别照抄**：手册写的是
> `wire [7:0] debug_this_bus /* synthesis PAP_MARK_DEBUG="<0/t1/12>" */;`，
> 好像一个标记能给整条总线分配连续 channel。**实测 PDS 会把多比特 wire 上的
> 这个属性整条丢弃**（见 §7.2）。**总线一律拆成一位一根。**

手册明确：**"如果 PDS 工程中没有添加 fic 文件，或添加了空的 fic 文件，那么 Inserter
打开后，会根据 RTL 中标记的信息自动进行信号连接"** —— 打开 Inserter 一点就自动连好，
只需确认再保存。

> [!] 手册也提醒：对 **port** 标记时，**标记必须写在 `,` 之前**，否则会标到下一个 port 上。

**路子二：用 Inserter TCL 命令生成 `.fic`**

Inserter 支持一整套 TCL。关键几条：

```
ins_set_file -input <绝对路径>/cpu_top_board_syn.adf
ins_add_core 1
ins_operate -core 0 -trig 0 -unit 0
ins_set_core  -core 0 -data_depth 1024 -clock_edge 1 -trig_num 1 -multi_windows 0
ins_set_trig  -core 0 -trig 0 -unit_num 1 -type 1        ;# type 1 = Basic W/Edges
ins_set_unit  -core 0 -unit 0 -func == -value 1 -cnt_type 0
ins_set_condition -core 0 -trigger "TU0"
ins_set_capture   -core 0 -type windows -windows 1 -position 512
ins_list_nets                                            ;# 先把可连的 net 和它们的序号打出来
ins_set_net -core 0 -data -clock -reset "1 2 3 4 5 6"    ;# 参数是 net 的【序号】不是名字
ins_save <绝对路径>/cpu_top_board_ila.fic
```

> [!] `ins_set_net` **不接受网线名字做参数**（手册理由：有些 net 名含特殊字符会让 TCL
> 解析混乱，且名字过长不便输入），只接受 `ins_list_nets` 打印出来的**序号** ——
> 所以这条路要么先跑 `ins_list_nets` 抄序号，要么干脆用上面的"路子一"精确标记
> 让它自动连。
>
> `-value` 只接受**二进制**串，且**位数必须等于该 Trigger Port 的宽度**。

**什么时候值得切到这条路**：需要反复重建 `.fic`（比如探针清单还在改）、
或者想让 `.fic` 的生成过程可复现/可进版本库。**现在不必。**

---

## 8. 复现命令

```powershell
# 1) 生成 CoreMark 固件（ITER=1；上板要另用 1500，见下）
scripts\run_coremark.ps1 -Iter 1 -SkipSim

# 2) 跑剖析（不抓波形），得到 §2 的全部统计
cd sim
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+PROF"

# 3) 抓逐拍波形。不要先猜窗口 —— 一次抓足整个区间再切，省得反复重跑：
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" `
    "+PROF" "+TRACE_START=18000" "+TRACE_LEN=390000" "+TRACE_FILE=programs/trace_r1.txt"
#    （+TRACE_* 受 +PROF 门控，漏了 +PROF 会一个字符都写不出来）

# 4) 渲染波形图（窗口怎么切见 §3/§4 的 PC 条件）
python scripts\trace2svg.py sim\programs\trace_r1.txt doc\figures\pipeline_hazard_mix.svg `
    --title "core_bench_list (PC 0xdac-0x0dbc)：5 条指令 / 10 拍，3 拍 load-use 停顿 + 2 拍分支冲刷"

# 5) 反汇编（确认循环里是什么代码）
riscv-none-elf-objdump -d --start-address=0x0cd8 --stop-address=0x0d18 sim\programs\coremark.elf

# 6) 上板用固件：ITER 必须按"每迭代 354,119 拍 ÷ 板上时钟"重算，然后同步进 PDS 工程
#    （本地盘古板 49.8927 MHz（PLL）→ 1663，实测 11.8031 s；
#      远程平台 27 MHz（无 PLL）→ 重新按 270,000,000 ÷ 354,119 = 762 算，并改回 EE_TICKS_PER_SEC）
#    [!] 更省事的做法是直接用 scripts\build_bitstream.ps1 coremark（它把这几步串起来并校验）
scripts\run_coremark.ps1 -Iter 1663 -SkipSim
scripts\sync_firmware.ps1
```

> [!] **第 6 步是必须的。** 跑过第 1 步之后 `sim\programs\mem.hex` 就变成 ITER=1 的
> 固件了 —— 直接拿它上板只有 0.014 秒，CoreMark 判 invalid。
> 反过来，抓完波形若忘了同步，PDS 里留的又是上一版镜像（见 `pds/README.md` §8 坑 1b）。

**关于回归基线**：本报告的剖析能力全部落在测试台（`sim/tb_coremark.v`）与
`scripts/trace2svg.py` 里。`+PROF` / `+TRACE_*` **默认关闭**、不参与仿真，
所以开关它不会改变周期数，对照组之间可比。

当前基线：riscv-tests **49/1/0**；CoreMark 计时区间 **354,119** 拍
（测试台总周期 **1,457,776**）。
> 这是 **2026-09-25 BTB/BHT 之后**的基线（此前 358,846 / 1,462,898）。
> 再往前：420,070（基线）→ 382,972（取指重定向）→ 358,846（ID 级静态预测）
> → **354,119**（BHT 动态预测）。**改了流水线就重算 ITER，否则 CoreMark 判 invalid。**
