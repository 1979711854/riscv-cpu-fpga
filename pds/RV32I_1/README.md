# PDS 工程 RV32I_1（RV32IM 五级流水线 RISC-V SoC）

## 基本信息
- 器件：紫光同创 **Logos2 `PG2L200H`**，速度等级 -6，封装 FBB676（见 `RV32I_1.pds`）
- 工具：Pango Design Suite **2022.2-SP6.4**
- 顶层：`cpu_top`
- 地址映射：见 `../../rtl/bus/addr_map.vh`（外设区 `0x8000_0000` 起；
  `0x7FF0~0x7FFF` 为 CoreMark 兼容区，不可移动）

## ⚠️ 约束文件当前指向远程 FPGA 平台

`RV32I_1.fdc` 里 `clk=D18 / resetn=C22 / uart_tx=AB26 / done=U16` 是**远程 FPGA 平台**
的引脚。新增的 `led[7:0]` / `key[7:0]` / `uart_rx` 该平台没有对应引脚，因此在 `.fdc`
里**整块注释掉**了。

- **compile / synthesize 不受影响**，仿真与综合验证可以照常做；
- **place & route 会因未指定 `PAP_IO_LOC` 失败**。上本地板卡前必须把那一整块
  取消注释（盘古 MES2L200HP 的实测引脚已经填好），并把 clk/resetn/uart_tx/done
  一并改成盘古板的引脚。

引脚来源：《盘古2L200H开发板》手册 表 3-8（按键）、表 3-9（LED）、表 3-5（UART）。

## 源文件位置（重要）
`.pds` 里的源文件已重指到**仓库根**，本工程不保存源码副本（单一真相）：

| 工程内路径 | 实际文件 |
|---|---|
| `../../rtl/core/*.v` | `core.v control.v alu.v imm_gen.v regfile.v divider.v` |
| `../../rtl/mem/unified_mem.v` | 统一存储器（指令+数据共用一块双端口 BRAM） |
| `../../rtl/bus/addr_map.vh` | 地址映射单点定义（被 `mem_bus.v` include） |
| `../../rtl/bus/mem_bus.v` | 存储总线 / 地址译码 |
| `../../rtl/periph/*.v` | `uart_tx.v` `uart_rx.v` `gpio.v` |
| `../../rtl/top/cpu_top.v` | SoC 顶层 |

打开工程后若提示找不到源文件，先确认 `../../rtl/` 目录存在（即仓库结构完整）。

> ⚠️ 若 PDS 报找不到 `addr_map.vh`，把 `rtl/bus` 加进工程的 **include 搜索路径**
> （或在 `.pds` 里确认 `addr_map.vh` 已在源文件列表中）。

## 固件（BRAM 初值）
`rtl/mem/unified_mem.v` 用 `$readmemh("mem.hex")` 初始化，路径相对**本工程目录**。
统一存储器只用**一份** `mem.hex`（指令+数据的并集，由 `elf2mem.py` 生成）：

```powershell
# 先跑 CoreMark 生成 hex，再同步到本工程目录
scripts\run_coremark.ps1 -Iter 200      # 27MHz 下约 10s（1 iter ≈ 1.53M 周期）
scripts\sync_firmware.ps1               # 把 sim/programs/mem.hex 拷到 pds/RV32I_1/
```

> `sync_firmware.ps1` 会顺手删掉本目录下过期的 `imem.hex`/`dmem.hex` —— 统一存储器
> 不再读取它们，留着会让人误以为那是当前镜像。

然后在 PDS 里重新 compile → synthesize → device map → place&route → generate bitstream。

**综合后建议看一眼资源报告**：存储器应推断为**一块** simple dual-port BRAM
（A 口只读 + B 口读写正是 SDP 的标准形态）。如果还是两块，说明 `unified_mem`
被拆开了，需要检查 `syn_ramstyle` 属性。

## 生成物
`compile/ device_map/ place_route/ report_timing/ synthesize/ generate_bitstream/ logbackup/` 等
均为 PDS 生成物，**不入库**（见仓库根 `.gitignore`）。
