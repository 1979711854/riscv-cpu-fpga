# 三人分工任务书 —— 128KB 单一位流收口（2026-10-17 起）

> 依据：`doc/reports/2026-10-17_qa_compliance.md` §8。
> 决策已定：**同一颗位流 + 运行时选择**；跑分时不启动应用；**不做总线突发**。
> 角色沿用 2026-10-12 分工：甲 = RT-Thread + 五子棋；乙 = CPU 优化；集成方 = 上板 + 修改核对 + 论文。
> 截止按仓库记录 **2026-11-04**，剩约 18 天。本文是执行底稿，做完一项勾一项。

> **[!] 2026-10-17 17:10 更新 —— §2.5（B5）的目标作废**
> 128KB 在 **85.0051 MHz 收不住**：8 个 seed（8~15）全部为负，最好 **seed 10 = −0.796 ns / Fmax 79.62**，
> 极差 0.513 ns（要补的量是 seed 空间的 1.5 倍）。
> 已按 `STATIC_RATIO0` 13.5 → **15.0** 降到 **76.5052 MHz** 收敛：
> CPU 域 **+0.304 ns / 0 失败端点 / Fmax 78.3269 MHz / `Design Summary: All Constraints Met`**，
> 位流 **`6074c89c`（未上板）**。
> ⇒ §2.5 的判据「85.0051 MHz 下 WNS>0、Fmax ≥85.01」**改为「76.5052 MHz 下 WNS>0、0 失败端点」**。
> 细节与后续排期见 `2026-10-17_handoff_mem128k_cpu.md`。

---

## 0. 关键路径与并行关系

```
乙：RTL 14→15 位 + 存储器 + CoreMark 重定位 + boot selector + 回归 + PDS 收敛
        │
        ├── 第 1 天下午交付【新内存地图 + 可跳转的 selector 骨架】
        │        │
        │        └── 甲：RT-Thread 重定位到 0x10000 + 界面美术 + 端到端仿真
        │
        └── 第 2~3 天：全套回归 + 重扫 seed + 候选位流
                 │
                 └── 集成方：合并镜像 + 最终综合 + 上板 + ILA + 视频 + 论文
```

**唯一串行点**：`无位流 = 不能抓 ILA`。128KB 必须在 ILA 之前落定。
**其余全部可并行**：乙改 RTL、甲改应用/界面、集成方冻结基线/写合并脚本/准备论文。

---

## 1. 统一约定（三个人都按这张表）

### 1.1 新内存地图（128KB，15 位字地址）

| 区间（字节） | 用途 | 说明 |
|---|---|---|
| `0x00000~0x00FFF` | **boot selector** | 复位入口 `0x0`；4KB 足够 |
| `0x01000~0x0EFFF` | **CoreMark** | 镜像 34,208 B；栈顶 `0x0F000`（不变） |
| `0x0F000~0x0FFFF` | 兼容区 + 间隙 | 兼容区仍在 `0xFFF0~0xFFFF`（CoreMark 移植层 literal 不动） |
| `0x10000~0x1FFEF` | **RT-Thread + 五子棋** | 镜像 ≈44,056 B + `.bss` 10,696 B；栈顶 `0x1FFF0` |
| `0x1FFF0~0x1FFFF` | 保留 | 不许当 RAM 用；见 §1.2 的别名陷阱 |

> 两个程序的栈各自独立：CoreMark `0x0F000`，RT-Thread `0x1FFF0`。
> RT-Thread 堆 = `_end ~ 0x1FFF0`，预计约 10 KB（甲必须实测并打印 `[boot] heap =`）。

### 1.2 [重点] 兼容区别名陷阱（最容易静默错的一处）

现在的兼容区判决是 `addr[15:8]==8'hFF && addr[7:4]==4'hF`。
**`0x1FFF0` 的 `addr[15:8]` 也是 `0xFF`** —— 扩到 128KB 后，如果不同时加限定，
`0x1FFF0` 会被误判成兼容区 MMIO，而它正好是 RT-Thread 的栈顶附近。
**修法：兼容区判决加 `!addr[16]`**（只匹配低 64KB 的 `0xFFF0~0xFFFF`）。
谁改 `mem_bus.v` 都要把这一条写进注释和测试。

### 1.3 分支与目录

| 角色 | 分支 | 目录 |
|---|---|---|
| 乙 | `feat/mem128k` | 主仓 `D:\riscv-cpu-fpga_merged`；seed 扫描用**独立副本**，避免与集成方抢 PDS 工程 |
| 甲 | `feat/app-ui` | 主仓；只动 `scripts/gomoku/**`、`scripts/rtthread/**` |
| 集成方 | `dualissue`（集成分支） | 主仓；合并顺序 乙 → 甲，冲突由集成方裁决 |

> [!] **同一个 PDS 工程目录不能并发综合**。乙的 seed 扫描在副本里跑；
> 集成方的最终综合在主仓跑。两边都要在日志里写清用的是哪份 `.pds`/哪个 seed。

### 1.4 冻结基线（集成方已做）

| 档位 | 位流 | 分数 | 说明 |
|---|---|---|---|
| 跑分 | `c6af65be` | 391.66 / 4.6064 | rev1027、ITER=4332、LUT 7,767、WNS +0.277 |
| 演示 | `5909a2d0` | — | T6 五子棋 |

**回退点**：128KB 若在上板前收敛不了，退回这两颗；报告如实说明。

---

## 2. 乙（CPU 优化）—— 关键路径，今天开工

### 2.1 任务 B1：RTL 地址宽度 14→15 位

**必改文件（一个都不能漏）**：

| 文件 | 改什么 |
|---|---|
| `rtl/core/core.v` | `imem_addr` / `imem_addr2` / `ld_addr` 端口宽度；`14'd1`→`15'd1`；所有字索引切片 |
| `rtl/top/cpu_top.v` | 例化端口宽度、切片 |
| `rtl/bus/mem_bus.v` | `ram_word` 切片、`ram_hit` 范围 → `0x00000~0x1FFEF`、**兼容区加 `!addr[16]`**、未映射读返回 0（不许 X） |
| `rtl/mem/unified_mem.v` | RAM 深度 16,384 → 32,768 word |
| `sim/mem_model.vh` | `[0:16383]` → `[0:32767]` |
| `sim/tb_riscv.v` / `tb_coremark.v` / `tb_amo_int.v` / `sim/tools/tb_debug_trap.v` | 同上的字索引宽度与常量 |
| `rtl/bus/addr_map.vh` | `RAM_LAST_BYTE`、注释、扩容清单 |

**判据**：iverilog 先编译过；`scripts\run_sim.ps1 -NoWave` 全过。

### 2.2 任务 B2：CoreMark 重定位 + boot selector

- `scripts/coremark_port/link.ld`：`. = 0x1000`；`_stack_top=0xF000`、`_tohost=0xFFF8` **不动**。
- 新增 `scripts/boot/boot.S`（或 `boot.c`）：
  - 链接在 `0x0`，≤4KB；
  - 读 GPIO `0x8000_0000` 的 key 位（低有效）。**复位时按住 KEY_UP（key[2]）→ `0x1000`（CoreMark）；否则 → `0x10000`（RT-Thread）**；
  - 两条路径都直接 `j` 目标入口，目标自己的 `start.S` 会设 SP；
  - 不初始化任何外设，不依赖 `.data`。
- 和集成方对齐：selector 的 ELF 也要参与合并，基址 `0x0`。

**判据**：
- 两个程序分别用 `+IMEM/+DMEM` 仿真能跑；
- 合并镜像后，仿真里能按 key 状态跳到两个入口（可先做 `tb` 小验证）。

### 2.3 任务 B3：新回归 `hi_fetch.S`（覆盖扩容量本身）

- 新增 `sim/tests/hi_fetch.S`：代码/数据跨 `0x10000` 取指与访存，walk 到 PASS。
- **必须做"弄坏能 FAIL"验证**：把 `imem_addr2` 的位宽故意改回 14 位，测试必须 FAIL。
- 这条测试是本次扩容的**唯一直接覆盖**，不做等于裸奔。

### 2.4 任务 B4：全套回归（改完 RTL 立刻跑）

| 探针 | 期望 |
|---|---|
| `scripts\run_riscv_tests.ps1` | 49 PASS / 1 FAIL / 0 TIMEOUT |
| `scripts\run_own_tests.ps1` | 6 PASS / 0 FAIL |
| `scripts\run_sim.ps1 -NoWave` | 全过（含 `tb_multiplier` 840 项） |
| CoreMark（仿真） | 四 CRC `e9f5/e714/1fd7/8e3a` 逐位一致；**217,088 拍/迭代不变** |
| `hi_fetch` | PASS；改回 14 位必须 FAIL |

### 2.5 任务 B5：PDS 综合 + 重扫 `gplace_seed`

- 在**独立副本**里跑 multiseed，按 **CPU 域**（不是全设计最差）选 seed。
- 目标：85.0051 MHz 下 CPU 域 **WNS > 0、Fmax ≥ 85.01**、0 失败端点。
- 交付给集成方：选中的 seed、`report_timing/cpu_top_board.rtr`、候选位流路径 + md5。
- [!] 跨域 `CPU→pix_clk` 的 −1.07 ns 是既有伪影，**不要**拿它当回归。

**Definition of Done（乙）**：B1~B5 全绿 + 候选位流与 seed 交给集成方。

---

## 3. 甲（RT-Thread + 五子棋）—— 今天先做不依赖的界面，地图一到就重定位

### 3.1 任务 A0（今天就能做，不依赖乙）

- 完成 `2026-10-17_session_state.md` §5 的界面美术：
  8×8 字库、棋盘 2×2 图块、HUD 框；只动 `scripts/gomoku/**`。
- 每改一次必跑：
  - `scripts\gomoku\run_test.ps1`（x86 228 项）
  - `scripts\gomoku\run_sim.ps1`（端到端：真 CPU + 真 PPU）
- **不碰 `rtl/`、`pds/`、`scripts/build_bitstream.ps1`。**

### 3.2 任务 A1（等乙的地图，约第 1 天下午）

- `scripts/rtthread/bsp/link.ld`：
  - `. = 0x10000`；
  - `__stack_top = 0x1FFF0`、`__rt_rvstack = 0x1FFF0`；
  - `__heap_end = 0x1FFF0`；
  - 注释里的旧地址全部改掉。
- 检查 `scripts/rtthread/bsp/board.h` 与 `scripts/rtthread/**` 里所有硬编码地址
  （搜索 `0x[0-9A-Fa-f]{4,}`），只改与 RAM 布局相关的。
- 重新编译：`scripts\rtthread\build.ps1 -Firmware`。
- **实测并记录**：`[boot] heap = N`；N 若 < 8 KB，先报给集成方，不要自己动栈。

### 3.3 任务 A2：验收

| 项 | 判据 |
|---|---|
| x86 单测 | 228/228 |
| `scripts\gomoku\run_sim.ps1` | 端到端 PASS |
| `scripts\rtthread\run_sim.ps1` | RT-Thread 启动、两线程、`[hb]` 无断 |
| 固件大小 | 报给集成方更新 `expectLines` |
| 板上 | 合并位流里选五子棋，HDMI 下完一局 |

**Definition of Done（甲）**：界面美术完成 + RT-Thread 在 `0x10000` 编译通过 + 单测/仿真全绿 + 板上下一局。

---

## 4. 集成方（上板 + 修改核对 + 论文）

### 4.1 任务 I0（今天，0.5 天）

- 归档冻结档：`c6af65be` / `5909a2d0` 的 `.sbit`、md5、时序报告、板级日志。
- 在 `2026-10-17_qa_compliance.md` §8 里补上 §1.1 的内存地图，作为三人共同口径。
- 建集成分支，约定合并顺序（乙 → 甲）。

### 4.2 任务 I1：合并镜像工具（与乙并行）

- 新增 `scripts/merge_images.py`：输入多个 ELF（selector/CoreMark/RT-Thread），
  按各自基址合并成一个 `mem.hex`；**检测区间重叠、检测越界、检测兼容区别名**。
- 在 `scripts/build_bitstream.ps1` 加 `combined` 变体：
  - `DEBUG_LED=1`；
  - `expectLines` 用合并后的实测值；
  - 打印三个 ELF 的基址/大小与最终 md5。
- 判据：故意把两个 ELF 的基址改重叠，脚本必须报错退出。

### 4.3 任务 I2：最终综合 + 上板（等乙的候选）

- 主仓跑最终综合，**引用归档位流那一次的时序报告**（不要用副本里的 seed 报告）。
- 上板验证两条路径：
  1. 默认启动 → RT-Thread 五子棋：HDMI 出棋盘、4 键操作、串口 `[hb]`、下完一局；
  2. 复位时按住 KEY_UP → CoreMark：串口 `Total ticks`、四 CRC、**391.66**、≥10 s。
- 记录：位流 md5、`RTL=` 版本、串口日志到 `doc/board/`。
- 判据：**同一颗 `.sbit` 两条路径都过**。

### 4.4 任务 I3：ILA（位流定稿后立刻做）

- 用与 `.sbit` 同一次综合的 `.fic`；91 根探针。
- 抓：BHT 三种行为、`ex_flush`、停机自旋；存 VCD + `.dprj`。
- 判据：91/91 存活；波形能逐拍解释。

### 4.5 任务 I4：演示视频 + 报告

- 视频：同一颗位流，先跑 CoreMark（串口出 391.66）→ 复位 → 五子棋下完一局；HDMI + 板卡同框。
- 报告：
  - 结构改为「场景指标 → 同等场景下资源/时序 → CoreMark」；
  - 时序页单列 CPU 域 WNS/Fmax/失败端点 + 跨域 CDC 伪影说明；
  - 资源表给全设计与 CPU 域两个口径；
  - 高阶任务如实写：Cache 已实现并量化（负收益、默认关）；总线突发经评估不做；AI 不做（可选）。
- 判据：报告、PPT、视频、代码四件套齐。

**Definition of Done（集成方）**：单一位流上板双路径通过 + ILA 归档 + 视频 + 报告/PPT + 交接包更新。

---

## 5. 时间表（按 2026-11-04 截止倒排）

| 日期 | 乙 | 甲 | 集成方 |
|---|---|---|---|
| 10-18 | B1 RTL 改完 + 单测 | A0 界面美术 | I0 冻结 + I1 合并脚本 |
| 10-19 | B2/B3 + 交付地图 | A1 重定位 | I1 完成 + 核对地图 |
| 10-20 | B4 全套回归 | A2 验收 | 等候选；准备论文骨架 |
| 10-21 | B5 seed 扫描 | 板上联调 | I2 最终综合/上板 |
| 10-22 | 修时序（如需） | 修应用问题 | I2 收口 |
| 10-23 | 支援 | — | I3 ILA |
| 10-24~26 | — | — | I4 视频 + 报告 |
| 10-27~11-03 | 缓冲：只修缺陷 | 缓冲 | 缓冲 + 打包 |

> **硬闸门**：10-23 前单一位流必须上板通过；否则启动回退（两颗位流），
> 把剩余时间全部给视频和报告。

---

## 6. 三条纪律（写在这里，省得再踩）

1. **128KB 定稿前不抓 ILA、不拍最终视频** —— `.fic`/`.sbit` 必须同源，返工成本最高。
2. **任何 RTL 改动都要跑四个探针**：riscv-tests 49/1/0、own_tests 6/0、CoreMark 217,088+四 CRC、`run_sim.ps1` 全过。
3. **甲不碰 `rtl/`，乙不碰 `scripts/gomoku/**`，集成方不改 RTL/应用代码只做核对**；
   交界改动（link.ld、build 脚本）由集成方裁决。

---

## 7. 扩容会不会降低跑分（团队常问）

**结论：CoreMark 周期数不会变；唯一风险是 Fmax。**

### 7.1 为什么周期数不变

- 存储器仍是**同步 1 拍读**，深度 16,384 → 32,768 word **不增加访问延迟**；
  取指/装载还是 1 拍，`Total ticks` 不受容量影响。
- CoreMark 从 `0x0` 搬到 `0x1000`、RT-Thread 搬到 `0x10000`：
  **BHT 索引是 `PC[9:2]`、tag 是 `PC[31:8]`**，整体平移只改高位，
  分支之间的相对索引和冲突关系不变 ⇒ 预测行为逐位不变。
- boot selector 只在复位时跑一次，不进 CoreMark 计时区间。

**预期：217,088 拍/迭代、四 CRC 逐位不变。**

### 7.2 风险只在 Fmax

分数 = `CoreMark/MHz × 实际频率`。85.0051 MHz 保持则 391.66 保持；
若 Fmax 掉到 80 MHz，分数约 368.5（−5.9%）。

风险来源：

| 来源 | 影响 |
|---|---|
| `imem_addr2` 加法 14→15 位 | 在关键路径上，多一级进位/几十 ps |
| 存储器阵列变大 | 布局布线变化，可能影响拥塞 |
| 当前 CPU 域余量只有 +0.277 ns | P&R 随机性 ±0.1~0.2 ns，必须重扫 seed |

### 7.3 历史数据

上次 32KB→64KB（2026-10-10，commit `de64f8d` + `imem_addr2` 位宽修复 `f72ef25`）：

| | 改前 | 改后 |
|---|---|---|
| CPU 域 Slack | +0.064 ~ +0.086 ns | **+0.236 ns** |
| CPU 域 Estimated | 85.63 MHz | **86.75 MHz** |
| CoreMark 周期 | — | **不变** |

⇒ **扩存储本身不增加延迟**，上一次实测没有变差（还略好）。
但这次是 14→15 位、且当前余量更薄，**不能直接外推**，必须实测。

### 7.4 应对顺序

1. 先按 P3.5 的手法保持窄加法：`imem_addr2` 只做 `fetch_addr[16:2] + 1`，不引入长链；
2. 重扫 `gplace_seed`（按 CPU 域选种）；
3. 若 Fmax 仍不达标，先修关键路径（拆进位/预计算），**不要直接降频**；
4. 实在修不动才降频，并在报告里如实写"为容量付出的频率代价"。
