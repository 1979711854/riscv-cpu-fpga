# 会话状态 —— 2026-10-16（P2：lane B 访存管道落地，`LANEB_MEM=0`）

> 接 `2026-10-15_session_state_p0p1.md` §6（"P2 是下个会话第一件事"）。
> **本文件取代它 §6 的「下个会话起手」**：P3（翻 `LANEB_MEM=1`）是下一个里程碑。
> 任务书：`2026-10-15_laneb_mem_plan.md`（§4 改动清单 A~L / §6 分阶段 / §7 风险 R1~R8）。

---

## 1. 一句话

**P2 完成**：任务书 §4 的 **A~L 全部落地**，`parameter LANEB_MEM=0`（开关未翻），
**四条 CoreMark 基线逐位不变** —— 证明"新增寄存器/逻辑不扰动既有行为"。
两处对任务书的**刻意偏差**（都是必要的，别当错误修回去）见 §3。
`DESIGN_REV` → `0x2026_1024`。

---

## 2. 判据达成情况（P2 = 四条基线逐位不变）

用 **P0 会话实测值**当对照（不是文档旧值）：

| 配置 | 命令 | 判据 ticks | 实测 ticks | 四 CRC |
|---|---|---|---|---|
| 双发射 + `EARLY_LD`（默认） | `run_coremark.ps1 -Iter 1 -EarlyLd` | 229,597 | **229,597 [OK]** | `e9f5/e714/1fd7/8e3a` [OK] |
| 双发射 + `EARLY_LD=0` | `run_coremark.ps1 -Iter 1` | 249,982 | **249,982 [OK]** | 同 [OK] |
| 单发射 | `run_coremark.ps1 -Iter 1 -Single` | 300,392 | **300,392 [OK]** | 同 [OK] |
| Cache corner | `run_coremark.ps1 -Iter 1 -DCache -ICache -EarlyLd` | 233,013 | **233,013 [OK]** | 同 [OK] |

其余回归（项目纪律）：

| 检查 | 判据 | 实测 |
|---|---|---|
| riscv-tests 默认（双发射 `EARLY_LD=0`） | 49/1/0 | **49/1/0** [OK]（唯一 FAIL = `ma_data` 哨兵） |
| riscv-tests Cache corner | 49/1/0 | **49/1/0** [OK] |
| own_tests（`btb_indirect/exceptions/hi_fetch/tb_amo_cpu/timer_irq`） | 5/0 | **5/0** [OK] |
| CoreMark `+MEMWAIT=1/2`（判四 CRC 不变） | 进行中/待跑 | 见 §7.3 |

**[OK] 结论：P2 判据全部达成，行为零变化。**

---

## 3. 两处对任务书的刻意偏差（别当错误"修回去"）

### 3.1 (B) `p_f7_b` 收窄【门控在 `LANEB_MEM` 上】

任务书写"`p_f7_b != 1` 必须收窄成仅 OP_REG"，**没提门控**。但 `instr[31:25]` 对
**OP_IMM 同样是立即数高位** —— 无条件收窄会顺带放行一批 `addi rd,rs1,0x20` 一类的 OPIMM：

* pairtrace 实测（288,056 条）：`instr[31:25]==0000001` 的 OP_IMM/LUI/AUIPC 共 **7,289** 条，
  其中 **927 条**处于"前一条非 break"的 **lane B 候选位**；
* 这 ~927 对会让 CoreMark **229,597 拍直接变** ⇒ **违反 P2"逐位不变"判据**。

实现（`core.v` 的 `p_f7_b_ok`）：

```verilog
wire p_f7_b_ok = (LANEB_MEM != 0) ? !((p_op_b == 7'b0110011) && (p_f7_b == 7'b0000001))
                                  : (p_f7_b != 7'b0000001);
```

⇒ **0 档逐位回退旧判据；1 档用收窄判据**。模型 ④ 档（`pair_analyze.py`）从 P1 起就按
**收窄后**的规则算，所以 P3 翻开关时"lane B load + 收窄"两件事一起生效，收益口径与
模型 ④（k=87,429）对齐，不会少算。

### 3.2 (H) 任务书的 `trap_pc` 写法有真 bug（**任何档都错**，不只 LANEB_MEM=1）

任务书写 `wire [31:0] trap_pc = ex_exception_a ? id_ex_pc : id_ex_b_pc;`。
**中断**（`int_take`，无同步异常）时 `ex_exception_a=0` ⇒ `trap_pc` 取 `id_ex_b_pc`
⇒ `mepc` 被写成 **lane B 的 PC** ⇒ `mret` 回到错地方。
这条在 `LANEB_MEM=1` 下每次双发射对里发生中断都会炸（`timer_irq` / RT-Thread 抓到），
在 0 档下同样错（只是本会话基线无中断负载，靠 own_tests 的 `timer_irq` 兜住）。

已改为"仅当 lane B 是唯一肇事者才选 B"：

```verilog
wire trap_from_b  = load_misaligned_b && !ex_exception_a;
wire [31:0] trap_pc = trap_from_b ? id_ex_b_pc : id_ex_pc;
```

⇒ 中断恒取 lane A 的 `id_ex_pc`；`LANEB_MEM=0` 时 `load_misaligned_b≡0` ⇒ 逐位回退。

---

## 4. 为什么 `LANEB_MEM=0` 可证"恒 0"（P2 的理论核心）

一条主链 + 四个推论：

* **主链**：`pair_now` 在 0 档不放 lane B load ⇒ `if_id_pair=1` 时 lane B 指令必是
  OP_REG/OP_IMM/LUI/AUIPC ⇒ `control_b` 译出的 `mem_read_b=0`
  ⇒ `id_ex_b_mem_read <= if_id_pair ? mem_read_b : 1'b0` **恒 0**；
* 由此 `ex_mem_b_mem_read ≡ 0` ⇒ (C) `b_mem_sel ≡ 0` ⇒ `mem_re/mem_addr` 逐位不变；
* (E) 停顿子句、 (H) `load_misaligned_b`（⇒ `ex_exception/exc_cause/exc_tval/trap_pc`）、
  (I) `wb_data_b` 的 `wb_sel==01` 腿全部随恒 0 折叠；
* (F) 的 `&& (ex_mem_b_wb_sel != 2'b01)` 在 0 档是**恒真式**（lane B 的 `wb_sel ∈ {00,11}`，
  load 才为 01）；
* (G) 的 `ld_bad_base` 新项自带 `ex_mem_b_mem_read` ⇒ 恒 0。

⇒ **没有任何一条既有行为依赖"新逻辑恰好也算对了"，而是结构上不可达**。这就是 P2
"接线与改行为分离"的价值：出问题能立刻二分到"接线错"vs"行为错"。

---

## 5. A~L 落地清单（全部在 `rtl/core/core.v` + `csr_file.v` + `scripts/pair_analyze.py`）

| 项 | 内容 | 位置 |
|---|---|---|
| **A** | `parameter LANEB_MEM=0`（`A_EXT` 旁）；lane B 新增 `id_ex_b_mem_read/funct3`、`ex_mem_b_mem_read/funct3`、`mem_wb_b_funct3/addr_low` | 参数区 / 寄存器声明区 |
| **B** | `p_mem_a`/`p_ld_b`；`p_opcode_b_ok += (LANEB_MEM!=0) && p_ld_b`；`pair_now += !(p_mem_a && p_ld_b)`；`p_f7_b_ok`（见 §3.1） | 到达级配对 |
| **C** | `b_mem_sel = ex_mem_b_valid && ex_mem_b_mem_read`；`mem_re/mem_addr` 加 B 腿（`mem_we` 不动）；R6 注释（为什么 read 不加 `!ex_flush`、靠 valid 门控） | 访存口 |
| **D** | `mem_wdata/mem_byte_en` **不动**（lane B 不放 store） | — |
| **E** | load-use 停顿新增 lane B 生产者子句（与 lane A 同构 + `if_id_pair` 门控；无需 `!ld_fast`） | `stall` |
| **F** | 四个 `fwd_*_exb` + `ld_f_exb` 各加 `&& (ex_mem_b_wb_sel != 2'b01)`（R1） | 前递网 / AGU |
| **G** | `ld_bad_base` 加 `ex_mem_b` 是 load 的子句（R2） | AGU |
| **H** | `load_misaligned_b`（地址 = `alu_result_b`）；`ex_exception_a` 拆出；`exc_cause/exc_tval` 扩展；`trap_pc`（见 §3.2）；`csr_file` 例化 `.trap_pc(trap_pc)`；重放安全性论证注释（5 条） | 异常段 / EX/MEM 段 |
| **I** | 并行 `load_data_b` 解包（复用同一 `load_src`，不串在时序敏感链上）；`wb_data_b` 加 `01` 腿；删过时注释 | WB 段 |
| **J** | 四处级间寄存器清/锁存/复位全分支（见 §6） | ID/EX、EX/MEM、MEM/WB |
| **K** | `DESIGN_REV` `0x2026_1023` → `0x2026_1024` + 历史行 | `csr_file.v` |
| **L** | `pair_analyze.py` 头注释写死"RTL 双档 ↔ 模型 1 档"的口径同步 | `scripts/` |

另外更新了两处**已过时的假设注释**（`u_ctrl_b` 的"lane B 只可能是 ALU 类"、
`ex_mem_forward_val_b` 的"lane B 结构上不会是 load"），避免后人被注释误导。

---

## 6. R4 对照表：四处级间寄存器的每个分支（本会话逐行核对）

| 寄存器 | 清/复位分支 | 锁存/推进分支 |
|---|---|---|
| **ID/EX** | `id_ex_b_mem_read<=0; id_ex_b_funct3<=0`（trap/flush/stall 清，1633 行区块） | `id_ex_b_mem_read <= if_id_pair ? mem_read_b : 1'b0; id_ex_b_funct3 <= if_id_instr_b[14:12]` |
| **EX/MEM** | `ex_mem_b_mem_read<=0; ex_mem_b_funct3<=0`（trap/mc_stall 清） | `ex_mem_b_mem_read <= id_ex_b_mem_read; ex_mem_b_funct3 <= id_ex_b_funct3`（**read 不加 `!ex_flush`，R6 承重注释在旁**） |
| **MEM/WB** | `mem_wb_b_funct3<=0; mem_wb_b_addr_low<=0`（复位） | `mem_wb_b_funct3 <= ex_mem_b_funct3; mem_wb_b_addr_low <= ex_mem_b_alu_result[1:0]` |

> `mem_ready=0` 冻结期的"保持"语义无需新字段 —— 保持分支本来就不赋值，新字段随块冻结。

---

## 7. 验证记录（可复现命令）

### 7.1 四条基线（本会话实测，全部逐位命中）

```powershell
scripts\run_coremark.ps1 -Iter 1 -EarlyLd                # 229,597 / e9f5 e714 1fd7 8e3a
scripts\run_coremark.ps1 -Iter 1                          # 249,982 / 同 CRC
scripts\run_coremark.ps1 -Iter 1 -Single                  # 300,392 / 同 CRC
scripts\run_coremark.ps1 -Iter 1 -DCache -ICache -EarlyLd # 233,013 / 同 CRC
```

### 7.2 其余

```powershell
scripts\run_riscv_tests.ps1                        # 49/1/0
scripts\run_riscv_tests.ps1 -DCache -ICache -EarlyLd  # 49/1/0
scripts\run_own_tests.ps1                           # 5/0（含 exceptions / timer_irq）
```

### 7.3 MEMWAIT 停顿注入（纪律项，判"四 CRC 不变"）

`+MEMWAIT=1/2` 在跑/待跑（停顿注入使仿真慢数倍）。结果补记于此表：

| 配置 | 四 CRC | 结论 |
|---|---|---|
| `+MEMWAIT=1` | 待补 | 待补 |
| `+MEMWAIT=2` | 待补 | 待补 |

---

## 8. 环境坑（新发现，与 RTL 无关）：PS 5.1 下回归脚本被链接器警告打断

* **现象**：`run_coremark.ps1` / `run_own_tests.ps1` 在 PowerShell **5.1** 下跑到
  `riscv-none-elf-gcc` 链接阶段就中断 —— `ld` 往 stderr 打一行
  `warning: ... has a LOAD segment with RWX permissions`，而脚本设了
  `$ErrorActionPreference = "Stop"` ⇒ 原生命令的 stderr 变成**终态错误**
  （`NativeCommandError`），脚本当场死。（`run_riscv_tests.ps1` 不受影响：它用随附预编译 ELF。）
* **本会话的绕过**：先让脚本把 ELF 构建出来（或 `-SkipBuild` 复用），再手工
  `iverilog`（显式文件列表 + `-D` 开关）+ `vvp`（`+MEMWAIT=n`），输出落盘取判据行。
  **四条基线与 49/1/0、5/0 都是这么跑出来的，口径与脚本一致**（`SIM CONFIG` 首行自证）。
* **建议后续修**（单独一个提交，别混进 RTL）：gcc 调用加 `2>$null`，或把构建段包进
  `try { ... } catch` 里过滤 RWX 警告。**这不是 RTL 问题，换台机器/PS 7 可能不复现。**

---

## 9. 跑分回答（用户当面问过，留档）

**分数不变。** P2 是"接线在位、开关没翻"，四条基线的 `Total ticks` 逐位相同：

* @85.0051 MHz：**370.2 分**（229,597 拍/迭代；`1e6/229597 = 4.3555 CoreMark/MHz`）；
* 板上最近实测：**370.31 分**（`55fae69e`，rev1023，`RTL=0x20261023`）；
* **LUT / Fmax 本会话未重新综合测量** —— 预计 LUT **略增**（新增 13 bit 级间寄存器 +
  访存口/前递/异常各处 mux 腿，综合器无法证明它们不可达），PDS 测量是 P4 闸门项
  （方案 A 盈亏平衡 **82.09 MHz**，已按新计分规则降级为"看掉多少、值不值"）。

---

## 10. P3 起手（下个会话第一件事）

1. **先写定向用例再翻开关**（R1/R2 是"静默错值"类，基线抓不到）：
   * R1：lane B load 紧跟一条依赖它的指令（验 (F) 的门控）；
   * R2：指针追逐 —— lane A load 的基址来自同拍 lane B load（验 (G) 的 `ld_bad_base`）；
   * 未对齐：lane B 的 `lh/lw` 地址错位（验 (H)，注意 `ma_data` 本来就是 FAIL，别被它掩盖）。
2. 翻 `core.v` 的 `parameter LANEB_MEM = 1`（一处）；
3. 判据（任务书 §6 P3）：**riscv-tests 49/1/0 + 四 CRC 逐位一致 + cycles 显著下降**；
   **别拿模型 6.0% 当 go/no-go**（模型两个盲区：lane B load 的 load-use 停顿 + ~5% 固有乐观度）；
4. P4 清单：`+MEMWAIT=1/2`、Cache 各配置、**RT-Thread 四配置**（需先按 `-Sim` 口径重建固件，
   现在 `scripts/rtthread/build/` 里是板级标定版、`.sim_build_ok` 标记缺失）、PDS 量时序。

---

## 11. 未决 / 遗留

* `tb_rvc` 的 10 项 FAIL 处置未决（修位域 / 连 `rvc_expand.v` 一起删）—— 上一会话遗留；
* RT-Thread 仿真本会话**未跑**（见 §10.4；四条基线 + 49/1/0×2 + 5/0 已覆盖全部改动路径，
  但按约定 55 的教训，翻开关后必须补）；
* §8 的脚本脆弱性待修；
* **未 push**（项目纪律：不自动 push）。
