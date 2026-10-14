# RT-Thread + Cache 上板挂死 —— 仿真归因（2026-10-14）

> **[!] 2026-10-14 晚补：本文 §4 的"最强怀疑（未证实）"（Cache 没有重定向输入）已被证伪。**
> 真正的两条根因都在 `core.v` 的 `mem_ready_int` 门控上：
> **#1** ID/EX 清零（约定 56，`..._bug1.md`）、**#2** CSR 写 / `mret`（约定 57，`..._bug2.md`）。
> "load 返回错数据"也已用 `-DLdChk` 证伪（297,379 条 RAM load 一条不错）。
> 现状：`DESIGN_REV=0x2026_1019`，rtthread **四种 Cache 配置全部 PASS**。

> 接 `2026-10-13_session_state.md`。上一轮（`4055052`）把 **`c10a2478`
> （rtthread + I+D Cache @76.5052 MHz）上板确定性挂死**记录在案，并给 `tb_rtthread`
> 补上了 Cache 开关（约定 55）。**本文是补完开关之后的归因结果。**
>
> 一句话：**不是"有 Cache 就不行"，是"带 Cache 的 RT-Thread 固件不行"** ——
> 而且**两个 Cache 都能打挂它**；仿真 100 MHz 就能复现 ⇒ **功能 bug，与时序无关**。

---

## 1. 仿真对拍（四种配置，同一固件 `FW=RTTHREAD-GOMOKU-G3`）

```powershell
scripts\rtthread\run_sim.ps1                  # 无 Cache（= 8894cdcb 那颗的配置）
scripts\rtthread\run_sim.ps1 -DCache          # 只开 D
scripts\rtthread\run_sim.ps1 -ICache          # 只开 I
scripts\rtthread\run_sim.ps1 -DCache -ICache  # I+D（= c10a2478 的配置）
```

| 配置 | vvp 首行 `SIM CONFIG` | 串口字节 | render 线程 | AI 线程 | `[hb]` 心跳 | 结果 |
|---|---|---|---|---|---|---|
| **无 Cache** | `DUAL=1 DCACHE=0 ICACHE=0 EARLY_LD=1` | 168 | **[OK]** | **[OK]** | **[OK]** | **=== PASS ===** |
| **只开 D** | `DUAL=1 DCACHE=1 ICACHE=0 EARLY_LD=1` | 168 | **[OK]** | **[OK]** | — | **崩**（串口打出寄存器转储）|
| **只开 I** | `DUAL=1 DCACHE=0 ICACHE=1 EARLY_LD=1` | **13** | — | — | — | **崩得早**（banner 都没出来）|
| **D + I** | `DUAL=1 DCACHE=1 ICACHE=1 EARLY_LD=1` | **13** | — | — | — | **崩得早** |

**读法**：

1. **无 Cache 是好的** —— 168 字节、四条自检全过。这与板上 `8894cdcb`（23:43 日志）一致。
2. **两个 Cache 都能打挂它**，但**崩的深度不同**：
   * **只开 D**：走到更远 —— banner、`[boot] gomoku render thread running`、
     `[boot] gomoku ai thread running` 都出来了，之后才崩（串口里是一段
     `Stack frame: / ra / mstatus / t0 / t1 …` 的**寄存器转储**）。banner 里
     `keys: SW4/5/6/7 …` 那行还出现了 `??` —— **字节已经损坏**。
   * **只开 I**：**更早**就挂 —— 连 RT-Thread banner 都没打全。
3. **I+D 单独看没有信息量**：`ICACHE_EN=1` 已经足以复现全部症状（13 字节 + ` turn=WHITE`），
   **所以嫌疑应集中在 I-Cache 侧，D-Cache 是"另一条独立的坏路"**。

### 与板上现象的对应

| 板上 | 配置 | 仿真对应 |
|---|---|---|
| `c10a2478`（00:08 归档）| I+D @76.5052 MHz | 仿真 I+D = **13 字节**，与板上**同一个数字**、同一段 ` turn=WHITE` |
| 00:57 `generate_bitstream/cpu_top_board.sbit` | **只开 D** @85.0051 MHz | 板上见 `uart_20261014_010219.txt`：banner 打 3 次、**停在 `[boot] heap`**（render 线程都没起来）|

> [!] **00:57 那颗要单独记一笔**：它是**只开 D @85 MHz**（合并日志
> `DCACHE_EN=1 / ICACHE_EN=0`），而它的 CPU 域时序是 **−0.177 ns / 13 个失败端点（17,821）**
> —— **即使功能修好，85 MHz 也塞不进去**。所以"只开 D @85"有两个独立问题叠加：
> **时序不过** + **功能被 D-Cache 打挂**。
> （`c10a2478` 则相反：**时序是历次 I+D 最好的一次，+0.904 ns / 全设计 0 失败端点**，
> 纯粹是功能挂。）

---

## 2. 已经排除掉的（省后面查的人）

| 怀疑 | 怎么排除的 | 结论 |
|---|---|---|
| **trap / 中断路径本身** | `scripts\run_own_tests.ps1 -ICache` → `exceptions` + `timer_irq` **都 PASS**（基线无 Cache 也是 2/0）| 不是"一陷就挂" |
| **地址截位（>32 KB 取指）** | `core.v:628` `imem_addr = fetch_addr[15:2]` 是 **14 位字地址**，覆盖完整 64 KB；`cache_i` 的 `idx=word[8:0]`、`tag=word[13:9]` 合起来也是全 64 KB | 不是截位 |
| **MMIO / 显存被缓存** | `mem_bus.v:170` `ram_hit = (mem_addr[31:16]==16'd0)`，Cache 的 `req` 挂在这个门控上；视频寄存器/显存在 `0x8003_xxxx` | **永远不会被缓存**，不存在"屏幕写不出去" |
| **`fence.i` 是 NOP** | 本设计无自修改代码 | 不相关 |

---

## 3. 崩溃现场

* **只开 I**：仿真收尾 `pc = 0x00004bc4`。`addr2line` 解出来是
  **`scripts/gomoku/ai.c:239`，函数 `gen_top`**（AI 走子生成），具体落在它的
  **尾声**（从栈上恢复 callee-saved 寄存器那一串 `lw`）。结合串口里那段
  ` turn=WHITE`（**说明棋局状态已经被搞到 `turn=WHITE`，而仿真根本没驱动过按键**），
  更像"**执行流已经跑偏**"而不是"卡在某条指令"。
* **只开 D**：串口打出 RT-Thread 的寄存器转储（`Stack frame:` / `ra` / `mstatus=0x1880` / …），
  即**取了一条不该取的异常**。

---

## 4. [!] 目前最强的怀疑（**未证实，别当结论用**）

**两个 Cache 模块都没有任何"流水线重定向"输入。**

端口清单（`rtl/bus/cache_i.v` / `cache_d.v`）里只有
`clk / resetn / word / bram_rdata`（D 多一个写口），
**没有 flush / trap / redirect / mispred 之类的信号**。

而 `cache_i.v` 的头注释明确把正确性**建立在下面这个假设上**：

> "回填地址直接用当拍的 idx —— **因为停顿期间地址被冻在 A**，idx 就是 A 的索引"

可 `core.v:330` 的 `fetch_addr` 优先级链是：

```
fetch_addr = trap ? trap_target : ex_flush ? ex_target : ex_mispred ? ex_mispred_target
           : p_redirect ? p_target : (stall_int || mc_stall || !mem_ready_int) ? if_addr_d : …
```

**`trap` / `ex_flush` / `ex_mispred` / `p_redirect` 全都排在"停顿回退到 `if_addr_d`"之上。**
于是：**缺失停顿期间一旦发生重定向，地址就不再冻在 A** ——
回填用的 idx、以及旁路取回的数据，就可能和真正要取的那条指令对不上。

**这条能解释"为什么 CoreMark 和小测试没事"**：

* **CoreMark 是裸机、不开定时器中断** ⇒ 几乎**不产生 trap**；I+D @76.5 板上实测过（325.96 分，
  CRC 逐位一致）就是因为整段跑下来没有 trap。
* `exceptions.S` / `timer_irq.S` **确实有 trap**，但代码/数据都极小 ⇒ 缺失窗口撞上重定向的
  概率极低。
* **RT-Thread 是 40 KB 代码 + 每 1 ms 一次定时器 trap + 大量数据访问** ⇒
  缺失期间撞上重定向的概率很高，**每次 tick 都是一次掷骰子**。

### 怎么证实（留给 CPU/RTL 线，很便宜）

在仿真里加一条**只报不改**的断言即可：

```verilog
// stall_r（或 d_stall）为 1 的那一拍，fetch_addr 若发生变化 → 打印告警
if (stall_active && (fetch_addr !== fetch_addr_d1)) $display("REDIRECT-DURING-STALL @%0t", $time);
```

无 Cache 跑同一条固件应当**一次都不报**；带 Cache 跑应当**报** —— 报了就基本坐实。

---

## 5. 对现有口径的更正

1. **`pds/RV32I_1/bitstreams/README.md` 里 `56374a08` 那条写的"结论：D-Cache 可以常规开着，
   不损失分数" —— 在 CoreMark 上成立，对五子棋/RT-Thread【不成立】。**
   （那次 `56374a08` 跑的是 CoreMark，而 CoreMark **不经过 gomoku/RT-Thread 的代码与中断路径**。）
2. **约定 43 的"塞得进 D、塞不进 I"要加限定**：那句 `+0.151 ns` 是 **A1 之前**、
   且是 **CoreMark 口径**。**A1 之后的"只开 D @85"实测是 −0.177 ns**（00:57 那颗）；
   而且**功能上：只开 D 也打挂 RT-Thread**。
3. **提交档继续用 Cache 全关**（= `8894cdcb` / `bcd8fdd2` 那一套）。修好之前
   **任何"rtthread/gomoku + Cache"的位流都别烧**。
4. **高阶任务① 的答辩口径不变**（"实现并量化评估后判定为负收益，默认关"），
   但现在多一条**更硬**的理由：**它在非 CoreMark 负载上会挂**。

---

## 6. 复现清单

```powershell
# 1) 前提：tb_rtthread 必须能吃 -D（约定 55，已在 4055052 里落地）
scripts\rtthread\run_sim.ps1 -DCache            # 只开 D：崩，但走得远
scripts\rtthread\run_sim.ps1 -ICache            # 只开 I：13 字节，早崩
scripts\rtthread\run_sim.ps1 -DCache -ICache    # = c10a2478 配置
scripts\rtthread\run_sim.ps1                    # 无 Cache：PASS（对照组，必须跑）
# 每次都要核对 vvp 首行的 SIM CONFIG
# 各约 5~6 分钟

# 2) 排除 trap 路径（快，几分钟）
scripts\run_own_tests.ps1 -ICache               # exceptions + timer_irq 应 PASS
```

仿真产物（本轮的原始日志，未入库，在临时目录）：
`rt_DCache_sim.log` / `rt_ICache_sim.log` / `rt_idcache_sim.log`。

---

## 7. 影响面 / 待办

* **[!] 这条线现在是 CPU 线的活**（`rtl/bus/cache_*.v` + `rtl/core/core.v` 的
  `fetch_addr` 优先级），归 **乙（CPU/RTL）**。见
  `doc/reports/2026-10-13_taskbook_v10_cpu.md` —— 它已经在"覆盖 A/B 热身"里要求补
  **`sim/tests/hi_fetch.S`（代码 >32 KB 取指）**，而 RT-Thread 固件（`.text` 40 KB）
  正是这个区间的第一个真实负载。
* **五子棋线不受阻塞**：T1/G3 在**无 Cache** 配置下是好的（`8894cdcb`，
  板上 + 仿真双证）。**甲按 `2026-10-13_taskbook_gomoku_v2.md` 继续即可**，
  别在 Cache 上耗时间。
* **`c10a2478` 与 00:57 那颗 D-only@85 都标"勿烧"**，只作存档。
