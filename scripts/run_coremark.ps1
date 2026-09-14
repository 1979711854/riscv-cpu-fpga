param(
    [int]$Iter = 1,                                                        # CoreMark 迭代次数（板上跑 ≥10s 需调大）
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$SkipBuild                                                     # 跳过编译，复用已有 ELF
)

# CoreMark 一键：编译 ELF -> 拆 hex 到 sim/programs -> iverilog 编译 tb_coremark -> vvp 跑分
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain          # 供 elf2mem.py 使用

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null
$elf = Join-Path $prog "coremark.elf"
$src = Join-Path $repo "third_party\coremark"
$port = Join-Path $repo "scripts\coremark_port"

if (-not $SkipBuild) {
    Write-Host "[1/3] 编译 CoreMark (ITER=$Iter) ..."
    # 用参数数组调用，避免 PowerShell 原生参数解析把 -DITERATIONS=$Iter 当字面量
    $gccArgs = @(
        "-march=rv32im", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
        "-nostartfiles",
        "-I$src", "-I$port",
        "-DITERATIONS=$Iter",
        "-T$port\link.ld",
        "$src\core_main.c", "$src\core_list_join.c", "$src\core_matrix.c",
        "$src\core_state.c", "$src\core_util.c",
        "$port\core_portme.c", "$port\ee_printf.c", "$port\start.S",
        "-o", $elf
    )
    & riscv-none-elf-gcc @gccArgs
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }
}
else { Write-Host "[1/3] 跳过编译（-SkipBuild）" }

Write-Host "[2/3] 拆 ELF -> imem.hex / dmem.hex ..."
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

Write-Host "[3/3] 编译 testbench 并仿真 ..."
$sim = Join-Path $repo "sim"
$vvp = Join-Path $sim "tb_coremark.vvp"
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
}
& iverilog -g2012 -I (Join-Path $repo "rtl\core") -I (Join-Path $repo "rtl\periph") `
    -I (Join-Path $repo "rtl\bus") -I $sim `
    -o $vvp (Join-Path $sim "tb_coremark.v") @rtl
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

Push-Location $sim
try {
    & vvp $vvp "+ITER=$Iter" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
}
finally { Pop-Location }
