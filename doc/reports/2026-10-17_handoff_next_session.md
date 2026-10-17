# 交接 · 2026-10-17 19:30 → 下一个会话

> **[!] 2026-10-17 深夜追记 · 减 LUT 版不在本分支**
> 本页描述的是交付位流 `b45941d6`（rev1028），本工作树（`feat/mem128k`）只有这一套，**这是有意的**。
> 更新的候选交付 **rev1029（`c642c0ac`：LUT 7,740→6,932、指标③ +11.7%、已上板、拍数逐位不变）** 在 `feat/lut`，
> 入口见 **`doc/reports/2026-10-17_rev1029_入口.md`**（含不切分支的查看命令与合并纪律）。
> **两线未合并前，本线交付物仍是 rev1028 `b45941d6`。**

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

> **[!] 2026-10-17 深夜改分工**：五子棋界面由队友继续优化（**不要动 `scripts/gomoku/**`**），
> 本线负责人这段时间的**主线任务 = 继续追 CPU 性能（指标①/②）**，见 §4.1。
> 板级验收类任务（整局、ILA、视频、PPT）等候选 rev1029 定稿后再排，避免绑定到会变的位流上。

| 优先级 | 任务 | 依赖 | 估时 | 产出 |
|---|---|---|---|---|
| ✅ **已完成** | **性能交叉实验**（减 LUT 网表 × P1+P3a） | 见 §4.1 | 4 次出流 ≈ 40 min 机器 | **结论：不收敛**（seed 10 −0.449、最优 seed 5 −0.259）；分支已归档为 tag `archive/lut-perf` |
| **P1** | 指标② 纯布局：新网表 40 seed 采样 | 同上 | 1.5~2 h 机器 | Fmax 软顶（可能 79~80） |
| **P1** | ILA 抓取 | **`.fic` 必须与最终交付流同源**（rev1029 定稿后再做） | 0.5~1 d | 91 根探针 + boot 分叉瞬间触发 |
| **P1** | 演示视频 | 同上（位流会变） | 0.5 d | 同一颗流：五子棋 → 复位+按住 SW6 → 11.06 s 跑分 → 回五子棋 |
| **P2** | 报告 / PPT 正文 | 交付定稿 | 1~2 d | 结构按 R104 第 4 条；数字抄 `delivery_rev1028.md`（合并后抄 rev1029） |
| **P2** | 资源证明页（2L200H vs 200K MINI） | 官方 200K MINI 容量待核 | 0.5 h | 初稿已在 `delivery_rev1028.md` §6 |
| **P2** | Cache 评估档（76.5 + I+D，**非交付**） | 需 `pds` 工程副本（GUI 锁着主工程） | 15~20 min 机器 + 搬运 | 备用数据：主分 4.291 / 经典分 325.96 |

---

## 4.1 还有多少性能空间（按赛事三项指标，2026-10-18 定稿）

现状（交付 rev1028，候选 rev1029 只改 ③）：

| 指标 | 现在 | 已到手的更强版本 | 卡在哪 |
|---|---|---|---|
| ① 执行效率（主分 CoreMark/MHz） | **4.6075**（217,036 拍/迭代） | **4.8287**（207,094 拍，P1+P3a，**板上实测**） | **两张网表都实测过：−0.318（旧）/ −0.449（减 LUT 后）⇒ 拿不到** |
| ② Fmax | **78.3699**（+0.311 ns） | 未测：40 seed 采样没做 | 只有布局空间，逻辑侧已无余量 |
| ③ 主分÷千LUT | **0.6647**（LUT 6,932，rev1029） | 已落地，+11.7% | 低风险额度用完，再挖要动 `u_core` 胶合 / `regfile` / `divider` |

> **[OK] 2026-10-18 00:xx 交叉实验已做完，结论 = 不通**（证据：tag `archive/lut-perf`，
> 报告 `2026-10-17_lut_perf_cross.md`；`feat/lut-perf` 分支已归档删除）。
> 拍数 **207,155（−4.58%）拿到了、四 CRC 与 `own_tests` 全绿**，但 76.5052 档：
> `seed 10` **−0.449**（176 失败端点）、扫 seed 后最优 `seed 5` **−0.259**（75.02 MHz）。
> **→ ① 的现实天花板就是 4.6075**，除非重写取指级。

**结论与剩余动作（按性价比）：**

1. **①（主分）：到此为止**。两条独立证据：旧网表 P1+P3a = −0.318；减 LUT 新网表 = −0.449（最优 seed −0.259）。
   扫 seed 也补不上（4 个 seed 全负，排序与旧网表 40 seed 一致：5 > 10 > 8 > 16，全距仅 0.26 ns）。
2. **②（Fmax）：唯一还剩的"零功能风险"空间** = 新网表做 40 seed 采样（旧网表软顶 +0.28，
   新网表端点更少、软顶未知；若 +0.5 ⇒ Fmax ~80.5 / +2.7%）。代价 1.5~2 h 机器 + 抢拷 `.rtr`。
   之前定过"别再追 80"，要做需要你点头。
3. **③（资源）：已用尽低风险额度**。`u_video` 只有 343 LUT（"视频最大"的猜测已被实测证伪）；
   剩下能动的是 `u_core` 胶合 6,100 / `regfile` 1,256 / `divider` ~150，收益 <3%、风险高，**不做**。
4. **不要做**：P3b（lane B 条件分支，要在取指环再加一条腿）、双 load（统一存储器单数据口）、
   取指单加法器（实测 −0.443）、加大 BHT、降到 74 MHz 换主分（② −5.2%，按 R104 顺序不划算）。
5. **要真上一台阶只有一条路**：取指级重构（IF 加一级 / 预取队列），3~5 天，本届不做。

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
