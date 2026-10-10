# 会话状态备忘（2026-10-10）

> 换会话时读这一份就能接上。**只记"现在在哪、下一步做什么"** ——
> 任务细节看 `2026-10-07_taskbook_v4.md`，踩坑看工程根 `CLAUDE.md`。
> **本文会过时**，以 git log 和位流 md5 为准。

---

## 0. 三十秒版

**CPU 加了 A 扩展（RV32A）后时序不收敛（slack −0.096 ns）。**
试过"降频"——**失败，而且更差**（PDS 的优化力度跟着约束走）。
最后用**多 seed 布局**解决：同一份网表试 8 种布局，挑最好的那个，
**slack 转正 +0.064 ns**。

---

## 1. 仓库现状

| | |
|---|---|
| **仓库** | `D:\riscv-cpu-fpga_merged`（Windows）/ `/d/riscv-cpu-fpga_merged`（bash） |
| **远端** | `https://github.com/1979711854/riscv-cpu-fpga.git` |
| **分支** | **`dualissue`**（当前主线）。另有 `merged-85mhz`（上一代）、`main`（旧的 CPU 单独仓，历史无关） |
| **推送到哪** | `git push origin dualissue` —— **代理 `127.0.0.1:31181` 没启动时必失败**，绕过用 `git -c http.proxy= -c https.proxy= push` |

**未推送的**：无（截至本文）。

---

## 2. 已经钉死的结论（**别再重新论证**）

| 结论 | 依据 |
|---|---|
| **双发射 CPU 板上实测 270.82 分**（单发射 233.85，+15.8%）| 位流 `coremark_dual_85mhz_5c4893de.sbit`，板级日志 |
| **效率三指标 1 升 2 降**（效率 +15.8% / Fmax −4.8% / CoreMark-LUTs −27%）| 报告里必须整张给，只报涨分是选择性呈现 |
| **HDMI 显示首次真正跑通**（27 寸显示器正常出图）| 修了刷新率 60.71 → 59.96 Hz 之后 |
| **HUD 完成**（紧凑 5×7 字库 665 字节，放大 2× 写显存）| 屏幕上有 `TURN:` / `LEVEL:` / `AI: NODES…` |
| **PDS 的优化力度跟着约束走** —— 调高约束它更卖力（62→66.87、71.7→73.26），**调低它也偷懒（83.45 请求只给 79.08）** | 两次实测 |
| **RT-Thread + 五子棋装不进 32KB**（22,507 + ~15,000 > 32,768）| 所以 G3（AI 跑在 RTOS 线程）不做 |
| **别按 SW2/D22** —— 那是 FPGA 配置键，按了设计被卸载要重烧。真复位是 SW3 | 判据：按完两个 PLL 灯还亮不亮 |

---

## 3. 当前卡点与刚做的处置

### 卡点：A 扩展让时序不收敛

```
单 seed：请求 85.0051 → 实际 84.3170，slack −0.096 ns（2 个失败端点）
关键路径在 u_multiplier 第二级（N21.fsub_* 进位链 → hi_ss → _N17231），
其中一段走线 1.553 ns —— 是【布局】问题不是逻辑深度问题
```

### 处置：多 seed 布局（已生效）

`pds/RV32I_1/RV32I_1.pds` 的 `cmd_pnr` 里写入了：

```
(_option gplace_times (_integer 8))
(_option seed_step   (_integer 1))
(_option saved_outcome (_integer 1))
(_option parallel    (_integer 4))
```

结果：

```
8 seed：请求 85.0051 → 实际 85.4701，slack +0.064 ns，CPU 域失败端点 0  ✓
```

**备份**：`pds/RV32I_1/RV32I_1.pds.bak_before_multiseed`（加选项之前的）。
**失败证据留档**：`report_timing/aext_85mhz_FAIL_-0.096ns.rtr`。

> [!] **+0.064 ns 只有 0.5% 余量，偏薄。** 若要更宽，把 `gplace_times` 提到 16/32
> 再跑一轮，或者修那条乘法器路径。**先把当前这版收下来，再说优化。**

---

## 4. 下一步（按顺序）

| # | 做什么 | 备注 |
|---|---|---|
| **1** | ~~烧 `gomoku` 双发射 + A 扩展 + HUD 位流，验板~~ | **[OK] 已做（2026-10-10 14:35 / 14:40）**：`3418c5fc` 与 `f00c6659` 各跑一局，**两版都正常**，14:40 那局还下到了 `WHITE wins`。日志 `doc/board/uart_20261010_1435*.txt` / `_1440*.txt`，判读见 `doc/board/README.md` 末尾。<br>[!] **但这次 A/B 证明的是"重综合没改坏"，不是"截位修复生效"** —— 五子棋代码 11.5 KB，碰不到 ≥0x8000 那条路径，两版行为本就该一样。<br>**[OK] 屏幕也确认了**（2026-10-10 用户接显示器实看，两版画面都正常）|
| **2** | **CoreMark 双发射 + A 扩展上板**，看 270.82 有没有变 | **位流已备好，等上板**：`coremark_dual_aext_ms_85mhz_mimpid_492714a8.sbit`（ITER=3170，slack **+0.525 ns**）。烧上去串口第一行应是 `[build] FW=COREMARK RTL=0x20261010`。**270.82 是修复前的 `d9ee1cfe` 测的**，这版要重测确认没变（理论逐位相同）|
| **3** | **给 AMO 补回归覆盖** | 见下，**这是最该补的**。**已成文交接给队友**：`doc/reports/2026-10-10_handoff_coverage.md` §1 |
| **4** | **给「代码 > 32KB」补一条测试** | 见 §8 末尾 —— 64KB 上半区取指仍然零覆盖。**这也是唯一能真正把截位修复变成"板上可验"的办法**。任务书同上一份 §2（含"怎么让测试真的能检出"的完整设计）|
| 5 | 五子棋菜单系统 / HUD 行距 / G1+G2 | 见 `2026-10-07_taskbook_v4.md` |
| 6 | ~~让固件在串口第一行打版本号~~ | **[OK] 已做（2026-10-10）**：RTL 侧加 `DESIGN_REV` 常量走只读 CSR `mimpid`（`rtl/core/csr_file.v`），三份固件（gomoku / CoreMark / RT-Thread）都把它打在串口第一行。见 `CLAUDE.md` **约定 42**（**改 RTL 后综合前必须改它**）|

### [!] 最该补的：AMO 没有回归覆盖

- **没有 rv32ua 的 riscv-tests**（50 个 ELF = rv32ui 42 + rv32um 8）
- `scripts/run_own_tests.ps1` 的 `$skipThese` **跳过了全部三个 AMO 测试**
  （`amo_int` / `dep_probe` / `tb_amo_cpu` —— 它们没转成 tohost 判定）
- **后果：四条基线里没有一条执行 AMO。将来谁改坏了 AMO，全绿也发现不了。**
- 目前唯一的真集成证据：**RT-Thread 的 `--Atomic` 构建**（4 OK / 0 FAIL）

---

## 5. 关键文件与命令

```powershell
# 上板唯一入口（生成固件 → 同步 → 综合）
scripts\build_bitstream.ps1 gomoku        # 或 coremark / demo / rtthread / video

# 回归（改 RTL 后两条都跑）
scripts\run_riscv_tests.ps1               # 双发射（默认，= 板上口径）
scripts\run_riscv_tests.ps1 -Single       # 单发射
scripts\gomoku\run_test.ps1               # 五子棋 270 项 + RV32 交叉编译检查

# 给队友打包（输出到 桌面\RV32I\，带 .git）
scripts\pack_for_teammate.ps1

# 串口
scripts\serial_monitor.ps1 -Port COM4 -Seconds 60      # 先起监控，再按 SW3
```

**两条回归基线（改 RTL 必须都跑）**：

| 配置 | riscv-tests | CoreMark 每迭代 |
|---|---|---|
| 双发射（默认）| 49 PASS / 1 FAIL / 0 TIMEOUT | **313,886** |
| 单发射（`-Single`）| 49 PASS / 1 FAIL / 0 TIMEOUT | **363,515** |

---

## 6. 位流归档一览（`pds/RV32I_1/bitstreams/`）

| md5 | 内容 |
|---|---|
| `ae4deea9` | 单发射 CoreMark @85MHz —— **板上实测 233.85** |
| `5c4893de` | 双发射 CoreMark @85MHz —— **板上实测 270.82** |
| `f4e78dc6` | 单发射 五子棋 @85MHz（无 HUD）|
| `50c4e364` | 双发射 + HUD @**标准 60Hz**（有残字 bug）|
| `074a0e11` | 双发射 + HUD @60Hz + **残字修复**（可玩）|
| `8c229a21` | 双发射 + HUD + **A 扩展** @85MHz —— **时序 −0.096，不可用** |
| `3418c5fc` | 双发射 + HUD + A 扩展 + **多 seed** —— slack +0.064 |
| `d9ee1cfe` | 双发射 + **A 扩展** CoreMark @85MHz —— **板上实测 270.82** |
| `1c5f0354` | 双发射 + A 扩展 + **64KB 存储器** 五子棋 |
| `f00c6659` | 同 `3418c5fc` + **`imem_addr2` 宽度修复** —— slack +0.236 ns。**已上板** |
| **`492714a8`** | **最新**：上面那版 + **版本自证**（`mimpid`）—— 双发射 **CoreMark**，slack **+0.525 ns**。**未上板** |

> [!] **单发射/双发射/是否 60Hz 的全都要看名字** —— 位流文件名和字节数完全一样
> （9,188,552），**不标配置分不出来**。

---

## 7. 任务 H 的卡点：**已解决（2026-10-10，commit `925070d`）**

上个会话卡在"主线程心跳没出现"，定位成 `HB_DELAY_MS` 没传下去。**那个定位是错的。**

**复验**：`-Sim` 里确实已经传了 `-DHB_DELAY_MS=20`（build.ps1 第 163 行，
banner 里 `tick period = 1000 Hz` 也印证时钟口径对），但心跳**依然**不出现。
于是加逐拍诊断（直接读固件里的 `rt_tick` / `rt_interrupt_nest`）：

```
t≈2ms   tick=2    pc=0x000050b8
t≈15ms  tick=14   pc=0x000050ac
t≈17ms  tick=16   pc=0xxxxxxxxx   <- PC 变 X，CPU 已经没了
t≈25ms  tick=16   （再也不动）
```

**真因**：`cpu_top.v` 里那段注释的前提失效了 ——

> 仿真里这几个测试台不接 `vid_*`，**而它们也从不访问 0x8001_0000 以上**
> ⇒ `rsel_d` 永远不为 3 ⇒ `vid_rdata` 的浮空值不会进 `mem_rdata`

任务 H 之后五子棋要 `video_set_scroll` / `video_wait_vblank` / `draw_frame`，
第一次读 `0x8003_0408`（VIDEO_STATUS）就让 `mem_rdata = vid_rdata`（悬空 → Z）
进了寄存器堆 → Z 参与运算变 X → **整颗 CPU 在 ~16 ms 死掉**。
（正是 CLAUDE.md 关键约定 4 / 13。）

**症状极具迷惑性**：串口把 banner 打完就静默、心跳永远不出现，看着像
"调度器没跑"或"延时没到"，其实是 CPU 已经没了。**tick 一直在走**这一点
可以把"中断/调度"整类怀疑一次排除。

**修法**：照 `sim\tb_gomoku.v` 的接法，把 `cpu_top` 的 `vid_*` 接到真正的
`video_core`；`scripts\rtthread\run_sim.ps1` 补上 `rtl/video` 那六个文件
（**不含 `video_top.v`** —— 它例化 PDS 专有原语 `pll_video` / OSERDES）。

**结果**：`scripts\rtthread\run_sim.ps1` → `=== PASS ===`，三条自检全 `[OK]`，
串口里游戏也真的往前走了（`level=0 EASY (greedy)`、`[hb] alive, uptime 20 ticks`）。
G3（AI 拆线程）**还没做**，那是下一帧。

---

## 8. `imem_addr2` 截位潜伏 bug —— **已修（commit `f72ef25`）**

`imem_addr2`（双发射的第二取指口）**还是 32KB 时代的 13 位**，而存储器在
2026-10-10 已经扩到 64KB（`imem_addr` 是 14 位）：

```
core.v:19      output wire [12:0] imem_addr2,     <- 应为 [13:0]
core.v:570     assign imem_addr2 = imem_addr + 13'd1;
cpu_top.v:57   wire [12:0] imem_addr2;
mem_bus.v:39   input  wire [12:0] imem_addr2,
```

`imem_addr + 1` 在 14 位宽里算出、赋给 13 位线 → **丢掉最高位**，于是
`imem_addr2` 在 8192 word（字节 `0x8000`）处**回绕** →
取指地址 ≥ 0x8000 时 lane B 从低 32KB 取错地方（`pair_now` 判据用的就是 `imem_rd2`）。

**iverilog 其实每次都报了这条**（`mem_bus.v:182: ... expects 14 bit(s), given 13`），
只是没人看。所以这次**顺手把这类警告升成了硬错误**：`run_riscv_tests.ps1` /
`run_coremark.ps1` / `run_own_tests.ps1` / `rtthread\run_sim.ps1` 现在检测到
`expects N bit(s), given M` 就抛异常（`CLAUDE.md` 约定 40）。

**回归（改前后逐位相同）**：双发射 49/1/0 + **313,886**；单发射 49/1/0 + **363,515**；
自写测试 2/0；四个 CRC 一致。测试台里同类的 `imem_addr` / `imem_addr2`（5 个 tb）
也一并补齐，**宽度警告从 2 条降到 0 条**。

**重新综合**（多 seed ×8，gomoku 变体）：

| | 改前 `3418c5fc` | 改后 `f00c6659` |
|---|---|---|
| CPU 域 Slack | +0.064 ~ +0.086 ns | **+0.236 ns** |
| CPU 域 Estimated | 85.63 MHz | **86.75 MHz** |
| CPU 域失败端点 | 0 | 0 |
| CPU→video 跨域 | −1.084 / 21 端点 | −1.036 / 21（**原样存在，与本改动无关**）|

新位流已归档为 `bitstreams/gomoku_dual_aext_ms_85mhz_addrfix_f00c6659.sbit`。
**[OK] 已上板验证（2026-10-10 14:40，五子棋一局下到 `WHITE wins`，日志
`doc/board/uart_20261010_144054.txt`）** —— 但那只证明"重综合没改坏"，
**不能证明截位修复本身**（见 §4 第 1 项）。注意 `bitstreams/` 里那些标着
"已实测"的**旧**位流现在都**不再对应源码**。

> [!] **仍然没有覆盖**（留给下次）：没有任何基线程序把代码放到 `0x8000` 以上，
> 所以"64KB 上半区取指"这条通路**仍然零覆盖**。这次的 bug 是**读代码读出来的**，
> 不是测出来的。想补的话要新写一个把 `.text` 放到 0x8000 以上的测试
> （`sim/tests/` 下加一个 .S + 它自己的 .ld，并让 `run_own_tests.ps1` 支持
> 按测试名选链接脚本）。
