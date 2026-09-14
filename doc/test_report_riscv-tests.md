# riscv-tests 回归报告（RV32I 五级流水线 CPU）

最近更新：2026-09-15
方法：不改 CPU、不改 riscv-tests 仓库；`scripts/elf2mem.py` 把 ELF 拆成
     `imem.hex` / `dmem.hex`（另出合并的 `mem.hex`），`sim/tb_riscv.v` 监控
     core 对 tohost 的 store，判定 PASS / FAIL / TIMEOUT。

运行方式：

```powershell
# 直接跑即可 —— 会自动用仓库里随附的基线 ELF（third_party/riscv-tests-elf/）
scripts\run_riscv_tests.ps1

# 有 riscv-tests 源码（第三方 clone 到 third_party/riscv-tests）时会改为从源码编译
# 也可以用 -ElfDir 显式指定一批 ELF
scripts\run_riscv_tests.ps1 -ElfDir third_party\riscv-tests-elf
```

> 那 42 个基线 ELF 是**有意入库**的：上游 riscv-tests 会变（例如 `fence_i` 的
> 自修改目标在不同版本里放在 `.text` 还是 `.data` 不一样），重新 clone 未必复现
> 同一批二进制，基线漂移会让人误判成自己改坏了 CPU。来源与再生成方式见
> `third_party/riscv-tests-elf/README.md`。

## 当前结果：41 PASS / 1 FAIL / 0 TIMEOUT（共 42）

| 分类 | 数量 | 测试 |
|------|------|------|
| PASS | 41 | add addi and andi auipc beq bge bgeu blt bltu bne **fence_i** jal jalr lb lbu ld_st lh lhu lui lw or ori sb sh simple sll slli slt slti sltiu sltu sra srai srl srli st_ld sub sw xor xori |
| FAIL | 1 | ma_data（未对齐访问，架构取舍，见下） |
| TIMEOUT | 0 | —— |

---

## 1. ma_data —— FAIL【架构限制，预期如此，不修】

`ma_data` 测试未对齐访问（`lh/lhu/lw` 从 `+1/+2/+3` 地址读）。本 CPU 只支持对齐访问：

- `mem_addr[14:2]` 直接丢掉低 2 位，按字地址取整
- `lh` 的 `load_half = addr_low[1] ? ... : ...` 只对偶地址正确
- `lw` 从未对齐地址会跨字，无法重拼

**RISC-V 规范允许实现不处理未对齐访问（§2.6 明确列为可选）**，简单实现通常不支持。
**判定：架构取舍，预期失败。**

> ⚠️ 回归时这一项必须**仍然 FAIL**。如果它"被修好了"，说明有人动了 load/store 的
> 字节抽取逻辑，属于非预期改动，要查清楚。

## 2. fence_i —— 已由 TIMEOUT 转为 PASS（2026-09-15）

### 这个测试在测什么

反汇编 `fence_i.elf` 可以看清它是**自修改代码**测试：

```
1c0: auipc t0,0x0
1c4: sh    a0,188(t0)   # 把一条新指令写进代码区 0x27c
1cc: sh    a1,182(t0)   # 接着写 0x27e
1d0: fence.i            # 要求 store 对取指可见
1dc: jalr  t1,a5        # 跳到 0x27c 执行刚写进去的指令
```

### 原来为什么挂死

原设计是**哈佛结构**：`imem` 与 `bram` 是两块独立的 BRAM，store 只写 dmem、
取指只读 imem。写进"代码区"的指令永远进不了取指通路，于是：
`fence.i` 就算是 NOP 也没用，`jalr` 跳到 0x27c 后执行到的仍是旧指令，
测试在 fail 自旋里跑死（实测 TIMEOUT at pc=0x288，全程未写 tohost）。

**结论：这不是"少实现一条指令"，是存储器结构决定的。**

### 怎么修好的

把 `imem` + `bram` 合并成**一块统一的双端口 BRAM**（`rtl/mem/unified_mem.v`）：

- A 口只读、同步读 1 拍 —— 供取指
- B 口读写、按字节写、同步读 1 拍 —— 供访存

于是 store 写进去的数据，后续取指天然能读到，`fence.i` 实现为 NOP 即满足语义
（RISC-V 规范允许无 Cache 的实现把 `FENCE`/`FENCE.I` 视作 NOP）。

这同时落地了 `doc/spec.md` 早先写下的 **modified-Harvard** 路线：软件看到统一
地址空间，核内部取指/访存通路仍然分离（为后续 I/D Cache 留出干净的后备存储）。

**关键证据：整个回归里，fence_i 是唯一发生变化的一项，其余 40 项逐项一致；
CoreMark 周期数也一字不差。** 说明这次改动没有引入任何时序副作用。

### 残留限制（诚实记录）

如果软件改写**自己取指窗口内**的指令（恰好是 store 之后第 3 条，即 `pc_r` 正好
指向它），那一拍发出的取指可能已读到旧值并在下一拍进 IF/ID，`fence.i` 也救不回来
（指令已在流水线里）。这与有没有统一存储器无关，是"没有 I-Cache / 取指缓冲"的
简单核的固有性质，riscv-tests 未覆盖这种极端情况。

## 3. 历史记录：曾被误判为"CPU bug"的几项

2026-09-10 的一份中间报告（`riscv32-FPGA-pds/riscv-tests-run/FAILURES.md`）记录过
`sb/sh/sw` FAIL、`ld_st` TIMEOUT，并归因为"取指在 stall 期间重复取指导致指令被复制
执行"。**那两个问题早已被队友修掉，该文档已过时。** 当前设计里：

- `pc_r` 在 stall 时是**保持不动**（不是后退到 `if_id_pc+4`）；
- `imem_addr` 的 mux 在 stall 时退回 `if_addr_d[14:2]`（重读同一 word），
  使 `if_id` 在 stall 结束那拍拿到 (pc, 指令) 同址的一对；
- `ex_flush_d` 提供跳转后的第二道冲刷，杀掉跳转前已发出的那次读。

这三点是承重逻辑，改动前务必读 `rtl/core/core.v` 里 PC 段的注释。**注意：是
`imem_addr` 后退，不是 `pc_r` 后退** —— 照字面把 `pc_r` 也往后推会复现那个
"指令被复制执行"的老 bug。

---

## 回归纪律

每次改动 RTL 后，以下两条必须同时满足：

1. **本报告的 41/1/0 逐项不变**（除非本次改动的目的就是改变某一项）
2. **CoreMark ITER=1 的周期数一字不差**（当前基线：**1,529,499** 周期，
   CRC 为 `crclist=0xe714 crcmatrix=0x1fd7 crcstate=0x8e3a`）

第 2 条是"没有碰坏流水线"最灵敏的探针 —— 多一个停顿、少一次前递都会让它变。
