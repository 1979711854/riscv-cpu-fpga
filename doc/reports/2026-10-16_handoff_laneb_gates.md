# 交接文件：lane B 时序门控 7 处已落盘，0 档回归跑到 3/4

> 写于 2026-10-16。上一会话上下文耗尽，本文为唯一权威交接。请**通读全文**再动手。
> 依据文档：`doc/reports/2026-10-16_laneb_timing_fix_taskbook.md`（并行会话写，提交 47af06d）。

## 1. 背景（一句话）

rev1024（lane B 访存 RTL 默认 LANEB_MEM=0）综合后 `load_misaligned_b` 背后的
`alu_result_b` 32 位加法器 cone 被并进 `fetch_addr → imem_addr` 关键路径，CPU 域
WNS +0.330 → −0.165 ns（83.83 MHz，85 MHz 生产档守不住）。修法 = 任务书 §4 的
**7 处常量折叠门控**：0 档让综合器整条删掉恢复 rev1023 网表，1 档语义不变。

## 2. 当前状态（精确）

- **RTL 改动：`rtl/core/core.v` 已完成全部 7 处门控（未提交，`git status` 只有这一个 M 文件）。**
  每处带 `[!] 时序门控（2026-10-16，任务书 §4-N）` 注释，可用
  `git diff rtl/core/core.v` 直接核对。7 处内容：
  1. `wire load_misaligned_b = (LANEB_MEM != 0) && id_ex_b_mem_read && b_mem_unaligned;`（主凶，fetch_addr mux 腿）
  2. `pair_now` 内 `!(p_mem_a && p_ld_b && (LANEB_MEM != 0)) &&`
  3. `wire b_mem_sel = (LANEB_MEM != 0) && ex_mem_b_valid && ex_mem_b_mem_read;`
  4. load-use stall 子句加 `(LANEB_MEM != 0) &&` 前缀
  5. 新增 `wire exb_wb_ok = (ex_mem_b_wb_sel != 2'b01) || (LANEB_MEM == 0);`，
     五处（ld_f_exb / fwd_a_exb / fwd_b_exb / fwd_ba_exb / fwd_bb_exb）改用 `&& exb_wb_ok`
  6. ld_bad_base 子句加 `(LANEB_MEM != 0) &&` 前缀
  7. `assign wb_data_b = ((mem_wb_b_wb_sel == 2'b01) && (LANEB_MEM != 0)) ? load_data_b : ...`
- 测试 / 仿真开关 / 脚本基础设施**已在提交 a8ae162**（tb_laneb_ld.S、tb 两处 LANEBMEM
  ifdef + SIM CONFIG 行 + PAIRTRACE 探针、三个 PS1 脚本 `-LanebMem` 开关）。
- 会话报告 §9 已写好并提交（e7adff5 + 并行会话 47af06d）。

## 3. 0 档逐位不变回归进度（3/4 完成，全部命中）

判据 = ticks + 四 CRC（seedcrc 0xe9f5 / crclist 0xe714 / crcmatrix 0x1fd7 /
crcstate 0x8e3a / crcfinal 0xe714），SIM CONFIG 行须自证 `LANEB_MEM=0`。

| # | 配置 | 判据 ticks | 状态 |
|---|------|-----------|------|
| 1 | `-Iter 1 -SkipBuild -EarlyLd` | 229,597 | ✅ |
| 2 | `-Iter 1 -SkipBuild` | 249,982 | ✅ |
| 3 | `-Iter 1 -SkipBuild -Single` | 300,392 | ✅（本会话最后一步） |
| 4 | `-Iter 1 -SkipBuild -DCache -ICache -EarlyLd` | 233,013 | ⬜ 未跑 |

命令模板（在仓库根）：
```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_coremark.ps1 -Iter 1 -SkipBuild -DCache -ICache -EarlyLd | Select-String -Pattern 'Total ticks|seedcrc|crclist|crcmatrix|crcstate|crcfinal|SIM CONFIG'
```

## 4. 剩余待办（按序执行，用户已两次催"继续"，无需再确认）

1. **CoreMark 基线 4/4**：上面命令，判据 **233,013** + 四 CRC。
2. **riscv-tests 两配置各 49/1/0**：
   - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_riscv_tests.ps1`（默认）
   - 同脚本 + `-DCache -ICache -EarlyLd`
3. **own_tests 6/0**（EarlyLd 两配置）：
   - `... scripts/run_own_tests.ps1 -EarlyLd`
   - `... scripts/run_own_tests.ps1 -EarlyLd -LanebMem`（**1 档复验**：tb_laneb_ld 应仍 PASS，
     证明门控在 1 档是 no-op；vvp 名带 `_lanebmem.vvp` 后缀）
4. **PDS 完整流程**：`scripts\build_bitstream.ps1 coremark`（ITER=4332）。
   预期：**LUT≈7,663 / CPU 域 WNS≈+0.33 ns / Fmax≈87.4 MHz**（≈rev1023 网表）。
   DESIGN_REV 保持 0x2026_1024 不变（任务书 §5 明确）。
   若达标，此位流可替代 `55fae69e`（rev1023）成为可上板交付；若不达标先查 7 处门控是否
   被综合器识别（对照任务书 §3 的网表证据方法）。
5. **提交（不 push）**：core.v 7 处门控 + 若 PDS 达标附上位流/报告数字。commit message
   风格参照 a8ae162（`fix(timing): ...`），注明 0 档逐位不变证据（四基线 ticks+CRC、
   49/1/0、6/0、1 档 no-op）。
6. 汇报后可开始真正的 P3 翻开关：`rtl/core/core.v` 顶部 `LANEB_MEM` 参数 0→1，
   重新跑全量回归 + PDS（预期时序变化需另评，不在本次门控提交内）。

## 5. 坑（本会话踩过，勿重蹈）

- **replace_all 自引用**：门控 5 曾把 `(ex_mem_b_wb_sel != 2'b01)` 全局替换成 `exb_wb_ok`
  误伤新声明自身右端，产生 `wire exb_wb_ok = exb_wb_ok || ...`。已修。用 replace_all 前先想
  新增行是否会吞掉模式自身。
- **PowerShell param 块尾逗号**会解析报错（run_coremark.ps1 踩过）。
- **Select-String -Context 交错显示**会让人误以为 lane A 的 fwd 比较被误改 —— 已直接读文件
  证实未受影响。判断改动以 `git diff` 为准，别信工具的上下文拼接。
- tb 里 `$value$plusargs` 作 task 调用的 Warning 是既有噪音，非错误。
- 回归脚本被链接器 RWX 警告打断的问题已在 9daa65d 修（EAP 临时切 Continue）。

## 6. 关键数字速查

- CoreMark 四基线（0 档）：229,597（dual+EarlyLd）/ 249,982（dual）/ 300,392（single）/
  233,013（dual+cache+earlyld）
- rev1023（可上板位流 55fae69e）：LUT 7,663 / WNS +0.330 / 87.4 MHz
- rev1024（开关版，未修前）：LUT 7,918 / WNS −0.165 / 83.83 MHz / 位流 5124b4bc 不可上板
- riscv-tests 期望 49 pass / 1 fail（已知 AMO） / 0 err；own_tests 6/0
- PAIRTRACE 已证：tb_laneb_ld 8 个 lane B load 配对、7 个驱动访存口、第 8 个未对齐走 trap
