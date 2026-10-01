# 开发环境搭建指南（队友通用）— 2026-09-08 验证

三台电脑配成一致环境。需要四样：Pango PDS（上板）、iverilog+GTKWave（仿真）、riscv gcc（编 C）、代码仓库同步。

## 1. Pango PDS 2022.2（上板综合）
- 各自从紫光同创/赛事资料渠道安装 PDS 2022.2（本机装在 `D:\pango\PDS_2022.2-SP6.4`）
- 安装下载器驱动（`PDS drive` 目录里的驱动，或 PDS 内驱动安装程序）

## 2. iverilog + GTKWave（RTL 仿真，约 5 分钟）
PowerShell 执行（首次用 scoop 需先装 scoop）：

```powershell
# 首次：装 scoop
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression

# 装 iverilog（包自带 GTKWave 波形查看器，从 bleyer.org 下载，无需代理）
scoop install iverilog
```

验证（**新开**终端）：
```powershell
iverilog -V
gtkwave --version
```
日常用法：
```powershell
iverilog -g2012 -o tb.vvp tb.v 模块.v ...
vvp tb.vvp
gtkwave tb.vcd
```
> 坑：改 PATH 后**已开着的终端不生效**，重开终端或用
> `$env:Path = "$env:Path;$env:USERPROFILE\scoop\shims"` 临时补上。
> 若 `get.scoop.sh` 拉取失败（GitHub 被墙），挂代理重试。

## 3. riscv-none-elf-gcc（编译 C / CoreMark，约 465MB）
PowerShell 执行：

```powershell
$ProgressPreference='SilentlyContinue'
Invoke-WebRequest -Uri "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64.zip" -OutFile "$HOME\Downloads\xpack-riscv-gcc.zip"

New-Item -ItemType Directory -Force -Path 'D:\riscv-toolchain' | Out-Null
Expand-Archive -Path "$HOME\Downloads\xpack-riscv-gcc.zip" -DestinationPath 'D:\riscv-toolchain' -Force

$bin = 'D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
$up = [Environment]::GetEnvironmentVariable('Path','User')
[Environment]::SetEnvironmentVariable('Path', $up.TrimEnd(';') + ';' + $bin, 'User')
```

验证（**新开**终端）：
```powershell
riscv-none-elf-gcc --version
riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -print-libgcc-file-name
```
> 说明：下载在 GitHub 上，**需代理**；命令前缀 `riscv-none-elf-` 与赛题写的 `riscv32-unknown-elf-` 等价（都是裸机 newlib 工具链，用 `-march=rv32i -mabi=ilp32` 指定 32 位）。

## 4. 代码仓库同步
```powershell
git clone <仓库URL>
cd <目录>
```
仓库内含：`CLAUDE.md`（项目约定）、`doc/plan.md`（任务与排期）、`doc/setup_env.md`（本文档）。

## 5. 通用约定（避免各写各的）
- 源码统一 **UTF-8** 编码（防止中文注释乱码）；外部来的 GBK 老文件只在本地"以 GBK 重开"看，不覆盖保存。
- 板卡引脚约束、板卡手册等资料统一入库（放到 `doc/board/`），不要各自手输。
- 提交纪律：小步提交、提交信息写清改了什么；动 `rtl/` 前先 `git pull`。
- git 仓库级身份（可选）：`git config user.name / user.email` 各填自己。
