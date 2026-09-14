# doc

需求、架构、赛题要求、参考资料。

| 文件 | 内容 |
|---|---|
| `plan.md` | 开发计划（分阶段任务清单） |
| `spec.md` | **架构文档** —— 当前实现的流水线、存储器与总线、地址映射、已知限制 |
| `base_task_status.md` | **基础任务三条的逐条核对**（对照赛题指南） |
| `test_report_riscv-tests.md` | **riscv-tests 回归报告** + CoreMark 基线 + 回归纪律 |
| `RV32I指令集参考.md` | 指令编码速查 |
| `setup_env.md` | 环境搭建（工具链、iverilog、PDS） |
| `patches/` | 给队友的兼容补丁（历史记录） |

## 两份最重要的"别踩坑"文档

1. `spec.md` §3.1 **取指时序不变量**与 §4.1 **总线时序契约** —— 改 `core.v` / `mem_bus.v` 前必读
2. `test_report_riscv-tests.md` 末尾的**回归纪律** —— 改完 RTL 后
   riscv-tests 的 49/1/0 与 CoreMark 的 1,529,499 周期必须同时不变
