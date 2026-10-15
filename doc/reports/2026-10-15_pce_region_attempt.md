# PCE 区域约束：尝试记录与结论（2026-10-15）

> 背景：`doc/reports/2026-10-15_earlyld_rest_timing_assessment.md` 查出——rev1022 的关键路径
> **约 60% 是布线**（`ram_rdata_eff[27]` 一根 **fanout=1 却走 1.925 ns** 的网线），
> 结论是"**抓手是布局，不是逻辑**"。本文是把那个抓手真正试一遍的记录。
>
> **结论：本次【没做成】——卡在两处都依赖 GUI / 未文档化的东西上。**
> 但**把路探清楚了**，下面是可直接执行的 GUI 步骤（连坐标怎么拿都给了）。

---

## 1. 已查实的事实（下次别再重查）

| # | 事实 | 依据 |
|---|---|---|
| 1 | **PCF 就是个文本文件**，而且**工程已经引用它**：`RV32I_1.pds:266` 有 `(_file "device_map/cpu_top.pcf" (_format pcf))` | `grep pcf RV32I_1.pds` |
| 2 | 该 PCF 的内容 = `.fdc` 生成的**端口 LOC**（`def_port {led[0]} LOC=C19 …`），**当前没有任何 region 行** | `device_map/cpu_top.pcf` |
| 3 | **PCE 的 region 命令语法**（官方手册 `Physical_Constraint_Editor_User_Guide.pdf` §4.13.2）：<br>`region -create <name> -value (xmin,xmax,ymin,ymax)`<br>`region -add <name> -addconstraint <inst>`<br>`region -add <name> -unaddconstraint <inst>`<br>`region -delete <name>` / `region -in` / `region -out` | 手册 §4.13.2 |
| 4 | 保存：`save_constraint -file_name <PCF>` / `save_as_constraint -constraint_save_as <PCF>`（§4.13.5）| 手册 §4.13.5 |
| 5 | **PCF 有 error 会【终止 pnr flow】**（"在 pnr 阶段，如果 PCF 中有 error 则会报 error，并终止 flow 的执行"）| 手册 §1.2.1 |
| 6 | `pce.exe` 二进制里**有 `-batch` / `-file` / `-db` / `-physical -pcf` 等字符串**，提示可能存在批处理模式 | `strings pce.exe` |
| 7 | 但 **`pce.exe -db <db>` 与 `pce.exe <db>` 都报 `Flow-0013: The input DB '(null)' should be of phase 'DEVMAP'`** —— **CLI 形式没试对**；手册只写了 GUI 启动（"单独启动 PCE 的方式，需要用户手动选择需要加载的 Map DB 文件"）| 实测 + 手册 §1.2.2 |
| 8 | **器件坐标网格尺寸拿不到**：器件定义 `pg2l200h/arch/*.eval` 是**加密的 `PANG!` 格式**；`.prt` 是引脚表不是网格 | 实测 |

**⇒ 卡点 = (7) CLI 形式未知 + (8) 网格尺寸未知。** 两者都指向 GUI。

---

## 2. [可执行] 用 GUI 做（**关键：用框选拿坐标，正好绕开卡点 8**）

1. PDS 里先跑到 **device map**（有 `device_map/dmr.db` 即可；本轮已有）。
2. **Tools → Physical Constraint Editor (Post-Map)**，打开的 PCF 选
   `device_map/cpu_top.pcf`（工程里已有，对话框会预填）。
3. 进 **Region Mode**（工具栏 `Region Mode` 按钮），在 floorplan 视图上**框选**一块区域
   —— **坐标由界面给出，不用知道网格尺寸**。
   * 目标：把 **`u_soc/u_core`（CPU 核）** 和 **`u_soc/u_bus/u_mem`（统一存储器 BRAM 阵列）**
     框进**同一块**区域 —— 这正是那根 1.925 ns 网线的两端。
   * [!] **别把 `u_video` 也框进去**（视频域是独立时钟域，框进来只会添乱）。
   * [!] **区域别开太小**：资源放不下时 P&R 会失败或严重劣化。先给**宽松**的一块
     （比如半个 die），看效果再收。
4. 选中 region → Properties 里给 inst 做 `Assign to Region`（等价 TCL：
   `region -add <name> -addconstraint u_soc/u_core`）。
5. **保存 PCF**（工具栏 Save / `save_constraint -file_name device_map/cpu_top.pcf`）。
6. 回 PDS 重跑 **P&R + report_timing**。

**判据（唯一）**：`report_timing/cpu_top_board.rtr` 的 Setup Summary，
**只看 `clk|u_pll/u_gpll/CLKOUT0_Inferred → 自己` 那一行**。

| 结果 | 结论 |
|---|---|
| slack **> +0.2 ns**（当前 +0.034）| [OK] 路子走通 → **复测可达频率**（"提频堵死"的结论要重来一遍）|
| slack 变化不大 / 变差 | [X] **放弃这条路**，如实记录，别再投入 |

---

## 3. [!] 风险：这条路**很可能反而变差**

* 手册与项目文档都警告过约束的副作用——**约定 43** 记着"放松约束 PDS 会偷懒"
  （请求 71.72 MHz 只做出 61.92，比请求 85 的 −1.586 还差）。
* 区域约束是"**给工具加限制**"，限制得不好会让拥塞更糟。
* ⇒ **所以：先小范围试一次、只看那一个数、不行就停**。别在它上面连做五六轮。

---

## 4. 如果 GUI 这条路也不通，还有两个备选（都不在本次范围）

1. **给 BRAM 输出加一级寄存** —— 直接打断那根 1.925 ns 的网线。
   代价：访存变 **2 拍**，等于把 `EARLY_LD` 省下的东西吐回去一部分。
   **要单独算账**（很可能不划算，但它是"逻辑侧"唯一能碰这根网线的办法）。
2. **I-Cache 的 tag 比较离开取指链** —— `doc/reports/2026-10-12_taskbook_v8.md` §5.A
   与 `doc/paper/overview.md` 都把它列为"唯一值钱的 Cache 方向"（≈+11%），
   但那是**带 Cache 档**的事，与当前生产档（Cache 全关）无关。

---

## 5. 本次未改任何 RTL、未改任何工程文件

* 只做了只读探查 + 一次 `pce.exe` 试探（未产生任何输出文件）。
* `device_map/cpu_top.pcf` **未被修改**（探针脚本里的 `save_constraint` 没跑起来）。
* 工作区干净。
