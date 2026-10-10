# 交接任务书 A · RV32A 原子指令扩展（修复版）

> 日期：2026-10-08　工程：`D:\riscv-cpu-fpga_ac`（分支 `master`，基线提交 `ca72bab`）
> 前置阅读：`doc/reports/2026-10-08_amo_wb_bug.md`、`doc/reports/2026-10-08_amo_fix_attempt2.md`
> **本文自包含** —— 只跑仿真就能把这里的活全干完，不需要板子。

---

## 0. 一句话现状

**AMO/LR/SC 的模块已经写完且单元测试 17/17 全过，但接进流水线后是坏的。**
RT-Thread 一旦切到硬件原子就死锁（`rt_tick` 永远是 0）。

**你不需要重写模块 —— 模块是对的。错的是它和流水线的接口。**

### 已经做到的（不是待办）

| 项 | 状态 |
|---|---|
| `rtl/core/amo_unit.v`（185 行）| **完成**，四拍状态机 READ→HOLD→LATCH→WRITE |
| 单元测试 `sim/tb_amo.v` | **17/17 全过**（11 个操作 + LR/SC 配对 + 3 条 SC 失败路径）|
| `control.v` AMO 译码 | **完成**（opcode `0101111`，`funct3=011` 判非法）|
| riscv-tests | **49 PASS / 1 FAIL / 0 TIMEOUT**，与基线完全一致 |
| CoreMark | **313,886 拍逐位一致**，四个 CRC 全同 |
| RT-Thread（软原子）| **4 OK / 0 FAIL**，banner + tick + ping/pong 7 轮 |

> [!] **riscv-tests 和 CoreMark 里没有一条 AMO 指令**（测试是 `rv32i_zicsr_zifencei`）。
> 所以上面两个"全过"只证明**非AMO 路径没被破坏**，不证明 AMO 能用。
> 这是本任务存在的根本原因。

### 硬指标（改坏了就是不合格）

```
riscv-tests   49 PASS / 1 FAIL / 0 TIMEOUT
CoreMark      Total ticks = 313,886（逐位一致）
RT-Thread     4 OK / 0 FAIL（软原子基线，不得退化）
AMO 单元测试  17/17
```

---

## 1. 三条命令开工

```powershell
cd D:\riscv-cpu-fpga_ac
scripts\run_riscv_tests.ps1          # 必须 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_coremark.ps1 -Iter 1     # 必须 Total ticks = 313,886
scripts\rtthread\run_sim.ps1         # 必须 4 OK / 0 FAIL
```

---

## 2. [!] 先读这一条：**两个会让你白跑小时的坑**

### 坑 1：CoreMark 的 vvp 必须带参数

```powershell
# 正确
cd sim; vvp tb_coremark_dual.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
# 错误（会跑 12 分钟不出结果，你以为死锁了，其实是没加载 hex）
vvp tb_coremark_dual.vvp
```

**动手前先跑一次基线确认能出结果。** 我本人因为漏这个参数，
先后两次误判「方案 A 引入死锁」——实际基线也一样跑不出来。

### 坑 2：RT-Thread 默认走**软原子**，AMO 根本没进固件

```powershell
# 查固件里到底有没有 AMO（应为 0）
scripts\rtthread\build.ps1
riscv-none-elf-objdump -d scripts\rtthread\build\rtthread.elf | Select-String "amo|lr\.w|sc\.w"
```

要测硬件原子，必须同时做三件事：

```powershell
# 1) build.ps1：-march 加 a
#    "-march=rv32im_zicsr_zifencei"  ->  "-march=rv32ima_zicsr_zifencei"
# 2) build.ps1：$excludeC 里删掉 'atomic_riscv.c'
#    （它无条件用 amoswap.w / lr.w / sc.w，没 A 扩展会报 "extension 'zaamo' required"）
# 3) bsp\rtconfig.h：加一行
#    #define RT_USING_STDC_ATOMIC
scripts\rtthread\run_sim.ps1
```

改完这三处，`objdump` 应该能看到 **5 条 `amoadd.w`**。**看不到就是没改对。**

---

## 3. 任务清单

| # | 任务 | 优先级 | 状态 |
|---|---|---|---|
| **T0** | 写最小复现：单条 `amoadd.w` 的 CPU 级逐拍 trace | **P0** | 未开始 |
| **T1** | 修 `mem_addr`：AMO 的总线地址取错 | **P0** | 未开始 |
| **T2** | 给 `regfile` 加第三个写口 C，AMO 独占 | **P0** | 未开始 |
| **T3** | AMO 自持写回（不借道 MEM/WB）| **P0** | 未开始 |
| **T4** | RT-Thread 硬件原子下4 OK / 0 FAIL | **P0** | 未开始 |

**T0 必须先做。** 原因见 §5。

---

## 4. 任务详情

### T0 · 最小复现（**先做这个，别跳过**）

**新建 `sim/tb_amo_int.v`**，只跑一条 `amoadd.w`，逐拍打印：

```verilog
always @(posedge clk) begin
    $display("[cyc=%0d] pc=%h st=%0d amo_stall=%0d ex_mem_is_amo=%0d "
             "amo_addr_r=%h bus_addr=%h mem_re=%0d mem_we=%0d mem_rdata=%h amo_wdata=%h",
             cyc, pc, u_core.u_amo.st, u_core.amo_stall, u_core.ex_mem_is_amo,
             u_core.u_amo.amo_addr_r, u_soc.mem_addr, u_soc.mem_re, u_soc.mem_we,
             u_soc.mem_rdata, u_core.amo_wdata);
end
```

**判据**：`mem_rdata` 在 `ST_LATCH` 那一拍必须是**有效数据**（不是 `xxxxxxxx`）。

**实测结论（2026-10-08，写给你省时间）**：修完 T1~T3 之后，
`amo_mem_we` 确实触发了 46852 次，但 `amo_wdata` **仍然是 `xxxxxxxx`**。
**所以真正的病灶是「BRAM 读出为 X」**，T0 的trace 会直接指出来。

> [!] 我上一轮跳过了 T0，直接推理原因改了 6~7 处，全都没修好。
> **不要重复这个错误。**

### T1 · `mem_addr` 对 AMO 是错的

**文件**：`rtl/core/core.v:196`

```verilog
assign mem_addr = ex_mem_alu_result;     // ← 对 AMO 是错的
```

AMO 的地址语义是 **rs1**，不是 `rs1+imm`。而 `ex_mem_alu_result = alu_result = rs1+imm`。

更要命的是：`amo_stall` 期间 EX/MEM 会被清成气泡 ⇒ `ex_mem_alu_result` **归 0**
⇒ `ST_WRITE` 拍写到了**地址 0**，而不是 `0x5748`。

**改法**：

```verilog
assign mem_addr = (ex_mem_is_amo || amo_stall) ? <AMO 锁存的地址> : ex_mem_alu_result;
```

> [!] **只能用 `amo_unit` 内部锁存的 `amo_addr_r`**，不能�� `ex_mem_amo_addr`——
> 它同样会被 mc_stall 清零。所以要给 `amo_unit` 加一个 `output [31:0] bus_addr`。

**验收**：T0 的 trace 里 `bus_addr` 必须等于 `amo_addr_r`，且等于预期地址。

### T2 · `regfile` 只有两个写口

**文件**：`rtl/core/regfile.v:52-53`

```verilog
if (we_a && (rd_a != 5'd0)) rf[rd_a] <= wd_a;
if (we_b && (rd_b != 5'd0)) rf[rd_b] <= wd_b;   // B 后写 ⇒ 同址时 B 赢
```

A 口给 MEM/WB，B 口给 lane B。**AMO 挤 A 口时，同拍 MEM/WB 里正好是它前一条指令，
两路同写、优先级吞掉一路。**

RT-Thread 的 `rt_interrupt_enter()` 里 `amoadd.w` **紧跟 `ret`**，正撞这个窗口：

```
0000118c <rt_interrupt_enter>:
    1194:  addi  a5,a5,-1812# 58ec <rt_interrupt_nest>
    1198:  amoadd.w.aqrl  zero,a4,(a5)      ← AMO
    119c:  ret                              ← 同一拍进 MEM/WB
```

**改法**：加**第三个物理写口 C**（AMO 独占）。不要用 or 合并到 A/B。
读转发（`rdata1_a/rdata2_a` 的 bypass）也要考虑 C口，见`regfile.v:59-62`。

**验收**：综合后 `regfile` 有 3 个写口；CoreMark 仍 313,886。

### T3 · AMO 自持写回（方案 B）

**问题**：AMO 的元数据（`rd` / `reg_write`）**只活一拍**——
只有落在 MEM 那一拍 MEM/WB 才装到正确值，下一拍 EX/MEM 被清成气泡，MEM/WB 装的就是气泡。

**已验证失败的方案**：

> [!] **方案 A（冻结 MEM/WB）已被实验证伪，别再尝试。**
> 把 MEM/WB 推进条件改成 `mem_ready && !mc_stall` 会**死锁**：
> `amo_stall = (st != ST_IDLE)`，而写回值在 `ST_WRITE` 拍已有效，
> 但那一拍 `st` 还是 `ST_WRITE` ⇒ `amo_stall` 仍为 1 ⇒ MEM/WB 永远等不到放行。
> 补一个 `amo_done = (st == ST_WRITE)` 放行那一拍，**仍然跑不出结果**。
> 详见 `doc/reports/2026-10-08_amo_fix_attempt2.md`。

**正确做法**：`amo_unit` 自己锁 `rd`，在 `ST_WRITE` 拍用 T2 的写口 C 直接写寄存器堆，
**完全不借道 MEM/WB**。

需要加的端口：

```verilog
input  wire [4:0]  rd,// 目标寄存器
output wire        reg_we,     // 单拍脉冲：只在 ST_WRITE 为 1
output wire [4:0]  reg_rd,
output wire [31:0] bus_addr,   // 给 core 的 mem_addr 用（见 T1）
```

内部：`IDLE` 拍锁 `amo_rd_r`；`assign reg_we = (st == ST_WRITE) && (amo_rd_r != 5'd0);`

> [!] **`reg_we` 必须是单拍脉冲**，不能是电平。同址时优先级会让 A/B 赢，
> AMO 写回会丢。

### T4 · 端到端验收

| 验证 | 判据 |
|---|---|
| `sim/tb_amo.v` | **17/17** |
| T0 新增的 trace | `mem_rdata` 在 LATCH 拍有效 |
| `scripts\run_riscv_tests.ps1` | **49 PASS / 1 FAIL / 0 TIMEOUT** |
| `scripts\run_coremark.ps1 -Iter 1` | **313,886** |
| `scripts\rtthread\run_sim.ps1`（软原子）| **4 OK / 0 FAIL** |
| `scripts\rtthread\run_sim.ps1`（硬件原子）| **4 OK / 0 FAIL** + 固件 5 条 `amoadd.w` |

---

## 5. [!] 方法论：本任务为什么会存在

**单元测试 17/17 全过，但模块接进流水线就是坏的。**

这不是偶然，是这类问题的必然：

| 测试 | 覆盖了什么 | 没覆盖什么 |
|---|---|---|
| `tb_amo.v` | `amo_unit` 模块逻辑 | **流水线级间寄存器** |
| riscv-tests | 标准 RV32I | **没有一条 AMO 指令** |
| CoreMark | 密集用 mul/div | **不碰原子指令** |
| RT-Thread（软原子）| 真实 OS | **关中断做临界区，不用 AMO** |

**唯一的验收标准是「真实软件用硬件原子跑起来」。**

> **纪律**：
> 1. **先写最小复现**，再改代码。不要靠读代码推理原因。
> 2. **每改一处就重跑四条基线**，不要攒到最后。
> 3. 改动前先 `git commit` 一个能跑的状态，随时能回退。
> 4. 报"修好了"之前，**必须**有 RT-Thread 硬件原子的 4 OK / 0 FAIL。

---

## 6. 已知会踩的坑

### 6.1 `core.v` 是 CRLF 行尾

Edit 工具按 LF 匹配会**静默失败**（报"Successfully edited"但没落盘）。
改完必须 `grep` 复查；不可靠时用 Python 按字节读写。

### 6.2 Verilog 拼接位数不等于 32 **不报错**

`iverilog` 不会警告，只会左侧补 0、字段静默错位。
本项目已有一个审计器可以复用：

```powershell
python scripts\audit_rvc_width.py     # 检查每条 {a,b,...} 是否恰好 32 位
```

> 这是我在 C 扩展上栽了三次的坑（漏 funct7 → 30 位、多塞 `1'b0` → 33 位、
> 立即数越界 → X 传播出 4106 个 X）。**写位域密集的 RTL，先写审计器。**

### 6.3 改 `build.ps1` 用 Python 按字节改

Windows PowerShell 5.1 读无 BOM 的 `.ps1` 会按 GBK 解，中文字面量会让引号配对失效、
报"missing )"。改完 `grep` 复查。

---

## 7. 交付

```powershell
git log --oneline        # 每个提交都要能编译+跑通基线
git status               # 干净
```

提交信息里请写清：**改了哪一处、为什么、四条基线的实测数字**。

**没跑通 RT-Thread 硬件原子 = 没做完。**

---

## 8. 还没解决的（不在本任务范围）

- **C 扩展解码器只有 22/32 项通过**（`rtl/core/rvc_expand.v`），`c.addi16sp` 与
  `c.j/jal/beqz/bnez` 的立即数位序还没对。**与 A 扩展完全无关**，别混进来。
- 32 KB 没有 MMU，**只有 M 模式**，`mstatus.MPP` 硬编码。多核/SMP 不可能。