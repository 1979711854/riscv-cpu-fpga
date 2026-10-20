# 五子棋主机预览（preview.ps1）执行约定

`scripts/gomoku/preview.ps1` 是**主机侧 UI 预览**：用 x86 gcc 编译真实的
`main.c / render.c / game.c`（假视频端口），输出 40×30 tile 字符网格，可选写 640×480 BMP。
它**不跑 PDS、不碰 `rtl/**`、不改固件**，只写 `doc/board/` 与 `sim/tools/` 的临时产物。

## 1. 固定调用方式（照这条抄，别自创）

```powershell
powershell -NoProfile -File d:\riscv-cpu-fpga_merged\scripts\gomoku\preview.ps1 -Scene all -Out d:\riscv-cpu-fpga_merged\doc\board\baseline.txt -Bmp d:\riscv-cpu-fpga_merged\doc\board\baseline.bmp
```

[!] 三条必须遵守，否则会被判成"危险命令"弹确认框：

- **不要**加 `-ExecutionPolicy Bypass` —— 本机 `CurrentUser = RemoteSigned`，本地脚本本来就能跑，
  加了这个参数只会让命令看起来像在绕安全策略。
- **不要**写成 `cd d:\...; powershell ...` 这种链式 —— 用 `-File` + 绝对路径**单条**调用。
- **不要**通过 `cmd /c`、`& {...}`、管道再包一层。

## 2. 什么时候跑（别每轮都跑）

- **只在用户明确要求**"生成/更新基线""解冻前证据"时跑 `-Scene all`；
- 平时改完界面自检，最多跑单场景，够用且快：

```powershell
powershell -NoProfile -File d:\riscv-cpu-fpga_merged\scripts\gomoku\preview.ps1 -Scene title
```

- **同一个会话里不要反复生成同一份基线**：`doc/board/baseline*.bmp` 会被覆盖，
  别的并行会话可能正在用它做对比，重复写会把证据搅乱。

## 3. 并行会话提醒

本仓库可能同时在跑多个会话（例如 v2 界面重做）。`preview.ps1` 编译的是**当前工作树**，
若别人正在改 `scripts/gomoku/*.c`，生成出来的基线是"半成品状态"。
跑之前先 `git status --short` 看一眼：有未提交的 `scripts/gomoku/**` 改动时，
先问用户"现在要冻结的是哪一版"。
