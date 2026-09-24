<#
.SYNOPSIS
    一条命令走完「生成固件 -> 同步进 PDS 工程 -> 综合布线出比特流」。

.DESCRIPTION
    这是**上板唯一的可靠入口**，原因：

      * `.sbit` 被 .gitignore 排除（每个 9 MB），**仓库里不存比特流** ——
        队友 clone 下来一个 .sbit 都没有，必须自己生成。
      * `generate_bitstream\cpu_top_board.sbit` 这个名字**看不出里面是哪个固件**，
        它只代表「最后一次综合的那版」。2026-09-23 实踩：想烧 CoreMark 跑分版，
        在 PDS Programmer 里直接点了 Program（沿用了上次的路径），结果烧成了
        演示程序版，现象是按键/串口而不是跑分。
      * PDS **不检查** `mem.hex` 的时间戳 —— 固件没同步过去，它也会照常综合出
        一个"能烧但跑的是旧程序"的比特流。

    所以：**要烧哪一版，就用本脚本生成哪一版**，别去猜 `generate_bitstream\` 里
    现在躺着的是什么。

.PARAMETER Variant
    coremark = CoreMark ITER=820 跑分版（板上约 10.9 s，赛题硬指标）
    demo     = 演示程序版（读按键 -> 写 LED -> 串口打印）

.PARAMETER Iter
    仅 coremark 用，默认 820。
    ⚠️ **改了流水线/取指逻辑必须重算**：ITER = 270,000,000 ÷ 每迭代周期数。

.PARAMETER NoBuild
    只生成并同步固件，不跑 PDS 综合（想自己在 GUI 里点时用）。

.EXAMPLE
    scripts\build_bitstream.ps1 coremark
    scripts\build_bitstream.ps1 demo
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("coremark", "demo")]
    [string]$Variant,

    [int]$Iter = 820,

    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$repo    = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$pdsDir  = Join-Path $repo "pds\RV32I_1"
$memHex  = Join-Path $pdsDir "mem.hex"
$sbit    = Join-Path $pdsDir "generate_bitstream\cpu_top_board.sbit"
$pdsShell = "D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe"

# 期望的 mem.hex 行数（每字两行：@地址 + 数据），用来挡住"固件没同步过去"
$expectLines = @{ coremark = 8418; demo = 326 }
$expectDesc  = @{ coremark = "4209 字"; demo = "163 字" }

Write-Host ""
Write-Host "=== 构建【$Variant】版比特流 ===" -ForegroundColor Cyan
Write-Host ""

# ---- 1) 生成固件 ----
Write-Host "[1/3] 生成固件 ..." -ForegroundColor Yellow
if ($Variant -eq "coremark") {
    & (Join-Path $PSScriptRoot "run_coremark.ps1") -Iter $Iter -SkipSim
} else {
    & (Join-Path $PSScriptRoot "run_demo.ps1") -SkipSim
}

# ---- 2) 同步进 PDS 工程 + 校验 ----
Write-Host "[2/3] 同步进 PDS 工程 ..." -ForegroundColor Yellow
& (Join-Path $PSScriptRoot "sync_firmware.ps1")

$lines = (Get-Content $memHex).Count
if ($lines -ne $expectLines[$Variant]) {
    Write-Host "!! mem.hex 行数不对：期望 $($expectLines[$Variant])（$($expectDesc[$Variant])），实际 $lines" -ForegroundColor Red
    Write-Host "   说明固件没同步成功 —— 停下，别往下走。" -ForegroundColor Red
    exit 1
}
Write-Host "    mem.hex = $lines 行（$($expectDesc[$Variant])）OK" -ForegroundColor Green

if ($NoBuild) {
    Write-Host ""
    Write-Host "已按 -NoBuild 停在同步步骤。请在 PDS GUI 里 Compile -> Synthesize -> Device Map -> P&R -> Generate Bitstream。" -ForegroundColor Yellow
    exit 0
}

# ---- 3) 综合布线出比特流 ----
if (-not (Test-Path $pdsShell)) {
    Write-Host "找不到 pds_shell.exe：$pdsShell" -ForegroundColor Red
    Write-Host "请在 PDS GUI 里手工走 Compile -> Synthesize -> Device Map -> P&R -> Generate Bitstream。" -ForegroundColor Yellow
    exit 1
}

Write-Host "[3/3] PDS 综合布线（约 5 分钟，每个 -run 都会重跑前面所有步骤）..." -ForegroundColor Yellow
$t0 = Get-Date
Push-Location $pdsDir
try {
    & $pdsShell -project RV32I_1.pds -run gen_bit_stream
} finally {
    Pop-Location
}

if (-not (Test-Path $sbit) -or (Get-Item $sbit).LastWriteTime -lt $t0) {
    Write-Host "!! 比特流没有更新（$sbit）—— 综合失败或没跑起来。" -ForegroundColor Red
    exit 1
}

$fi = Get-Item $sbit
$md5 = (Get-FileHash $sbit -Algorithm MD5).Hash.Substring(0, 8).ToLower()

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "  比特流：$sbit"
Write-Host "  时间  ：$($fi.LastWriteTime)   大小：$([math]::Round($fi.Length/1MB,2)) MB   md5：$md5..."
Write-Host ""
Write-Host "接下来：" -ForegroundColor Cyan
Write-Host "  1) PDS -> TOOL -> Programmer，器件选 PG2L200H，"
Write-Host "     配置文件就是上面这个路径（**别用备份/旧文件**）"
if ($Variant -eq "coremark") {
    Write-Host "  2) 烧完立刻抓串口（一轮约 11 秒，慢一拍就错过）："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60"
    Write-Host "     期望：Total ticks ≈ 294262913 -> 294262913 / 27e6 = 10.898 s，Correct operation validated"
} else {
    Write-Host "  2) 烧完开串口，应反复打印 KEY=0x00 LED=0x00；按 SW4..SW7 看对应灯亮"
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4"
}
Write-Host ""
Write-Host "  详细步骤与排障：doc\board_bringup.md" -ForegroundColor DarkGray
