# PDS 工程 RV32I_1（队友交接的 5 级流水线 CPU）

## 基本信息
- 器件：紫光同创 **Logos2 `PG2L200H`**，速度等级 -6，封装 FBB676（见 `RV32I_1.pds`）
- 工具：Pango Design Suite **2022.2-SP6.4**
- 顶层：`cpu_top`（MMIO：`0x7FF4` 周期计数、`0x7FFC` UART 发字符、`0x7FF8` done→LED）
- 约束：`RV32I_1.fdc` —— 当前是**远程 FPGA 平台**（27MHz，`clk=D18 / resetn=C22 / uart_tx=AB26 / done=U16`）
  > 本地"盘古"板卡的引脚/时钟以后再改，改前先确认板卡手册。

## 源文件位置（重要）
`.pds` 里的源文件已重指到**仓库根**，本工程不保存源码副本（单一真相）：

| 工程内路径 | 实际文件 |
|---|---|
| `../../rtl/core/*.v` | `core.v control.v alu.v imm_gen.v regfile.v divider.v` |
| `../../rtl/mem/*.v` | `imem.v bram.v`（行为级，`$readmemh` 初始化 BRAM） |
| `../../rtl/periph/uart_tx.v` | UART 发送 |
| `../../rtl/top/cpu_top.v` | 板级顶层 |

打开工程后若提示找不到源文件，先确认 `../../rtl/` 目录存在（即仓库结构完整）。

## 固件（BRAM 初值）
`rtl/mem/*.v` 用 `$readmemh("imem.hex")` 初始化，路径相对**本工程目录**，所以：

```powershell
# 先跑 CoreMark 生成 hex，再同步到本工程目录
scripts\run_coremark.ps1 -Iter 200      # 27MHz 下约 10s（1 iter ≈ 1.53M 周期）
scripts\sync_firmware.ps1               # 把 sim/programs/*.hex 拷到 pds/RV32I_1/
```

然后在 PDS 里重新 compile → synthesize → device map → place&route → generate bitstream。

## 生成物
`compile/ device_map/ place_route/ report_timing/ synthesize/ generate_bitstream/ logbackup/` 等
均为 PDS 生成物，**不入库**（见仓库根 `.gitignore`）。
