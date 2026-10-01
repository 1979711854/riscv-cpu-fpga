# riscv-tests 的编译环境头文件（上游原件）

这里是 **riscv-tests 官方测试套件自带的编译环境**，用来编我们自己的汇编测试。
它不是我们写的，是从队友交接的原件里抢救出来的（见下"来源"）。

## 里面是什么

| 文件 | 内容 |
|---|---|
| `encoding.h` | 全部 CSR 编号（`CSR_MSTATUS` 0x300 … `CSR_CYCLE` 0xc00 …）与位掩码（`MSTATUS_MIE` 0x8、`MSTATUS_MPIE` 0x80…）、`CAUSE_*` 常量表，以及 `csrr`/`csrw`/`csrrw` 等内联汇编宏 |
| `p/riscv_test.h` | 测试用的汇编宏环境：`RVTEST_CODE_BEGIN/END`、`RVTEST_PASS/FAIL`、`trap_vector` 骨架、`TESTNUM` 约定 |

## 为什么单独存一份

写"异常/中断"的汇编测试必须要有这套宏与 CSR 编号 ——
自己重写一遍既费事又容易和上游语义不一致（尤其是 `trap_vector` 与 `tohost` 的约定）。

**来源**：`riscv32-FPGA-pds/riscv-tests-run/env/`，队友交接的原件。那个目录
**已 gitignore、且标注"验证完可删"**，所以这里另存一份，避免被删掉后
编译新增测试时抓瞎（重新联网 clone 未必能拿到同一版本）。

## 链接脚本不在这里

上游的 `env/p/link.ld` 与本仓库 `scripts/riscv_tests_link.ld` **逐字节相同**
（已核对）。为避免将来两处漂移，这里不存副本 —— 编译时用
`scripts/riscv_tests_link.ld` 即可。

## 归属与许可

riscv-tests 由 UC Berkeley（RISC-V 官方）发布，采用 **BSD-3-Clause**。
原始项目：<https://github.com/riscv-software-src/riscv-tests>。
本目录仅为便于离线编译而保存其 env 头文件，未作修改。

> 与本仓库 `third_party/riscv-tests-elf/` 的关系：那一份是**预编译好的 50 个基线 ELF**
> （回归金标准）；这一份是**编译新测试用的头文件**。两者互补，缺一不可。

## 上游版本未知

交接原件里没有记录上游 commit。`encoding.h` 的规模（约 192KB）与合并
`csr` 指令的内联汇编风格表明它是较新的版本，但**没有精确版本号**。
如果将来要严格复现，需以本目录的文件内容为准，而不是去 clone 最新版。
