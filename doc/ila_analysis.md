# ILA 波形分析与流水线效率报告

> 对应赛题《FPGA 创新设计赛道选题指南（紫光同创）》选题一「性能测评标准 · 3. 技术实现与文档 (2)」：
> 「需提交详细的性能分析文档。利用 ILA 抓取的波形图，分析 CPU 在执行 CoreMark 关键算法时的流水线效率。」
> 编制日期：2026-09-21

## 0. 先说清楚数据来源边界

这份文档分三块，**状态不同，不要混淆**：

| 部分 | 内容 | 状态 | 证据形态 |
|---|---|---|---|
| **A** | 流水线效率量化分析（停顿/冲刷/前递占比、CPI） | **已完成** | 仿真逐拍观测，全量统计 |
| **B** | 流水线时序波形图（2 张） | **已完成** | `doc/figures/pipeline_*.svg`，仿真时序图 |
| **C** | 硬件在环 ILA 抓取 | **待执行** | 平台提供 JTAG 通道与波形界面，但探针描述文件 `.fic` 须在本地 PDS 用 **Fabric Inserter** 生成；步骤见 §7 |

**为什么可以先做 A/B**：ILA 抓的是「有限深度的窗口 + 真实硬件凭证」，而效率分析
需要的是「全量、可复现的统计」。两者信号同名、定义同源（都取自 `rtl/core/core.v`
的同一批内部信号），因此仿真结论与 ILA 波形可以互相印证 —— 仿真给结论，ILA 给凭证。

**B 部分的图是仿真时序图，不是 ILA 截图**，报告中引用时必须如实标注。
真正的 ILA 截图请在 §7 流程跑完后替换或补充。

---

## 1. 分析口径：CoreMark 计时区间

CoreMark 的 `start_time()` / `stop_time()` 各是一次读 MMIO `0x7FF4`
（`scripts/coremark_port/core_portme.c` 里的 `barebones_clock`）。该读操作在
CPU 访存口上表现为 `mem_re && mem_addr == 0x7FF4`，可直接观测，因此能**精确框出
计时区间**，把「纯 CoreMark 算法」与「UART 打印轮询」区分开。

```
start_time cycle : 21,533
stop_time  cycle : 441,603
计时区间长度     : 420,070 拍   ← 与 CoreMark 自报 Total ticks 逐位一致
```

> 口径提醒：整场仿真总周期是 1,529,499 拍，其中约 109 万拍是一次性 UART 打印
> 轮询开销（打印区间 CPI 高达 2.33，纯属轮询循环，不能混进算法效率统计）。
> **效率分析必须只用 420,070 拍这个区间**。

---

## 2. 流水线效率实测结果

### 2.1 总体

| 指标 | 数值 |
|---|---|
| 计时区间周期数 | **420,070** |
| 提交指令数 | **288,056** |
| **CPI** | **1.4583** |
| 流水线效率（理想 CPI=1） | 68.6% |

提交指令数的测法：在测试台里搭一条**影子流水线**，逐级镜像 `core.v` 中
`IF/ID`、`ID/EX`、`EX/MEM`、`MEM/WB` 四个级间寄存器的清零/暂停条件，
从而数出真正流过 WB 的指令条数。不能直接用 `mem_wb_reg_write` 计数 ——
store / branch / jump 不回写寄存器，会被漏掉。

### 2.2 效率损失分解

| 损失来源 | 发生次数 | 每次代价 | 损失周期 | 占计时区间 |
|---|---|---|---|---|
| **分支/跳转冲刷** | 37,098 | **3 拍** | **111,294** | **26.49%** |
| load-use 停顿 | 20,720 | 1 拍 | 20,720 | 4.93% |
| 除法停顿（多拍除法器） | 0 | — | 0 | 0.00% |
| **合计** | | | **132,014** | **31.43%** |

自洽性校验：`288,056（有效）+ 132,014（损失）= 420,070` ✓

**结论：控制冒险（分支冲刷）是压倒性的第一瓶颈，单项占掉 26.5% 的周期，
是 load-use 停顿的 5.4 倍。**

### 2.3 前递的贡献（正向数据）

| 事件 | 次数 |
|---|---|
| 从 EX/MEM 前递 | 56,540 |
| 从 MEM/WB 前递 | 83,845 |
| 合计前递 | 140,385 |

前递没有直接"节省"周期，但它把大量 RAW 相关在 1 拍内解决掉了。
反证：如果把这些相关全部退化成停顿，按 140,385 次、每次至少 1 拍估算，
将额外增加约 14 万拍 —— 相当于计时区间的 33%。**前递是当前效率的主要贡献者。**

### 2.4 分支事件构成

| 类型 | 次数 |
|---|---|
| 条件分支（taken，6 种 B 型） | 37,098 中占绝大多数，全区间 184,530 / 193,698 |
| 无条件跳转（jal/jalr） | 全区间 9,168 |
| 全区间冲刷事件合计 | 193,698 |

---

## 3. 关键算法波形一：`matrix_test` 内层循环

CoreMark 的矩阵测试内层循环，反汇编（`riscv-none-elf-objdump -d`）：

```
16c8:  add    a6,a0,a4        ; a6 = a0 + a4
16cc:  slli   a0,a6,0x10
16d0:  addi   a1,a1,1
16d4:  srai   a0,a0,0x10
16d8:  addi   a2,a2,4
16dc:  bgeu   a1,s0,1710      ; 循环上界判断（不跳）
16e0:  mv     a4,a5
16e4:  lw     a5,0(a2)        ; 访存
16e8:  addi   a6,a0,10
16ec:  add    a3,a3,a5
16f0:  slt    a4,a4,a5
16f4:  bge    s1,a3,16c8      ; ← 回跳分支，几乎必然跳转
```

实测：**12 条指令 / 15 拍 → 本循环 CPI 1.25**，其中 **3 拍全部耗在
`0x16f4` 的回跳分支冲刷上**。

![matrix_test 内层循环流水线时序](../figures/pipeline_matrix_loop.svg)

**读图要点**（信号名与 §7 的 ILA 探针一一对应）：

- 上半部分是五级流水占用格，格内为 PC 低 4 位，虚线空格是气泡
- 浅红色整列 = 分支冲刷周期；浅黄色整列 = load-use 停顿周期
- 每 15 拍重复一次：`IF` 取到 `0x1700` 后直接跳到 `0x16c8`，
  `ID`/`EX` 两行各出现 2 个气泡
- 该循环内 `load-use 停顿` 一栏全程为低 —— `lw a5,0(a2)` 与后续使用之间的
  距离由前递消化，不需要停顿。**这是前递生效的直接证据**
- `前递 EX/MEM`、`前递 MEM/WB` 两栏在这个循环里频繁拉高

---

## 4. 关键算法波形二：停顿与冲刷叠加

另一个热点循环（`0x0dac`–`0x0dc0`），**停顿与冲刷同时出现**：

实测：**5 条指令 / 11 拍 → CPI 2.2**，其中 3 拍分支冲刷 + 3 拍 load-use 停顿。

![停顿与冲刷叠加的流水线时序](../figures/pipeline_hazard_mix.svg)

**读图要点**：

- 第 390006 拍 `分支/跳转冲刷` 拉高 → 该拍 `EX` 中是 `0x0dbc` 的 taken 分支
- 下一拍（390007）`冲刷第 2 拍` 拉高，`ID`/`EX` 两行同时变成虚线空格
- 连续 3 拍没有任何一格填满 —— 这就是 3 拍惩罚的可视化
- 第 390002、390004、390010 拍 `load-use 停顿` 拉高，对应拍 `EX` 行为气泡
  （停顿期间 `IF`/`ID` 保持不动，重读同一 word，见 `core.v` PC 段注释）

---

## 5. 重要发现：分支惩罚是 **3 拍**，不是此前文档写的 2 拍

`doc/spec.md`、`doc/base_task_status.md` 及既往记录均写「分支惩罚固定 2 拍
（`ex_flush` + `ex_flush_d` 双拍冲刷）」。**本次逐拍实测证明实际吞吐损失是 3 拍。**

### 证据一：逐拍提交缺口

在 §4 那个窗口里，`影子流水线` 的 WB 有效位序列：

```
cyc 390006: v_wb=1   ← 分支指令自身提交
cyc 390007: v_wb=0   ┐
cyc 390008: v_wb=1   │ 中间 3 拍无提交
cyc 390009: v_wb=0   │
cyc 390010: v_wb=0   │
cyc 390011: v_wb=0   ┘
cyc 390012: v_wb=1   ← 目标路径第一条指令提交
```

### 证据二：全量数字自洽

全区间：`1,529,499（总周期）- 771,498（提交）= 758,001（气泡）`
而 `3 × 193,698（冲刷）+ 174,890（停顿）+ 2,013（除法）= 757,997`
两者相差 4 拍（复位启动的边角），**完全闭合**。若按 2 拍计算，
缺口会差出 19 万拍，无法闭合。

### 根因

本设计取指使用**同步读 BRAM**（1 拍延迟），并靠 `if_addr_d` 做取指补偿。
分支在 EX 解析时，取指端已经多推进了一拍，所以：

- 拍 T：`ex_flush` 置位，`pc_r ← 目标`，`IF/ID` 与 `ID/EX` 清零
- 拍 T+1：`ex_flush_d` 置位，`IF/ID` 再次清零（补偿同步读延迟），
  `if_addr_d` 记录目标地址
- 拍 T+2：`IF/ID` 才锁存到目标指令（此时 `imem_rd` 才是目标地址的数据）

即：**冲刷确实是 2 拍，但第 3 拍仍在"等取指数据回来"**，合计 3 拍空缺。

### 影响与处理

1. **文档需更正**：把「分支惩罚 2 拍」改为「分支冲刷 2 拍，实际吞吐损失 3 拍」。
2. **这反而强化了优化叙事**：分支惩罚越大，加分支预测的收益越显著（见 §6）。
3. 这是「同步读存储器 + 异步取指」结构的固有代价，不是实现 bug。

---

## 6. 优化建议（按收益排序）

| 优先级 | 措施 | 预期收益 | 代价 |
|---|---|---|---|
| **P0** | **加分支预测（BHT / BTB）** | 最直接的场景是 `matrix_test` 这类**后向循环分支**（几乎必然跳转）。2 位饱和计数器或「后向分支预测跳转」的静态规则即可命中绝大多数。若冲刷命中率降到 10%，可省下约 **10 万拍 ≈ 24%** | LUT 余量 98%，资源不是约束；属承重改动，必须完整回归 |
| P1 | load-use 停顿消除 | 若能靠增加前递路径/编译器调度消化，可省约 2 万拍（4.9%） | 改动风险较高，收益中等 |
| P2 | 缩短分支解析到 ID 级 | 可省 1 拍惩罚 | 需额外比较器与前递，时序压力上升 |
| P3 | 提升 Fmax 至 46.4 MHz | 得分按频率线性提升（64.3 → 110.5 CoreMark） | 不消耗逻辑资源，但受平台固定 27 MHz 时钟限制，只能在本地板验证 |

**理论天花板**：若两类损失全部消除，`10^6 / 288,056 = 3.472 CoreMark/MHz`
（当前 2.380）。这是报告里可以做「优化闭环」叙事的抓手。

---

## 7. 硬件在环 ILA 抓取方案（待执行）

### 7.0 结论：平台出 JTAG 和波形界面，PDS 出 `.fic` 和比特流

**查证结果（2026-09-21，实读远程平台前端 + 本机 PDS 安装目录）**

`http://www.logicmatrixsemi.com:5174/` 是「FPGA LAB 远程 FPGA 实验平台」，
开发者工作区侧边栏包含：

```
设备管理 · 固件烧录 · 工作区 · 示波器 · 信号发生器 ·
逻辑分析仪 · 串口通信 · 摄像头 · 数字孪生 · ILA
```

即 **平台自带一个名为 "ILA" 的模块**。它的面板有一条按钮叫
**「导入fic文件」**（Xilinx 板子则显示「导入LTX文件」，文件过滤器是 `.ltx`）。
抓取时调用的接口是 `POST /modules/debugger/jtag-ila/config`，参数含
`deviceId / ilaChannelCount / sampleDepth / triggerConditions / mode / ilaIndex / coreName`。

**所以分工是这样的**：

| 环节 | 谁负责 |
|---|---|
| 把 debug 核插进设计、生成**探针描述文件 `.fic`** | **本地 PDS（Fabric Inserter）** |
| 生成含 debug 核的比特流 `.sbit` | **本地 PDS** |
| 烧写比特流 | 平台「固件烧录」（也支持本地上传 `.sbit`） |
| **JTAG 在环抓取 + 波形显示** | **平台 ILA 模块** |

也就是说：**不需要**在自己电脑上把 PDS Debugger 连到板子（本地也没有那条 JTAG 通路），
但**仍然需要本地 PDS 走一遍 Fabric Inserter**，因为 `.fic` 只有 PDS 能生成。
平台负责的是 JTAG 通道和波形界面这两件本地做不到的事。

> 一句话：**平台要你上传的那个 `.fic`，是你自己在 PDS 里做出来的。**

`.fic` 的真实身份（读 PDS 自带例程 `example/PG2L100H_adc_test/pnr/adc_ctrl_demo_syn.fic` 确认）：

```
#Fabric Core Inserter Project File
#Generated by Fabric Inserter (version 2020.3-rc3 build 62368) at ...
Project.device.designInputFile=.../pnr/synthesize/adc_ctrl_demo_syn.adf
Project.device.deviceFamily=Logos2
Project.device.deviceModel=PG2L100H
Project.device.devicePackage=FBG676
Project.unit<0>.clockChannel=nt_clk
Project.unit<0>.dataDepth=1024
Project.unit<0>.triggerChannel<0><1>=pdata[0]
Project.unit<0>.triggerChannel<0><2>=pdata[1]
...
```

即 **Fabric Inserter 工程文件**，核心内容是**「第 N 号采集通道 ↔ 设计里的哪个信号」的映射表**，
外加器件型号、采样时钟、采样深度。平台的波形软件就是靠它把 JTAG 读回的裸比特流
翻译成有名有姓的波形 —— **没有它，抓回来的数据没法解读**。

**要注意的一点**：平台有一句提示文案「当前设备配置未启用该仪器」——
说明**仪器是按设备逐个配置启用的**。你预约到的那台设备可能开了逻辑分析仪但没开 ILA。
申请设备前先确认，或直接找赛方技术支持问（QQ 群见赛题指南第五节）。

### 7.1 ILA 探针清单与位宽预算

**先看硬限制**。DebugCore IP 的官方能力说明（`ip/system_ip/ips_debug_core/.../info.html`）写着：

- 数据缓存深度 **64 ~ 128k**（2 的整数幂）
- 数据缓存位宽 **1 ~ 4096**
- **Trig Match Unit 信号位宽 1 ~ 256** ← 触发比较单元的位宽上限
- Trigger Port 个数 1~16，Trig Match Unit 总数不超过 16

对应到 RTL 就是 `ips_dbc_compare_256b_v1_0.v`。平台的校验规则
`maxTotalChannelBits: 256`、`maxSignalsPerIla: 32`、`maxIlaCores: 16` 与之吻合。

**结论：256 位是触发比较单元的位宽上限**（采集缓存本身可以更宽，到 4096），
而平台又把它作为总通道位宽的硬性校验，所以实际按 **不超过 256** 来做。

所以探针要**精打细算**。下表按「能讲清流水线故事」裁剪，并给出位宽预算与通道分配：

| 通道位 | 信号 | 位宽 | 取法 / 说明 |
|---|---|---|---|
| `[14:0]` | `pc` / `pc_r[14:0]` | 15 | 取指 PC（`pc` 已是顶层端口；内存 32KB，PC < 0x8000） |
| `[29:15]` | `if_id_pc[14:0]` | 15 | ID 级 PC |
| `[44:30]` | `id_ex_pc[14:0]` | 15 | EX 级 PC |
| `[59:45]` | `ex_mem_pc[14:0]` | 15 | MEM 级 PC |
| `[66:60]` | `if_id_instr[6:0]` | 7 | 只取 opcode，看指令类别 |
| `[67]` | `stall` | 1 | load-use 停顿（**触发信号候选**） |
| `[68]` | `div_stall` | 1 | 多拍除法停顿 |
| `[69]` | `ex_flush` | 1 | 分支/跳转冲刷第 1 拍（**首推触发信号**） |
| `[70]` | `ex_flush_d` | 1 | 冲刷第 2 拍 |
| `[71]` | `fwd_a_ex` | 1 | 从 EX/MEM 前递（rs1） |
| `[72]` | `fwd_b_ex` | 1 | 从 EX/MEM 前递（rs2） |
| `[73]` | `fwd_a_wb` | 1 | 从 MEM/WB 前递（rs1） |
| `[74]` | `fwd_b_wb` | 1 | 从 MEM/WB 前递（rs2） |
| `[75]` | `id_ex_branch` | 1 | EX 级是否分支指令 |
| `[76]` | `branch_taken` | 1 | 分支条件结果 |
| `[77]` | `mem_we` | 1 | 访存写使能 |
| `[78]` | `mem_re` | 1 | 访存读使能 |
| `[79]` | `mem_wb_reg_write` | 1 | WB 是否回写寄存器 |
| **合计** | | **80 位** | 远低于 256，余量充足 |

> **省位宽的关键**：PC 只取低 15 位。若按 32 位传，四个 PC 就吃掉 128 位，
> 加上其他信号直接顶到 256 上限。地址总线是位宽预算里最贵的东西。

采样深度取 **1024**（例程里的默认值）：`1024 / 27MHz = 37.9 µs`。
DebugCore 的缓存深度范围是 **64 ~ 128k**（2 的整数幂），要抓更长的窗口可以调大，
但要注意 BRAM 占用。平台上另有 `triggerPosition` 参数，
把它设在缓冲区中间，才能看到触发**之前**的流水线状态。

### 7.2 抓取前必须加的防优化属性（两条路径都要）

Fabric Inserter 是从**综合后的网表 `.adf`** 里挑信号的
（见 §7.0 里 `.fic` 的 `designInputFile=..._syn.adf`）。
所以**被综合优化掉的中间信号，在 Inserter 里根本选不到** ——
必须在 RTL 里显式保住它们：

```verilog
// rtl/core/core.v —— 只加在要抓的信号上，不要全局加
wire stall      /* synthesis syn_keep=1 */;
wire ex_flush   /* synthesis syn_keep=1 */;
wire div_stall  /* synthesis syn_keep=1 */;
wire fwd_a_ex   /* synthesis syn_keep=1 */;
wire fwd_b_ex   /* synthesis syn_keep=1 */;
wire fwd_a_wb   /* synthesis syn_keep=1 */;
wire fwd_b_wb   /* synthesis syn_keep=1 */;
reg  ex_flush_d /* synthesis syn_preserve=1 */;
// 也可用 Pango 专用属性（Inserter 会自动识别并列出）：
// wire stall /* synthesis PAP_MARK_DEBUG="true" */;
```

**重要：这些属性和 DebugCore/JTAG Hub 两个 IP 都只能用于调试版本。**

- 它们会保留本可优化掉的逻辑，**LUT 用量会变化**，会破坏
  `doc/resource_efficiency.md` 中记录的 2,301 LUT / 46.42 MHz 数据
- `ips_debug_core`（含 256 位比较器 + `data_capture_mem`）与 `ips_jtag_hub` 自身也占 LUT 与 BRAM

**抓完波形、截图存档后必须移除，并重新综合一次，确认资源与时序回到原值。**
比赛提交的工程里绝不能留着调试核。

> 这些属性是**注释形式**（`/* synthesis ... */`），iverilog 会直接忽略，
> 所以不影响仿真，也不会破坏 `1,529,499` 的回归探针。但为保险，
> 改完仍应跑一次回归确认。

**抓完之后怎么安全地删干净**（`core.v` 是 UTF-8 带中文注释，别用 sed / 别用文本编辑器批量替换，
容易把编码搞坏）。用 Python 按字节替换最稳：

```powershell
# 先看有哪些（应列出 16 处）
Select-String -Path rtl\core\core.v -Pattern "synthesis syn_"

# 一次性删除全部探针属性（含可能的 PAP_MARK_DEBUG）
python -c "import io,re; p=r'rtl/core/core.v'; s=io.open(p,encoding='utf-8').read(); n=len(re.findall(r'/\* *synthesis +(?:syn_keep|syn_preserve) *=[^*/]*\*/', s)); s=re.sub(r' *?/\* *synthesis +(?:syn_keep|syn_preserve) *=[^*/]*\*/', '', s); io.open(p,'w',encoding='utf-8',newline='').write(s); print('removed', n)"

# 复查：应为 0 条，且回归必须回到基线
Select-String -Path rtl\core\core.v -Pattern "synthesis syn_" | Measure-Object | Select-Object -ExpandProperty Count
scripts\run_riscv_tests.ps1            # 期望 49/1/0
scripts\run_coremark.ps1 -Iter 1        # 期望 1,529,499
```

删完重新综合，再用 `pds/RV32I_1/multiseed_summary.csv` 核对 LUT 是否回到 **2,301**。

### 7.3 操作步骤

**主路径（用平台 ILA）**

1. 按 §7.2 在 `rtl/core/core.v` 给要抓的信号加防优化属性。
2. 在 PDS 里 **Compile → Synthesize**，产出网表 `.adf`
   （本工程在 `pds/RV32I_1/synthesize/cpu_top_syn.adf`）。
3. PDS 菜单 **TOOL → Inserter** 打开 **Fabric Inserter**，在 **JtagHub** 目录下选 **DebugCore**，
   配置三栏：
   - **Trigger Parameters**：采样时钟选 `clk`；采样深度 `dataDepth=1024`；
     触发条件设 `ex_flush`（或 `stall`）；触发位置设在缓冲区中间
   - **Net Connections**：按 §7.1 的 77 位清单把设计信号连到通道上
     （PC 记得只连低 15 位）
   - **PowerOn Init Parameters**：默认即可
4. **保存 Inserter 工程 → 这就是那个 `.fic` 文件**
   （PDS 例程里的命名是 `<顶层名>_syn.fic` / `<设计名>_debug.fic`，惯例放在布线输出目录）。
   ⚠️ **务必把 `.fic` 和随后生成的 `.sbit` 放在一起成对保存**。
5. 继续 **Place & Route → Generate Bitstream**，得到含 debug 核的 `.sbit`。
   - 别忘了 `mem.hex` 必须在工程目录，否则 BRAM 为空（见 `pds/README.md` 的坑）
6. 到平台「固件烧录」烧写这个 `.sbit`，确认设备唤醒成功。
7. 进平台的 **ILA** 模块 → 点 **「导入fic文件」** → 选第 4 步保存的 `.fic`。
8. 设触发条件 → **启动** → 抓波形 → 用 **导出** 按钮把波形存下来。
9. 截图至少覆盖三种情形：(a) 一次完整的分支冲刷，(b) 一次 load-use 停顿，
   (c) 一次前递生效。存到 `doc/reports/`。

> **最大的坑**：`.fic` 与 `.sbit` **必须来自同一次综合布线**。
> 改了 RTL 重新生成比特流后，旧的 `.fic` 就作废了 —— 通道映射会整体错位，
> 波形看起来"有信号但全不对"，极难排查。每次重新生成比特流都要同批更新 `.fic`。

**备选路径（平台不给 ILA 时）**

走 §7.3 的 1–5 步之后，不开平台，改在本机：
6′. 直接用 PDS **Debugger** 连板子（**Scan JTAG**），能扫到器件与 `debug_core` 才可行。
7′. 点触发捕获，在波形窗口把总线信号 **Bus radix** 设为 Hex（PC）。
8′. 若 Scan JTAG 扫不到，说明没有 JTAG 通路，只能换成本地盘古 MES2L200HP 板
   （需先按 `RV32I_1.fdc` 中注释的引脚解锁 `led`/`key`/`uart_rx` 并改时钟约束）。

### 7.4 触发条件建议（与 §3/§4 的波形对应）

| 目的 | 触发条件 | 期望看到 |
|---|---|---|
| 分支惩罚 | `ex_flush == 1` | `ex_flush`、`ex_flush_d` 连续 2 拍，`IF/ID`、`ID/EX` 清零，之后 3 拍空档 |
| load-use | `stall == 1` | `stall` 拉高拍 `pc_r` 保持不动，下一拍 `ID/EX` 为气泡 |
| 前递生效 | `fwd_a_ex == 1` | EX 级运算数取自 EX/MEM 而非寄存器堆 |

触发位置建议设在缓冲区中点：这样触发条件满足**之前**的流水线状态也能看到，
才有"前因后果"而不只是"结果"。

### 7.5 待确认事项（执行前必须落实）

1. **你预约到的那台设备有没有启用 ILA。**
   平台文案「当前设备配置未启用该仪器」说明仪器是按设备逐个启用的。
   在「设备管理」里看设备详情，或直接问赛方技术支持（QQ 群见赛题指南第五节）。
2. **平台接受不接受 `.fic` 而不只是 `.ltx`。**
   从代码看：按钮文案在 Pango 板子上是「导入fic文件」、在 Xilinx 板子上是「导入LTX文件」，
   文件过滤器按板卡型号切换。所以**先确认你预约的设备是不是紫光同创的板子**——
   如果是 Xilinx 板，本项目的 Pango `.fic` 用不上。
3. 该设备的 `ilaChannelCount` / `ilaSampleDepth` 是多少（平台按设备下发这两个参数）。
   若通道数少于 §7.1 的 77 位计划，需要再裁剪探针。
4. 截图分辨率与报告排版要求（建议原图，不要压缩到看不清信号名）。
5. 抓完后**移除调试属性与调试核，重跑一次综合与回归**，确认
   `49/1/0`、`1,529,499`、2,301 LUT / 46.42 MHz 都回到基线。

---

## 8. 复现命令

```powershell
# 1) 生成 CoreMark 固件与仿真器
scripts\run_coremark.ps1 -Iter 1 -SkipSim

# 2) 跑剖析（不抓波形），得到 §2 的全部统计
cd sim
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+PROF"

# 3) 抓一段逐拍波形（先看 §2 的直方图挑窗口）
vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" `
    "+PROF" "+TRACE_START=390000" "+TRACE_LEN=40" "+TRACE_FILE=programs/trace.txt"

# 4) 渲染时序波形图
python scripts\trace2svg.py sim\programs\trace.txt doc\figures\pipeline_hazard_mix.svg `
    --title "load-use 停顿与分支冲刷叠加 (PC 0x0dac-0x0dc0)：5 条指令 / 11 拍"

# 5) 反汇编（确认循环里是什么代码）
riscv-none-elf-objdump -d --start-address=0x16b0 --stop-address=0x1704 sim\programs\coremark.elf
```

**回归纪律未受影响**：以上全部改动都在测试台（`sim/tb_coremark.v`，新增的
观测逻辑默认关闭）与新增脚本里，`rtl/` 一行未改。
实测 `ITER=1` 的测试台总周期仍是 **1,529,499**，与改动前逐位一致。
