# D:\riscv-cpu-fpga — 嵌入式大赛 FPGA 赛道 · 基于紫光同创(Pango) 的 RISC-V CPU

## 项目目标
- 参赛方向：全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道（选题：**RISC-V 处理器设计**）
- 器件平台：紫光同创 **Logos2 PG2L200H**（速度 -6，封装 FBB676）；工具 **Pango Design Suite 2022.2-SP6.4**
- 当前目标板：**本地"盘古2L200H"开发板**，系统时钟经 PLL 从板载 27MHz 倍频到 **85.0051MHz**（2026-10-04 提频，`STATIC_RATIO0` 18.5 → 13.5；此前 62.0309MHz）
  > 远程 FPGA 平台**没有 PLL、固定 27MHz** —— 那是另一套口径，回那边要改回
  > `EE_TICKS_PER_SEC`/`CPU_HZ`=27e6 并重新生成固件（见 `scripts/demo/addr_map.h` 注释）。
  > **仿真也是 27MHz**（测试台例化 `cpu_top`，不传 `UART_DIV`）。三处口径别混。
- 设计内容：**RV32I + M 扩展的 5 级流水线 CPU，顺序双发射**（forwarding 前递 + load-use 停顿 + 多拍除法器；2026-10-06 起 `DUAL_ISSUE=1`），集成 UART/GPIO，跑 riscv-tests 与 **CoreMark v1.0**（要求运行 ≥10s）
- 可选加分项：2 路组相联 I/D Cache、BTB 动态分支预测 + 完整异常/中断、边缘 AI 加速

## 会话纪律（防上下文溢出）—— 2026-10-10 实踩后加

> **背景**：2026-10-10 会话 `c14ae61b` 撞到 **1,017,073 tokens**（模型上限 1,048,576），
> 连 `/compact` 都失败 —— 因为**压缩请求本身就要把整段对话装进去**，一样超限 →
> UI 完全无响应，只能弃会话。**根因不是模型，是工作模式**：那个会话跨了 7 天、
> 在 `riscv-cpu-fpga` / `_merged` / `_ac` 三个仓库之间来回干（4797 条事件）。

**规矩（按重要性排）：**

1. **一个会话只干一个里程碑。** 干完 → commit → 更新
   `doc/reports/<日期>_session_state.md` → 换会话（`/clear` 或新开）。
   **跨仓库尤其要换会话** —— 别在一个 cwd 里连着好几天操作另一个仓库。
2. **盯状态栏的 `ctx 已用 N%`。** 到 **65% 就收尾**（写明状态 + commit），
   到 **75% 别再开新任务线**。**别等它自动压** —— 压不动的时候已经晚了。
   （2026-10-10 的教训：数字一直在状态栏上，只是没人看。）
3. **主动压缩**，在里程碑交界处做，而不是撞墙前一刻。`/compact` 可以带聚焦指示，
   例如 `/compact 只保留 CPU 侧改动与未决项，丢掉已完成的板级日志分析`。
4. **大文件别读进主上下文。** 多文件检索、长报告（`doc/reports/` 那些）交给子代理
   （Explore / general-purpose），**只要结论**。整篇读一次长报告可能就吃掉几个百分点。
5. **结论落盘优先。** 任何"钉死的结论"立刻写进 `CLAUDE.md` 或 session_state 备忘 ——
   这就是 2026-10-10 那次恢复几乎零成本的原因（崩溃前 13:04 的成果都已 commit + push）。

**万一还是撞了 —— 工作不会丢：**

- 进度在 **git** 里，不在对话里。开新会话，先在三个仓各跑一次 `git status`，
  把未提交的 WIP 提交掉（2026-10-10 那次就是靠这个保住了任务 H 的三个文件）。
- 旧会话完整记录在 `C:\Users\zjn\.claude\projects\d--riscv-cpu-fpga\<sessionId>.jsonl`。
  **不要 resume 它**（装不下，必定再报 400）。
- 接着干活只需要读一份 `doc/reports/<最近日期>_session_state.md`。

---

## 当前进度（**2026-10-13：A1 乘法器去阻塞（II=1 流水线）已上板实测通过 —— 365.93 CoreMark**）—— 板上 `Total ticks 994,229,330` → 11.6961 s，每迭代 **232,296.6** 拍（仿真 232,345，差 **−0.021%**），效率 **4.304 CoreMark/MHz**，较 A1 前的 351.86 **+4.00%**。位流 `bcd8fdd2`（`RTL=0x20261017`），ITER=**4280**，日志 `doc/board/uart_20261013_184111.txt`。
**当前跑分口径 = 85.0051 MHz 顺序双发射 + `EARLY_LD`**（I+D Cache 版 @76.5052 MHz = 313.63，A1 前口径）。
演进：2026-10-12 I/D Cache 上板跑通 + 任务C `EARLY_LD`（351.86）；2026-10-06 双发射（270.82）；2026-10-04 提频到 85.0051 MHz；2026-09-28 62.03 MHz + 两拍乘法器 + 动态 BHT

> **[!] 2026-10-14 已推进（RTL 改动，位流待重出）**：**B1-RAS + B1-BTB 均已落地（v11 §3 任务表四项全完）**。
> B1-RAS 返回地址栈 ⇒ 双发射 + `EARLY_LD` 仿真 **232,345 → 229,597 拍/迭代**（−1.18%，`region commit`
> 逐位不变 214,703）。B1-BTB（256 项直接映射、只预测间接 `jalr`、优先级 RAS>BTB>PC+imm）⇒ **对基准逐位中性**
> （`region commit`/`region cycles`/四 CRC 全不变；价值在赛题点名项/功能分），配套 §7 校验放宽到所有被预测 jalr。
> `DESIGN_REV → 0x2026_1022`；时序 CPU 域 **B1-RAS 后 +0.311 → B1-BTB 后 +0.034 ns / 0 失败端点（20,507）**
> —— 仍为正但**很薄**（后备：BTB 缩 64 项 → 再不行 `BTB_EN` 默认 0 / `-DNOBTB`）。详见「待办」小节。）

**另一条腿 —— 应用线（RT-Thread + 五子棋）：[OK] 已做成并上板。**
RT-Thread Nano 跑在板上，五子棋走**板载 HDMI** 出棋盘 + 4 键操作 + **串口棋盘镜像**。
**2026-10-13 T1/G3（render 高优 + AI 低优两条线程）首次上板**（位流 `8894cdcb`，
日志 `doc/board/uart_20261013_224652.txt`）：两条线程都起、**两线程邮箱往返真通**
（`AI moved, nodes=10592 depth=6 t=5068ms`）。
> [!] **但 G3 的正题"AI 思考期间画面不卡"没验** —— 那次上板**没接显示屏**；
> 另有一处 `[!] vblank timeout` 待定案（机制与一步判据见 `doc/board/README.md`）。
> **别把这一版当成"G3 已验证"。**

> [!] **本节以下凡是出现 `351.86` / `313.63` / `241,633` / `ITER=4116` / 优化环最后一项
> 的段落，都是【A1 之前】的记录**。A1（2026-10-13）只改乘法器一项：
> `241,633 → 232,345`（−9,288 拍 / −3.84%），四条并列基线**同幅度各降 9,2xx**，
> `DESIGN_REV` → `0x2026_1017`。**判回归请用「四条并列基线」小节里的新值。**
基础任务完成度详见 `doc/base_task_status.md`：

| 基础任务 | 状态 |
|---|---|
| ② ≥3 级流水线 + 数据冲突 + 分支跳转 | [OK] 达标（5 级流水线、前递、load-use 停顿、6 种分支；**分支惩罚 1 拍**，见下） |
| ① RV32I 基础整数指令集 | [OK] **全覆盖**，含 FENCE / FENCE.I / ECALL / EBREAK |
| ③ 集成基础外设（UART/GPIO） | [OK] 存储总线 + 地址译码 + GPIO + UART 收发；演示程序跑通 |

- 验证：riscv-tests rv32ui + rv32um（50 项）→ **49 PASS / 1 FAIL / 0 TIMEOUT**
  （M 扩展的 mul/mulh/mulhsu/mulhu/div/divu/rem/remu 8 项也纳入回归 —— CPU 实现了
   M 扩展且 CoreMark 用 `-march=rv32im` 编译，此前只有手写单测覆盖）
  > 唯一 FAIL 是 `ma_data`（testnum 1），归因是**未对齐访存不做特殊处理**：
  > `load_half = addr_low[1] ? … : …` 假设按访问宽度对齐，而该测试在 0x2001 做
  > `lh`（半字跨字节边界）→ 取错字节。**RISC-V 规范允许实现不支持未对齐访问**，
  > 属架构取舍，不是 bug。
  > [!] **2026-09-21 勘误**：此前本文档与多份报告称"取指重定向后 `ma_data` 自动
  > 转 PASS、说明它是冲刷路径上的潜在 bug"——**该结论无法复现，已撤回**。
  > 用取指重定向【之前】的 RTL 复测，同样是 FAIL (testnum 1)，改造前后行为完全一致；
  > 且基线 ELF 的 SHA256 全部校验通过、riscv-tests 源码不存在，不存在"重编译出
  > 不同二进制"的可能。原文"架构取舍"的归因才是对的。详见
  > `doc/reports/2026-09-21_branch_opt_verify.md` §2.1。
  > 未对齐通路仍无专门测试覆盖，不把它当作已实现的功能对外承诺。
- **CoreMark**：2026-09-15 已在远程平台实测通过（旧取指路径，ITER=700，
  `Total ticks 294,065,438` → 10.89 秒，`Correct operation validated`，
  `seedcrc/crclist/crcmatrix/crcstate` 与仿真逐位一致 → **CPU 真机算得对**）。
  2026-09-23 两轮分支优化后，仿真每迭代降到 **358,846** 周期 → **2.787 CoreMark/MHz**。
  > [!] **改了流水线就必须重算 ITER，否则 CoreMark 判 invalid。**
  > **速算式：`ITER = 时钟频率 × 10s ÷ 每迭代周期数`** —— **分子是哪个频率，取决于你往哪儿烧**：
  >   * **本地盘古板：850,051,000 ÷ 每迭代周期数**（85.0051 MHz × 10 s）
  >   * 仿真 / 远程平台：270,000,000 ÷ 每迭代周期数（27 MHz × 10 s）
  > 取整后留 5~10% 余量。**当前（双发射 + `EARLY_LD` + A1）232,345 周期/迭代 → 板上 ITER=4280**
  > （4280 × 232,345 ÷ 85,005,100 = **11.70 s**，余量 17%）。
  > [!] **`build_bitstream.ps1` 的默认 `Iter` 还写着 4116（A1 前口径）—— 下次出跑分位流要改成 4280。**
  > 其他配置：`EARLY_LD=0` → 252,730；单发射 → 303,140；I+D Cache（76.5 MHz）→ 235,628。
  > 上板流程（唯一入口）：`scripts\build_bitstream.ps1 coremark` —— 它会生成固件、同步、
  > 综合一条龙，并打印 md5。
  > 历史（27 MHz 时代）：420,094 周期/迭代时 ITER=700 = 10.89s（远程平台实测）；
  > 382,972 时 ITER=770 = 10.92s；358,846 时 ITER=820 = **10.898 s**（本地板实测）。
  > [OK] **2026-09-23 本地盘古板实测（27 MHz，ITER=820）**：`Total ticks 294,262,913` →
  > **10.898 s**，358,857 拍/迭代，与仿真 358,846 差 **+0.0031%**；
  > `Correct operation validated`，`seedcrc/crclist/crcmatrix/crcstate` 与仿真逐位一致
  > （**`crcfinal` 不比** —— 见本节末尾 CRC 判据说明）。
  > 原始日志 `doc/board/uart_20260923_201540.txt`。
  > [OK] **2026-09-25 45 MHz 版板上实测通过**：`Total ticks 538,285,445` → ÷45e6 =
  > **11.9619 s**，`Iterations 1500`，`Correct operation validated`，
  > **358,857 拍/迭代 —— 与 27 MHz 板上实测逐位相同**（周期数与时钟无关的直接证据）。
  > 得分 **125.40 CoreMark**，较 27 MHz 板的 75.24 **+66.7%**（= 纯时钟比 45.0005/27）。
  > 日志 `doc/board/uart_20260925_005201.txt`。
  > [OK] **2026-09-25 49.89 MHz 版板上实测通过**：`Total ticks 588,890,651` →
  > ÷49,892,700 = **11.8031 s**，`Iterations 1663`，`Correct operation validated`，
  > **354,113 拍/迭代**（仿真 354,119，差 **−0.0016%**）。
  > 得分 **140.89 CoreMark**，与推算值**分毫不差**；较 45 MHz 板的 125.40 **+12.36%**，
  > 较 27 MHz 板的 75.24 **+87.3%**。日志 `doc/board/uart_20260925_172318.txt`。
  > [OK] **2026-10-01 62.0309 MHz 版板上实测通过**（两拍乘法器之后）：
  > `Total ticks 727,018,199` → ÷62,030,900 = **11.7203 s**，`Iterations 2000`，
  > **363,509 拍/迭代**，得分 **170.64 CoreMark**。日志 `doc/board/uart_20261001_204718.txt`。
  > [OK] **2026-10-04 85.0051 MHz 版板上实测通过（**单发射**）**：
  > `Total ticks 996,015,474` → ÷85,005,100 = **11.7171 s**，`Iterations 2740`，
  > `Correct operation validated`，四个 CRC `e9f5/e714/1fd7/8e3a` 与仿真逐位一致，
  > **363,509 拍/迭代**（仿真 363,515，差 −0.0016%）。得分 **233.85 CoreMark**
  > （= 每秒迭代 **233.85 次**），较 62.03 MHz 板的 170.64 **+37.0%**。
  > 日志 `doc/board/uart_20261004_114730.txt`；位流 md5 `ae4deea9`。
  > [!] **`Iterations/Sec : 249` 是整数截断的假值**（2740 ÷ 截断后的 11）——
  > 真实值一律自己算 `Iterations ÷ (Total ticks ÷ 时钟)`。
  > [!] **提频的完整论证**见 `doc/board_bringup.md` §2：**PDS 的 `Estimated Frequency`
  > 不是设计上限，而是"这次被要求跑多快"** —— 同一份 RTL 只改 PLL 分频比实测：
  > 请求 62.03→达 66.87、71.72→73.26、85.01→91.87（slack +0.879）、99.79→失败（WNS −1.188）。
  > 真实上限 **≈90 MHz**，取 85 是留 ~7% 余量。
  > [OK] **2026-10-06 顺序双发射（`DUAL_ISSUE=1`）板上实测通过 —— [历史口径，当时最高分；当前为 351.86，见「当前进度」]**：
  > `Total ticks 994,988,178` → ÷85,005,100 = **11.7050 s**，`Iterations 3170`，
  > 四个 CRC 与单发射**逐位一致**，**313,876 拍/迭代** → 得分 **270.82 CoreMark**。
  > 位流 md5 `5c4893de`，日志 `doc/board/uart_20261006_162410.txt`。
  > [!] **这一版是改【效率】而不是改时钟**：效率 2.751 → **3.186（+15.8%）**，
  > 时钟仍 85.0051 MHz。与前面几轮"靠提频涨分"的路子完全不同。
  > [!] **代价**：Fmax 91.40 → **87.00**（slack 只剩 **+0.270 ns**，单发射是 +0.823）、
  > LUT 4,377 → **6,909（+58%）**、**CoreMark/LUTs 0.0534 → 0.0392（−27%）**。
  > 赛题点名的三项性能指标是 **1 升 2 降** —— 报告里必须摆出这张表，只报 270.82 是选择性呈现。
  > [!] 配置口径已统一（2026-10-06）：仿真/综合都显式声明 `DUAL_ISSUE`，
  > 回归有**两条并列基线**（双发射 49/1/0 + 313,886 为默认；单发射 `-Single` 363,515）。
  > `build_bitstream.ps1` 也支持 `-Single` 出回退版位流，期望值**按配置自动算**。
  > [!] **全部得分历史与"效率 × 时钟"分解**见 `doc/reports/2026-10-04_coremark_score.md`。
  > **一律以 PDS 报告的实际频率为准**（`27e6` / `45e6` / `49,892,700` 都是历史口径）。
  > [!] **板/仿真差会双向抖动**：27/45 MHz 两代 +0.0031%（板上慢 11 拍），
  > 49.89 MHz 这代 −0.0016%（板上快 6 拍）。方向相反、量级相同，是仿真模型抖动，别当趋势。
  >
  > [!] **CRC 判据要修正**（2026-09-25 读 CoreMark 源码后确认）：
  > **只有 `seedcrc` / `crclist` / `crcmatrix` / `crcstate` 四个能跨 ITER、跨时钟比对**，
  > 它们必须逐位相同。**`crcfinal` 不能比** —— 它是 `iterate()` 里
  > `res->crc = crcu16(crc, res->crc)` 的**跨迭代累加器**，必然随 ITER 变
  > （实测 ITER=1→0xe714、ITER=820→0xbd59、ITER=1500→0x25b5，三个都对）。
  > 此前"四个 CRC 与仿真逐位一致"的措辞不严，已更正。
  > [!] CoreMark 打印的 `Total time (secs)` / `Iterations/Sec` 是**整数截断**
  > （`HAS_FLOAT=0`），显示 10 / 82，真实值 10.898 / 75.24 —— 一律用
  > `Total ticks ÷ 27,000,000` 自己算。
  > [!] **别用 ITER=1 的测试台总周期去推算迭代成本**。那是仿真
  > 测试台的总周期，含约 108 万周期的一次性串口打印开销；而 CoreMark 自己的
  > `Total ticks` 计时在打印**之前**就停了，不含打印。两个口径不同，混用会把迭代
  > 成本算错，进而把 ITER 估得偏小（本项目据此写成"ITER≈200 约 10s"，
  > 实测只有 3.11s，被判 invalid）。
- **本地盘古板上板跑通（2026-09-23 首次）**：clk/UART/GPIO 全链路验证通过，
  27 MHz 实测确认（串口无乱码）。**上板教程见 `doc/board_bringup.md`**，
  实测证据见 `doc/board/`，引脚出处见 `pds/RV32I_1/RV32I_1.fdc` 头部注释。
  > [!] **上板 top module 是 `cpu_top_board`，不是 `cpu_top`**（`rtl/top/cpu_top_board.v`）——
  > 它把 `pc[31:0]`/`done` 挡在板外，因为 PDS 会把未约束的输出自动布到 BANKR5
  > （板上有 SFP/HSST）的真实引脚上。仿真仍用 `cpu_top`（`pc` 是 `+TRACE` 与
  > TIMEOUT 诊断的数据源，不能删）。
  > [!] **板上 Jtag 与 USB UART 是两个独立接口**，两根 USB 线都要插 ——
  > 只插 Jtag，串口永远没输出（这是最容易卡住的一步）。
- 演示程序：`scripts\run_demo.ps1`（读按键 → 写 LED → 串口打印 + 串口回显）
  串口查看用 `scripts\serial_monitor.ps1`（零依赖，用 .NET 自带 SerialPort，
  默认把输出落盘到 `doc/board/uart_<时间戳>.txt`）
- **平台坑**：远程平台偶发"固件下载完成但设备唤醒失败"，**多烧录几次即可**，不是设计问题 ——
  别浪费时间怀疑自己的 RTL
- **工程坑**：综合前必须把 `mem.hex` 放进 PDS 工程目录（`scripts\sync_firmware.ps1`）。
  缺失时 PDS 只报一行 `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** ——
  但 BRAM 是空的，板上什么都不跑，且没有任何其他报错，极难排查。
  > [!] **同一类坑的第二种形态（2026-09-21 实踩）：文件在，但内容过期。**
  > PDS 综合读的是 `pds\RV32I_1\mem.hex`（**不是** `sim\programs\mem.hex`），
  > 而且**从不检查时间戳**。跑过 `run_demo.ps1` 或 `run_riscv_tests.ps1` 之后再
  > `sync_firmware.ps1`，工程里就留下 demo / riscv-test 的镜像；此后无论怎么改 RTL、
  > 重新综合布线，**板上跑的都还是那个旧程序**，而 PDS 全程零报错。
  > 判据：看 `pds\RV32I_1\pds.log` 里的 `Loading memory data from file ... mem.hex`，
  > 再核对 `mem.hex` 的字数与 ELF 的 `.text` 规模是否相当（CoreMark = 4209 字）。
  > **上板前的固定动作：`scripts\build_bitstream.ps1 coremark`（或 `demo`）** ——
  > 它把"生成固件 → 同步 → 校验 mem.hex 字数 → 综合出 .sbit"串成一条，并打印 md5。
  > 别再手工跑 `run_coremark.ps1` + `sync_firmware.ps1` 两步，容易漏第二步。
- **流水线效率基线（改动流水线后用来对比）**：CoreMark 计时区间
  * **双发射 + `EARLY_LD` + A1（当前板上口径）**：**232,345** 拍（仿真）→ 效率 **4.304 CoreMark/MHz**。
    （**A1 = 乘法器去阻塞 II=1，2026-10-12**：241,633 → 232,345，−9,288/−3.84%，原 4.139。）
    （`EARLY_LD=0` 回退口径 **252,730**；单发射 **303,140**；I+D Cache 版 **235,628** / 4.244。）
  * **单发射（回退版口径）**：**303,140** 拍（2026-10-13 A1 之后的新基线；再往前
    **312,428**（2026-10-11 阶段0/1）/ **363,515**（两拍乘法器之后））/ 提交 288,056 条指令 →
    **CPI 1.2620** / 效率 2.751（363,515 口径）。
  > [!] 下面这条**精确闭合式是【单发射】口径**（四项相加 = 363,515）；双发射的分解式不同，
  > 板上是 241,584 拍/迭代（**A1 前；A1 后仿真 232,345**）。四条基线与跑法见文末「回归纪律」。
  **精确闭合式（单发射，`+PROF` 实测，四项相加 = 区间总数）**：
  ```
  288,056（提交）+ 20,720（load-use）+ 9,396（mul 多拍）+ 45,343（分支）= 363,515  [OK]
  ```
  [重点] 这条闭合式是**判断"有没有碰坏别的东西"最快的探针** —— 任何一项单独变了、
  而其他三项不动，就说明改动只影响了那一项。
  > [!] **单发射板上实测同一口径为 363,509 拍/迭代**（2026-10-04，85.0051 MHz：996,015,474 ÷ 2740），
  > 与仿真差 −0.0016%，是仿真模型的固有抖动。
  实测方法见
  `doc/ila_analysis.md`，测试台已内置 `+PROF` / `+TRACE_*`（默认关闭，不影响回归）。
  > 四轮演进：**420,070**（基线，惩罚 3 拍，冲刷占 26.5%）→ **382,972**（取指重定向，2 拍）
  > → **358,846**（ID 级静态后向预测 + jal，1 拍）→ **354,119**（BHT 动态预测，2026-09-25）。
  > CoreMark/MHz 2.380 → 2.611 → 2.787 → **2.824**。
  > 前两轮的气泡分解精确闭合：`288,056（提交）+ 20,720（load-use）+ 50,070（分支）= 358,846`。
  > 优化记录见 `doc/reports/2026-09-21_branch_opt_verify.md`（前两轮）与
  > `doc/reports/2026-09-25_49mhz_migration.md`（第四轮）。
- **高阶任务②：异常/中断【已完整】；动态分支预测【只做了方向】，赛题点名的 BTB 未做**
  （赛题原文：「实现**动态分支预测器（如 BTB）** *以及* **完整的 RISC-V 异常/中断处理机制」）：
  * **完整异常/中断**（2026-09-23）：CSR 文件 + 6 条 CSR 指令 + `mret`
    + 六类同步异常（非法指令/EBREAK/未对齐 load+store/ECALL/写只读 CSR）+ 定时器中断（CLINT）。
    自写汇编测试在 `sim/tests/`，一键 `scripts\run_own_tests.ps1`。
  * **动态分支预测**（2026-09-25）：`core.v` 里加了 **256 项、2 位饱和计数器、带 tag 的 BHT**
    （`bht_tag/bht_ctr/bht_valid` 数组，索引 `PC[9:2]`、tag `PC[31:8]`）。
    **只预测条件分支方向** —— `jal` 走静态预测、`jalr` 不预测（目标依赖 rs1，ID 级无前递通路），
    两者仍走 EX 冲刷。这个"保守版"**完整绕开了"预测对方向但目标算错"那个坑**
    （那只可能由 jalr 引起）。训练在 EX 级用 `branch_taken`（门控于 `id_ex_branch`），
    未命中时每个条件分支都分配。
    > **收益 358,846 → 354,119 拍（省 1.32%）**，理论上限 2.36%，**捕获率 56%**。
    > 残余空间的原因是 **256 项表偏小、别名冲突**：实测 341 个静态条件分支里
    > **149 个冲突**（`objdump -M noAliases` 统计），最挤的槽 5 个分支共用；
    > 两条最热的冲刷分支（`0x0d04` 实测 5,780 次、`0x0dbc` 2,778 次）都在冲突里。
    > 扩到 1024/4096 项预计还能回收约 1% —— **这是可优化项，不是缺陷**。
    > [!] 占位符级别的提醒：`objdump` 默认把 `bne rd,x0` 打印成伪指令 `bnez`，
    > **不加 `-M noAliases` 会漏掉一半分支**（我第一遍就算错了）。
  > [!] **"BTB" 这个词在本仓出现过很多次，但设计里【没有 BTB】** —— 上面这套是 **BHT（方向）**：
  > `jal` 走静态预测、`jalr` **完全不预测**，两者都靠 EX 冲刷兜住，从来不预测"目标"。
  > **2026-10-13 用 `+JALRTRACE` 探针实测后判定：本 workload 上 BTB 记目标几乎无收益** ——
  > jalr 1,374 条 **100% 是函数返回**，直接映射 BTB（16~16384 项、1/2/4 路）捕获率**恒为 6.40%**；
  > **正解是 RAS**（8 项就到 99.93%），性能账 BTB ≈ +0.04%、BTB+RAS ≈ +0.59%。
  > **BTB 的价值在赛题措辞/功能分，不在分数。** 两者都还没做，任务书见
  > **`doc/reports/2026-10-13_taskbook_v10_cpu.md`**（= 发出去的 `RISC-V_CPU优化任务书_v10_20261013.md`；
  > 自包含，含覆盖 A/B 热身 + RAS + BTB + 与五子棋线的文件划分），
  > 技术依据全文见 `doc/reports/2026-10-13_handoff_btbras.md`
  > （**该文件取代 `2026-10-13_handoff_pathB.md` 的 §5-B1**）。
  > 外部中断 MEIP：通路具备但**无测试**，不得当成已验证能力。
  > 关键取舍见 `doc/spec.md` §6：只支持 M 模式（MPP 硬连线）；未实现的 CSR 读 0、写忽略、
  > 不抛非法（否则 50 个基线 ELF 的 init 段会全挂）。

**回归纪律（重要，2026-10-12 起为四条并列基线）**：改动 RTL 后，riscv-tests 与 CoreMark
**各跑多种配置**，各条基线**不同、不能混**：

| 配置 | 怎么跑 | riscv-tests | CoreMark 每迭代（计时区间） |
|---|---|---|---|
| **双发射 + `EARLY_LD`（默认，= 板上口径）** | `scripts\run_riscv_tests.ps1` / `run_coremark.ps1` | 49 PASS / 1 FAIL / 0 TIMEOUT | **229,597 拍**（B1-RAS；此前 A1 后 232,345）|
| 双发射 + `EARLY_LD=0` | 上面不传 `-EarlyLd` | 49 PASS / 1 FAIL / 0 TIMEOUT | **252,730 拍**（原 262,018）|
| 单发射（回退版口径） | 上面加 `-Single` | 49 PASS / 1 FAIL / 0 TIMEOUT | **303,140 拍**（原 312,428）|
| 带 Cache（corner —— **约定 47 的 bug 只在这里可达**） | 加 `-DCache -ICache -EarlyLd` | 49 PASS / 1 FAIL / 0 TIMEOUT | **235,628 拍**（原 243,933）|

> [!] **为什么必须两条都跑**：`tb_riscv` / `tb_coremark` 是**直接例化 `core`**、靠编译期
> `-DDUAL` 选配置，而板上走的是 `cpu_top`（参数 `DUAL_ISSUE=1`，`cpu_top_board` 不覆盖它）。
> 2026-10-06 之前脚本**不传 `-DDUAL`** ⇒ 默认跑的其实是**单发射**，却被拿去给**双发射比特流**
> 背书；而单发射路径上"`mul` 与 lane B 同处 ID/EX 被冻结 → 读陈旧寄存器 → TIMEOUT"这类 bug
> **根本不复现** —— 默认脚本永远测不出来。
> 现在三处自证、配置不靠默认值：测试台 t=0 打印 `SIM CONFIG: DUAL_ISSUE=?`（也进
> `sim/programs/results.txt` 首行）；`run_*` 脚本用 `-Single` 显式切换、默认双发射；
> `build_bitstream.ps1` 综合前打印它将综合的 `DUAL_ISSUE`（与 md5 并列）。
> 双发射 + `EARLY_LD` 的 **229,597**（B1-RAS 之后）是**当前板上基线**；单发射 303,140 只属回退版，**别拿它算板级得分**。
> 历史基线（均为**单发射**口径）：`420,070`（原始）→ `382,972`（取指重定向）→ `358,846`
> （ID 级静态后向预测 + jal）→ `354,119`（2026-09-25 动态 BHT）→ `363,515`（2026-09-28 两拍乘法器）
> → `312,428`（2026-10-11 阶段0/1）→ **`303,140`（2026-10-13 A1 乘法器 II=1）**。
> 双发射另起一条：`313,886`（2026-10-06，−13.65%）→ `241,633`（2026-10-11 任务C `EARLY_LD`，−7.79%）
> → `232,345`（2026-10-13 A1 乘法器 II=1）→ **`229,597`（2026-10-14 B1-RAS 返回地址栈，当前）**。
> [OK] **2026-09-25（45 MHz 迁移）复测通过**：49 PASS / 1 FAIL / 0 TIMEOUT、
> 358,846 拍 / 1,462,898 总周期，两者都**逐位不变** —— 证明 `core.v` 的
> `addr_result` 旁路确实是纯组合改动（不增删任何周期）。
> [!] **勘误**：本文档此前记 ma_data 的 FAIL 是 **testnum 1** —— 实测**不是**。
> 2026-09-25 用迁移前（HEAD）和迁移后两份 RTL 各跑一遍，**都是 testnum 668**，
> 与 `addr_result` 无关。判回归时**只认 49/1/0 这个组合**，别去对 testnum。

## 仓库结构（以此为准，勿再新建顶层目录）
- `rtl/core/`    CPU 核：`core.v`(5 级流水线 / 冒险 / 分支 / trap / **顺序双发射**) `control.v`(主控译码) `alu.v`(含 M 扩展乘法) `divider.v`(多拍除法) `imm_gen.v` `regfile.v`
                 `csr_file.v`(**CSR 寄存器组 + trap/mret 副作用 + `DESIGN_REV` 版本号**，只支持 M 模式)
                 `multiplier.v`(两拍乘法器) `amo_unit.v`(**A 扩展 AMO 4 拍状态机**) `rvc_expand.v`(RVC 展开器 —— **已写但无模块引用，未集成**)
- `rtl/mem/`     `unified_mem.v` —— **统一存储器**（指令+数据共用一块双端口 BRAM：A 口取指 / B 口访存 /
                 **第三份阵列 `mem2` = 任务C 快通路 load 专用读口**）。
                 行为级、仅 PDS 综合用，`$readmemh` 读 PDS 工程目录下的 `mem.hex`
- `rtl/bus/`     `addr_map.vh`(地址映射单点定义) `mem_bus.v`(**唯一的地址译码处** + 读数据 mux)
                 `cache_d.v` `cache_i.v`(**4 KB/侧、2 路组相联 I/D Cache**，NRU 替换 + 写通；**默认关**，理由见约定 43)
- `rtl/periph/`  `uart_tx.v`(发送，1024 深 FIFO) `uart_rx.v`(接收，16 深 FIFO、读弹出) `gpio.v`(LED+按键)
- `rtl/video/`   **HDMI 视频子系统**：`video_core.v` `ppu.v` `vram_dp/b32/pal.v` `sync_vg.v` `tmds_encoder.v`
                 `rgb2tmds.v` `outputserdes.v` `colorbar_gen.v`。
                 **`video_top.v` 例化 PDS 专有原语（`pll_video` / OSERDES），iverilog 里不存在** ⇒
                 测试台只接 `video_core`（`sim/tb_gomoku.v` 是接法范例，见约定 41）
- `rtl/top/`     `cpu_top.v` SoC 顶层，只做连线 + **配置开关**（`DUAL_ISSUE` / `EARLY_LD` / `DCACHE_EN` / `ICACHE_EN` / 探针；
                 地址映射见 `rtl/bus/addr_map.vh`）
                 `cpu_top_board.v` **上板专用顶层**（PDS 的 top）：包住 `cpu_top` + PLL + HDMI，
                 不引出 `pc[31:0]`/`done`（原因见"当前进度"里的 [!]）
- `rtl/top.v`    早期 LED 点灯练习工程顶层（保留）
- `sim/`         `mem_model.vh`(存储器行为模型，被各 tb `include)
                 整核/SoC 测试台：`tb_riscv.v` `tb_coremark.v` `tb_demo.v` `tb_amo_int.v` `tb_rtthread.v`
                 `tb_gomoku.v` `tb_video.v` `tb_video_core.v` `tb_video_bars.v` `tb_ppu.v` `tb_rvc.v`
                 单元测试：`tb_alu_*` `tb_control.v` `tb_gpio.v` `tb_uart_rx.v` `tb_uart_fifo.v` `tb_multiplier.v` `tb_amo.v`
                 `sim/tests/` **自写汇编测试**（`exceptions.S` `timer_irq.S` `amo_int.S` `dep_probe.S` + `test_macros.h`）
                 `sim/tools/` 逐拍调试台（`tb_debug_trap.v` `tb_memdbg.v` `tb_icache_dbg.v`；需 -WithCore，放 tools/ 以免被 run_sim 通配捞走）
                 `sim/programs/` 为生成的 hex/ELF（**不入库**）
- `scripts/`     `run_sim.ps1` `run_coremark.ps1` `run_riscv_tests.ps1`(支持 `-ElfDir` 免源码回归) `run_demo.ps1` `sync_firmware.ps1`
                 `run_own_tests.ps1`(**自写测试**：汇编 → 跑 → 汇总) `elf2mem.py`(出 imem/dmem/mem 三种 hex)
                 `trace2svg.py`(逐拍 trace → 流水线波形 SVG) `pair_analyze.py`(双发射配对率) `audit_rvc_width.py` `run_video.ps1`
                 `riscv_tests_link.ld` `coremark_port/` `demo/` `gomoku/`(**五子棋**) `rtthread/`(**RT-Thread 移植**)
                 `build_bitstream.ps1`(**上板唯一入口**：固件→同步→综合出 `.sbit`，一条命令；`-Single` / `-Cache` 出变体位流)
                 `serial_monitor.ps1`(**串口抓取**，零依赖；默认落盘 `doc/board/uart_<时间戳>.txt`)
                 `pack_for_teammate.ps1` `pack_handoff.ps1`(打包交接)
- `pds/RV32I_1/`  **正式 CPU 工程**（`.pds` 内源文件已重指 `../../rtl/**`，单一真相）
                 `ipcore/pll/` **Pango PLL IP**（27MHz→85.0051MHz，`RATIO0=13.5`）。`pll.v` 是 IP 生成产物，
                 **必须经 `.pds` 的 `wgt_my_ips_src` 引用**，不能当普通源文件加（见关键约定 24）
                 `bitstreams/` 归档的 `.sbit`（`.sbit` 被 gitignore，只入库 README）
                 `mem.hex` **固件快照（有意入库）** —— PDS 综合读的是**它**，不是 `sim/programs/mem.hex`（见约定 8）
                 > [!] **入库内容定死为【生产固件】= CoreMark（双发射 + `EARLY_LD` + A1 @85 MHz，
                 > ITER=4280，即 **17104 行** = 脚本里的 `expectLines['coremark']`）。**
                 > 理由：**在 PDS GUI 里手工综合的人读的就是这份**，而 `build_bitstream.ps1`
                 > 每次都会重新生成并覆盖它 —— 所以【入库值】唯一的作用就是"手工综合时的默认"，
                 > 必须是最不容易误导的那个。
                 > **每次跑完任何变体的构建，提交前 `git checkout -- pds/RV32I_1/mem.hex` 还原。**
                 > （2026-10-14 曾把 RT-Thread 固件快照入过一次库，已还原；两种口径并存会让
                 > 任务书里"提交前还原"这条自相矛盾。）
- `third_party/coremark/`  官方 CoreMark 源码（含 LICENSE）
- `third_party/riscv-tests-elf/`    50 个**预编译基线 ELF**（回归金标准）
- `third_party/riscv-tests-env/`    上游 riscv-tests 的 **env 头文件**（encoding.h / riscv_test.h），
                                    自写汇编测试要用；从队友原件抢救入库，详见其 README
- `doc/`          `plan.md`(计划) `spec.md`(架构) `base_task_status.md`(基础任务核对) `RV32I指令集参考.md` `setup_env.md`(环境搭建) `test_report_riscv-tests.md` `resource_efficiency.md`(赛题三条性能指标成文) `ila_analysis.md`(流水线效率+ILA方案) `board_bringup.md`(**上板教程**) `board/`(**板上实测证据**：串口原始日志 + ILA 硬件波形 + 索引) `figures/`(波形图) `patches/`(给队友的兼容补丁) `paper/`(**论文草稿 + 获奖策略**) `reports/`(会话报告/交接)
- [!] **已不存在的旧条目（2026-10-12 核实，别再往这些路径写东西）**：`.vscode/`、
  `riscv32-FPGA-pds/`（队友交接原件，验证完已删）、`pds/riscv_cpu/`（早期 LED 练习工程）

## 工具链与常用命令
- **iverilog 14 + GTKWave**（scoop 安装）、**riscv-none-elf-gcc 15.2.0**（`D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin`，等价赛题写的 `riscv32-unknown-elf-`）、PDS 2022.2-SP6.4
- 常用命令：
  - `scripts\run_sim.ps1` —— 跑 `sim/` 下全部单测；`-Testbench sim/xxx.v` 单个；`-NoWave` 不弹波形；整核测试台加 `-WithCore`
  - `scripts\run_coremark.ps1 -Iter 700 -SkipSim` —— **上板用**：只生成固件，几秒钟
  - `scripts\run_coremark.ps1 -Iter 700` —— 完整仿真跑分（ITER=700 要跑十几分钟）
  - `scripts\run_demo.ps1 -SkipSim` —— 演示程序固件，同上
  - `scripts\run_riscv_tests.ps1` —— rv32ui 全量回归 + 汇总（**需 riscv-tests 源码**，见待办）
  - `scripts\sync_firmware.ps1` —— 把 `sim/programs/*.hex` 同步到 PDS 工程供 BRAM 初始化
  - **`scripts\build_bitstream.ps1 coremark|demo`** —— **上板唯一入口**：
    生成固件 → 同步到 PDS 工程（并校验 `mem.hex` 字数）→ 综合布线出 `.sbit`。
    **`generate_bitstream\cpu_top_board.sbit` 这个名字看不出里面是哪个固件**，
    别猜，用这条命令确定。详见 `doc/board_bringup.md` §3

## 关键约定（都是踩过的坑）
1. **iverilog 14 严格要求"先声明后使用"**：信号声明必须出现在使用之前，否则报 `Unable to bind ... declaration after use`（队友原始代码踩过，补丁见 `doc/patches/`）。改 RTL 时务必注意。
2. **仿真时不要编译 `rtl/mem/`**：testbench 通过 `` `include "mem_model.vh" `` 自带
   `unified_mem` 行为模型（带 `+IMEM=`/`+DMEM=` plusarg），重复定义会冲突；`rtl/mem` 只在 PDS 综合时用。
   单测（`tb_alu_*` 等）默认也不编 SoC 级模块（`core.v` / `mem_bus.v`），跑整核/SoC 测试台才用 `-WithCore`。
3. **Verilog 字符串转义里没有 `\r`**（标准只有 `\n \t \\ \" \ddd`）。iverilog 会把
   `"\r\n"` 里的 `\r` 当成字面字符 `'r'`，期望串永远对不上。换行统一用 `16'h0D0A` 常量拼。
4. **外设任何时候都不该把 X 放上总线**。X 被 CPU 读走会污染分支比较（X 参与 `<` 的结果是 X，
   而 `if (X)` 在 Verilog 里按假处理），导致控制流走错分支 —— 本工程被 `uart_rx` 空 FIFO 坑过。
5. **测试台驱动同步信号要避开 posedge 竞态**：`ack=1; @(posedge clk); ack=0;` 这种写法里，
   任务恢复执行与 always 块采样是同一时间步内的不确定顺序，信号可能被提前清零而丢掉这一拍。
   在 **negedge 之后**驱动就没这个问题。
6. **取指补偿逻辑是承重的**：stall 时是 `imem_addr` 退回 `if_addr_d`，**不是 `pc_r` 后退**。
   搞反会复现"指令被复制执行"的老 bug。细节见 `rtl/core/core.v` PC 段注释。
7. **PDS 工程源文件指向 `../../rtl/**`**：改了 rtl 只需在 PDS 里重新 compile，**不要再往 `pds/` 拷源码副本**。
8. 综合前先把固件 hex 放到 PDS 工程目录（`scripts\sync_firmware.ps1`）。
   统一存储器只用**一份** `mem.hex`（指令+数据并集），旧的 `imem.hex`/`dmem.hex` 已废弃。
   > [!] **`pds/RV32I_1/mem.hex` 是【有意入库】的，且入库内容定死为生产固件 = CoreMark**
   > （17104 行 = `expectLines['coremark']`）。因为 **PDS GUI 手工综合读的就是这份**，
   > 而脚本每次构建都会覆盖它 —— 入库值唯一的作用就是"手工综合时的默认"。
   > **跑完任何变体的构建，提交前 `git checkout -- pds/RV32I_1/mem.hex` 还原。**
9. 外部给的 GBK 文件用"以 GBK 重新打开"查看，**不要覆盖保存**；本项目源码统一 **UTF-8**。
10. 交流与输出默认使用**简体中文**。
11. 提交按里程碑拆分、信息写清改动；**不自动 push**。
12. PDS 是紫光同创的工具（Vivado 是 Xilinx/AMD 的），注意区分。
13. **测试台里悬空的输入端口会变成 Z，不是 0**。`tb_riscv.v` 一度漏接了
    `mem_bus` 的 `.irq_timer`，于是 core 里 `int_timer = mie.MTIE & Z` 是不定态，
    中断行为完全随机。**症状极具迷惑性：同一份 RTL、同一份 hex，调试台跑出
    "正常停在 PASS 自旋"，tb_riscv 跑出 pc 跑飞**。两个测试台结果不一致时，
    先怀疑接线不一致，别怀疑 RTL。
14. **C 预处理器会把 `.text.init` 拆成 `.` `text` `.` `init`** —— `init` 是独立
    token。`sim/tests/test_macros.h` 里补 riscv-tests 的 `init` 宏时若写成
    `#define init nop`，段名就被静默改写成 `.text.nop`，链接脚本匹配不到、
    内存布局整体错位（`_start` 从 0x0 跑到 0x1000）。
    **上游用汇编宏（`.macro init / .endm`）正是为了避开这个。**
15. **静态"全零字按气泡处理"是承重的**：取指是同步读、1 拍延迟，复位后第一拍
    发出的地址、数据下一拍才回来，所以那一拍 IF/ID 锁存到的是存储器的复位值
    `0x00000000`。`control.v` 的 `default` 必须对它例外（否则上电第一拍就 trap），
    `core.v` 的 `if_id_valid` 也用它判"是不是真指令"（否则中断会拿气泡的
    `id_ex_pc`=0 去写 mepc）。`tb_control` 里有回归锁。
16. **PDS 会把"未在 `.fdc` 里指定 LOC 的输出端口"自动布到 BANKR5 的真实引脚上**
    （实测 `pc[0]→M2`、`pc[10]→M5`）。本板 BANKR5 接的是 SFP/HSST，
    32 位输出乱布有驱动冲突风险 —— 所以上板 top 是 `cpu_top_board`（挡掉 `pc`/`done`），
    **不是在 `cpu_top` 里删端口**（`pc` 是仿真侧 `+TRACE` 与 TIMEOUT 诊断的数据源）。
17. **手册是 0 起编号、板上丝印是 1 起编号**：手册 `KEY0..KEY4` = 丝印 `SW3..SW7`。
    另外 **LED 丝印（D12..D19）相对开关是乱序的** —— 这是板卡硬件现状，不是映射错误
    （根因：按键引脚按排列分配，LED 引脚按布线就近分配）。所以 `led[]` 已按
    **开关正下方**重排，`.fdc` 头部有完整两张表。
18. **板上 Jtag 和 USB UART 是两块独立接口，要插两根 USB 线** —— Jtag 是 FTDI
    （枚举成两个 COM 口），USB UART 是 CP2102（枚举成一个 `Silicon Labs CP210x` 口）。
    **只插 Jtag，串口永远没输出**，这是上板最容易卡住的一步。
19. **PDS 命令行的实测事实**（`pds_shell.exe`）：
    `-run <action>` 的 action ∈ `compile / synthesize / dev_map / pnr / report_timing /
    gen_bit_stream`，**每个 `-run` 都会把前面的步骤重跑一遍**（所以 `-run gen_bit_stream`
    跑完整条链约 5 分钟）；`-file <tcl>` 与 `-project` **不能同时用**；
    **每次 `gen_bit_stream` 都会先清空 `generate_bitstream/`**（旧版进 `bak/`），
    重要比特流要及时归档到 `pds/RV32I_1/bitstreams/`。
20. **trap 必须同时清 EX/MEM，只清 ID/EX 不够**：`EX/MEM <= ID/EX` 是**同一个沿**
    发生的，清 ID/EX 只保证下一拍是气泡，这一拍 EX/MEM 照样把肇事指令收下 ——
    实测现象是"未对齐 `sw` 既正确陷入了 `mcause=6`，内存却也被改了"。
21. **CSR 写必须从 EX 级提交**（不是 WB）。riscv-tests 里 `csrw mepc, t0` 与 `mret`
    只隔 1 条指令，从 WB 提交会让 `mret` 读到复位值 0 → 跳回 `_start` → 50 个 TIMEOUT。
22. **`csr_wr_illegal` 只看地址，必须与"这条指令真的在写吗"相与** ——
    `csrr a0, mhartid` 是 RS 且 rs1=x0、根本不写，却被判成非法 → init 每轮 trap。
23. **`.sbit` 不进仓库，且 `generate_bitstream/cpu_top_board.sbit` 看不出是哪个固件**。
    `.sbit` 被 gitignore（9 MB/个），**队友 clone 下来一个比特流都没有**，必须自己生成；
    而那个固定文件名只代表"最后一次综合的那版"。PDS 的 Programmer 会记住上次的路径，
    所以"只点 Program 不重新浏览"极易烧成上一版 —— **2026-09-23 实踩：想烧跑分版
    结果烧成了演示程序版**（现象：按键有反应、串口是 `KEY=0x..`）。
    判据：`scripts\build_bitstream.ps1 coremark|demo` 会打印 md5，**别靠文件名猜**。
24. **PLL IP 必须以"IP 源文件"的形式加进 `.pds`**，不能只把 `ipcore/pll/pll.v`
    当普通 Verilog 源文件添加 —— 那样综合会报 `pll` 是黑盒。正确形态是
    `wgt_my_ips_src` 里的一条 `(_ip "ipcore/pll/pll.idf")` +
    `(_ip_source_item "ipcore/pll/pll.v")`。`.idf` 与 `.v` 要一起带。
25. **`.fdc` 里看不见 85.0051MHz** —— 那文件只有输入晶振的
    `create_clock ... -period 37.037`（27MHz）。PLL 输出的约束是
    **PDS 从 PLL IP 自动推导**的，只在时序报告里显示（当前 `clk 85.0051 MHz`）。
    **别以为约束没生效**，也别手动去改那句 create_clock。
26. **`DEBUG_LED` 参数决定 `led[2:0]` 是调试信号还是 GPIO**（`cpu_top_board.v`）：
    1（默认）= `led[0]=pll_locked` / `led[1]=video_locked` / `led[2]=done`；0 = `led[7:0]` 全给 GPIO。
    PDS 综合取**默认值**，命令行传不了 `-D` 宏 —— 所以切演示版要改参数再综合。
    `build_bitstream.ps1` 已按变体自动改（coremark→1、demo→0）并在结束时还原；
    若手工在 PDS GUI 里综合，记得自己改。
27. **板上跑完 CoreMark 的时长 = `Total ticks ÷ 85,005,100`**（当前板上时钟）。
    **一律以 PDS 时序报告里的实际频率为准**，不要用标称值：
    `27MHz`（仿真/远程平台）→ `45.0005MHz` → `49.8927MHz` → `62.0309MHz` → **`85.0051MHz`（当前）**。
    文档里 `294,262,913 ÷ 27e6 = 10.898s`、`538,285,445 ÷ 45e6 = 11.9619s`
    都是历史记录，别拿来当现在的判据。
28. [!] **`unified_mem` 这个名字指两样完全不同的东西，删之前必须看清路径**：
    * **`rtl/mem/unified_mem.v`（我们仓库）= 统一存储器本体，承重，删了 CPU 就没存储器**
      （`.pds` 正引用它；`sim/mem_model.vh` 是它的仿真版）。**永远不要删。**
    * `pds/.../ipcore/unified_mem/`（**只在队友桌面那份导出目录里**）= 队友用 IP Compiler
      生成 Pango 双口 BRAM 的**失败尝试**，`.pds` 从未引用。**这个才是可删的**
      （含 `mem_init.hex`、`ip_backup/`，约 2 MB）。
    2026-09-25 队友确认过它"是添加 IP 核失败的产物，可删"。
[!] 这句话**只针对后者** —— 因为名字一样，转述时极易被理解成"把 unified_mem 删掉"，
    那会把存储器干掉。**转述给别人时务必带上路径。**
29. **判 CoreMark 的 CRC 只看 `seedcrc`/`crclist`/`crcmatrix`/`crcstate` 四个，
    `crcfinal` 不能比** —— 它是 CoreMark `iterate()` 里的**跨迭代累加器**，
    必然随 ITER 变（实测 ITER=1→`0xe714`、820→`0xbd59`、1500→`0x25b5`，**三个都对**）。
    依据见 `third_party/coremark/core_main.c`：`res->crc = crcu16(crc, res->crc)` 在循环里，
    而 `if (i == 0) res->crclist = res->crc;` 只在第 0 轮快照。
    不知道这条的话，看到 `crcfinal` 变了会误判成回归。

30. **ILA 探针属性必须带 `PAP_MARK_DEBUG`，只写 `syn_keep` 不够** ——
    Pango 自带例程里 `adc.v` 的 `wire prdata /* synthesis syn_keep = 1 */` **不出现在 `.fic`**，
    而 `adc_crtl_demo.v` 的 `wire pdata /* synthesis PAP_MARK_DEBUG="1" */` **出现**。
    `syn_keep` 只防优化，`PAP_MARK_DEBUG` 才是让 Fabric Inserter 把它列出来的那个。
    **两个都写。** 属性必须挂在【声明】上、且必须在【分号之前】。
31. [!] **多比特 wire 上的 `PAP_MARK_DEBUG` 会被综合整条丢弃** ——
    手册例子里 `wire [7:0] debug_this_bus /* synthesis PAP_MARK_DEBUG="<0/t1/12>" */`
    暗示一个标记能给总线分配连续 channel；**实测 PDS 2022.2-SP6.4 不保留它**：
    ```
    (* PAP_KEEP="TRUE", PAP_MARK_DEBUG="<0/d0/77>" *)  wire dbg_mem_we;  <- 1 位：保留
        wire [14:0] dbg_pc;                                              <- 总线：属性丢失
    ```
    **所以 PC / opcode 这类必须拆成一位一根 wire**（15+15+15+15+7 = 67 根）。
32. [!] **Inserter 的网线树【不列出模块端口的网线】** —— `pc`、`mem_we`、`mem_re`
    都是 `module core` 的**输出端口**，在 Inserter 里**根本选不到**（`mem_we` 在 RTL 里
    只是 `assign mem_we = ex_mem_mem_write;` 的别名，没法和端口分开选）。
    **解法：在 RTL 里新建内部 `wire` 做别名**，再标记那些 wire。
    另外 PC 在网表里叫 **`pc`** 不叫 `pc_r`（`assign pc = pc_r` 被合并；
    flop 实例名是 `\pc_r[0]` 但输出网线叫 `pc[0]`）。
33. [!] **Fabric Debugger 用前必须先连 JTAG Server** —— 不连的话器件栏只有
    `device - jtag chain` 这个**空树标题**，看着像已经扫到了，其实什么都没连，
    敲任何命令都报 `the connection is disconnected`。
    做法：工具栏 `Connect to server`（或 `File` 菜单）→ IP `127.0.0.1` + 端口 **`65420`**
    → 选 Cable → 总结页点 `Next`。TCL 等价：`dbg_connect -ip 127.0.0.1 -port 65420`。
    连不上就手动起 `D:\pango\PDS_2022.2-SP6.4in\cdt_js.exe -port 65420`。
34. [!] **Inserter 里三个设置项的位置**（手册与直觉不符，详见 `doc/ila_analysis.md` §7.1.1）：
    * **采样时钟**在 **`Net Connections → Modify Connection → Select Net → Channel View → Clock Port`**
      —— **不在 `Trigger Parameters` 里**（那里只有 `Sample On`，那是"采样沿"不是"时钟源"）
    * **触发条件 / 触发位置**在 **Fabric Debugger 的 `Trigger Setup` 里运行时配**，
      **不用重新综合**（手册原文："实时配置 Debugger Core 无需重新编译"）
    * 换触发信号要**改两处**：`dbg_set_unit -unit N ...` 改 TU 的值，
      **还要** `dbg_set_condition -select 0 -set "TUN"` 把条件公式指过去。
      只改 `-unit` 的话条件仍指向 `TU0`（2026-09-25 实踩）。
      判据：`Position=512` 居中，所以波形里**采样 512** 那拍对应触发信号必须是 1。
35. [!] **抓 CoreMark 的 ILA 波形必须先按复位键** —— CoreMark 是一次性程序，
    上电跑 11.8 秒就结束，之后 CPU 在停机自旋 `j 38`（`while(1)`）。
    那条循环里**没有任何条件分支**，而 `ex_flush = ex_resolve_taken && !id_ex_pred_taken`
    在"跳转被预测中"时恒为 0 → **触发条件永远等不到**（表现是波形一直 `waiting for trigger`）。
    做法：`dbg_run` 挂上触发 → 按板上 **丝印 KEY1**（手册 KEY0 / 管脚 C22，本板复位键）
    → CoreMark 重跑，11.8 秒内触发必然满足。
    板级判据：`led[1]=done=`**丝印 D18**（亮=已跑完）；`led[0]=pll_locked=`**丝印 D19**。
36. **Fabric Debugger 关掉后总线定义会丢**（只有 `File → Save Project As` 存出 `.dprj`
    才会连总线一起落盘），但**波形数据会自动落到 `pds/RV32I_1/data.wf`** 不会丢。
    恢复视图：`source scripts/ila_restore_view.tcl`（重建 5 条总线）。
    抓完立刻存一份 `.dprj`。
    > 另：组合成总线**不会移除原信号**（手册 §5.2.1"一条新的总线被加入到 DataPort 的最上面"），
    > 所以波形里总线和 86 根裸位会**同时出现**。想要清爽视图得手工
    > `DataPorts → Clear All` 后 ctrl 点选再 `Add to View`（TCL 没有"只加某一根"的命令）。

37. **双发射有【两条并列基线】，配置口径不靠默认值**（2026-10-06 建立）：
    * `rtl/core/core.v` 的 `DUAL_ISSUE` 参数默认 **0**（单发射）；`rtl/top/cpu_top.v:52` 传 **1**
      —— **上板走的是双发射**。
    * 测试台 `tb_riscv.v` / `tb_coremark.v` 是**直接例化 `core`**、吃编译期 `-DDUAL`；
      而 `tb_demo` / `tb_rtthread` / `tb_gomoku` / `tb_video_bars` 例化的是 `cpu_top`，**本来就是双发射**。
    * 脚本 `run_riscv_tests.ps1` / `run_coremark.ps1` / `run_own_tests.ps1` **默认双发射**，加 `-Single` 出单发射。
    * 测试台 t=0 打印 `SIM CONFIG: DUAL_ISSUE=%0d`；`sim/programs/results.txt` 首行记录配置。
    * **回归四条并列基线**（**2026-10-13 更新为 A1 之后的口径**）：双发射 + `EARLY_LD` 49/1/0 + **232,345**（默认 = 板上口径）；
      `EARLY_LD=0` **252,730**；单发射 49/1/0 + **303,140**（`-Single`）；
      **带 Cache 235,628**（`-DCache -ICache -EarlyLd`，约定 47 的 bug 只在这里可达）。
      （A1 之前的旧值：241,633 / 262,018 / 312,428 / 243,933 —— **别再拿旧值判回归**。）
    * `build_bitstream.ps1` 支持 `-Single` 出回退位流，期望值**按 `DUAL_ISSUE` 自动算**。
    * **位流归档名必须带 `_dual_` / `_single_`** —— 两者文件名与字节数完全一样，不标就分不出来，
      而烧错的表现只是"分数差 15.8%"，**比烧错固件更难发现**。
    > 2026-10-06 之前脚本**不传 `-DDUAL`** ⇒ 默认跑的其实是**单发射**，却被拿去给**双发射比特流**背书。

38. [!] **中文 Windows 上 PowerShell 5.1 把【无 BOM 的 `.ps1`】按 GBK 读** ——
    中文注释里的字符会**吃掉引号配对**，于是脚本报"缺 `)`"这种**假语法错**，
    或更隐蔽地不报语法错却跑出垃圾结果。**仓库里四个脚本已统一加 BOM**；
    改脚本时**别把 BOM 去掉**（编辑器存成"UTF-8 无 BOM"就会复发）。

39. [!] **板子【断电后 FPGA 配置丢失】，两颗 PLL 灯都会灭** —— 比特流烧进 SRAM，
    断电/拔 USB 就没了。现象是"按键无反应 + 串口无输出 + `pll_locked`/`video_locked` 灯不亮"。
    **"灯不亮"先问"是不是刚断电、还没重烧"**，别一上来怀疑设计。
    只要没断电、没重生成比特流，按一下复位键（丝印 **SW3** / 管脚 C22）就能让程序从头再跑一轮。

40. [!] **iverilog 报的「端口宽度不一致」不是良性警告，是【静默截位】**（2026-10-10 实踩）。
    它长这样：
    ```
    rtl/bus/mem_bus.v:182: warning: Port 5 (a2_addr) of module unified_mem expects 14 bit(s), given 13.
    ```
    **后果**：那一位被丢掉（或补 0），地址/数据在 32KB 边界处**回绕**，而且
    **编译零报错、测试全过、板上也看不出** —— 除非程序正好走到被截掉的那半区。
    * 实例：64KB 扩容时 `imem_addr` 改成 14 位、`imem_addr2` 漏改留在 13 位，
      于是**取指地址 ≥ 0x8000 时双发射的 lane B 从低 32KB 取错指令**。
      四条基线没有一条覆盖得到（当时所有程序代码都 < 32KB）。
    * **判据**：`run_riscv_tests.ps1` / `run_coremark.ps1` / `run_own_tests.ps1` /
      `rtthread\run_sim.ps1` 现在**把这个警告当硬错误抛异常**。
      看到它报错，**别去改脚本，去把宽度对齐**。
    * **凡是承载"word 索引"的线，宽度必须跟 `imem_addr` 一起走**（现在 14 位）。
      `rtl/bus/addr_map.vh` 头部有一份"扩容要一起改哪几处"的清单，加线时补进去。
    * **测试台也要跟着改** —— `tb_riscv / tb_coremark / tb_amo_int / tb_debug_trap /
      tb_memdbg` 里的 `wire imem_addr` 自己也是 13 位，会把测试台内部的取指地址
      再截一次。

41. [!] **测试台例化 `cpu_top` 时，`vid_*` 口【必须接】**（2026-10-10 实踩）。
    `cpu_top.v` 上那段注释写着"这些测试台不接 `vid_*`，而它们也从不访问
    0x8001_0000 以上 ⇒ `vid_rdata` 的浮空值不会进 `mem_rdata`" ——
    **只要被测程序碰一下显存/视频寄存器，这句前提就没了**。
    * 实例：五子棋（`video_set_scroll` / `video_wait_vblank` / `draw_frame`）
      跑在 `tb_rtthread` 里，第一次读 `0x8003_0408`（VIDEO_STATUS）就把悬空的
      `vid_rdata`（**Z**，见约定 13）读进了寄存器堆 → 参与运算变 X →
      **PC 变成 `0xxxxxxxxx`，整颗 CPU 在 ~16 ms 死掉**。
    * **症状极具迷惑性**：串口把 banner 打完就静默、心跳永远不出现，
      看着像"调度器没跑 / 延时没到"，其实是 CPU 已经没了。
      **一次断言的引入方式**：读固件里的全局变量（如 `rt_tick`）——
      它**还在涨**就说明定时器/中断/调度这一整类都没问题，别再往那儿怀疑。
    * **接法**：照 `sim\tb_gomoku.v` 把 `vid_*` 接到 `video_core`
      （**不要接 `video_top.v`** —— 它例化 PDS 专有原语 `pll_video` / OSERDES，
      iverilog 里不存在），并在 `run_sim.ps1` 里补上 `rtl/video` 那六个文件。

42. [!] **改 RTL 后、综合前，必须把 `DESIGN_REV` 改成新值**（2026-10-10 加）。
    常量在 `rtl/core/csr_file.v`，由只读 CSR **`mimpid`（`0xF13`）**读出；
    固件把它打在串口第一行：
    ```
    [build] FW=GOMOKU RTL=0x20261017             <- scripts/gomoku/main.c
    [build] FW=COREMARK RTL=0x20261017           <- scripts/coremark_port/core_portme.c
    [build] FW=RTTHREAD-GOMOKU-G3 RTL=0x20261017 <- scripts/rtthread/app/main.c
    ```
    * **为什么需要**：**两版位流可以装着完全相同的固件**，串口日志因此一模一样，
      事后分不出烧的是哪一版（2026-10-10 实踩：`3418c5fc` vs `f00c6659` 跑出来
      两份日志完全无法区分）。版本号必须来自 **RTL 侧**才有区分力。
    * **同一天改多次**就用最低字节当序号（`0x2026_1010` → `0x2026_1011` → …）。
      旧的位流读出 `0x0`（那时 mimpid 恒 0），正好当"这一代之前"的标识。
    * 为什么用 `mimpid` 而不是新加 MMIO：它是规范里的只读 ID 寄存器，
      **不用动地址映射、不用动 `mem_bus`、不用改固件的板级头文件**，
      固件一条 `csrr` 就读到。写它会抛非法指令（`csr_file.v` 的 `wr_illegal`）。
    * **`csrr` 需要 `zicsr`** —— `scripts/gomoku/build.ps1`（`rv32ima_zicsr`）与
      `scripts/run_coremark.ps1`（`rv32im_zicsr`）的 `-march` 里已补上。
      `core_portme.h` 的 `COMPILER_FLAGS` 字符串是**打印给人看的**，也要跟着改，
      否则报告里写的编译口径和命令行对不上。
    * [!] **CoreMark 那行不能用 `ee_printf` —— 必须直写 UART 口、不忙等。**
      因为 `ee_printf` 的 `uart_send_char()` 每发一个字符都要**读 `0xFFF4` 忙等**，
      而 `sim/tb_coremark.v` 判定"CoreMark 计时区间"的判据就是
      **第 1 次 / 第 2 次读 `0xFFF4`**（CoreMark 自己在 `start_time()` 之前一个字都不打，
      那两个读本来正好是 `start_time` / `stop_time`）。用了 `ee_printf` 之后，
      区间在 banner 处被提前打开、下一个字符又立刻关上 ——
      `region cycles / commit / mem acc` **静默全变成 1**，所有流水线分解数据失效，
      **而 `Total ticks` 仍然是对的，所以从跑分上完全看不出来**。
      **2026-10-10 我自己踩了这个坑。**
      **判据**：`+PROF` 跑出来 `region cycles` 必须等于 `Total ticks`
      （ITER=1 时 **313,886**）。看到 **1** 就是这个坑复发了。
    * 这段打印在 `start_time()` 之前，所以不计入 `Total ticks`（仍是 313,886 / 363,515）。
      测试台**总周期**现在约 **1,427,800**（含启动 + 报告打印的一次性开销）——
      **那不是跑分变了**，跑分一律看 `region cycles` / `Total ticks`。

43. [!] **I/D Cache 已完整实现，但【默认必须关】—— I+D 同开时 85 MHz 塞不进**
    （2026-10-11；2026-10-12 修正容量口径）。
    [!] **容量口径（2026-10-12 修正）**：实现**默认是 4 KB / 侧**（`IDX_BITS=9`，
    `mem_bus.v` 例化时【没有】传参 ⇒ 用模块默认值；D-Cache 版位流的 DRM 只比关时多 4 个，
    也印证是 4 KB）。**模块注释里写的 "16KB 用 11" 是"怎么放大"，不是"现在就是 16 KB"**
    —— 此前多份文档（含本节旧文）写成"各 16 KB"是**错的**。
    （评估时确实手工试过 16 KB/侧：更差，见下表。）代码：`rtl/bus/cache_d.v` / `cache_i.v`
    （4 KB/侧、2 路组相联、NRU 替换、写通 + 写命中更新）；开关：`rtl/top/cpu_top.v` 的
    `DCACHE_EN` / `ICACHE_EN`（**都是 0**）；脚本加 `-DCache` / `-ICache` /
    `build_bitstream.ps1 -Cache`；计数器只读 MMIO `0x8000_0018`~`0x24`。
    实测与结论见 `doc/reports/2026-10-11_cache_impl.md`。**四个时序数据点**：

    | 配置 | CPU 域 slack |
    |---|---|
    | 完全不开（生产口径） | **+0.544 ns** ✓ |
    | 只开 I（16 KB） | −1.128 ns ✗ |
    | I+D（16 KB） | −1.586 ns ✗ |
    | I+D（缩到 4 KB） | −1.092 ns ✗ |

    * **根因**：后端是单周期片内 BRAM，**命中 1 拍 = 零收益**，Cache 的全部作用就是
      往 `BRAM 输出 → tag 比较 → way mux → mem_rdata` 这条关键路径上加逻辑。
    * **"缩小 Cache"只解决三分之一**：面积砍 75% 只换回 0.5 ns，剩下的是逻辑深度。
    * **[!] 降频演示这条路是坏的**：请求 71.72 MHz 时 PDS 只做出 61.92 MHz，
      slack −2.208 —— **比请求 85 的 −1.586 还差**（约定 25"放松约束它也偷懒"
      在带 Cache 的设计上重新发作）。别再试。
    * **要"开了还能收敛"的唯一路径**：把访存地址提前到 EX（= 任务 C）。
      但那是**假说**，且任务 C 自己也要吃余量 —— **先做假路径评估再谈**。
    * 答辩口径：**"实现并量化评估后判定为负收益，默认关"** —— 这是加分项，不是短板。
      （旁证：参考设计的 D-Cache 缺失率 **0.000%**，那个 Cache 对他们也没贡献。）
    * [!] **任务 C 之后（约定 45）重测过，结论要更新**：同一份 `pds_shell -run pnr` 流程
      | 配置 | C 之前 | **C 之后 @85 MHz** | **@76.5 MHz（RATIO0=15.0）** |
      |---|---|---|---|
      | 都不开 | +0.544 | +0.045 | — |
      | 只开 D | **（当时没单测，旧表那格是错标）** | **+0.151** ✓ | — |
      | I+D 全开 | −1.586 | **−1.143** ✗（2026-10-12 复测，343 失败端点）| **+0.589** ✓（0 失败端点）|
      > [!] **2026-10-12 实测：I+D 降频到 76.5 MHz 就收敛，且【已上板跑通】**
      > （313.63 分，`[cache] I`/`D` 计数都非 0），slack 随周期 **1:1 恢复**
      > ——**约定 43 §7.2 "放松约束 PDS 会偷懒"在这版设计上不成立**
      > （那条是任务 C 之前、另一配置的一次观测）。
      > [!] **修 `wb_rdata_snap`（约定 47）不会把 85 MHz 拿回来**：复测 **−1.143**
      > （修复前记的 −0.857 —— 两者都是"不收敛"，差值属布局抖动）。
      > 该修复动的是 **WB / 前递链**，而 **I-Cache 挂在取指链**上，两条链是分开的。
      > [!] 同一 RTL 两次独立布局反推的"真实 Fmax"分别是 **77.5 / 80.1 MHz**（差 0.42 ns）
      > ⇒ **"76.5 有余量"不等于"80 一定行"**；想卡某一档必须多 seed 实测。
      **D-Cache 的时序代价已经消失**（快通路 load 不再占用 B 口 ⇒ tag/way 整体离开访存
      关键路径），**I-Cache 仍塞不进**（它挂在取指链上，任务 C 没动取指链）。
      **而收益仍是 0**：I+D 全开每迭代 232,345 → **235,628（+1.41%）**（A1 前是 241,633 → 243,933 / +0.95%），
      且 D-Cache 只服务**没走快通路的那部分访存** —— 别再把 98.47% 那个旧口径拿出来说。
      > [!] **文档旧写的"I+D 周期代价 +9.8%（265,408 拍）"是漏了 `EARLY_LD` 的口径，已作废**
      > ⇒ **"压 I-Cache 缺失通路 ≈ +6%"这条不再值钱**（上限只剩 ~0.9%）；
      > **I+D 唯一的值钱方向是"把主频拿回来"**（PCE 区域约束 / I-Cache 离开取指链）。
      ⇒ **默认仍关**，理由从"塞不进"改成**"塞得进 D、塞不进 I，而两者都不涨分"**。
      > [!] **2026-10-14 修正（两处，都别再用旧结论）**：
      > 1. **"塞得进 D" 那句是 A1 之前、且只看 CoreMark 的`+0.151 ns`。** A1 之后的
      >    "只开 D @85" 实测 **−0.177 ns / 13 失败端点**（00:57 那颗，见
      >    `doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`）——**85 MHz 也塞不进了**。
      > 2. **更要紧的是功能**：同一条 RT-Thread 五子棋固件，在 `-DCache` / `-ICache`
      >    / 两者下**都会挂**（仿真 100 MHz 复现，与板上 `c10a2478` 现象一致），
      >    而**无 Cache 是 PASS** ⇒ **是功能 bug，不是时序**。CoreMark 不经过
      >    gomoku/RT-Thread 的代码与中断路径，所以从没暴露过 ⇒
      >    **"D-Cache 可以常规开着"这条【对非 CoreMark 负载不成立】，已从
      >    `bitstreams/README.md` 的 `56374a08` 条目里改掉。**
      想让它真有用只有"让后端变慢"（片外存储），本项目已决策不做 —— 别再绕回来。

44. **任务 C（消除 load-use 停顿）的时序评估已完成：可行，但余量只剩 1.3%**
    （2026-10-11）。报告 `doc/reports/2026-10-11_taskC_agu_probe.md`。
    * 探针：`rtl/core/core.v` 的 `AGU_PROBE`（默认 **0**，透传见 `cpu_top.v`），
      插的是「寄存器堆读 → 前递 mux → 32 位加法器 → ID/EX」，**喂真实信号**防删，
      结果经 `mem_bus` 的只读 MMIO `0x8000_0028` 回读。
    * 实测：基线 **+0.578 ns**（89.398 MHz）→ 探针开 **+0.148 ns**（86.088 MHz），
      **Δ = −0.430 ns**。与 A.1 假 tag 探针的 0.452 ns 同量级 ⇒
      **"插一级 32 位逻辑到这个设计上"的标准代价 ≈ 0.43 ns**（可当经验常数）。
    * [!] **探针只量了 AGU 那一小块。** 任务 C 真正的风险是**改协议**不是加路径：
      地址提前到 ID 会引入新的 **地址-use RAW**（可能新增停顿，把收益吃回去）、
      并且 `mem_addr/mem_we/mem_re` 从 EX/MEM 改成 ID/EX 驱动 ——
      **AMO 的 4 拍状态机、`mem_ready` 冻结、trap 的 EX/MEM 清除全建立在这之上**。
    * 建议做法：**先只把 load 的地址提前（store/AMO 不动），用最小改动量把收益量出来**，
      再决定要不要搬其余部分。判据：`+PROF` 的 `region cycles` + 回归 49/1/0。

45. **任务 C 第一步已做成：load 地址提前到 ID（`EARLY_LD`）—— 每迭代 −7.79%**
    （2026-10-11）。报告 `doc/reports/2026-10-11_taskC_early_ld.md`。
    开关：`core.v` / `cpu_top.v` 的 **`EARLY_LD`（cpu_top 默认 1）**，仿真 `-DEARLYLD`、
    脚本 `-EarlyLd`。**`EARLY_LD=0` 回退逐位不变（`Total ticks` 恰 252,730；A1 前 262,018）。**

    | 版本 | 拍/迭代 | 快通路 load 占比 | 剩余停顿 |
    |---|---|---|---|
    | 基线 | **252,730**（A1 前 262,018） | — | 27,181 |
    | `EARLY_LD=1` | **232,345**（−8.07%；A1 前 241,633 / −7.79%）| 85.0% | 6,796 |

    * 做法：ID 级 AGU 算地址 → **专用读口**（`unified_mem` 的**第三份阵列 `mem2`**，
      写口同样广播，与 A2 取指口同构）在该 load 的 **EX 级**发地址、**MEM 级**取回数据
      → 紧跟其后的消费者在 EX 级就能前递到它 ⇒ **load-use 停顿消失**。
      **store / AMO / trap / `mem_ready` 的旧机制一行未改** —— 评估里"最重的那部分
      （把访存端口整体提前一级）本轮没搬**，靠"专用读口 + 保守判据"整体绕开了。
    * [重点] **只接【字 load】的基址前递**（`ex_mem_funct3 == 3'b010`）：
      byte/half 作为基址来源要先解包，那几级会顶替乘法器成为**新的 CPU 域最差路径**
      （实测 slack +0.208 → **+0.035**）。限制成字 load 后**周期数一模一样**
      （链式指针解引用在 CoreMark 里全是 `lw`），时序却回来了。**这是本轮最划算的一刀。**
    * [!] **前递给消费者的必须是【解包后】的值**（`ld_fwd_byte/half` + 符号扩展），
      不能是原始字 —— 只前递原始字时 `lw` 全过、**`lb/lbu/lh` 全 FAIL**、
      CoreMark 的 matrix/state CRC 全错（u16）。
    * 保守判据（判错只退回旧通路，ID 级即可判定）：①基址不在 EX / 不在 EX/MEM 的
      旧通路 load·AMO ②地址在 RAM 段（读口只镜像 RAM）③紧前不是 store
      ④前/后不是 AMO。**判据先行的实测：86% 的 load 可走，理论 24,568 拍、兑现 20,385 拍（83%）**。
    * **[OK] 板上实测通过（2026-10-11 22:57）**：位流 `2ddaf32f`、ITER=4116、
      `Total ticks 994,362,145` → **11.6976 s**，四个 CRC 与仿真逐位相同，
      **351.8 分**（原 324.5 ⇒ **+8.4%**，**A1 前板上值**）；每迭代 **241,584** 拍（**A1 前**仿真 241,633，−0.02%；A1 后仿真 232,345）。
      日志 `doc/board/uart_20261011_225624.txt`。
    * 验证：riscv-tests **49/1/0**、自写测试 **2/0**、**AMO 集成 T0 PASS**
      （riscv-tests 里一条 AMO 都没有，这块只能靠它）、四个 CRC 逐位一致、
      `+MEMWAIT=1/2/3` CRC 仍全对。工具：`tb_coremark` 加 **`+LDANAL`**
      （停顿按成因分类 + "模型判可走/RTL 标慢"对拍，**定位差异靠它**）、
      `tb_riscv` 加 `+LDBUG`（逐条 load dump）。
    * 时序：CPU 域 **0 失败端点**；本期三次 P&R（同一 RTL 家族）实测 slack
      **+0.208 / +0.035 / +0.322** —— **同一个 RTL 家族的散布就有 0.3 ns**（约定 25），
      **引用余量必须说清是哪一次跑的**。关键路径在"字 load 限制"之前是
      `ld_rdata → 解包 → ID 加法器`（本轮新逻辑），之后回到乘法器。
    * 剩余停顿（下一步的可选项）：**基址在 EX 4,744 拍（1.81%）**需要真加 EX→ID 前递
      （两级加法器串成一条链，**应当先插假路径量时序**）；紧前是 store 1,869 拍（0.71%）
      要 store→load 字节合并旁路。

46. [!] **"带开关的位流"必须验【网表】，不能只看脚本打印**（2026-10-12 实踩，比约定 23/42 更阴）。
    `build_bitstream.ps1` 的 `-Cache` / `-DCacheOnly` 是"改 `cpu_top.v` 的 parameter → 综合 → 还原"。
    **我改这个开关时误删了那一行 `[System.IO.File]::WriteAllText($cpuTopFile, $cacheNewTxt, ...)`**，
    于是脚本**照常打印**"`-DCacheOnly：cpu_top.v 的 DCACHE_EN=1`"，**却根本没改文件** ——
    两次"带 D-Cache 的位流"其实**Cache 全关**，而且：
      * 日志正常、文件名正常、`md5` 也变（每次都不同）✗ **一个都看不出来**
      * 唯一露馅的是**时序数**：Cache 关 = `+0.045`，只开 D = `+0.151`（同一 RTL 可复现）
    **判据（归档任何"带开关"的位流前都跑一次）**：
    ```bash
    grep -aE "parameter DCACHE_EN\|parameter ICACHE_EN\|parameter EARLY_LD" rtl/top/cpu_top.v   # 运行时看一眼
    grep -aic dcache pds/RV32I_1/place_route/seed_*/cpu_top_board_pnr.netlist                     # 网表里必须有
    grep -aE "^Total DRM" pds/RV32I_1/flow.log                                                    # 只开 D 应比关时多 ~4 个 DRM
    ```
    **推论（更一般）**：`parameter` 开关的位流，"配置自证"只能靠**网表/资源/时序数**，
    与约定 42 的 `DESIGN_REV`（那证明的是 **RTL 版本**，**证明不了开关**）分工不同，两个都要看。

47. [!] **级间快照/前递的"选源信号"必须与它服务的【流水级】同源**（2026-10-12 实踩，
    I+D 位流"板上只反复打 banner"的真凶）。
    `core.v` 的 `wb_rdata_snap` 服务的是 **MEM/WB** 级的 load，却在停顿沿写成
    `wb_rdata_snap <= ex_mem_ld_fast ? ld_early_data : mem_rdata;` ——
    `ex_mem_*` / `ld_early_data` 是 **EX/MEM** 级（**下一条**指令）的信号 ⇒
    I-Cache 缺失冻结时，把下一条 load 的值写进了本条 load 的写回路径。
    **修法一行**：停顿那支**只能取 `mem_rdata`** —— 快通路 load 在自己的前进沿
    已被第一支抓过快照，走不到这一支，所以这一支服务的必然是普通 load。
    **判据/教训**：
    * **"信号名里带 `ex_mem_` 就属于 EX/MEM 级"** —— 用它去服务 `mem_wb_*` 那级
      是**张冠李戴**，编译不报、短仿真也未必崩（本例 8,124 拍才跑飞）。
    * **要触发它，四个条件缺一不可**：`EARLY_LD=1`（否则 `ex_mem_ld_fast≡0`，
      三元式退化成 `mem_rdata`，bug 不可达）+ `ICACHE_EN=1`（提供**大量停顿**）
      + `DCACHE_EN=1` + "普通 load 在 WB 且快通路 load 在 EX/MEM"。
      ⇒ **四条回归默认都是 `EARLY_LD=0`，天然盖不住它** ——
      验 Cache / 任务 C 时必须**显式**带上 `-DCache -ICache -EarlyLd`，
      并**核对 vvp 首行 `SIM CONFIG:`**（别再拿"长仿真过了"当结论，见下条）。
    * **"仿真过了 ⇒ 逻辑对"这个推理不成立**，除非**配置打印全对**。
      项目此前记的"I+D ITER=50 长仿真四个 CRC 全对"与本 bug **直接冲突**
      （未修 RTL 8,124 拍就崩），几乎肯定是**漏了 `-EarlyLd`** ⇒ 该结论作废。
      详见 `doc/reports/2026-10-12_icache_wb_snap_fix.md`。

48. [!] **得分要自己算：`ITER × 时钟 ÷ Total ticks`** —— 串口日志里的 `Iterations/Sec`
    **不可信**（2026-10-12 实踩）。这个 CoreMark port 是 `HAS_FLOAT=0`（`core_main.c` 的 `#else` 支），
    那一行是**整数截断**：I+D 版真实 **313.63** 分，日志打的是 **333**（`3668 ÷ 11`）；
    只开 D 的 85 MHz 版真实 **351.86**，日志打的是 **374**。**照那行报分就是报错**。
    原始证据只看三样：`Total ticks`、`ITER`、四个 CRC（`seedcrc/crclist/crcmatrix/crcstate`）。

49. [!] **`.sbit` 的 md5 只在【同一仓库】内可比**（2026-10-12 实踩）。
    两个仓库副本综合同一份 RTL：**网表逐字节相同**（`A48149160663EE4EB42F36C669A2DF45`）、
    时序数字逐位相同，但 **`.sbit` 的 md5 不同** —— 因为文件里**内嵌了工程路径**。
    ⇒ 判断"两个位流是不是同一设计"要**比网表**（或比 slack / 资源占用），**不是比 `.sbit` md5**；
    md5 仍要归档记录，但**注明它是在哪个仓库/路径下产出的**。

50. [!] **改频率是一次"三处改动 + 事后全部还原"的事务**（2026-10-12 用过两次）。
    改 `pll.idf` 的 `STATIC_RATIO0` 后必须依次：
    ① `ip_generate.exe -i pll.idf` 重生成 `pll.v`（**不是**改 `CLKOUT0_REQ_FREQ`）
    → ② `cpu_top_board.v` 的 `UART_DIV = f ÷ 115200`
    → ③ `core_portme.c` 的 `EE_TICKS_PER_SEC = f`
    → ④ 重算 `ITER`（按**当前配置**的拍/迭代，别用别的配置的数）。
    **做完必须把频率改动全部还原**（不还原 ⇒ 下次出的"跑分位流"时钟口径就是错的，而且**看不出来**）。
    本次 I+D 用的一组：`RATIO0=15.0`（76.5052 MHz）/ `UART_DIV=664` /
    `EE_TICKS_PER_SEC=76,505,200` / `ITER=3668`。

51. [!] **流水线化的多拍单元，其使能必须与它服务的流水级【同源】**（2026-10-12 实踩，A1）。
    把乘法器改成 II=1 流水线（见约定 52）后，第一版**没给它加使能**，于是：
      * `+MEMWAIT=0/1/2` **四个 CRC 全对**
      * **`+MEMWAIT=3` 四个 CRC 全变**（`e714/1fd7/8e3a` → `ec70/b9d6/b215`）
    **根因**：乘法器是**自由流动**的两级流水线，而 EX/MEM、MEM/WB 在 `mem_ready_int=0` 时
    是【保持】的 ⇒ 乘法器的结果寄存器继续前进、`*_is_mul` 标志却停住 ⇒ **错位**，
    写回取到的是**别的 mul** 的结果。
    **修法**：给它一个 `en` 输入，接 **`mem_ready_int`**（与 EX/MEM、MEM/WB 同一个条件），
    `en=0` 时整体保持。
    **⇒ 推广**：任何"自己会往前走"的流水结构（乘法器、取指队列、结果 FIFO），
    都必须与它服务的流水级**共用同一个使能**。
    **⇒ 而且这类 bug 往往只在停顿最密的配置下暴露** —— 本次只有 `+MEMWAIT=3` 抓到，
    `0/1/2` 全对。**再证回归必须带 `+MEMWAIT`。**

52. [!] **乘法器已从"阻塞两拍"改成 II=1 流水线（A1，2026-10-12）—— 四条基线同步下降**
    `multiplier.v`：第 0 级锁存操作数，第 1 级把**已选中的乘法结果**再打一拍 ⇒
    **latency 2、II=1**（`busy` 恒 0）。配套 `core.v`：
    `mul_start = id_ex_is_mul`、**`mc_stall` 不再含 mul**、`stall` 加一条 mul 判据
    （只有"紧邻下一条就消费"才停 1 拍 —— 实测 **9,396 条 mul 里只有 108 条**落这一类，
    用 `+PROF` 新增的 `region mul near` 计数器量的），
    并新增 `ex_mem_is_mul` / `mem_wb_is_mul` 级联 + `wb_data` 的 mul 分支。
    * **收益**：每迭代 **241,633 → 232,345（−9,288，−3.84%）**；效率 **4.139 → 4.304 CoreMark/MHz**。
      **四条并列基线同步下降**（约定 37 的表已更新）—— 四条差值都是 −9,288，四个 CRC 全不变。
    * **代价**：LUT 7,254 → **7,482（+228，+3.1%）**；**时序中性**（同流程 8-seed 实测：
      A1 前最好 −1.098 / A1 后最好 −1.137 ⇒ **Δ = −0.04 ns**，在 seed 抖动内）。
    * **板上 ITER 要改成 4280**（见「当前进度」的速算式）。
    * [!] **判"某个改动有没有动时序"，必须把原版 RTL 跑一遍当对照** ——
      **别拿文档里的历史 slack 当基线**。本次我一开始拿文档的 `+0.045` 当基线，
      得出"退化 1.2 ns、准备重做结构"的**错误结论**；把原版跑一遍才发现它自己就是 −1.098。
      详见 `doc/reports/2026-10-12_taskbook_v9.md` §8.6.1。

53. [!] **判 CPU 时序只认 `.rtr` 里的【`u_pll` → `u_pll` 那一行】，不是 `pds_shell -run pnr` 的 seed 汇总**
    （2026-10-12 实踩，查了半天才发现口径错）。
    `report_timing/cpu_top_board.rtr` 的 Setup Summary **按 launch→capture 时钟对分行**，实测：

    | Launch → Capture | WNS | 失败端点 | 含义 |
    |---|---|---|---|
    | **`u_pll/CLKOUT0` → 自己** | **+0.068** | **0 / 17,216** | **CPU 域（唯一的 CPU 时序指标）** |
    | `u_pll` → 视频 `CLKOUT0` | **−1.137** | **21 / 21** | CPU↔视频 **CDC** 路径 |
    | 视频 `CLKOUT0` → CPU | −0.081 | 1 / 1 | 反方向 CDC |
    | 视频 → 视频（两组）| +6.856 / +33.353 | 0 | 视频域自己 |

    * **`-run pnr` 每个 seed 打的 `Setup(Slow): -1.137` 是【全设计最差】**（= 那 21 条 CDC），
      与 CPU 域**无关**。拿它比较 CPU 侧的改动，会得出完全错误的结论。
    * **⇒ 规矩**：改 CPU RTL 后判时序，**只读 `.rtr` 的 Setup Summary**，认 `u_pll` → `u_pll` 那行。
    * **⇒ 也解释了"文档 +0.045 vs 实测 −1.098 差 1.14 ns"那个悬案**：两个数根本不是同一个东西。
      文档的 `+0.045` 是 **CPU 域**口径，一直是对的。（详见 taskbook v9 §8.6.2，已结案。）
    * **CPU 域真实余量只有 +0.068 ns（约 0.6%）** ⇒ **任何往 CPU 关键路径加逻辑的方案都要先算清**：
      经验常数是"插一级 32 位逻辑 ≈ 0.43 ns"（约定 44）⇒ **A2（剩余 load-use）就此出局**。
    * [!] **⚠️ 勘误（2026-10-13）：那 22 条跨域违例【修不了】，别再去试。**
      `pds/RV32I_1/RV32I_1.fdc` 第 96~132 行有完整的否证记录（2026-09-27）：
      `set_clock_groups -asynchronous` / `set_false_path -to [get_pins ...]` /
      厂商层次写法 / `-derive` —— **四种写法逐一实测全部不成立**，其中 (B) 那句
      还会报 **E 级错误让整个综合当场中止**（比不写还糟）。
      **根因**：`.fdc` 的命令都在 Constraint check 阶段跑完，而三路 PLL 输出时钟是
      PDS【读完本文件之后】才 `create_generated_clock` 出来的 ⇒ **写约束时那些时钟
      和 FF 都还不存在**；且 PnR 只重读 `.pcf`、**不重读 `.fdc`**，也没法推迟绕过。
      ⇒ **那 22 条是建模假象（0 级逻辑、纯走线），不是可修的约束缺失。**
      **⇒ 教训：提"新增约束"类建议前，先读目标文件自己的注释** —— 本项目的
      `.fdc` / `.pds` 头部埋着大量"试过、不行、原因"的记录，一条 grep 就能避免重踩。

54. [!] **双发射下 `commit + stall + mul + flush` 【不是】周期划分（2026-10-12 实踩，A4）**
    单发射时这条闭合式**精确成立**（`288,056 + 20,720 + 9,396 + 45,343 = 363,515`），
    直接照搬到双发射会算出假的"未归类 6,912 拍"。实测分桶（互斥优先链）：

    ```
    region cycles    : 232,345
    region commit    : 214,703
    region noretire  :  17,642   ← 正确口径 = cycles − commit（7.59%）
      mc_stall 占    :       0
      load-use 占    :      68   ← 只有 68！停顿拍大多【同时也在退休】
      冲刷当拍占     :     263
      重定向 3 拍内  :   5,197   ← 前端重填（分支代价的一部分，不是独立的一类）
      [!] 真正无解释  :  12,114   ← A4 的真目标（5.21%，比假数 6,912 还大）
    ```

    **根因**：停顿（load-use）发生在 lane A，而**同拍更老的指令仍能退休** ⇒ `stall` 拍
    与"退休拍"大量重叠，四项相加**会多算**。`+PROF` 的 `region stall`（6,904）也不是
    "没退休的拍数"。
    **⇒ 规矩**：双发射下判"有多少拍没干活"用 **`cycles − commit`（`region noretire`）**，
    不要用四项相加。**新增 `+PROF` 的 5 个互斥桶之和必须等于 `tc_noret`**，用它自检。

55. [!] **rtthread 线（以及一切非 coremark 固件）上板前必须补 Cache 开关仿真**（2026-10-14 实踩）：
    `scripts\rtthread\run_sim.ps1` 编译 `tb_rtthread` 时**不带任何 `-D` 旗标**（连 `-DDUAL` 都没有，
    而板上 `cpu_top` 默认 `DUAL_ISSUE=1`/`EARLY_LD=1`）⇒ **RT-Thread 线的仿真一直只覆盖"无 Cache"**
    单配置，`EARLY_LD`/Cache 的板级行为在 rtthread 固件上从没被仿真过。本次 rtthread + I+D
    @76.5 位流（`c10a2478`）就这么漏过去：构建全链路自证都过（网表 `dcache`1188/`icache`1208/
    `tag0`205 ✓；CPU 域 **+0.904 ns / 0 失败端点**，76.5 MHz 连 CDC 都收敛 ⇒ 全设计 0 失败端点），
    **上板却确定性挂死**——三次抓取逐字节相同，只有一行 `?? turn=WHITE`（原始字节 2 个高位字节
    + BEL，见约定 55），程序在"AI 第一手后的第一张棋盘快照"处损坏并挂死（无 `[hb]`）。
    **同一固件在无 Cache 位流 `8894cdcb` 上完全正常** ⇒ 疑 I+D + `EARLY_LD` + 中断/上下文切换
    路径上的 RTL bug（约定 47 同族——那次的触发条件正是 `ICACHE_EN=1` 提供的大量停顿）。
    * **⇒ 规矩**：`tb_rtthread` 要补 `-DDUAL/-DEARLYLD/-DDCACHE/-DICACHE` 开关（照 `tb_coremark`
      的写法）并核对 vvp 首行 `SIM CONFIG:`；**修好前 `c10a2478` 只是"综合验证通过"的存档，
      不是可交付版**。
    * **[OK] 2026-10-14：开关已补（`-DCache/-ICache/-RxTrace`），归因做完了。**
      仿真 100 MHz 下四种配置对拍：**无 Cache = PASS(168B)**；
      **只开 D = 崩**（走得较远：两条线程都起来了，之后寄存器转储）；
      **只开 I = 崩得早（13B）**；**D+I = 同样 13B**。
      ⇒ **不是"有 Cache 就不行"，是"带 Cache 的 RT-Thread 固件不行"，且【两个 Cache 都能打挂它】；
      是【功能 bug，与时序无关】。** 已排除：trap 路径本身（`exceptions`/`timer_irq`
      在 `-ICache` 下都 PASS）、地址截位（`imem_addr` 是 14 位字地址，覆盖全 64 KB）、
      MMIO 被缓存（`ram_hit = addr[31:16]==0` 门控，显存在 `0x8003_xxxx`）。
      **最强怀疑（未证实）**：两个 Cache **没有任何流水线重定向输入**，而 `cache_i.v`
      的正确性建立在"停顿期间地址冻在 A"上 —— 可 `fetch_addr`(core.v:330) 的优先级里
      `trap/ex_flush/ex_mispred/p_redirect` **都排在停顿回退之上**；CoreMark 不开定时器
      中断所以从没暴露。**全文见 `doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`。**
    * 另：**rtthread + D-Cache only @85MHz 位流【已经存在】** —— 10-14 00:57 那颗
      （合并日志 `DCACHE_EN=1/ICACHE_EN=0`），CPU 域 **−0.177 ns / 13 失败端点**（时序不过）
      **且功能上也打挂 RT-Thread**，同样**勿烧**。10-13 23:40 那次是**更早的一次中断构建**
      （`.sbit` 从未落盘）。
    * [!] **被中断的构建会留下 `cpu_top.v` 的 `DCACHE_EN=1` 不还原**（`finally` 没跑到）——
      下次构建前先 `git diff rtl\top\cpu_top.v` 看一眼，否则 `-Cache` 会把 `DCACHE_EN=1` 当"原值"。

56*. [!] **`serial_monitor` 日志里的 `?` 不一定是固件打的 `?`**（2026-10-14 实踩）
    （编号说明：本条与下一条都写成 56，历史遗留。**各处文档引用的"约定 56"是下一条**
    —— ID/EX 清零门控；本条按"串口字节解码"找。）
    `serial_monitor.ps1` 用 `$sp.ReadExisting()` 且**从未设置 `$sp.Encoding`** ⇒ .NET `SerialPort`
    默认 **ASCII 解码，每个 ≥0x80 的字节在日志里一律变成 `?`（0x3F）**。本次挂死现场那行
    `?? turn=WHITE` 的原始字节是 `3F 3F 07 20`（两个高位字节 + BEL +空格）——固件实际发出的是
    **损坏的数据**，不是字符串里真有 `?`（`scripts/gomoku` 里根本没有 `?` 字面量，别去源码里找）。
    **⇒ 规矩：串口日志里看到成片 `?`，先 `Format-Hex` 看原始字节再下结论。**

56. [!] **流水线级寄存器的"清零"必须门控 `mem_ready_int`；`trap` 例外**
    （2026-10-14 实踩 —— **Cache + RT-Thread 挂死的根因 #1**）。
    `core.v` 的 ID/EX 寄存器原来写作
    `if (!resetn || ex_flush || ex_mispred || stall_int || trap)` 就清成气泡。
    但 **`ex_flush`/`ex_mispred`/`stall_int` 都是【EX 里那条指令自己】发出的**
    （jal/jalr/分支 / load-use）：流水线被访存停顿冻结（`mem_ready_int=0`）时整条流水线
    不能平移，ID/EX 里躺着的就是**那条发冲刷的指令本身** ⇒ 清它 = **把它自己杀掉**
    ⇒ 它进不了 EX/MEM ⇒ **`jal/jalr` 的链接值写回永久丢失**。
    * 修法一行：`if (!resetn || trap || ((ex_flush||ex_mispred||stall_int) && mem_ready_int))`。
      即**照抄 EX/MEM 的门控**（A.0 修复，`core.v:1474-1482` 的注释已经把道理讲透了，
      ID/EX 侧漏了同一刀）。`trap` 保持无条件（肇事指令必须死，约定 20）。
    * 复现：`scripts\rtthread\run_sim.ps1 -ICache`。修前**全程只 13 字节**挂死；
      修后完整启动（banner + render/AI 两线程 + 心跳窗口内到位）。
    * 为什么一直没被发现：`mem_ready_int=0` 原来只在真访存停顿（`+MEMWAIT`）出现，
      撞上"跳转在 EX 解析"那一拍概率极低；**带 Cache 后取指链几乎每拍停顿**（冷启动
      每次取指都缺失）⇒ 撞上概率≈1。CoreMark/riscv-tests 都盖不住。
    * [!] **同类推广：任何"冻结拍更新"的级间寄存器都要问一句"它服务的是哪一级、
      冻结时该保持还是该清"**（同理见约定 47 的快照同源、约定 51 的 mul 使能同源）。
    * 全套证据链与工具见 `doc/reports/2026-10-14_cache_fix_bug1.md`。
    * 这只是 #1；**#2 见下一条**（已修）。

57. [!] **EX 级的"副作用"必须门控 `mem_ready_int`，与"离开 EX"同拍 —— 不只是级间寄存器**
    （2026-10-14 实踩 —— **Cache + RT-Thread 挂死的根因 #2**）。
    **CSR 写是在 EX 级提交的**（约定 21），而"这条指令离开 EX"发生在 `mem_ready_int=1` 的
    那个沿（`EX/MEM <= ID/EX` 用的就是同一个条件）。两者不同源时，访存冻结那一拍 CSR
    **已经写进寄存器组**，而这条指令**仍旧停在 EX**（约定 56 的修复正是让级间寄存器在冻结
    期间保持）⇒ 下一拍 `alu_result = csr_rdata` 拿到的是【写后】的值 ⇒
    **`csrrw/csrrs/csrrc` 的 `rd` 被写成新值而不是规范要求的旧值**。
    * 修法：`assign csr_wr_en = csr_wr_en_raw && !trap && mem_ready_int;`，并把送给
      `csr_file` 的 `.mret()` 改成 `mret_commit && mem_ready_int`（同族：`mret` 的
      `mstatus.MIE ← MPIE` 也不该在冻结期间重复施加）。重定向仍走 `mret_commit`。
    * **触发条件极窄**，所以三条基线全都盖不住：要同时有 ①**访存冻结**
      （`mem_ready_int=0`，无 Cache 时恒 1，只有开 Cache / AMO 才出现）
      ②一条**写 CSR 且 `rd != x0`** 的指令（读只读 CSR 的 `csrr` 不受影响 —— CoreMark
      只有这类，所以 I+D 下也不炸）。RT-Thread 的中断入口/出口各有一条
      `csrrw sp, mscratch, sp`（**rd 就是 sp**）⇒ 冻结撞上它，**sp 不切到中断栈**、
      处理函数跑在线程栈上，出口那条再把 `mscratch` 写坏 ⇒ 之后每次中断 sp 漂移 ⇒
      踩坏内核链表 ⇒ `cause=6`（`sw a4,4(a3)`）死循环转储。
    * **决定性证据**（同一处的"处理函数 C 帧落点"）：无 Cache 金标准 = `0xffec`（中断栈
      `__rt_rvstack` 顶 `0xfff0`）；`-ICache` 修前 = **`0xb490`（线程栈！）**；修后 = `0xffec` ✓。
    * 复现/验证：`scripts\rtthread\run_sim.ps1 -DCache -ICache`（修前崩、修后 PASS），
      四种配置（无Cache/只D/只I/I+D）修后**全部 PASS**。
    * **⇒ 推广（本轮最该记住的一句）**：不止级间寄存器，**任何"只该发生一次的 EX 级副作用"**
      （CSR 写、`mret` 的 mstatus、将来的 fence/AMO 提交、外设写选通……）都要问一句
      "它和谁同拍提交？冻结时会不会被重复/提前施加？" 同族：约定 47（快照选源）、
      约定 51（mul 使能）、约定 56（级间清零）；`mem_bus.v` 的外设写 one-shot
      （`bus_first`）也是同一个问题的另一种解法（"只准第一次那拍发生"）。
    * [!] **诊断方法（可复用）**：先用 `-DLDCHK`（`run_sim.ps1 -LdChk`）把
      "某条 load 读错了吗"变成可判定问题（影子寄存器与 MEM/WB **同门控**镜像，
      期望值取 `mem0[addr]` 按 funct3 解包）—— 本次实测 **297,379 条 RAM load 一条不错**，
      于是"load 返回错数据"被证伪、嫌疑正确挪到"寄存器值/中断路径"。
      再用**规范化事件流**（`rtthread_ldtrace.txt`，load 记 WB 沿/store 记 MEM 沿、停顿折叠）
      对拍两份日志定位首处分叉；**注意中断落点本身是随机的**，别把"中断插在不同指令处"当成 bug。
    * 全套证据链见 `doc/reports/2026-10-14_cache_fix_bug2.md`。

58. [!] **位流的身份只认 RTL 侧的 `mimpid`（串口 `RTL=` 行）；固件里不许写死任何频率字面量**
    （2026-10-14 实踩 —— 差点把"修好了"误判成"烧错了"）。
    **现象**：烧了 **76.5052 MHz** 的 rev1019 位流（`90944754`），串口横幅却打
    `RV32IMA + RT-Thread + GOMOKU(G3) @85.0051MHz` —— 看着像烧了 85 MHz 那颗。
    **原因**：`scripts/rtthread/app/main.c` 把主频当**字符串字面量**写死了（不是从
    `BOARD_SYSTEM_CLOCK_HZ` 算的）。同一份固件要装进 85.0051 / 76.5052 两种位流，
    写死的那份在另一种上必然打错。已改成从宏算（`app/main.c:173`）。
    * **⇒ 规矩 1**：固件里出现的"频率/版本/口径"数字，凡是**由 RTL 或编译宏决定的**，
      一律**算出来**，不许写字面量（版本号的正解见约定 42 的 `mimpid`）。
    * **⇒ 规矩 2**：判"烧的是哪颗位流"**只看** `RTL=0x…`（RT-Thread 侧与五子棋侧各打一行）；
      横幅那行是**固件的自我介绍**，换固件/换频率档都可能与位流不一致。
    * **⇒ 规矩 3（旁证）**：串口文本能在 115200 下**完整可读**，就说明**位流里的 PLL 频率与
      固件编译时的频率一致**（`UART_DIV` 是按那个频率算的，偏 10% 就乱码）—— 这是不用仪器
      就能做的时钟旁证。
    * 同病的还有 `scripts/demo/addr_map.h:68` 的 `CPU_HZ 85005100u`（喂 `hw_ticks_per_ms()`）：
      76.5 档下 long-press 阈值 ≈0.67 s、AI 打印 `t=…ms` 约低 10%。**纯阈值/显示**，
      但修它要绑到 `BOARD_SYSTEM_CLOCK_HZ`（会同时改裸机五子棋与仿真的去抖口径，需回归）。

## 待办
-  **[OK] 2026-10-14 B1-BTB（分支目标缓冲，赛题点名项）已完成 —— v11 §3 任务表四项全完**：
  256 项**直接映射** BTB（索引 `pc[9:2]`、tag `pc[31:8]`，与 BHT 同形），**只预测间接 `jalr` 目标**
  （条件分支/`jal` 的 `PC+imm` 现算已对，不重复存）。到达级命中即折进**既有的** `p_target` 腿
  （优先级 **RAS > BTB > PC+imm**），**绝不新增 `fetch_addr` 的腿**；EX 级提交那拍训练（门控同 RAS：
  `mem_ready_int && !mc_stall && !trap && id_ex_jump_reg`）。v10 §7 校验**放宽到所有被预测的 jalr**
  （`id_ex_pred_taken` 门控 ⇒ 没被预测的 jalr 逐位不变；`imm≠0` 强制冲刷 ⇒ 不比"不预测"差；`imm=0` 仍用
  `rs1_val & ~1` 直比，**不碰 `ex_target` 加法器**）。`parameter BTB_EN=1`（默认开）+ `-DNOBTB` 配置自证。
  **收益在功能分/赛题点名，不在跑分**：CoreMark 的 `jalr` 几乎全是 `ret`（已被 RAS 99.9%+ 捕获），
  BTB 只触发 44 次且全在计时区外 ⇒ **`region commit` 214,703、`region cycles` 229,597、四 CRC 逐位不变**
  （既证没算错，也说明"跑分不变"证明不了 BTB 有效）。**故新增测试 + 探针**：`sim/tests/btb_indirect.S`
  （非 call/ret 间接跳转，只有 BTB 能预测；稳定目标省拍 + 交替目标逼 §7 纠正）+ `+BTBTRACE` 探针
  （实测 `btb pred=15/train=15` 开 vs `0/0` 关，省 16 拍）。**"§7 承重"已证**：弄坏 §7（`ex_target_wrong` 置 0）
  ⇒ `btb_indirect` **FAIL(testnum 2)**；精确 Edit 还原、`git diff` 核对。回归（双发射口径）：riscv-tests 默认与
  Cache corner 均 **49/1/0**、`run_own_tests` **5/0**（含 `btb_indirect`）、CoreMark 逐位不变、rtthread 四配置 PASS。
  **[坑·实测]** 交替目标测试**阶段 2 若用两段独立循环体**，错误路径会"自收敛"到同一结果（都 =34）⇒ 弄坏 §7
  也 PASS、判不出来；改**共享循环控制块 + 差异大的加数(+1/+100) + 6 次**（期望 303）才成为承重判据。
  **`DESIGN_REV → 0x2026_1022`；改过 RTL ⇒ 上板前必须重出位流。** 详见 `doc/reports/2026-10-14_session_state.md` §9。
  **[!] 时序是唯一代价**：CPU 域 **+0.311 → +0.034 ns / 0 失败端点（20,507）** —— 仍为正（过红线，BTB 默认保持开），
  但只剩 **0.29% 周期**、在 ~5.7% 综合噪声内。**后备**：BTB 缩到 **64 项**（读 mux 更浅）→ 仍负则 `BTB_EN` 默认改 **0**。
-  **[OK] 2026-10-14 AMO 后紧跟分支走错路径的 RTL bug 已修（同族第三条：门控的是"源"）**：
  `tb_amo_cpu.S` 从旧协议转 tohost 判分后首次端到端跑即 **FAIL(testnum 9)** —— 根因是
  `core.v` 的 `ex_flush`/`ex_mispred` **源**没门控 `mem_ready_int`：AMO/LR/SC 占 MEM 的 4 拍里
  前递的 `amo_wb_data` 是**上一条** AMO 的陈旧值，紧跟其后的分支据此解析错方向，而
  `ex_flush` 在 `fetch_addr` 里高于冻结兜底、IF/ID 冲刷又没门控 ⇒ 错误路径被提交。
  修法 = `ex_flush`/`ex_mispred` 各加 `&& mem_ready_int`（只影响冻结拍；`p_redirect`/ID/EX 清/
  EX/MEM 本就已门控，行为不变）。`DESIGN_REV` → **`0x2026_1020`**（**RTL 动过 ⇒ 上板前必须重出位流**）。
  回归（双发射口径）：riscv-tests 默认 **49/1/0**、CoreMark `-Iter 1 -EarlyLd` **232,345 + 四 CRC 全对**、
  rtthread 四配置（无/D/I/I+D）**全 PASS**、`run_own_tests` **3/0**（新增 `tb_amo_cpu`）；
  "弄坏 `amo_unit`（`F5_AMOMAX` 改无符号）能 **FAIL(testnum 5)**"已验证并还原。
  四条基线**一条 AMO 都没有** ⇒ 该 bug 此前完全不可达。详见 `doc/reports/2026-10-14_session_state.md`。
-  **[OK] 2026-10-14 覆盖 B（`hi_fetch.S`，取指越过 0x8000）已完成**：
  64 KB 扩容后无任何程序取指越过 `0x8000` ⇒ `imem_addr2` 截位 bug（`f72ef25` 修）通路零覆盖。
  新增 `sim/tests/hi_fetch.S`：运行时把一段 `addi t2,t2,1`×2048 的代码【拷到 0x9FFC】再跳过去执行，
  低地址 0x2000 放 `addi s0,s0,1`×2048 毒丸；判据 `s0==0 && t2==2048`。`run_own_tests` **4/0**
  （新增 `hi_fetch`）。**"弄坏能 FAIL"已验证**：临时把 `core.v` 的 `imem_addr2` 掩成 `[12:0]`（只掩码、
  不改宽度 ⇒ 不触发宽度守卫）→ `hi_fetch` **FAIL(testnum 1)**、同一条弄坏下低地址 `tb_amo_cpu` 仍 PASS；
  **精确 Edit 还原**（**没 `git checkout core.v`**，它含上一条未提交的 AMO 修复），`git diff` 核对只剩那两行。
  **本任务未动 RTL**（无需重出位流）。详见 `doc/reports/2026-10-14_session_state.md`。
-  **[OK] 2026-10-14 B1-RAS（返回地址栈，本轮真正拿分的一项）已完成**：
  16 项 RAS（`RAS_DEPTH=16`）。`call`（`jal`/`jalr` 且 `rd∈{x1,x5}`）在 **EX 级提交那拍** push `id_ex_pc+4`；
  `ret`（`jalr x0,0(x1|x5)`）在**到达级**命中即 `p_target = ras_top`、同拍重定向（**不新增 `fetch_addr` 的腿**，
  折进既有的 `p_target`）；`p_pred_taken=1` ⇒ 独占、`pair_now=0`。配套 **v10 §7 预测目标校验**：`ret` 预测目标
  与真实链接值不符即并入 `ex_flush` 纠正（**功能正确性靠它兜底**）。
  **收益**：`region cycles 232,345 → 229,597`（**−2,748 / −1.18%**），而 **`region commit` 逐位不变 214,703**
  （最灵敏探针 ⇒ 省的全是冲刷气泡）、`region flush 5,645 → 2,452`；四 CRC 全对。`DESIGN_REV → **0x2026_1021**`。
  **[坑·实测]** §7 若直接比 `ex_target != id_ex_pred_target`，会把 ~2 ns 的 `ex_target` 加法器拽进取指临界路径
  ⇒ 时序 **−0.271 ns / 66 失败端点**（基线 +0.068/0）。改法 = **只对 `ret` 比对**、直接用 `rs1_val`
  （`(rs1_val & ~1) != id_ex_pred_target`）、`imm≠0` 强制冲刷，绕开该加法器 ⇒ **+0.311 ns / 0 失败端点（18,122）**。
  回归：riscv-tests 默认与 Cache corner 均 **49/1/0**、`run_own_tests` **4/0**、rtthread 四配置全 PASS。
  **改过 RTL ⇒ 上板前必须重出位流。** 详见 `doc/reports/2026-10-14_session_state.md`。
-  **[OK] 2026-10-14 Cache + RT-Thread 挂死的两条根因都【已修】**：
  * **#1**（约定 56）：`core.v` ID/EX 清零漏门控 `mem_ready_int`，1 行；
  * **#2**（约定 57）：CSR 写（+`mret`）漏门控 `mem_ready_int`，1 行 ——
    RT-Thread 的 `csrrw sp, mscratch, sp` 在冻结拍读到写后值 ⇒ sp 不切中断栈 ⇒ 链表被踩坏。
  `DESIGN_REV` → **`0x2026_1019`**。
  仿真验证（`-NoBuild`，同一份固件）：**rtthread 四种配置（无 Cache/只D/只I/I+D）全部 PASS**；
  riscv-tests 默认与 `-DCache -ICache -EarlyLd` 均 **49/1/0**；CoreMark `-Iter 1 -EarlyLd`
  **232,345 一字不差**；`run_own_tests -DCache -ICache -EarlyLd` 3/0。
  详见 `doc/reports/2026-10-14_cache_fix_bug1.md` 与 `..._bug2.md`。
-  **[OK] 横幅自洽版位流已重出（2026-10-14 14:34，rev 1019）**：
  `bitstreams/rtthread_..._idcache_76mhz_rev1019_53b81dfe.sbit` —— **RTL 与 `90944754` 逐位相同**
  （网表 `dcache`1190/`icache`1216/`tag0`196、CPU 域 **+0.534 ns / 0 失败端点（18,997）**、
  `All Constraints Met`），**只换固件**（横幅主频改成算的 ⇒ 打 `@76.5052MHz`）。**推荐烧这颗。**
  顺带：`build_bitstream.ps1` 的 `expectLines` 因固件改动从 20270 → **20276**（守卫按设计拦下了一次），
  构建日志也改成从 `board.h` 读频率打印（约定 58）。约定 50 的四件套**已全部还原并核对**。
-  **[OK] 更早一颗（2026-10-14 13:48，rev 1019）**：
  `bitstreams/rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_idcache_76mhz_rev1019_90944754.sbit`
  （rtthread + I+D @76.5052 MHz；网表自证 `dcache`1190/`icache`1216/`tag0`196；
  `All Constraints Met`，CPU 域 **+0.534 ns / 0 失败端点（18,997）**，CDC 0 失败；
  首行自证 **`RTL=0x20261019`**）。约定 50 的四件套**构建后已全部还原**。
  `c10a2478`（I+D@76.5）/ `9feaa089`（D-only@85）仍是 **rev 1017 旧 RTL，仍【勿烧】**；
  `9feaa089` 另叠时序问题（CPU 域 −0.177 ns / 13 失败端点）⇒ 塞不进 85 MHz。
-  **[OK] 2026-10-14 13:59 上板（串口侧）通过**（`doc/board/uart_20261014_135935.txt`）：
  `RTL=0x20261019`（两侧自证）+ render/AI **两条线程都起来** + `[hb] alive, uptime 5000…20000`
  每 5 s 一条、**全程无断** ⇒ **"带 Cache 必挂"的组合现在通了**（对照修复前：`c10a2478` 死在
  AI 第一手后的棋盘快照、`9feaa089` 卡在 `heap = 9368 bytes` 循环重启）。
  **⇒ "Cache 可用"这句话现在成立**（限 rtthread + I+D @76.5052 MHz 这颗）；生产/交付档继续
  Cache 全关（`8894cdcb` / `bcd8fdd2` —— 那是**性能/评分**判断，不是功能问题）。
  **14:11 追加验证**（`doc/board/uart_20261014_141147.txt`，413 行）：真按键**完整下完一局并判出
  `WHITE wins`**、难度切换/复位全有响应、AI 线程真在算（HARD `nodes=10592 depth=6 t=5737ms`），
  且**用户接 HDMI 显示器下棋正常** ⇒ 落子/对局 + 显示侧都已验。
-  **[!] rev1017 的生产档（Cache 全关）要不要重出？—— 功能上【不必】，口径上【建议】**
  （2026-10-14 定论，判据写进 `pds/RV32I_1/bitstreams/README.md` 文首）：
  `rev1017→rev1019` 只差两处门控（都在 `rtl/core/core.v`），而 **Cache 全关时
  `b_ready = 1'b1` 是硬连线（`rtl/mem/unified_mem.v:80`）⇒ `mem_ready_int ≡ !amo_hold`**；
  两个交付固件（跑分档 `-march=rv32im_zicsr`、rtthread 档实测 0 条 AMO/lr/sc）**都不含 AMO**
  ⇒ `mem_ready_int ≡ 1` ⇒ 两处修复恒为真 ⇒ **逐位等价**。
  **但它们的 `mimpid` 是 `0x20261017`**，与"当前 RTL=rev1019"的口径对不上。
  要统一就重出（各约 10 分钟，85 MHz 不降频；重出后分数/CRC 应逐位相同）。
-  **[!] `vblank timeout` 的性质（2026-10-14 查清）**：它**不是显示坏了**（用户已接屏下棋），
  而是**"vblank 等待变成了一次概率事件"**：RT-Thread 侧 `video_vblank_yield()` 是 `mdelay(1)`
  ⇒ 采样周期 ≈1 ms，而 `rtl/video/video_core.v:139` 的状态位是 **62.7 µs** 的 vsync 脉冲
  ⇒ 命中率量级 **6~12%**，等不到就由 **50 ms 超时**兜底返回（告警只打一次）。
  三种处理（兜底降级日志 / 换成 1.04 ms 消隐窗 / **加只读帧计数器，推荐**）见
  `doc/board/README.md` 的 rev1019 那节。归口：`rtl/video/**` 属视频线（要申请）。
-  **[!] 横幅主频写死**（2026-10-14 实踩，**源码已修 + 位流已重出 `53b81dfe`**）：`app/main.c` 把
  `@85.0051MHz` 写成字符串字面量 ⇒ 76.5052 那颗位流也照打 85.0051，**看着像烧错位流**。
  已改成从 `BOARD_SYSTEM_CLOCK_HZ` 算（`app/main.c:173`）。**⇒ 规矩：日志里出现的频率/版本数，
  RTL 侧的只认 `mimpid`（`RTL=` 那行），固件侧不许写死任何频率字面量。**
  另：`scripts/demo/addr_map.h:68` 的 `CPU_HZ 85005100u` 也有同病（喂 `hw_ticks_per_ms()`），
  76.5 档下 long-press 阈值 ≈0.67s、AI 打印 `t=…ms` 约低 10% —— **纯阈值/显示，未动**。
  > CoreMark 的 I+D@76.5 档（`c6b12d95`，rev 1016）**没有重出** —— 它本来就是通过的，
  > 且 CoreMark 不含"写 CSR 的指令"⇒ 本次修复对它逐位等价（要用新 rev 的话再跑一次
  > `build_bitstream.ps1 coremark -Cache` + 降频四件套即可）。
-  **[OK] 本轮新增的调试开关**（都在 `scripts/rtthread/run_sim.ps1`）：
  `-RxTrace` / `-PcTrace` / `-ITrace` / `-TrapTrace` / `-LTrace` / **`-LdChk`**（load 自检
  + 规范化访存事件流 `rtthread_ldtrace.txt`，**别指望靠 trap_tval 猜寄存器，先用它把
  "load 读错了吗"判死**）；
  两个对拍脚本 `scripts/pctrace_diff.py`（PC 流）与 `scripts/itrace_stream_diff.py`
  （指令流，**配对感知，推荐**——`pc` 流在双发射下会因配对差异假分叉）。
  > [!] 规范化事件流对拍时记住：**中断落在哪条指令上是随机的**（无害），别把
  > "中断插在不同指令处"当成 bug；**但"被冻结的中断"是有害的**。
-  **[OK] 2026-10-12 I+D 板上失败的根因已定位并修复**（`core.v` 的 `wb_rdata_snap`
  停顿快照取错流水级，一行；见约定 47 与 `doc/reports/2026-10-12_icache_wb_snap_fix.md`）。
  **[OK] 位流已出（2026-10-12 晚）**：85 MHz **仍不收敛**（−1.143 / 343 端点），
  **76.5052 MHz 收敛**（setup **+0.589** / hold +0.147 / 失败端点 0）⇒ 交付位流
  `bitstreams/coremark_dual_aext_ms_earlyld_idcache_76mhz_rev1016_c6b12d95.sbit`
  （`DESIGN_REV` 已按约定 42 递增到 `0x2026_1016` ⇒ 串口首行 `RTL=0x20261016`）。
  全流程见 `doc/reports/2026-10-12_idcache_board_bitstream.md`。
  **[OK] 2026-10-12 15:59 已上板通过**（`doc/board/uart_20261012_155934.txt`）：
  `RTL=0x20261016`、`Total ticks 894,745,801` → **11.6952 s / 313.63 分**、
  四个 CRC 逐位相同、`Correct operation validated`、**`[cache] I`/`[cache] D` 都非 0**
  （I 98.985% / D 99.929%）⇒ **I/D Cache 上板任务完成**。
  性能：相对 351.86 分 **−10.9% = 主频 −10.0% + 周期 −0.95%** ⇒
  **I+D 的代价几乎全在主频，Cache 周期代价只有 +0.95%**（文档旧写 +9.8% 的口径错）。
  > [!] 顺带更正：I+D 的真实周期代价是 **+0.99%（244,034 拍/迭代）**，不是文档旧写的
  > **+9.8%**（那是**漏了 `EARLY_LD`** 的口径，265,408）⇒ `ITER` 取 **3668**。
-  **[!] 交接给队友看这两份（2026-10-11 晚）**：
  * **`doc/reports/2026-10-11_taskbook_v7.md` 的 §8** —— 现状 + Cache 阶段性总结 +
    交接清单（P0 = 提高双发射配对率；P0-2 = 解 Cache 布局拥塞）+ 纪律。
  * **`doc/reports/2026-10-11_rvc_feasibility.md`** —— RVC 评估：**收益 ≈ 0，不做**
    （实测指令条数 +0.7%，只有编码 −17%；对手领先是 IPC 1.06 vs 0.89，不是 RVC）。
-  **【当前主线】任务 C：已做成第一步（`EARLY_LD`，−7.79%，见约定 45）。**
  **[OK] 已上板：351.8 分**（位流 `2ddaf32f`）。
  **下一步二选一**：
  * **[OK] 上板验证（A1 之后）已完成（2026-10-13）**：ITER=4280（`build_bitstream.ps1` 已改默认值），
    板上 `Total ticks 994,229,330` → **365.93 分**（A1 前板上 351.86 → **+4.0%**），位流 `bcd8fdd2` / `RTL=0x20261017`。
  * **继续压**：约定 45 末尾两条剩余项（基址在 EX 1.81% / 紧前是 store 0.71%）。
-  **【其后】Cache 重估**：任务 C 做完再回头看（C 不自动让 Cache 收敛，约定 43）。
-  **【应用场景线】RT-Thread + 五子棋 —— [OK] 已做成并上板（2026-10-13 口径）**
  > [!] **下面"掌上游戏机 + 买 SPI TFT"那版 2026-09-25 计划已被现实取代，别再照它开工**：
  > 显示最终用的是**板载 HDMI**（**没买 SPI TFT**），游戏做的是**五子棋**（不是平台跳跃）。

  | 任务 | 状态 |
  |---|---|
  | **RT-Thread Nano 移植** | [OK] **已完成并上板**（`scripts/rtthread/`；BSP / 中断栈切换 / 静态线程见其 `README.md`）|
  | **显示** | [OK] 走**板载 HDMI**（640×480@60Hz，TMDS 编码，`rtl/video/`）|
  | **游戏本体** | [OK] **五子棋**（`scripts/gomoku/`）：HDMI 出棋盘 + 4 键操作 + **串口棋盘镜像**（无显示器也能验）；素材原创 |
  | **T1/G3 拆线程**（render 高优 + AI 低优两条线程）| [OK] **2026-10-13 已并入并首次上板**：位流 `8894cdcb`，日志 `doc/board/uart_20261013_224652.txt`。**两线程邮箱往返真通**（`AI moved, nodes=10592 depth=6 t=5068ms`），对局/按键/轮次全对 |
  | [!] **"AI 思考期间画面不卡"（G3 的正题）** | [ ] **尚未验证** —— 那次上板**没接显示屏**；另有 `[!] vblank timeout` 待定案（机制 + 一步判据见 `doc/board/README.md`）|
  | 收尾（报告 + 录像）| [ ] 仍缺录像/照片（`doc/board/` 只有串口文本与 ILA 波形）|

  **交给队友接着做的入口（2026-10-13 已出正式任务书）**：
  **`doc/reports/2026-10-13_taskbook_gomoku_v2.md`**（= 发出去的 `RISC-V_五子棋任务书_v2_20261013.md`，
  自包含：T1 的两件收尾 + T2~T5 + 与 CPU 线的文件划分）。
  T1 的过程细节仍在 `doc/reports/2026-10-13_T1_rtthread_g3_checklist.md`。
  **历史存档**（2026-09-25 那版计划书与进度报告，**口径已过期**）：
  `doc/reports/2026-09-25_handoff_rtthread_gameconsole.md`、`doc/reports/2026-09-25_progress_report.md`。

  **赛题对齐（2026-09-25 首次核对；2026-10-12 更新了 Cache 一行）**：基础任务 3 条**全达标 [OK]**；高阶任务：
  | 高阶任务 | 赛题原文要点 | 我们 |
  |---|---|---|
  | ① 存储优化 | 2 路组相联 I/D Cache + 总线突发 | **[OK] I/D Cache 已实现并上板**（4 KB/侧、2 路组相联，2026-10-12）——但**默认关、判定为负收益**（约定 43）。**总线突发未做。** 答辩口径："实现并量化评估后判定为负收益" |
  | ② 高级控制 | **动态分支预测器（如 BTB）** *以及* **完整异常/中断机制** | **[部分] 异常/中断【已完整】**（09-23）；动态分支预测**只做了方向（BHT，09-25）**，**赛题点名的 BTB（目标）未做** —— 10-13 实测判定 BTB 低收益、正解是 RAS，**两者都还没落地**（见 `doc/reports/2026-10-13_handoff_btbras.md`）|
  | ③ AI 加速 | YOLO / 轻量 LLM + 传感器 | [X] **硬件不可行**（32KB BRAM 硬墙，话术见 §3.2）|

  **总方针（2026-09-25 用户已定）：高阶任务选做，性能优先。** 不适配架构的宁可不做。
  > [!] **2026-10-12 翻案注**：上表①已翻案 —— I/D Cache **已实现并上板**
  > （4 KB/侧、2 路组相联；结论 = 对分数贡献 0、价值在功能条目，见 `doc/spec.md` §4.4）；
  > 表中"32KB"均已变 **64 KB**（RAM 2026-10-10 扩容）。②里"BTB/BHT"这个写法**要更正**：
  > **设计里只有 BHT（方向），没有 BTB** —— 见上面「高阶任务②」那节的 [!]。
  **但写进报告的部分必须真实** —— 没做的就写没做，评委一验证就穿帮。

  **性能（[历史记录] 下表是 2026-09-25「49.89 MHz / 140.89 分」当时写的"已冻结"清单；
  2026-09-28 起已解冻，推进到两拍乘法器 + 85.0051 MHz 提频 + 顺序双发射 + **A1 乘法器 II=1**，
  板上实测最新是 **351.86 CoreMark**（85.0051 MHz 双发射 + `EARLY_LD`，**A1 前**）；
  **A1 后板上实测 365.93 分**（`bcd8fdd2`），见「当前进度」）：**
  | 可选项 | 收益 | 说明 |
  |---|---|---|
  | BHT 表扩容（256 → 1024/4096 项）| +1% | 别名冲突已定位（149/341 分支冲突）。改动小，但要**单独一次**做 |
  | 消除 load-use 停顿 | +5.8% | 风险高，有余力再说 |
  | 主频再提 | +4.2 MHz 空间 | 可达 54.0745 MHz，当前 49.8927 MHz |
  | ~~2 路组相联 Cache~~ | **（09-25 当时的判断）不做** | 单周期 32KB BRAM、工作集仅 16.4KB，**没有慢速后端可藏** → 命中 1 拍（零收益）、缺失 2 拍（纯亏）。**[!] 2026-10-11 已实现、10-12 已上板**，实测确认"收益为 0、周期 +0.95%、代价几乎全在主频" ⇒ 见约定 43。**这一行只代表 2026-09-25 那一刻的判断。** |

  > [!] **别把没把握的写成已完成**：MEIP 只有通路无测试、AI 完全不可行、
  > 未对齐访存不支持（`ma_data` FAIL 属架构取舍）。评委一验证就穿帮。
- [OK] **ILA 硬件在环抓波形已完成**（2026-09-25）——赛题点名要求的评分项。
  全链路：探针束（RTL 精确标记）→ 综合 86/86 存活 → Inserter 自动连线 →
  `.fic` 逐条核对 → 登记进 `.pds` → P&R（DRM 16→19 确认调试核插入）→ 烧板 →
  连 JTAG Server → 抓波形 → **收尾还原并逐项核对回基线**。
  * 波形证据：`doc/board/ila_hw_exflush_coremark.vcd`（**三种 BHT 行为的逐拍证据**）、
    `ila_hw_halt_loop.vcd`（停机自旋）
  * 方法、坑与逐拍解读：`doc/ila_analysis.md` §7
  * **调试版比特流已归档**（`bitstreams/debug_ila_86probe_localboard.sbit`，md5 `96ee7877`）
    —— **想补抓波形直接烧它 + 用 `cpu_top_board.fic` 即可，不用重做 Inserter/P&R**
- [OK] **两份历史交接报告已归档**（内容已并入进度报告，无需再读）：
  45 MHz 迁移（`reports/2026-09-25_45mhz_migration.md`）、队友 45 MHz 改动复核
  （`reports/2026-09-24_teammate_45mhz.md`）。
  > 队友那份里 `ipcore/unified_mem/`（+ `mem_init.hex`、`ip_backup/`）**是"加 IP 核失败"
  > 的产物，可删**。迁移时**故意没带**，我们仓库里本来就没有。
  > **别和 `rtl/mem/unified_mem.v` 搞混 —— 见关键约定 28。**
- **补 riscv-tests 源码**（可选）：放到 `third_party/riscv-tests`（需联网 clone）。
  **不补也能全量回归** —— `scripts
un_riscv_tests.ps1` 不带参数时会自动回退到随附的
  基线 ELF（`third_party/riscv-tests-elf/`，50 个 = rv32ui 42 + rv32um 8，已入库，约 650KB）。
  之所以把二进制入库：上游 riscv-tests 会变，重新 clone 未必复现同一批二进制，
  基线漂移会让人误以为是自己改坏了 CPU。详见该目录的 README。
- **演示视频/照片**：`doc/board/` 里目前只有串口文本和 ILA 波形数据，**缺录像/照片**。
- **高阶任务的剩余项**：
  - [ ] **外部中断 MEIP**：通路已具备（`cpu_top` 接了 UART RX 非空），但**没有测试**，
    不得当作已验证能力
  - [ ] BHT 表扩容 / **剩余 load-use**（基址在 EX 1.81% / 紧前是 store 0.71%）/ 主频再提 —— 见上面「性能已冻结」表
  - [x] **2 路组相联 I/D Cache：已实现并上板**（4 KB/侧，默认关；I+D @76.5052 MHz 实测 **313.63 分**）。
    **不是"没做"，是"做了、代价几乎全在主频"** —— 唯一值钱的方向是**把 I+D 的主频拿回来**（约定 43 / `taskbook_v8` §5.A）
  - [x] ~~边缘 AI~~：**32KB BRAM 是硬墙，硬件条件不可行**
