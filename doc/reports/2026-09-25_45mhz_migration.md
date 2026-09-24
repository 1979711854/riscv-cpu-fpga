# 45 MHz 迁移执行报告（2026-09-25）

> 上游：`doc/reports/2026-09-24_teammate_45mhz.md`（分析与方案）
> 本报告记录**执行结果**：改了什么、验证到什么程度、还剩什么没做。
> 分支：`feat/pll-45mhz`

---

## 0. 结论

**迁移完成，§5 的 6 项验证过了 5 项，第 6 项（板上实测）待做。**

| # | 验证项 | 结果 |
|---|---|---|
| 1 | `run_riscv_tests.ps1` | ✅ **49 PASS / 1 FAIL / 0 TIMEOUT** —— 与迁移前逐项一致 |
| 2 | `run_coremark.ps1 -Iter 1` | ✅ **Total ticks 358,846 / total cycles 1,462,898** —— **逐位不变** |
| 3 | `run_sim.ps1 -NoWave` | ✅ 6 个测试台全过（exit 0）|
| 4 | `run_own_tests.ps1` | ✅ `exceptions` PASS、`timer_irq` PASS |
| 5 | PDS 综合布线 | ✅ **45.0005 MHz / 可达 51.5198 MHz / slack +2.812 / All Constraints Met** |
| 6 | 板上实测 | ⬜ **待做** —— 见 §4 |

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
* `ipcore/unified_mem/` + `mem_init.hex` —— 队友的半成品，工程未引用。
  **注意那是负收益方向**（单周期 BRAM 无缺失惩罚，换 IP 核不提升性能）。
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

### 4.1 ⬜ 板上实测（唯一的未完成验证）

```powershell
# 烧 pds\RV32I_1\generate_bitstream\cpu_top_board.sbit
# （md5 36d2687d…，与归档的 coremark_iter1500_pll45mhz_localboard.sbit 同一份）
powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60
```

**判据（与 27 MHz 时代不同，别搞错）**：

| | 27 MHz（已完成） | **45 MHz（待测）** |
|---|---|---|
| ITER | 820 | **1500** |
| 期望 `Total ticks` | 294,262,913 | **≈ 538,270,000**（= 1500 × 358,846）|
| 时长算法 | ÷ 27e6 = 10.898 s | **÷ 45e6 = 11.96 s** |
| 四个 CRC | `e714 / 1fd7 / 8e3a / e714` | **必须完全相同** |

**CRC 不变是本项的核心判据** —— 时钟变了、ITER 变了，程序算的还是同一件事。
若 CRC 对不上，说明 45 MHz 下某处出了问题（而不是"时钟没生效"）。

**另外两个辅助判据**：
* `led[0]`（`pll_locked`）应**常亮**。不亮 = PLL 没锁 = CPU 被一直复位。
* 串口**不乱码** = 45 MHz 分频（390）对上了。乱码优先怀疑固件是 27 MHz 那版。

跑完把日志落盘到 `doc/board/`，并更新 `doc/board/README.md` 的"待补"标记。

### 4.2 问队友：`ipcore/unified_mem` 是要做什么

他做了 Pango 双口 BRAM IP（`ipm2l_dpram_v1_9`）但**没在 `.pds` 里引用**，
还生成了无 `@` 地址格式的 `mem_init.hex`（IP 核格式）。动向不明。
**记得提醒他这是负收益方向**（见 §1），除非目的是"用真 IP 核"拿规范化加分。

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
   > 已全部更正为 **75.25 → 125.42 = +66.7%**，恰好等于纯时钟比 `45.0005 / 27`。
   > **教训**：同一段里给"CoreMark/MHz"和"×频率"两个数时，**乘一遍再落笔** ——
   > 这个错从 2026-09-21 就在文档里躺着，靠"看起来合理"是发现不了的。
   > 本次是子代理在做别的改动时顺手验算才抓到的。

5. **"得分 +66.7%"与"效率 +17.1%"是两个独立事件，不要相乘。**
   前者是提频（分子 2.787 不变，只变频率），后者是第三轮分支优化的贡献。
   `doc/paper/` 里若把它们乘起来叙述，会得到一个虚高的数。
