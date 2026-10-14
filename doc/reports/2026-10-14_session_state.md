# 会话状态 —— 2026-10-14（覆盖 A：`tb_amo_cpu.S` 转 tohost + 抓到并修掉一族 RTL bug；覆盖 B：`hi_fetch.S`；**B1-RAS 返回地址栈**）

> 接 `2026-10-13_session_state.md` / 本日更早的 `2026-10-14_cache_fix_bug1.md`、`..._bug2.md`。
> 本会话做了 v11 §3 任务表的 **覆盖 A**（抓到并修掉一族此前不可达的 RTL bug）、**覆盖 B**、
> 以及 **B1-RAS**（返回地址栈，本轮真正拿分的一项）。**改动未提交**（按约定：里程碑 → 推分支
> → 集成方合并；本机不自动 push）。**B1-RAS 见 §8。**

---

## 1. 一句话

**把 `sim/tests/tb_amo_cpu.S` 从旧 done/UART 协议转成 riscv-tests 的 tohost 判分、摘出
`$skipThese` 进回归；顺手抓到并修掉"AMO/LR/SC 后紧跟分支用陈旧前递值解析方向、把错误路径提交"
的 RTL bug（`ex_flush`/`ex_mispred` 源漏门控 `mem_ready_int`，与约定 56/57 同族的第三条）。**

---

## 2. 本次做了什么

| # | 事项 | 结果 |
|---|---|---|
| 1 | 改写 `sim/tests/tb_amo_cpu.S` 为 tohost 判分（`RVTEST_CODE_BEGIN … RVTEST_PASS/FAIL … RVTEST_CODE_END`；11 个失败分支映射到 `TESTNUM` 1..11）| 测试体逐字不动；scratch 仍取 `0x2000/0x2010/0x2020/0x2030` |
| 2 | `scripts/run_own_tests.ps1` 从 `$skipThese` 摘掉 `tb_amo_cpu`（只剩 `amo_int`/`dep_probe`）| 进回归 |
| 3 | **首次端到端跑 → FAIL(testnum 9)** | 定位到真实 RTL bug（见 §3），**非测试之误** |
| 4 | 修 RTL：`rtl/core/core.v` 的 `ex_flush`/`ex_mispred` 各加 `&& mem_ready_int` | 见 §3.3 |
| 5 | 升 `DESIGN_REV 0x2026_1019 → 0x2026_1020`（`rtl/core/csr_file.v`）| **RTL 动过 ⇒ 上板前必须重出位流** |
| 6 | 跑 v11 §4.2 全回归 + "弄坏能 FAIL" 验证 | 全绿，见 §4 |
| 7 | 文档口径 2→3（v11/v10/`CLAUDE.md`）+ 本报告 | —— |

---

## 3. 发现的 bug：AMO 后紧跟分支走错路径（同族第三条）

### 3.1 现象

双发射默认口径下 `tb_amo_cpu` 落 **`=== FAIL (testnum 9) ===`** = `fail_sc_noq`：
连续第二条 `sc.w`（无预约）本应失败（`a0=0`），却走进了 `bnez a0, fail_sc_noq` 的失败分支。
逐拍 trace（原文见下）：

```
[AMO]   t=2355000 f5=00011 addr=00002020 resv=0 resv_addr=00002020   ← SC 正确判定失败
[FLUSH] t=2355000 pc=00000298 ->0000032c                             ← 但 bnez 解析成 TAKEN
[EX-BR] t=2395000 pc=00000298 rs1v=00000000 rs2v=00000000 taken=0 pred=0  ← 解除冻结后重解析：NOT taken
[WB]    t=2435000 rd=x3 data=00000009                                ← 错误路径 li gp,9 @0x32c 被提交
```

（反汇编：`0x294 = sc.w a0,t4,(t0)`；`0x298 = bnez a0,fail_sc_noq`；`0x32c = li gp,9`；
`TESTNUM = gp = x3`。）

### 3.2 根因

`ex_mem_forward_val = ex_mem_is_amo ? amo_wb_data : …` 在整个 AMO **占住 MEM 的 4 拍**里都无条件
给出 `amo_wb_data`，但该值要到 `ST_WRITE`/`mem_release` 才有效 —— 冻结期间它还是**上一条** AMO 的
陈旧值。于是：

1. 紧跟 AMO 的分支在**第一拍**就用陈旧值（上一条 SC 的 `1`，而非本条的 `0`）解析方向；
2. 解析成 taken ⇒ 拉高 `ex_flush`；而 **`ex_flush` 在 `fetch_addr` 里优先级高于冻结兜底**
   （`core.v` 里 `ex_flush ? ex_target : … : !mem_ready_int ? if_addr_d : …`），取指被拽到错误路径；
3. IF/ID 的冲刷清空**没被 `mem_ready_int` 门控** ⇒ 错误路径**没被丢掉**，放开后提交。

- **数据面消费者（ALU）不受影响**：它被冻在 ID/EX，放开那拍用正确值重算，结果只由"最后一遍"决定。
- **只有控制面（分支/跳转）会踩**：它的解析结果有**组合副作用**（改地址流），一旦泄漏就回不去。
- `sim/tb_amo.v`（单元级）覆盖了"地址不匹配""store 后 SC"，**独缺"SC 后无预约"**这条；
  四条基线（riscv-tests / CoreMark / RT-Thread）**一条 AMO 都没有** ⇒ 该 bug 此前完全不可达。

### 3.3 修法（与约定 56/57 同族：门控的是**源**）

`rtl/core/core.v`：

```verilog
assign ex_flush   = ex_resolve_taken && !id_ex_pred_taken && mem_ready_int;
assign ex_mispred = !ex_resolve_taken && id_ex_pred_taken && mem_ready_int;
```

门控**源**而非某个消费者 ⇒ 一处改动同时覆盖 `fetch_addr` / `pc_r` / IF/ID 冲刷三处；
而 `p_redirect`、ID/EX 清零、EX/MEM（lane B 抑制）本来就已经带 `mem_ready_int`，
在冻结拍源被压 0 后**行为逐位不变**。冻结拍：`fetch_addr` 退回 `if_addr_d`、IF/ID 保持；
放开那拍（`mem_ready_int=1`）再用**正确**的前递值重解析，方向因此总是对的。

`DESIGN_REV → 0x2026_1020`（`rtl/core/csr_file.v` 的注释表已同补一行）。

---

## 4. 回归证据（双发射口径；改 RTL 后 v11 §4.2 全跑）

| 回归 | 命令 | 结果 |
|---|---|---|
| 自写测试（全量） | `run_own_tests.ps1` | **PASS 3 / FAIL 0 / OTHER 0**（`exceptions` / `tb_amo_cpu` / `timer_irq`）；2 → 3 |
| 新增 e2e | `run_own_tests.ps1 -Name tb_amo_cpu` | `=== PASS ===` |
| AMO×Cache | `run_own_tests.ps1 -Name tb_amo_cpu -DCache -ICache -EarlyLd` | `=== PASS ===`（此前无 AMO×Cache 组合测试）|
| riscv-tests | `run_riscv_tests.ps1` | **49 PASS / 1 FAIL(ma_data) / 0 TIMEOUT**（与基线一致）|
| CoreMark | `run_coremark.ps1 -Iter 1 -EarlyLd` | **Total ticks = 232,345**；CRC `e714/1fd7/8e3a/e714` 全对；日志 `RTL=0x20261020` |
| RT-Thread ×4 | `rtthread\run_sim.ps1`（无 / `-DCache` / `-ICache` / `-DCache -ICache`）| **四配置全 PASS**（四条自检全绿）|
| **弄坏能 FAIL** | 临时把 `amo_unit` 的 `F5_AMOMAX` 改成无符号比较 → 跑 `-Name tb_amo_cpu` | **`=== FAIL (testnum 5) ===`**（落 `fail_max`）；`git checkout` 还原后复跑 `=== PASS ===` |

**弄坏步骤的还原已核对**：`rtl/core/amo_unit.v` 与 HEAD 逐字节一致（`git status` 只剩本会话的 4 个文件）。

---

## 5. 遗留 / 下一步

1. **[必须] 重出位流**：本会话动了 RTL（`core.v` + `csr_file.v`），`DESIGN_REV=0x2026_1020`。
   `pds/RV32I_1/mem.hex` 与 `RV32I_1.pds` 提交前需还原（约定）。上板前跑 `build_bitstream.ps1`。
2. **覆盖 B**（v11 §3 下一项）：`sim/tests/hi_fetch.S`（代码 > 32 KB 取指）+ "把 `imem_addr2` 截位
   改回去能 FAIL"验证 —— 与覆盖 A 同一种热身。
3. **可选**：把 §3.2 的最小复现（`sc.w` 后紧跟 `bnez a0`）作为一条独立 `.S` 收进 `sim/tests/`，
   让这条纪律（"AMO 后紧跟控制流"）有更聚焦的守护（当前由 `tb_amo_cpu` 的 `fail_sc_noq` 覆盖）。
4. **BHT 训练的小注**：冻结拍 `id_ex_branch` 仍每拍按（可能陈旧的）`branch_taken` 训练 BHT，
   属**性能**层面的过训练（预测表是建议性的，误预测在非冻结拍会被正常冲刷兜住），**不是**本
   次修的语义 bug；若要一并收紧，可给训练也加 `mem_ready_int`（未做，避免无谓改动基线）。

---

## 6. 本会话改动文件（未提交）

```
 M rtl/core/core.v                 ← ex_flush/ex_mispred 加 && mem_ready_int
 M rtl/core/csr_file.v             ← DESIGN_REV → 0x2026_1020 + 注释表一行
 M scripts/run_own_tests.ps1       ← $skipThese 去掉 tb_amo_cpu
 M sim/tests/tb_amo_cpu.S          ← 旧 done/UART 协议 → tohost 判分
 M doc/reports/2026-10-14_taskbook_v11_cpu.md   ← §3 覆盖A 标完成 + 说明块；§4.2 2→3 PASS
 M doc/reports/2026-10-13_taskbook_v10_cpu.md   ← 速查 2/0 → 3/0
 M CLAUDE.md                       ← 待办新增本修复；口径 2/0 → 3/0
 + doc/reports/2026-10-14_session_state.md      ← 本文件
```

---

## 7. 覆盖 B（同日续做）：`hi_fetch.S` —— 取指越过 0x8000 的回归

**结论：完成了 v11 §3 的覆盖 B，未发现新 bug（符合预期——`imem_addr2` 早已修，只是通路零覆盖）。**

| # | 事项 | 结果 |
|---|---|---|
| 1 | 新增 `sim/tests/hi_fetch.S`（运行时拷贝生成"代码 > 32 KB / 取指越 0x8000"）| 见 §7.1 |
| 2 | 无需改脚本 —— 非 `$skipThese`，按 glob 自动进回归 | —— |
| 3 | 跑覆盖（默认 / `-Single` / `-DCache -ICache -EarlyLd`）| 三配置全 **PASS** |
| 4 | 全量 `run_own_tests.ps1` | **PASS 3 → 4 / FAIL 0 / OTHER 0** |
| 5 | **弄坏能 FAIL**（`imem_addr2` 掩成 `[12:0]`）+ 精确还原 | 见 §7.2 |
| 6 | 文档口径 3→4（v11/v10/`CLAUDE.md`）| —— |

### 7.1 设计与判据

- **为什么非有不可**：64 KB 扩容的全部意义就是让程序能大过 32 KB，但**现有每个程序都远小于它**
  （CoreMark 14,348 B / 裸机五子棋 11,528 B / RT-Thread 25,484 B）⇒ 没有任何程序取指越过 `0x8000`
  ⇒ `imem_addr2` 截位 bug（commit `f72ef25`）当年是**读代码读出来的**，四条基线**一条都盖不住**。
- **地址数学**：lane B 读 word `W+1`；截成 13 位后 = `W + 1 − 8192`。故执行块起点 `D`（word）与毒丸块
  起点 `P` 须满足 `D = 8191 + P`，字节上即 `D_byte = P_byte + 32764`。
- **结构（不改链接脚本）**：毒丸块 `addi s0,s0,1`×N 落 `.text`（0x2000，`la` 运行时算 P）；拷贝源
  `addi t2,t2,1`×N + `jalr` 紧随其后；运行时拷 (N+1) 字到 `0x9FFC`（≥0x8000）→ `fence.i` → `jalr` 过去执行。
- **判据 `s0==0 && t2==N`**：修好后 lane B 取到真正的下一条 `addi t2,t2,1` ⇒ `rd_a(t2)==rs1_b(t2)` ⇒
  **不配对** ⇒ PC 逐字推进、`s0` 恒 0、`t2=N`；截位时 lane B 取到毒丸 ⇒ 配对成立 ⇒ lane B 执行毒丸 ⇒
  **`s0!=0`**（这就是判据）。
- **[订正] N 取 2048**：v11 引文/文档 §7 写的 `N=8191` **放不下 64 KB**（需 `D + N < 16384` ⇒ `N ≤ 6142`）。
  2048 让执行块止于 0xC000、源块止于 0x4004，远离 `0xFFF0` 兼容区。本测试不用 `sp`（序言已清零）。

### 7.2 弄坏能 FAIL（关键：测试不是恒真）

- 临时把 `rtl/core/core.v` 的 `imem_addr2` 改成 **只掩码、不改宽度**：
  ```verilog
  wire [13:0] imem_addr2_breaktmp = imem_addr + 14'd1;
  assign imem_addr2 = {1'b0, imem_addr2_breaktmp[12:0]};   // [临时弄坏]
  ```
  只掩码不改宽度 ⇒ **不触发** `run_own_tests.ps1:99-104` 的端口宽度守卫（比文档建议的"改窄端口+绕守卫"更干净）。
- 结果：`hi_fetch` → **`=== FAIL (testnum 1) ===`**（`s0 != 0`）；
  **同一条弄坏下**低地址测试 `tb_amo_cpu` 仍 **PASS** ⇒ 证明这是"**≥0x8000 取指专属**"的故障（不是把整机弄坏）。
- **[红线做法] 还原用精确 Edit（不是 `git checkout core.v`）**：`core.v` 含**覆盖 A 未提交的修复**，
  `git checkout` 会连它一起抹掉。还原后 `git diff rtl/core/core.v` 核对**只剩覆盖 A 那两行**
  （`ex_flush`/`ex_mispred` + 注释），`imem_addr2` 回到 `imem_addr + 14'd1`；复跑 → **PASS**。

### 7.3 回归证据（未动 RTL；覆盖 B 自身不预期改 RTL）

| 回归 | 命令 | 结果 |
|---|---|---|
| hi_fetch（默认双发射）| `run_own_tests.ps1 -Name hi_fetch` | **PASS** |
| hi_fetch（单发射）| `... -Name hi_fetch -Single` | **PASS**（lane B 不发射，同样过）|
| hi_fetch（I+D Cache + EarlyLd）| `... -Name hi_fetch -DCache -ICache -EarlyLd` | **PASS** |
| 自写测试全量 | `run_own_tests.ps1` | **PASS 4 / FAIL 0 / OTHER 0**（3 → 4）|
| riscv-tests 默认 | `run_riscv_tests.ps1` | **49 / 1 / 0**（= 基线）|
| riscv-tests Cache corner | `... -DCache -ICache -EarlyLd` | **49 / 1 / 0**（= 基线）|

> 未重跑 CoreMark / rtthread：覆盖 B **未动 RTL**（弄坏已精确还原，`git diff` 证明 `core.v` 与覆盖 A
> 提交前逐字节一致），故这四条基线不可能变化。本轮 riscv-tests 两口径已复跑确认无结构性破坏。

### 7.4 覆盖 B 改动文件（追加，未提交）

```
 + sim/tests/hi_fetch.S            ← 新增（本覆盖唯一新文件）
 M doc/reports/2026-10-14_taskbook_v11_cpu.md   ← §3 覆盖B 标完成 + 说明块；§4.2 3→4 PASS
 M doc/reports/2026-10-13_taskbook_v10_cpu.md   ← 速查 3/0 → 4/0
 M CLAUDE.md                       ← 待办新增覆盖B；口径 → 4/0
```

---

## 8. B1-RAS（同日续做）：返回地址栈 —— 本轮真正拿分的一项

**结论：v11 §3 的 B1-RAS 完成。双发射 + `EARLY_LD` 每迭代 232,345 → 229,597 拍（−2,748 / −1.18%），
而 `region commit` 逐位不变 ⇒ 省下的全是返回跳转的冲刷气泡。功能靠 v10 §7 目标校验兜底，四 CRC 全对。**

### 8.1 设计（照批准方案 `harmonic-snacking-pike.md`，v10 §5 + §7）

| 部件 | 位置 | 做法 |
|---|---|---|
| **RAS 存储** | `core.v` BHT 数组后（`RAS_DEPTH=16`）| `ras_mem[0:15]` + `ras_sp`（0..16）；`ras_empty = (ras_sp==0)`；`ras_top = ras_mem[ras_sp[3:0]-4'd1]`（sp=0 时回绕，被 `ras_empty` 挡掉）|
| **到达级读** | `core.v` 到达级预解码 | 新增 `p_rs1_a`/`p_f3_a`；`p_is_ret = opcode==1100111 && f3==000 && rd==x0 && rs1∈{x1,x5}`；`p_ras_hit = p_is_ret && !ras_empty` |
| **目标折入** | `p_pred_taken`/`p_target` | `p_ras_hit` ⇒ `p_target = ras_top`、`p_pred_taken=1` ⇒ 经**既有** `p_redirect` 腿同拍重定向，**不新增 `fetch_addr` 的腿**；`p_pred_taken=1` ⇒ 独占（`pair_now=0`）|
| **EX push/pop** | `core.v` BHT 训练块后 | `ras_upd_en = mem_ready_int && !mc_stall && !trap`（= "这条指令提交进 EX/MEM"那拍）；`call`（`id_ex_jump/id_ex_jump_reg` 且 `id_ex_rd∈{x1,x5}`）push `id_ex_pc+4`；`ret`（`id_ex_jump_reg` 且 `id_ex_rd==x0` 且 `id_ex_rs1∈{x1,x5}`）pop（`!ras_empty`）|
| **§7 目标校验** | `core.v` `ex_flush` | `ret` 的预测目标与真实链接值不符即并入 `ex_flush` 纠正（**功能正确性靠它兜底**）|

- **为什么 push/pop 只由 lane A 驱动**：`p_opcode_b_ok` 只放 OP/OP-IMM/LUI/AUIPC ⇒ lane B 永不是控制指令，
  无"两条控制指令同处 EX"。
- **为什么不需要影子栈**：EX 是顺序的，唯一能冲刷某条指令的是比它更老、已在 EX 的分支/跳转 ⇒ **到达 EX
  = 已在正确路径** ⇒ push/pop 无需回滚。
- **为什么 EX 更新必须门控 `mem_ready_int`**：`!mem_ready_int` 时 ID/EX 保持 ⇒ 不门控会**每拍重复 push/pop**
  （根因 #2 那一族）。`!mc_stall` 同理（div 停顿 ID/EX 保持、EX/MEM 被清，不算提交）。
- **[固有] call 紧邻 ret（相隔 1 条）**：ret 在到达级读栈时 call 还没进 EX ⇒ 读到上一层返回地址 ⇒ 预测错 ⇒
  §7 冲刷纠正（正确、只是没省下气泡）。相隔 ≥2 条即命中。**不是 bug。**

### 8.2 §7 的坑（**关键：时序**）—— 第一次实现把时序打负了

- **第一版**：`wire ex_target_wrong = id_ex_pred_taken && (ex_target != id_ex_pred_target);`。
  跑 PDS 时序 → CPU 域 `u_pll→u_pll` = **−0.271 ns / 66 失败端点**（基线 +0.068/0）。
- **根因**（读 `.rtr` 路径链）：该比较器把 **~2 ns 的 `ex_target` 加法器**（`rs1_val → jalr_target`）
  拽进了**取指临界路径** —— `ex_target` → 比较器 → `ex_flush` → `fetch_addr` mux → `if_addr_d` →
  `imem_addr` → `imem_addr2` → BRAM。最差两条路径（−0.271 / −0.265）全是这条链。
- **改法**（**只对 `ret` 比对、绕开 `ex_target` 加法器**）：
  ```verilog
  wire ex_is_ret_ex   = id_ex_jump_reg && (id_ex_rd == 5'd0);
  wire ex_tgt_mm      = ex_is_ret_ex && ((id_ex_imm != 32'd0) ||
                                         ((rs1_val & 32'hFFFF_FFFE) != id_ex_pred_target));
  wire ex_target_wrong = id_ex_pred_taken && ex_tgt_mm;
  assign ex_flush   = (ex_resolve_taken && !id_ex_pred_taken && mem_ready_int) ||
                      (ex_target_wrong && mem_ready_int);
  ```
  原理：ABI `ret` 的 `imm==0` ⇒ 真实 `ex_target = (rs1_val+0)&~1`，可直接用 `rs1_val`（到达级读到的
  `jalr_target` 等效式）比对，**不经过那个加法器**；`imm≠0` 的 `jalr x0,off(ra)` 极少见，直接**强制冲刷**。
- **结果**：时序 **−0.271/66 → +0.311 ns / 0 失败端点（18,122）**（**优于**基线 +0.068），功能复跑不变
  （own_tests 4/0、CoreMark 229,597 一字不差、四 CRC 全对）。

### 8.3 收益证据（`+PROF` 计时区间）

| 指标 | RAS 前 | RAS 后 | 说明 |
|---|---|---|---|
| `region cycles` | 232,345 | **229,597** | **−2,748 / −1.18%** |
| `region commit` | 214,703 | **214,703** | **逐位不变**（最灵敏探针：提交指令数一条不差 ⇒ 省的全是气泡）|
| `region flush` | 5,645 | **2,452** | 返回跳转不再付 EX 级冲刷气泡 |
| `region cycles/commit`（CPI）| — | 1.069370 | —— |
| 四 CRC | 全对 | **全对** | `seedcrc/crclist/crcmatrix/crcstate` 与基线逐位一致 |

### 8.4 回归（双发射口径；改 RTL 后 v11 §4.2 全跑）

| 回归 | 命令 | 结果 |
|---|---|---|
| riscv-tests 默认 | `run_riscv_tests.ps1` | **49 PASS / 1 FAIL(ma_data) / 0 TIMEOUT**（= 基线）|
| riscv-tests Cache corner | `... -DCache -ICache -EarlyLd` | **49 / 1 / 0**（= 基线）|
| 自写测试全量 | `run_own_tests.ps1` | **4 PASS / 0 FAIL / 0 OTHER** |
| CoreMark | `run_coremark.ps1 -Iter 1 -EarlyLd` | **229,597 拍**；四 CRC 全对；`RTL=0x20261021` |
| RT-Thread ×4 | `rtthread\run_sim.ps1`（无 / `-DCache` / `-ICache` / `-DCache -ICache`）| **四配置全 PASS** |
| **时序** | `report_timing\cpu_top_board.rtr` 的 `u_pll→u_pll` | **+0.311 ns / 0 失败端点（18,122）** |

> **RAS"弄坏能 FAIL"的特别说明**：RAS 预测错会被 §7 **静默纠正** ⇒ **功能测试抓不到"预测错但被纠正"**。
> 故功能正确性靠 **CoreMark 四 CRC + riscv-tests** 兜底（§7 或 push/pop 有错 ⇒ CRC 立刻错）；
> 收益正确性靠 §8.3 的 `commit` 不变 + `cycles` 下降。

### 8.5 B1-RAS 改动文件（追加，未提交）

```
 M rtl/core/core.v                 ← RAS 存储 + 到达级 ret 检测/p_target 折入 + EX push/pop + §7 目标校验
 M rtl/core/csr_file.v             ← DESIGN_REV → 0x2026_1021 + 注释表一行
 M doc/reports/2026-10-14_taskbook_v11_cpu.md   ← §0/§1/§3/§4.2 口径更新 + B1-RAS 说明块
 M CLAUDE.md                       ← 顶部横幅 + 四条并列基线 + 待办 B1-RAS 条目
 M doc/reports/2026-10-14_session_state.md      ← 本文件（标题 + 本 §8）
 M doc/paper/论文框架_v1_20261012.md            ← §0 效率口径 4.304→4.355 + RAS 横幅 + 优化闭环 + 两处自评
 M pds/RV32I_1/RV32I_1.pds         ← PDS 流程态时间戳 churn（提交前 `git checkout` 还原）
```

> **上板前必须重出位流**（`DESIGN_REV=0x2026_1021`）。`pds/RV32I_1/mem.hex` 未动（本会话未跑 CoreMark 固件重生成）。
