# riscv-tests 补测结果（RV32I_1 流水线 CPU）

日期：2026-09-10
方法：不改 CPU、不改 riscv-tests 仓库；用 elf2mem.py 把 ELF 拆成 imem.hex / dmem.hex，
     重新链接到 0x0 地址（link.ld），testbench 监控 tohost 写判定 PASS/FAIL。

## 总结果

| 分类 | 数量 | 测试 |
|------|------|------|
| PASS | 36 | add addi and andi auipc beq bge bgeu blt bltu bne jal jalr lb lbu lh lhu lui lw or ori simple sll slli slt slti sltiu sltu sra srai srl srli st_ld sub xor xori |
| FAIL | 4 | ma_data、sb、sh、sw |
| TIMEOUT | 2 | fence_i、ld_st |

---

## 1. ma_data —— FAIL (testnum 1)【架构限制，非 bug】

`ma_data` 测试未对齐访问（`lh/lhu/lw` 从 `+1/+2/+3` 地址读）。当前 CPU 只支持对齐访问：

- `dmem_addr = ex_mem_alu_result[14:2]` 直接丢掉低 2 位，按字地址取整。
- `lh` 的 `load_half = addr_low[1] ? dmem_rd[31:16] : dmem_rd[15:0]` 只对偶地址正确，
  奇地址（addr_low=1）实际应取 bytes[1:2]，当前取 bytes[0:1]。
- `lw` 从未对齐地址会跨字，当前无法重拼。

RISC-V 规范允许实现不处理未对齐访问（可选），简单 CPU 通常直接不支持。
**判定：架构限制，预期失败，不改。**

## 2. sb / sh / sw —— FAIL (testnum 11)【CPU 流水线 bug，需修】

三者都是 TEST_CASE 11 "unaligned base" 失败，根因相同。

### 触发代码（以 sb 为例）

```asm
la  x1, tdat9        # auipc ra + addi ra,-828  → x1 = 0x2008
li  x2, 0x00003098   # lui sp + addi sp,152      → x2 = 0x3098
addi x1, x1, -6      # x1 = 0x2002
sb  x2, 7(x1)        # 应存到 0x2002+7 = 0x2009 (tdat10)
la  x4, tdat10
lb  x5, 0(x4)        # 期望 0x98 符号扩展 = 0xffffff98
```

### 现象

`sb` 实际写到了 **0x2003** 而不是 0x2009。跟踪 WB 发现 `x1` 多了一次异常写入：

```
x1 = 0x2008   (addi ra,-828)
x1 = 0x2002   (addi ra,-6)
x1 = 0x1ffc   (addi ra,-6 被重复执行了一次！ 0x2002-6)
```

`sb` 读到的 `x1=0x1ffc`，`0x1ffc+7=0x2003`，所以写错地址。

### 根因：取指流水线在 stall 期间被重复取指，导致指令在流水线里"复制"成两份

core.v 里 stall 时：

```verilog
else if (stall) pc_r <= if_id_pc + 32'd4;   // 把 PC 退回到"在途指令"地址
```

但 `imem_rd` / `if_addr_d`（两级取指寄存器）**没有被 stall 住**，仍然每拍跟着 pc_r 走。
于是**连续 2 拍的 stall**（例如 `lui` 写 sp、下一条 `addi sp,sp,imm` 读 sp 造成的 RAW 停顿）
会让 `pc_r` 连续两拍停在同一个地址，导致同一条指令（如 `lui sp`）被取指两次。

级联后果：被复制的是 `addi ra,-6`（非幂等），它执行了两遍，`ra` 被多减了一次 6，
后随的 `sb` 就用了错的 `ra`。对 `lui` 这种幂等指令（复制两遍写同一个值）无感，所以
前面 test 2~10 都 PASS，只有 test 11 里被复制的恰好是 `addi` 才暴露。

### 结论

**stall 与两级取指延迟（imem 同步读 1 拍 + if_id 1 拍）不兼容**。修法方向（以后改）：
- stall 时让取指寄存器 `imem_rd`/`if_addr_d` 也保持/插入气泡，而不是靠"退 pc_r"来补；
- 或把取指延迟改回 1 拍（消除 `if_addr_d`/`ex_flush_d` 那套补偿逻辑）。

## 3. fence_i —— TIMEOUT【架构限制，非 bug】

`fence_i` 做自修改代码：先 `sh` 改代码区，再 `fence.i`，再 `jalr` 跳到被改的代码。
当前是哈佛结构（imem/dmem 分开），store 只写 dmem，取指只读 imem，改代码永远看不见；
`fence.i` 在 control.v 里也是 no-op。所以测试挂死。
**判定：哈佛结构固有限制，不改。**

## 4. ld_st —— TIMEOUT（两个问题）

### 4a. testbench 的 tohost 地址写死了 0x1000【测试台 bug，不是 CPU】

`ld_st` 的 `.text.init` 超过 0x1000，link.ld 里 `.tohost` 被 ALIGN 到 **0x2000**。
但 `cpu_tb_riscv.v` 里 `TOHOST_ADDR = 32'h1000` 写死，监控地址错了，错过 tohost 写。
其它测试 `.text.init` 都 <0x1000，tohost 在 0x1000，所以只有 ld_st 踩到。

实测 `ld_st` CPU 已经跑进 fail 循环（PC 停在 0x1014 `beqz zero,1014`），
也就是它其实 **FAIL** 了（fail 例程往 tohost=0x2000 写，被 testbench 漏掉才显示 TIMEOUT）。

### 4b. ld_st 为什么 fail —— 大概率同 bug 2

ld_st 是 load-use 密集的 bypass 测试，`lw` 后立刻用结果会频繁触发 2 拍 stall，
正是 bug 2 的触发条件，导致指令被复制、数据/控制流错乱，最终跳进 fail 而不是 pass。

### 结论

- 测试台需把 tohost 地址改成从 ELF 里读（elf2mem.py 已经打印 `tohost = 0x...`），
  而不是硬编码 0x1000。
- 修掉 bug 2 后 ld_st 才能真 PASS。

---

## 给以后修 CPU 的优先级

1. **修 stall/取指重复 bug（bug 2）** —— 影响 sb/sh/sw，且是 ld_st fail 的根因。
2. **修 testbench 的 tohost 地址**（从 ELF 读，别硬编码）—— 否则 ld_st 这类大代码测试结果不可信。
3. ma_data（未对齐）和 fence_i（自修改代码）是架构限制，不修。
