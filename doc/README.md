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
| `resource_efficiency.md` | **赛题三条性能指标成文**（CoreMark/MHz、Fmax、CoreMark/LUTs） |
| `ila_analysis.md` | **流水线效率分析**（CPI/停顿/冲刷占比）+ ILA 抓取方案 + 优化建议；**硬件波形已抓齐**（三种分支预测行为的逐拍证据） |
| `board_bringup.md` | **上板教程** —— 接线（两根 USB 线）、引脚表、烧录两个流程、串口抓取、排障速查 |
| `board/` | **板上实测证据** —— 串口原始日志 + **ILA 硬件波形**（`ila_hw_*.vcd`）+ 索引（**当前 62.0309 MHz 版 ITER=2000 已实测：11.7203 s / 170.64 CoreMark**；同代"只改 RTL 不提频"的对照 137.25、49.89 MHz 的 140.89、45 MHz 的 125.40、27 MHz 的 75.24 作为历史对照保留） |
| `figures/` | 流水线时序波形图（`pipeline_*.svg` / `.png`） |
| `reports/` | 单次改动的验证记录与会话报告（`2026-09-21_branch_opt_verify.md`、`2026-09-23_board_bringup.md`、`2026-09-24_teammate_45mhz.md`（迁移方案）、`2026-09-25_45mhz_migration.md`、`2026-09-25_49mhz_migration.md`、`2026-09-25_progress_report.md`、`2026-09-28_handoff_mario.md`（掌上游戏机任务书）、**`2026-09-28_cpu_opt_handoff.md`（CPU 优化交接给应用线 —— 含合并步骤、`.pds` 那个坑、新基线、7 级流水线的实测结论）**） |
| `paper/` | 论文撰写思路与获奖策略 |
| `patches/` | 给队友的兼容补丁（历史记录） |

## 两份最重要的"别踩坑"文档

1. `spec.md` §3.1 **取指时序不变量**与 §4.1 **总线时序契约** —— 改 `core.v` / `mem_bus.v` 前必读
2. `test_report_riscv-tests.md` 末尾的**回归纪律** —— 改完 RTL 后
   riscv-tests 的 **49/1/0** 与 CoreMark 的**计时区间 363,515 拍**必须同时不变
   （测试台总周期 1,467,276）；最灵敏的探针是那条闭合式
   `288,056 + 20,720 + 9,396 + 45,343 = 363,515`
3. `pds/README.md` §4.1 与 §8 坑 1 —— **`mem.hex` 缺失或过期都会静默产出错误比特流**，
   板上跑的可能是上一个人留下的程序
