# 会话状态 —— 2026-10-16 P3：lane B 访存开关翻转（`LANEB_MEM=1`）

> 接 `2026-10-16_session_state_p2.md` §10（"P3 起手"）与
> `2026-10-15_laneb_mem_plan.md` §6（分阶段：P3 = 翻开关 + 只跑默认双发射配置）。
> `DESIGN_REV` → **`0x2026_1025`**。本文件是 P3 的唯一权威记录。

---

## 1. 一句话结论

**P3 完成：开关已翻（`LANEB_MEM=1`），功能全绿，CoreMark 效率 +5.76%。**
但 **P4 的 PDS 时序闸门没过**：CPU 域 @85.0051 MHz **WNS −0.701 ns / Fmax 80.22 MHz**，
关键路径是 lane B 的 `alu_result_b` 锥（P2 任务书预警过的 `fetch_addr` 第一风险点）。
⇒ **交付位流不变（rev1023 的 `55fae69e`，0 档）；下一里程碑 = P3.5 把这条腿从取指路径上摘掉。**

---

## 2. 本次改动（4 个文件 + 1 个脚本）

| 文件 | 改动 | 性质 |
|---|---|---|
| `rtl/core/core.v` | `parameter LANEB_MEM` **默认 0 → 1**（+ 结论注释） | P3 本体，一行 |
| `rtl/core/csr_file.v` | `DESIGN_REV` `0x2026_1024` → **`0x2026_1025`**（+ 历史行） | 约定 42 |
| `rtl/top/cpu_top.v` | **新增** `parameter LANEB_MEM = 1` 并透传给 `core` | 板级口径显式化 |
| `sim/tb_rtthread.v` | 新增 `` `ifdef LANEBMEM `` → `LANEBMEM_OUT`；SIM CONFIG 行加 `LANEB_MEM=%0d`；透传给 `cpu_top` | 约定 37/55 |
| `scripts/rtthread/run_sim.ps1` | 新增 **`-NoLanebMem`**（默认传 `-DLANEBMEM`）；配置自证行加 `LANEB_MEM=` | 同上 |

改动前 `cpu_top.v` **根本没透传** `LANEB_MEM`：板级靠 `core` 的默认值，仿真侧 tb_rtthread
则无法二选一、日志也无法自证 —— 这次一并补上（`DUAL_ISSUE`/`EARLY_LD` 的既有写法照抄）。

> `tb_riscv.v` / `tb_coremark.v` 本来就是 tb 内 `localparam` 覆盖（`-DLANEBMEM`），未动。

---

## 3. 功能验证矩阵（全部在 1 档下跑）

### 3.1 PAIRTRACE：先证明"lane B load 真的配了对"（判据不是"测试过了"）

先手工编 `tb_laneb_ld.S` → `elf2mem` → 用 `-DLANEBMEM` 的 vvp 加 `+PAIRTRACE`：

```
BMEM b_pc=000001ac addr=00000340     ← 用例 1  lw  （lane B 驱动访存口）
BMEM b_pc=000001cc addr=00000340     ← 用例 2  lw
BMEM b_pc=000001f8 addr=00000344     ← 用例 3  lb
BMEM b_pc=00000214 addr=00000345     ← 用例 4  lbu
BMEM b_pc=00000230 addr=00000346     ← 用例 5  lh
BMEM b_pc=00000250 addr=00000344     ← 用例 6  lhu
BMEM b_pc=00000280 addr=00000348     ← 用例 7  lw（指针追逐）
=== PASS ===                          ← 用例 8（未对齐 lh）走 trap，不驱动访存口
```

7 条 lane B load 各驱动一次访存口、PC 互不相同 ⇒ 定向用例**真的覆盖了** lane B 访存路径
（不是"通过但什么都没测"）。

### 3.2 CoreMark（ITER=1，判 cycles + 四 CRC）

| 配置 | 1 档 ticks | 0 档基线 | Δ | 四 CRC |
|---|---|---|---|---|
| 双发射 + `EARLY_LD`（**交付档**） | **217,088** | 229,597 | **−12,509（−5.45%）** | `e9f5/e714/1fd7/8e3a` 逐位一致 |
| 双发射（`EARLY_LD=0`） | **228,698** | 249,982 | −21,284（−8.51%） | 同 [OK] |
| 单发射 | **300,392** | 300,392 | **0（逐位不变）** | 同 [OK] |

* **效率（赛题公式的口径）**：`1e6 ÷ 217,088 = 4.6064 CoreMark/MHz`；基线 `4.3555` ⇒ **+5.76%**。
  比模型 ④ 的预估（方案 A k=+7,866，≈+3.4%）**更好** —— 说明 `p_f7_b` 收窄（只对 OP_REG 生效）
  顺带放行的配对也真实兑现了收益。
* 单发射逐位不变 = `pair_now` 被 `DUAL_ISSUE` 门控的预期行为（任务书 §5 的预测全部命中）。

### 3.3 riscv-tests（四组，全部 49 PASS / 1 FAIL(`ma_data` 哨兵) / 0 TIMEOUT）

```powershell
scripts\run_riscv_tests.ps1 -LanebMem                       # 49/1/0
scripts\run_riscv_tests.ps1 -LanebMem -DCache -ICache -EarlyLd  # 49/1/0
scripts\run_riscv_tests.ps1 -LanebMem -MemWait 1            # 49/1/0
scripts\run_riscv_tests.ps1 -LanebMem -MemWait 2            # 49/1/0
```

### 3.4 own_tests（含 R1/R2/R5 定向用例 `tb_laneb_ld.S`）

```powershell
scripts\run_own_tests.ps1 -EarlyLd -LanebMem            # 6/0
scripts\run_own_tests.ps1 -EarlyLd -LanebMem -MemWait 1 # 5/1
```

* `-MemWait 1` 的那 1 个 FAIL = **`tb_amo_cpu` testnum 1**，是 P2 报告 §7.4 记录在案的
  **既有 bug**（A 扩展 + `+MEMWAIT` 的合成停顿模式下 `bnez` 读陈旧值），与 P3 无关。
* **`tb_laneb_ld` 在 `+MEMWAIT=1` 下仍 PASS** ⇒ lane B 访存路径能扛注入停顿
  （R4 那类"漏一处级间寄存器"的错会在这种配置下暴露）。

### 3.5 RT-Thread 四配置（约定 55 的唯一真回归，1 档）

| 配置 | SIM CONFIG（自证行） | 结果 |
|---|---|---|
| 默认（无 Cache） | `LANEB_MEM=1` | **PASS** |
| `-DCache` | `LANEB_MEM=1` | **PASS** |
| `-ICache` | `LANEB_MEM=1` | **PASS** |
| `-DCache -ICache`（挂死历史档） | `LANEB_MEM=1` | **PASS**（四条自检全过） |

> 四份日志首行都打出了 `LANEB_MEM=1`（本次新加的自证字段），口径不用猜。

---

## 4. PDS 综合（1 档，CoreMark `ITER=4332`，位流 `6a040f79`）

| 指标 | rev1023（**当前交付** `55fae69e`） | 0 档 + 7 处门控（本次前一步） | **1 档（本次）** |
|---|---|---|---|
| LUT（cpu_top_board） | 7,663 | 7,709 | **8,029** |
| FF | 3,675 | 3,675 | 3,693 |
| DRM / APM / DistRAM | 101.5 / 4 / 572 | 101.5 / 4 / 572 | 101.5 / 4 / 572 |
| CPU 域 @85.0051 MHz | **+0.330 ns（0 端点）** | **+0.004 ns（0 端点）** | **−0.701 ns（181/20,111 端点，TNS −48.145）** |
| CPU 域可达 Fmax | 87.46 MHz | 85.03 MHz | **80.22 MHz** |
| 跨域 CPU→pix_clk | −1.048 / 21 端点 | −1.093 / 21 端点 | −1.047 / 21 端点（既有，性质不变） |
| 位流 | `55fae69e` | `b42c210a` | `6a040f79`（**时序不过，不要上板**） |

### 4.1 关键路径（`report_timing/cpu_top_board.rtr`，seed 6）

```
u_video/u_core/u_pal DRAM 读出 → vid_rdata
  → u_soc/u_core/load_half_b[7]                       ← lane B load 解包（P3 新活逻辑）
  → load_data_b_4[16] → wb_data_b[27]                 ← (I) 的 wb_data_b
  → b_alu_a[27] → u_alu_b/N21…/result_207[0] → alu_result_b[0]   ← lane B ALU 32 位加法器
  → N616_5 → if_addr_d[5] → imem_addr[3] → imem_addr2[12]        ← 取指地址 mux
Data arrival 17.207 ns（Logic Levels 16；Logic 36.5% / **Route 63.5%**）
```

**这正是 P2 任务书 §3 预警的 `alu_result_b` 锥并进 `fetch_addr`**：0 档时 7 处门控能把它整条
常量折叠掉（+0.004 ns）；**1 档下它是活逻辑、折叠不掉**，于是又回到取指关键路径上。

### 4.2 盈亏平衡算术（诚实版）

* **归一化效率**（赛题公式 `Score = Iter/(Time×Freq)`）**与主频无关**：
  4.6064 vs 4.3555 ⇒ **+5.76%**，这一项 1 档明确赢。
* **物理分**（固定板上时钟）：如果强行 85 MHz → `85.0051e6 ÷ 217,088 = 391.6 分`（+5.8%），
  但**时序过不了、不能这么出**；退到可达的 80.22 MHz → `80.2246e6 ÷ 217,088 = **369.5 分**`，
  比现在的 **370.31 分** 略**亏 0.2%**。
* **break-even 频率**（用实测 Δ 而非模型 Δ）：`85.0051 × 217,088 ÷ 229,597 = **80.37 MHz**`；
  实测 80.22 MHz **正好差 0.15 MHz**。

⇒ **结论：1 档现在"功能赢、时序输"，净收益约为零，不值得为它换掉交付位流。**

---

## 5. 下一步（P3.5，优先级最高）

**目标**：把 lane B 的 `alu_result_b` 腿从 `if_addr_d/imem_addr` 的组合路径上摘掉，
让 1 档的 CPU 域 Fmax 回到 87 MHz 级（判据：≥ 85.0051 MHz 且余量回到 rev1023 的 +0.330 量级）。

候选修法（按代价排序，**均未验证**）：

1. **给 lane B 的未对齐判定换窄逻辑**：`load_misaligned_b` 只需要地址低 2 位与"跨字"信息，
   不必等 `alu_result_b` 全 32 位 —— 用 `{rs1_val_b[1:0] + imm_b[1:0]}` 的 2 位加法 + funct3
   即可判 `lh/lw` 是否越界。风险：跨字边界条件要写全（`lh` 在 offset=3 时也越界）。
2. **把 lane B 的 trap/flush 变成寄存器输出**：`if_addr_d` 只在 trap 那拍被强制改写，
   若允许"lane B 的异常在下一拍才冲刷取指"（多 1 拍气泡、只在异常路径上，正确性不受影响），
   这条长链就从 fetch 路径上断开了。风险：`trap_pc`/`mepc` 语义要重证（`tb_laneb_ld` 用例 8）。
3. **兜底**：维持 0 档交付，把 1 档当作"效率储备"，等 P3.5 修完再翻。

**P3.5 的验证入口**（照抄本次的命令，全在 1 档下）：
`run_own_tests.ps1 -EarlyLd -LanebMem`（6/0，重点看 `tb_laneb_ld` 用例 8）→
`run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem`（必须仍是 **217,088** + 四 CRC，证明只动时序不等价性）
→ `build_bitstream.ps1 coremark`（判 LUT 回落 + WNS ≥ 0）。

---

## 6. 本次踩到 / 复用的坑

* **`run_own_tests.ps1` 默认清掉 `sim/tests/build/`**（`-KeepHex` 才留）。想手工 `vvp +PAIRTRACE`
  要先加 `-KeepHex`，或者直接手工 `riscv-none-elf-gcc` 编到 `sim/programs/`（本次采用后者）。
* **PDS 位流默认不带时间戳校验**：`6a040f79` 时序不过却照样 8.76 MB 正常生成 —— 判"能不能上板"
  只认 `report_timing` 的 WNS，不认"构建成功"。
* `multiseed_result.csv` 的 `Setup(Slow)` 列是**全设计最差**（= 跨域 CPU→pix_clk），
  **不是 CPU 域**的值；CPU 域要看 `report_timing/*.rtr` 的 `Setup Summary` 分域行。
* 各 seed 的 `place_route/seed_*/` 只在被选中的那个保留（本次只有 `seed_6/`）。

---

## 7. 未决 / 遗留

* **P3.5（见 §5）** —— 本轮唯一阻塞项。
* `scripts/gomoku/run_sim.ps1` 未跑：它例化 `cpu_top`，现在会默认取到 `LANEB_MEM=1`
  （= 板级口径，一致），但**没做过 1 档回归**；P3.5 时补一次。
* `tb_amo_cpu` + `+MEMWAIT` 的既有 bug（P2 §7.4）仍未查。
* `mem_model.vh` 的 `$value$plusargs` 竞速、PS 5.1 下脚本被链接器警告打断 —— 两个工具链坑待修。
* 未 push（项目纪律）。
