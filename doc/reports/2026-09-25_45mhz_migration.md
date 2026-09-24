# 45 MHz 迁移执行报告（2026-09-25）

> 上游：`doc/reports/2026-09-24_teammate_45mhz.md`（分析与方案）
> 本报告记录**执行结果**：改了什么、验证到什么程度、还剩什么没做。
> 分支：`feat/pll-45mhz`

---

## 0. 结论

**迁移完成，§5 的 6 项验证全部通过（含第 6 项板上实测）。**

| # | 验证项 | 结果 |
|---|---|---|
| 1 | `run_riscv_tests.ps1` | ✅ **49 PASS / 1 FAIL / 0 TIMEOUT** —— 与迁移前逐项一致 |
| 2 | `run_coremark.ps1 -Iter 1` | ✅ **Total ticks 358,846 / total cycles 1,462,898** —— **逐位不变** |
| 3 | `run_sim.ps1 -NoWave` | ✅ 6 个测试台全过（exit 0）|
| 4 | `run_own_tests.ps1` | ✅ `exceptions` PASS、`timer_irq` PASS |
| 5 | PDS 综合布线 | ✅ **45.0005 MHz / 可达 51.5198 MHz / slack +2.812 / All Constraints Met** |
| 6 | 板上实测 | ✅ **`Total ticks 538,285,445` → 11.9619 s / 125.40 CoreMark**；`Correct operation validated`，`seedcrc/crclist/crcmatrix/crcstate` 逐位一致 —— 见 §4.1 |

**第 2 项是本次迁移最重要的证据**：`addr_result` 属于纯组合旁路，
周期数与迁移前**逐位相同**，所以 `doc/resource_efficiency.md` 里那套
基于"每迭代 358,846 周期"的性能数字**原样成立，无需重测仿真**。

---

## 1. 实际改动的文件（与方案 §4 的偏差已标注）

| 文件 | 改动 | 与方案一致？ |
|---|---|---|
| `rtl/core/core.v` | 新增 `addr_result = alu_a + alu_b`，用于 `mem_addr_low` / `exc_tval` | ✅ |
| `rtl/top/cpu_top_board.v` | PLL 例化 + `lock` 门控复位 + **`DEBUG_LED` 参数开关** + 文件头重写 | ✅（开关按用户拍板） |
| `rtl/top/cpu_top.v` | 新增 `parameter [9:0] UART_DIV = 10'd234`，透传给 uart_tx/rx | ✅ |
| `rtl/periph/uart_tx.v` | `localparam DIV` → `parameter DIV` | ✅ |
| `rtl/periph/uart_rx.v` | 同上；`HALF` 改为 `DIV / 2`（不再硬编码 117） | ✅ |
| `scripts/coremark_port/core_portme.c` | `EE_TICKS_PER_SEC` → 45000000 | ✅ |
| `scripts/demo/addr_map.h` | `CPU_HZ` → 45000000u | ✅ |
| `pds/RV32I_1/ipcore/pll/` | 整个目录复制过来 | ✅ |
| `pds/RV32I_1/RV32I_1.pds` | 只加 `wgt_my_ips_src` 里的 pll IP 引用 | ✅ 最小改动 |
| `pds/RV32I_1/mem.hex` | ITER=1500 | ✅ 但**自己重新生成**，见 §2 |
| `scripts/build_bitstream.ps1` | 默认 `Iter` 820→1500；**按变体自动设置 `DEBUG_LED`**；文档口径 | ➕ 方案外，理由见 §3.2 |
| `pds/RV32I_1/RV32I_1.fdc` | 只加时钟说明注释（约束一个字没改） | ➕ 方案 §3 要求补注释 |

**没带的**（按方案）：
* `ipcore/unified_mem/` + `mem_init.hex` + `ip_backup/` —— 队友"加 IP 核失败"的产物
  （2026-09-25 已确认，见 §4.2），`.pds` 从未引用。本来就是**负收益方向**。
  ⛔ 别和我们自己的 `rtl/mem/unified_mem.v` 搞混 —— 那个是承重的存储器本体。
* `doc/**`、`CLAUDE.md`、`bitstreams/`、`bak_2026-09-21_ila/` —— 我们比队友新。
* 任何 PDS 构建产物。

---

## 2. `mem.hex` 没有直接抄队友的，而是自己重新生成

```powershell
scripts\run_coremark.ps1 -Iter 1500 -SkipSim
```

结果与队友那份**逐字节一致**（`diff` 无差异）。这同时是一次**工具链可复现性**的交叉验证 ——
两台的编译器/链接器产出同一个二进制，说明 ITER=1500 这个取值双方算的是同一件事。

比直接拷贝好在：来源可追溯、可重生成，不依赖队友那份目录还在不在。

---

## 3. 方案外做的两件事（都有具体理由）

### 3.1 `uart_rx.v` 的 `HALF` 参数化

队友的版本是把 `localparam HALF = 10'd117` 改成 `DIV / 2`。**这是必须的** ——
不跟着 `DIV` 走的话，45 MHz 下 `HALF` 仍取 117（应为 195），采样点会跑到
第 117 个时钟而不是位正中，接收端在 45 MHz 下会**间歇性收错字节**。
上板时这个 bug 只在"CPU 要读串口"的场景才暴露，CoreMark 跑分根本用不到接收，
所以**极易漏测** —— 记录在此以防后人"优化"回去。

### 3.2 `build_bitstream.ps1` 自动设置 `DEBUG_LED`

方案 §4 说"要切演示版得重新综合（或用 `-D` 宏）"，把这件事留给文档。
但 `build_bitstream.ps1` 的定位是**上板唯一入口**，而
`DEBUG_LED` 默认 1 会让**演示程序版的两个最低位 LED 被 `pll_locked`/`done` 占掉** ——
即"用唯一入口生成演示版"必然产出一个 LED 映射不对的比特流。这与该脚本
当初被写出来要防的坑（烧错固件）**属同一类**，所以直接在脚本里解决：

* coremark → `DEBUG_LED=1`；demo → `DEBUG_LED=0`
* 改的是 `cpu_top_board.v` 里的**参数默认值**（PDS 命令行传不了 `-D` 宏），
  用 `try/finally` 保证**任何退出路径都还原**，实测 `exit` 也会走 `finally`
* 用 `[System.IO.File]::WriteAllText` + no-BOM UTF8 ——
  **PowerShell 5.1 的 `Set-Content -Encoding utf8` 会写 BOM**，那会给 `.v` 文件
  开头插三个字节
* 还原正确性已实测：跑完 `demo -NoBuild` 后该文件与运行前**逐字节相同**

---

## 4. 待办

### 4.1 ✅ 板上实测（2026-09-25 已完成）

```powershell
# 烧 pds\RV32I_1\generate_bitstream\cpu_top_board.sbit
# （md5 36d2687d…，与归档的 coremark_iter1500_pll45mhz_localboard.sbit 同一份）
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60
```

**实测结果**（原始日志 `doc/board/uart_20260925_005201.txt`，30 秒内跑了 2 轮、
`Total ticks` 两轮**逐位相同**）：

```
Total ticks      : 538285445
Total time (secs): 11            ← 整数截断，实际 11.9619 s
Iterations/Sec   : 136           ← 废数（= 1500/11），实际 125.40
Iterations       : 1500
seedcrc 0xe9f5 | crclist 0xe714 | crcmatrix 0x1fd7 | crcstate 0x8e3a
crcfinal         : 0x25b5
Correct operation validated.
```

| 指标 | 值 |
|---|---|
| 板上时长 | 538,285,445 ÷ **45,000,000** = **11.9619 s**（满足赛题 ≥10s）|
| 每迭代周期 | 538,285,445 ÷ 1500 = **358,857** |
| 板上得分 | 1500 ÷ 11.9619 = **125.40 CoreMark** |
| CoreMark/MHz | **2.787**（与仿真一致）|
| 对比 27 MHz 板上实测（ITER=820，`294262913`，75.24 CoreMark）| **+66.7%** |

**判据对照（与 27 MHz 时代不同，别搞错）**：

| | 27 MHz（已实测） | **45 MHz（已实测）** |
|---|---|---|
| ITER | 820 | **1500** |
| 期望 `Total ticks` | 294,262,913 | 期望 ≈ 538,270,000，**实测 538,285,445** |
| 时长算法 | ÷ 27e6 = 10.898 s | **÷ 45e6 = 11.9619 s** |
| 四个子 CRC | `e9f5 / e714 / 1fd7 / 8e3a` | **完全相同** ✅ |

**CRC 不变是本项的核心判据** —— 时钟变了、ITER 变了，程序算的还是同一件事。
若 CRC 对不上，说明 45 MHz 下某处出了问题（而不是"时钟没生效"）。

> ⚠️ **CRC 判据口径更正（此前措辞不严）**：判据是
> **`seedcrc` / `crclist` / `crcmatrix` / `crcstate` 四个逐位一致** —— 它们跨 ITER、跨时钟不变。
> **`crcfinal` 不能拿来比对** ❌。读 CoreMark 源码（`third_party/coremark/core_main.c` 的
> `iterate()`）可确认：`res->crc = crcu16(crc, res->crc)` 是**跨迭代累加**的
> （子 CRC 只在第 0 轮快照），所以它**随 ITER 变** ——
> **ITER=1 → `0xe714`、ITER=820 → `0xbd59`、ITER=1500 → `0x25b5`，三个都正确**。

**另外两个辅助判据也都通过**：
* `led[0]`（`pll_locked`）**常亮** —— PLL 已锁定（否则 CPU 被一直复位）。
* 串口**不乱码** —— 45 MHz 分频（390）对上了（否则优先怀疑固件是 27 MHz 那版）。

日志已落盘到 `doc/board/uart_20260925_005201.txt`，`doc/board/README.md` 的"待补"标记已更新。

> ⭐ **最重要的新事实**：每迭代周期在两个时钟下**逐位相同** ——
> 27 MHz 板上 358,857、45 MHz 板上 358,857，仿真 358,846。
> **时钟翻倍而周期数不变**，直接证明了"周期数与时钟无关"，
> 也是"仿真数据可外推到板上"的依据。

### 4.2 ✅ 已解决：`ipcore/unified_mem` 是"加 IP 核失败"的产物，**已删除**

**队友 2026-09-25 确认**：那是他用 IP Compiler 加 Pango 双口 BRAM
（`ipm2l_dpram_v1_9`）**没成功**留下的东西，`.pds` 从未引用过，**可以删**。
✅ **已按此删除**（2026-09-25，用户确认）。

涉及三处，**都只在队友桌面那份导出目录里，我们仓库本来就没有**
（迁移时按 §1 故意没带）：

| 路径（队友那份，均已删除） | 大小 | 说明 |
|---|---|---|
| `pds/RV32I_1/ipcore/unified_mem/` | 1.9 M | 36 个文件：IP 生成物 + `rev_1/` 构建产物 |
| `pds/RV32I_1/mem_init.hex` | 12 K | 无 `@` 地址的 IP 核格式初值 |
| `pds/RV32I_1/ip_backup/` | 104 K | 时间戳备份目录 `20260924182640` |

删除后核对：`ipcore/` 下只剩 `pll/`（**那是承重的，别一起删**）；
该目录已无任何 `unified_mem*` / `ipm2l_dpram*` 残留。
**我们仓库全程零改动**（`rtl/mem/unified_mem.v` 完好、`.pds` 引用未变、设计仍可完整 elaborate）。

> 顺带一句仍然成立：即便做成了也是**负收益方向** —— 我们的存储器是行为级
> 单周期 BRAM，访存恒 1 拍、**无缺失惩罚**，换成真 IP 核不提升性能。
> 除非动机是"用真 IP 核"拿规范化加分，否则不值得做。

> ⛔ **名字撞车警告（转述时务必带上路径）**：
> 我们**自己的** `rtl/mem/unified_mem.v` 是**统一存储器本体，承重，绝不能删** ——
> 删了整个 CPU 没有存储器，`.pds` 直接编译不过。
> 队友说的"那个可以删"**只指 `pds/.../ipcore/unified_mem/`**。
> 两处同名，一句"把 unified_mem 删掉"足以毁掉设计。已同时写进 CLAUDE.md 关键约定 28。

### 4.3 远程 FPGA 平台回退路径

远程平台没有 PLL，仍是 27 MHz。回那边要改回
`EE_TICKS_PER_SEC` / `CPU_HZ` = 27e6、`UART_DIV` 不传参数（默认 234）、ITER 按 270e6 算。
三个地方**都要改**，漏一个就得到错误的秒数或乱码。

---

## 5. 附带发现（本次核实，与迁移无关）

1. **CLAUDE.md 里"`ma_data` FAIL 的 testnum 是 1"是错的。**
   实测（迁移前后的 RTL 各跑一遍）**都是 `testnum 668`**。
   判回归时**只认 49/1/0 这个组合**，不要对 testnum。已在 CLAUDE.md 标注勘误。
2. **`tb_alu_inst.v` 打印的 DIV/REM 结果是错的**（`-20/6` 显示 -14）。
   但它是**只打印、无断言**的冒烟测试，且直接例化 `alu`（`alu.v` 未实现
   op 14–17，DIV/REM 在 `core.v` 里走 `divider.v`，由 `tb_alu_div` 覆盖且通过）。
   **属既有现象，非本次引入**：`alu.v` / `divider.v` 本次未改动。
   记录以免后人误判为回归。
3. **`pds/README.md` 里 CoreMark 的 `Total ticks 294,888,440` 与其他文档的
   294,262,913 对不上。** 核对结论：**不是笔误，是两个不同时代的真实数** ——
   `770 × 382,972 = 294,888,440`，对应"取指重定向后、第三轮优化前"那次的
   ITER=770 实测；而 `294,262,913 = 820 × 358,857` 是第三轮之后 ITER=820 的实测。
   真正错的是同一个小标题写的"ITER=820"。已在 `pds/README.md` 按"推测 + 待核"措辞标注，
   **原数保留不抹**。

4. ⭐ **`doc/resource_efficiency.md` 里 `2.787 × 27 ≈ 70.50` 是算错的** ——
   即本节开头那个错误的源头。`2.787 × 27 = 75.25`；**70.50 实际等于 `2.611 × 27`**，
   而 2.611 是**第二轮优化后、第三轮之前**的效率，与 2.787 不是同一版设计。
   同一处原文的 `2.787 × 47.8126 ≈ 124.84` 犯了同样的错（124.84 = 2.611 × 47.81）。
   > **本次迁移一度把这个错抄进了多处文档**（写成"实际得分 70.50 → 125.42，+77.9%"）。
   > 已全部更正为 **75.25 → 125.42（推算）= +66.7%**，恰好等于纯时钟比 `45.0005 / 27`
   > （板上实测得分 **125.40**，见 §4.1 —— 与推算值差 0.02%）。
   > **教训**：同一段里给"CoreMark/MHz"和"×频率"两个数时，**乘一遍再落笔** ——
   > 这个错从 2026-09-21 就在文档里躺着，靠"看起来合理"是发现不了的。
   > 本次是子代理在做别的改动时顺手验算才抓到的。

5. **"得分 +66.7%"与"效率 +17.1%"是两个独立事件，不要相乘。**
   前者是提频（分子 2.787 不变，只变频率），后者是第三轮分支优化的贡献。
   `doc/paper/` 里若把它们乘起来叙述，会得到一个虚高的数。
