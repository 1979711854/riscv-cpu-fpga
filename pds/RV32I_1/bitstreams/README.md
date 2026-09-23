# 已归档的比特流（本地板 MES2L676-200HP）

PDS 每次 `gen_bit_stream` 都会清空 `generate_bitstream/`，所以在这里留档。
`.sbit` 未入库（体积 9MB），只保留本说明与重新生成的方法。

| 文件 | 固件 | 用途 |
|---|---|---|
| `coremark_iter820_localboard.sbit` | CoreMark v1.0，ITER=820 | 跑分（板上 10.898 s，见 `doc/board/uart_20260923_201540.txt`）|

## 重新生成任一版

```powershell
# 1) 生成固件（二选一）
scripts\run_coremark.ps1 -Iter 820 -SkipSim     # CoreMark 跑分版
scripts\run_demo.ps1 -SkipSim                   # 演示程序版
# 2) 同步进 PDS 工程
scripts\sync_firmware.ps1
# 3) 命令行重建比特流（约 5 分钟）
cd pds\RV32I_1
D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe -project RV32I_1.pds -run gen_bit_stream
```

> ⚠️ 改过 `RV32I_1.fdc` 或 `rtl/` 之后必须重新走一遍上面的流程 ——
> PDS **不检查** `mem.hex` 与 `.fdc` 的时间戳，直接用旧比特流会静默跑到旧设计上。
