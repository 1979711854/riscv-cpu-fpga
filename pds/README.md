# PDS 工程目录 —— 交接说明

> 更新：2026-09-15（口径最近一次同步：**2026-09-28**，系统时钟迁 **62.0309 MHz** 并把
> M 扩展乘法改成**两拍单元**，见 §二）
> 原来那份 5 级流水线 CPU 仍在，但**存储器、总线和外设做了一次重构**，构建流程也跟着变了。
> 这份文档说清三件事：**现在是什么状态**、**和交接时有什么不同**、**还剩什么没做**。

---

## 一、先看这些

| 我想…… | 去这里 |
|---|---|
| 打开工程 | PDS → `File > Open Project` → `pds/RV32I_1/RV32I_1.pds` |
| 了解架构 | `doc/spec.md`（当前实现的权威描述） |
| 了解基础任务达标情况 | `doc/base_task_status.md` |
| 了解测试结果与基线 | `doc/test_report_riscv-tests.md` |
| 看板上实测证据 / ILA 硬件波形 | `doc/board/`（`uart_2026*.txt` + `ila_hw_*.vcd`，索引见其 `README.md`） |
| 跑回归 | `scripts/run_riscv_tests.ps1`（不带参数即可，不需联网） |

>  **不要从 `riscv32-FPGA-pds/RV32I_1/` 打开。** 那是你交接时的原始副本，里面的 RTL
> 已是旧版本。正式工程是 `pds/RV32I_1/`，源文件指向仓库根的 `../../rtl/**`（单一真相）。

---

## 二、交付状态（一句话）

**基础任务三条全部达标，赛题硬指标（CoreMark ≥10s）已在远程平台与本地盘古板实测通过。**
（2026-09-28 起本地板时钟为 **62.0309 MHz**，并把 M 扩展乘法改成**两拍单元**：
**仿真、综合与板上实测全部通过** —— `Total ticks 727,018,199` ÷ 62,030,900
= **11.7203 s / 170.64 CoreMark**，见下表。）

| 赛题要求 | 状态 | 证据 |
|---|---|---|
| ① 支持 RV32I 基础整数指令集 | [OK] 全覆盖 | riscv-tests **49 PASS / 1 FAIL / 0 TIMEOUT**（含 M 扩展 8 项；唯一 FAIL 是未对齐访存，规范允许） |
| ② ≥3 级流水线 + 数据冲突 + 分支跳转 | [OK] | 5 级流水线 + 前递 + load-use 停顿；分支惩罚 **1 拍**（2026-09-21 取指重定向 3→2 拍，2026-09-25 ID 级静态预测 + BHT 后 **2→1 拍**） |
| ③ 集成 UART / GPIO 用于系统控制与结果输出 | [OK] | 总线 + GPIO + UART 收发；演示程序仿真端到端 7/7 PASS |
| 测评：CoreMark 运行 ≥10s | [OK] **62.0309 MHz 版（ITER=2000）板上实测通过**（2026-09-28 21:24）；49.89 / 45 / 27 MHz 各代亦已实测（历史记录） | **当前**：`Total ticks 727,018,199` ÷ 62,030,900 = **11.7203 秒** → **170.64 CoreMark**，`Correct operation validated`，`seedcrc/crclist/crcmatrix/crcstate` 逐位一致（日志 `doc/board/uart_20260928_212449.txt`）<br>同代对照（只改 RTL、不提频）：`Total ticks 604,516,199` ÷ 49,892,700 = 12.1163 秒 → **137.25 CoreMark**（日志 `doc/board/uart_20260928_212347.txt`）<br>49.89 MHz 历史：`Total ticks 588,890,651` ÷ 49,892,700 = **11.8031 秒 / 140.89 CoreMark**（日志 `doc/board/uart_20260925_172318.txt`）<br>45 MHz 历史：`Total ticks 538,285,445` ÷ 45e6 = **11.9619 秒 / 125.40**<br>27 MHz 历史（本地板）：`Total ticks 294,262,913` ÷ 27e6 = **10.898 秒 / 75.24** |
| 测评：CoreMark/MHz | [OK] | **2.751**（当前设计，每迭代 **363,515** 周期，仿真）<br>五轮演进：2.380 → 2.611 → 2.787 → 2.824 → **2.751**（末轮下降 2.6% 是主动选择：把乘法器拆成两拍换来 Fmax +22%）<br>实际得分：27 MHz 板测 **75.24** → 45 MHz **125.40（+66.7%）** → 49.89 MHz **140.89（+12.36%）** → **62.03 MHz 板测 170.64（+21.12%，累计 +126.8%）** |

> [!] **下面这一节是 45 MHz 时代（2026-09-25 下午）的记录，留作对照。**
> **当前状态是 62.0309 MHz + 两拍乘法器** —— 数字见上面两张表与 §六/§七；
> 完整迁移记录见 `doc/reports/2026-09-25_49mhz_migration.md`。
>
> **2026-09-25：系统时钟已由 27 MHz 迁到 45 MHz。** 做法是用 Pango **PLL IP** 把板载
> 27 MHz 晶振倍频；上板顶层相应改为 **`cpu_top_board`**。`.fdc` 里约束的仍是 27 MHz
> **输入晶振**，45 MHz 由 PDS 从 PLL IP **自动推导**（不是手写的约束）。
> **仿真与远程 FPGA 平台仍是 27 MHz** —— 测试台例化的是 `cpu_top`，不经过 PLL。
>
> | 指标 | 27 MHz 版 | **45 MHz 版** |
> |---|---|---|
> | 时钟约束 | 27 MHz | **45.0005 MHz** |
> | 估计可达 | 47.8126 MHz | **51.5198 MHz** |
> | Setup slack | +16.122 ns | **+2.812 ns**（余量 77% → **14.5%**） |
> | LUT / FF | 2,316 / 1,913 | **3,030 / 2,185** |
> | 资源效率 | 1.127 | **0.920 CoreMark/MHz 每千 LUT** |
> | 实际得分 | 75.25 CoreMark（板上 75.24） | **125.40 CoreMark（板上实测，+66.7%）** |
> | 时序报告 | `report_timing/cpu_top.rtr` | **`report_timing/cpu_top_board.rtr`** |
>
> **每迭代周期 358,846 与迁移前逐位不变**（与时钟无关），所以 **2.787 CoreMark/MHz
> 不变** —— 得分提升**全部**来自频率的线性提升。
> **`+66.7%` 的口径**：`125.40 / 75.24 ≈ 45.0005 / 27 = 1.667`，即"**同一设计只提频**"
> 的收益（分子 2.787 没变）。**不要把提频收益与"第三轮优化的效率收益"乘成一个数** ——
> 那是两个独立口径。
> **资源效率 1.127 → 0.920 不是退步**：分子没变、分母因 PLL 与 `addr_result` 优化而变大，
> 本质是"**用面积换频率**"，换来的是完整得分 **+66.7%**。
> [!] **归因诚实性**：47.81 → 51.52 MHz 是两件事的**合并**效果（① 约束从 27 提到 45 MHz
> ② 同批改了 `core.v` 关键路径：新增 `addr_result` 加法器，把 32×32 乘法器从
> "未对齐判据→异常→pc_r"这条假路径上切下来）。**没做"只改约束不改 RTL"的对照综合**，
> 所以别把增益归给其中任何单一改动。
> [OK] **45 MHz 版已上板实测通过**（2026-09-25）：`Total ticks 538,285,445` ÷ 45e6 = **11.9619 s**
> → **125.40 CoreMark**，`seedcrc/crclist/crcmatrix/crcstate` 逐位一致（`crcfinal` 随 ITER 变，不比）。
> 详见 `doc/resource_efficiency.md` §0（结论）、§2（得分/ITER）、§3（时序）、§10（迁移记录）。

---

## 三、和交接时的差异（重要）

### 3.1 存储器：指令/数据合并成一块

**原来**：`imem` + `bram` 两块独立 BRAM（哈佛）。
**现在**：`rtl/mem/unified_mem.v` 一块双端口 BRAM —— A 口取指、B 口访存。

**为什么必须改**：riscv-tests 的 `fence_i` 测的是**自修改代码**（用 `sh` 把新指令写进代码区，
`fence.i` 后跳过去执行）。哈佛结构下 store 永远改不到指令，`fence.i` 做成 NOP 也没用，
测试必然 TIMEOUT。合并后 store 对取指天然可见，`fence.i` 按 NOP 实现即满足语义。

副产品：BRAM 用量减半，且这正是 `doc/spec.md` 早先写下的 modified-Harvard 路线。

### 3.2 访存从核内移到总线上

**原来**：`core.v` 内部直接例化 `bram`，顶层用地址比较硬译码 MMIO。
**现在**：`core.v` 只给出 `mem_addr/mem_wdata/mem_byte_en/mem_we/mem_re/mem_rdata`，
地址译码全部收敛到 `rtl/bus/mem_bus.v`。**核不再知道存储器映射。**

`mem_bus.v` 头注释里写了两条**硬约束**，改动前务必读：

1. **写通路零寄存器** —— 否则 `st_ld`/`ld_st` 这类"存完立刻读回"会读到旧值
2. **读数据与读选择位都在 MEM→WB 沿寄存**，所有地址源统一 1 拍延迟

### 3.3 新增外设

- `rtl/periph/gpio.v` —— 8 位 LED 输出 + 8 位按键输入（2 级同步，不做硬件消抖）
- `rtl/periph/uart_rx.v` —— UART 接收，8N1 115200，16 深 FIFO，**读操作弹出**
- `rtl/periph/uart_tx.v` —— 你的原文件，未改动

### 3.4 补了 4 条指令

`control.v` 新增 `7'b0001111`（FENCE/FENCE.I → NOP）与 `7'b1110011`
（ECALL → NOP；EBREAK → 置 `sys_ebreak` 停机钩子，经 ID/EX→EX/MEM 送到核外）。

### 3.5  一处**没改**但容易被"好心改坏"的地方

`core.v` 里取指通路的补偿逻辑是**承重的**，请不要动：

```
stall / div_stall 时：pc_r 与 if_addr_d 都保持不动，
由 imem_addr 的 mux 退回 if_addr_d[14:2]（重读上一拍已读过的同一 word）
```

**是 `imem_addr` 后退，不是 `pc_r` 后退。** 若把 `pc_r` 也往后推，连续两拍 stall 会让
同一条指令被取两次，非幂等指令被重复执行 —— 你交接的那版之前就踩过这个坑
（`sb`/`sh`/`sw` 曾因此 FAIL，后来你修好了）。

> 补充（2026-09-21）：这段话原有的后半句是「`ex_flush_d` 的第二道冲刷同理」。
> 现在 `ex_flush_d` 已被**删除**（取指重定向改造：跳转目标改为在冲刷**当拍**旁路给
> 取指端，惩罚从 3 拍降到 2 拍），但**这条纪律仍然成立** —— `imem_addr` 那层的
> "后退"逻辑没有变化，别顺手把 `pc_r` 也推回去。另外注意 `pc_r <= ex_target + 4`
> 里的 `+4`：地址已在当拍发出，不加 `+4` 会让目标指令被取两次。

---

## 四、构建流程（和以前不同了）

### 4.1 固件：只用一份 `mem.hex`

**统一存储器只初始化一个数组**，所以不再用 `imem.hex` + `dmem.hex`：

```powershell
# 1) 生成固件（选一种）
scripts\run_coremark.ps1 -Iter 2000 -SkipSim  # 跑分用：11.72s @62.0309MHz，满足赛题 >=10s（当前设计）
scripts\run_demo.ps1                          # 演示用：读按键→写 LED→串口打印

# 2) 同步到本工程目录（会删掉过期的 imem.hex/dmem.hex）
scripts\sync_firmware.ps1
```

>  **`mem.hex` 缺失时 PDS 不会拦住你。** 它只报一行
> `Cannot open specified data file "mem.hex"`，然后**照常生成比特流** —— 但 BRAM 是空的，
> 板上什么都不跑，且**没有任何其他报错**。这个坑我们踩过，极难排查。
>
>  **`mem.hex` 过期时更隐蔽（2026-09-21 实踩）**：文件存在、大小也正常，只是内容是
> 上一次构建的镜像（例如跑完 demo 之后）。综合**照常成功**、时序资源全部正常，
> 但板上跑的是**旧程序**。PDS 从不比较时间戳。
> **纪律：每次上板前都重新跑一遍 `sync_firmware.ps1`，别凭"上次同步过了"判断。**
> 核对方法：`mem.hex` 的字数应与 ELF 的 `.text` 规模相当 —— CoreMark 固件是
> **4209 字 / 67,693 字节**，而 demo 只有 101 字、riscv-test 约 431 字。

### 4.2 PDS 里跑流程

```
compile → synthesize → device map → place & route → generate bitstream
```

产物：`generate_bitstream/cpu_top_board.sbit`（约 8.8 MB；具体字节数以当次生成为准）

> [!] **产物名跟着上板顶层走**：上板顶层是 `cpu_top_board`（`rtl/top/cpu_top_board.v`），
> 所以 `.sbit` / `.smsk` 也是这个名字。而**这个名字看不出里面烧的是哪个固件** ——
> 判据用 `scripts\build_bitstream.ps1 coremark|demo` 打印的 md5，别靠文件名猜。

> 同目录的 `cpu_top_board.smsk` 是掩码文件，**大小和文件头与 `.sbit` 完全一样**，上传平台时别点错。

### 4.3 已知的无害告警

- `C: Bitstream-2001: SCBV has not been set.` —— 配置 bank 电压提醒，**实测不影响上板运行**
- `W: Port 'key[*]' / 'uart_rx' is not constrained` —— 早期未分配 GPIO 引脚时会打印；
  2026-09-23 起 `.fdc` 已给 `led[7:0]` / `key[3:0]` / `uart_rx` 分配 LOC（见 §7）

---

## 五、地址映射

单点定义在 `rtl/bus/addr_map.vh`（软件侧镜像 `scripts/demo/addr_map.h`）：

```
0x0000_0000 - 0x0000_7FEF   RAM（统一存储器 32KB 内可用部分）
0x0000_7FF0 - 0x0000_7FFF   兼容区（CoreMark 移植层硬编码，不可移动）
    0x7FF4  R  周期计数器[31:0]      0x7FF8  W  done        0x7FFC  W  UART 发送
0x8000_0000 起              外设区（字内偏移 = addr[5:2]）
    0x00  W LED[7:0] / R {key[7:0], led[7:0]}     0x08  W UART 发送
    0x0C  R UART 接收（读弹出）                     0x10  R 周期计数器
```

> RAM 译码**显式挖掉了 `0x7FF0~0x7FFF`**。若把它改回连续译码，CoreMark 写 `0x7FF8`
> 会落进 RAM，`done` 永不拉高。
> **栈顶必须 ≤ 0x7FF0**（CoreMark 用 0x7000）。

---

## 六、已验证的结果（附复现命令）

```powershell
scripts\run_riscv_tests.ps1     # 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\run_sim.ps1             # 6 个单元测试全过
scripts\run_coremark.ps1 -Iter 1
scripts\run_demo.ps1            # 演示程序端到端 7/7 PASS
```

**riscv-tests：49 PASS / 1 FAIL / 0 TIMEOUT**（50 项）
- 唯一 FAIL 是 `ma_data`（未对齐访存，testnum 1）—— **架构取舍**，规范允许实现不支持。
  2026-09-21 曾据一次测量称"取指重定向后它转 PASS"，**该结论经复核已撤回**
  （用改造前的 RTL 复测同样是 FAIL，前后行为一致）
- `fence_i` 已从 TIMEOUT 转 PASS
- rv32um 的 8 项（mul/mulh/mulhsu/mulhu/div/divu/rem/remu）**一次全过**，
  给 M 扩展补上了官方测试背书（此前只有手写单测）

**CoreMark（62.0309 MHz 版板上实测 —— 当前口径，2026-09-28）**
```
Total ticks      : 727018199     → 实际 11.7203 秒（÷ 62,030,900）→ 170.64 CoreMark
Iterations       : 2000
seedcrc/crclist/crcmatrix/crcstate 逐位一致（crcfinal 随 ITER 变，不比）
Correct operation validated.
```
原始日志：`doc/board/uart_20260928_212449.txt`。
（每迭代 727,018,199 ÷ 2000 = **363,509** 拍，仿真 363,515，差 **−0.0016%**。）

**CoreMark（同代对照：只改 RTL、不提频 —— 2026-09-28）**
```
Total ticks      : 604516199     → 实际 12.1163 秒（÷ 49,892,700）→ 137.25 CoreMark
Iterations       : 1663
```
原始日志：`doc/board/uart_20260928_212347.txt`。
它的用处是**把"两拍乘法器代价 −2.6%"单独锁死**：137.25 = 140.89 × 0.9734。

**CoreMark（49.8927 MHz 版板上实测 —— 历史，2026-09-25）**
`Total ticks 588890651` → 11.8031 秒 → **140.89 CoreMark**（日志 `doc/board/uart_20260925_172318.txt`）。

**CoreMark（45 MHz 时代的板上实测 —— 历史记录）**
```
Total ticks      : 538285445     → 实际 11.9619 秒（÷ 45,000,000）→ 125.40 CoreMark
Iterations       : 1500
seedcrc/crclist/crcmatrix/crcstate 逐位一致
Correct operation validated.
```
原始日志：`doc/board/uart_20260925_005201.txt`。

**CoreMark（27 MHz 时代的远程平台实测 —— 历史记录，不是当前设计的判据）**
```
Total ticks      : 294888440     → 实际 10.92 秒
Iterations       : 770
seedcrc/crclist/crcmatrix/crcstate 与仿真逐位一致
Correct operation validated.
```

> 这块日志属于**取指重定向之后、第三轮优化之前（382,972）** 的镜像：`Total ticks`
> 与 `Iterations: 770` 自洽（`770 × 382,972 = 294,888,440`），**标题里的 ITER=820 疑为笔误，待核**。
> **27 MHz 时代的本地板实测**（ITER=820，当时 358,857 拍/迭代）是 `Total ticks 294,262,913`
> → 10.898 s / 75.24 CoreMark，记在 `doc/base_task_status.md`；
> **45 MHz 版（ITER=1500）与 49.89 MHz 版（ITER=1663）均已上板实测，见上**。

**时序（当前：62.0309 MHz 约束 + 两拍乘法器，2026-09-28）**
```
Requested Frequency  : 62.0309 MHz      （周期 16.1210 ns）
Estimated Frequency  : 67.78 MHz        （周期 14.7530 ns）
Setup(Slow) 最差裕量 : +1.368 ns       失败端点 : 0
```
报告文件：**`report_timing/cpu_top_board.rtr`**（上板顶层是 `cpu_top_board`，
不再是 `cpu_top.rtr`）。裕量 1.368ns / 周期 16.121ns → 关键路径约 14.75ns，
时序余量 **8.5%**（49.89 时代 7.7%，45 MHz 时代 14.5%，27 MHz 时代 77%），
`All Constraints Met`。

> [!] **同一份 RTL 两次综合的 Estimated 会差几个点**（实测 67.78 vs 71.62，差 5.7%）。
> **引用余量时要用【归档比特流那一次】的数字**，否则说的和实际烧进去的对不上。
> 任何小于 ~6% 的"提升"也不可信，要多次综合取中位数。

> [!] `.fdc` 里约束的是 **27 MHz 输入晶振**，PLL 输出（当前 62.0309 MHz）由 PDS 从 **PLL IP 自动推导** ——
> 看到约束写 27 MHz 别以为没生效。
> [!] 这次提频**同时**改了 RTL（新增 `addr_result` 加法器，见上文 §二 的归因说明），
> **没有做"只改约束"的对照综合**，别说成单一改动的功劳。

**时序（历史：27MHz 约束，2026-09-21 取指重定向后的设计）**
```
Estimated Frequency  : 47.8126 MHz      （约束 27.0000 MHz）
Setup(Slow) 最差裕量 : +16.122 ns     失败端点 : 0
Hold(Slow)  最差裕量 : +0.147 ns      失败端点 : 0
收敛率 : 100%
```
裕量还有 16.1ns / 周期 37.037ns → 关键路径约 20.9ns，**理论上还能跑到约 47.8MHz**
（工具估计值；真要提频需要重新约束和验证）。

> 读时序/资源报告前先确认它与当前 RTL **同批**。改造前的数据
> （46.4209 MHz / +15.495 ns / 2301 LUT）备份在 `report_timing/bak/`、`synthesize/bak/`，
> 别和新的混用。

### 回归纪律（请务必遵守）

改动 RTL 后，**这两条必须同时保持不变**（除非本次改动的目的就是改变某一项）：

1. riscv-tests 的 **49/1/0**
2. CoreMark 计时区间 **363,515 拍**（测试台总周期 1,467,276）；
   最灵敏的探针是闭合式 `288,056 + 20,720 + 9,396 + 45,343 = 363,515`

第 2 条是"没碰坏流水线"最灵敏的探针 —— 多一个停顿、少一次前递都会让它变。

> 2026-09-21 的取指重定向改造**目的就是改变第 2 条**，所以基线从
> 420,070 / 1,529,499 换成了现在这两个数。除这种"目的即改变"的情况外，它不该动。
> 顺带：**跑 `run_coremark.ps1` 之前先确认 `sim/programs/*.hex` 对应的是当前 ELF**
> —— `elf2mem.py` 若中途失败会留下上一次的镜像，让回归结论完全失真。

---

## 七、待办清单（截至 2026-09-25；标 [OK] 的是已闭环、留档备查的项）

### 高优先级

| 项目 | 说明 |
|---|---|
| `ma_data` 未对齐访问 | **唯一的 FAIL**（testnum 1，确定性）。规范允许实现不支持未对齐访存，属架构取舍。未对齐通路仍无专门测试覆盖（见 `doc/base_task_status.md` §已知限制） |
| **演示程序上板** | [OK] **已在本地盘古板跑通**（2026-09-23：读按键 → 写 LED → 串口打印 + 回显，日志 `doc/board/uart_20260923_200337.txt`）。远程平台约束只有 `clk/resetn/uart_tx/done` 四个信号，大概没有按键和 LED，要现场演示得用本地盘古板 |
| **GPIO 引脚分配** | [OK] **已按盘古板实测引脚分配**（2026-09-23）：`led[7:0]` / `key[3:0]` / `uart_rx` 的 LOC 全在 `.fdc` 里，两张对应表见该文件头部注释。板上 `key[7:4]` 由 `cpu_top_board` 恒定接 1（板级调试口已裁掉，见 §4.2） |
| **资源效率** | 见 `doc/resource_efficiency.md`：LUT **3,767**，主口径 A = **0.730** CoreMark/MHz 每千 LUT；口径 B（完整得分/千 LUT）= **45.30**。<br>比 27 MHz 版的 2,316 / 1.127 低，但这不是退步 —— 分母因 PLL、`addr_result`、BHT 表与两拍乘法器的寄存器变大，本质是「用面积换频率」。<br>**两种口径结论相反，报告里都要给**：A 度量「每 LUT 换多少流水线效率」（降了），B 度量「每 LUT 换多少完整得分」（涨了）。<br>附带：乘法器重构把 **APM 从 11 降到 4** |

### 中优先级

| 项目 | 说明 |
|---|---|
| **ILA 波形抓取** | [OK] **已完成**（2026-09-25）：86 探针调试版比特流 `bitstreams/debug_ila_86probe_localboard.sbit`（md5 `96ee7877`），硬件波形 `doc/board/ila_hw_*.vcd`（CoreMark 分支冲刷、停机自旋），三种分支预测行为的逐拍证据在 `doc/ila_analysis.md`。生产版是另一份（md5 `c4e2c4d2`）。**`.fic` 与 `.sbit` 必须同批成对**，`.fic` 一变旧 `.sbit` 即作废 —— 步骤见该文档 §7 |
| **riscv-arch-test** | RISC-V 官方合规套件，用签名文件逐字节比对，比 riscv-tests 更严格 |
| **应用场景构建** | 目前只有"读按键→写 LED→串口"雏形，赛题有独立评分项 |

### 高阶任务进展

| 方向 | 状态 |
|---|---|
| **完整异常/中断** | [OK] **已完成**：CSR + 6 条 CSR 指令 + `mret` + 六类同步异常 + 定时器中断。测试 `sim/tests/` |
| BHT / BTB 动态分支预测 | [OK] **已完成**（2026-09-25）：`core.v` 里 **256 项、2 位饱和计数器、带 tag 的 BHT**（索引 `PC[9:2]`、tag `PC[31:8]`），**只预测条件分支方向** —— `jal` 仍走 ID 级静态预测、`jalr` 不预测（两者仍走 EX 冲刷）。EX 级训练。**358,846 → 354,119 拍（-1.32%），捕获率 56%**（这两代数字是 BHT 当时代的，此后两拍乘法器把区间推到了 363,515）。<br>残余空间来自 256 项表偏小、别名冲突（341 个静态条件分支中 **149 个冲突**）；扩到 1024/4096 项预计还能回收约 **1%** —— **可优化项，不是缺陷** |
| 2 路组相联 I/D Cache | [ ] 未做，**且经分析是负收益** —— 存储器是单周期 BRAM，访存恒 1 拍、无缺失惩罚，加 Cache 只会引入缺失惩罚。注意届时 `fence.i` 必须从 NOP 升级为"冲刷 I-Cache" |
| 边缘 AI 加速 | [ ] 未做，32KB BRAM 是硬墙 |

---

## 八、会咬人的坑（都踩过）

1. **`mem.hex` 缺失 → 静默生成空 BRAM 比特流**（见 §4.1）
1b. **`mem.hex` 过期 → 板上跑的是上一次的程序，PDS 全程零报错**（2026-09-21 实踩）。
   本工程综合读的是 `pds/RV32I_1/mem.hex`，**不是** `sim/programs/mem.hex`，且不看时间戳。
   跑过 `run_demo.ps1` / `run_riscv_tests.ps1` 之后再 `sync_firmware.ps1`，工程里就留下
   demo / riscv-test 的镜像；此后无论怎么改 RTL、重新综合布线，板上跑的都还是那个旧程序。
   判据：`pds.log` 里 `Loading memory data from file ... mem.hex` + 核对字数
   （CoreMark 固件 = **4209 字 / 67,693 字节**；demo 仅 101 字）。
   **纪律：每次上板前重新 sync，别凭"上次同步过了"判断。**
2. **Verilog 转义里没有 `\r`**。标准只有 `\n \t \\ \" \ddd`，iverilog 会把 `"\r\n"` 里的
   `\r` 当成字面字符 `'r'`，测试台的期望串永远对不上。换行用 `16'h0D0A` 拼
3. **外设不该把 X 放上总线**。`uart_rx` 空 FIFO 曾返回未初始化槽位（值是 X），
   X 被 CPU 读走会污染分支比较（X 参与 `<` 结果是 X，而 `if (X)` 按假处理），
   导致控制流走错分支。已修
4. **测试台驱动同步信号要避开 posedge 竞态**：`ack=1; @(posedge clk); ack=0;` 这种写法
   里，任务恢复与 always 块采样是同一时间步内的不确定顺序。在 **negedge 之后**驱动
5. **PDS 循环展开上限 2000 次**。综合用的 `rtl/mem/unified_mem.v` 里**不能**加整数组
   清零的 for 循环（8192 次）。清零是仿真侧需求，写在 `sim/mem_model.vh` 里
6. **仿真时不要编译 `rtl/mem/`**。testbench 通过 `` `include "mem_model.vh" `` 自带
   `unified_mem` 行为模型，重复定义会冲突
7. **远程平台偶发"固件下载完成但设备唤醒失败"** —— **多烧录几次即可**，与设计无关

---

## 九、目录速查

```
rtl/core/     core.v(5级流水线) control.v alu.v divider.v imm_gen.v regfile.v
rtl/mem/      unified_mem.v          ← 统一存储器（仅 PDS 综合用）
rtl/bus/      addr_map.vh  mem_bus.v ← 地址映射 + 唯一译码处
rtl/periph/   uart_tx.v  uart_rx.v  gpio.v
rtl/top/      cpu_top.v cpu_top_board.v ← SoC 顶层，只做连线；**上板顶层是 cpu_top_board**

sim/          tb_riscv.v tb_coremark.v tb_demo.v（集成）
              tb_alu_* tb_control.v tb_gpio.v tb_uart_rx.v tb_uart_fifo.v（单元）
              mem_model.vh           ← 测试台共用的存储器行为模型
scripts/      run_sim / run_coremark / run_riscv_tests / run_demo / sync_firmware
doc/          spec.md(架构) base_task_status.md(达标核对) test_report_riscv-tests.md

pds/RV32I_1/  本工程（源文件指向 ../../rtl/**，不在 pds/ 保存副本）
pds/riscv_cpu/ 早期 LED 练习工程
```

生成物（`compile/ synthesize/ device_map/ place_route/ report_timing/ generate_bitstream/`
等）均不入库；`mem.hex` 作为固件快照入库。

---

**有疑问或者发现本文与代码不符，以代码和 `doc/spec.md` 为准，并请顺手更新本文。**
