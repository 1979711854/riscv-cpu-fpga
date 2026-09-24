# 队友 45 MHz 改动分析与迁移方案（2026-09-24）

> **这份是给下一个会话的入口。** 读它 + `CLAUDE.md` 就能直接执行迁移，不用重新做分析。
> 结论已由用户拍板：**走分支迁移**；`led[0]/led[1]` 调试信号**保留但加开关能切回演示映射**。

---

## 0. 结论摘要

**队友把系统时钟从 27 MHz 提到 45 MHz（PLL 倍频），并为此刻意缩短了关键路径，已通过综合验证。**

| 指标 | 我们（27 MHz） | **队友（45 MHz）** |
|---|---|---|
| 时钟约束 | 27 MHz | **45.0005 MHz** |
| 可达 Fmax | 37.53 MHz | **51.52 MHz** |
| slack | +10.394 ns | **+2.812 ns** |
| 约束 | ✅ | ✅ **All Constraints Met** |
| LUT / FF | 2915 / 2183 | 3030 / 2185 |
| CoreMark ITER | 820 | **1500**（45 MHz 下 11.96 s）|

⭐ **这正好印证了 2026-09-23 的关键路径分析** —— 当时写下"乘法器 APM 三级级联约占 8 ns，
是 Fmax 优化最直接的抓手"。**队友独立找到了同一个点并把它切掉了**（见 §2 的 `addr_result`）。

---

## 1. 来源与判定依据

| 项 | 值 |
|---|---|
| 路径 | `C:\Users\zjn\Desktop\RV32I\RV2_1\riscv-cpu-fpga` |
| 性质 | **无 `.git`**，是普通目录 —— 从我们仓库导出的全量副本 |
| 基准 | 我们 **2026-09-23 20:36** 的状态（CLAUDE.md 22030 字节、该时刻的时间戳） |
| 判定是"基于我们"的依据 | ① `.gitignore` 与我们**逐字节相同**；② `rtl/core/csr_file.v` 与我们**完全相同**（那是我们 09-23 才写的）；③ `rtl/core/core.v` 只差 7 行 |
| 另一份 | 桌面还有 `riscv-cpu-fpga_clean_20260924.zip`（1.0 MB，09-24 14:32）—— 疑似同一份的打包版，未查 |

### ⚠️ 比对方法：必须先剥 CR

两边的行尾符不一致（git 的 `autocrlf` 造成），**不剥 CR 的话几乎每个文件都"不同"**
（连 09-14 就没动过的 `imm_gen.v`、`SHA256SUMS` 都报差异）。正确做法：

```bash
diff -rq --strip-trailing-cr --exclude=programs --exclude=tools \
  --exclude="*.vvp" --exclude="*.vcd" \
  --exclude=compile --exclude=synthesize --exclude=device_map --exclude=place_route \
  --exclude=report_timing --exclude=generate_bitstream --exclude=generate_netlist \
  --exclude=report_power --exclude=log --exclude=logbackup --exclude=bak \
  "$TEAMMATE" "/d/riscv-cpu-fpga"
```

剥 CR 后**真正的差异只有下面这些**（其余全部相同）。

---

## 2. 改动清单（源码级）

### 2.1 `rtl/core/core.v` — +7 / −2（最关键的一处）

```diff
@@ -312,6 +312,11 @@
     wire [31:0] alu_result = id_ex_is_csr ? csr_rdata :
                              id_ex_is_div ? div_result : alu_raw;
+    // 访存地址 = base + offset，恒为 ADD（load/store 的 alu_op 固定为 0）。
+    // 单独用一个加法器产生地址的低位，把 32×32 乘法器从
+    // "未对齐判据 → 异常 → pc_r 写使能" 这条【假路径】上切下来：
+    // mul 指令从不访存，乘法结果根本不该出现在 pc_r 的时序弧里。
+    wire [31:0] addr_result = alu_a + alu_b;
     assign      div_stall  = id_ex_is_div && !div_done;
@@ -361,7 +366,7 @@
-    wire [1:0] mem_addr_low = alu_result[1:0];
+    wire [1:0] mem_addr_low = addr_result[1:0];
     wire mem_unaligned = ...
@@ -399,7 +404,7 @@
-    wire [31:0] exc_tval = (load_misaligned || store_misaligned) ? alu_result : 32'd0;
+    wire [31:0] exc_tval = (load_misaligned || store_misaligned) ? addr_result : 32'd0;
```

**性质：纯组合旁路，不改变流水线行为、不改变周期数。**
预期每迭代仍是 **358,846** 拍 —— 但**必须跑回归实测确认**（CLAUDE.md 回归纪律）。

### 2.2 `rtl/top/cpu_top_board.v` — +25 / −6

```diff
-    cpu_top u_soc (
-        .clk      (clk),
-        .resetn   (resetn),
+    // ---- PLL：27MHz 晶振 → 45MHz 系统时钟 ----
+    wire clk_sys;        // PLL 输出系统时钟（45MHz）
+    wire pll_locked;     // PLL 锁定指示
+    pll u_pll (
+        .clkin1 (clk),        // 27MHz 晶振输入
+        .clkout0(clk_sys),    // 45MHz 输出
+        .lock   (pll_locked)
+    );
+    // PLL 锁定前保持复位：上电后 PLL 需几百 us 才锁定，期间 clkout0 不稳定，
+    // 用 lock 门控 resetn 能保证 CPU 在稳定时钟下启动。
+    wire sys_resetn = resetn & pll_locked;
+    wire [7:0] led_gpio;    // CPU 的 GPIO LED 输出（led[1:0] 被调试信号占用）
+    wire       done;        // CoreMark 完成标志
+    cpu_top #(.UART_DIV(10'd390)) u_soc (   // 45MHz → 115200 波特
+        .clk      (clk_sys),
+        .resetn   (sys_resetn),
+        .led      (led_gpio),
+        .done     (done)
+    );
+    // ---- 调试：把关键状态拉到 LED 上，判断卡在哪一步 ----
+    //   led[0] = pll_locked ：亮 = PLL 已锁定；不亮 = PLL 没锁，CPU 被一直复位
+    //   led[1] = done       ：亮 = CoreMark 已跑完（写 0x7FF8）；不亮 = 程序没跑完
+    //   led[7:2] = GPIO 原样
+    assign led[0]   = pll_locked;
+    assign led[1]   = done;
+    assign led[7:2] = led_gpio[7:2];
```

> ⚠️ `led[0]/led[1]` 覆盖了我们"LED 按开关位置重排"的映射 → 演示程序 `LED=KEY`
> 的按键→灯对应关系会失效。**用户已决定：保留调试信号，但加开关能切回演示映射。**

### 2.3 其余源码改动（都很小）

| 文件 | 改动 |
|---|---|
| `rtl/top/cpu_top.v` | +3/−2：新增 `parameter [9:0] UART_DIV = 10'd234;`，并 `uart_tx #(.DIV(UART_DIV))` / `uart_rx #(.DIV(UART_DIV))` |
| `rtl/periph/uart_tx.v` | `localparam [9:0] DIV` → `parameter [9:0] DIV`（注释加 45MHz→390） |
| `rtl/periph/uart_rx.v` | 同上；`localparam HALF` → `localparam [9:0] HALF = DIV / 2;` |
| `scripts/coremark_port/core_portme.c` | `#define EE_TICKS_PER_SEC 27000000` → **`45000000`** |
| `scripts/demo/addr_map.h` | `#define CPU_HZ 27000000u` → **`45000000u`**（注释说明回远程平台要改回） |

> **仿真不受影响**：`cpu_top` 的 `UART_DIV` 默认仍是 234（27 MHz），测试台例化 `cpu_top`
> 时没传参数 → 仿真语义完全不变。只有上板顶层 `cpu_top_board` 传 390。

### 2.4 PDS 工程与固件

| 文件 | 改动 |
|---|---|
| `pds/RV32I_1/RV32I_1.pds` | 加入 `(_ip "ipcore/pll/pll.idf")` + `(_ip_source_item "ipcore/pll/pll.v")`；其余只是 timespec 刷新 |
| `pds/RV32I_1/mem.hex` | **ITER 820 → 1500**（`@126b` = `0x5dc`）|
| 新增 `pds/RV32I_1/ipcore/pll/` | Pango PLL IP：`CLKIN_FREQ=27.00000000`、`CLKOUT0_REQ_FREQ_basicPage=45.00000000` |
| 新增 `pds/RV32I_1/ipcore/unified_mem/` | Pango 双口 BRAM IP（`ipm2l_dpram_v1_9`）—— **未被工程引用，是半成品** |
| 新增 `pds/RV32I_1/mem_init.hex` | 1034 行、**无 `@` 地址**（IP 核格式，与我们 `mem.hex` 的 `@addr` 格式不同）—— 同样是半成品的一部分 |

---

## 3. 队友跑出的综合结果（迁移后要复现）

来源：`<队友目录>/pds/RV32I_1/report_timing/cpu_top_board.rtr`、`multiseed_summary.csv`

```
 clk   45.0005 MHz   可达 51.5198 MHz   周期 22.2220 → 19.4100   slack 2.812
 Design Summary : All Constraints Met.
 Device Map: LUT 3030 / FF 2185 / DRM 16 / APM 11 / DistRAM 132
```

### ★ `.fdc` 没写 45 MHz 约束，但约束是生效的

`.fdc` 与我们**逐字节相同**，仍只有 `create_clock -name {clk} [get_ports {clk}] -period {37.037}`。
PDS **从 PLL IP 自动推导出了输出时钟约束**（时序报告里显示 `45.0005 MHz`）——
所以没问题。但**`.fdc` 里该补一句注释**，否则只看约束文件会误以为还是 27 MHz。

---

## 4. 迁移方案

### 为什么不能直接覆盖

队友那份基于我们 **09-23 20:36** 的状态。直接覆盖会回退掉这两天的成果：
`doc/board_bringup.md`、`scripts/build_bitstream.ps1`、`doc/board/` 证据、
`pds/RV32I_1/bitstreams/`、CLAUDE.md 关键约定 16–23、`bak_2026-09-21_ila/`。

### 步骤

```bash
# 0) 确认工作区干净、当前分支与远端同步
git status && git log --oneline -1

# 1) 建分支
git checkout -b feat/pll-45mhz
```

**要复制的文件（只挑真改动，共 8 个源文件 + PLL IP + 固件）：**

```
rtl/core/core.v
rtl/top/cpu_top.v
rtl/top/cpu_top_board.v
rtl/periph/uart_tx.v
rtl/periph/uart_rx.v
scripts/coremark_port/core_portme.c
scripts/demo/addr_map.h
pds/RV32I_1/RV32I_1.pds          ← 注意：里面还有 timespec churn，逐块看
pds/RV32I_1/mem.hex              ← ITER=1500
pds/RV32I_1/ipcore/pll/          ← 整个目录（含 pll.v / pll.idf / .settings）
```

**不要复制：**

* `doc/**`、`CLAUDE.md`、`README.md`、`scripts/serial_monitor.ps1`、
  `scripts/build_bitstream.ps1`、`pds/RV32I_1/bitstreams/`、`bak_2026-09-21_ila/`
  —— 这些是我们 09-24 的新增，队友那份里没有或更旧
* `pds/RV32I_1/ipcore/unified_mem/` 与 `mem_init.hex` —— **半成品，先原样带上或先不带，
  但绝不要在 `.pds` 里引用**（`ipcore/unified_mem/rev_1/` 里还有一堆构建产物）
* 任何 `compile/ synthesize/ device_map/ place_route/ report_timing/ generate_*/ log*/`
  —— PDS 构建产物

**复制时注意行尾符**：可用 `git add` 后由 `core.autocrlf` 统一，避免整文件 diff 假象。

### LED 调试信号的开关（用户已拍板）

保留 `led[0]=pll_locked` / `led[1]=done`，但加一个能切回演示映射的开关。建议实现：

```verilog
module cpu_top_board #(
    parameter DEBUG_LED = 1     // 1 = led[1:0] 显示 pll_locked/done（调试）
                                // 0 = led[7:0] 全给 GPIO（现场演示）
) ( ... );
    ...
    generate
        if (DEBUG_LED) begin
            assign led[0]   = pll_locked;
            assign led[1]   = done;
            assign led[7:2] = led_gpio[7:2];
        end else begin
            assign led = led_gpio;      // 回到"按开关位置重排"的映射
        end
    endgenerate
```

⚠️ PDS 综合时 parameter 取默认值，所以**要切演示版得重新综合**（或用 `-D` 宏）。
在 `.fdc` 头部与 `doc/board_bringup.md` 里都要写清这一点。

---

## 5. 迁移后必须做的验证

| # | 验证 | 期望 |
|---|---|---|
| 1 | `scripts\run_riscv_tests.ps1` | **49 PASS / 1 FAIL / 0 TIMEOUT**（不变） |
| 2 | `scripts\run_coremark.ps1 -Iter 1` | **Total ticks 358846 / total cycles 1462898**（不变 —— `addr_result` 不应改周期数） |
| 3 | `scripts\run_sim.ps1 -NoWave` | 6 个单测全过 |
| 4 | `scripts\run_own_tests.ps1` | exceptions PASS + timer_irq PASS |
| 5 | PDS 综合 | 复现 `45.0005 MHz` 约束 + `All Constraints Met`，Fmax ≈ 51.5 MHz |
| 6 | 上板 | 烧完看串口：CoreMark `Total ticks` → 除以 **45e6** 应 ≈ 11.96 s；`Correct operation validated` |

> ⚠️ **第 6 项的判据变了**：板上时钟现在是 45 MHz，所以
> `板上时长 = Total ticks ÷ 45,000,000`（不再是 ÷27e6）。
> `core_portme.c` 的 `EE_TICKS_PER_SEC` 已是 45e6，CoreMark 自己算的数是对的；
> 但**我们文档里那些"÷27e6"的说明要同步改**。

---

## 6. 待决 / 半成品

1. ~~**`ipcore/unified_mem` + `mem_init.hex`**：队友做了但没启用（`.pds` 未引用）。
   动向不明 —— **要问队友**是打算替换行为级存储器、还是中途放弃。~~
   ✅ **2026-09-25 已问明**：那是队友**加 IP 核失败**的产物，**可删**。
   迁移时本就**故意没带**，我们仓库里没有这些东西 —— 详见
   `doc/reports/2026-09-25_45mhz_migration.md` §4.2。
   > ⛔ **转述警告**：这里的 `ipcore/unified_mem/` 与我们**自己的**
   > `rtl/mem/unified_mem.v`（统一存储器本体，**承重，绝不能删**）同名但完全无关。
   > 一句"把 unified_mem 删掉"足以毁掉设计 —— **务必带路径**。
   至于"用真 IP 核"的动机：仍是**负收益方向**（单周期 BRAM 无缺失惩罚，
   换 IP 核不提升性能，见 `doc/resource_efficiency.md`）。
2. **`doc/` 里的时钟口径**：一批文档写"27 MHz 固定时钟"。迁移后要区分
   **仿真 27 MHz / 上板 45 MHz**，别一刀切替换。
3. **远程 FPGA 平台回退路径**：`addr_map.h` 的注释提醒"回远程平台需改回 27e6"。
   如果还要在远程平台跑，得有一份 27 MHz 的固件配置（或用 `-D` 宏参数化）。
