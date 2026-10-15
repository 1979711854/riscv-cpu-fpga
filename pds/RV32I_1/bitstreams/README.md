# 归档比特流（.sbit 本身不入库，只入库这份索引）

> `.sbit` 被 `.gitignore` 排除（9 MB/个）。**别人 clone 下来一个都没有，必须自己综合。**

> **[!] rev1017 的老位流要不要重出？（2026-10-14 实测定论：**功能上不必，时序上不能**）**
> `rev1017 → rev1019` 的 RTL 差异只有两处**门控**（约定 56 的 ID/EX 清零、约定 57 的 CSR 写/mret，
> 都在 `rtl/core/core.v`；`rtl/mem` / `rtl/bus` / `rtl/video` **一行未动**）。
> 而 **Cache 全关时 `ram_ready = b_ready = 1'b1`（`rtl/mem/unified_mem.v:80` 硬连线）**
> ⇒ `mem_ready_int ≡ !amo_hold`；**两个交付固件都不含任何 AMO/lr/sc**
> （跑分档 `-march=rv32im_zicsr`，编译器根本发不出；rtthread 档实测 ELF 里 0 条，原子走软实现）
> ⇒ `amo_hold` 永不成立 ⇒ **`mem_ready_int ≡ 1` ⇒ 两处修复的 `&& mem_ready_int` 因子恒真
> ⇒ 功能逐位等价**。
>
> **[!] 但 2026-10-14 真的重出了两颗 85 MHz 生产档，结果【时序不过】**：
> | 重出件 | md5 | CPU 域 `u_pll→u_pll` | 失败端点 | 结论 |
> |---|---|---|---|---|
> | CoreMark @85.0051（ITER=4280） | `aad1e2ac` | **−0.153 ns** | **16 / 16,581** | `Some Constraints Violated` ✗ |
> | rtthread 五子棋 @85.0051 | `382ce876` | **−0.153 ns** | **16 / 16,581** | 同上（两次独立运行**逐位相同** ⇒ 确定性，不是 8-seed 抖动）|
> | 对照：rev1017 的 `bcd8fdd2` | — | **+0.068 ns** | **0 / 17,216** | 达标（且已板级验证 365.93 分）|
>
> ⇒ **结论：生产/交付档【继续用 rev1017 的 `bcd8fdd2` / `8894cdcb` 】，不要换成 rev1019。**

> **[OK] 2026-10-15 更新：这条结论【对 rev1019 成立，对 rev1022 已不成立】—— 生产档可以升级了。**
> rev1022（= rev1019/1020 + **B1-RAS/BTB**）的 85 MHz 生产档**实测达标**：
> * 跑分档 `f64b977`：CPU 域 **+0.034 ns / 0 失败端点（20,507）**，且**已上板 370.23 分**（10-14 23:39）
> * 演示档 `176e0028`（本轮重出的 rtthread 五子棋）：**同样是 +0.034 ns / 0 / 20,507**
>   —— 与跑分版**逐位一致**（同一份 RTL，只换 BRAM 初始化）
>
> 也就是说：rev1019 当时那 **−0.153 ns** 的问题，在 rev1022 上**不再出现**。
> 成因推断：RAS/BTB 把关键路径**重排**了（两者的延迟正好落在 `fetch_addr` 那条链的不同位置），
> 加上 P&R 布局变化 —— 注意 **+0.034 ns 仍远低于本项目的综合噪声（≈5.7%）**，
> **换 seed 有可能翻负**（届时按 §9.7 的后备方案：BTB 缩 64 项 → 仍负则 `BTB_EN` 默认 0）。
> **⇒ rev1022 的 `f64b977` / `176e0028` 现在是新的交付口径；`bcd8fdd2` / `8894cdcb`（rev1017）降为历史对照。**
> 两颗 rev1019 的 85 MHz 位流已按 `_wns-0.153ns_` 命名归档，**只作"功能等价"的证据，勿烧**。
> 成因（供 CPU 线参考）：那两处 AND 加在 `mem_ready_int` 这条**本来就很晚**的信号上（它同时是
> ID/EX、EX/MEM、MEM/WB、乘法器的使能）⇒ 扇出/连线变差，把只剩 0.068 ns 的余量吃掉了。
> 想真把 85 MHz 收敛回来，要先解决这条使能路径（例如给它在源头加一级缓冲/寄存器），
> 那是一笔**独立的时序优化账**，不是顺手能做的。
> * **带 Cache 的档（`c10a2478`/`9feaa089`）已经重出且达标**（76.5052 MHz，CPU 域 **+0.534 ns / 0**）✓
>   —— 也就是说：**需要这两处修复的那个配置（有停顿），恰好就是已经修好并上板验证的那一颗。**

| 文件 | 内容 | md5 |
|---|---|---|
| **`rtthread_dual_noaext_ms_earlyld_a1_ras_btb_gomoku_g3_85mhz_rev1023_1e2075e6.sbit`** | **[OK] 演示档对齐 rev1023（A 扩展默认关）—— 2026-10-15 23:25 综合，md5 `1e2075e6`**：双发射 + `EARLY_LD` + A1 + RAS(16)/BTB(256)，RTL **与跑分版 `55fae69e` 逐位相同**，只换 BRAM 初始化。`DEBUG_LED=1` ⇒ led[0]=pll_locked(D19) / led[1]=video_locked(D18) / led[2]=done(**本变体不亮，别误判**)；`RATIO0=13.5`、`UART_DIV=738`、`DESIGN_REV=0x2026_1023`。固件 `mem.hex` **21046 行 / 10523 字**（守卫 ✓ 已过），串口 banner 应打 **`FW=RTTHREAD-GOMOKU-G3 RTL=0x20261023`**（`RTL=` 读的是 mimpid，是位流的权威自证）。**为什么要重出这颗**：上一颗 `176e0028` 是 **rev1022、A 扩展还在**的 RTL，直接验它等于**验一颗不交付的位流** —— 正是 rev1017->rev1019 那次踩过的坑。**时序/资源与跑分版逐位相同**：CPU 域 `u_pll→u_pll` **+0.330 ns / 0 失败端点**，请求 85.0051 → 可达 **87.4585 MHz**；LUT **7,663** / FF 3,675 / DRM 101.5。`Design Summary : Some Constraints Violated` = 21 条 `u_pll→video` + 1 条 `video→u_pll` 跨域建模假象，CPU 域 0 失败。**[ ] 板上待验**：四条判据（banner 的 `RTL=0x20261023` / `[boot] gomoku render thread running` / `ai thread running` / `[hb]` 每 5 s 一条不断）。 | `1e2075e6` |
| **`coremark_dual_noaext_ms_earlyld_a1_ras_btb_85mhz_rev1023_55fae69e.sbit`** | **[OK] 跑分版 —— A 扩展默认关（面积优化），2026-10-15 23:03 综合，md5 `55fae69e`**：双发射 + `EARLY_LD` + A1 + RAS(16)/BTB(256)，`DCACHE_EN=ICACHE_EN=0`、`RATIO0=13.5`、`UART_DIV=738`、`EE_TICKS_PER_SEC=85,005,100`、**ITER=4332**，`DESIGN_REV=0x2026_1023`（串口首行应打 `RTL=0x20261023`）。**这一版把 RV32A（AMO/LR/SC）改成 `parameter A_EXT`、默认 0** ⇒ `amo_unit` 不例化、AMO 的 opcode 判非法（mcause=2）。依据：赛题公式 `Score = Iterations/(Total_Time×Frequency)` 化简即 CoreMark/MHz ⇒ **主频与面积都不进主分**，而面积进指标(3) CoreMark/LUTs；两个交付固件都不含原子指令 ⇒ 零性能代价。**实测对比 `f64b977`（同 RTL + A 扩展）**：LUT **8,104 → 7,663（−441 / −5.44%）**、FF **3,899 → 3,675（−224）**、DRM 101.5 不变；CPU 域 `u_pll→u_pll` slack **+0.034 → +0.330 ns**、可达 **85.2515 → 87.4585 MHz**、0 失败端点（18,785）；⇒ 指标(3) **+5.8%**、指标(2) **+2.6%**、指标(1) 不变。**回归（全部逐位不变）**：CoreMark 五配置 229,597 / 249,982 / 287,056 / 300,392 / 233,013 与改动前**逐位相同**、四 CRC `e9f5/e714/1fd7/8e3a` 五种配置全一致；riscv-tests 49/1/0；own_tests 5/0；RT-Thread 仿真默认 + `-DCache -ICache` 均 PASS；`tb_amo_int` T0 PASS（A_EXT=1 时）。**A 扩展的验证口径仍保留**（`A_EXT=1` 可随时重开：`tb_amo_int` / `run_own_tests.ps1 -DAEXT` / `rtthread
un_sim.ps1 -Atomic`），只是不再占生产位流面积。网表自证同 `f64b977`（`dcache`/`icache`/`tag0` 全 0 ✓）。**[ ] 板上待验**（预期 370.2 分，`Total ticks ≈ 994,614,204`，拍/迭代 229,597 不变）。`Design Summary : Some Constraints Violated` = 21 条 `u_pll→video` + 1 条 `video→u_pll` 跨域建模假象，CPU 域 0 失败 —— 与 `f64b977` 同。 | `55fae69e` |
| **`rtthread_dual_aext_ms_earlyld_a1_ras_btb_gomoku_g3_85mhz_rev1022_176e0028.sbit`** | **[OK] 演示档重出 —— RT-Thread 五子棋，RTL 对齐到 rev1022（2026-10-15 19:49 综合，md5 `176e0028`）**：双发射 + `EARLY_LD` + A1 + **RAS(16)/BTB(256)**，`DESIGN_REV=0x2026_1022`，`DCACHE_EN=ICACHE_EN=0`、`RATIO0=13.5`、`UART_DIV=738`。`DEBUG_LED=1` ⇒ led[0]=pll_locked / led[1]=video_locked / led[2]=done（本变体不亮）。固件来自 `scripts/rtthread/`：`mem.hex` **21046 行 / 10523 字**（守卫 `@(21046, 21048)` ✓ 已过），静态 **52,761 / 61,440 B（85.9%）**、堆余 5,144 B，串口 banner `FW=RTTHREAD-GOMOKU-G3 RTL=0x20261022`。**目的**：上一颗 `8894cdcb` 是 **rev1017** 的 RTL，功能虽逐位等价（Cache 关 + 无 AMO ⇒ `mem_ready_int≡1` ⇒ 两处门控恒真），但交付口径不统一。**时序：CPU 域 `u_pll→u_pll` +0.034 ns / 0 失败端点（20,507）**，请求 85.0051 → 实测 85.2515 MHz —— **与跑分版 `f64b977` 逐位一致**（同一份 RTL，只换 BRAM 初始化）。**[ ] 板上待验**：四条判据（banner / `[broadcast] render thread` / AI 线程 / `[hb]` 无断）。<br>[!] **这颗直接推翻上一条注记的结论** —— 详见下方"rev1017 要不要重出"那段的 [2026-10-15 更新]。 | `176e0028` |
| **`coremark_dual_aext_ms_earlyld_a1_ras_btb_85mhz_rev1022_f64b977.sbit`** | **[OK] B1-RAS + B1-BTB 跑分版 @85.0051 MHz —— 已上板通过，当前最好成绩（2026-10-14 23:39，370.23 分）**（2026-10-14 23:04 综合，md5 `f64b977`；集成方合并队友 `riscv-cpu-fpga_dualissue_20261014_cpu (2).zip` 后重出，集成报告 `doc/reports/2026-10-14_integrate_b1_ras_btb.md`）：双发射 + `EARLY_LD` + **RAS（16 项返回地址栈）+ BTB（256 项直接映射，只预测间接 `jalr`，RAS>BTB>PC+imm）**，`DCACHE_EN=ICACHE_EN=0`，`DESIGN_REV=0x2026_1022`，`UART_DIV=738`、`EE_TICKS_PER_SEC=85,005,100`，**ITER=4332**。网表自证 `dcache`/`icache`/`tag0` **全 0** ✓、`btb_tag` 145 / `btb_target` 124 / `ras_mem` 16 在网表中 ✓。**时序：CPU 域 `u_pll→u_pll` +0.034 ns / 0 失败端点（20,507）**，请求 85.0051 → 实测 **85.2515 MHz**（`Some Constraints Violated` = 21 条 `u_pll→video` + 1 条 `video→u_pll` 跨域建模假象，CPU 域 0 失败）。资源 **LUT 8,104 / 5.07%**（rev1017 的 7,482 + 622 = RAS+BTB 代价）、FF 3,899、DRM 101.5。**[OK] 上板实测**（日志 `doc/board/uart_20261014_233933.txt`）：首行 `RTL=0x20261022`、`Total ticks 994,412,748` → **11.6980 s** → **370.23 分**（日志里 `Iterations/Sec 393` 是 `HAS_FLOAT=0` 整数截断，别用）、四 CRC `e9f5/e714/1fd7/8e3a` 与仿真**逐位一致**、`Correct operation validated`；拍/迭代 **229,574.8**（仿真 229,597，差 **−0.0097%**，±0.04% 抖动内）⇒ 较 `bcd8fdd2` 365.93 **+1.17%**（周期 −1.18%）。仿真依据：riscv-tests 49/1/0（默认 + `-DCache -ICache -EarlyLd`）、自写 5/5、RT-Thread `-DCache -ICache` PASS | `f64b977` |
| **`coremark_dual_aext_ms_earlyld_a1_85mhz_rev1019_wns-0.153ns_aad1e2ac.sbit`** | **[X] rev1019 的 CoreMark 生产档重出 —— 【时序不过，勿烧】**（2026-10-14 15:04 综合，md5 `aad1e2ac`；ITER=4280，脚本期望 `Total ticks ≈ 994,436,600` → 11.7 s）：`DCACHE_EN=ICACHE_EN=0`、85.0051 MHz（`RATIO0=13.5`/`UART_DIV=738`）。网表自证 `dcache` **0** / `icache` **0** / `tag0` **0** ✓（Cache 全关口径正确）。**CPU 域 `u_pll→u_pll` −0.153 ns / 16 失败端点（16,581）⇒ `Design Summary : Some Constraints Violated`**（对照 `bcd8fdd2` = +0.068 / 0）⇒ **不作交付件**，只为"rev1019 与 rev1017 功能等价"留证；分数**未上板验证**，别引用 | `aad1e2ac` |
| **`rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_85mhz_rev1019_wns-0.153ns_382ce876.sbit`** | **[X] 同上的 rtthread 五子棋版 —— 【时序不过，勿烧】**（2026-10-14 15:24 综合，md5 `382ce876`）：固件 `mem.hex` **20274 行 / 10137 字**（85.0051 MHz 口径；注意与 76.5 MHz 档的 10138 字不同 —— `build_bitstream.ps1` 的 `expectLines` 已改成接受这两个值）。**CPU 域 −0.153 ns / 16 失败端点**，与上面那颗**逐位相同**（两次独立运行 ⇒ 确定性结果，不是 8-seed 抖动）。**交付继续用 `8894cdcb`** | `382ce876` |
| **`gomoku_dual_aext_ms_earlyld_a1_85mhz_rev1019_wns-0.153ns_e03c0e6e.sbit`** | **[X] 裸机五子棋版 @85.0051 —— 【时序不过，勿烧】**（2026-10-14 17:52 综合，md5 `e03c0e6e`）：**T2/T3 固件整合后的第一颗裸机 gomoku 位流**（菜单系统 + HUD 重排；`scripts/gomoku/` 六个文件来自队友 `feat/gomoku-t2` 交接包）。固件 `mem.hex` **12552 行 / 6276 字**（T2/T3 前 11268 行 / 5634 字，`expectLines` 已同步更新）。网表自证 `dcache` **0** / `icache` **0** / `tag0` **0** ✓（Cache 全关）。**CPU 域 −0.153 ns / 16 失败端点**，与前两颗 rev1019 85MHz 件**逐位相同**（第三次独立运行 ⇒ 确定性坐实）⇒ **不作交付/上板件**；它补上的是"新网表上还没综过裸机 gomoku"这个记录缺口（`doc/board/README.md` 待办），功能上板请用下方 76.5052 MHz 档 | `e03c0e6e` |
| **`gomoku_dual_aext_ms_earlyld_a1_76mhz_rev1019_dd4fecb4.sbit`** | **[OK] 裸机五子棋（T2/T3 菜单 + HUD）@76.5052 MHz —— 已上板验证（2026-10-14 18:49/18:53 两局），当前演示/测试推荐烧这颗**（2026-10-14 18:17 综合，md5 `dd4fecb4`）：`RATIO0=15.0` / `UART_DIV=664`（约定 50 四件套构建后**已全部还原**）。固件 `mem.hex` 12552 行 / 6276 字。**`Design Summary : All Constraints Met`** —— CPU 域 `u_pll→u_pll` **+0.773 ns / 0 失败端点（2,625）**（76.5052 MHz 请求 → 81.3140 MHz 实测；对照同 RTL 85MHz 档 −0.153 ns），视频两域 +6.856 / +33.023。网表自证 `dcache` **0** / `icache` **0** / `tag0` **0** ✓。首行 `RTL=0x20261019`。**板上实测**（日志 `doc/board/uart_20261014_184921.txt` 人机局 / `_185341.txt` AI 对弈局，`replay_log.py` 复盘 29 快照全合法）：菜单三确认开局、串口逐项反馈、AI 挡四后竖五连（G5-G9）胜人机局、判胜与相位正确、无 vblank 超时。旁路：`addr_map.h` 的 `CPU_HZ` 仍写死 85,005,100 ⇒ 长按阈值约 0.67 s、AI `t=…ms` 约低 10%（阈值/显示偏差，不影响功能；任务书 §4.1）| `dd4fecb4` |
| **`rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_85mhz_rev1017_8894cdcb.sbit`** | **[[OK]+[!]] 已上板（2026-10-13 22:46，未接显示屏）—— RT-Thread 版五子棋（任务 T1/G3：render 高优 + AI 低优两条线程）**：双发射 + `EARLY_LD` + A1 @ **85.0051 MHz**，`DEBUG_LED=1` ⇒ **led[0]=pll_locked / led[1]=video_locked（HDMI 黑屏先看这颗）/ led[2]=done 本变体不会亮，别误判**。固件来自 `scripts/rtthread/`（**非 coremark**，别被 `generate_bitstream\cpu_top_board.sbit` 这个固定名骗了）：静态 **51,193 / 61,440 B（83.3%）**、堆余 9,368 B，串口 banner `[build] FW=RTTHREAD-GOMOKU-G3 RTL=0x20261017`。**RTL 与跑分版 `bcd8fdd2` 逐位相同**（只换 BRAM 初始化）⇒ CPU 域 **WNS +0.068 ns / 失败端点 0 / 17,216**，与已板级验证过的 `bcd8fdd2` **完全一致**；`clk→video −1.137`(21)、`video→clk −0.081`(1) 仍是跨域建模假象。**已验**：x86 单测 138 项 / 独立复核 28 项 / RV32 交叉编译无警告 / `tb_rtthread` 仿真 `=== PASS ===`；**板上（2026-10-13 22:46，日志 `doc/board/uart_20261013_224652.txt`）**：两条线程都起来、`[hb]` 全程无断、**两线程邮箱往返真通**（`AI moved, nodes=10592 depth=6 t=5068ms` —— RT-Thread 固件链的是异步 pump，子落得下来即该链走通），对局/按键/轮次均正确。**[!] 遗留**：串口有 `[!] vblank timeout`（23 份裸机日志都没有）—— 新加的 `video_vblank_yield()` 用 1 ms 采样去看 RTL 里 **63 µs** 的 vsync 脉冲，粒度差 16 倍；显示侧未测，判据与机制见 `doc/board/README.md` 该节 | `8894cdcb` |
| **`rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_idcache_76mhz_rev1017_c10a2478.sbit`** | **[X] I+D Cache 全开 @76.5052 MHz + RT-Thread 五子棋 —— 已构建/已归档，但【上板确定性挂死，勿烧】**（2026-10-14 00:08 综合，md5 `c10a2478`）：`DCACHE_EN=1`/`ICACHE_EN=1`，`RATIO0=15.0`、`UART_DIV=664`、`board.h` 的 `BOARD_SYSTEM_CLOCK_HZ=76,505,200`（rtthread 固件按约定 50 四件套联动，**构建后已全部还原**）。网表自证（约定 46）：`dcache` 1188 / `icache` 1208 / `tag0` 205 ✓。**时序是历次 I+D 里最好的一次**：CPU 域 `u_pll→u_pll` **+0.904 ns / 0 失败端点（16,560）**，且 76.5 MHz 下两条 CDC 也收敛（+6.347 / +8.558，0 失败）⇒ **全设计 0 失败端点**（对比 `da8ffd31`：CPU 域 +0.015、8-seed 散布 −0.596…+0.015）。**[X] 上板失败（00:08:50 / 00:10:05 / 00:28:30 三次抓取逐字节相同）**：只有一行 `?? turn=WHITE`——原始字节 `3F 3F 07 20`，`serial_monitor` 按 ASCII 解码把**固件实发的 2 个 ≥0x80 字节**显示成了 `??`（约定 56）；程序在 **AI 第一手之后的第一张棋盘快照**处打出损坏数据即挂死（18~29 s 内无 `[hb]` 心跳）。**同一固件在无 Cache 位流 `8894cdcb` 上完全正常**（23:43 日志）⇒ 疑 I+D + `EARLY_LD` + 中断/上下文切换路径上的 RTL bug（约定 47 同族；该组合此前**没有任何仿真覆盖**——`rtthread/run_sim.ps1` 编 `tb_rtthread` 不带任何 `-D` 旗标，见约定 55）。**[OK] 下一步已做完（2026-10-14）：`tb_rtthread` 的 Cache 开关已补（约定 55），仿真复现成功 —— `-DCache`/`-ICache`/`-DCache -ICache` 三种都能打挂这条固件，而无 Cache 是 PASS ⇒ 确认是【功能 bug，与时序无关】，且【两个 Cache 都能打挂它】。归因全文见 `doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`。**[!] 2026-10-14 晚更新：两条根因（约定 56 的 ID/EX 清零门控、约定 57 的 CSR 写门控）都已修，
同配置仿真 `-DCache -ICache` 已 **PASS**；但本 `.sbit` 是 **rev 1017 的旧 RTL** ⇒
**rev ≥ `0x2026_1019` 的位流已重出并上板（见下方 `90944754` / `53b81dfe` 两行），本行只作归因留档。**另注：rtthread 固件不打 `[cache]` 计数 ⇒ 本变体的 Cache 自证只能靠网表/md5。**再另注：rtthread + D-Cache only @85MHz 位流【已经存在了】—— 10-14 00:57 那颗（`generate_bitstream/cpu_top_board.sbit`，合并日志 `DCACHE_EN=1/ICACHE_EN=0`），但它 **CPU 域 −0.177 ns / 13 失败端点**（时序不过）且**功能上也打挂 RT-Thread**，同样是勿烧。10-13 23:40 那次是**更早的一次中断构建**（`.sbit` 从未落盘）| `c10a2478` |
| **`rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_idcache_76mhz_rev1019_53b81dfe.sbit`** | **[OK] 同上一颗的【横幅自洽版】—— 推荐烧这颗**（2026-10-14 14:34 综合，md5 `53b81dfe`）：**RTL 与 `90944754` 逐位相同**（网表自证 `dcache` 1190 / `icache` 1216 / `tag0` 196 ✓，时序同为 CPU 域 **+0.534 ns / 0 失败端点（18,997）**、CDC 0 失败、`All Constraints Met`），**唯一区别是固件**：横幅主频改为从 `BOARD_SYSTEM_CLOCK_HZ` 算 ⇒ 这次会打 **`@76.5052MHz`**（`90944754` 打的是写死的 `@85.0051MHz`）。固件 `mem.hex` 20276 行 / 10138 字（约定 50 四件套构建后已还原）。首行 `RTL=0x20261019` | `53b81dfe` |
| **`rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_idcache_76mhz_rev1019_90944754.sbit`** | **[OK] I+D Cache 全开 @76.5052 MHz + RT-Thread 五子棋 —— 两条根因（约定 56/57）修复后重出的【可上板待验】版**（2026-10-14 13:48 综合，md5 `90944754`）：`DCACHE_EN=1`/`ICACHE_EN=1`，`RATIO0=15.0`、`UART_DIV=664`、rtthread `board.h` 的 `BOARD_SYSTEM_CLOCK_HZ=76,505,200`（约定 50 的四件套，**构建后已全部还原**）；固件来自 `scripts/rtthread/`（**非 coremark**，`mem.hex` 20726 行 / 10135 字）⇒ **串口首行自证 `RTL=0x20261019`**。网表自证（约定 46）：`dcache` **1190** / `icache` **1216** / `tag0` **196** ✓（对照 rev1017 那颗 1188/1208/205）。**时序全过**：`Design Summary : All Constraints Met`，CPU 域 `u_pll→u_pll` **+0.534 ns / 0 失败端点（18,997）**、hold +0.147；两条 CDC 也 0 失败（`u_pll→video` +6.663 / `video→u_pll` +8.072）⇒ **全设计 setup/hold 均 0 失败端点**。仿真依据（rtthread 四配置全 PASS + 四条基线逐位不变）见 `doc/reports/2026-10-14_cache_fix_bug2.md`。**[OK] 2026-10-14 13:59 已上板（串口侧通过，`doc/board/uart_20261014_135935.txt`）**：`RTL=0x20261019`（两侧自证）+ render/AI 两条线程都起来 + `[hb] alive, uptime 5000…20000 ticks` 每 5 s 一条、单调递增、**全程无断** ⇒ **之前"带 Cache 必挂"的组合现在通了**（对照：`c10a2478` 死在 AI 第一手后的棋盘快照、`9feaa089` 卡在 `heap = 9368 bytes` 循环重启）。**追加验证（2026-10-14 14:11，`doc/board/uart_20261014_141147.txt`，413 行）**：真按键下棋 —— 光标/落子/难度切换（EASY·NORMAL·HARD）/SW3 复位全有响应；**完整下完一局并判出 `WHITE wins`**；AI 线程真在算（NORMAL `nodes=1287…435 depth=4 t=398~672ms`、**HARD `nodes=10592 depth=6 t=5737ms`**）；`[hb]` 5000→25000 无断（AI 思考 5.7 s 期间画面/按键仍响应 = G3 正题）；**用户接 HDMI 显示器下棋正常** ⇒ **T1/G3 的"显示侧未验"就此关闭**。**已知坑**：横幅第 10 行打 `@85.0051MHz` —— 那是 `app/main.c` 里写死的字面量（跑的是 76.5052），**判位流只看 `RTL=` 行**；源码已改，下次重出才会对。`[!] vblank timeout` 是已知噪声（`8894cdcb` 也有） | `90944754` |
| **`rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_dcache_85mhz_rev1017_9feaa089.sbit`** | **[X] D-Cache only @85.0051 MHz + RT-Thread 五子棋 —— 【上板失败，勿烧】的归档件**（2026-10-14 00:57 综合，md5 `9feaa089`；= 上一行提到的 `generate_bitstream` 那颗的**归档副本**，归档时已按约定 46 验网表）：`DCACHE_EN=1` / `ICACHE_EN=0`，`UART_DIV=738`、`board.h=85,005,100`；网表自证 `dcache` 1174 / **`icache` 0** / `tag0` 97 ✓。**板上**（`doc/board/uart_20261014_010219.txt`）：RT-Thread banner **打 3 次**、每次停在 `[boot] heap = 9368 bytes`（render 线程都没起来）= **重启循环**；**仿真同配置崩得更晚**（banner + render/AI 两线程都出后才异常转储）。**根因 = ID/EX 清零漏 `mem_ready_int` 门控（约定 56，已修）+ CSR 写漏 `mem_ready_int` 门控（约定 57，2026-10-14 晚也已修）**。两条修复后，同配置仿真（`scripts\rtthread\run_sim.ps1 -DCache`）已 **PASS**；但本 `.sbit` 是 **rev 1017 的旧 RTL**，且时序本来就不收敛 ⇒ **仍勿烧**，要重出 rev ≥ `0x2026_1019` 的位流。另：CPU 域 **−0.177 ns / 13 失败端点**，功能修好也塞不进 85 MHz。**⇒ 交付继续用 Cache 全关**（`8894cdcb` / `bcd8fdd2`） | `9feaa089` |
| **`coremark_dual_aext_ms_earlyld_a1_dcache_85mhz_rev1017_56374a08.sbit`** | **[OK] D-Cache only @85.0051 MHz（A1 之后）—— 高阶任务①的一半，且【几乎不要钱】**：`DCACHE_EN=1`/`ICACHE_EN=0`，`UART_DIV=738`、`EE_TICKS_PER_SEC=85,005,100`，ITER=**4280**。**[OK] 2026-10-13 19:52 已上板通过**（日志 `doc/board/uart_20261013_195230.txt` 第二段）：`RTL=0x20261017`、`Total ticks 994,255,126` → **11.6964 s** → **365.92 分**、`Correct operation validated`、四个 CRC 与仿真逐位相同、**`[cache] D` hits 36,749,229 / miss 26,063（99.929%）、`[cache] I` 全 0**；拍/迭代 **232,302.6**（比无 Cache 的 232,296.6 **只多 6.0 拍 = +0.003%** ⇒ **得分只掉 0.01**）。**结论（[!] 2026-10-14 限定）：D-Cache 对【CoreMark】不损失分数**——**但这条【不能推广到五子棋/RT-Thread】**：同一条 RT-Thread 五子棋固件在 `-DCache` 下会挂（仿真与板上双证，见 `doc/reports/2026-10-14_cache_rtthread_sim_bisect.md`）。**别再写"D-Cache 可以常规开着"** —— 目前只有 CoreMark 证明过；生产档继续 Cache 全关 | `56374a08` |
| **`coremark_dual_aext_ms_earlyld_a1_idcache_76mhz_rev1017_da8ffd31.sbit`** | **[OK] I+D Cache 全开 @76.5052 MHz（A1 之后）—— 高阶任务①完整档**（`RATIO0=15.0`，`UART_DIV=664`、`EE_TICKS_PER_SEC=76,505,200`，ITER=**3800**）。网表自证：`dcache` 658 / `icache` 668 / `tag0` 205 ✓。**CPU 域 setup 余量仅 +0.015 ns**（8 seed 散布 −0.596…+0.015，PDS 取最优 seed）—— **但板上实测是稳的**。**[OK] 2026-10-13 19:52 已上板通过**（日志同上第一段）：`RTL=0x20261017`、`Total ticks 891,885,963` → **11.6578 s** → **325.96 分**、四个 CRC 与仿真逐位相同、**`[cache] D` hits 32,690,873 / miss 23,224（99.929%）、`[cache] I` hits 874,301,508 / miss 9,331,007（98.944%）**；拍/迭代 **234,706.8**（比无 Cache 多 2,410 拍 = **+1.038%**）。**比 85 MHz 无 Cache 低 10.9%（−10.0% 主频 + −1.0% 周期）** | `da8ffd31` |
| **`coremark_dual_aext_ms_earlyld_a1_85mhz_rev1017_bcd8fdd2.sbit`** | **[OK] A1（乘法器 II=1 流水线）跑分版 —— 当前最好成绩**：双发射 + `EARLY_LD` @ 85.0051 MHz，`DESIGN_REV` = `0x2026_1017`，`UART_DIV`=738、`EE_TICKS_PER_SEC`=85,005,100。ITER=**4280**（`4280 × 232,345`）。**[OK] 2026-10-13 18:41 已上板通过**（日志 `doc/board/uart_20261013_184111.txt`）：首行 **`RTL=0x20261017`**、`Total ticks 994,229,330` → **11.6961 s** → **365.93 分**（日志里的 `389` 是整数截断，别用）、**四个 CRC（`seedcrc`/`crclist`/`crcmatrix`/`crcstate`）与仿真逐位相同**、`Correct operation validated`；拍/迭代 **232,296.6**（仿真 232,345，差 **−0.021%**，在 ±0.04% 模型抖动内）。较 A1 前的 351.86 **+4.00%**。缺陷/未做：**CPU 域时序余量仅 +0.068 ns**、LUT 6,909 → 7,482（乘法器流水化 +228）| `bcd8fdd2` |
| **`coremark_dual_aext_ms_earlyld_idcache_76mhz_rev1016_c6b12d95.sbit`** | **[OK] I+D 全开（完整 2 路组相联 I/D Cache）+ 降频 76.5052 MHz**（`RATIO0=15.0`），含 `wb_rdata_snap` 根因修复（`2026-10-12_icache_wb_snap_fix.md`）+ `DESIGN_REV` 递增到 `0x2026_1016`（约定 42）。CPU 域 **setup +0.589 ns / hold +0.147 ns / 0 失败端点**（19,021 端点）；网表自证 **`dcache` 655 / `icache` 670** ✓。ITER=3668（`3668 × 244,034`）、`UART_DIV=664`、`EE_TICKS_PER_SEC=76,505,200`。**[OK] 2026-10-12 15:59 已上板通过**（日志 `doc/board/uart_20261012_155934.txt`）：首行 **`RTL=0x20261016`**、`Total ticks 894,745,801` → **11.6952 s** → **313.63 分**（日志里的 `333` 是整数截断，别用）、**四个 CRC 逐位相同**、`Correct operation validated`、**`[cache] I` hits 878,103,971 / miss 9,006,928（98.985%）+ `[cache] D` 31,555,354 / 22,423（99.929%）**；拍/迭代 **243,932.9**（仿真 244,034，差 −0.041%）。全流程见 `doc/reports/2026-10-12_idcache_board_bitstream.md` | `c6b12d95` |
| `coremark_dual_aext_ms_earlyld_idcache_76mhz_rev1016_d073366b.sbit` | 上面那条的**同设计孪生**（在 `idcache` 仓库副本综合）：**网表逐字节相同**（md5 `A4814916…`）、时序数字逐位相同。`.sbit` 里内嵌工程路径不同 ⇒ md5 不同。**归档只为留一手，烧哪个都一样** | `d073366b` |
| `gomoku_pll62mhz_2cee98c9.sbit` | 五子棋版（62 MHz 时代）—— 提频出问题时的回退版 | `2cee98c9` |
| `coremark_pll85mhz_ae4deea9.sbit` | **单发射** CoreMark @ 85 MHz —— **已板上实测 233.85 分**（ITER=2740）| `ae4deea9` |
| `gomoku_pll85mhz_f4e78dc6.sbit` | **单发射** 五子棋 @ 85 MHz —— 已上板跑通（含串口棋盘快照等）| `f4e78dc6` |
| `gomoku_dual_85mhz_3976aebd.sbit` | **双发射** 五子棋 @ 85 MHz（无 HUD 的上一版）—— 已板上跑通 | `3976aebd` |
| `gomoku_dual_hud_85mhz_e5bc227a.sbit` | 双发射 + HUD @ 85 MHz（**60.71Hz 刷新**，画面会抖/撕裂）| `e5bc227a` |
| **`gomoku_dual_hud_60hz_50c4e364.sbit`** | 双发射 + HUD @ **标准 60Hz**（刷新率修正，屏幕正常）—— 有一处 HUD 残字 bug | `50c4e364` |
| `gomoku_dual_hud_60hz_rv32a_8c229a21.sbit` | 双发射 + HUD + **A 扩展** @85MHz —— **时序 −0.096 ns，不可用**（留作"单 seed 不收敛"的证据）| `8c229a21` |
| `gomoku_dual_aext_ms_85mhz_3418c5fc.sbit` | 双发射 + HUD + **A 扩展** + **多 seed 布局** —— slack +0.064 ns | `3418c5fc` |
| `gomoku_dual_aext_ms_85mhz_addrfix_f00c6659.sbit` | 上面那版 + **`imem_addr2` 截位修复**（约定 40）—— slack +0.236 ns。**已上板**（2026-10-10，两局五子棋正常，屏幕正常）| `f00c6659` |
| **`coremark_dual_aext_ms_earlyld_dcache_76mhz_a69a19b5.sbit`** | **[二分用] 只开 D-Cache + 降频 76.5052 MHz**（ITER=3700，4 处常量=76,505,200）。setup **+0.717 ns**、hold **+0.145 ns**、**0 失败端点**；网表 `dcache` 659 / **`icache` 0** ✓。预期 `Total ticks ≈ 894,000,000` → 11.69 s → ≈316 分。**[OK] 2026-10-12 01:23 上板通过（日志 `doc/board/uart_20261012_012310.txt`）**：`Total ticks 893,885,762` → 11.6842 s、**351 行报告完整**、四个 CRC 逐位相同、`[cache] D hits=31,739,605 / miss=22,616`（99.929%）、`[cache] I` 全 0 ⇒ **得分 316.7**。
⇒ **76.5 MHz 口径完全没问题，问题 100% 在 I-Cache**（用途达成）（见 `2026-10-12_handoff_completeness_first.md` §2.3）| `a69a19b5` |
| ⚠️ **`coremark_dual_aext_ms_earlyld_idcache_76mhz_fa957dbd.sbit`** | **【已作废 —— 根因已修，用上表的 `c6b12d95`】** [完整条目] I+D 全开 + 降频 76.5052 MHz（`RATIO0=15.0`，ITER=3372，4 处固件常量=76,505,200）。CPU 域 slack **+0.410 ns / 0 失败端点**（周期 13.071 ns）；**网表两个 cache 都在**（`dcache` 660 / `icache` 670 处）。⚠️ **[X] 2026-10-12 上板失败，别烧**（日志 `doc/board/uart_20261012_010314.txt` / `_010344.txt`）：
串口只有 banner **重复约 590 次/秒**（13 秒 7,627 次），**没有任何 CoreMark 输出**，
⇒ CPU 跑飞后陷入非法指令 → `mtvec`(复位值 0 = `_start`) → 反复从头跑。
**仿真（ITER=1）是过的**（四个 CRC 正确、265,408 拍/迭代）⇒ 属于"仿真过、板上不过"。
**定位思路见 `doc/reports/2026-10-12_handoff_completeness_first.md` §2.3。**| `fa957dbd` |
| **`coremark_dual_aext_ms_stage01_earlyld_dcache_2f7a4d0a.sbit`** | **带 D-Cache 的一版（2026-10-12）**：`2ddaf32f` + **`DCACHE_EN=1`（只开 D-Cache）**。CPU 域 slack **+0.151 ns / 失败端点 0**，DRM **105.5/415**；网表已验（`dcache` 653 处、`tag0` 100 处、`icache` 0 处）。ITER=4116，**[OK] 已上板（2026-10-12，日志 `doc/board/uart_20261012_002541.txt`）**：`Total ticks 994,386,960` → **11.69797 s** → **351.86 分**；`[cache] D hits=35,341,114 / miss=25,081`（**命中率 99.929%**）；**四个 CRC 与关 Cache 时逐位相同**；拍/迭代 241,590.6（关 Cache 版 +6.0 拍）| `2f7a4d0a` |
| **`coremark_dual_aext_ms_stage01_earlyld_2ddaf32f.sbit`** | **跑分版（2026-10-11 晚）**：在 `03d8a7eb` 之上加**任务 C 的 `EARLY_LD`（load 地址提前到 ID + 专用读口）** —— 每迭代 **241,633** 拍（原 262,018，**−7.79%**），ITER=**4116**，CPU 域 slack **+0.045 ns**、失败端点 **0**（16,484 端点）。预期板上 11.70 s / **≈352 分**。**[OK] 已上板（2026-10-11，日志 `doc/board/uart_20261011_225624.txt`）**：`Total ticks 994,362,145` → **11.6976 s** → **351.8 分**（日志里的 `Iterations/Sec 374` 是整数截断，别用）；拍/迭代 **241,584**（仿真 241,633，−0.02%），首行 `RTL=0x20261015`。四条基线全过（riscv-tests 49/1/0、自写 2/0、AMO T0 PASS、RT-Thread SoC PASS、CoreMark 四 CRC 逐位一致）| `2ddaf32f` |
| `coremark_dual_aext_ms_stage01_a0cache_03d8a7eb.sbit` | **上一版（2026-10-11）**：`4f1b0977` + **A.0（`mem_ready`/访存停顿收尾）+ I/D Cache 骨架（默认关，等于没有）+ 外设 one-shot 门控**。slack **+0.578 ns**（89.40 MHz），失败端点 0，ITER=3796。**串口日志与 `4f1b0977` 逐位应一致**（Cache 关时功能逐位不变）| `03d8a7eb` |
| `coremark_dual_aext_ms_stage01_4f1b0977.sbit` | （2026-10-10，已被上一条 `2ddaf32f` 取代）：`imem_addr2` 修复 + 版本自证 + **阶段0（-O3 编译选项）+ 阶段1（到达级分支重定向）** —— CoreMark **ITER=3796** @85MHz，slack **+0.544 ns**（89.13 MHz），失败端点 0。**[OK] 已上板（2026-10-10，日志 `doc/board/uart_20261010_224932.txt`）**：`Total ticks 994,437,480` → 11.6976 s → **324.5 分**（261,969.8 拍/迭代）| `4f1b0977` |
| `coremark_dual_aext_ms_85mhz_mimpid_492714a8.sbit` | `imem_addr2` 修复 + **版本自证**（`mimpid` 打出 `RTL=`，约定 42）—— CoreMark ITER=3170 @85MHz，slack +0.525 ns，失败端点 0。**已板上实测 270.82** | `492714a8` |
| `gomoku_dual_hud_60hz_074a0e11.sbit` | 裸机五子棋：60Hz + HUD 残字修复。已板上可玩。<br>[!] **别把这条当"最新"** —— 更新的几代在表格上方（如 `f00c6659`，2026-10-10）。本行原写着"当前最新"，已过时更正 | `074a0e11` |
| **`coremark_dual_85mhz_5c4893de.sbit`** | **双发射** CoreMark @ 85 MHz —— **已板上实测 270.82 分**（ITER=3170，`Total ticks 994,988,178` / 11.7050 s）| `5c4893de` |

> [!] **ITER=1 的仿真会【高估】Cache 的周期代价 —— 判 Cache 收益只认板上数**（2026-10-13 实测）：
> 仿真（ITER=1）说 D-Cache +365 拍、I+D +3,283 拍；**板上（ITER=4280/3800）只有 +6.0 拍 / +2,410 拍**。
> 差一个数量级。**根因：ITER=1 时 Cache 是冷的**，那一次迭代的缺失被完整计进周期；
> 而板上跑几千次迭代，缺失被摊薄。⇒ **带 Cache 的配置，仿真必须跑多迭代才可比**，否则只能信板。

> [!] 旧的 `gomoku_dual_hud_85mhz_e5bc227a.sbit`（60.71Hz）保留作对照 ——
> **它能复现"画面抖动/撕裂"那个症状**，是刷新率那条结论的证据。

> [!] **别用本文件判断"当前源码对应哪一版位流"** —— 位流是历史快照，而 RTL 一直在动。
> 判据只有两条：① 串口首行 `RTL=0x…` 是否等于 `rtl/core/csr_file.v` 的 `DESIGN_REV`（约定 42）；
> ② 重新跑 `scripts\build_bitstream.ps1 coremark`，看它打印的**配置与 md5**（约定 23）。
> （本文件旧文写"2026-10-11 起当前源码 = `03d8a7eb`"，那只对那一刻成立。）
>
> 当前**仿真口径**（A1 后；板上最后一代仍是 A1 前）：**85.0051 MHz 双发射 + 任务C `EARLY_LD` + A1**，
> 每迭代 **232,345** 拍 → **4.304 CoreMark/MHz**，ITER=4280，**[OK] 板上实测 365.93 分**（`bcd8fdd2`，2026-10-13，日志 `doc/board/uart_20261013_184111.txt`）。
> **A1 前跑分口径**（2026-10-11/12 板上实测）：ITER=4116，每迭代 **241,633** 拍 → **351.86 分**（`2f7a4d0a` / `2ddaf32f`，两者分数相同）；
> **I+D Cache 版**为 **76.5052 MHz / ITER=3668 → 313.63 分**（`c6b12d95`，`RTL=0x20261016`，**A1 前口径**）。
> `4f1b0977` 保留作它的对照。
>
> [!] **`4f1b0977` 是 2026-10-10 阶段0+1 那一代的位流，早已被取代**（当时它才是"当前源码"）——
> 串口第一行是 `[build] FW=COREMARK RTL=0x2026_1011`（`DESIGN_REV` 当时递增到 `1011`，
> **自证是阶段1 之后的网表**；`492714a8` / `7b6e5e05` 读出来的都是 `0x2026_1010`）。
> **`7b6e5e05` 是复核阶段的中间产物（ITER=3518，板上只有 10.84 s），别烧它。**

> [!] **`492714a8` 是阶段0/1 之前的 CoreMark 位流**（2026-10-10，已板上实测 **270.82**）——
> `imem_addr2` 宽度修复 **+** 版本自证（`mimpid`）。烧上去串口第一行是：
> ```
> [build] FW=COREMARK RTL=0x20261010
> ```
> **看到 `RTL=` 就是"有版本自证的那一代"**；更早的位流没有这一行（那时 `mimpid`
> 恒 0，固件也还没读它）。判分看 `Total ticks`（ITER=3170 约 994,9xx,xxx，
> ÷85,005,100 ≈ 11.7 s）+ 四个 CRC。
>
> **`RTL=` 的值可以一眼分辨网表代次**（`DESIGN_REV` 定义在 `rtl/core/csr_file.v`，约定 42）：
> `0x2026_1017` = **A1 乘法器 II=1 那代（当前 RTL；`bcd8fdd2`，板上 365.93 分）**；`0x2026_1016` = I+D Cache 那代（`c6b12d95`）；`0x2026_1015` = 任务C `EARLY_LD` 那代（`2ddaf32f` / `2f7a4d0a`）；
> `0x2026_1011` = 含阶段1；`0x2026_1010` = 阶段1 之前；无此行 = 更早。
>
> [!] 因为加了这一行，CoreMark 镜像从 4208 字涨到 **4228 字**
> （`build_bitstream.ps1` 的 `expectLines` 表已实测更新）。

> [!] **`f00c6659` 与 `3418c5fc` 的差别只在 RTL 的一个宽度**（2026-10-10）：
> `imem_addr2` 从 13 位改回 14 位（64KB 扩容时漏改的那处）。
> 现代码都 < 32KB，所以**两者功能上应当逐位相同** —— 但它**换了网表**，
> 时序是重新跑多 seed 布局得到的（+0.064 → **+0.236 ns**，CPU 域失败端点仍是 0）。
> **没上板验过，别当"已验"。** 想最保险就继续用 `3418c5fc`（已板上跑通的那版）——
> 前提是程序代码不越过 32KB。

> [!] **"单发射 / 双发射"现在是位流名字的一部分**（2026-10-06 起）。两者文件名与字节数
> 完全一样，**不标配置就分不出来** —— 而烧错的表现是"分数差 15.8%"这种不显眼的差别，
> 比烧错固件更难发现。**归档时一律带上 `_dual_` / `_single_`。**
>
> 两块 `coremark_*` 都**已板上实测**（2026-10-06 补齐）：
> - `ae4deea9`（单发射）**233.85 分**，slack +0.823 ns
> - `5c4893de`（双发射）**270.82 分**，slack +0.270 ns —— **薄余量扛住了**
>
> 双发射这一版**只是多出 15.8% 的分**，功能上四个 CRC 与单发射逐位一致。
> **若它在别的场景出问题，一键回退 `ae4deea9`**（不用重新综合）。
>
> **[OK] 双发射的应用侧也已验证**（2026-10-06，日志 `doc/board/uart_20261006_172315.txt`）：
> 五子棋启动、按键、难度切换、落子、AI 应手、棋盘状态全部正常。
> **AI 一手从平均 553 ms 降到 486 ms（−18%）** —— 与 CoreMark 的 +15.8% 吻合，
> 说明双发射的收益不只是跑分数字，应用侧也真的更跟手。
> **唯一还没验的是 HDMI 画面**（缺显示器）。

> [!] **两块 85 MHz 位流的区别只在固件**（同一个网表、同一份 RTL）：
> `coremark_*` 是跑分固件，`gomoku_*` 是五子棋固件。**烧错的现象是完全相反的两件事** ——
> 烧成 coremark 版：串口打 CoreMark 报告、按键无反应；烧成 gomoku 版：串口打棋盘、不跑分。
> **`generate_bitstream\cpu_top_board.sbit` 永远只代表"最后一次综合的那版"**，别靠它猜。

**怎么生成 / 怎么确认是哪一版**（2026-10-01 首次成功综合）：

```powershell
scripts\build_bitstream.ps1 video     # 一条命令：固件 -> 同步 -> 综合，并打印 md5
```

> [!] **`generate_bitstream\cpu_top_board.sbit` 这个固定名字看不出里面是哪一版** ——
> 它只代表"最后一次综合的那版"，而且**任何一次综合都会覆盖它**（包括临时探针）。
> 别靠文件名猜，看 md5。要留档就复制到这里并改名。

> [!] **2026-10-01 实踩（第二次）：烧成了上一次分配的位流。**
> 当时想测视频彩条，烧完抓串口却打出 **CoreMark**（`Total ticks 727,018,199` /
> `Iterations 2000`）—— 说明烧的是 **`D:\riscv-cpu-fpga`（CPU 单仓）那份 CoreMark 位流**
> （md5 `3f76e554`），不是本工程的视频位流（md5 `75871d8a`）。
> **两个位流的文件名完全相同、字节数也完全相同（9,188,552）**，只看文件名/大小
> 永远分不出来。
> **根因**：Fabric Configuration 会把上次分配的文件记在器件节点上，而且是在
> **分配时**读进内存的 —— 只点 `Program` 就会重烧上次那份。
> **纪律**：`Scan Device → `**`Assign New Configuration File`**` → Program` 三步走全，
> 中间那次 Browse 不能省；烧完**先对 md5**再下结论。

## 这一版（2026-10-01）的实测状态

**首次综合通过。** 三个时钟域 slack 全正：

| 时钟域 | Requested | Estimated | Slack |
|---|---|---|---|
| `clk_sys`（CPU / 显存 A 口） | 62.0309 MHz | 66.87 MHz | **+1.167 ns** |
| `pix_clk`（PPU / 显存 B 口） | 25.5004 MHz | 176.6 MHz | **+33.554 ns** |
| `ser_clk`（TMDS 并串） | 127.5022 MHz | — | **+6.856 ns** |

资源：LUT 4,003（2.51%）/ FF 2,849（0.89%）/ **DRM 53.5（12.89%）** / APM 4。
（DRM 从 16 涨到 53.5 是视频显存 73 KB —— 与 CPU 的 32 KB 统一存储器**是分开的两块**。）

**`Design Summary` 显示 `Some Constraints Violated`，但那 22 条全是跨域建模假象：**

| 起点 → 终点 | WNS | 失败端点 |
|---|---|---|
| `clk_sys → clk_sys` | +1.167 | **0** |
| `pix_clk → pix_clk` | +33.554 | **0** |
| `ser_clk → ser_clk` | +6.856 | **0** |
| `clk_sys → pix_clk` | −4.207 | 21 |
| `pix_clk → clk_sys` | −4.049 | 1 |

21 + 1 = 22，与 `RV32I_1.fdc` 里预测的"恒报 21 条 clk_sys→pix_clk + 1 条 pix_clk→clk_sys"
**一字不差**。原因：`.fdc` 执行时机早于 PLL 时钟创建，`set_clock_groups` / `set_false_path`
试过 4 种写法全失败，所以这两个域**无法被判为异步**，STA 就按一个 pix_clk 周期
(39.215 ns) 去算那 12+9 位同步器。**读报告必须按 path group 分开看。**

> [!] 残留风险（已知、已接受）：PDS 不知道那两条路径是同步器，布局时不会特意把
> 两级 flop 放近。最坏表现是**偶发一帧滚动位置错一下**（scroll/vblank 都是准静态量），
> 不会死机。**五子棋不用滚动，影响面更小。**

## 上板判据（HDMI 特有）

1. **`led[0] = pll_locked`、`led[1] = video_locked`** —— **led[1] 不亮先查视频 PLL，别去看 HDMI**
2. 串口应打印 banner + 各读回值 + **`SELFCHECK OK`**（共 187 字节，一次性）
   —— `SELFCHECK FAIL` 说明问题在 CPU 侧写/读显存，与 TMDS 无关
3. 显示器应出 **8 条等宽竖条**，从左到右：白 黄 青 绿 品红 蓝 黑
4. 黑屏/无信号/雪花 的排查顺序见 `rtl/video/video_top.v` 文件头那 5 条
