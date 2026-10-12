# I+D 板上失败的根因：`wb_rdata_snap` 停顿快照取错了流水级（2026-10-12）

> **结论先行**：I+D 位流（`fa957dbd`）板上"只有 banner 反复"的失败，**不是物理实现问题，
> 是 `core.v` 里一个真 bug**：`wb_rdata_snap` 在**停顿沿**的快照写成了
> `ex_mem_ld_fast ? ld_early_data : mem_rdata` —— 用 **EX/MEM 级**指令的信号，
> 去选 **MEM/WB 级**指令的数据。一行改掉（[core.v:1174](../../rtl/core/core.v)），
> 四条回归全过，A/B 对照板上症状逐字复现并被消除。
> **此前"故障在物理/实现层"的结论已作废**（见 §5）。

---

## 1. 现象

| 现场 | 观测 |
|---|---|
| **板上**（`uart_20261012_010314.txt`）| 串口只有 banner 反复（`[build] FW=COREMARK RTL=0x20261015`），≈590 次/秒，`2K performance run` / `Total ticks` / `[cache]` 一个都没有；相邻两份字符互相交织 |
| **仿真**（同一配置，ITER=1）| CPU 在 **cyc≈8124 跑飞**，`pc` 跳 0（`mtvec` 复位值 = `_start`）⇒ 反复从头跑 ⇒ 同样的 banner 循环 |

板上与仿真**症状逐字一致** ⇒ 可以在仿真里定位，不必上 ILA。

**触发配置**：`DUAL_ISSUE=1 + EARLY_LD=1 + DCACHE_EN=1 + ICACHE_EN=1`。
**四个条件缺一不可**，下面 §3 逐条解释。

---

## 2. 根因（cyc=8119–8120 现场）

`sim/tb_dbg.v` 的 `P` 行逐拍 dump（`programs/dbg_trace.txt`，已随修复删除）：

```
P cyc=8118 ... ldfx_i=1 ldfx_e=0 ... snen=1 snap=0000f137 wbsen=1 wbsnap=00008da6 mrdata=00000000 mrdy=1
P cyc=8119 ... ldfx_i=1 ldfx_e=1 ... snen=0 snap=0000f137 wbsen=0 wbsnap=00008da6 mrdata=00000000 mrdy=0   <-- 停顿第一沿
P cyc=8120 ... ldfx_i=1 ldfx_e=1 ... snen=1 snap=00000066 wbsen=1 wbsnap=00000066 mrdata=00000066 mrdy=1
                                     ^^^^^^^^^^                 ^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^
                                     L2 的快通路     ← 抓成这个 ✗     本应是这个 ✓
```

* **cyc=8119**：`mrdy=0` = 停顿第一沿。此刻
  * **MEM/WB 里是 L1**（普通 load `lw s2,36(sp)`），它的数据在 `mem_rdata = 0` ✓
  * **EX/MEM 里是 L2**（快通路 load `lw s1,40(sp)`），`ldfx_e = 1`，
    它的提前读数据在 `ld_early_data = 0x66`（`snen=0`，所以走 `ld_rdata` 那一路）
* 旧代码 `wb_rdata_snap <= ex_mem_ld_fast ? ld_early_data : mem_rdata` 里
  `ex_mem_ld_fast` 说的是 **L2（EX/MEM 级）**，于是抓成 `0x66` ✗
* cyc=8120 起 L1 写回 `0x66`（**下一条 load 的值**）⇒ 寄存器被污染 ⇒ 几拍后跑飞

### 为什么"这里只能取 `mem_rdata`"

快通路 load **在自己的前进沿就被上面第一支**（`mem_ready_int && ex_mem_ld_fast`）
**抓过快照**（`snap_en=1`）—— 它进 MEM/WB 的那一拍一定在前进（`mem_ready_int=1`），
所以**永远走不到** `!wb_rdata_snap_en` 这一支。⇒
**这一支服务的必然只是【普通 load】**，它的数据就是实时 `mem_rdata`。
`ex_mem_ld_fast ? ld_early_data : …` 这个三元式是**把两个流水级的信号张冠李戴**。

---

## 3. 为什么四个条件缺一不可（解释历史观测）

| 条件 | 为什么需要 |
|---|---|
| `EARLY_LD=1` | `ex_mem_ld_fast` 只在 `EARLY_LD != 0` 时才可能为 1（`ld_fast` 表达式门控）⇒ **`EARLY_LD=0` 时三元式恒退化为 `mem_rdata`，bug 不可达** |
| `ICACHE_EN=1` | 触发需要"**停顿沿**"，而停顿要有来源。I-Cache 缺失把 `mem_ready` 压 0（≈4,400 次/迭代）⇒ 机会极多 |
| `DCACHE_EN=1` | 与 I-Cache 同开才是失败配置；**只开 D 时停顿来自 D-Cache 缺失，11.7 s 里只有 25,081 次** ⇒ 命中该 corner 的概率极低（这就是"D-only 版板上能过"的原因）|
| 普通 load 在 WB **且** 快通路 load 在 EX/MEM | corner 的形状本身 |

> [!] **这也解释了"为什么四条回归抓不到它"** ——
> `run_riscv_tests.ps1` / `run_own_tests.ps1` / AMO 的默认配置都是 **`EARLY_LD=0`**
> （且代码短、无 Cache 停顿）；CoreMark 的 `+MEMWAIT` 测试虽有停顿，但**没有 I-Cache**
> ⇒ 都没踩到。**修复后应把 `-DCache -ICache -EarlyLd` 纳入回归**（见 §6）。

---

## 4. 修复

`rtl/core/core.v` 的 WB 段快照 always 块，停顿那一支：

```diff
-            wb_rdata_snap    <= ex_mem_ld_fast ? ld_early_data : mem_rdata;
+            wb_rdata_snap    <= mem_rdata;
```

**安全性**：等价的等价性论据见 §2；实现上**只有这一支变**，
`mem_ready_int=1` 的两支（前进沿快照 / 清 `snap_en`）**一字未动** ⇒
**`EARLY_LD=0` 或 `MEMWAIT=0`（无停顿）时逐位不变**（实测也确认了，见 §5 回归）。
逻辑还**少了一个 mux 输入** ⇒ 对时序只会更友好。

---

## 5. 验证（A/B + 四条回归）

**A/B —— 唯一变量是这一行**（同配置 `DUAL+DCACHE+ICACHE+EARLYLD`，同固件 ITER=1）：

| 版本 | 结果 |
|---|---|
| **未修（HEAD）** | `vvp` 跑 150 s 不结束，日志里 banner 反复 **28 次**、字符交织（`[[buiild]]`）—— **与板上症状逐字一致** ✗ |
| **已修** | 一次跑完，**1,551,521 拍**，无 trap；四个 CRC 全对 ✓ |

**四条回归（已修）**：

| 回归 | 结果 |
|---|---|
| `run_riscv_tests.ps1` | **49 PASS / 1 FAIL / 0 TIMEOUT** ✓（与基线一致）|
| `run_own_tests.ps1` | **2 PASS / 0 FAIL** ✓ |
| AMO T0（`tb_amo_int.v` + `amo_int.S`）| **PASS**（`RAM[0x2000]=0x12`、UART `0f`/`12`）✓ |
| `run_coremark.ps1 -EarlyLd` 四 CRC × `+MEMWAIT=0/1/2/3` | **8 组全对**：`seedcrc=e9f5` / `crclist=e714` / `crcmatrix=1fd7` / `crcstate=8e3a` ✓ |

> `+MEMWAIT=1/2/3` 是**直接**打在这一支上的（它们就是制造停顿），8 组全过 ⇒ 修复正确。

### [!] 与旧记录的冲突（需要重新认识）

本项目此前记为"**I+D 长仿真 ITER=50 = 1330 万拍、四个 CRC 全对**"，并据此判定
"逻辑对、故障在物理层"。**这与本次结论直接冲突** ——
未修的 RTL 在 ITER=1 上 **8,124 拍就崩**，长仿真不可能跑出正确 CRC。

最可能的解释：**那份长仿真没有加 `-EarlyLd`**（`EARLY_LD=0` 时 bug 不可达，见 §3）。
⇒ **"故障在物理实现层"的结论作废**；§8.3.4 与交接文档 §2.3 已同步更正。
以后凡是"验证 Cache / 任务 C"的仿真，**配置必须显式写全并核对首行 `SIM CONFIG:`**。

---

## 6. 下一步

1. **重出 I+D 位流**（`EARLY_LD=1 + DCACHE_EN=1 + ICACHE_EN=1`）——
   逻辑既然修对了，**优先在 85 MHz 再试一次**（此前 −0.857 ns 是含这个 bug 的网表量的，
   值不值得信要重测）；不收敛再退回 **76.5 MHz（`RATIO0=15.0`）**。
   步骤照 `2026-10-12_handoff_completeness_first.md` §2.1（PLL 重生成 + 4 处固件常量 + ITER 重算）。
2. **上板复验**：判据 = 串口出完整 CoreMark（不再是 banner 循环）+ 四个 CRC 逐位相同 +
   `[cache] I/D` 计数非 0。
3. **把 `-DCache -ICache -EarlyLd` 加进回归**（当前四条回归覆盖不到这个 corner）。

---

## 7. 一句话

> `wb_rdata_snap` 的停顿分支本来是拿**下一条指令（EX/MEM）**的"快通路 load"标志，
> 去选**当前这条（MEM/WB）**指令的读数据 —— 在 I-Cache 缺失冻结下就抓成了**别人的值**。
> **一行改回 `mem_rdata`**；A/B 对照板上症状逐字复现又被消除，四条回归全过。
> **I+D 的板级失败是逻辑 bug，不是布局拥塞** —— 之前"物理不可行"的结论作废。
