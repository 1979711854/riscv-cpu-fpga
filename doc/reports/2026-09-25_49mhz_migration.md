# 49.89 MHz 迁移执行报告（2026-09-25）

> 上游：`doc/reports/2026-09-25_next_steps_handoff.md` §3（任务② 主频 45 → 49.89 MHz）
> 基线：`doc/reports/2026-09-25_45mhz_migration.md`（45 MHz 迁移，已上板闭环）
> 本报告记录 49.89 MHz 提频**改了什么、验证到什么程度、还剩什么没做**。

---

## 0. 结论

**提频改动全部完成，仿真验证通过，还剩「上板验证」一项未做。**

| 状态 | 项 |
|---|---|
| [OK] | PLL 改到 49.89 MHz，综合 `All Constraints Met`（实际 **49.8927 MHz**，slack **+1.550 ns**）|
| [OK] | 5 处连带改动全部完成（见 §1）|
| [OK] | CoreMark 仿真：周期数 **354,119 不变**，CRC 四子项逐位一致 |
| [OK] | riscv-tests 回归 **49 PASS / 1 FAIL / 0 TIMEOUT**（见 §4.2）|
| [待办] | 上板验证：串口不乱码 + 实际跑分（见 §5）|

> [重点] **本报告在 2026-09-25 迁移进主仓库时做过一次复核，改了三处**（原报告的问题）：
> 1. **§3 的 slack / 可达频率引的是旧一次综合** —— 原写 `+1.995 ns / 55.4078 MHz`，
>    那两个数来自 **12:29** 那次综合（现躺在 `report_timing/bak/`）；
>    随交付的是 **13:14** 那次，实际是 **`+1.550 ns / 54.0745 MHz`**。已更正。
> 2. **原报告没有写 riscv-tests 结果** —— 实际跑过且通过（见 §4.2），已补。
> 3. **原交付的比特流里装的是 ITER=1500 固件，不是 1663** —— 见 §5.1，已修。

---

## 1. 改动清单（5 处）

| # | 文件 | 改动 | 45 MHz | → 49.89 MHz |
|---|---|---|---|---|
| 1 | `pds/RV32I_1/ipcore/pll/` | CLKOUT0 输出频率（**IP Compiler GUI 改**）| 45.0 | 49.89 |
| 2 | `rtl/top/cpu_top_board.v` | `.UART_DIV` | 390 | **433** |
| 3 | `scripts/coremark_port/core_portme.c` | `EE_TICKS_PER_SEC` | 45000000 | **49892700** |
| 4 | `scripts/demo/addr_map.h` | `CPU_HZ` | 45000000u | **49892700u** |
| 5 | `scripts/build_bitstream.ps1` | 默认 `Iter` + 注释口径 | 1500 | **1663** |

> [!] 第 1 项是在 PDS 的 IP Compiler GUI 里改 `CLKOUT0_REQ_FREQ` 后重新生成的，
> `.v` 与 `.idf` 由 GUI 统一更新。没有手工改 `.v`/`.idf`（`.idf` 里存在
> `STATIC_RATIO0` 与 `STATIC_RATIO0_advancedPage` 不一致的历史残留，手改易漏）。

---

## 2. PLL 实际频率（不是标称 49.89）

PLL 结构（从 `pll.v` 反推）：

```
VCO     = 27 ÷ RATIOI(1) × RATIOM(2) × RATIOF(21.25) = 1147.5 MHz
CLKOUT0 = VCO ÷ RATIO0
```

改 `STATIC_RATIO0`：25.5 → 23，标称 `1147.5 / 23 = 49.8913 MHz`。

但 **PDS 综合后报的是 49.8927 MHz**（`report_timing/cpu_top_board.rtr` 的
`Requested Frequency` 列），与标称差 1.4 kHz。跟 45 MHz 时代「标称 45.0、PDS 报 45.0005」
是同一个现象。

**所以第 3/4/5 项填的是实际值 `49,892,700`（取整到 Hz），不是标称 49.89。**
填错不会报错，但 CoreMark 会算出错误的秒数 —— 判 valid 时按这个值卡。

---

## 3. 时序结果

来源：`pds/RV32I_1/report_timing/cpu_top_board.rtr`（本次综合）

| 项 | 45 MHz（基线）| 49.89 MHz（本次）|
|---|---|---|
| Requested Frequency | 45.0005 MHz | **49.8927 MHz** |
| Estimated Frequency | 51.5198 MHz | **54.0745 MHz** |
| Period | 22.2220 ns | 20.0430 ns |
| Slack（慢角）| +2.812 ns | **+1.550 ns** |
| 结论 | All Constraints Met | **All Constraints Met** |

余量从 +2.812 收窄到 **+1.550 ns**，仍有 1.5 ns 富余，`All Constraints Met`。
预计还有约 4.2 MHz 的提频空间（Estimated 54.07 MHz），但 49.89 是「最接近 50 且稳」的档。

> [!] **上面这两个数是 13:14 那次综合的。** 本案一共跑了两次：
> * **12:29** —— Estimated 55.4078 MHz / slack **+1.995 ns**（旧，现于 `report_timing/bak/`）
> * **13:14** —— Estimated **54.0745** MHz / slack **+1.550 ns**（**随包交付的这份**）
>
> 本报告初稿引的是 12:29 那组。两者结论相同（都 `All Constraints Met`），
> **但引用时要认准与 `.sbit` 同批的那次** —— 认批看 `multiseed_summary.csv` 的
> `Setup(Slow)` 列（权威值），或文件时间戳。

---

## 4. 仿真验证（CoreMark ITER=1）

```
Total ticks      : 354119
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
```

| 项 | 结果 |
|---|---|
| 每迭代周期 | **354,119** —— 与 BTB 后基线一致（提频不该改周期数）|
| CRC 四子项 | 逐位一致 |
| 编译 | 通过 |

> [!] 周期数基线说明：`358,846`（BTB 前）→ **354,119**（任务① BTB + BHT 后）。
> 本次 49.89 MHz 提频不碰流水线逻辑，周期数保持 354,119 不变。

> [!] 仿真不过 PLL：testbench 例化的是 `cpu_top`（27 MHz），不是上板顶层
> `cpu_top_board`。所以 `UART_DIV=433` 和「实际秒数」这两件事仿真验证不了，
> 只能上板确认（见 §5）。

## 4.2 riscv-tests 回归（**原报告漏写，迁移复核时补上**）

**判据：`49 PASS / 1 FAIL / 0 TIMEOUT`** —— 与 BTB 之前完全一致。

```
PASS=49  FAIL=1  TIMEOUT=0  OTHER=0
FAIL     ma_data   === FAIL (testnum 668) ===
```

> ⭐ **这是本次改动最关键的一条验证。** BHT 直接动的是分支预测，预测错**不应该**
> 影响正确性（EX 级冲刷会兜住）—— 所以 `riscv-tests` 一旦有任何变化，
> 就说明预测逻辑破坏了正确性，必须回退。49/1/0 保持不变 = 逻辑是对的。
>
> 那个 FAIL 是 `ma_data`，**属架构取舍**（不支持未对齐访存，会正确陷入异常），
> 与本次改动无关。**判回归只认 49/1/0 这个组合，别去对 testnum**
> （`testnum 668` 才是实测值，历史文档写过的 `1` 是错的）。

**另外两项也都通过**：`run_own_tests`（`exceptions` + `timer_irq`）、
`run_sim`（6 个单元测试台）。

## 4.3 BTB + BHT 的收益与残余空间

```
358,846（BTB 前）→ 354,119（BTB + BHT 后）   省 4,727 拍 = 1.32%
```

**低于理论上限 2.36%**（BHT 能救的 2,367 + 6,101 = 8,468 个事件），**捕获率 56%**。
原因已定位 —— **256 项表太小，别名冲突严重**（反汇编实测，`objdump -M no-aliases`）：

| BHT 配置 | 用到槽 | 冲突分支数 | 最挤的槽 |
|---|---|---|---|
| **256 项 PC[9:2]（现用）** | 192/256 | **149 / 341（44%）** | 5 个分支 |
| 1024 项 PC[11:2] | 302/1024 | 39 | 3 |
| 4096 项 PC[13:2] | 341/4096 | 0 | 1 |

两条实测最热的冲刷分支都在冲突里（`0x0d04` 实测 5,780 次、`0x0dbc` 实测 2,778 次）：
同槽两个分支各自的训练会互相覆盖对方，**两边都持续误预测**。

> **这是可优化项，不是缺陷** —— 现有实现是正确的，只是表偏小。
> 若日后想拿回那 ~1%，把表扩到 1024 或 4096 项即可（代价约 +350 LUT 或 1 块 DRM，
> 我们 DRM 只用了 16/415）。**但不要和上板验证混在一起做**，一次只动一个变量。

---

## 5. 待办：上板验证

`UART_DIV` 校验：`49,892,700 / 433 = 115,226 ≈ 115200`，误差 **+0.02%**，不会乱码。

### 5.1 [!] 原交付的比特流装错了固件（已修）

**原样交付的那份 `.sbit` 里是 `ITER=1500` 的固件，不是 1663。**

证据：
```
pds/RV32I_1/mem.hex    时间戳 01:45   ITER=1500   <- 上一版打包时留下的，从未被覆盖
sim/programs/mem.hex   时间戳 12:52   ITER=1      <- 跑仿真留下的
pds.log 确认 13:13 综合时读的就是 pds/RV32I_1/mem.hex（= 1500）
```
即：**改了 `build_bitstream.ps1` 的默认 `Iter=1663`，但没有实际跑过这条命令**，
直接进 PDS 综合了 —— 用的是工程目录里那份旧固件。

| | 预期（ITER=1663）| 原交付（ITER=1500）|
|---|---|---|
| 板上时长 | 11.80 s | **10.65 s** |
| 余量 | 18% | **6.5%** |

仍然 ≥10 s 所以判 valid，**但余量和报告对不上** —— 真上板会量出 10.65 s。

这正是 CLAUDE.md 里反复强调的坑：**PDS 从不检查 `mem.hex` 的时间戳**。

**已修**：迁移进主仓库时重跑了 `build_bitstream.ps1 coremark`，
工程里的 `mem.hex` 现在是 ITER=1663（与 `sim/programs/mem.hex` **逐字节一致**），
并给该脚本加了一道 **sha256 比对守卫**，专门挡这个坑（比原来数行数牢靠）。

**当前待烧的比特流**：

```
pds/RV32I_1/generate_bitstream/cpu_top_board.sbit    md5 c4e2c4d2...
pds/RV32I_1/bitstreams/coremark_iter1663_pll49mhz_localboard.sbit   （同一份）
综合于 2026-09-25 14:29，49.8927 MHz / slack +1.550 / All Constraints Met
```

### 5.2 上板步骤与判据

1. 烧 `pds/RV32I_1/generate_bitstream/cpu_top_board.sbit`（md5 `c4e2c4d2...`）
   —— **必须在 Programmer 里重新 Browse，别直接点 Program**（会沿用上次路径）
2. **串口不乱码**（验证 `UART_DIV=433` 对上了）
3. `Total ticks ÷ 49,892,700 ≈ 11.80 s`
4. `seedcrc / crclist / crcmatrix / crcstate` 与 §4 逐位一致 + `Correct operation validated`
5. 辅助：`led[0]`（`pll_locked`）常亮 = PLL 已锁

> [!] **`crcfinal` 不要比** —— 它是 CoreMark 的跨迭代累加器，必然随 ITER 变。

> ITER 重算：下限（10 s）= `49,892,700 × 10 / 354,119 = 1409`。
> 取 1663 → 11.80 s，留 ~18% 余量，与 45 MHz 时代一致。

> [!] **固件字数从 4209 变成了 4208** —— 这不是 bug。原因：
> `EE_TICKS_PER_SEC` 由 `45,000,000` 改成 `49,892,700` 后，
> 编译器把 `/ EE_TICKS_PER_SEC` 的**常量除法优化**少生成了一条指令。
> 实测对照：`EE_TICKS_PER_SEC=45e6 → 4209 字`、`=49,892,700 → 4208 字`；
> 而 `ITER` 取 1 / 820 / 1500 / 1663 **都是 4208 字**（与 ITER 无关）。
> `build_bitstream.ps1` 里的行数粗筛已同步更新为 8416 行。
