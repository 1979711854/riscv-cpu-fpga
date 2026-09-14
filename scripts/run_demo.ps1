param(
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$SkipBuild,          # 跳过编译，复用已有 ELF
    [switch]$NoWave              # 不弹 GTKWave
)

# 演示程序一键：编译 demo.c+start.S -> 拆 hex -> iverilog 编译 tb_demo -> 跑
# 这是赛题【基础任务③ 外设系统集成】的验收脚本：
#   读按键 -> 写 LED -> 串口打印
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain          # 供 elf2mem.py 使用

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null
$elf = Join-Path $prog "demo.elf"
$src = Join-Path $repo "scripts\demo"

if (-not $SkipBuild) {
    Write-Host "[1/3] 编译演示程序 ..."
    # 纯 RV32I（不带 M 扩展）——顺带验证基础整数指令集这条路也能跑 C 程序
    $gccArgs = @(
        "-march=rv32i", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
        "-nostartfiles",
        "-I$src",
        "-T$src\link.ld",
        "$src\demo.c", "$src\start.S",
        "-o", $elf
    )
    & riscv-none-elf-gcc @gccArgs
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }
}
else { Write-Host "[1/3] 跳过编译（-SkipBuild）" }

Write-Host "[2/3] 拆 ELF -> imem.hex / dmem.hex / mem.hex ..."
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

Write-Host "[3/3] 编译 testbench 并仿真 ..."
$sim = Join-Path $repo "sim"
$vvp = Join-Path $sim "tb_demo.vvp"
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus", "rtl\top")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
}
& iverilog -g2012 -I (Join-Path $repo "rtl\core") -I (Join-Path $repo "rtl\periph") `
    -I (Join-Path $repo "rtl\bus") -I $sim `
    -o $vvp (Join-Path $sim "tb_demo.v") @rtl
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

Push-Location $sim
try {
    & vvp $vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
}
finally { Pop-Location }
