# 交接 · 128KB 单一位流：CPU 侧收口（2026-10-17 17:10）

> 接 `2026-10-17_handoff_128k.md` / `2026-10-17_three_way_split.md` / `2026-10-17_qa_compliance.md`。
> 分支 **`feat/mem128k`**，HEAD **`f239cff`**（B1 已提交：15 位字地址 + 兼容区 `!addr[16]`）。
> **工作树有未提交的时钟口径改动**（§4），下一个会话先看清楚再动。
> 本文是下一个会话的**唯一入口**。

---

## 0. 一句话

**85 MHz 判死**（8 seed 最好 −0.796 ns），已按 **76.5052 MHz** 出了候选位流：
**CPU 域 +0.304 ns / 0 失败端点 / Fmax 78.33 MHz / `Design Summary: All Constraints Met`**，
位流 **`6074c89c`（未上板）**。
**四个回归探针已全绿**（§5.1：riscv-tests 49/1/0、own_tests 8/0、CoreMark 217,088 拍 + 四 CRC、`hi_fetch_128k` 负向验证）；
剩下 = 提交冻结 → B2/B3 → 合并镜像 → 上板 → ILA/视频。

---

## 1. 本会话做了什么

| 步骤 | 内容 | 证据 |
|---|---|---|
| D | 8 seed 扫描（`gplace_seed 8` + `gplace_times 8`，并行 4），**逐 seed 抢拷 CPU 域报告** | `pds/_capture_seeds/b1_mem128k/`（8 份 `.rtr` + `seed_cpu_wns_summary.csv`） |
| 判定 | 85 MHz 不可行（见 §2.1） | 同上 |
| A | PLL `STATIC_RATIO0` 13.5→15.0 并 `ip_generate`；4 处时钟常量；CoreMark `ITER=3900` 重编；钉 `gplace_seed 10` 出流 | `pds/RV32I_1/_b1_build76.log`、`report_timing/mem128k_76mhz_seed10_6074c89c.rtr` |
| 文档 | 用原件核对官方答疑表，勘误落进 `2026-10-17_qa_compliance.md` **§9** | 原件 `D:\download\2026FPGA大赛紫光同创杯答疑表.xlsx` |

时间线：16:30 起 8 seed → 16:49 全收；16:52 起 76.5 单 seed → **17:02:36 出位流**。

---

## 2. 数字（引用前先看口径）

### 2.1 85 MHz 的 8 个布局（CPU 域，`Setup Summary(Slow Corner)` 里 launch==capture 那行）

| seed | 8 | 13 | 12 | 11 | 15 | 9 | 14 | **10（最优）** |
|---|---|---|---|---|---|---|---|---|
| WNS (ns) | −1.309 | −1.283 | −1.192 | −1.185 | −1.136 | −1.092 | −0.941 | **−0.796** |
| 失败端点 | 1,109 | 1,310 | 771 | 966 | 853 | 861 | 535 | **334** |

- 极差 **0.513 ns**；最好的布局仍差 **0.796 ns** ⇒ **85 MHz 不可达**（要补的量是 seed 空间的 1.5 倍）。
- 失败路径只有 3 类，全是 **BRAM 读 → load 解包/前递 → 分支比较 → `ex_resolve_taken` → `if_addr_d` → `imem_addr` → BRAM 地址口**；其中走线占 68%。
- 根因不是逻辑变大：LUT 7,767→7,833（+66）、FF +1，**DRM 101.5→165.5（+64，三份阵列各翻倍）**。

### 2.2 76.5 MHz 候选档（`6074c89c`）

| 项 | 值 | 来源 |
|---|---|---|
| Requested / Estimated | **76.5052 MHz** / **78.3269 MHz** | `Performance Summary` |
| Requested / Estimated 周期 | 13.0710 / **12.7670 ns** | 同上 |
| CPU 域 WNS | **+0.304 ns / 0 失败端点（21,135）** | `Setup Summary(Slow Corner)` |
| 跨域 `CPU→pix_clk` | **+6.484 ns / 0 端点** | 同上（85 档是 −1.181/21） |
| Design Summary | **All Constraints Met** | 报告首页 |
| 资源 | LUT **7,740** / FF **3,692** / DRM **165.5 (40%)** / Dist RAM 572 | PDS `Device Utilization Summary` |
| 位流 | `pds/RV32I_1/generate_bitstream/cpu_top_board.sbit`，md5 **`6074c89c`**，2026-10-17 17:02:36 | 本地实测 |
| 固件 | CoreMark，`ITER=3900`，`mem.hex` **17,104 行 / 8,552 字** | 守卫通过 |
| 时长 / 分数 | **11.0665 s**；主分 **4.6064 CoreMark/MHz**；经典分 **352.4** | 算得，未上板 |

> [!] **`Design Summary: All Constraints Met` 是本次的意外收获**：85 档那条"跨域 21 端点伪影"在 76.5 + seed 10 上变成 **+6.484 ns / 0 端点**。
> 这只证明**这一版布局没有该伪影**，不能外推成"伪影从此消失"——报告里仍要备那段 CDC 说明（`qa_compliance` §3.2）。

### 2.3 与 85 MHz 交付档的差（答辩口径）

| 项 | `c6af65be`（85 MHz，rev1027，64KB） | `6074c89c`（76.5 MHz，rev1028，128KB） |
|---|---|---|
| 主分 | 4.6064 | **4.6064（不变）** |
| 经典分 | 391.66 | **352.4** |
| Fmax | 87.0549 | **78.3269** |
| DRM | 101.5 | 165.5 |
| 合规 | **两颗位流** | **单一位流（待 B2 落地）** |

⇒ 128KB 换来的代价全在**指标② Fmax**；主分一分没丢。

---

## 3. 为什么钉 seed 10、为什么降到 76.5

- 85 MHz 下 8 个布局全部为负，最好 −0.796 ⇒ 不是"运气问题"，是 **BRAM 翻倍后 RAM 读 → 分支 → 取指链**的物理距离。
- 76.5 MHz 只是把捕获窗口从 11.764 放宽到 13.071 ns（+1.307），不动机器周期 ⇒ **CoreMark 拍数应仍为 217,088**（待 §5 第 1 步验证）。
- seed 10 是 85 档实测最好的布局；换 PLL 后净表变了，**实测 +0.304（不是换算预测的 +0.511）** —— 见 §6 坑 1。

---

## 4. 工作树未提交改动（**先看这一节**）

| 文件 | 改了什么 | 为什么 |
|---|---|---|
| `rtl/top/cpu_top_board.v` | `.UART_DIV(10'd738)` → **`10'd664`** + 头注释改 76.5 | 76,505,200/115,200 = 664.1 |
| `scripts/coremark_port/core_portme.c` | `EE_TICKS_PER_SEC` 85,005,100 → **76,505,200** | 板上秒数口径 |
| `scripts/demo/addr_map.h` | `CPU_HZ` → **76,505,200u** | 五子棋去抖/长按阈值 |
| `scripts/rtthread/bsp/board.h` | `BOARD_SYSTEM_CLOCK_HZ` → **76,505,200u** | RT-Thread tick/延时 |
| `pds/RV32I_1/ipcore/pll/pll.idf` | `STATIC_RATIO0` 13.5 → **15.0** | VCO 1147.5/15 = 76.5 MHz |
| `pds/RV32I_1/ipcore/pll/pll.v`、`.last_generated` | `ip_generate.exe -i pll.idf` 重生成 | 同上 |
| `pds/RV32I_1/RV32I_1.pds` | `gplace_seed` 5 → **10** | 钉本轮布局 |
| `pds/RV32I_1/mem.hex` | 76.5 档 CoreMark（17,104 行） | 由 `build_bitstream.ps1` 同步 |
| `pds/RV32I_1/report_timing/mem128k_*.rtr` | **新增**归档（85 失败档 + 76.5 通过档） | 证据 |

> [!] `build_bitstream.ps1` 的 `expectLines[coremark]=17104` **仍然成立**；但 `rtthread` 的 **22,028 在 76.5 下会变**（`board.h` 改了常量除法），出演示档前必须重测并更新守卫。

---

## 5. 下一步（按序，全部有判据）

1. **B4 回归四探针**（CPU 冻结前必须全绿）
   ```powershell
   scripts\run_riscv_tests.ps1                  # 49 PASS / 1 FAIL(ma_data) / 0 TIMEOUT
   scripts\run_own_tests.ps1                    # 6 PASS / 0 FAIL
   scripts\run_coremark.ps1 -Iter 1 -EarlyLd    # 四 CRC e9f5/e714/1fd7/8e3a + 217,088 拍/迭代
   scripts\run_sim.ps1 -NoWave                  # 全过（含 tb_multiplier 840 项）
   # sim/tests/hi_fetch_128k.S —— 提交里新加，还没验"改回 14 位必须 FAIL"
   ```
   > `run_coremark` 在 PS 5.1 会被 `ld` 的 RWX 警告打断（ELF/hex 已生成）；必要时手工 `vvp`。

   ### 5.1 四探针结果（2026-10-17 17:20，**已全绿**）

   | 探针 | 命令（板上配置） | 结果 | 时刻 |
   |---|---|---|---|
   | riscv-tests | `scripts\run_riscv_tests.ps1` | **PASS=49 / FAIL=1（`ma_data`，基线预期）/ TIMEOUT=0** | 17:08 |
   | 自写定向测试 | `scripts\run_own_tests.ps1 -LanebMem -EarlyLd` | **PASS=8 / FAIL=0**（含 `hi_fetch`、`hi_fetch_128k`、`tb_amo_cpu`、`timer_irq`、`exceptions`） | 17:10 |
   | CoreMark | `scripts\run_coremark.ps1 -Iter 1 -EarlyLd -LanebMem` | **Total ticks = 217,088**；四 CRC **`e9f5 / e714 / 1fd7 / 8e3a`** | 17:14 |
   | 负向验证 | 把 `imem_addr2` 临时改成 `{1'b0, fetch_addr[14:2]} + 15'd1` 再跑 `-Name hi_fetch_128k` | **`FAIL (testnum 1)`** ⇒ 测试真的能抓住 14 位回绕；已 `git checkout` 还原 | 17:19 |

   > `ITER=1` 的 `total cycles = 1,527,634` 含一次性初始化；**每迭代看 CoreMark 自己打印的 `Total ticks = 217,088`**。
   > 周期数与 64KB 版逐位一致 ⇒ 128KB 扩容没有引入额外拍子（符合 BRAM 仍 1 拍读的预期）。
2. **提交本档**（RTL + 常量 + pll + .pds seed 10），信息里写清"76.5 MHz / +0.304 / 6074c89c / 未上板"。
3. **B2**：`scripts/coremark_port/link.ld` 改 `. = 0x1000`；新增 `scripts/boot/boot.S`（链接 `0x0`，≤4KB，读 `0x8000_0000` 的 key[2]，按住 → `0x1000`，否则 → `0x10000`）。
4. **I1**：`scripts/merge_images.py` + `build_bitstream.ps1` 的 `combined` 变体（重叠/越界/兼容区别名必须报错）。
5. 甲：`scripts/rtthread/bsp/link.ld` 重定位 `0x10000`、栈顶 `0x1FFF0`，实测 `[boot] heap`。
6. 合并镜像仿真 → 单一 `.sbit` → 板上双路径 → ILA → 视频 → 报告（结构按 `qa_compliance` §9.3）。

---

## 6. 本次新增的坑（按代价排序）

1. **换频 = 换净表 ⇒ 钉住的 seed 余量作废**。seed 10 在 85 档 −0.796（按 1.307 换算应得 +0.511），换 PLL 后实测 **+0.304**（差 −0.207）。**换频后必须重收时序，不能用换算值当结论。**
2. **`capture_seed_timing.ps1` 的 Fmax 是按 85 MHz 周期 `11.764` 硬编码**：拿它解析 76.5 报告会打印 `87.26 MHz`（错）。正确算法 `Fmax = 1000/(13.071 − WNS)`。**脚本待修**。
3. **PDS 多 seed 日志里的 `UserFilter: Setup(Slow) -1.2 ~ -1.6` 仍是跨域口径**，排序只认 `seed_*/cpu_top_board.rtr` 里的 CPU 行。
4. **PDS 每跑一次都重写 `.pds`**：本轮跑完已把 `gplace_seed 10` 写回；**别顺手 `git checkout -- pds/RV32I_1/RV32I_1.pds`**，会把 seed 退回 5。
5. **`openpyxl` 打不开官方答疑 xlsx**（样式表 `TypeError: Fill() takes no arguments`）⇒ 用 zip + XML 直读（做法见 `qa_compliance` §9 开头）。
6. `ld` 的 `LOAD segment with RWX permissions` 警告在 PS 5.1 下会抛 `NativeCommandError`，但 **ELF/hex 已生成**，不影响构建结果。
7. 大目录 `pds/_capture_seeds/`（8 份 `.rtr` + 日志）**不入库**；结论表格已落进本文件 §2.1。

---

## 7. 未决问题（需要用户 / 集成方裁决）

| # | 问题 | 选项 | 影响 |
|---|---|---|---|
| 1 | 要不要出一颗 **76.5 + I+D 的评估档**（只作证据，不进交付） | 做（~15 min）/ 不做 | 主分 4.291（−6.8%）、余量可能不够 |
| 2 | boot selector 按键约定 | 按住 **KEY_UP** → CoreMark，默认 → 五子棋 | 影响视频拍法、说明书 |
| 3 | 板卡资源证明页 | 2L200H 不在推荐型号字面清单（R112 = 200K MINI） | 按 R104 第 2 条备材料 |

---

## 8. 命令速查

```powershell
cd D:\riscv-cpu-fpga_merged
git log --oneline -3 ; git status

# 看本轮 CPU 域时序（判据行）
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\RV32I_1\report_timing\mem128k_76mhz_seed10_6074c89c.rtr
powershell -File scripts\capture_seed_timing.ps1 -Parse pds\_capture_seeds\b1_mem128k

# 出流（唯一入口；76.5 档）
scripts\build_bitstream.ps1 coremark -Iter 3900

# 改频率三步（如需再动）
#   1) pds\RV32I_1\ipcore\pll\pll.idf 的 STATIC_RATIO0
#   2) cd pds\RV32I_1\ipcore\pll ; D:\pango\PDS_2022.2-SP6.4\bin\ip_generate.exe -i pll.idf
#   3) 同步 cpu_top_board.v 的 UART_DIV / core_portme.c / addr_map.h / board.h，并重算 ITER
```

---

## 9. 一句话交接

> **CPU 侧已在 76.5 MHz 收敛（+0.304 ns / 0 失败端点 / `6074c89c`，未上板），85 MHz 用 8 个布局证伪。**
> **四个探针已全绿（§5.1），RTL 可以冻结 rev1028。**
> 下一个会话第一件事：**提交本档**（§4 的 9 个文件），
> 然后做 **B2 boot selector + 合并镜像**，把"两颗位流"变成"一颗位流"——这是官方答疑第 53 问的唯一硬项。
> 别再追 85/80 MHz：主分与频率无关，指标②已定 78.33，时间要花在合规和演示材料上。

---

## 10. 本轮进展（2026-10-17 18:15，B2/I1/甲/出流全部落地）

### 10.1 提交

| 提交 | 内容 |
|---|---|
| `bf6fd8c` | rev1028 时序档：9 个代码/配置文件（76.5052MHz / +0.304 / `6074c89c` / 回归 49-1-0 + 8-0 + 217088） |
| `e3a9d17` | 文档：交接入口 + `qa_compliance` §9 七条勘误 + `three_way_split` 顶部声明 |
| 见本条提交 | B2 + I1 + 甲 + 合并位流 `b45941d6` |

> 工作树原本是 **14 个已改 + 1 个新文档**，不是 §4 写的 9 个 —— 因为
> `pds/**/report_timing/` 被 `.gitignore` 忽略（时序归档只能本地留，结论已落 §2）。

### 10.2 B2：boot selector（`scripts/boot/`）

- `boot.S`：**17 字 / 68 B，`_end = 0x44`**，链接脚本用 `ASSERT(_end <= 0x1000)` 挡越界；
- 读 `0x8000_0000` 的 **key[2] = bit 10**（丝印 **SW6**，低有效），连采 3 次（间隔约 0.5ms）取按位与：
  三次都读到 0 → `jr 0x1000`（CoreMark），否则 → `jr 0x10000`（RT-Thread）；
- **选路在任何写 RAM 之前**完成（两个程序 bss 范围不同，先清 bss 会清掉对方还没跑的数据区）；
- `vendor`：`scripts/boot/build.ps1`（4KB 双保险：ASSERT + `_end` 复核），产物 `scripts/boot/build/` 已加 `.gitignore`。

### 10.3 I1：合并镜像（`scripts/merge_images.py` + `build_bitstream.ps1 combined`）

布局与产物（实测）：

| 镜像 | 区间 | 字数 | 行数 |
|---|---|---|---|
| boot | `0x00000~0x00043` | 17 | 34 |
| coremark | `0x01000~0x09a67` | 8,552 | 17,104 |
| rtthread | `0x10000~0x1b23f` | 11,141 | 22,282 |
| **合并** | — | **19,710** | **39,420** |

四类错误**全部实测会 exit 2 且指向根因**（不是警告）：

1. 交叉重叠 —— `coremark 与 rtthread 有 6 个字重叠（最小 0x10000）`
2. 段内越界 —— `coremark 越界：占 0x01000~0x0f00f，区间 0x01000~0x0efff`
3. 兼容区 —— 落在 `0xFFF0~0xFFFF` 直接报错（先于"越界"判，否则提示会误导成"程序太大"）
4. **`0x1FFF0` 保留区** —— `rtthread 有 4 个字落在保留区 0x1fff0~0x1ffff`，报错文本明确写出
   "兼容区判决漏 `!addr[16]` 就会被误判成 MMIO"

另有两条：入口必须等于区间起点（`boot.S` 是常数 `jr`，起点错了会跳进别人中段）、镜像不能为空。

### 10.4 甲：RT-Thread 重定位（`scripts/rtthread/`）

| 项 | 值 |
|---|---|
| 起点 | `0x10000`（`.text.init`，`boot.S` 的 `jr` 目标） |
| 栈顶 | `0x1FFF0`（`__stack_top = __rt_rvstack`） |
| 栈区 | **4KB：`0x1EFF0~0x1FFF0`**（`__heap_end = __stack_bottom = 0x1EFF0`） |
| text / data / bss | 44,373 / 188 / 10,952 B |
| `_end` | `0x1DD08` |
| **堆** | **4,840 B**（静态占用 **90.4%**，`$ramTotal` 61,424） |
| mem.hex | **22,282 行 / 11,141 字**（守卫从 22,028 更新） |

> [!] **这是本轮唯一的新增风险**：`three_way_split` §1.1 估的"堆约 10 KB"偏乐观，
> 实测只有 4,840 B。板上第一条要看 `[boot] heap = 4840`；五子棋若 malloc 峰值超了会挂，
> 届时先裁 rodata / T6 装饰 tile，不要动栈顶（`0x1FFF0` 与 `0x1FFF0~0x1FFFF` 保留区是硬的）。
> 另：`stack_top = 0x1FFF0` 但栈区只留 4KB —— 与上一版 `0xF000~0xFFF0` 等价，
> **不要**把 `__heap_end` 顶到 `0x1FFF0`，否则中断一来就踩穿堆。

### 10.5 合并镜像仿真（`sim/tb_combined.v` + `scripts/run_combined_sim.ps1`）

| 路径 | 判据 | 结果 |
|---|---|---|
| A：按住 key[2] | `region=1`、`first_pc=0x00001004`、跑到 `done` | **PASS**：`Total ticks 217088`、四 CRC `e9f5/e714/1fd7/8e3a`、679 字符、1,647,671 拍 |
| B：松开 | `region=2`、`first_pc=0x00010004`、出 banner | **PASS**：RT-Thread 5.3.1 banner + `[build] FW=RTTHREAD-GOMOKU-G3`，817 字符 |

> [!] **坑（新）**：`core.v` 的三路重定向一律写 `pc_r = target + 4`（`core.v:1686`），
> 所以 `pc` 端口**永远看不到** `0x1000` / `0x10000` 本身（`0x14 → 0x1004`）。
> 判路由只能按**区间**判，别写等值比较。
>
> [!] 五子棋**不做仿真**（2026-10-17 决定）：按键去抖/长按 600ms 在 100MHz 下是 6000 万拍、
> AI 递归深度不可控、还要 video_core 出 vblank。分工：**仿真证"镜像 + 路由 + CoreMark"，
> 板上证"游戏可玩"**。B 路径判到 banner 为止，够证明分叉成立。

### 10.6 交付位流（合并镜像）

| 项 | 值 |
|---|---|
| 文件 | `pds/RV32I_1/generate_bitstream/cpu_top_board.sbit` |
| md5 | **`b45941d6`**，2026-10-17 **18:11:33**，9.19 MB |
| CPU 域 | **+0.304 ns / 0 失败端点（21,135）**，Fmax **78.3269** |
| Design Summary | **All Constraints Met** |
| 布局 | 钉 `gplace_seed 10`（`.pds` 里仍是 10） |
| 固件 | `mem.hex` 39,420 行，与 `sim/programs/mem.hex` **sha256 一致** |
| 状态 | **已上板 · 两条路径均通**（2026-10-17 18:54，见 §10.9） |

⇒ 与 `6074c89c` 逐项一致：**装两个程序的代价是 0**（BRAM 初值不进时序路径）。

### 10.7 工具修正

- `capture_seed_timing.ps1`：Fmax 从"写死 11.764"改成**从 `.rtr` 的时钟表读请求周期**，
  双档验证通过（76.5 档 → 78.3269、85 档 → 87.0549）。原写法解析 76.5 报告会打印 87.26（错）。
- `build_bitstream.ps1`：新增 `combined` 变体；`Iter` 默认 4332 → **3900**；
  收尾打印的时钟改成读 `core_portme.c` 的 `EE_TICKS_PER_SEC`（不再写死 85,005,100）。
- `.gitignore`：加 `/scripts/boot/build/`。

### 10.8 下一步（按序）

1. **上板**（串口先看 `[boot] heap`，再下完一局）→ 两条路径都要跑通；
2. **ILA**：`capture_update_ila` 用**新** `.fic`（与 `b45941d6` 同源），91 根探针复核；
3. **视频**：同一颗位流，按住 SW6 跑分（11.07 s）→ SW3 复位 → 进五子棋；
4. **报告**：按 R104 第 4 条顺序（场景 → 资源/时序 → CoreMark），时序页单列 CPU 域
   `+0.304 / 0 失败 / 78.3269`，并备 CDC 伪影说明（`qa_compliance` §3.2）；
5. **待裁决三项**（§7）仍原样：评估档做不做、按键约定（现为 **key[2]=SW6**）、资源证明页。

---

## 11. 上板实测（2026-10-17 18:54:44，`b45941d6`）

日志：`doc/board/uart_20261017_185444.txt`（COM4 @115200，连续 120 行，含 3 次复位）。

### 11.1 两条路径都通（**R99 从"仿真过"升级为"板上过"**）

| 路径 | 板上现象 | 判定 |
|---|---|---|
| 默认（不按 SW6） | banner → `[boot] heap = 4840` → render/ai 两线程 → `[hb] alive 5000/10000/15000 ticks` | **PASS**（连续 3 次复位一致） |
| 按住 SW6 + SW3 | `[build] FW=COREMARK` → `Total ticks 846,440,591` / `Correct operation validated` / 四 CRC `e9f5 e714 1fd7 8e3a` | **PASS** |

**同一份 `mem.hex`、同一颗位流，两条路径先后跑通** ⇒ 官方答疑第 53 问（R99）不再是"设计意图"，
而是**板上可复现的事实**。录像脚本可以照这个顺序拍：默认进五子棋 → SW3 复位 + 按住 SW6 → 11 s 跑分。

### 11.2 板上数字（与预测对比）

| 项 | 预测 | 板上实测 | 差 |
|---|---|---|---|
| Total ticks | 846,643,200（3900×217,088） | **846,440,591** | −202,609（−0.024%） |
| 时长 | 11.0665 s | **11.0638 s** | — |
| 经典分（Iterations/秒） | 352.4 | **352.5** | — |
| 主分 | 4.6064 CoreMark/MHz | **4.6075** | +0.0011 |
| 每迭代拍数 | 217,088 | 217,036 | −52 |

> [!] **打印的 `Iterations/Sec 354` 不能用**：`ee_printf` 没有浮点，CoreMark 走 `%d` 分支
> （`core_main.c:367`），先把 11.0638 s 截成 **11 s** 再除 → 3900/11 = 354（高报 0.4%）。
> 报告与答辩一律用 **352.5 / 4.6075**（按 `Total ticks ÷ EE_TICKS_PER_SEC` 算），
> 并注明"串口打印为整数秒口径"，别让评委按 354 反推出 4.63。
> 修这个要动固件（重新出流），**不值得** —— 数字本身在 `Total ticks` 行里是准确的。

### 11.3 资源（与 `6074c89c` 逐项相同）

`run.log:931-938`：`Total LUTs 7740 / 159800 (4.84%)`、`Total Registers 3692`、`Total DRM 165.5 / 415 (39.88%)`。

> [!] 同一份日志末尾的 `Device Utilization Summary` 会把 LUT 拆成 `CLMA 6497 + CLMS 2265 = 8,762`，
> 那是**物理站点口径**，与 `Total LUTs 7,740`（逻辑口径）不是一回事。
> 报告只引一个口径 —— 用 `Total LUTs 7740`，并写明"PDS run.log 逻辑 LUT 口径"。

### 11.4 唯一未闭环项：`[!] vblank timeout`

出现 3 次（每次复位最多打一次，`main.c:429` 的一次性告警）。

已排除的原因：
- **不是改频引起**：视频链吃板上原始 27MHz，`video_top` 自带独立 `u_pll_video`（`cpu_top_board.v:137-148`）；
- **不是时序**：新报告 `CPU→pix_clk` = **+6.484 ns / 0 失败端点**；
- **不是 128KB 引起**：显存译码在 `0x8001_0000` 以上，`addr[17:16]≠0`，与 RAM 扩容不相交。

待判定（需肉眼，日志分不出来）：
1. **D18（`led[1]=video_locked`）是否常亮** —— 不亮 = 视频 PLL 没锁，真问题；
2. **屏幕是否出画面（标题菜单 / 15×15 棋盘）** —— 有画面 = 该行只是"复位后第一次 50ms 等超时"的良性竞争
   （2026-10-07 加超时保护时的同款现象），记一句说明即可。

若确为良性：报告里写成"启动瞬间视频域未就绪，首帧同步等待超时一次后自动恢复"，并给
`video_wait_vblank` 的 50ms/3 帧超时保护作为鲁棒性设计。
