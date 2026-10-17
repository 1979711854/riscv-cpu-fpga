# 交接 · 2026-10-17 19:30 → 下一个会话

> **一句话**：交付位流 `b45941d6` 已出、已归档、**已在板上双路径验证**；剩下 ILA / 演示视频 / 报告，
> 以及一个可选的 Cache 评估档（备份用，不交付）。
>
> 本文件面向**没有任何上下文**的接手者。过程与踩坑细节见
> `doc/reports/2026-10-17_handoff_mem128k_cpu.md`，**答辩数字只认**
> `doc/reports/2026-10-17_delivery_rev1028.md`。

---

## 1. 现在在哪

| 项 | 值 |
|---|---|
| 分支 / 工作树 | `feat/mem128k`，**干净**（无未提交文件） |
| 最近提交 | `4245adc`（归档）← `58e0e56`（交付页）← `0da9933`（vblank 定性）← `29a13c7`（板上证据）← `ffcfa46` ← `2da888f`（合并镜像+位流）← `e3a9d17` ← `bf6fd8c`（76.5MHz 时序档） |
| 交付位流 | `pds/RV32I_1/generate_bitstream/cpu_top_board.sbit`，md5 **`b45941d6`**（2026-10-17 18:11:33） |
| 归档副本 | `pds/RV32I_1/bitstreams/combined_..._rev1028_seed10pin_b45941d6.sbit`（本地，`.sbit` 被 gitignore） |
| 归档说明 | `pds/RV32I_1/bitstreams/README.md` 的 **rev1028 章节**（配置/镜像/时序/板测/备份关系/复现） |
| 位流内容 | **一份** `mem.hex`：boot 17 字 + CoreMark 8,552 字 + RT-Thread 11,141 字 = 19,710 字 / 39,420 行 |
| 板上状态 | 默认复位 → 五子棋（heap 4840 / `[hb] alive`）；**按住 SW6 + SW3** → CoreMark（846,440,591 拍 / 352.5 / 4.6075 / 四 CRC 全对） |

### 1.1 并行分支 `feat/perf-opt`（性能优化，**已归档、不进交付**）

| 项 | 值 |
|---|---|
| 分支 | `feat/perf-opt`（从本分支 `bd59ce3` 拉出，4 个提交：`fa9125a` → `27ee172` → `2165626` → `d22041c`） |
| 交付锚点 | 标签 `deliver-b45941d6`（= 本分支 `bd59ce3`），任何优化结论都不回写交付数字 |
| 仿真成绩 | 217,088 → **207,611 拍/迭代**（主分 4.6075 → **4.8167**，+4.54%），四 CRC 不变、riscv-tests 49/1/0 ×3、own_tests 8/0、单发射 300,392 逐位不变 |
| **PDS 判据** | 76.5 档 seed 10：冻结网表复现 **+0.304 / 78.3269 / 0 失败**；优化网表**全部** −0.318 ~ −0.593（seed 8 到 −0.823）**⇒ 上不了板** |
| 结论 | P3b（lane B 分支）**判死**；降频换 CPI 不划算；后续只走"减 LUT 提指标③"（不吃关键路径） |
| 全记录 | `doc/reports/2026-10-17_p1_ab_bypass.md`（含对照实验、失败原因、还能做什么） |
| 减 LUT 清单 | `doc/reports/2026-10-17_lut_reduction_candidates.md`（L1 UART FIFO −64 / L2 BTB −192 / L3 BHT −100，含验收门槛与命令） |

> [!] 在本仓库跑 PDS 前必须 `git branch --show-current` 确认分支。本会话出现过一次
> "工作树被切到 `feat/mem128k`、PDS 跑在冻结 RTL 上"的事故；稳妥做法是
> `git worktree add <临时目录> <分支>`，在独立目录出流，用完 `git worktree remove --force`。

---

## 2. 已冻结的决定（不要再讨论，除非用户改口）

| 决定 | 值 |
|---|---|
| 交付位流 | **只有一颗**：`b45941d6`。`c6af65be` / `5909a2d0`（85MHz 两颗流时代）降为**备份** |
| Cache | **关**（`DCACHE_EN=ICACHE_EN=0`）。带 Cache 主分 4.291（−6.9%），最多做"非交付"评估档 |
| 按键约定 | **`key[2]` = 丝印 SW6**（bit 10，低有效）。按住进 CoreMark，松开进 RT-Thread |
| 频率 | **76.5052 MHz**（PLL STATIC_RATIO0 = 15.0）。85.0051 已用 8 seed 证伪，**不再尝试 85/80** |
| 跑分/应用关系 | 同一颗位流 + 运行时二选一（满足官方答疑第 53 问 R99） |
| 五子棋验证方式 | **只在板上测**，不做棋局仿真（2026-10-17 决定，仿真成本远高于收益） |

---

## 3. 证据清单（每条都可复查，别凭记忆）

| 证据 | 位置 | 关键值 |
|---|---|---|
| 时序（CPU 域） | `pds/RV32I_1/report_timing/cpu_top_board.rtr` | **+0.304 ns / 0 失败端点（21,135）/ Fmax 78.3269** |
| 跨域 | 同上 Setup Summary | clk_sys→pix_clk **+6.484 / 0**；pix_clk→clk_sys **+8.477 / 0** |
| 约束总判 | 同上 | **`Design Summary : All Constraints Met`** |
| 资源 | `pds/RV32I_1/run.log`（`Total LUTs` 段） | **LUT 7,740 / 159,800（4.84%）**、FF 3,692、DRM 165.5 / 415（39.88%） |
| 板上 | `doc/board/uart_20261017_190201.txt` | 两条路径；`Total ticks 846,440,591`；四 CRC `e9f5 e714 1fd7 8e3a` |
| 合并镜像仿真 | `scripts/run_combined_sim.ps1` | 路径 A `region=1`、路径 B `region=2` + banner |
| 回归 | `scripts/run_riscv_tests.ps1` / `scripts/run_own_tests.ps1` | riscv-tests **49 PASS / 1 FAIL(ma_data，基线预期) / 0 TIMEOUT**；own_tests **8/0** |
| 固件指纹 | `pds/RV32I_1/mem.hex` | 39,420 行，sha256 `d8a8ce93…` |

---

## 4. 剩余任务（按依赖排序，估时是净工时）

| 优先级 | 任务 | 依赖 | 估时 | 产出 |
|---|---|---|---|---|
| **P0** | 下完一局五子棋（人机 AI 与对战各一局） | 板子 | 0.5 h | 板级验收闭环 |
| **P0** | ILA 抓取 | **新 `.fic` 必须与 `b45941d6` 同源** | 0.5~1 d | 91 根探针 + 建议触发：boot 分叉瞬间（`pc 0x14→0x1004 / 0x10004` 同时抓 `key[2]`）——"单一位流"最直观的证据 |
| **P1** | 演示视频 | HDMI 正常（已确认） | 0.5 d | 同一颗流：五子棋 → 复位+按住 SW6 → 11.06 s 跑分 → 回五子棋 |
| **P1** | 报告 / PPT 正文 | 上面两项 | 1~2 d | 结构按 R104 第 4 条（场景 → 资源/时序 → CoreMark）；数字抄 `delivery_rev1028.md` |
| **P2** | 资源证明页（2L200H vs 200K MINI） | 官方 200K MINI 容量待核 | 0.5 h | 初稿已在 `delivery_rev1028.md` §6 |
| **P2** | Cache 评估档（76.5 + I+D，**非交付**） | 需 `pds` 工程副本（GUI 锁着主工程） | 15~20 min 机器 + 搬运 | 备用数据：主分 4.291 / 经典分 325.96 |
| ~~—~~ | ~~性能优化（P3b / 加宽发射）~~ | **已判死**（见 §1.1） | — | 只保留 `feat/perf-opt` 归档；唯一还有空间的方向是"减 LUT 提指标③" |
| P2 | 减 LUT（可选，**必须排在 ILA/视频/报告之后**） | 清单见 `2026-10-17_lut_reduction_candidates.md` | 0.5 d | L1+L2+L3 估算 −356 LUT ≈ 指标③ +4.5%，且不碰 CPU 关键锥 |

---

## 5. 硬约束与陷阱（12 条，按踩过的顺序）

1. **固件冻结窗口**：任何 `scripts/**` 固件源码改动 → `mem.hex` 变 → 位流作废。改一行 printf 也要重出 15 分钟。
2. **Fmax 只认** `seed_*/cpu_top_board.rtr` 里 `Path Group: clk|u_pll/u_gpll/CLKOUT0_Inferred` 那一行。
3. **`multiseed` 日志里的 `Setup (Slow)` 是跨域口径**，不能当 CPU 域引用（历史上因此误读成 87 MHz）。
4. **`capture_seed_timing.ps1` 已修好**：Fmax 从报告读请求周期（76.5 档 → 78.3269、85 档 → 87.0549）。别再改回硬编码 11.764。
5. **分数口径**：报告写 **352.5 / 4.6075**（`Total ticks ÷ EE_TICKS_PER_SEC`）。串口打印的 `354` 是 `HAS_FLOAT=0` 的整数秒截断；**打开 `HAS_FLOAT=1` 会让 `.text` 32KB → 96,217B、越出 56KB 区间**（已实测并回退）。
6. **资源两个口径**：引 `run.log` 的 `Total LUTs 7740`（逻辑）；日志末尾 `CLMA 6497 + CLMS 2265 = 8,762` 是**物理站点口径**，不许混。
7. **永远不要** `git checkout pds/RV32I_1/RV32I_1.pds`（会把 `gplace_seed` 从 10 退回 5）。
8. **`core.v` 的重定向写 `pc_r = target + 4`**（`core.v:1686`）：pc 端口看不到 `0x1000/0x10000`，测试台只能按**区间**判路由。
9. **`merge_images.py` 五类硬错**：重叠 / 越界 / 兼容区 `0xFFF0~0xFFFF` / **`0x1FFF0~0x1FFFF` 保留区** / 入口不等于区间起点。改布局必须同时改 `LAYOUT` 与两份 `link.ld`。
10. **128KB 地址别名**：兼容区判决依赖 `!addr[16]`（`rtl/bus/mem_bus.v`）。负向验证已做：`imem_addr2` 截 14 位 → `hi_fetch_128k` FAIL。
11. **PS 5.1 三件套**：`.ps1` 必须带 **UTF-8 BOM**（否则中文乱码/解析错）；`ld` 的 RWX 警告会抛 NativeCommandError（脚本里已用 EAP=Continue 包住）；`sim/*.v` 是 **GBK**，新建的 `tb_combined.v` 故意写成 ASCII。
12. **同一 PDS 工程不能并发**；PDS GUI 打开时目录被锁。评估档必须复制工程目录跑。

---

## 6. 常用命令

```powershell
# 出交付位流（boot + CoreMark(ITER=3900) + RT-Thread → 合并 → 综合）
scripts\build_bitstream.ps1 combined

# 合并镜像两条路径的仿真判据（ITER=1，约 3~5 分钟）
scripts\run_combined_sim.ps1

# 只校验三块镜像不合并（重叠/越界/兼容区/保留区）
python scripts\merge_images.py --no-out

# 只重建 boot selector（≤4KB，链接期 ASSERT）
scripts\boot\build.ps1

# 读时序（只认 CPU 那一行）
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\cpu_top_board.rtr

# 上板
scripts\serial_monitor.ps1 -Port COM4 -Seconds 120
```

---

## 7. 需要人确认的两件事

1. **官方「200K MINI」的具体 LUT/DRM 总量** —— 仓库里没有留证，`delivery_rev1028.md` §6 已标 `[?]`。
   拿到后把资源证明页的占比换算成对方手册口径（我们的绝对用量 7,740 LUT 不变）。
2. **Cache 评估档要不要真跑** —— 需复制 `pds/RV32I_1` 到独立目录（GUI 锁主工程），约 15~20 分钟机器时间；
   产物只能标"非交付"。

---

## 8. 本轮新增/修改的文件

| 文件 | 作用 |
|---|---|
| `scripts/boot/{boot.S,link.ld,build.ps1}` | 0 级 boot selector（17 字 / 68 B / `_end 0x44`），读 `key[2]` 选路 |
| `scripts/merge_images.py` | 三块镜像合并 + 布局硬校验（五类错误） |
| `scripts/run_combined_sim.ps1`、`sim/tb_combined.v` | 合并镜像双路径仿真判据 |
| `scripts/build_bitstream.ps1` | 新增 `combined` 变体；`Iter` 默认 3900；收尾时钟读 `core_portme.c`；分数口径分离 |
| `scripts/capture_seed_timing.ps1` | Fmax 改为从 `.rtr` 读请求周期 |
| `scripts/coremark_port/link.ld` | `. = 0x1000` |
| `scripts/rtthread/bsp/link.ld` + `scripts/rtthread/build.ps1` | 起点 `0x10000` / 栈顶 `0x1FFF0` / 栈区 4KB / 守卫 61,424 |
| `.gitignore` | 加 `/scripts/boot/build/` |
| `doc/reports/2026-10-17_delivery_rev1028.md` | **答辩数字唯一源**（四个指标 + 合规页 + 资源证明页） |
| `doc/reports/2026-10-17_handoff_mem128k_cpu.md` | 过程与坑（§10 本轮进展、§11 上板实测） |
| `pds/RV32I_1/bitstreams/README.md` | rev1028 归档章节 |
