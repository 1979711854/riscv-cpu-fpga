# riscv-tests 预编译 ELF（回归基线样本）

这是 riscv-tests 的 **50 个预编译 ELF**，约 650KB：

| 套件 | 数量 | 测试 |
|---|---|---|
| `rv32ui` | 42 | 基础整数指令集（add/beq/lw/sw/jal/… 含 `fence_i`） |
| `rv32um` | 8 | M 扩展：`mul mulh mulhsu mulhu div divu rem remu` |

`rv32um` 这 8 项是 2026-09-15 补进来的：本 CPU 实现了 M 扩展、CoreMark 也用
`-march=rv32im` 编译，但此前回归只覆盖 rv32ui。补入后 8 项一次全过。

## 为什么把二进制入库

正常做法是"克隆源码 + 编译"，不该提交编译产物。这里破例，是因为这批 ELF 是
**回归基线所依据的确切二进制**，而重新克隆无法保证复现：

- 上游 riscv-tests **会变**。例如自修改代码测试 `fence_i` 在不同版本里把改写目标
  放在 `.text` 还是 `.data` 是不一样的，而这直接决定它在我们这个核上能不能过。
- 基线一旦悄悄漂移，表现是"某个测试莫名其妙从 PASS 变成 FAIL"，很容易被误判成
  自己改坏了 CPU，浪费大量时间排查。

代价是 450KB，收益是**离线可复现的回归基线**。这是有意为之的取舍。

## 来源

由队友的 `build.sh` 生成（原件在 `riscv32-FPGA-pds/riscv-tests-run/build.sh`）：

```
源码    D:\riscv-tests\isa\rv32ui          未改动的 riscv-tests clone
        D:\riscv-tests\isa\macros\scalar
        D:\riscv-tests\env\
链接脚本 scripts/riscv_tests_link.ld       与队友的 env/p/link.ld 逐字节相同
工具链  riscv-none-elf-gcc 15.2.0 (xpack)
        D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin
编译    riscv-none-elf-gcc -march=rv32i_zicsr_zifencei -mabi=ilp32 -static \
          -mcmodel=medany -nostdlib -nostartfiles \
          -I<env> -I<isa/macros/scalar> -T<scripts/riscv_tests_link.ld> <test>.S -o <test>.elf
```

`rv32um` 那 8 个由队友用同样方式编译（原件在
`riscv32-FPGA-pds/riscv-tests-run/build_um/`，编译参数未单独记录）。

> ⚠️ **上游的确切 commit 未知**（源码目录 `D:\riscv-tests` 已不在本机）。
> 这也正是这批二进制要入库的原因 —— 它们就是被钉住的那一版。

## 用法

```powershell
# 不需要 riscv-tests 源码，直接跑：
scripts\run_riscv_tests.ps1 -ElfDir third_party\riscv-tests-elf

# 或者省略 -ElfDir：脚本在找不到源码时会自动回退到这里
scripts\run_riscv_tests.ps1
```

## 用这批 ELF 测得的基线

```
50 PASS / 0 FAIL / 0 TIMEOUT   （共 50 项）
```

`ma_data`（未对齐访问）此前长期是唯一的 FAIL，曾归因为"RISC-V 规范允许的架构取舍"。
**2026-09-21 取指重定向改造后它自动转为 PASS** —— 说明该 FAIL 更可能是冲刷路径上的
一个潜在 bug，而非架构限制。但未对齐通路没有专门测试覆盖，不当作已实现的功能。

详见 `doc/test_report_riscv-tests.md`。

## 校验

`SHA256SUMS` 是这 50 个文件的校验和。如果你重新克隆源码编译了一批，可以对比：

```bash
cd third_party/riscv-tests-elf && sha256sum -c SHA256SUMS
```

对不上不代表你的核有问题 —— 大概率是上游版本不同。**以本目录这批为准**，
或者确认差异来源后显式重建基线（并同步更新 `doc/test_report_riscv-tests.md`）。
