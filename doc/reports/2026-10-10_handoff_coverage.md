# 交接任务书：补两条「零覆盖」的回归

> 读者：接手写测试的队友。**这份是自包含的** —— 不需要先读完整个仓库。
> 仓库 / 分支：`D:\riscv-cpu-fpga_merged`，分支 `dualissue`。
> 开工前先读工程根的 `CLAUDE.md`（关键约定 1–41，全是踩过的坑）和
> `doc/reports/2026-10-10_session_state.md`（现在在哪、下一步是什么）。

---

## 0. 三十秒版

现有四条回归基线**覆盖不到两条通路**，而这两条都已经被证明会咬人：

| 任务 | 缺什么 | 为什么重要 |
|---|---|---|
| **A. AMO 回归** | 四个基线里**没有一条执行 AMO 指令** | RV32A 已上板、已用 RT-Thread `--Atomic` 构建验证过，但它是**回归裸奔**的 |
| **B. 代码 > 32 KB 的取指** | 所有测试程序都 < 32 KB，**64 KB 上半区零覆盖** | 2026-10-10 的 `imem_addr2` 截位 bug 就是靠这个盲区躲过全部基线的 |

两条都要**写代码**。A 主要是**改现有的**，B 是**新写一个**。

---

## 1. 任务 A：给 AMO 补回归覆盖

### 现状（要改的东西）

`scripts/run_own_tests.ps1` 第 46 行：

```powershell
$skipThese = @('amo_int', 'dep_probe', 'tb_amo_cpu')
```

这三个被跳过，原因是它们用**旧的 done/UART 协议**汇报（写 `0xFFF8` 报 done、
往 `0xFFFC` 吐字节），不吃 `run_own_tests.ps1` 的 **tohost 判分**，
放进 glob 会误报 `OTHER/FAIL`。

文件都在 `sim/tests/`：

| 文件 | 是什么 | 该不该转 |
|---|---|---|
| `tb_amo_cpu.S` | **整颗 CPU 的 AMO 端到端测试**：连续 amoadd / amoswap / amomax(u) / lr+sc / AMO 与普通访存混合，11 个失败分支各带一个错误码 | **[OK] 要转** —— 这就是我们要的回归 |
| `amo_int.S` | T0 最小复现，配 `sim/tb_amo_int.v` **逐拍 trace** 用 | [X] 不转。它是 trace 的输入，不是判定型测试 |
| `dep_probe.S` | 双发射相邻依赖对的**诊断探针**（非回归） | [X] 不转 |

### 要做的事

1. **把 `tb_amo_cpu.S` 改成 tohost 判定**。参照 `sim/tests/exceptions.S`
   的写法（它已经是标准形态）：
   ```asm
   #include "encoding.h"
   #include "riscv_test.h"
   #include "test_macros.h"

   RVTEST_CODE_BEGIN
           li    TESTNUM, 1
           ...
           RVTEST_PASS          /* 通过 */
   fail_xxx:
           li    a0, <错误码>    /* 失败时把码留在 a0，方便定位 */
           RVTEST_FAIL
   ```
   判分机制：`scripts/riscv_tests_link.ld` 把 `.tohost` 放在 `0x1000`，
   `run_own_tests.ps1` 出 `tohost_addr.hex` 交给 `tb_riscv.v` 轮询。
2. **把 `tb_amo_cpu` 从 `$skipThese` 里去掉**（只去它一个）。
   记得同步改第 41–45 行那段注释 —— 它现在解释的是"为什么三个都跳过"。
3. **保持语义不变**：`tb_amo_cpu.S` 里那 11 个失败分支的用例一条都不能删。
   它们的价值就在于把 `amo_unit` 的边界（有符号 vs 无符号的 `amomax`、
   SC 无预约必须失败、AMO 之后普通 `lw` 必须看得见）钉死。

### 验收标准

- `scripts\run_own_tests.ps1` 输出 **`PASS=3  FAIL=0  OTHER=0`**
  （现有 `exceptions` + `timer_irq` + 新的 `tb_amo_cpu`）。
- **做一次"故意弄坏"验证**：把 `rtl/core/amo_unit.v` 里的 `amomax` 和
  `amomaxu` 改成同一个实现（去掉有符号/无符号之分），重跑 —— **必须 FAIL**。
  验完改回来。**没做过这一步就不算补上了**，否则你不知道测试是不是恒真。
- 双发射/单发射都跑一遍：`run_own_tests.ps1` 与 `run_own_tests.ps1 -Single`。

### 坑（别踩）

- **别动 `sim/tb_amo_int.v` 与 `sim/tb_amo.v`** —— 前者是逐拍 trace 的台子，
  后者是 `amo_unit` 的单元测试（17 项），两者都在正常工作。
- `test_macros.h` 里 `init` 宏**必须是汇编宏**，不能改成 `#define`（见约定 14，
  改了会让 `.text.init` 段名被静默改写成 `.text.nop`，内存布局整体错位）。
- AMO 的目标地址**必须落在 RAM 内**（`0x8000` 以下、且避开 `0xFFF0+` 的兼容区）。
  `tb_amo_cpu.S` 现在用的是 `0x2000~0x2030`，直接沿用即可。

---

## 2. 任务 B：补一条「代码 > 32 KB」的取指测试

### 为什么非有不可

统一存储器 2026-10-10 从 32 KB 扩到 64 KB，**扩容的全部意义就是让程序能大过 32 KB**。
但现有**每一个**程序都远小于它：

| 程序 | 代码末地址 |
|---|---|
| `coremark.elf` | 0x380C = 14,348 B |
| `gomoku.elf`（裸机） | 0x2D08 = 11,528 B |
| RT-Thread 版五子棋 | 0x638C = 25,484 B |

后果：扩容时 `imem_addr2` 漏改宽度（13 位 vs 14 位）→ 取指地址 ≥ `0x8000` 时
**双发射的第二条指令从低 32 KB 取错地方** → 这条 bug 躲过了全部四条基线，
是**读代码读出来的**，不是测出来的。修是修了（commit `f72ef25`），
**但通路仍然零覆盖**。

### 要做的事

写一个测试，让 **CPU 在 `0x8000` 以上取指**并验证结果正确。

**建议做法：不改链接脚本。** 运行时把一段代码**拷贝到高地址**再跳过去执行：

```asm
    /* 1) 把 hi_blob 拷到 target（target = 0x8000 以上，避开 0xFFF0+ 兼容区） */
    /* 2) fence.i                      <- 我们的 CPU 实现了 FENCE.I */
    /* 3) jalr 过去执行               */
    /* 4) 回来后校验结果，RVTEST_PASS / RVTEST_FAIL */
```

这样不用给 `sim/tests/` 引入新的链接脚本，也不用改
`scripts/riscv_tests_link.ld`（那是所有自写测试共用的，动它风险外溢）。

### [重点] 怎么让这个测试**真的能检出**那个 bug

这是整个任务唯一有技术难度的地方，**不做这一步测试就是恒真的**。

故障机理：取指 word `W`（≥ 8192）时，被截位的 `imem_addr2` 读的是
word `W + 1 − 8192`。所以只要在**低地址**放一段"毒药"，
让它在错取时被取到即可。

但**光放毒药没用** —— `core.v` 的配对判据 `pair_now` 是门控的：

```verilog
assign pair_now = (DUAL_ISSUE != 0) &&
                  (imem_rd != 32'd0) && (imem_rd2 != 32'd0) && !p_pred_taken &&
                  !p_muldiv_a && !p_amo_a &&
                  p_opcode_b_ok && (p_f7_b != 7'b0000001) && (p_rd_b != 5'd0) &&
                  (p_rd_a != p_rs1_b) && (p_rd_a != p_rs2_b) && (p_rd_a != p_rd_b);
```

`p_opcode_b_ok` 只放这四种：`OP(0110011)` / `OP-IMM(0010011)` / `LUI(0110111)` /
`AUIPC(0010111)`。**毒药写成 `unimp` 或全 0 都不行**：前者根本配不上对、
后者会被 `imem_rd2 != 0` 挡掉 —— 两种情况下 lane B 都不发射，
表现只是"退化成单发射"，**测不出错**。

一个验证过的设计（照这个写最省事）：

- **低地址毒药块**：`addi s0, s0, 1` 重复 N 次（`s0` 只在毒药里被写）。
- **高地址执行块**：`addi t2, t2, 1` 重复 N 次。
- 校验：**`s0 == 0` 且 `t2 == N`**。

为什么成立：

| | 配对判据 | 结果 |
|---|---|---|
| **修复后**（lane B 取到真正的下一条 `addi t2,t2,1`）| `p_rd_a(t2) != p_rs1_b(t2)` **不成立** → **不配对** | 逐条单发射：`t2` 加 N 次，**`s0` 保持 0** |
| **截位时**（lane B 取到毒药 `addi s0,s0,1`）| `t2 != s0`、`t2 != x0` → **配对成立** | lane A 执行高地址那条、lane B 执行毒药 → **`s0` 被加，`s0 != 0`** |

也就是说 **`s0 != 0` 就是"截位 bug 存在"的判据**，不需要看时序、不需要读波形。

对地址（把毒药对到错取的 word 上）：执行块放在 `D`，毒药放在 `P`，
要满足 `D + i + 1 − 8192 = P + i`，即 **`D = 8191 + P`**。
`P` 用 `la` 在运行时算出来（别写死 —— 环境宏的序言长度会变），
`D` 再换算成字节地址，拷贝目标就是它。

### 验收标准

- **修复后**：`run_own_tests.ps1` 里新测试 **PASS**（双发射与单发射都跑）。
- **回归验证（关键）**：把 `rtl/core/core.v` 的
  `output wire [13:0] imem_addr2` 临时改回 `[12:0]`、`+ 14'd1` 改回 `+ 13'd1`
  （`cpu_top.v` / `mem_bus.v` 的宽度也要跟着窄，否则 `run_own_tests.ps1`
  会先被宽度检查拦下 —— 那是**预期的**，见约定 40），
  **新测试必须 FAIL**。验完改回来。**没做过这一步就不算补上了。**

  > 提示：宽度检查会先报错拦下你。想验证功能就临时把
  > `run_own_tests.ps1` 里那段宽度检查注释掉，或者直接手工 `iverilog`+`vvp`
  > 绕开脚本。**验完记得恢复。**

### 坑

- **`fence.i` 必须写**：拷完代码不刷指令侧，取到的可能是旧内容。
  我们的 CPU 实现了 `FENCE.I`（`rtl/core/control.v`），riscv-tests 里也有
  `fence_i` 这一项。
- **拷贝目标不能碰到 `0xFFF0~0xFFFF`**：那是 CoreMark 兼容区（`0xFFF4` 周期计数器 /
  `0xFFF8` done / `0xFFFC` UART），RAM 实际只能用到 `0xFFEF`。
- **别用 `sp`**：这个测试不需要栈，用了反而要确认栈顶没被覆盖。
- 建议文件名：`sim/tests/hi_fetch.S`。**加完记得更新 `run_own_tests.ps1`
  第 41–46 行那段注释里的清单**（哪个跳过、哪个不跳）。

---

## 3. 两条任务共同的纪律

1. **改完 RTL 或测试，四条基线都要跑**（`doc/reports/2026-10-10_session_state.md` §5）：
   ```powershell
   scripts\run_riscv_tests.ps1                 # 双发射：49 PASS / 1 FAIL / 0 TIMEOUT
   scripts\run_riscv_tests.ps1 -Single         # 单发射：同上
   scripts\run_own_tests.ps1                   # 自写测试
   scripts\run_coremark.ps1 -Iter 1            # Total ticks = 313,886
   scripts\run_coremark.ps1 -Iter 1 -Single    # Total ticks = 363,515
   ```
   > 跑 CoreMark 时会打印 `ERROR! Must execute for at least 10 secs...` 和
   > `Errors detected` —— **那是 ITER=1 的正常现象，不是失败**。
   > 判据是 **`Total ticks`** 和四个 CRC（`seedcrc`/`crclist`/`crcmatrix`/`crcstate`）。
   > **`crcfinal` 不比** —— 它是跨迭代累加器，必然随 ITER 变（约定 29）。

2. **iverilog 的「端口宽度不一致」警告是硬错误**（约定 40）。看到脚本报
   `expects N bit(s), given M`，**别改脚本，去把宽度对齐**。

3. **改 RTL 就要重新综合、重新上板**（约定 23）：
   `scripts\build_bitstream.ps1 gomoku`（或 `coremark` / `demo` / `rtthread` / `video`）。
   注意当前 CPU 域 slack 只有 **+0.236 ns**，余量很薄。

4. **提交按里程碑拆、信息写清改动；不自动 push。**

---

## 4. 交付清单

- [ ] `sim/tests/tb_amo_cpu.S` 转成 tohost 判定，并做"故意弄坏能 FAIL"的验证
- [ ] `scripts/run_own_tests.ps1` 的 `$skipThese` 去掉 `tb_amo_cpu`，注释同步更新
- [ ] `sim/tests/hi_fetch.S` 新测试，并做"截位回去能 FAIL"的验证
- [ ] 四条基线全部复跑，数字逐位不变（除新增的 PASS 项）
- [ ] 两条验证的**原始输出**贴进 `doc/` 下的报告或 commit message（否则别人无法复现你的结论）
