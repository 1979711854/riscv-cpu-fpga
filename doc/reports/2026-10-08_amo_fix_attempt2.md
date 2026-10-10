# 方案 A 失败的复盘：AMO 写回缺陷比预想的深

> 时间：2026-10-08（承接 `ecf2f07` 的记录继续修）
> 结论：**方案 A 被实验证伪，已revert（`424bd58`）**。缺陷仍未修，但定位到了确切层。

## 一、方案 A 为什么失败

方案 A 原文是「MEM/WB 推进条件加 `!mc_stall`」。实施后CoreMark 从313,886 变成**跑不出结果**。

原因：`amo_stall = (st != ST_IDLE)`，而 AMO 的写回值在 `ST_WRITE` 拍就已有效——
那一拍 `st` 还是 `ST_WRITE`，所以 `amo_stall` 仍为 1。MEM/WB 被冻结 ⇒ 永远等不到放行 ⇒ **死锁**。

补了个 `amo_done = (st == ST_WRITE)` 放行那一拍，仍然跑不出结果。**方案 A 方向本身错了。**

## 二、真正的问题层级（逐层测量，不是推测）

我按你的方案试完后，改用**逐层测量**而不是继续推理，得到三个事实：

| 测量 | 结果 | 说明 |
|---|---|---|
| 固件里`amoadd.w` | **5 条** | AMO 确实进了二进制 |
| `[pong]` 出现次数 | **1 次**（软原子下 7 次） | 第一次 ping/pong 之后就停 |
| 最终 `pc` | `0x40d0` = `rt_hw_interrupt_enable` | 停在临界区恢复处 |
| `rt_tick`（0x5748）| **0** | **系统 tick 从未递增** |
| `amo_mem_we` 计数 | **46852 次** | AMO 写口一直在动|
| 写入数据 | **`xxxxxxxx`** | **写进内存的是 X** |

最后两行是关键：**AMO 一直在写，但写的是 X**。

## 三、定位到的三个真实缺陷

### 缺陷1：AMO 的总线地址取错了（已确认）

```verilog
assign mem_addr = ex_mem_alu_result;   // ← 对 AMO 是错的
```

AMO 的地址语义是 **rs1**，不是 `rs1+imm`。而 `ex_mem_alu_result = alu_result = rs1+imm`。
更要命的是 `amo_stall` 期间 EX/MEM 被清成气泡 ⇒ `ex_mem_alu_result` **归 0**
⇒ `ST_WRITE` 拍写到了**地址 0**，不是 `0x5748`。

修正：`assign mem_addr = (ex_mem_is_amo || amo_stall) ? <AMO 锁存的地址> : ex_mem_alu_result;`

注意：**只能用 `amo_unit` 内部锁存的 `amo_addr_r`**，因为 `ex_mem_amo_addr`
同样会被 mc_stall 清零。

### 缺陷 2：AMO 的元数据只活一拍（已确认）

AMO 落在 MEM 那一拍，MEM/WB 装走它的 `rd`/`reg_write`；下一拍 EX/MEM 被清成气泡，
MEM/WB 装的是气泡。所以「AMO 的写回目标」在 4 拍里只有第1 拍是对的。

这正是方案 A 想解决的问题，但方案 A 的解法（冻结 MEM/WB）会死锁。
**正解是方案 B：AMO 自己锁 `rd`，在 `ST_WRITE` 拍用独立写口直接写寄存器堆。**

### 缺陷 3：寄存器堆写口不够（已确认）

我把方案 B 的 `reg_we` 先or 到 A 口上，结果仍然挂。原因：

> `regfile` 只有 A/B 两个写口。A 口给 MEM/WB，B 口给 lane B。
> AMO 落地的同一拍，MEM/WB 里正好是它前面那条指令 —— **两路同写，优先级会吞掉一路**。
> RT-Thread 的 `rt_interrupt_enter()` 里 `amoadd.w` 紧跟 `ret`，正撞这个窗口。

正解：给 regfile 加**第三个物理写口 C**，AMO 独占。

## 四、为什么最后仍然没修好

三处改动都做了，但**写进去的仍然是 X**（`last_amo_data=xxxxxxxx`）。

`amo_wdata = fused = f(mem_rdata, amo_rs2_r)`。既然写的是 X，
说明 `mem_rdata` 在 `ST_LATCH` 拍是 X —— 即 **BRAM 读出无效**。

这一层我**没有继续查下去**。原因是我已经在同一问题上连做了 6~7 轮改动
（方案 A →加 amo_done → 方案 B →加写口 C → 改 mem_addr → 加 csr_wr_en 门控），
每轮都基于推测而非测量，其中 csr_wr_en 那轮纯属误判（加了门控症状完全没变）。

**正确的下一步应该是**：写一个只跑一条 `amoadd.w` 的最小CPU 级测试台，
逐拍打印 `amo_stall / st / mem_addr / mem_re / mem_rdata / amo_addr_r`，
先证明「单条 AMO 在流水线里读得到数据」，再谈系统级。

## 五、当前状态

- 已 `git revert` 方案 A（提交 `424bd58`），工作树 = `ecf2f07` 状态
- **RT-Thread 回归 4 OK / 0 FAIL**，固件 AMO 指令数 0（走软原子）
- riscv-tests 与 CoreMark 不受影响（A 扩展对非 AMO 路径零影响，此前已逐位验证）
- **缺陷仍未修**，`doc/reports/2026-10-08_amo_wb_bug.md` 里的记录仍然有效

## 六、教训

> **我这次的表现不合格的地方**：连续 6 轮改动，每轮都靠「推理出一个可能原因 → 改 → 跑一次」。
> 正确做法是第1 轮就上最小复现（单条 AMO + 逐拍打印），
> 把「单条 AMO 是否正确」和「系统里是否正确」这两件事分开验证。
>
> 单元测试 17/17 全过恰恰说明问题不在 `amo_unit` 模块内——
> **模块是对的，错的是它与流水线的接口**。这类问题只能靠系统级逐拍 trace 定位，
> 不能靠读代码想出来。
