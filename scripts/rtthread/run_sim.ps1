<#
============================================================================
 run_sim.ps1 —— 一条命令跑完 RT-Thread 的编译 + 仿真验证
----------------------------------------------------------------------------
 用法：
   scripts\rtthread\run_sim.ps1            编 RT-Thread -> 编测试台 -> 跑仿真
   scripts\rtthread\run_sim.ps1 -NoBuild   跳过 RT-Thread 重编（只重跑仿真）

 测试台 sim\tb_rtthread.v 会检查三个自检（对应 app\main.c 的设计）：
   [1] 控制台通了        —— 出现 RT-Thread banner
   [2] 系统 tick 在走     —— ping 的 tick 差值 == APP_DELAY_MS，且反复出现
   [3] 上下文切换正确     —— ping / pong 靠信号量交替，次数成对

 [!] 仿真口径与上板不同，别混（见 build.ps1 里的说明）：
     仿真时钟 100MHz（sim\ 下所有测试台都是 always #5）、短延时、出 hex
============================================================================
#>
param(
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent (Split-Path -Parent $Here)
$Sim  = Join-Path $Repo "sim"
$Bld  = Join-Path $Here "build"

# ---- 1) 按仿真口径编 RT-Thread（27/49MHz 那套口径跑仿真会算错 tick）----
if (-not $NoBuild) {
    & (Join-Path $Here "build.ps1") -Sim
    if ($LASTEXITCODE -ne 0) { throw "RT-Thread 编译失败" }
}

foreach ($f in @("imem.hex", "dmem.hex")) {
    if (-not (Test-Path (Join-Path $Bld $f))) { throw "缺少 $f —— 先不带 -NoBuild 跑一次" }
}

# ---- 2) 编测试台 ----
# [!] 不要编 rtl\mem\unified_mem.v —— 测试台用 sim\mem_model.vh 里的行为模型，
#     重复定义会冲突（CLAUDE.md 关键约定 2）。
Write-Host "[1/2] 编译测试台 ..." -ForegroundColor Cyan
$vvp = Join-Path $Bld "tb_rtthread.vvp"
$srcs = @(
    (Join-Path $Sim "tb_rtthread.v")
) + (Get-ChildItem (Join-Path $Repo "rtl\core") -Filter *.v -File | ForEach-Object { $_.FullName }) `
  + @((Join-Path $Repo "rtl\bus\mem_bus.v")) `
  + (Get-ChildItem (Join-Path $Repo "rtl\periph") -Filter *.v -File | ForEach-Object { $_.FullName }) `
  + @((Join-Path $Repo "rtl\top\cpu_top.v"))

$inc = @("-I", (Join-Path $Repo "rtl\core"), "-I", (Join-Path $Repo "rtl\periph"),
         "-I", (Join-Path $Repo "rtl\bus"),  "-I", $Sim)
& iverilog -g2012 @inc -s tb_rtthread -o $vvp @srcs
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

# ---- 3) 跑 ----
Write-Host "[2/2] 跑仿真 ..." -ForegroundColor Cyan
& vvp $vvp "+IMEM=$Bld\imem.hex" "+DMEM=$Bld\dmem.hex"
exit $LASTEXITCODE
