# 整合报告：队友 T2/T3 五子棋交接包并入 `dualissue`（2026-10-14）

> 对象：`riscv-cpu-fpga_dualissue_20261014_gomoku(1).rar`（微信收到，16:28）
> 内容：队友仓库 `feat/gomoku-t2` 分支 HEAD `5b16140` 的**工作区未提交改动**（7 个文件）。
> 对应任务书 v3 的 **T2（标题屏多级菜单 + AI 双向独立难度 + 间隔档位）+ T3（HUD 行距重排）**。
> 本仓库 `dualissue` 当时 HEAD `42b423e` = `5b16140` + 5 个 docs 提交 ⇒ **RTL 侧零分歧**，合入是纯固件/测试台层。

## 1. 合入了什么

| 文件 | 改动 | 性质 |
|---|---|---|
| `scripts/gomoku/game.c` / `game.h` | `game_t` 拆字段：`level`→`level_black/level_white`、`demo`→`mode`、新增 `menu_stage`/`step_ms`；标题屏多级菜单（MODE→DIFF→COLOR / AI 分支 BLACK→WHITE→INTERVAL）；新增 `game_start()` / `game_ai_level()`；AI 从"同步跑"改为"派单"（`game_ai_begin`，裸机仍同步泵） | 核心 |
| `scripts/gomoku/main.c` | HUD 重排（T3）：标题屏行 3/4 显示菜单层名/当前值，对局屏顶部按模式 1~4 行；串口新增 `menu=`/`mode=`/`you=`/`black=`/`white=`/`step=` 逐项反馈 | 核心 |
| `scripts/gomoku/test_game.c` | A~H 八节重写（菜单导航/双向难度独立/间隔档/回绕/返回上层） | 测试 |
| `sim/tb_gomoku.v` | 开局从 1 次长按改 **3 次长按**（走完菜单确认到底） | 测试 |
| `scripts/rtthread/app/main.c` | 一行：`ai_cmd.level = gm->level` → `game_ai_level(gm)`（字段已拆） | 联动 |
| `scripts/build_bitstream.ps1` | 注释：gomoku/rtthread 两个 `expectLines` 将过期，需重量（本次已量并回填，见 §3） | 守卫 |

## 2. 整合期发现并修掉的 3 个问题（都在队友未提交改动里）

1. **`game.h:110` 注释把块注释提前闭合**：`level_*/step_ms` 里的 `*/` 关掉注释 ⇒ `step_ms` 变成代码 ⇒ x86 单测编译失败。**已修**（改述为"难度"）。
2. **`game.c:187` 同一处**（`game_start` 的注释，同样写法）。**已修**。
   * 判据评论：这两处说明该交接包**没有在 x86 单测里编过 `test_game.exe`**（`game.h` 只被 `test_game.c` 包含，前四个测试台不含它，所以前四项全过、第五项才炸）。
3. **`test_game.c` 两个死函数**（`menu_start_ai` / `cycle_up`，H 节是内联导航用不到）⇒ `-Wall -Wextra` 警告。按"警告当错误看"纪律**删除**。

## 3. 验证结果（全部实跑）

| 项 | 命令 | 结果 |
|---|---|---|
| x86 单测 ×5 | `scripts\gomoku\run_test.ps1` | **全 PASS**（B2/B3 对局 79 checks / B1 按键 39 / …），**零警告** |
| RV32 交叉编译 | 同上末尾 | 7 个文件 `rv32im` 无警告 |
| 端到端仿真 | `scripts\gomoku\run_sim.ps1` | **`=== PASS ===`** 6 checks / 0 errors（45 min，符合文档记载的 20~50 min）；串口见 `cursor=H8 you=BLACK turn=BLACK` |
| gomoku 固件（上板口径） | `scripts\gomoku\build.ps1` | `.text 25,104 B`，静态 25,720/61,440；`mem.hex` **12552 行 / 6276 字**（T2/T3 前 11268/5634） |
| rtthread 固件 | `scripts\rtthread\build.ps1 -Firmware` | `.text 41,901 B`（85.0051MHz）/ 41,905（76.5052MHz），静态 52,761/61,440（85.9%）；`mem.hex` **21046/21048 行（10523/10524 字）** |
| `expectLines` 守卫 | `build_bitstream.ps1 gomoku` | 命中新值 12552 ✓ |

## 4. 位流（两颗）

| 档 | md5 | 时序 | 用途 |
|---|---|---|---|
| 85.0051 MHz（`RATIO0=13.5`/`UART_DIV=738`） | `e03c0e6e` | CPU 域 **−0.153 ns / 16 端点** | **[X] 勿烧**。与前两颗 rev1019 85MHz 件（`aad1e2ac`/`382ce876`）逐位相同 ⇒ 第三次坐实"确定性时序不过"；归档为 `gomoku_dual_aext_ms_earlyld_a1_85mhz_rev1019_wns-0.153ns_e03c0e6e.sbit`，补上"新网表未综过裸机 gomoku"的记录缺口 |
| **76.5052 MHz（`RATIO0=15.0`/`UART_DIV=664`）** | **`dd4fecb4`** | **All Constraints Met；CPU 域 +0.773 ns / 0 端点**（请求 76.5052 → 实测 81.3140 MHz） | **[OK] 上板功能测试用这颗**，归档 `gomoku_dual_aext_ms_earlyld_a1_76mhz_rev1019_dd4fecb4.sbit`。rev1019 的 85MHz 档时序不过（确定性），降频档闭合 ⇒ 与 76.5 档一贯做法一致 |

> [!] 76.5052 档固件旁路影响：`scripts/demo/addr_map.h` 的 `CPU_HZ` 仍写死 85,005,100（任务书 §4.1 的既有开口）⇒ 板上长按阈值约 0.67 s（标称 0.6 s）、AI 打印的 `t=…ms` 约低 10%。**纯阈值/显示偏差，不影响功能**；修法（让 `CPU_HZ` 跟随 `BOARD_SYSTEM_CLOCK_HZ`）归共享头改动，另行申请。

## 5. 上板清单（给上板侧）

1. 烧 `pds/RV32I_1/bitstreams/gomoku_dual_aext_ms_earlyld_a1_76mhz_rev1019_dd4fecb4.sbit`（md5 `dd4fecb4`；Programmer 里 **Assign New Configuration File**，别只点 Program）。
2. **先看串口第一行 `[build] ... RTL=0x20261019`** 对版（约定 42/58，别信横幅频率）。
3. 灯：`led[1]=video_locked`（D18）不亮 ⇒ 视频 PLL 没锁，屏幕不会亮；`led[0]=pll_locked`（D19）。
4. HDMI 应出 **15×15 棋盘**；标题屏三行菜单（GOMOKU / 层名 / 当前值）。
5. 按键（SW4~SW7 = 左/右/上/下）：标题屏 **↑/↓ 换项、长按或 → 确认、← 返回**；三次确认到底开局（默认 HUMAN/EASY/人执黑）；对局中短按移动、**长按落子**。
6. 串口判据：`menu=`/`mode=`/`you=`/`black=`/`white=`/`step=` 逐项有反馈；落子后 `AI moved, nodes=… depth=… t=…ms`；下完一局出胜负行。
7. 日志：`scripts\serial_monitor.ps1 -Port COM4 -Seconds 60`（自动落 `doc/board/uart_<时间戳>.txt`）。

## 5b. 上板实测结果（2026-10-14 18:49 / 18:53，用户实测）

日志 `uart_20261014_184921.txt`（人机局）/ `_185341.txt`（AI 对弈 HARD vs NORMAL）。
用新入库的 `scripts/gomoku/replay_log.py` 复盘（逐快照校验落子合法性/轮色/`*`/五连）：

| 判据 | 结果 |
|---|---|
| 版本 / 启动 / 菜单 | `RTL=0x20261019` ✓；三确认开局 ✓；菜单每项串口反馈 ✓ |
| 整局规则 | **29 个快照零冲突**：零非法落子、零棋子变色、计数合法 |
| 判胜 | 人机局 AI 挡四（N8）后 **G5 竖五连（G5-G9）胜**，`WHITE wins` + 相位正确转 GAME_OVER |
| AI 对弈 | 14+ 手全合法；中途回标题重开正常 |
| CPU 侧 | **无问题**（用户问"CPU 跑五子棋有没有问题"的答案）；无 vblank 超时 |
| 已知偏差 | `t=` 低 ~10%、长按阈值 ~0.67s（`CPU_HZ` 写死，见 §4 注） |
| 固件小瑕疵 | ① 回标题时假 `AI moved`（stale stats）② `AI thinking` 死路径 ③ `t=` 偏差 —— 均归五子棋线，已写入任务书 v4 §3 |

**用户的下一步需求**（GUI/交互重设计）已形成任务书 v4（`doc/reports/2026-10-14_taskbook_gomoku_v4.md`）
并随本提交打包交接给队友。

## 6. 后续（不在本包内）

- **T6**（GUI/交互重设计，任务书 v4）：用户要求主菜单竖排 + 二级菜单 + 视觉重做，P0。
- **T4**（AI 思考卡顿 G1/G2）与 **T5**（CoreMark 编进固件）仍是 P0，队友未交。
- `CPU_HZ` 写死（§4 注）——共享头，需申请后修。
- 若要把 85 MHz 收敛回来：独立时序优化账（`mem_ready_int` 使能路径加缓冲/寄存），见 `bitstreams/README.md` 顶部结论。
