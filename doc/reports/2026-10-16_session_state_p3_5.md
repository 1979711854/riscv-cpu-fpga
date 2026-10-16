# 会话状态 —— 2026-10-16 P3.5：摘掉 lane B 的 `alu_result_b` 腿，1 档在 85 MHz 重新收敛

> 接 `doc/reports/2026-10-16_handoff_p3.md`（P3 交接，含 P3.5 精确方案）与
> `doc/reports/2026-10-16_session_state_p3.md`（P3 全量验证记录）。
> `DESIGN_REV` **`0x2026_1025` → `0x2026_1027`**（中间态 1026 = 只做 (A) 的那一版，也综合过）。
> 本文件是 P3.5 的唯一权威记录。

---

## 1. 一句话结论

**P3.5 成功：1 档（`LANEB_MEM=1`，lane B 放 load）在 85.0051 MHz 重新收敛 —— CPU 域 WNS
`−0.701 → +0.014 ns`（0 失败端点 / 19,083）、Fmax `80.22 → 85.1064 MHz`、LUT `8,029 → 7,753`。**

两处改动都是**严格等价改写**（只动时序、不动语义）：

| 步骤 | 改动 | 效果（PDS CPU 域） |
|---|---|---|
| (A) `0x2026_1026` | `b_addr_low = rs1_val_b[1:0] + id_ex_b_imm[1:0]`（原来是 `alu_result_b[1:0]`） | −0.701 → **−0.345 ns**（Fmax 82.58 MHz、LUT 7,763） |
| (B) `0x2026_1027` | `imem_addr2 = fetch_addr[15:2] + 14'd1`（原来是 `imem_addr + 14'd1`） | −0.345 → **+0.014 ns**（Fmax 85.11 MHz、LUT 7,753） |

功能判据与 P3 **逐位相同**：CoreMark **217,088** 拍 + 四 CRC `e9f5/e714/1fd7/8e3a`、
own_tests **6/0**（含 `tb_laneb_ld` 用例 8）、riscv-tests **49/1/0**、RT-Thread **四配置全 PASS**。

⚠ **余量很薄（+0.014 ns；rev1023 是 +0.330 ns）** —— 位流 `9b58e84c` 已归档但**未上板**。

---

## 2. 改动清单（2 个 RTL 文件）

| 文件 | 改动 | 性质 |
|---|---|---|
| `rtl/core/core.v:1394` | `wire [1:0] b_addr_low = rs1_val_b[1:0] + id_ex_b_imm[1:0];`（原 `alu_result_b[1:0]`）+ 12 行等价性论证注释 | P3.5(A)，1 行逻辑 |
| `rtl/core/core.v:846` | `assign imem_addr2 = fetch_addr[15:2] + 14'd1;`（原 `imem_addr + 14'd1`）+ 8 行时序论证注释 | P3.5(B)，1 行逻辑 |
| `rtl/core/csr_file.v` | `DESIGN_REV` `0x2026_1025 → 0x2026_1026 → 0x2026_1027`（+ 两条历史行） | 约定 42 |

### 2.1 等价性论证（为什么敢只改一行）

**(A) lane B 未对齐判定** —— `control.v` 的 `OP_LOAD` 分支只写
`reg_write/alu_b_sel/mem_read/wb_sel`，`alu_a_sel` 与 `alu_op` 取 always 块默认值
（`0` 与 `5'd0` = ADD）⇒ `b_alu_a = rs1_val_b`、`b_alu_b = id_ex_b_imm` ⇒
`alu_result_b ≡ rs1_val_b + id_ex_b_imm`。低 2 位模 4 加法与全 32 位加法**逐位相同**
（进位不跨出 bit1）。且 `b_mem_unaligned` 只经 `load_misaligned_b`
（本身已 `&& id_ex_b_mem_read && (LANEB_MEM != 0)`）被消费 ⇒ 只在 lane B 是 load 时有意义。

* **不改 `exc_tval`**（`core.v` lane B 分支仍用全 32 位 `alu_result_b`）：它进 CSR 寄存器，
  不在取指路径上；改它只会多一处风险。
* 判据（两条都过）：`tb_laneb_ld` 用例 8（mcause=4 / mtval=出错地址 / mepc=肇事 PC）+ CoreMark 仍 217,088。

**(B) 第二取指地址** —— `imem_addr ≡ fetch_addr[15:2]`（`core.v:832` 就是那个赋值），
两式同为模 2^14 加法 ⇒ 逐位等价。改写的意义是把"两个平级加法器"的自由度还给综合器，
避免 `+1` 串在 `imem_addr` 之后（实测尾段 `imem_addr → N247_1_* COUT 链 → imem_addr2 →
BRAM ADB`，3 级 LUT + 1.2 ns 长线）。

---

## 3. 功能验证矩阵（全部 1 档）

| 回归 | 命令 | 结果 |
|---|---|---|
| own_tests | `scripts\run_own_tests.ps1 -EarlyLd -LanebMem` | **PASS=6 FAIL=0**（`btb_indirect`/`exceptions`/`hi_fetch`/`tb_amo_cpu`/`tb_laneb_ld`/`timer_irq`）；SIM CONFIG 自证 `LANEB_MEM=1` |
| CoreMark | `scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem` | **`Total ticks 217088`**；`seedcrc 0xe9f5` / `crclist 0xe714` / `crcmatrix 0x1fd7` / `crcstate 0x8e3a` —— **四 CRC 与 P3、与 0 档逐位一致** |
| riscv-tests | `scripts\run_riscv_tests.ps1 -LanebMem` | **PASS=49 FAIL=1(`ma_data` 哨兵) TIMEOUT=0** |
| RT-Thread ×4（约定 55） | `scripts\rtthread\run_sim.ps1`（默认）/ `-NoBuild -DCache` / `-NoBuild -ICache` / `-NoBuild -DCache -ICache` | **四配置全 `=== PASS ===`**，四份日志首行 SIM CONFIG 都带 `LANEB_MEM=1` |

* (A)(B) 各跑了一遍完整三连 + 四配置，结论两次一致（见 §4 的两行 PDS 数字）。
* **`_SkipBuild` 口径提醒**：跑过 `build_bitstream.ps1` 之后 `sim/programs/coremark.elf` 是
  **ITER=4332**（本次为了出位流跑过），想再跑 ITER=1 必须去掉 `-SkipBuild` 重建（本次就是这么做的）。

---

## 4. PDS 时序（唯一真判据：`report_timing/cpu_top_board.rtr` 的 Setup Summary **分域行**）

| 版本 | LUT | FF | CPU 域 WNS @85.0051 | 可达 Fmax | 失败端点 | 位流 md5 |
|---|---|---|---|---|---|---|
| rev1023（**当前交付**） | 7,663 | 3,675 | **+0.330 ns** | 87.4585 MHz | 0 | `55fae69e` |
| P3（rev1025，1 档） | 8,029 | 3,693 | **−0.701 ns** | 80.22 MHz | 181 / 20,111 | `6a040f79`（勿烧） |
| **P3.5(A)（rev1026）** | 7,763 | 3,691 | **−0.345 ns** | 82.5832 MHz | 41 / 19,099 | `a3a4d5a7`（时序不过） |
| **P3.5(A+B)（rev1027）** | **7,753** | 3,691 | **+0.014 ns（MET）** | **85.1064 MHz** | **0 / 19,083** | **`9b58e84c`** |

* 跨域 CPU→`pix_clk`：`−1.047 → −1.074 ns / 21 端点` —— **既有伪影**（2026-10-04 报告即 −1.283），
  **不是本次回归**；`multiseed_result.csv` 的 `Setup(Slow)` 列就是它，**别当 CPU 域读**。
* 多 seed：8 个 seed 里 `Best Seed = 6`（csv 按"全设计最差"排序选，**不保证 CPU 域最优**）。
* **网表校验（1 档证据）**：`place_route/cpu_top_board_pnr.netlist` 里 lane B 访存活逻辑确实存在 ——
  `load_half_b` ×10 / `load_data_b` ×14 / `b_addr_low` ×8 / `id_ex_b_mem_read` ×2 / `load_misaligned_b` ×1
  （⇒ 不是 0 档误综合）。

### 4.1 关键路径演化（三段各断一段）

```
P3    ：palette DRAM → vid_rdata → lane B 解包(load_half_b/wb_data_b) → b_alu_a
        → u_alu_b(32 位加法器) → alu_result_b[0] → load_misaligned_b
        → if_addr_d → imem_addr → (+14'd1) → imem_addr2 → BRAM       （16 级，−0.701）
P3.5(A)：同一前端，但未对齐判定改 2 位窄加法 ⇒ alu_result_b 锥被摘掉
        ⇒ 关键路径换成取指尾段的 imem_addr + 14'd1 进位链           （14 级，−0.345）
P3.5(B)：尾段解耦后，最差路径变成 D-RAM 读 → ld_early_val(EARLY_LD 快通路) → rs1_val
        → ALU 的 lt 比较链 → branch_taken → ex_resolve_taken
        → if_addr_d → imem_addr → imem_addr2 → BRAM ADB0            （15 级，+0.014）
```

* 尾段仍是 `imem_addr → N247_1_* COUT → imem_addr2` —— 综合器把两式做了 CSE，**加法器仍在
  `fetch_addr` 锥之后**（数学上无法省），(B) 的收益主要来自"少一级串行共享 + 布局变化"。
* 若将来还要加余量，剩下的大头是：BRAM `tco 1.644 + net 2.143`（前端，固定）、
  ALU 的 `lt` 比较链 4 级（~0.8 ns）、`imem_addr2 → BRAM ADB` 的长线 **1.236 ns**（布局距离）。

---

## 5. 归档

* 位流：`pds/RV32I_1/bitstreams/coremark_dual_noaext_ms_earlyld_a1_ras_btb_lanebmem_85mhz_rev1027_9b58e84c.sbit`
  （8.76 MB，md5 前缀 `9b58e84c`，**2026-10-16 12:53 生成，未上板**）。
* **交付档仍是 rev1023 的 `55fae69e`** —— 换档前必须上板跑一轮（ITER 沿用 4332 ⇒ 板上 ≈11.06 s，
  仍满足 CoreMark ≥10 s 有效性；预期 **391.6 分** = 85.0051e6 ÷ 217,088`）。
* ⚠ 上板前建议先补余量（可选：`imem_addr2` 折进 `fetch_addr` 各腿的 word+1 版本，
  需覆盖全部腿、风险高；或做位置约束改善 ADB 长线）—— **+0.014 ns 属于"过但薄"**，
  与 rev1024+门控那次（+0.004 ns）同档。

---

## 6. 本次踩到 / 复用的坑

* **[!] `run_coremark.ps1` 在 PS 5.1 下会被 vvp 的 stderr 警告打断**（`tb_coremark.v:299` 的
  `$value$plusargs()` 警告 → `NativeCommandError` → `EAP=Stop` 当场终止，**ELF/hex/vvp 其实都已生成**）。
  这与技能 §3 记的 `ld` RWX 警告是**同一类坑的第二个实例**（那次在 gcc，这次在 vvp）。
  **绕过**：手工 `vvp tb_coremark_dual_earlyld_lanebmem.vvp +ITER=1 +IMEM=... +DMEM=... +MEMWAIT=0`。
  修法照抄 gcc 那处的 `try/finally` EAP 保护（**待修**）。
* `run_own_tests.ps1` / `run_riscv_tests.ps1` 不受影响（前者调 gcc 处已有保护，后者用预编译 ELF）。
* `build_bitstream.ps1 coremark` 走 `run_coremark.ps1 -SkipSim`（不跑 vvp）⇒ **不触发上个坑**。
* PDS 的 `RV32I_1.pds` 每次构建都会改 `_timespec`（无实质变化，随提交一起走）。
* 多 seed 只保留被选中的那个工作目录（本次 `seed_6/`），其余 7 个已删 —— 因此
  **无法事后查"别的 seed 的 CPU 域结果"**；换 seed 重跑 = 重新抽 8 个布局再选全设计最优。

---

## 7. 未决 / 遗留

* **位流未上板**（`9b58e84c`）；`55fae69e` 仍是正式交付档。
* **+0.014 ns 余量薄**：见 §5 的补余量建议。
* `scripts\rtthread\run_sim.ps1` 四配置本次已补跑（1 档）；`scripts/gomoku/run_sim.ps1`
  仍未做 1 档回归（P3 §7 起就挂着）。
* `tb_amo_cpu` + `+MEMWAIT` 的既有 bug（P2 §7.4）仍未查。
* `mem_model.vh` 的 `$value$plusargs` 竞速、PS 5.1 下 `run_coremark.ps1` 被 vvp stderr 警告打断
  —— 两个工具链坑待修。
* 未 push（项目纪律）。
