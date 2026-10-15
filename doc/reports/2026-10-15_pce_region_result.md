# PCE 区域约束实验 —— 结论：**负收益，判死**（2026-10-15）

> 本文是 `2026-10-15_session_state.md` §2 那个"半途实验"的**收口**。
> 那份 §2 已同步更新为"已完结·结论否定"，别再照着它的"续做步骤"重做一遍。

---

## 1. 一句话

**把 `u_soc/u_core` + `u_soc/u_bus/u_mem` 框进同一块区域，`u_pll` 的 slack 从
+0.034 ns 掉到 −0.755 ns（可达频率 85.25 → 79.88 MHz）。这条路走不通，已还原。**

---

## 2. 数据

判据是 `.rtr` 里 `clk|u_pll/u_gpll/CLKOUT0_Inferred` 那一行（见 CLAUDE.md 约定 53）。

| | 基线 rev1022（无约束）| 区域约束版 | 还原后重跑 |
|---|---|---|---|
| `u_pll` slack | **+0.034 ns** | **−0.755 ns** | **+0.034 ns** |
| `u_pll` Estimated | 85.2515 MHz | 79.8786 MHz | 85.2515 MHz |
| `u_pll` Estimated period | 11.7300 ns | 12.5190 ns | 11.7300 ns |
| `u_video` CLKOUT0 slack | 33.962 ns | 33.523 ns | 33.962 ns |
| `u_video` CLKOUT0 Estimated | 190.3674 MHz | 175.6852 MHz | 190.3674 MHz |
| CPU 域违规端点 | **0** | **3** | **0** |
| 位流 md5 | `f64b977`（已归档）| `5b4781cf`（**废，未归档**）| `a6ca1c12` |

* 区域内容：`def_region region1 4 177 144 249 {DRM CLMA CLMS APM}`
  —— 约 **29% 的 die**，`Placed fail Instances number: 0`（资源够，不是放不下）。
* 约束版本比基线多出的 3 条违规，正是 CPU 域关键路径
  （−0.755 / −0.737 / −0.705，均在 `u_pll` 组）。
* `u_video` 域**不在区域里**，它的 Estimated 却从 190.37 掉到 175.69 ——
  说明 u_core+u_mem 被挤进 29% 的 die 之后，把 u_video 推到了别处，**整个布局被搅动**。

**为什么变差**：PDS 本来就会把有连接的东西放近。人为加限制只会换来拥塞。
这正是约定 43「放松约束 PDS 会偷懒」的镜像面 —— **收紧约束 PDS 会塞车**。

---

## 3. 约束到底有没有生效（怎么自证的）

光看"文件没被覆盖"不够。三条证据：

1. `place_route/cpu_top_board.prr` 的约束文件清单里**明确列着**
   `.../cpu_top_region.pcf` ⇒ P&R 确实读了它。
2. `u_video`（不在区域内）的 Estimated 也被拉动 190.37 → 175.69 ⇒ 全局布局变了。
3. CPU 域违规从 0 条变 3 条，且形态是那条已知的关键路径被拉长。

---

## 4. [重点] 副产品一：PDS 的 P&R 在约束不变时是【确定性】的

还原 `.pds` 后重跑，`u_pll` 的 slack / Estimated / Estimated period
**与基线逐位相同**（+0.034 / 85.2515 / 11.7300），`u_video` 也逐位相同。

⇒ **同 RTL、同约束，两次综合给出完全相同的结果**。所以那个 −0.789 ns
**100% 归因于区域约束**，没有随机性成分。

> [!] **勘误提醒**：CLAUDE.md 约定 25 记着"同一 RTL 两次综合给出 71.62 vs 67.78（差 5.7%）"，
> 常被当成"P&R 有随机性"的证据。**那次是改了时钟约束**（49.8927 → 62.0309），
> **不是同一约束下的重复综合**。别拿它做"结果不可复现"的论据 —— 本次实测表明可复现。

---

## 5. [重点] 副产品二：怎么让 PDS **不覆盖**你放进工程的 pcf

这是本次卡住最久的地方，踩了三轮才通。**关键结论：光把 `target_file` 改成 OFF 是没用的。**

| 轮次 | `.pds` 的写法 | 结果 |
|---|---|---|
| 1 | `_input` 下**只放一份** pcf，`(_option target_file (_switch OFF))` | **失败** —— PDS 把它当默认覆盖目标，写回 1912 字节的自动产物；`flow.log` 只留一行 `W: Public-4010: Pcf file ... has been covered.` |
| 2 | `_input` 下**放两份**：一份显式 `target_file ON`，region 那份不标 | **约束活了**（`has been covered` 只指向 target 那份），但 P&R 挂了 |
| 3 | 同上，并**删掉 region 那份里的 `def_port`** | **通过** |

* 轮 2 的失败：两份 pcf 都带端口 LOC ⇒
  `E: PhysicalConstraintEditor-0013: [device_map/cpu_top.pcf(line 16)] R25 is already placed, please check your constraint file.`
  P&R **8/8 seed 全失败**、比特流没出。
* **正解**：`wgt_edit_placement_cons` 的 `_input` 下**放两份** ——
  一份显式 `target_file ON`（占住"覆盖目标"这个角色），region 那份当纯输入；
  **且 region 那份只留 `def_region` + `def_inst_region`，端口 LOC 交还给自动产物那份**。
* 依据：UCE 手册 V1.7 第 218-219 行 —— 支持多个 fdc/pcf 文件共存，
  `SetAsTargetFile` 指定哪一份接收新增约束，**未修改的约束保存在原约束文件中**。
* 判据（唯一）：跑完 grep `flow.log` 的 `has been covered`，
  **它指向哪个文件、就是哪个文件被覆盖了**。

> 最终形态（`RV32I_1.pds` 的 `wgt_edit_placement_cons`）：
> ```
> (_input
>     (_file "device_map/cpu_top.pcf"
>         (_option target_file (_switch ON))      <- 显式 target，让它去覆盖
>         (_format pcf)
>     )
>     (_file "cpu_top_region.pcf"                 <- 纯输入，不含 def_port
>         (_format pcf)
>     )
> )
> ```

---

## 6. 现场状态

* **`.pds` 已还原**到提交状态（只引用 `device_map/cpu_top.pcf` + `target_file ON`）。
* **`generate_bitstream/cpu_top_board.sbit` 已盖回**（md5 `a6ca1c12`，slack +0.034，
  与归档档 `f64b977` 的时序数逐位相同）。**实验中途那版 `5b4781cf` 是不收敛版，未归档、勿烧。**
* `pds/RV32I_1/cpu_top_region.pcf` **仍留在目录里**（被 gitignore，不进仓库）。
  [!] 它**当前不被 `.pds` 引用**，只是一次失败实验的产物 —— 别看到它以为约束还生效着。
* 本次未改任何 RTL。

---

## 7. 这条路判死之后的下一步

会话状态 §2 当初的动机是"关键路径 route 占 60%、一根 fanout=1 的网线走 1.925 ns，
所以是 BRAM 离消费它的逻辑太远"。**区域约束本是想逼它们靠近，结果更糟。**

剩下没试过的方向（`2026-10-15_earlyld_rest_timing_assessment.md` 已排除"加流水级数"）：

1. **BRAM 输出加一级寄存** —— 直接打断那根长网线。代价：访存变 2 拍，
   要单独算账（很可能不划算）。
2. **I-Cache 的 tag 比较离开取指链**（带 Cache 档的事，与当前生产档无关）。
3. 接受 85 MHz 现状 —— 当前成绩 **370.23 CoreMark**，余量 0.034 ns 虽然薄，
   但**实测已上板跑通并逐位对齐仿真**，不是纸面结论。

> 建议：**在"提频/时序"这条线上再投入的边际收益已经很低**。
> 队伍时间更该花在 §7 那几条"演示与交付"的缺口上（录像/照片至今为零）。
