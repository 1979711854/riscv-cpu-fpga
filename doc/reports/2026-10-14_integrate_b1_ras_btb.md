# 集成报告：并入队友 B1-RAS/BTB 交接包 + 重出跑分位流（2026-10-14 晚）

> 交接包：`riscv-cpu-fpga_dualissue_20261014_cpu (2).zip`（队友 2026-10-14 21:06 发，桌面
> `RV32I\交接文件\`，32.9 MB，含 `.git`）。**本报告 = 集成方视角**（合并、Review、回归、综合）；
> 队友侧的完整开发记录在 `doc/reports/2026-10-14_session_state.md` §8/§9 与
> `doc/reports/2026-10-14_taskbook_v11_cpu.md`。
> 合并提交：`a4e7ceb merge(cpu): 并入队友 B1-RAS/BTB 交接包（rev1020-1022）`。

---

## 1. 包里有什么（相对我方 HEAD `35e62aa`，共同基点 `5b16140`）

| 提交 | 内容 |
|---|---|
| `3eefdf1` | fix：AMO 后紧跟分支用陈旧前递值解析方向并提交错误路径（`ex_flush`/`ex_mispred` **源**补 `mem_ready_int`，约定 56/57 同族第三条；`tb_amo_cpu` testnum 9 实测） |
| `23ff4b3` | feat：**B1-RAS** 返回地址栈（ret 到达级预测 + §7 预测目标校验） |
| `51fa969` | feat：**B1-BTB** 256 项直接映射（只预测间接 `jalr`，RAS>BTB>PC+imm；§7 放宽到所有被预测 jalr） |
| `77d93d6` | docs：session_state §9.8 + 任务书 v11 + 新测试 `btb_indirect.S` / `hi_fetch.S` / `tb_amo_cpu` 转 tohost |

RTL 改动只在 `rtl/core/core.v`（+170 行）与 `rtl/core/csr_file.v`（`DESIGN_REV 0x2026_1019 → 0x2026_1022`）。
我方侧同期是 T2/T3 五子棋合并 + 文档口径扫除 ⇒ **真 merge，非 fast-forward**。

## 2. 冲突解决（仅 2 处，均为文档）

- `CLAUDE.md`：取我方 A1 后现口径（I+D 325.96）+ 保留队友 B1 横幅。
- `doc/paper/论文框架_v1_20261012.md` §0：得分行取我方 A1 后口径，执行效率行取队友 B1-RAS 新值（4.355 / 229,597）。
- `run_riscv_tests.ps1` / `tb_coremark.v` 自动合并正确（我方注释更新 + 队友 BTB 插桩 `-DNOBTB` 开关/计数器都在）。
- **`rtl/core/core.v` / `csr_file.v` 合并后与队友版逐字节一致**（`git diff stage1014/dualissue` 空）。

## 3. RTL Review 结论（承重逻辑，逐条过）

- RAS/BTB 更新全部门控 `mem_ready_int && !mc_stall && !trap`（与"离开 EX"同拍）—— 约定 56/57 同族纪律遵守；
- 目标校验（§7）只比 `rs1_val&~1`，**不进 `ex_target` 加法器**（避开 fetch 关键路径）；`imm≠0` 的罕见 `jalr` 一律判错冲刷（代价 = 不预测，不会更差）；
- BTB 目标只折进**已有 `p_target` 腿**，不新增 `fetch_addr` 腿（Fmax 第一风险点）；
- `id_ex_pred_target` / `if_id_pred_target` 在所有清零路径补了清零；
- `p_pred_taken` 的 RAS/BTB 档让 `pair_now=0`（jalr 独占发射，与原"不被预测、不配对"一致）。

## 4. ITER 重算（约定 3，动流水线必须重算）

- B1-RAS 后双发射 + `EARLY_LD`：**232,345 → 229,597 拍/迭代**（−1.18%）。
- `ITER = 85,005,100 × 10 ÷ 229,597 = 3,702`（恰好 10s）⇒ 按 17% 余量政策取 **4332**
  （`4332 × 229,597 = 994,614,204` ticks = **11.7004 s**，预期 **≈370.2 分**）。
- `build_bitstream.ps1` 默认 `Iter` 4280 → **4332**，`$cpiCycles` 232345 → **229597**，注释同步；
  `EE_TICKS_PER_SEC` 不变（时钟没动）⇒ `expectLines['coremark']=17104` 守卫不受影响（实测通过）。

## 5. 回归（集成方在合并后的仓库复跑，rev1022）

| 回归 | 命令 | 结果 |
|---|---|---|
| riscv-tests 默认 | `run_riscv_tests.ps1` | **49 PASS / 1 FAIL(ma_data) / 0 TIMEOUT**，`BTB_EN=1` 自证 |
| riscv-tests Cache corner | `run_riscv_tests.ps1 -DCache -ICache -EarlyLd` | **49 / 1 / 0** |
| 自写测试 | `run_own_tests.ps1` | **5 / 5 PASS**（`btb_indirect`/`hi_fetch`/`tb_amo_cpu`/`exceptions`/`timer_irq`） |
| CoreMark | `run_coremark.ps1 -Iter 1 -EarlyLd` | `Total ticks = 229,597`、四 CRC `e9f5/e714/1fd7/8e3a` 全对、`RTL=0x20261022` |
| RT-Thread ×Cache corner | `rtthread\run_sim.ps1 -DCache -ICache` | **PASS**（三条自检全 OK） |

> RT-Thread 其余三配置（无 Cache / 只 D / 只 I）队友已在同一 RTL 上跑过（session_state §4/§8/§9），
> I+D 是停顿最多的超集，集成方复跑最难的这一条。

### 5.1 过程中抓到的一个坑（与 RTL 无关，已加守卫）

首次跑 `run_sim.ps1 -NoBuild -DCache -ICache` 报 `[FAIL] 没看到主线程心跳`。逐层排查后定位：
`scripts/rtthread/build/` 里的 hex 是 **17:21 板级集成时的板载口径固件**（`BOARD_SYSTEM_CLOCK_HZ=76.5052MHz`、
`HB_DELAY_MS=5000`），`-NoBuild` 拿它跑 100MHz 仿真 ⇒ 心跳要 3.8 秒 wall time 才出现，30ms 扫描窗永远等不到。
**与 B1 RTL 无关**（换 `-Sim` 全新构建后同配置 PASS）。这是 `mem.hex` 时间戳坑的**同族新变种**
（板级构建覆盖仿真固件），已加守卫：

- `build.ps1`：`-Sim` 构建写 `build/.sim_build_ok` 标记，板载构建删它；
- `run_sim.ps1`：`-NoBuild` 见到没标记直接 throw，不让错口径固件静默跑完判 FAIL。

## 6. 上板综合（`build_bitstream.ps1 coremark`，2026-10-14 23:04 完成）

| 项 | 值 |
|---|---|
| 位流 | `pds/RV32I_1/bitstreams/coremark_dual_aext_ms_earlyld_a1_ras_btb_85mhz_rev1022_f64b977.sbit`（md5 **`f64b977`**，9.76 MB） |
| 配置 | 双发射 + `EARLY_LD` + RAS + BTB，**Cache 全关**，85.0051 MHz（`RATIO0=13.5`/`UART_DIV=738`），ITER=**4332** |
| mem.hex 守卫 | 17104 行 / 8552 字 ✓，SHA256 逐字节一致 ✓ |
| **时序（CPU 域 `u_pll→u_pll`）** | **+0.034 ns / 0 失败端点（20,507）**，请求 85.0051 → 实测 **85.2515 MHz** —— 与队友预判逐位一致，**过红线（很薄）** |
| 全设计 | `Some Constraints Violated` = 21 条 `u_pll→video` + 1 条 `video→u_pll` **跨域建模假象**（历届 85 MHz 生产档同款，CPU 域 0 失败） |
| 网表自证 | `dcache`/`icache`/`tag0` = **0** ✓；`btb_tag` 145 / `btb_target` 124 / `ras_mem` 16 在网表中 ✓ |
| 资源 | **LUT 8,104 / 5.07%**（rev1017 的 7,482 **+622** = RAS+BTB 代价）、FF 3,899、DRM 101.5、APM 4 |
| 预期板上 | `Total ticks ≈ 994,614,204` → **11.7004 s** → **≈370.2 分**（**未烧板，不得引用**） |

## 7. 下一步（上板验证判据）

1. Programmer 选 PG2L200H，`Assign New Configuration File` 指到上面这颗（别用备份/旧文件）；
2. 烧完立刻抓串口（一轮约 12 s）：`scripts\serial_monitor.ps1 -Port COM4 -Seconds 60`；
3. 判据：首行 **`RTL=0x20261022`**、`Total ticks ≈ 994,614,204`、四个 CRC 与仿真逐位一致、
   `Correct operation validated`；led[0]=pll_locked 常亮；
4. 过了 ⇒ 交付档从 `bcd8fdd2`（365.93）换 `f64b977`（≈370.2），CLAUDE.md / 论文框架 §0/§0.1 同步换数；
   若时序/功能异常 ⇒ 按任务书 v11 §0.6 后备：BTB 缩 64 项 → 再不行 `BTB_EN` 默认 0（`-DNOBTB` 可复现）。
