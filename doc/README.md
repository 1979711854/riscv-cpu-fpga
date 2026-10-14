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
| `board/` | **板上实测证据** —— 串口原始日志 + **ILA 硬件波形**（`ila_hw_*.vcd`）+ 索引（**当前口径：85.0051 MHz 双发射 + `EARLY_LD` + A1 —— 已板上实测 11.6961 s / 365.93 CoreMark**（ITER=4280，日志 `uart_20261013_184111.txt` / `_184950.txt`）；A1 前：ITER=4116 已实测 11.6980 s / 351.86 CoreMark（只开 D-Cache 的 `2f7a4d0a` 分数相同）；**I+D Cache 版 76.5052 MHz / 325.96 分已实测（A1 后，ITER=3800，位流 `da8ffd31`）**（A1 前 313.63：`uart_20261012_155934.txt`）；历史对照保留：270.82（双发射）、233.85、170.64、140.89、125.40、75.24）<br>**另有应用线（RT-Thread + 五子棋）的板级证据**：`uart_20261013_224652.txt` —— T1/G3 双线程**首次上板**（位流 `8894cdcb`），两线程邮箱往返真通；**T1/G3 显示侧 2026-10-14 已验（位流 `53b81dfe` / `90944754`）：接屏 + 真按键下完一局判出 `WHITE wins`；`vblank timeout` 已定性为概率命中、非显示故障**，见该目录 `README.md` 该节 |
| `figures/` | 流水线时序波形图（`pipeline_*.svg` / `.png`） |
| `reports/` | 单次改动的验证记录与会话报告（`2026-09-21_branch_opt_verify.md`、`2026-09-23_board_bringup.md`、**`2026-09-24_teammate_45mhz.md`（迁移方案）**、`2026-09-25_45mhz_migration.md`（27→45 MHz 执行结果：6 项验证全部通过，含板上实测）、`2026-09-25_49mhz_migration.md`（45→49.89 MHz + BHT 执行结果，含板上实测）、`2026-09-25_progress_report.md`（进度报告）、`2026-09-25_handoff_rtthread_gameconsole.md`（新任务书）、**`2026-10-04_coremark_score.md`（各代板测得分逐条汇总 + 口径说明 —— 当前口径的依据）**、`2026-10-06_taskbook_v3.md`（新任务书 v3）、**`2026-10-12_taskbook_v9.md`（总任务书 · A+B 计划）**、**`2026-10-13_handoff_btbras.md`（分支目标预测任务书 —— 实测判定正解是 RAS、不是 BTB）**、**`2026-10-13_T1_rtthread_g3_checklist.md`（五子棋 RT-Thread 版 T1/G3 拆线程的阶段与验收）**、**`2026-10-13_taskbook_v10_cpu.md`（CPU/RTL 线任务书 —— 覆盖A/B + RAS + BTB，与旧 v8/v9 的 B1 口径不同）**、**`2026-10-13_taskbook_gomoku_v2.md`（五子棋线任务书 —— T1 收尾 + T2~T5）**、**`2026-10-13_session_state.md`（最新会话状态）**、**`2026-10-12_idcache_board_bitstream.md`（I/D Cache 上板全流程 + 板上实测 + 性能拆解）**、`2026-10-12_icache_wb_snap_fix.md`（I+D 上板失败的根因修复）、**`2026-10-12_idcache_lessons.md`（经验记录）**） |
| `paper/` | 论文撰写思路与获奖策略 |
| `patches/` | 给队友的兼容补丁（历史记录） |

## 两份最重要的"别踩坑"文档

1. `spec.md` §3.1 **取指时序不变量**与 §4.1 **总线时序契约** —— 改 `core.v` / `mem_bus.v` 前必读
2. `test_report_riscv-tests.md` 末尾的**回归纪律** —— 改完 RTL 后
   riscv-tests 的 **49/1/0** 与 CoreMark 的**计时区间 232,345 拍**必须同时不变
   （**双发射 + `EARLY_LD` + A1 默认**；A1 前 241,633；`EARLY_LD=0` 时是 252,730；单发射 `-Single` 为 303,140）
   —— **验 Cache 时必须显式带 `-DCache -ICache -EarlyLd`**（计时区间变成 235,628）
3. `pds/README.md` §4.1 与 §8 坑 1 —— **`mem.hex` 缺失或过期都会静默产出错误比特流**，
   板上跑的可能是上一个人留下的程序
