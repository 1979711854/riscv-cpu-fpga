# 任务书：给 lane B 加 load 能力（2026-10-15 定稿，**未开工**）

> 承接 `2026-10-15_pair_rate_analysis.md` §5。那份文档判定：**周期侧唯一剩下的实质机会
> 就是让 lane B 能发访存指令**。本文是把那件事做成可执行方案。
>
> [!] **状态：方案定稿，RTL 一行未改。** 下个会话从 §6 的 P0 开始。

---

## 1. 收益与方案选择（都是离线规则复放，`sim/programs/pairtrace.txt`，288,056 条）

| 方案 | 配对数 k | 相对实现基线 72,256 | **分数提升** |
|---|---|---|---|
| 现状（lane B 只放纯 ALU）| 72,256 | — | — |
| **A. 只放 load** + "每对最多一条访存" | **80,122** | +7,866 | **≈ +3.5%** |
| A'. load + store，同样约束 | 80,655 | +8,399 | ≈ +3.8% |
| B. load + store，**不限同拍访存** | 88,198 | +15,942 | ≈ +7.2% |

**推荐：方案 A（只放 load）。** 理由见 §3/§4。

**方案 B 为什么不做**：那 16,189 组"A、B 同拍都是访存"的构成是
**LL 47% / LS 38% / SL 13% / SS 仅 2.2%** —— 也就是说 98% 的收益需要
**≥2 个独立读口 + 读写并发**。这不是"加个仲裁器"，而是**存储子系统重构**：
要新增第 4 份 BRAM 阵列、把 `unified_mem` 的写广播解耦成独立读写口、
改 `mem_bus` 的时序契约、把 D-Cache 改成双请求、重证 `fence.i` / 自改码的一致性。
**边际只多 +3.5%，风险收益比不成立。**

---

## 2. 为什么"不做端口仲裁"就够了 —— 时序上根本不冲突

lane A 与 lane B 是**同一对、同拍锁存**（`ex_mem` / `ex_mem_b` 同沿更新，`core.v:1718-1754`）。
所以任一拍的 MEM 级里躺着的就是**这一对**的两条指令。规则"每对最多一条访存"
⇒ **任一拍 MEM 级至多一条访存** ⇒ 访存口在 lane A / lane B 之间**做一次 2 路 mux 即可**，
不需要仲裁器、不需要 ready/wait 交互、不需要"两条访存串行化"。跨拍也不会冲突。

由此**顺带消除**三个原本很麻烦的点：
* **不需要第二份 `ld_snap`** —— `mem_rdata` 每拍至多一个消费者，
  `core.v:1376` 那句"`load_src` 与基线逐字相同、不给这条链加级"的承重结论得以保持。
* **不需要动 `wb_rdata_snap`**（`core.v:1350-1373`，历史最易复发处）。
* **快通路与 B 口天然不撞**：lane A 走快通路时不占 B 口（`core.v:274` 已排除
  `ex_mem_ld_fast`），而同对里 lane B 不可能是访存。

---

## 3. 为什么只放 load、不放 store

| 项 | load-only | +store |
|---|---|---|
| 分数 | +3.5% | +3.8%（**边际仅 +0.26%**）|
| 新增字段 | `mem_read` / `funct3` | 再加 `mem_write` / `wdata`，并改动 `mem_we`/`mem_wdata`/`mem_byte_en` 三条写通路 |
| 风险 | — | **`ex_flush` 那拍 lane B 若为 store 会静默写坏内存**（见 §7 R-main）|

只放 load 还顺带消灭三个隐患：
* **风险 #1（静默写内存）** 从设计上不存在 —— lane B 不写内存。
* **风险 #5（`ld_snap` 串地址）** 不存在 —— lane B **不走 `EARLY_LD` 快通路**（见下）。
* **风险 #6（`p_rd_b != 0` 对 store 不成立）** 不存在 —— load 有 rd，语义成立。

**lane B 的 load 一律走旧通路（slow path），永不使用 `EARLY_LD`。** 收益为 0
（+3.5% 全部来自配对率，与消停顿无关），却要第二根 `ld_addr`、第 4 份阵列、
lane-B 的 ID 级 AGU 前递网、第二份 `ld_snap` —— 全落在 `core.v:1347-1349`
说的"每一级都贵"那条链上。

---

## 4. 改动清单（全部在 `rtl/core/core.v` + 一个常量，**端口契约零改动**）

> `mem_bus.v` / `unified_mem.v` / 端口契约 **不动** —— 这是方案 A 相对 B 最大的优势。

建议新增 `parameter LANEB_MEM = 0`（`core.v:5-22` 那组参数旁），最终翻 1；理由见 §6 的 P2。

**(A) 新增流水线寄存器**（`core.v:243-263` 那块的 lane B 组）
```
id_ex_b_mem_read, id_ex_b_funct3            // ID/EX
ex_mem_b_mem_read, ex_mem_b_funct3[2:0]     // EX/MEM
mem_wb_b_funct3[2:0], mem_wb_b_addr_low[1:0]// MEM/WB
```
不需要 `id_ex_b_ld_fast`/`ld_addr`（不走快通路），不需要 `ex_mem_b_wdata`/`mem_write`（不放 store）。

**(B) 配对规则**（`core.v:623-633` 解码、`693-700` 的 `pair_now`）
* 新增 `wire p_mem_a = (p_op_a==7'b0000011)||(p_op_a==7'b0100011);`
  `wire p_ld_b  = (p_op_b==7'b0000011);`
* `p_opcode_b_ok` 加 `|| ((LANEB_MEM!=0) && p_ld_b)`
* **`p_f7_b != 1` 必须收窄成"仅 OP_REG"**：
  `!((p_op_b==7'b0110011) && (p_f7_b==7'b0000001))`。
  这是因为 **load 的 `instr[31:25]` 是立即数高位**，`imm[11:5]==1` 的合法 load
  会被现在这条无条件排除 —— **表现为"少配一对"，不报错、CRC 也不变**（见 §7 R3）。
* 新增 `&& !(p_mem_a && p_ld_b)`（每对最多一条访存）
* `p_rd_b != 0`、`p_rd_a != p_rs1_b/rs2_b/rd_b` **保持原样**
* [!] **不给 `fetch_addr` 新增 mux 腿**（`core.v:548, 688` 明令）—— 新条件全部折进现有的 `pair_now` 项

**(C) 访存口 mux**（`core.v:270-281`）
```
wire b_mem_sel = ex_mem_b_valid && ex_mem_b_mem_read;
assign mem_re   = b_mem_sel ? 1'b1 : ((ex_mem_mem_read && !ex_mem_ld_fast) | amo_mem_re);
assign mem_addr = b_mem_sel ? ex_mem_b_alu_result :
                  (ex_mem_is_amo ? ex_mem_amo_addr : ex_mem_alu_result);
assign mem_we   = ex_mem_mem_write | amo_mem_we;      // 不变实现，lane B 不写
```
* lane B 的 `control_b` 给 `alu_a_sel=0, alu_b_sel=1, alu_op=0` ⇒ `alu_result_b = rs1_val_b + imm_b`
  **就是地址，不需要新增加法器**。
* **`ex_mem_b_valid` 天然含 `&& !ex_flush`**（`core.v:1748`）⇒ 用 `b_mem_sel` 门控
  **自动满足"`ex_flush` 拍 lane B 不得驱动读口"**（否则会误触发 D-Cache/LRU 与快照）。
  **这一点必须写进注释**，否则后人会以为 `ex_mem_b_valid` 冗余而清理掉（见 §7 R6）。

**(D) `mem_wdata`/`mem_byte_en`**（`core.v:1301-1327`）—— **本阶段不动**

**(E) load-use 停顿**（`core.v:589-599`）新增一条同构子句，生产者 = `id_ex_b_mem_read`：
```
(id_ex_b_mem_read && (id_ex_b_rd != 5'd0) &&
 ((id_ex_b_rd == rs1) || (id_ex_b_rd == rs2) ||
  (if_id_pair && ((id_ex_b_rd == rs1_b) || (id_ex_b_rd == rs2_b)))))
```
`if_id_pair` 门控的理由与 `core.v:580-585` 完全一致。不需要 `!ld_fast`（lane B 无快通路）。
`stall_int = stall && mem_ready_int`（606）**自动覆盖冻结期"保持而非清"**。

**(F) [!] 前递网的 lane-B load 洞（高危静默错）** —— `core.v:846/852/929/935`
四个 `fwd_*_exb` 用 `ex_mem_b_reg_write && ex_mem_b_rd==...`，**没有排除 `wb_sel==2'b01`**。
lane B 一旦是 load，`ex_mem_forward_val_b`（734-737）会落到 `ex_mem_b_alu_result`（= 地址）
被当成数据前递。四处都要加 `&& (ex_mem_b_wb_sel != 2'b01)`（与 lane A 的 `fwd_a_ex` 同构）。

**(G) [!] ID 级 AGU 基址网的 lane-B load 洞（高危静默错）** —— `core.v:778-814`
* `ld_f_exb`（778）同样缺 `ex_mem_b_wb_sel != 2'b01`，加。
* **更隐蔽**：`ld_bad_base`（802-807）只查 `id_ex` / `id_ex_b` / `ex_mem`，
  **完全没查 `ex_mem_b`**。当 lane A（ID 级）是 load、基址由 `ex_mem_b` 里的**另一条 load**
  产生时，`ld_f_exb` 被门控掉后静默回落到 `id_ex_rdata1`（陈旧值）→ `ld_id_addr` 算错，
  而 `ld_fast` 仍判"可走快通路" → **读到错地址**。补：
  `|| ((ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == rs1) && ex_mem_b_mem_read)`

**(H) lane B 未对齐异常 / trap** —— `core.v:1182-1189, 1228-1265, csr 例化 1280`
新增 `load_misaligned_b`（地址 = `alu_result_b`），并让 trap 按**最老的肇事指令**选：
```
wire ex_exception = ex_exception_a || (load_misaligned_b && (LANEB_MEM!=0));
wire [31:0] trap_pc       = ex_exception_a ? id_ex_pc : id_ex_b_pc;
wire [31:0] exc_cause_sel = ex_exception_a ? exc_cause : 32'd4;   // 4 = Load misaligned
wire [31:0] exc_tval_sel  = ex_exception_a ? exc_tval  : alu_result_b;
```
并把 `csr_file` 例化的 `.trap_pc(id_ex_pc)`（1280）改成 `.trap_pc(trap_pc)`。

> **为什么"mepec 取 lane B 的 PC、lane A 被冲刷重放"是安全的**（必须写进注释）：
> 1. 规则"每对最多一条访存" ⇒ lane A 只可能是 ALU / branch / jal / jalr / CSR / SYSTEM；
> 2. 这些在"先提交再重放"下都幂等（写 rd 同值；CSR 的 RW/RS/RC 幂等）；
> 3. 唯一不显然的 `csrrw` 被 `csr_wr_en = csr_wr_en_raw && !trap && mem_ready_int`（1218）救掉
>    —— lane B 的异常并进 `trap` 后，lane A 那拍不写 CSR，重放时读到旧值，rd 正确；
> 4. `mret` 同理被 `mret_commit = id_ex_mret && !trap`（1051）抑制；
> 5. lane B 的错**不会真写内存**（它还在 EX，trap 清 ID/EX ⇒ 下一拍进不了 EX/MEM）。

**(I) WB 写回** —— `core.v:1376-1402`
加 lane B 的 load 解包（复用同一份 `load_src`，理由见 §2），并给 `wb_data_b` 加 `wb_sel==2'b01` 分支；
**删掉 1399 行"`wb_sel=01` 对 lane B 不可能"的注释**（已不成立）。

**(J) [!] 四处级间寄存器的 清 / 保持 / 锁存 —— 最容易漏的就是这里**
新增字段必须在**每一个分支**都出现，漏一处就是静默错：
| 位置 | 行号 | 加什么 |
|---|---|---|
| ID/EX 清（trap/flush/stall）| 1546-1597 | `id_ex_b_mem_read <= 0;` |
| ID/EX 锁存 | 1642-1657 | `id_ex_b_mem_read <= if_id_pair ? mem_read_b : 1'b0;`（含 `id_ex_b_funct3`）|
| EX/MEM 清（trap/mc_stall）| 1682-1708 | `ex_mem_b_mem_read<=0; ex_mem_b_funct3<=0;` |
| EX/MEM 锁存 | 1718-1754 | `ex_mem_b_mem_read <= id_ex_b_mem_read;` `ex_mem_b_funct3 <= id_ex_b_funct3;` |
| MEM/WB 复位 + 锁存 | 1758-1794 | `mem_wb_b_funct3`、`mem_wb_b_addr_low <= ex_mem_b_alu_result[1:0]` |

> lane B 的 **read** 不需要额外 `&& !ex_flush`（靠 (C) 的 `b_mem_sel`），
> 但**要在这段承重注释里写明为什么**，与 1741-1746 的既有理由并列。

**(K) `rtl/core/csr_file.v:90`** —— `DESIGN_REV` `0x2026_1022` → **`0x2026_1023`**

**(L) `scripts/pair_analyze.py`** —— 文件头明写"改 RTL 的配对规则时这里要跟着改"。
把 `is_simple_alu_b` 扩成允许 LOAD、加"每对最多一条访存"。**这是 P1 的判据来源。**

---

## 5. [重点] 判据修正：那两条基线**必然会变**

`CLAUDE.md:290-298` 的四条并列基线里，**"双发射 + `EARLY_LD=0`"（252,730）和
"带 Cache"（235,628）两条也是双发射** —— 默认开启 lane B 访存后，**它们的 cycles 必然下降**。

* **单发射（`-Single`，303,140）自动逐位不变**（`pair_now` 被 `DUAL_ISSUE != 0` 门控）。
* 那两条的正确判据是：**49 PASS / 1 FAIL / 0 TIMEOUT + 四个 CRC 逐位一致，cycles 允许下降**。
* [!] **带 Cache 那条不能因为"它本来就会变"而跳过 —— 它是约定 47 的 bug 唯一可达的配置。**

---

## 6. 分阶段实施（P2 是这套流程的关键）

| 阶段 | 内容 | 判据 |
|---|---|---|
| **P0** | 复现四条基线（当前 RTL）+ 记 4 CRC | 229,597 / 252,730 / 303,140 / 235,628 全对上 |
| **P1** | 改 `pair_analyze.py` 规则，复跑 pairtrace | k 从 72,256 → **80,122** |
| **P2** | core.v 全部"管道"落地，但 **`LANEB_MEM=0`** | **四条基线逐位不变**（证明新增寄存器/逻辑不扰动既有行为）|
| **P3** | 翻 `LANEB_MEM=1`，只跑默认双发射配置 | riscv-tests 49/1/0；**4 CRC 逐位一致**；cycles 显著下降 |
| **P4** | 其余配置 + own_tests + **+MEMWAIT=1/2** + Cache + PDS 时序 | 见下 |
| **P5（可选）** | 加 store | 仅在 P4 后时序有富余、且基线全干净时才考虑 |

**P2 的价值**：把"接线"和"改行为"分开，让 90% 的改动在**不影响任何基线**的前提下先落地，
出问题能立刻二分。

**P4 必跑清单**
* `scripts\run_own_tests.ps1`（含 `exceptions.S`）→ 5/0 —— **唯一能抓 trap 相关漏门控的**
* `run_coremark.ps1 -MemWait 1` / `-MemWait 2` → **唯一能抓快照/冻结类 bug 的配置**
* `run_coremark.ps1 -DCache -ICache -EarlyLd` → 4 CRC 一致
* `scripts\rtthread\run_sim.ps1` 两配置 → 4 配置 PASS
* **PDS 综合：CPU 域 WNS ≥ 0，Fmax ≥ 79.1 MHz（break-even）**

**判据提醒**：模型给的 −7,866 拍是"配对率上界"，实测会打折（模型对实现的已知乐观度 ~5%）。
P3 的判据应写成"**cycles 显著下降且 4 CRC 不变**"，而不是死抠某个数字。

---

## 7. 风险清单：最容易引入"测试测不出来"的静默错误

| # | 风险 | 为什么测不出来 | 防法 |
|---|---|---|---|
| **R1** | `fwd_*_exb` 未排除 `wb_sel==01`（§4F）| 只在"lane B load 紧跟依赖它的指令"时错；CoreMark 里没这组合就全过 | 加门控 + **定向汇编用例** |
| **R2** | `ld_bad_base` 漏 `ex_mem_b` 是 load（§4G）| 需"lane A load 的基址来自 B 槽 load"的链式解引用 | 补子句 + **指针追逐用例** |
| **R3** | `p_f7_b != 1` 未收窄（§4B）| **表现为"少配一对"，不报错、CRC 不变，只是分数少** | 收窄 + pairtrace 复核 |
| **R4** | 四处级间寄存器漏一处（§4J）| 只在"trap/mc_stall/冻结 撞上 lane B load"时错 | 逐分支对照 + `+MEMWAIT` + own_tests |
| **R5** | lane B 未对齐判错 | 唯一的未对齐测试 `ma_data` **本来就 FAIL**，不报警 | **定向用例**，或至少保证 testnum 不变 |
| **R6** | `ex_mem_b_valid` 被当冗余清掉 | 它是 lane B 的访存/写回**总门控**，承重 | 在 253 行补注释 |
| **R7** | 用 `alu_result_b` 当地址但控制选错 | 依赖 `control_b` 的 `alu_b_sel=1` | (C) 处注释依赖关系 |
| **R8** | 冻结期 `wb_rdata_snap` 抓错 | 1360-1372 是历史上最易复发处 | **+MEMWAIT + Cache 必跑**；lane B 不走快通路 |
| **R-main** | （若做 store）`ex_flush` 拍 lane B store 静默写内存 | 写坏的地址不在 CoreMark 数据布局里就测不出 | **本轮不做 store**；将来做必须 `&& !ex_flush` |

---

## 8. 明确**不做**的部分

1. **方案 B 的端口仲裁**（§1）—— 那是存储子系统重构。
2. **本轮给 lane B 加 store** —— 边际 +0.26%，换来 R-main。
3. **给 lane B 加 `EARLY_LD` 快通路** —— 收益 0，全落在最贵的链上。
4. **允许 lane B 是 AMO / LR / SC** —— 多拍状态机独占 B 口，收益可忽略。
5. **允许 lane B 是 branch/jal/jalr/CSR/SYSTEM** —— 会碰重定向/陷阱/BHT/RAS/BTB。
   **尤其不要动 BHT/BTB/RAS 训练**（它们挂在 `id_ex_*` 上，全按"lane B 永远不是控制指令"写的，`core.v:1123-1136`）。
6. **给 `fetch_addr` 新增 mux 腿**（`core.v:548, 688` 明令）。
7. **改 `unified_mem.v` / `mem_bus.v` 任何东西** —— 本方案不需要；改了就要重证
   `fence.i` / 自改码 / 写通三条不变量。

---

## 9. 最大的不确定性（go / no-go 闸门）

**`pair_now` 落在 `fetch_addr` 的关键路径上**（`core.v:336-340, 688`），
而当前 CPU 域余量只有 **+0.034 ns**。新条件（多一个 `p_mem_a && p_ld_b` 项）
会加一级 LUT。

**所以：P2 落地后先做一次 PDS 综合量 `fetch_addr` 路径，再决定是否翻开关。**
若综合后 WNS < 0 或 Fmax < 79.1 MHz，本方案作废。**这是先验闸门，不做完不算数。**
