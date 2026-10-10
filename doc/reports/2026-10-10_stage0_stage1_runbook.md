# 阶段 0 + 阶段 1 改动与回机验证手册（2026-10-10）

> 对应 v6 交接任务书 §2.2（阶段 0：CoreMark 编译选项）+ §2.1（阶段 1：BTB 取指级重定向）。
> 改动已全部落盘，本手册只讲**回机器上怎么验证**。
>
> **[OK] 2026-10-10 已在有工具链 + PDS 的机器上复核完毕，本文相关数字已按实测更正。**
> 完整复核报告：`2026-10-10_review_stage01.md`。实测结论：
> * 回归：riscv-tests 双/单发射 **49/1/0**、自写测试 **2/0** —— 全过 ✓
> * CoreMark 双发射 **262,018** 拍/迭代（阶段 1 再降 **−7.34%**）→ 得分 **324.4**（较 270.82 **+19.8%**）
> * CoreMark 单发射（-O3 + 阶段 1）**312,428** 拍
> * **PDS 时序（最高风险点）：CPU 域 slack +0.544 ns、Estimated 89.13 MHz、失败端点 0** ✓
> * 位流 md5 **`7b6e5e05`**
> * 隔离性证据：`region commit` / `mem acc` / `cond branches` / `mispredict` **四项逐位不变**，
>   只有 `region cycles` 降 —— 改动是隔离的。
> * [!] **发本包时缺 `a217358`**（+PROF 计时区间修复）—— 在那个树上跑 `+PROF` 会看到
>   `region cycles: 1`。现已合并进主线。

---

## 一、改了什么（两句话）

| 阶段 | 性质 | 改动 | 预期收益 |
|---|---|---|---|
| 阶段 0 | 编译选项（零 RTL 风险） | CoreMark 从 `-O2` 换 `-O3 -funroll-loops -funroll-all-loops -fpeel-loops -falign-functions=4 -falign-loops=4` | 313,886 → **282,777** 拍/迭代，得分 270.82 → **300.6**（+11%） |
| 阶段 1 | RTL（有时序风险） | 分支预测重定向从 ID 级提前到**到达级**（`p_redirect`/`p_target`），消掉每个预测-taken 分支的 1 拍取指气泡 | **实测 −7.34%**：282,777 → **262,018** 拍/迭代 |

阶段 1 的机制：到达级同一拍 `imem_rd` 已给出指令字，当场算 `p_target = if_addr_d + imm`（第三个 `imm_gen` 实例）并立即重定向取指，比旧的 ID 级 `id_redirect` 早 1 拍。正确预测不再产生气泡；EX 级误判恢复（`ex_mispred`）逻辑不变，`if_id_pred_taken` 进位寄存器把"实际生效的重定向"传到 EX 级以区分正确预测/误判。

> 设计取舍：任务书"推荐给 BHT 加 target 字段（真 BTB）"，但也明确写了备选"**用 PC 直接算立即可用的那部分**"——本实现选的是后者：到达级**同时**有 `if_addr_d`（PC）和 `imem_rd`（指令），可直接算 target，不必新增 BTB 数组。关键点是 BHT 用**寄存的 `if_addr_d`** 查询、不是组合的 `fetch_addr`，所以**不会形成任务书担心的组合环**（难点① 已绕开）；难点② 的时序风险仍在（见第 4 步）。

---

## 二、改动文件清单

| 文件 | 阶段 | 关键内容 |
|---|---|---|
| `scripts/run_coremark.ps1` | 0 | 第 41 行 flags 换成 `-O3`+展开/对齐；注释更新 313,886→282,777 |
| `scripts/coremark_port/core_portme.h` | 0 | 第 36 行 `COMPILER_FLAGS` 同步 |
| `scripts/build_bitstream.ps1` | 0 | `Iter=3796`；`cpiCycles` 双发 **262018** / 单发 **312428**；ITER 公式注释 |
| `rtl/core/core.v` | 1 | 删除 ID 级重定向，新增到达级 `p_redirect`/`p_target`/`if_id_pred_taken` |
| `rtl/core/csr_file.v` | 1 | `DESIGN_REV = 32'h2026_1011`（原 2026_1010） |
| `sim/tb_coremark.v` | 1 | `c_redir`/`tc_redir` 从 `id_redirect` 改计数 `p_redirect`；+PROF 标签改 "arrival redirect" |
| `sim/tools/tb_memdbg.v`、`sim/tools/tb_debug_trap.v` | 1 | 同步改名 `p_redirect` |

---

## 三、回机器上怎么跑（按顺序）

### 第 0 步：先冻结一个能演示的 gomoku 位流（阶段 0 的头一件事，别省）

```powershell
scripts\build_bitstream.ps1 gomoku   # 综一个带版本号的 gomoku 位流，上板验一遍
```

归档到 `pds/RV32I_1/bitstreams/`。**手里永远要有一个能回退的完好版本**——后面阶段 1 若时序炸了，退回这个继续演示。

### 第 1 步：RTL 回归（阶段 1 的验收，先跑这条）

```powershell
scripts\run_riscv_tests.ps1          # 双发射，必须 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_riscv_tests.ps1 -Single  # 单发射，必须 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_own_tests.ps1            # 自写测试，必须 2 PASS / 0（exceptions + timer_irq）
```

**唯一允许的 FAIL = `ma_data`**（非对齐访问测试，与分支预测无关，是文档化基线）。
> 注：riscv-tests 两条我在这台机器上已经跑过（预编译 `third_party/riscv-tests-elf/*.elf` + 纯 Python elf2mem），都是 49/1/0。
> `run_own_tests.ps1` 要现场用 riscv gcc 汇编 `sim/tests/*.S`（本机没 gcc，跑不了），这条在机器上跑。

### 第 2 步：CoreMark 新口径（阶段 0）

```powershell
scripts\run_coremark.ps1 -Iter 1          # 双发射：计时区间 = **262,018** 拍（已实测）
scripts\run_coremark.ps1 -Iter 1 -Single  # 单发射：= **312,428** 拍（已实测）
```

判据：
- 双发射 `Total ticks` ÷ 85,005,100 ÷ 迭代数 = **262,018** 拍/迭代。
- 四个稳定 CRC `seedcrc/crclist/crcmatrix/crcstate` = **`e9f5/e714/1fd7/8e3a`** 必须与旧口径逐位一致（只影响代码生成、不影响正确性）。
- ⚠️ **`crcfinal` 不能比** —— 它是跨迭代累加器，随 ITER 变（实测 ITER=1→0xe714、820→0xbd59、1500→0x25b5）。
- ⚠️ ITER=1 打印的 `ERROR! Must execute for at least 10 secs` / `Errors detected` 是**正常现象**，看 Total ticks 和四个 CRC 即可。

**单发射已实测 = 312,428**（旧 -O2 口径是 363,515），`build_bitstream.ps1` 的 `cpiCycles` 已回填。

### 第 3 步：阶段 1 的 CoreMark 提速（必须实测，本机没法跑 riscv gcc）

**阶段 1 实测：282,777 → 262,018 拍（−7.34%）**。用 +PROF 看周期与气泡：

```powershell
cd sim
vvp tb_coremark_dual.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+PROF"
```

看这几行（**直接证据 = `region cycles` 和 `pipeline bubbles` 下降**）：
- `region cycles`：**262,018**（阶段0 是 282,777），降 20,759 拍 —— 正是每条预测-taken 分支省下的那 1 拍。
  > [!] **判据：`region cycles` 必须等于 `Total ticks`。看到 `1` 就是缺 `a217358` 那个修复。**
- `pipeline bubbles`（= 周期 − 提交指令）：应同步下降。
- `CPI` / `region CPI`：应下降。

⚠️ 两个计数**不会降、也不该降**，别当失败信号：
- `arrival redirect`（原 "ID redirect"）：现在计数的是到达级 `p_redirect`，仍是**每条预测-taken 分支一次**（实测 22,637 次/迭代），只是提前了 1 拍——**计数不变才是对的**。
- `region flush`（= `ex_flush`）：误判/jump/trap 的 EX 级冲刷，阶段 1 不改变误判率（~1,543 次/迭代），所以它基本不变。

**[OK] 已回填**：`cpiCycles` 双发 = 262018；ITER 已重算为 **3796**（见下）。

### 第 4 步：综合 + 时序（阶段 1 的**唯一关键风险**）

```powershell
scripts\sync_firmware.ps1            # 先同步 mem.hex，防烧旧镜像
scripts\build_bitstream.ps1 coremark # 出位流（默认 ITER=3796）
```

**必须先看 PDS 的 `report_timing`**。基线（双发射 85.0051 MHz）当前 CPU 域 setup slack 只有 **+0.525 ns**（实测 88.98 MHz，余量 4.5%，任务书 §5），而阶段 1 在取指关键路径上新增了一个 32 位加法器 `p_target = if_addr_d + p_imm`，其中 `p_imm` 由**晚到的 BRAM 输出 `imem_rd`** 译出 —— 很可能吃掉这 0.525 ns 变成负 slack。同一份 RTL 不同 seed 能差 5%，别拿旧报告的 Estimated 当上限。

- ✅ slack 仍为正 → 收工，上板。
- ❌ slack 变负 → 二选一：
  - **降频**：改 PLL 分频比（历史上 85.01 → 91.87 是硬极限，取 85 留 7% 余量；阶段 1 后上限可能回落到 ~80，需实测）。
  - **回退阶段 1**：`git checkout rtl/core/core.v` 只保留阶段 0（+11% 零时序风险），并把 `DESIGN_REV` 一并回退。

### 第 5 步：上板 + 故意弄坏

```powershell
scripts\build_bitstream.ps1 coremark   # 默认双发射 ITER=3796（约 11.70s）
```

上板判据：
- 串口第一行读 `mimpid`（csrr 0xF13）= **`0x2026_1011`**，自证烧的是新版位流（不是旧版装同样固件）。
- 四个稳定 CRC `e9f5/e714/1fd7/8e3a` 逐位一致。
- `Iterations ÷ (Total ticks ÷ 85,005,100)` = 每秒迭代数 = 新 CoreMark 分。
- 复位用 **SW3**（别按 SW2/D22，那是 FPGA 配置键；判据：按完两个 PLL 灯还亮不亮）。

**"故意弄坏必须 FAIL"纪律（别跳过）**：改一行 RTL 故意引入 bug → 重综合 → 确认回归/CRC 判定 FAIL → 再改回来。这验证的是"判定机制真的在拦你"，不是走形式。

---

## 四、关键数字速查

| 项 | 旧（-O2 / 阶段1前） | 新（-O3 / 阶段1后） |
|---|---|---|
| 双发射 CoreMark 拍/迭代 | 313,886 | **262,018**（-O3 + 阶段1，实测）|
| 单发射 CoreMark 拍/迭代 | 363,515（-O2） | **312,428**（-O3 + 阶段1，实测）|
| CoreMark 得分（双发 @85.0051MHz） | 270.82 | **324.4**（阶段0+1）|
| 上板 ITER | 3170 | **3796**（=85,005,100×10÷262,018×1.17）|
| DESIGN_REV | 0x2026_1010 | **0x2026_1011** |
| beq.elf 仿真时间（阶段1 生效证明） | 3,436 ns | **3,276 ns（省 160 ns = 16 拍 @10ns）** |
| 双发 setup slack | +0.525 ns（88.98 MHz） | **+0.544 ns（89.13 MHz）**，失败端点 0 —— 风险点通过 |

---

## 五、别踩的坑（照抄既有铁律）

1. **改 RTL 必跑四条基线**，数字逐位不变：双发 49/1/0 + CoreMark ／ 单发 49/1/0 + CoreMark；外加自写测试 2/0。
2. **改 RTL 后、综合前，`DESIGN_REV` 必须 +1**（当前已 0x2026_1011；再改 RTL 改 0x2026_1012）。
3. **改了固件，`build_bitstream.ps1` 的行数守卫会拦** —— 实测后更新 `expectLines`，别放宽它。
4. **`crcfinal` 随 ITER 变**，只能比 `seedcrc/crclist/crcmatrix/crcstate` 四个。
5. **别按 SW2/D22**（FPGA 配置键），真复位是 **SW3**。
6. 变短/换行的字符串要整行重写（`render_text` 已改成整行写）。
7. PDS 不校验 `mem.hex` 时间戳 —— 综合前必须 `sync_firmware.ps1`。
