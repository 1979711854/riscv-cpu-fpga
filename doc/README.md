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
| `ila_analysis.md` | **流水线效率分析**（CPI/停顿/冲刷占比）+ ILA 抓取方案 + 优化建议 |
| `figures/` | 流水线时序波形图（`pipeline_*.svg` / `.png`） |
| `reports/` | 单次改动的验证记录（如 2026-09-21 取指重定向改造） |
| `paper/` | 论文撰写思路与获奖策略 |
| `patches/` | 给队友的兼容补丁（历史记录） |

## 两份最重要的"别踩坑"文档

1. `spec.md` §3.1 **取指时序不变量**与 §4.1 **总线时序契约** —— 改 `core.v` / `mem_bus.v` 前必读
2. `test_report_riscv-tests.md` 末尾的**回归纪律** —— 改完 RTL 后
   riscv-tests 的 **50/0/0** 与 CoreMark 的**计时区间 382,972 拍**必须同时不变
   （测试台总周期 1,488,333）
3. `pds/README.md` §4.1 与 §8 坑 1 —— **`mem.hex` 缺失或过期都会静默产出错误比特流**，
   板上跑的可能是上一个人留下的程序
