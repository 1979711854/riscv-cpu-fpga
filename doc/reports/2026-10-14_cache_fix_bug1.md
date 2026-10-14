# Cache + RT-Thread 挂死 —— 根因 #1 已修（2026-10-14）

> **[!] 2026-10-14 补：本文 §5 的"#2 仍未修"已作废 —— 根因 #2 已定位并修复。**
> #2 不是"load 返回错数据"（**已用 `-DLdChk` 证伪：297,379 条 RAM load 一条不错**），
> 而是 **CSR 写在 EX 级提交时漏了 `mem_ready_int` 门控**，RT-Thread 的
> `csrrw sp, mscratch, sp` 在冻结拍读到【写后】值 ⇒ sp 不切中断栈 ⇒ 内核链表被踩坏。
> 全文见 **`doc/reports/2026-10-14_cache_fix_bug2.md`**（约定 57）。
> `DESIGN_REV` 现为 **`0x2026_1019`**；rtthread 四种 Cache 配置**全部 PASS**。

> 接 `2026-10-14_cache_rtthread_sim_bisect.md`（归因：两个 Cache 都能打挂 RT-Thread 固件、
> 无 Cache 是 PASS ⇒ 功能 bug、与时序无关）。本文是**修复与验证**记录。
>
> 一句话：**`core.v` 的 ID/EX 寄存器清零条件漏了 `mem_ready_int` 门控** ——
> 冻结那一拍把【正在 EX 的发跳转指令自己】清掉了，它的链接值写回永久丢失。
> 已修（1 行），仿真 13 字节挂死 → 完整启动；四条基线不受影响。
> **[!] 但还有第二处独立缺陷（见 §5），Cache 版位流仍未可交付。**

---

## 1. 复现与定位链（方法可复用）

| 步 | 手段 | 得到什么 |
|---|---|---|
| 1 | `run_sim.ps1 -DCache -ICache` | 复现：**全程只收到 13 字节**，尾部 ` turn=WHITE`，与板上逐字节一致 |
| 2 | 加 `-PcTrace` + `scripts/pctrace_diff.py` | 首处分叉：指令 #5348 前后，pc `0x6b14` 之后 无 Cache→`0x2b4`、I-only→`0x72ac` |
| 3 | 解读 `pc_r` 语义（`core.v:1257`） | `pc_r` 是**顺序发出地址流**，重定向落 `target+4` ⇒ 分叉那拍的重定向目标 = **`ra`** |
| 4 | 加 `-ITrace`（IF/ID + 三级 pc + 双写口） | `0x2ac` 的 `jalr -1956(ra)` 在 EX 发 `ex_flush`、同拍 `mem_ready_int=0`；**下一拍 `id_ex_pc` 被清成 0**，而 `ex_mem_pc` 仍是旧的 ⇒ **这条 jalr 进不了 EX/MEM** |

**结论**：`_start` 里 `0x2a8 auipc ra,0x7` 刚把 `ra=0x72a8` 写下，
`0x2ac jalr` 本该把链接值 `ra=0x2b0` 写回 —— 它被清掉 ⇒ 唯一生效的 `ra` 还是 `0x72a8`
⇒ `0x6b08` 的 `ret` 跳回 `0x72a8` ⇒ 执行流跑飞、~5.5k 拍挂死。

---

## 2. 根因（`rtl/core/core.v:1350` 附近）

```verilog
// 修前
if (!resetn || ex_flush || ex_mispred || stall_int || trap) begin   // ← 没有 mem_ready_int

// 修后
if (!resetn || trap || ((ex_flush || ex_mispred || stall_int) && mem_ready_int)) begin
```

**为什么**：`ex_flush` / `ex_mispred` / `stall_int` 都是 **EX 里那条指令自己**发出的
（jal/jalr/分支 / load-use）。流水线被访存停顿冻结（`mem_ready_int=0`）时**整条流水线
不能平移** —— ID/EX 里躺着的就是那条发冲刷的指令**本身**；这时清 ID/EX = **把它自己杀掉**。

`EX/MEM` 侧早就有同样的门控（A.0 修复，见 `core.v:1474-1482` 注释：
"mem_ready_int=0 时整条流水线冻结、任何平移都不能发生，故清 EX/MEM 也必须一起压住"），
**ID/EX 侧漏了同一刀**。

**为什么 `trap` 不门控**：肇事指令必须死（约定 20：不得产生副作用）；冻结期间清掉它、
放开后 `EX/MEM <= 气泡`，与当场清等价（同 A.0 注释的推理）。
误清的只有"发冲刷的指令自己"这一类，而它恰恰是**必须活到 MEM/WB** 的那条
（`jal/jalr` 要写链接值、`mret` 折进 ex_flush）。

**为什么以前看不出来**：`mem_ready_int=0` 只在真访存停顿时出现（`+MEMWAIT` 才注入），
撞上"跳转在 EX 解析"那一拍的概率极低；带 Cache 后**取指链几乎每拍停顿**
（冷启动每次取指都缺失、`mem_ready` 0/1 交替）⇒ 撞上概率≈1。
CoreMark（无 trap、且无 Cache 口径跑分）与 riscv-tests（镜像小、缺失少）天然盖不住。

---

## 3. 修复验证（仿真）

| 配置 | 修前 | 修后 |
|---|---|---|
| `-ICache` | **13 字节**挂死（banner 都没有） | **1254 字节**：banner + `[boot]` 全出 + **render/AI 两线程都起来** ✓ |
| 无 Cache（对照） | PASS | PASS（不变） |
| riscv-tests 默认双发射 | 49/1/0 | **49/1/0** ✓ |
| riscv-tests `-DCache -ICache -EarlyLd` | 49/1/0 | **49/1/0** ✓ |
| CoreMark `-Iter 1 -EarlyLd` | 232,345 | **232,345（一字不差）** ✓ |

⇒ 修复**只影响"冻结拍撞上冲刷"这一角**，对无 Cache 基线逐位不变。
`DESIGN_REV` 已按约定 42 递增到 **`0x2026_1018`**。

---

## 4. 顺带查清的（省后面查的人）

* **`??` 不是固件打的**：`serial_monitor.ps1` 用 `ReadExisting()` 且未设 `$sp.Encoding`
  ⇒ .NET `SerialPort` 默认 **ASCII 解码，≥0x80 的字节一律变 `?`**（约定 55）。
* 快通路 load **不经过正常访存口** ⇒ `-DLTrace` 里看不到它们（排查时要记得）。
* `pc_r` 是**顺序地址流**、双发射配对时 `+8`、停顿原地重复 ⇒ 用 `pctrace` 直接 diff 会
  因**配对差异**产生假分叉；要判"指令级差异"请用 `scripts/itrace_stream_diff.py`。

---

## 5. [!] 仍未修：第二处缺陷（load 返回错数据）

修完 #1 后程序能完整启动，但**跑得更远之后仍然挂**（现象与 D-only 那份一致：
RT-Thread 打寄存器转储）。已定位到的证据：

* `-TrapTrace`（新增）统计：133 次 trap = 15 次定时器中断（正常）+ **118 次 `cause=6`
  （store 地址未对齐）全部在 `pc=0x2da4`** ⇒ 死循环转储。
* `0x2da4` 属 `_timer_remove`：`lw a3,20(a0)` → `sw a4,4(a3)`。
  `trap_tval` = **`0x00812627`**（≈ 指令字 `0x00812623`+4）、`-NoEarlyLd` 下是
  **`0x646e6576`**（ASCII "vend"）⇒ **指针寄存器被载入了"隔壁的内容"**（指令/字符串），
  即**某次 load 返回了错数据**。
* **与 `EARLY_LD` 无关**（`-NoEarlyLd` 同样挂，只是肇事 pc 变成 `0x3308`）；
  与 D-Cache 无关（I-only 就复现）⇒ 在**公共 load 数据路径**上。

**下一步（建议顺序）**：
1. 给 `-LTrace` 加"寄存后的 mem_rdata"列，跑 无 Cache / I-only 两份，
   用序列对拍找**第一次返回错数据的 load**（同一程序 ⇒ 事件序列应逐条一致）。
2. 盯三处嫌疑：`wb_rdata_snap` 抓拍时机（约定 47 同族）、寄存器堆 write-first 旁路在
   冻结多拍下的行为、I-Cache 缺失停顿与 MEM/WB 的交互。
3. 修好后必须重跑：四条基线 + `run_sim.ps1`（无Cache/只D/只I/I+D 四种）+
   重出位流（`c10a2478` / `9feaa089` 都是**旧 RTL，勿烧**）。

---

## 6. 本轮新增工具（都在仓库里）

```powershell
scripts\rtthread\run_sim.ps1 -DCache -ICache            # 复现/验证
scripts\rtthread\run_sim.ps1 -ICache -PcTrace           # PC 逐拍落盘（对拍找首处分叉）
scripts\rtthread\run_sim.ps1 -ICache -ITrace            # IF/ID + 三级 pc + 写口
scripts\rtthread\run_sim.ps1 -ICache -TrapTrace         # trap cause/pc/tval
scripts\rtthread\run_sim.ps1 -ICache -LTrace            # 访存事件
python scripts\pctrace_diff.py  <A> <B>                 # PC 流对拍（含原始逐拍上下文）
python scripts\itrace_stream_diff.py <A> <B>            # 指令流对拍（配对感知，推荐）
```
