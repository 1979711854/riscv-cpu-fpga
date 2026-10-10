param(
    [int]$Iter = 1,                                                        # CoreMark 迭代次数（板上跑 ≥10s 需 ≥650，用 700）
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$SkipBuild,                                                    # 跳过编译，复用已有 ELF
    [switch]$SkipSim,                                                      # 只生成固件、不跑仿真
    [switch]$Single                                                        # 切单发射（不传 -DDUAL）。默认【双发射】，与板上比特流一致
)

# -SkipSim 的用途：上板流程只需要 mem.hex，不需要仿真。
#   ITER=700 的仿真要跑 3 亿周期（十几分钟），而生成固件只要十几秒。
#   想核实 CoreMark 数值时再去掉这个开关跑一遍。

# CoreMark 一键：编译 ELF -> 拆 hex 到 sim/programs -> iverilog 编译 tb_coremark -> vvp 跑分
#
# [重点] 配置必须显式、且与板上比特流对齐：
#   默认 = 双发射（传 -DDUAL，每迭代 313,886 拍）；-Single = 单发射（363,515 拍）。
#   得分 = 时钟 ÷ 每迭代周期数 ⇒ 配置不同得分不同，混了会把分数算错。
#   日志首行 "SIM CONFIG: DUAL_ISSUE=?" 会自证本次跑的是哪一种。
$ErrorActionPreference = "Stop"
$dualIssue = if ($Single) { 0 } else { 1 }

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

Write-Host "[2/3] 拆 ELF -> imem.hex / dmem.hex / mem.hex ..."
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

if ($SkipSim) {
    Write-Host "      已跳过仿真（-SkipSim）"
    Write-Host "      固件:     $prog\mem.hex  （ITER=$Iter）"
    Write-Host "      下一步:   scripts\sync_firmware.ps1  同步到 PDS 工程目录"
    exit 0
}

$vvpName = if ($dualIssue -eq 1) { "tb_coremark_dual.vvp" } else { "tb_coremark_single.vvp" }
Write-Host "[3/3] 编译 testbench 并仿真 ... DUAL_ISSUE=$dualIssue（$vvpName）"
$sim = Join-Path $repo "sim"
$vvp = Join-Path $sim $vvpName
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
}
$defs = @()
if ($dualIssue -eq 1) { $defs += "-DDUAL" }
$iverilogArgs = @("-g2012") + $defs + @(
    "-I", (Join-Path $repo "rtl\core"), "-I", (Join-Path $repo "rtl\periph"),
    "-I", (Join-Path $repo "rtl\bus"), "-I", $sim,
    "-o", $vvp, (Join-Path $sim "tb_coremark.v")
) + $rtl
$ivOut = & iverilog @iverilogArgs 2>&1
$ivOut | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }
# [!] **端口宽度不一致 = 静默截位，必须当错误处理**（2026-10-10 实踩，同 run_riscv_tests.ps1）。
$widthWarn = @($ivOut | Where-Object { $_ -match 'expects \d+ bit\(s\), given' })
if ($widthWarn.Count -gt 0) {
    $widthWarn | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "iverilog 报了 $($widthWarn.Count) 条端口宽度不一致 —— 那是静默截位，先把宽度对齐再跑回归"
}

Push-Location $sim
try {
    & vvp $vvp "+ITER=$Iter" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
}
finally { Pop-Location }
