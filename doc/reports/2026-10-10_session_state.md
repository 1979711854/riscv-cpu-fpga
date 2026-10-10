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
| **1** | **烧 `gomoku` 双发射 + A 扩展 + HUD 位流**，验板 | 看屏幕（现在有显示器了）+ 串口 |
| **2** | **CoreMark 双发射 + A 扩展上板**，看 270.82 有没有变 | A 扩展加 291 LUT，理论上周期数不变 |
| **3** | **给 AMO 补回归覆盖** | 见下，**这是最该补的** |
| 4 | 五子棋菜单系统 / HUD 行距 / G1+G2 | 见 `2026-10-07_taskbook_v4.md` |

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

## 8. 顺手发现的一个**潜伏 bug**（未修，等决策）

`imem_addr2`（双发射的第二取指口）**还是 32KB 时代的 13 位**，而存储器在
2026-10-10 已经扩到 64KB（`imem_addr` 是 14 位）：

```
core.v:19      output wire [12:0] imem_addr2,     <- 应为 [13:0]
core.v:559     assign imem_addr2 = imem_addr + 13'd1;   <- 14 位结果被截成 13 位
cpu_top.v:57   wire [12:0] imem_addr2;
mem_bus.v:39   input  wire [12:0] imem_addr2,
```

`imem_addr + 1` 在 14 位宽里算出、赋给 13 位线 → **丢掉最高位**，于是
`imem_addr2` 在 8192 word（字节 `0x8000`）处**回绕**。

**后果**：取指地址 ≥ 0x8000 时，lane B 从低 32KB 里取错地方
（`pair_now` 判据用的就是 `imem_rd2`）。

**现在没炸是因为没有任何程序碰得到**（都已核对，全部 < 32KB）：

| 程序 | 代码末地址 |
|---|---|
| `coremark.elf` | 0x380C = 14,348 B |
| `gomoku.elf`（裸机）| 0x2D08 = 11,528 B |
| RT-Thread 版五子棋 | 0x638C = 25,484 B |

**但 64KB 扩容的全部意义就是让程序能大过 32KB** —— 一旦 `.text` 越过 32,768 字节，
这个 bug 立刻变成"执行错指令"。**这正是"四条基线里没有一条覆盖得到"的典型**。

修法是三处宽度 + 那个 `13'd1` 一起改成 14 位；但**这动的是 RTL 网表**，
而当前双发射 + A 扩展的 slack 只有 **+0.064 ns（0.5% 余量）**，
改完要重跑回归**并重新综合确认时序**。所以先记下来，别顺手改。
