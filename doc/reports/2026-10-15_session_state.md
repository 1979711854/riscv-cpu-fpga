# 会话状态 —— 2026-10-15（演示档重出 rev1022 / 约定45 评估 / **PCE 区域约束实验·未完结**）

> 接 `2026-10-14_session_state.md`。**本会话三件事，两件收口、一件正在半途。**
> **下个会话第一件事就是接第 §2 节那个实验 —— 它已经走到"只差改 2 处 + 重跑"了。**

---

## 1. 一句话

**演示档已对齐 rev1022 并达标（`176e0028`）；约定 45 剩余两项评估为"做不了"，
并查出真正的瓶颈是【布线】（关键路径 60% 是 route，一根 fanout=1 的网线走 1.925 ns）；
于是去试 PCE 区域约束 —— 命令全试通了、区域也画好了，但撞上 `.pds` 的 `target_file` 覆盖坑，
**只差改 2 处配置 + 重跑就能出结果**。**

---

## 2. [!] 正在半途的实验：PCE 区域约束（**下个会话从这里接**）

### 目标

把 **`u_soc/u_core`** 和 **`u_soc/u_bus/u_mem`** 约束进**同一个物理区域**，
逼它们靠近 —— 因为关键路径上那根 **`ram_rdata_eff[27]`（fanout=1）走了 1.925 ns**，
判断是"BRAM 阵列离消费它的逻辑太远"。**若成功，关键路径余量（当前 +0.034 ns）应显著回升，
进而解锁 提频 / 配对放宽 / 约定 45 三件事。**

### 已完成（**别重做**）

| 项 | 结果 |
|---|---|
| **命令全部试通** | `region -create region1 <xmin> <xmax> <ymin> <ymax> {CLMA CLMS DRM APM}`<br>`assign_to_region -module {<完整器件路径>} -region {region1}` |
| **[!] module 路径要用【完整器件路径】** | `PG2L200H-6FBB676/cpu_top_board/u_soc/u_core`<br>（不是 `u_soc/u_core` —— 用短路径会报 `Flow-4041: Instance ... can't be found`）|
| **区域画好了** | `def_region region1 4 177 144 249 {DRM CLMA CLMS APM}`（≈整片 die 的 29%，**资源够**：`Placed fail Instances number: 0`）|
| **约束已存盘** | **`pds/RV32I_1/cpu_top_region.pcf`**（437 KB：`def_port` 24 + `def_region` 1 + **`def_inst_region` 6574**）<br>**另备份在** `%TEMP%\claude\cpu_top_region.pcf.BAK`（防再被覆盖）|
| PCE 的界面路径 | 工具栏 **`Region Mode`** → floorplan 右键 **`Draw Region`**（鼠标变十字）；<br>工具栏右键空白处可勾出 **`Console`** / **`Region Mode`**；<br>**`Design Browser` 的 `Show By hierarchy` 必须打开**才有 RTL 模块层次 |

### [!] 撞到的坑（**这是本实验卡住的唯一原因**）

`.pds:265` 那一处把 **PCF 标记成了"输出目标"**：

```
(_file "device_map/cpu_top.pcf"          ← 原来指向 dev_map 的自动产物
    (_option target_file (_switch ON))   ← ★ ON = PDS 每次都重新生成并【覆盖】它
    (_format pcf)
)
```

**症状**：PDS 在 dev_map 阶段把 `cpu_top_region1.pcf` 整个覆盖回 1912 字节（region 全没了），
**只在 `flow.log` 留一行**：

```
W: Public-4010: Pcf file D:/riscv-cpu-fpga_merged/pds/RV32I_1/cpu_top_region1.pcf has been covered.
```

> 这意味着"在 PCE 里加约束 → 保存 → 跑"这条天真路径**必然静默失败**。
> **`flow.log` 里 grep "has been covered" 是唯一的判据。**

### 续做步骤（**就这 5 步**）

1. **确认 PDS 已停**（当前那次跑是无约束的白跑，可停可让它跑完当对照）
2. **备份**：`copy pds\RV32I_1\cpu_top_region.pcf <别处>`
   （已经从 `%TEMP%\claude\cpu_top_region.pcf.BAK` 也留了一份）
3. **改 `.pds` 第 265 行附近两处**：
   ```
   (_file "cpu_top_region.pcf"              ← 换成完好那份（不是被覆盖的 region1）
       (_option target_file (_switch OFF))  ← ★ ON 改 OFF（表示这是【输入】，PDS 别写它）
       (_format pcf)
       (_timespec "2026-10-15T20:49:xx")    ← 跟随文件 mtime
   )
   ```
4. **重跑** `scripts\build_bitstream.ps1 coremark`（约 6 分钟）
   → **跑完立刻再 grep 一次** `has been covered`：**没出现才算约束真的生效**
5. **判据**：`report_timing/cpu_top_board.rtr` 的 Setup Summary，
   **只看 `clk|u_pll/u_gpll/CLKOUT0_Inferred → 自己` 那一行**：

   | slack | 结论 |
   |---|---|
   | **> +0.2 ns**（当前 **+0.034**）| **成了** → 复测可达频率（当前 85.2515 MHz）、重开提频线 |
   | ~0 | 约束没起作用（先确认第 3 步生效）|
   | **变负** | 约束反而添乱 → `.pds` 还原即可 |

### [!] 三条已知风险

1. **`.pcf` 被 gitignore（`pds/RV32I_1/*.pcf` 都不入库）** ⇒ **我把 `.pds` 的改动还原了**，
   否则队友 clone 下来工程会指向一个不存在的文件。**所以上面第 3 步要重新做。**
2. **那 6574 行是"当前 netlist 的叶子单元名"** ⇒ 约束**绑定当前 RTL**，改 RTL 就得在 PCE 里重做。
3. **本条路成功率本就不高** —— 约定 43 记着"放松约束 PDS 会偷懒"（请求 71.72 只做出 61.92）。
   **试一次、看一个数、不行就停。**

---

## 3. 本会话另外两件（**已完成**）

### 3.1 演示档重出 rev1022 —— `176e0028`（提交 `e9cf324`）

* `build_bitstream.ps1 rtthread` 全流程通过（守卫 `mem.hex` **21046 行** ✓）。
* **CPU 域 +0.034 ns / 0 失败端点（20,507）**，请求 85.0051 → 实测 85.2515 MHz，
  **与跑分版 `f64b977` 逐位一致**（同一份 RTL，只换 BRAM 初始化）。
* **推翻了归档索引里"生产/交付档继续用 rev1017 的 `bcd8fdd2` / `8894cdcb`"这条旧结论** ——
  那是 10-14 在 **rev1019** 上得出的（当时重出 −0.153 ns），**对 rev1022 已不成立**。
  已在 `bitstreams/README.md` 加 [2026-10-15 更新]，`f64b977` / `176e0028` 为**新交付口径**。
* **[ ] 板上四条判据待验**：banner `FW=RTTHREAD-GOMOKU-G3 RTL=0x20261022`
  → `render thread running` → `ai thread running` → `[hb]` 每 5 s 一条不断。
  灯：D19/D18 亮，**D13 不亮正常**。

### 3.2 约定 45 剩余两项评估（提交 `2dda062`）

`doc/reports/2026-10-15_earlyld_rest_timing_assessment.md`

* **结论：两项都做不了** —— 不是因为"余量小"，而是**插入点就在当前关键路径上**
  （基址在 EX 要加在 `… → load_data → rs1_val → …` 那段；紧前是 store 要加在
  `load_half/load_data` 那两级），而余量只有 **+0.034 ns（0.29%）**。
* **[重点] 关键路径（rev1022 实测）**：
  ```
  BRAM 读出 → load 解包(load_half/load_data) → 前递 → rs1_val
    → 分支比较 → branch_taken → ex_resolve_taken
    → if_addr_d → imem_addr → imem_addr2 → BRAM 地址口
  ```
  **与会话状态 §4.2（62 MHz 时代）记的那条【逐段一致】** ⇒ 从 62 提到 85 MHz，
  **瓶颈一直是同一条链**。当年那句"抓手是高扇出复制与布局、不是加流水线级数"**今天仍成立**。
* **数据路径 11.234 ns 里：逻辑 ≈4.5 ns、网线 ≈6.7 ns（约 60%）**。最刺眼的一根：
  `ram_rdata_eff[27]  net (fanout=1)  1.925 ns`。
* **不要**加流水级数（load-use 与分支惩罚各加一拍，净亏）。

---

## 4. 当前基线（别用旧数）

| 项 | 值 |
|---|---|
| **板上最好成绩** | **370.23 CoreMark**（`f64b977`，rev1022，日志 `doc/board/uart_20261014_233933.txt`）|
| 每迭代 | **229,597**（仿真）/ 229,574.8（板上，−0.0097%）|
| 效率 | **4.355 CoreMark/MHz** |
| **CPU 域时序** | **+0.034 ns / 0 失败端点（20,507）**；请求 85.0051 → **实测 85.2515 MHz** |
| 板上 ITER | **4332** |
| 回归 | riscv-tests **49/1/0**（默认 + `-DCache -ICache -EarlyLd` 双口径）；自写 **5 PASS**；RT-Thread **四配置全 PASS** |
| 资源 | LUT 8,104 / 5.07%（RAS+BTB 代价 +622）|

**"提频堵死"的口径要微调**：可达 85.2515 vs 请求 85.0051 —— 这**是当前布局下的结论**；
**若 §2 的区域约束能把长网线收回来，可达频率要重新量。**

---

## 5. 本会话新增的文件

| 文件 | 内容 |
|---|---|
| `doc/reports/2026-10-15_earlyld_rest_timing_assessment.md` | §3.2 的评估全文 |
| `doc/reports/2026-10-15_pce_region_attempt.md` | PCE 实验的**早期**记录（**部分被本文 §2 取代**：那时还没找到 `region -create` / `assign_to_region`，也没发现 `target_file` 覆盖坑）|
| `doc/Physical_Constraint_Editor_User_Guide.pdf` + `_文本提取.txt` | PCE 手册（**注意：手册版本旧，`region -add` 在本版不存在**）|
| `doc/User_Constraint_Editor_User_Guide.pdf` + `_文本提取.txt` | **UCE 手册（V1.7，较新）—— 区域约束的正确操作在这份里** |

---

## 6. 下个会话起手

```powershell
cd D:\riscv-cpu-fpga_merged ; git log --oneline -3 ; git status    # 分支 dualissue
# 然后读本文件 §2，直接接那个实验
```

**未 push 的提交**：本会话产生的若干提交都在本地。按项目纪律**不自动 push**，需要时手动。

---

## 7. [!] 仍未验证 / 悬着的（别当成已完成）

* **`176e0028` 的板上四条判据**（§3.1）—— 位流已出但没有上板。
* **G3 的"AI 思考期间画面不卡"** —— 从没接过显示器看过（`v2` 任务书 §2.2）。
* **RT-Thread 的 `vblank timeout`** —— 23 份裸机日志都没有、只有 RT-Thread 那份有；
  机制与一步判据（看 D18）在 `doc/board/README.md`。**`176e0028` 正好可以拿来复验这条。**
* **录像 / 照片** —— `doc/board/` 至今只有串口文本和 ILA 波形，
  **赛题"应用场景演示"这一项没有任何视觉证据**。用户决定**等五子棋队友完善后再录**。
* **论文 / 答辩材料** —— §15（Cache 负收益 + 官方口径）已是一块；RVC 的答辩理由也可引官方那句。
