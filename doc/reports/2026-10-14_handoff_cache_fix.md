# 交接：Cache + RT-Thread 挂死 —— 根因 #1 已修，根因 #2 待修（2026-10-14）

> 读者：下一个接手 CPU/RTL 线的人（或我自己开新会话）。
> 本文**自包含**：只看这一份 + `CLAUDE.md` 即可开工。
> 上一轮的归因见 `doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`；
> 本轮的修复证据链见 `doc/reports/2026-10-14_cache_fix_bug1.md`。

---

## 0. 一句话

`rtl/core/core.v` 的 ID/EX 寄存器清零漏了 `mem_ready_int` 门控 ⇒ "发跳转的指令把自己清掉、
`jal/jalr` 链接值写回丢失" —— **已修并验证**（`DESIGN_REV = 0x2026_1018`，commit `4b6c413`）。
但**还有第二处独立缺陷（load 返回错数据）未修**，所以 **Cache 版位流仍不可交付**。

---

## 1. 仓库 / 起手

- 仓 `D:\riscv-cpu-fpga_merged`，分支 **`dualissue`**，HEAD `4b6c413`（工作区干净，**未 push**）。
- 先读（按序）：
  1. `CLAUDE.md` 的 **约定 55 / 56**（本轮的坑与承重教训）
  2. `doc/reports/2026-10-14_cache_fix_bug1.md`（证据链 + #2 现状 + 下一步做法）
  3. `doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`（上一轮的归因）
- 时间预算参考：`-ICache` 仿真约 3~4 分钟；`riscv-tests` 全量约 5 分钟；
  `run_coremark.ps1 -Iter 1 -EarlyLd` 约 5 分钟；PDS 出位流约 8~15 分钟。

---

## 2. 已完成（别重做）

| 项 | 结果 |
|---|---|
| **根因 #1**：ID/EX 清零缺 `mem_ready_int` 门控 | **已修**（1 行）`if (!resetn \|\| trap \|\| ((ex_flush\|\|ex_mispred\|\|stall_int) && mem_ready_int))`；`trap` 保持无条件（肇事指令必须死） |
| `-ICache` 仿真 | 修前 **全程 13 字节挂死** → 修后**完整启动**（banner + render/AI 两线程 + 心跳窗口内到位） |
| riscv-tests：默认双发射 | **49 PASS / 1 FAIL / 0 TIMEOUT** ✓（唯一 FAIL = `ma_data`，预期） |
| riscv-tests：`-DCache -ICache -EarlyLd` | **49/1/0** ✓ |
| CoreMark：`-Iter 1 -EarlyLd` | **`Total ticks 232,345` 一字不差** ✓（证明对无 Cache 基线零影响） |
| 位流归档 | `9feaa089`（rtthread + D-only @85）已建 + 归档 + 登记 README，**标"勿烧"** |

**根因 #1 机理一句话**：`ex_flush`/`ex_mispred`/`stall_int` 都是 **EX 里那条指令自己**发出的；
流水线被访存停顿冻结（`mem_ready_int=0`）时整条流水线不能平移，ID/EX 里躺着的就是那条
**发冲刷的指令本身** ⇒ 清 ID/EX = 把它自己杀掉 ⇒ 它进不了 EX/MEM ⇒ `jal/jalr` 的链接值
写回永久丢失。`EX/MEM` 侧早有同样的门控（A.0 修复，`core.v:1474-1482`），ID/EX 漏了。

---

## 3. [!] 待修：根因 #2（load 返回错数据）

**现象**：修完 #1 后程序能完整启动，但跑得更远仍挂 —— RT-Thread 打寄存器转储
（与 D-only 那份现象同形）。

**已定位**（`-TrapTrace`）：

* 133 次 trap = 15 次定时器中断（正常）+ **118 次 `cause=6`（store 地址未对齐）
  全部在 `pc=0x2da4`** ⇒ 死循环转储。
* `0x2da4` 属 `_timer_remove`：`lw a3,20(a0)` → `sw a4,4(a3)`。
* `trap_tval` = **`0x00812627`**（≈ 指令字 `0x00812623`+4）、`-NoEarlyLd` 下
  = **`0x646e6576`**（ASCII "vend"）⇒ **指针寄存器被载入了"隔壁的内容"**
  ⇒ **某次 load 返回了错数据**。
* **范围**：I-only 就复现（不需要 D-Cache）；`-NoEarlyLd` 同样挂（只是肇事 pc 变成
  `0x3308`）⇒ 在**公共 load 数据路径**上。

**下一步（建议顺序）**：

1. 给 `-LTrace` 加"**寄存一拍后的 `mem_rdata`**"列 —— 现有列里 `mem_rdata` 与 `mem_addr`
   同拍，其实是**上一次访存**的数据，容易读错。
   然后跑 无 Cache / `-ICache` 两份，做**事件序列对拍**（同一程序 ⇒ 访存事件序列应逐条
   一致），找出**第一次返回错数据的 load**。
2. 顺那条 load 的级间路径查三处嫌疑：`wb_rdata_snap` 抓拍时机（约定 47 同族）、
   `u_regfile` 的 write-first 旁路在"冻结多拍"下的行为、I-Cache 缺失停顿与 MEM/WB 的交互。
3. 修好后必跑（**一个都不能少**）：
   * `scripts\run_riscv_tests.ps1`（默认）与 `-DCache -ICache -EarlyLd` → 都要 49/1/0
   * `scripts\run_coremark.ps1 -Iter 1 -EarlyLd` → `Total ticks` 必须还是 **232,345**
   * `scripts\run_own_tests.ps1 -DCache -ICache -EarlyLd` → 2 PASS
   * `scripts\rtthread\run_sim.ps1` 四种配置（无Cache / 只D / 只I / I+D）→ 都要 PASS
   * 递增 `DESIGN_REV`，然后重出受影响位流（并把旧位流标"勿烧"）

---

## 4. 调试工具（本轮新增，都在仓库里）

```powershell
scripts\rtthread\run_sim.ps1 -ICache                 # 复现/验证（默认 = 双发射 + EARLY_LD + Cache 关）
scripts\rtthread\run_sim.ps1 -ICache -PcTrace        # PC 逐拍落盘（对拍找首处分叉）
scripts\rtthread\run_sim.ps1 -ICache -ITrace         # IF/ID + 三级 pc + 双写口
scripts\rtthread\run_sim.ps1 -ICache -TrapTrace      # trap cause / 肇事 pc / tval
scripts\rtthread\run_sim.ps1 -ICache -LTrace         # 访存事件（pc/addr/wdata/rdata/ready）
scripts\rtthread\run_sim.ps1 -ICache -RxTrace        # 逐字节打 rx + pc
python scripts\pctrace_diff.py       <A> <B>         # PC 流对拍（含原始逐拍上下文）
python scripts\itrace_stream_diff.py <A> <B>         # 指令流对拍（★配对感知，推荐）
```

**坑（都踩过，别重复）**：

* **`pc` 流在双发射下会因"配对与否"假分叉** —— 判"指令级差异"要用
  `itrace_stream_diff.py`（它从 IF/ID 内容变化提取执行流）。
* `pc_r` 是**顺序发出地址流**：配对时 +8、停顿原地重复，重定向落 `target+4`
  （所以"跳号"不代表丢指令）。
* **快通路 load 不经过正常访存口**（专用读口 mem2）⇒ `-LTrace` 里看不到它们。
* `serial_monitor` 日志里的 `?` 是**它自己 ASCII 解码把 ≥0x80 字节显示成这样**
  （约定 55），不是固件打的 —— 先 `Format-Hex` 看原始字节。
* trace 产物（单个几百 MB）已进 `.gitignore`，**别入库**。

---

## 5. 交付口径（未变，别乱改）

* **生产/交付继续用 Cache 全关**：五子棋 = `8894cdcb`；跑分 = `bcd8fdd2`（365.93 @85.0051 MHz）。
* **`c10a2478`（rtthread + I+D @76.5）与 `9feaa089`（rtthread + D-only @85）都是旧 RTL、
  已标"勿烧"**（`pds/RV32I_1/bitstreams/README.md` 已登记）。
  另：**D-only @85 的 CPU 域是 −0.177 ns / 13 失败端点**，即使功能修好也塞不进 85 MHz。
* **高阶任务① 答辩口径不变**（"实现并量化评估后判定为负收益、默认关"），
  但现在多一条更硬的理由：带 Cache 时它在非 CoreMark 负载上会挂（#1 已修、#2 待修）
  —— **修完之前不要对评委说"Cache 可用"**。
* **队友（RAS 线）可基于 `4b6c413` 开工**：本轮的 `core.v` 改动只有 ID/EX 寄存器块
  一个 hunk，与取指/预测段（RAS 的活）不重叠。
* **RTL 改动纪律**：改完 `core.v` → 递增 `DESIGN_REV`（现在 `0x2026_1018`）→ 跑四条基线
  → 重出受影响位流 → 同步文档口径（见 `CLAUDE.md` 约定 42 / 约定 56）。
