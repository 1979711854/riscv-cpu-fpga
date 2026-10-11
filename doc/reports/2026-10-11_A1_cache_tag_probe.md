# A.1 · 假 tag 路径综合量时序（2026-10-11）

> 任务书 v7 §5.A.1。**结论先说：85 MHz 下，光"一次 tag 比较 + 一级 way mux"就吃掉
> 4.6% 余量里的 86%（+0.525 → +0.073 ns）。完整 2 路组相联 Cache 只会更差 —— 直接上
> 会把 CPU 域时序做成负的。**

---

## 1. 目的

真做 I/D Cache 时，`set 索引 → 读两路 tag → 与地址 tag 比较 → way 选择 → 数据 mux`
这一段会压到访存关键路径上，而当前 CPU 域余量只有 **+0.544 ns / 11.764 ns = 4.6%**
（v7 §3.2）。先插一条**结构等价**的假路径综合一次，量出它到底吃掉多少余量，再决定
要不要写完整 Cache。**用一次综合（约 4 分钟）换掉几周的错误投入。**

## 2. 做法（关键：探针必须"非冗余"，否则量不到东西）

一条"恒命中"的假逻辑是**冗余**的，综合器会整个消掉 → 时序报告纹丝不动 →
得到假的"无影响"结论。所以 tag 和数据都**借真实存储端口**（对综合器未知），
比较结果确实未知、mux 选择确实有效 ⇒ 逻辑一定保留：

```
p_addr_tag = mem_addr[31:12]      // 地址 tag（20 位）
p_tag0     = ram_rdata[31:12]     // "way0 存的 tag"（借数据 BRAM 读数据）
p_tag1     = imem_rd2[31:12]      // "way1 存的 tag"（借第二取指口）
p_hit0/hit1 = (p_tag0/tag1 == p_addr_tag)
p_d0 = ram_rdata, p_d1 = imem_rd, p_fill = vid_rdata    // 三个真实数据源
p_way_data = p_hit0 ? p_d0 : p_d1                        // way mux
p_rdata    = (p_hit0|p_hit1) ? p_way_data : p_fill       // 命中/回填 mux
mem_rdata  = ... : (CACHE_TAG_PROBE ? p_rdata : ram_rdata)
```

- 代码：`rtl/bus/mem_bus.v`（参数 `CACHE_TAG_PROBE` + 上述逻辑）、
  `rtl/top/cpu_top.v`（同名参数并透传）。**默认关**（`=0`）：
  三目被常量折叠成 `ram_rdata` 直通 ⇒ **逐位不变**。
- 切换方式同 `DUAL_ISSUE`：PDS 命令行传不了 `-D` 宏，改 `cpu_top.v` 的 parameter 默认值。
- **探针版仅用于综合量时序**，不上板、不跑分（`CACHE_TAG_PROBE=1` 时访存读数据不再等于
  `ram_rdata`，功能不正确 —— 这正是"非冗余"的代价，换来的是综合器删不掉）。

## 3. 复现

```powershell
cd pds\RV32I_1
# 基线（探针关，默认值）
D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe -project RV32I_1.pds -run pnr
# 读 place_route\seed_<best>\cpu_top_board.rtr 的 Performance Summary：
#   CPU 域 = clk|u_pll/u_gpll/CLKOUT0_Inferred 那一行
# 探针开：把 rtl\top\cpu_top.v 的 `parameter CACHE_TAG_PROBE = 0` 改成 1，重跑，再改回 0
```

> [!] `-run pnr` 跑到 P&R 为止（含嵌套的 post-PnR STA），**不**生成比特流。
> 该 STA 报告落在 `place_route/seed_<best>/cpu_top_board.rtr`，不是 `report_timing/`。

## 4. 原始结果（各 8-seed 多 seed，三次 best seed 都是 3）

| 配置 | LUT | FF | DRM | **CPU 域 slack** | Est 频率 | CPU 域失败端点 |
|---|---|---|---|---|---|---|
| 探针关（第 1 次） | 6986 | 3489 | 85.5 | **+0.525 ns** | 88.9759 MHz | 0 |
| 探针关（第 2 次·复核）| 6986 | 3489 | 85.5 | **+0.525 ns** | 88.9759 MHz | 0 |
| 探针开 | **7239** | 3489 | 85.5 | **+0.073 ns** | 85.5359 MHz | 0 |

- **基线两次逐位一致**（+0.525 / LUT 6986）⇒ 工具可复现，下降**不是噪声**
  （本机 8-seed 多 seed，seed 集合固定）。
- 探针 = **+253 LUT、0 FF**（纯组合）⇒ 逻辑确实进了网表，没被综合掉。
- **Δ = −0.452 ns**（= 原余量 0.525 的 **86%**）；Est 频率 −3.44 MHz。

> 报告顶部 `Design Summary : Some Constraints Violated` 的失败端点**全在视频跨域**
> （`clk_sys↔pix_clk`），与 CPU 无关 —— 见 `doc/resource_efficiency.md` §"整体报 Violated
> 但 22 条全在跨域"。**CPU 域自身失败端点 0**，但余量只剩 0.6%。

## 5. 关键路径证据

探针开之后，CPU 域最差两条几乎**并列第一**：

```
+0.073 ns  乘法器 u_multiplier/N15_m1/gopapm/CLK → mem_wb_alu_result[31]   （12 级）← 老关键路径
+0.084 ns  u_bus/u_mem BRAM → p_d0 → tag 比较 N99.eq_9 → mem_rdata mux
           → core(_N4365/load_half/rs1_val_amo) → imem_addr2 → BRAM 地址   （14 级）← 探针自己的路径
```

- 探针路径逻辑 4.208 ns / 布线 7.175 ns（63% 布线），**14 级**，含 `p_d0`、比较器
  `N99.eq_9`、mux `mem_rdata_10` —— 即**光一次 tag 比较 + 一级 way mux 就做到了与乘法器
  路径并列的关键程度**。
- 乘法器路径（探针未触碰）也从 +0.525 掉到 +0.073：加 253 LUT 后 placer 全局重排，
  老路径布线变差 —— 即**代价不只是探针自身的逻辑深度，还有面积带来的全局扰动**。
  两条合计，CPU 域 worst 从 +0.525 落到 +0.073。

## 6. 结论与建议

**判据**（v7 §5.A.1）：slack 仍为正 → 可放心写完整 Cache；变负 → 改直接映射或降频。
实测落在**边缘**：仍为正（+0.073，MET），但只剩 **0.6%**。

完整 2 路组相联 Cache 还要在探针之上再加：**index 译码、两路 tag/数据存储、缺失判定 +
回填 mux（再多一级 mux）、以及大得多的面积** —— ⇒ 只会比探针更差。

**结论：85 MHz 下直接上完整 2 路 Cache，几乎必然把 CPU 域做成负 slack。**

三条出路（供 A.2 选）：
1. **直接映射**：省掉 way mux（约一级 mux）。但探针表明"单次比较 + 一级 mux"已吃 0.45 ns，
   直接映射估计仍吃 ~0.3 ns，余量仍很薄。
2. **Cache 开时降频**（如 75~80 MHz）：要同步改 `CLAUDE.md` 约定 27 的 4 处常量 + ITER +
   `expectLines`；且 §2 已证改频有坑。
3. **默认关 + 只做功能演示/答辩**（A.2/A.3 本来的口径）：Cache 作为可编译开关实现，
   **跑分永远用关配置报 324.5**；若要在板上演示"带 Cache"，用降频位流。

## 7. 勘误 / 局限（如实记录）

- 探针的 "way1 tag/数据" 借的是**取指口** `imem_rd2`/`imem_rd`（数据侧只有一块
  unified_mem，拿不到第二个数据 BRAM）。真实 Cache 的 way1 会读同一组数据 BRAM
  （按同一 index），深度与 way0 相当 —— 所以本探针的**比较 + mux 深度是代表值**，
  但引入了一些真实 Cache 不会有的取指口耦合路径。**0.45 ns 应看作偏保守的上界。**
- 本探针量的是"访存读通路 + 回填 mux"这一段的增量；真实 Cache 的**缺失路径**（多一拍
  BRAM 读 tag + 回填）在跨拍逻辑上、不在单拍关键路径里，这里没有建模。
