# riscv-tests 回归报告（RV32IM 五级流水线 CPU）

最近更新：2026-09-25（2026-10-06 补**顺序双发射**口径；2026-10-12 补核心口径；**2026-10-13 补 A1 乘法器 II=1**：双发射 + 任务C `EARLY_LD` + A1 **232,345 拍/迭代 → 4.304 CoreMark/MHz**、**ITER=4280，板上实测 365.93 分**（位流 `bcd8fdd2`，日志 `doc/board/uart_20261013_184111.txt`）；**A1 前**板上实测为 241,633 → 351.86 分（@85.0051MHz，ITER=4116）、I+D Cache 版 243,933 → 313.63（@76.5052MHz，ITER=3668），A1 后 I+D 仿真 235,628。本文「附」CoreMark 小节内的 270.82/313,876 等为 2026-10-06 历史口径；回归基线四条并列见文末）
方法：不改 CPU、不改 riscv-tests 仓库；`scripts/elf2mem.py` 把 ELF 拆成
     `imem.hex` / `dmem.hex`（另出合并的 `mem.hex`），`sim/tb_riscv.v` 监控
     core 对 tohost 的 store，判定 PASS / FAIL / TIMEOUT。

运行方式：

```powershell
# 直接跑即可 —— 会自动用仓库里随附的基线 ELF（third_party/riscv-tests-elf/）
scripts\run_riscv_tests.ps1

# 有 riscv-tests 源码（clone 到 third_party/riscv-tests）时会改为从源码编译
# 也可以用 -ElfDir 显式指定一批 ELF
scripts\run_riscv_tests.ps1 -ElfDir third_party\riscv-tests-elf
```

> 那 50 个基线 ELF 是**有意入库**的：上游 riscv-tests 会变（例如 `fence_i` 的
> 自修改目标在不同版本里放在 `.text` 还是 `.data` 不一样），重新 clone 未必复现
> 同一批二进制，基线漂移会让人误判成自己改坏了 CPU。来源与再生成方式见
> `third_party/riscv-tests-elf/README.md`。

## 当前结果：49 PASS / 1 FAIL / 0 TIMEOUT（共 50）

| 分类 | 数量 | 测试 |
|------|------|------|
| PASS（rv32ui） | 42 | add addi and andi auipc beq bge bgeu blt bltu bne **fence_i** jal jalr lb lbu ld_st lh lhu lui lw **ma_data** or ori sb sh simple sll slli slt slti sltiu sltu sra srai srl srli st_ld sub sw xor xori |
| PASS（rv32um） | 8 | **div divu mul mulh mulhsu mulhu rem remu** |
| FAIL | 1 | `ma_data`（未对齐访存，testnum 668；规范允许不支持的架构取舍，见 §1） |
| TIMEOUT | 0 | —— |

> **rv32um 这 8 项是 2026-09-15 补上的。** 本 CPU 实现了 M 扩展、CoreMark 也是用
> `-march=rv32im` 编译的，但此前回归只覆盖 rv32ui，M 扩展只有手写的 `tb_alu_div`
> 在撑。补进官方测试后 8 项全部一次通过，M 扩展自此有了 riscv-tests 背书。

---

## 1. ma_data —— 唯一的 FAIL，架构取舍（2026-09-21 复核更正）

`ma_data` 测试未对齐访问（`lh/lhu/lw` 从 `+1/+2/+3` 地址读）。本 CPU 只支持对齐访问：

- `mem_addr[14:2]` 直接丢掉低 2 位，按字地址取整
- `lh` 的 `load_half = addr_low[1] ? load_src[31:16] : load_src[15:0]`
  **只对偶地址正确**。测试在 `0x2001` 做 `lh`（半字跨字节边界），
  `addr_low = 1` → `addr_low[1] = 0` → 取字节 0-1，而实际要的是字节 1-2 → 取错
- `lw` 从未对齐地址会跨字，无法重拼

**RISC-V 规范允许实现不处理未对齐访问（§2.6 明确列为可选）**，所以这项 FAIL
判定为"架构取舍、预期失败"。失败是**确定性**的，**testnum 恒为 668**
（2026-09-25 二次勘误：迁移前（HEAD）与迁移后两份 RTL 各跑一遍都是 668，
见下；判回归只认 49/1/0 这个组合，别去对 testnum）。

> [!] **勘误（2026-09-21）**：本报告曾有一个版本写着"取指重定向改造后 `ma_data`
> 自动转为 PASS，说明它此前更可能是冲刷路径上的潜在 bug"——**该结论无法复现，
> 现已撤回。** 复核方式：
>
> 1. 用取指重定向【之前】的 RTL（`git show 9616ab5:rtl/core/core.v`）单独跑
>    `ma_data` → 同样 **FAIL (testnum 1)**
> 2. 改造【之后】单独跑两次 → **FAIL (testnum 1)**，确定性复现
> 3. `third_party/riscv-tests-elf/` 的 50 个 ELF 全部通过 `sha256sum -c`，
>    且仓库内不存在 riscv-tests 源码 → 两次测量用的是**同一批二进制**，
>    不存在"重新编译出不同 ma_data"的可能
>
> 且从代码即可确证：那次改造只碰了取指重定向路径，**完全没有动 load/store 的
> 字节抽取逻辑**，物理上不可能改变未对齐访存的结果。原文"架构取舍"的归因是对的。
>
> 仍需诚实记录：**未对齐通路没有专门测试覆盖**，`ma_data` 是唯一的哨兵，
> 不对外承诺这个能力。
>
> [!] **二次勘误（2026-09-25）**：上面复核查到的 `testnum` 也记错了 —— 实测**不是 1**。
> 用迁移前（HEAD）和迁移后两份 RTL 各跑一遍，**都是 `testnum 668`**，与
> `addr_result` 那类改动无关。所以本报告与 `doc/base_task_status.md`、`doc/spec.md`
> 里的 testnum 一律以 **668** 为准；**判回归只认 49/1/0 这个组合**，别去对 testnum。

## 2. fence_i —— 已由 TIMEOUT 转为 PASS（2026-09-15）

### 这个测试在测什么

反汇编 `fence_i.elf` 可以看清它是**自修改代码**测试：

```
1c0: auipc t0,0x0
1c4: sh    a0,188(t0)   # 把一条新指令写进代码区 0x27c
1cc: sh    a1,182(t0)   # 接着写 0x27e
1d0: fence.i            # 要求 store 对取指可见
1dc: jalr  t1,a5        # 跳到 0x27c 执行刚写进去的指令
```

### 原来为什么挂死

原设计是**哈佛结构**：`imem` 与 `bram` 是两块独立的 BRAM，store 只写 dmem、
取指只读 imem。写进"代码区"的指令永远进不了取指通路，于是：
`fence.i` 就算是 NOP 也没用，`jalr` 跳到 0x27c 后执行到的仍是旧指令，
测试在 fail 自旋里跑死（实测 TIMEOUT at pc=0x288，全程未写 tohost）。

**结论：这不是"少实现一条指令"，是存储器结构决定的。**

### 怎么修好的

把 `imem` + `bram` 合并成**一块统一的双端口 BRAM**（`rtl/mem/unified_mem.v`）：

- A 口只读、同步读 1 拍 —— 供取指
- B 口读写、按字节写、同步读 1 拍 —— 供访存

于是 store 写进去的数据，后续取指天然能读到，`fence.i` 实现为 NOP 即满足语义
（RISC-V 规范允许无 Cache 的实现把 `FENCE`/`FENCE.I` 视作 NOP）。

这同时落地了 `doc/spec.md` 早先写下的 **modified-Harvard** 路线：软件看到统一
地址空间，核内部取指/访存通路仍然分离（为后续 I/D Cache 留出干净的后备存储）。

**关键证据：整个回归里，fence_i 是唯一发生变化的一项，其余 40 项逐项一致；
CoreMark 周期数也一字不差。** 说明这次改动没有引入任何时序副作用。

### 残留限制（诚实记录）

如果软件改写**自己取指窗口内**的指令（恰好是 store 之后第 3 条，即 `pc_r` 正好
指向它），那一拍发出的取指可能已读到旧值并在下一拍进 IF/ID，`fence.i` 也救不回来
（指令已在流水线里）。这与有没有统一存储器无关，是"没有 I-Cache / 取指缓冲"的
简单核的固有性质，riscv-tests 未覆盖这种极端情况。

## 3. 历史记录：曾被误判为"CPU bug"的几项

2026-09-10 的一份中间报告（`riscv32-FPGA-pds/riscv-tests-run/FAILURES.md`）记录过
`sb/sh/sw` FAIL、`ld_st` TIMEOUT，并归因为"取指在 stall 期间重复取指导致指令被复制
执行"。**那两个问题早已被队友修掉，该文档已过时。** 当前设计里：

- `pc_r` 在 stall 时是**保持不动**（不是后退到 `if_id_pc+4`）；
- `imem_addr` 的 mux 在 stall 时退回 `if_addr_d[14:2]`（重读同一 word），
  使 `if_id` 在 stall 结束那拍拿到 (pc, 指令) 同址的一对；
- 跳转时 `ex_flush` **只清 IF/ID 一拍**，同时把目标地址**同拍**旁路给取指端
  （`imem_addr` 的 mux 取 `ex_target`），使目标指令早 1 拍进 IF/ID —— 惩罚 2 拍。
  （旧设计另有 `ex_flush_d` 做第二道冲刷、惩罚 3 拍；2026-09-21 已随取指重定向一并移除）

这三点是承重逻辑，改动前务必读 `rtl/core/core.v` 里 PC 段的注释。**注意：是
`imem_addr` 后退，不是 `pc_r` 后退** —— 照字面把 `pc_r` 也往后推会复现那个
"指令被复制执行"的老 bug。

---

## 附：CoreMark 与板上验证

> [!] **当前仿真口径（2026-10-13 A1）**：**85.0051 MHz 顺序双发射 + 任务C `EARLY_LD` + A1 乘法器 II=1**，
> 每迭代 **232,345** 拍 → **4.304 CoreMark/MHz**、**ITER=4280，板上实测 365.93 分**。
> **[历史] A1 前那一代板上实测（2026-10-11/12）**：ITER=4116、每迭代 **241,633** 拍（板上 241,584）
> → **351.86 CoreMark**（位流 `2ddaf32f` / `2f7a4d0a`，日志 `doc/board/uart_20261011_225624.txt` / `uart_20261012_002541.txt`）。
> **I+D Cache 版**：76.5052 MHz / ITER=3668 → **313.63 分**（`c6b12d95`，`RTL=0x20261016`，**A1 前口径**）。
> 下面这一节是 **2026-10-06 那一代**的原始记录 —— 读的时候按【当时那一代】理解，别当当前值。

### 板上实测结果（本地盘古板，85.0051 MHz，ITER=3170）—— 2026-10-06 那一代（**已被任务C `EARLY_LD` 取代**）

```
CoreMark Size    : 666
Total ticks      : 994988178
Total time (secs): 11            ← 整数截断，实际 11.7050 s
Iterations/Sec   : 288           ← 废数（= 3170/11），实际 270.82
Iterations       : 3170
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : （随 ITER 变，不比）
Correct operation validated. See README.md for run and reporting rules.
```

- **994,988,178 ÷ 85,005,100 = 11.7050 秒** [OK] 满足赛题 ≥10s → **270.82 CoreMark**（= 3170 ÷ 11.7050）
- 每迭代 **313,876** 周期（994,988,178 ÷ 3170）—— 与仿真 313,886 差 **−0.003%**
- `seedcrc / crclist / crcmatrix / crcstate` 与仿真**逐位一致**
- 位流 md5 `5c4893de`，原始日志：`doc/board/uart_20261006_162410.txt`

> [!] **那一代的默认配置是顺序双发射**（`rtl/top/cpu_top.v` 的 `parameter DUAL_ISSUE = 1`，2026-10-06；
> 当前配置在这之上还多了任务C 的 **`EARLY_LD = 1`**）。
> 上一代（**单发射**、85.0051 MHz、ITER=2740）是 **233.85 CoreMark**（363,509 拍/迭代，位流 md5 `ae4deea9`，
> 日志 `doc/board/uart_20261004_114730.txt`），保留为**可回退版**（`build_bitstream.ps1 -Single`）。
> 双发射改的是**效率**（2.751 → 3.186，+15.8%），**时钟没动**；代价是 Fmax 91.40 → 87.00、
> LUT 4,377 → 6,909（同构建 DUAL=0/1 口径）、**CoreMark/LUTs 0.0534 → 0.0392** —— 赛题三项指标 **1 升 2 降**。

### 板上实测结果（远程 FPGA 平台，27MHz，ITER=700）—— 取指重定向改造【前】的设计

```
CoreMark Size    : 666
Total ticks      : 294065438
Total time (secs): 10
Iterations/Sec   : 70
Iterations       : 700
seedcrc          : 0xe9f5 [OK] 与仿真一致
[0]crclist       : 0xe714 [OK]
[0]crcmatrix     : 0x1fd7 [OK]
[0]crcstate      : 0x8e3a [OK]
[0]crcfinal      : 0x65c5        （随迭代次数变化，与仿真不同属正常）
Correct operation validated. See README.md for run and reporting rules.
```

- **实际时长 = 294,065,438 ÷ 27MHz = 10.89 秒** [OK] 满足赛题 ≥10s
  （`Total time (secs): 10` 是整数截断；`Iterations/Sec: 70` = 700 ÷ 10 也是按截断后的 10 算的）
- **`Correct operation validated`** = CoreMark 自己判定 CRC 全部通过
- `seedcrc` / `crclist` / `crcmatrix` / `crcstate` 与仿真**逐位一致** → **CPU 在真实硬件上算得对的最强证据**
  （[!] **`crcfinal` 不比** —— 它跨迭代累加、随 ITER 变：ITER=700 → `0x65c5`、ITER=820 → `0xbd59`、ITER=1500 → `0x25b5`、ITER=1663 → `0x81c9`）

### 板上实测结果（本地盘古板，49.8927 MHz，ITER=1663）—— 历史（**单发射**，BHT 之后，2026-09-25）

```
CoreMark Size    : 666
Total ticks      : 588890651
Total time (secs): 11            ← 整数截断，实际 11.8031 s
Iterations/Sec   : 151           ← 废数（= 1663/11），实际 140.89
Iterations       : 1663
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x81c9        （随 ITER 变，不比）
Correct operation validated. See README.md for run and reporting rules.
```

- **588,890,651 ÷ 49,892,700 = 11.8031 秒** [OK] 满足赛题 ≥10s → **140.89 CoreMark**（= 1663 ÷ 11.8031）
- 每迭代 **354,113** 周期（588,890,651 ÷ 1663）—— 与仿真 354,119 差 **−0.0016%**（板上略快）
- `seedcrc / crclist / crcmatrix / crcstate` 与仿真**逐位一致**
- 原始日志：`doc/board/uart_20260925_172318.txt`（30 秒内跑了 2 轮，`Total ticks` 逐位相同）

### 板上实测结果（本地盘古板，45 MHz，ITER=1500）—— 历史（2026-09-25 上午）

```
CoreMark Size    : 666
Total ticks      : 538285445
Total time (secs): 11            ← 整数截断，实际 11.9619 s
Iterations/Sec   : 136           ← 废数（= 1500/11），实际 125.40
Iterations       : 1500
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x25b5        （随 ITER 变，不比）
Correct operation validated. See README.md for run and reporting rules.
```

- **538,285,445 ÷ 45 MHz = 11.9619 秒** [OK] 满足赛题 ≥10s → **125.40 CoreMark**（= 1500 ÷ 11.9619）
- 每迭代 **358,857** 周期（538,285,445 ÷ 1500）—— **与 27 MHz 板上实测逐位相同**
  （时钟翻倍而周期数不变 → 证明周期数与时钟无关，仿真数据可外推到板上）
- `seedcrc / crclist / crcmatrix / crcstate` 与仿真**逐位一致**
- 原始日志：`doc/board/uart_20260925_005201.txt`（30 秒内跑了 2 轮，`Total ticks` 逐位相同）

### 每迭代周期数怎么算（别踩这个坑）

板上两次实测一解方程，口径完全自洽：

```
ITER=200 → Total ticks  84,018,579 / 200 = 420,093 周期/迭代   ← 改造前设计
ITER=700 → Total ticks 294,065,438 / 700 = 420,094 周期/迭代   ← 改造前设计
仿真（ITER=1，改造前）                    420,070 周期/迭代
仿真（ITER=1，BHT 之前）                  358,846 周期/迭代   ← 历史（ID 级静态预测时代）
仿真（ITER=1，单发射，BHT 之后）          354,119 周期/迭代
仿真（ITER=1，单发射，两拍乘法器后）      363,515 周期/迭代
仿真（ITER=1，双发射）                    313,886 周期/迭代
仿真（ITER=1，双发射 + 阶段0/1）           262,018 周期/迭代
仿真（ITER=1，双发射 + `EARLY_LD`）       241,633 周期/迭代   ← A1 前
仿真（ITER=1，双发射 + `EARLY_LD` + A1）   232,345 周期/迭代   ← **当前默认（= 板上口径）**
仿真（ITER=1，+ `DCACHE` + `ICACHE` + `EARLY_LD`）  243,933 周期/迭代   ← I+D Cache 版（A1 前）
仿真（ITER=1，双发射 + A1 + `DCACHE` + `ICACHE` + `EARLY_LD`）  235,628 周期/迭代   ← I+D Cache 版（A1 后）
```

**改造前真机与仿真只差 0.0057%** → 仿真模型可信，仿真数据可以放心写进报告。
**改造前 CoreMark/MHz = 1,000,000 / 420,094 ≈ 2.38**
**当前设计（双发射 + 任务C `EARLY_LD` + A1）= 1,000,000 / 232,345 ≈ 4.304**；
**I+D Cache 版（A1 后）= 1,000,000 / 235,628 ≈ 4.244**（A1 前：4.139 / 241,633、I+D 4.099 / 243,933）；
历史：双发射 313,886 → 3.186；单发射（两拍乘法器后）363,515 → 2.751（BHT 之后 354,119 → 2.824）

> 历史（2026-09-21 那轮）：仿真的 420,070（改造前）与 382,972（改造后）都是当时用 `+PROF`
> 直接读 CoreMark 的 `Total ticks` 得到的。逐拍 trace 复核：`stop_time` 的读指令
> （PC `0x2920` 的 `lw a5,0(a5)`，读 MMIO `0x7FF4`）在第 **402,182** 拍进入 MEM 级；
> 区间的**长度** 358,846 拍与 CoreMark 自报的 `Total ticks` 逐位一致。
> （起点在本次 trace 窗口之前，未实测，所以这里不给起点值。）
> 此前的文档写「仿真 ≈ 420,414」，该值无法复现，已更正。
> 注意 2026-09-21 那次改造前后 `ITER=1` 的测试台总周期不是同一个值（1,529,499 → 1,488,333）——
> 因为改造的目的就是减少周期数；但区域内提交指令数、停顿数、前递数、访存数
> **完全相同**，说明只改了时序、没改行为。

> [!] **别用 ITER=1 的测试台总周期（单发射 1,457,776）当"每迭代成本"。** 那是**仿真
> 测试台**的总周期，含约 108 万周期的一次性 UART 打印开销；而 CoreMark 自己的
> `Total ticks` 计时在打印**之前**就停了、**不含**打印。两个口径不同，混用会把
> 迭代成本算错。
>
> 本项目就踩过：据此写成"ITER≈200 约 10s"，实测只有 **3.11s**，被 CoreMark 判 invalid。

### 迭代次数的选取

**当前设计（双发射 + 任务C `EARLY_LD` + A1）每迭代 232,345 周期**
（A1 前 241,633；`EARLY_LD=0` 是 252,730；单发射 303,140；**I+D Cache 版（A1 后）是 235,628**）。
ITER 的分子是**你往哪儿烧**的那个时钟频率：

```
本地盘古板（85.0051MHz，双发射+EARLY_LD+A1）: 850,051,000 / 232,345 ≈ 3659 → 取 ITER=4280（11.70s，余量 17%）
                                                     → **板上实测 365.93 分**
【A1 前已板上实测】ITER=4116 → 11.69797 s / 351.86 CoreMark
I+D Cache 版（76.5052MHz，A1 前口径 243,933）: 765,052,000 / 243,933 ≈ 3135 → 取 ITER=3668（11.70s）
                                                     → **已板上实测 11.6952 s / 313.63 CoreMark**（A1 后仿真 235,628，未上板）
```
历史（**双发射**）：85.0051MHz → ITER=3170（994,988,178 → 11.7050 s / 270.82）；
（**单发射**）：85.0051MHz → ITER=2740（996,015,474 → 11.7171 s / 233.85）；
49.8927MHz → ITER=1663（588,890,651 → 11.8031 s / 140.89）。

> [!] **改了流水线、或换了平台时钟，都必须重算这个数。**
> 三条独立的历史教训：
> ① 旧设计 420,094 周期/迭代时用 700 正合适（10.89s）；降到 358,846 后
> **ITER=700 只剩 9.93s，会被判 invalid**。
> ② 2026-09-25 板上时钟 27→45 MHz 后，**原来正好的 ITER=820 只剩 6.54s**，
> 同样 invalid —— 周期数一个字没变，**是分母变了**。
> ③ 同一天再提到 49.8927 MHz 后，45 MHz 时代的 **ITER=1500 只剩 10.65s**
> （1500 × 354,119 ÷ 49,892,700），余量掉到 6.5% → 重取 **ITER=1663**。
> ④ 再往后 49.89 → 62.03 → 85.0051 MHz，单发射 ITER 一路重取 1663 → 2000 → **2740**。
> ⑤ 2026-10-06 加**顺序双发射**后，每迭代从 363,515 掉到 **313,886**，**ITER 又得重算** → **3170**。
> 每次动流水线后先跑 `run_coremark.ps1 -Iter 1` 读 `Total ticks`，再按平台时钟定 ITER。

### 平台注意事项

- 远程平台偶发 **"固件下载完成但设备唤醒失败"** → **多烧录几次即可**，与设计无关
- 综合前必须把 `mem.hex` 放进 PDS 工程目录（`scripts\sync_firmware.ps1`）。
  缺失时 PDS 只报 `Cannot open specified data file "mem.hex"` 然后**照常生成比特流**，
  但 BRAM 是空的 —— 板上什么都不会跑，且没有任何其他报错
- [!] **同一类坑的第二种形态：文件在，但内容过期。** PDS 综合读的是
  `pds\RV32I_1\mem.hex`，**不是** `sim\programs\mem.hex`，而且从不检查时间戳。
  跑过 `run_demo.ps1` / `run_riscv_tests.ps1` 之后再 `sync_firmware.ps1`，
  工程里就留下 demo / riscv-test 的镜像；此后无论怎么改 RTL、重新综合布线，
  **板上跑的都还是那个旧程序**，PDS 全程零报错（2026-09-21 实踩）。
  判据：看 `pds.log` 里的 `Loading memory data from file ... mem.hex`，
  再核对 `mem.hex` 字数与 ELF 的 `.text` 规模是否相当（CoreMark = **8,552 字**）。
- 日志里的 `SCBV has not been set` 是配置 bank 电压的提醒，**实测不影响上板运行**

---

## 回归纪律

每次改动 RTL 后，以下两条必须同时满足：

1. **本报告的 49/1/0 逐项不变**（除非本次改动的目的就是改变某一项）
2. **CoreMark 计时区间**（`+PROF` 读到的 `Total ticks`）**一字不差**

**四条基线（2026-10-13 A1 之后，都很灵敏，别混口径）**：

| 配置 | 怎么跑 | 每迭代 | 判据 |
|---|---|---|---|
| 双发射 + `EARLY_LD`（**默认 = 板上口径**）| `run_riscv_tests.ps1` / `run_coremark.ps1` | **232,345**（A1 前 241,633）| 49/1/0 |
| 单发射 | 加 `-Single` | **303,140**（A1 前 312,428）| 49/1/0 |
| 双发射 + `EARLY_LD=0` | （不传 `-EarlyLd`）| **252,730**（A1 前 262,018）| 49/1/0 |
| **带 Cache** | 加 **`-DCache -ICache -EarlyLd`** | **235,628**（A1 前 243,933）| 49/1/0 |

CRC 一律 `crclist=0xe714 crcmatrix=0x1fd7 crcstate=0x8e3a`（`crcfinal` 随 ITER 变，**不比**）。

> [!] **验 Cache / 任务C 时必须显式写全开关，并核对 vvp 首行 `SIM CONFIG:`** ——
> 默认四条回归都是 `EARLY_LD=0`，**盖不住 `EARLY_LD=1` 的 corner**
> （2026-10-12 那个"I+D 上板只有 banner 循环"的 bug 就躲过了全部默认回归）。

第 2 条是"没有碰坏流水线"最灵敏的探针 —— 多一个停顿、少一次前递都会让它变。

> 历史基线（单发射口径）：420,070（改造前）→ 382,972（2026-09-21 取指重定向）
> → 358,846（静态预测 + jal）→ 354,119（2026-09-25 BHT）→ 363,515（2026-09-28 两拍乘法器）
> → 313,886（2026-10-06 顺序双发射）→ `241,633`（2026-10-11 阶段0/1 + 任务C `EARLY_LD`）→ **232,345（2026-10-13 A1 乘法器 II=1，当前）**。
> 数值变只有一种合法理由：**本次改动的目的就是改变它**。
