<#
.SYNOPSIS
    轨道 C（棋盘 / 判胜）的 x86 单测 —— 一条命令编译并跑。

.DESCRIPTION
    **不需要板子、不需要 RISC-V 工具链、不需要 iverilog**，只要一个 x86 gcc。
    没装的话：`scoop install gcc`。

    为什么单独给 C 轨道开一条 x86 路径（工作清单 §C / §6）：
    判胜逻辑改一行就走 iverilog 全仿真太慢，没法迭代。这里是纯 C 逻辑，
    x86 上毫秒级出结果，而且 board.c 是【一份源码两处用】——
    同一份文件原样编进 RV32 固件，不存在"PC 上过的和板上跑的不是同一份"。

    [!] 编译时带 -Wall -Wextra，且把警告当错误看 —— 固件那边没有 printf 兜底，
        警告往往就是真 bug（尤其是 int8_t 与 int 混用、比较有无符号）。

.EXAMPLE
    scripts\gomoku\run_test.ps1
#>
param(
    [string]$Gcc = ""    # 默认走 PATH；scoop 装的在 ~\scoop\apps\gcc\current\bin
)

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here "..\..")).Path

if ([string]::IsNullOrWhiteSpace($Gcc)) {
    $cand = Join-Path $env:USERPROFILE "scoop\apps\gcc\current\bin\gcc.exe"
    if (Test-Path $cand) { $Gcc = $cand }
    else {
        $cmd = Get-Command gcc -ErrorAction SilentlyContinue
        if ($cmd) { $Gcc = $cmd.Source }
        else {
            Write-Host "找不到 x86 gcc。装一个： scoop install gcc" -ForegroundColor Red
            exit 1
        }
    }
}

$exe = Join-Path $here "test_board.exe"

Write-Host "[1/2] 编译（gcc -std=c99 -O2 -Wall -Wextra）..." -ForegroundColor Yellow
& $Gcc -std=c99 -O2 -Wall -Wextra `
    (Join-Path $here "board.c") (Join-Path $here "test_board.c") `
    -o $exe
if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }

Write-Host "[2/2] 运行 ..." -ForegroundColor Yellow
& $exe
$rc = $LASTEXITCODE

if ($rc -eq 0) {
    Write-Host ""
    Write-Host "本条路径不需要硬件 —— 这是没板子时能推进的那部分。" -ForegroundColor Green
}
exit $rc
