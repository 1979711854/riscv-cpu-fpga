# 任务书：修 rev1024 的时序回归 + P3 翻开关前的闸门（2026-10-16 交接）

> 接 `2026-10-16_session_state_p2.md` §9.1（另一个并行会话已记录 PDS 对比数字）。
> **本文件是给下一个会话的执行手册**：根因已定位、修法已写好、验证步骤已列好。
> 作者：本会话（P2 主线会话）—— 因上下文容量主动停在"结论+任务书"，未动 RTL。

---

## 1. 结论（三句话）

1. **P2 功能侧全部达标**（四条基线逐位不变、riscv-tests 49/1/0×3、own_tests 5/0），
   **但 PDS 实测不过时序**：CPU 域 @85.0051 MHz **WNS −0.165 ns / 20 个失败端点**，
   可达 **83.83 MHz**（rev1023 是 +0.330 ns / 0 端点 / 87.4585 MHz）；LUT **7,663 → 7,918（+255）**。
2. **根因不是"P&R 噪声"，是 P2 新逻辑真的上了 fetch_addr 关键路径** —— 已追到完整路径：
   BRAM 读出 → … → **`b_mem_unaligned`（(H) 新增）** → `fetch_addr` mux → `imem_addr` → BRAM。
   综合器把 `load_misaligned_b` 背后的 `alu_result_b`（32 位加法器 cone）并进了取指路径。
   （§9.1 里"关键路径不在 P2 新逻辑上"的判断**有误**，路径中间那些 `load_half`/`rs2_val`/
   `branch_taken` 是网线名，真正的断点在其后的 `b_mem_unaligned_5/gateop_perm` LUT。）
3. **修法已备好（未实施、未验证）**：把 7 处新逻辑的消费者用 `LANEB_MEM` 门控成**常量折叠**，
   0 档综合器整条删掉 ⇒ 逐位恢复 rev1023 的网表与时序；1 档语义不变。见 §4。

**双重确认**：本会话完整跑完 8 seed + report_timing + 出位流，数字与并行会话中断前的最优
seed **逐位相同**（LUT 7,918、Fmax 83.8293 MHz、WNS −0.165 ns）⇒ 不是 seed 抖动，是确定性回归。

---

## 2. 当前位流状态（重要，别烧错）

| 位流 | 状态 |
|---|---|
| `55fae69e`（rev1023，A 扩展默认关） | **仍然是唯一可交付/可上板的位流**（370.31 分，板上验证过） |
| 本会话新出的 `pds/RV32I_1/generate_bitstream/cpu_top_board.sbit`（md5 **`5124b4bc…`**，9,188,552 B，10:33:04） | **时序不过（−0.165 ns），不要上板**。它只是"rev1024 能编出来"的证据 |

构建日志：`p2_build_rev1024.log`（仓库根，未入库，作为证据留着）。

---

## 3. 根因细节（下一个会话复查用）

**失败路径**（`pds/RV32I_1/report_timing/cpu_top_board.rtr`，WNS −0.165 ns 那条）：

```
Startpoint: u_video/u_core/u_pal/mem_2_bwe_2/...QA[14]   (video palette DRAM 读出)
  → pal_q → vid_rdata → load_half → rs2_val → 分支比较链(N600.lt_*) → branch_taken
  → _N32690(fanout=32)
  → CLMS_231_781/Y1  = u_soc/u_core/b_mem_unaligned_5/gateop_perm/Y   ← P2 新增(H)
  → CLMA_243_768/Y3  = u_soc/u_core/if_addr_d[3]/.../L6
  → u_soc/imem_addr[1] → imem_addr2 → DRM ADB（终点）
```

**机理**：`b_mem_unaligned = f(id_ex_b_funct3, alu_result_b)`，其中
`alu_result_b = rs1_val_b + imm_b`（32 位加法器）。它喂
`load_misaligned_b → ex_exception → trap → fetch_addr` 的**最高优先级 mux 腿**。
虽然 `LANEB_MEM=0` 时 `load_misaligned_b` 功能上恒 0，但**综合器证明不了**
（`id_ex_b_mem_read` 是真寄存器），于是把整条 cone 建出来，并**合并进 fetch_addr 的
mux LUT** —— 正是 `core.v:572/688` 与任务书 §9 预警的"Fmax 第一风险点"。

**同类暴露点（同一批修掉）**：任何"喂 fetch_addr / stall / 访存口 / 前递"的新消费者，
在 0 档都必须常量折叠，否则综合器都会把它建出来。共 7 处，见 §4。

---

## 4. 修法（已写好，直接实施；全部是"加门控"，行为零变化）

> 原则：`(LANEB_MEM != 0) && 新逻辑`（正向门控）或 `旧条件 || (LANEB_MEM == 0)`（反向兜底）。
> 0 档综合器折叠成常量 ⇒ 与 rev1023 逐位同网表；1 档就是现在的语义。
> 每处都要**同时保留/更新注释**，说明"为什么必须门控"（时序原因，不是功能原因）。

| # | 位置（`rtl/core/core.v`） | 现状 | 改成 |
|---|---|---|---|
| 1 | `load_misaligned_b` 定义（(H)，**主凶**） | `id_ex_b_mem_read && b_mem_unaligned` | `(LANEB_MEM != 0) && id_ex_b_mem_read && b_mem_unaligned`（任务书 §4H 原本就带这个门控，是实现时漏的） |
| 2 | `pair_now` 的“每对最多一条访存” | `!(p_mem_a && p_ld_b)` | `!(p_mem_a && p_ld_b && (LANEB_MEM != 0))` |
| 3 | `b_mem_sel`（(C) 访存口） | `ex_mem_b_valid && ex_mem_b_mem_read` | `(LANEB_MEM != 0) && ex_mem_b_valid && ex_mem_b_mem_read` |
| 4 | `stall` 的 lane B 子句（(E)） | `(id_ex_b_mem_read && …)` | 整条前置 `(LANEB_MEM != 0) &&` |
| 5 | 五个 `ld_f_exb`/`fwd_*_exb` 的 `wb_sel` 门控（(F)） | `&& (ex_mem_b_wb_sel != 2'b01)` | 新增 `wire exb_wb_ok = (ex_mem_b_wb_sel != 2'b01) \|\| (LANEB_MEM == 0);`，五处改用 `&& exb_wb_ok` |
| 6 | `ld_bad_base` 的 `ex_mem_b` 子句（(G)） | `((ex_mem_b_rd != 0) && (ex_mem_b_rd == rs1) && ex_mem_b_mem_read)` | 整条前置 `(LANEB_MEM != 0) &&` |
| 7 | `wb_data_b` 的 load 腿（(I)） | `(mem_wb_b_wb_sel == 2'b01) ? load_data_b : …` | `((mem_wb_b_wb_sel == 2'b01) && (LANEB_MEM != 0)) ? load_data_b : …` |

实施后 `DESIGN_REV` 不变（仍 `0x2026_1024`，同一天内的第二次改动可不动；若想区分可升 `0x2026_1025`，
**但要在 `csr_file.v` 历史块写清**）。

---

## 5. 验证步骤（按顺序，全过才能说修好）

1. **编译**：`iverilog -g2012 -DDUAL …` 四配置全过（无宽度警告）。
2. **行为逐位不变**（判据！门控是 0 档的无操作，必须仍然逐位相同）：
   * `run_coremark.ps1 -Iter 1 -EarlyLd` → **229,597** + CRC `e9f5/e714/1fd7/8e3a`
   * `run_coremark.ps1 -Iter 1` → **249,982**；`-Single` → **300,392**；
     `-DCache -ICache -EarlyLd` → **233,013**（四 CRC 全一致）
   * `run_riscv_tests.ps1` 与 `-DCache -ICache -EarlyLd` → 各 **49/1/0**
   * `run_own_tests.ps1` → **5/0**
   （脚本刚修好（`9daa65d`），PS 5.1 下可直接跑，不用再手工复刻。）
3. **PDS 完整流程**：`scripts\build_bitstream.ps1 coremark`（ITER=4332）。
   **预期**：LUT ≈ **7,663**（±seed 噪声几位）、CPU 域 **WNS ≈ +0.33 ns / 0 失败端点**、
   Fmax ≈ 87.4 MHz —— 即"折叠生效、时序恢复"。若仍不过 ⇒ 还有漏网的新逻辑消费者，
   按 §3 的方法从 `report_timing/cpu_top_board.rtr` 的最差路径倒查（看路径上有没有
   `*_b_mem_read`/`b_mem_unaligned`/`load_data_b` 这类新信号）。
4. **（可选但建议）P3 成本预览**：临时 `LANEB_MEM=1` 再跑一次 PDS，拿到翻开关的**真实**
   时序代价 —— 这才是任务书 §9 闸门该用的数（方案 A 盈亏平衡 **82.09 MHz**；按新计分规则
   它已降级为"看掉多少、值不值"，但翻开关前必须知道）。跑完改回 0。

---

## 6. P3 及之后（本任务书之后的事）

1. **修完时序并提交后**，才轮到 P3：先写 R1/R2 定向用例（lane B load 紧跟依赖指令 /
   指针追逐），再翻 `LANEB_MEM=1`，判据 = riscv-tests 49/1/0 + 四 CRC 逐位一致 + cycles 显著下降
   （别拿模型 6.0% 当 go/no-go）。
2. P4：`+MEMWAIT`（riscv-tests/own_tests 口径，**CoreMark 的 +MEMWAIT 判据不可靠**，见 P2 报告 §7.5）、
   Cache 各配置、RT-Thread 四配置、PDS 满 8 seed 重量时序。
3. **遗留待查**：既有 AMO+`+MEMWAIT` bug（P2 报告 §7.4，生产配置不可触发）。
4. 上板：只有"修完时序 + 翻开关验证过"的新位流才能替掉 `55fae69e`；替之前先过 P4 全单。

---

## 7. 本会话已确认的事实清单（省得下一个会话重跑）

* 两个独立 PDS 运行数字逐位相同：LUT 7,918、CPU 域 WNS −0.165 ns、Fmax 83.8293 MHz
  （本会话跑满 8 seed + report_timing + 位流；并行会话中断在 seed 3/8 但最优 seed 相同）。
* 失败路径经 `b_mem_unaligned_5/gateop_perm` LUT —— 即 (H) 新增逻辑，见 §3 路径原文。
* 位流 `5124b4bc…`（rev1024、时序不过）已生成但**不可交付**；交付仍是 `55fae69e`。
* §4 的 7 处门控在本会话已全部推演过（行为等价性逐处证明过），但**一行都没落盘**
  （`rtl/core/core.v` 已 `git checkout` 还原到 `b7f39fe` 状态，工作树干净）。
