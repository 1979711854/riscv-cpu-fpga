param(
    [string]$Testbench = "",   # 单个测试台：如 "sim/tb_alu_div.v"（相对仓库根）
    [switch]$NoWave,           # 加此开关则不弹 GTKWave（CLI/CI 用）
    [switch]$WithCore          # 编入 core.v（跑整核测试台时需要；单测默认不编）
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$simRoot = Join-Path $repoRoot "sim"

# 需要外部程序镜像(hex)的测试台，由专用脚本运行，不参与 "Run All"
#   sim/tb_riscv.v    -> scripts/run_riscv_tests.ps1
#   sim/tb_coremark.v -> scripts/run_coremark.ps1
#   sim/tb_demo.v     -> scripts/run_demo.ps1（跑整个 SoC，还要编 rtl/top）
#   sim/tb_rtthread.v -> scripts/rtthread/run_sim.ps1（同样要编 rtl/top）
#   sim/tb_gomoku.v   -> scripts/gomoku/run_sim.ps1（同样要编 rtl/top + 视频六件）
# [!] 这张表【必须】跟着 sim/ 下新增的 tb_*.v 一起维护：漏一个就会让
#     "跑全部"这条入口在它那里抛异常中断，排在它【后面】的测试台全部不跑，
#     看起来却像"只坏了一个"。tb_rtthread.v 就漏过一次（2026-09-28 发现），
#     tb_gomoku.v 又漏了一次（2026-10-14 补：它在这张表之外，Run All 走到它
#     就报 "Unknown module type: cpu_top"，后面 tb_multiplier/tb_ppu/... 全不跑）。
$externalProgramTbs = @("tb_riscv.v", "tb_coremark.v", "tb_demo.v", "tb_template.v",
                        "tb_rtthread.v", "tb_amo_int.v", "tb_gomoku.v")

# 编译哪些 RTL：core + periph。
# 注意 1：存储器模型 imem/bram 在 testbench 里自带（行为级），所以【不要】编译 rtl/mem，
#         否则会与 tb 内的同名模块冲突；rtl/mem 只在 PDS 综合时使用。
# 注意 2：core.v 例化了 imem/bram，单测（tb_alu_*）不需要它，默认不编；
#         跑整核测试台时用 -WithCore（并把存储器模型交给 tb 提供）。
$rtlDirs = @("rtl\core", "rtl\periph", "rtl\bus")

function Get-RtlFiles {
    $files = @()
    foreach ($d in $rtlDirs) {
        $p = Join-Path $repoRoot $d
        if (Test-Path $p) {
            $files += Get-ChildItem -Path $p -Filter "*.v" | Sort-Object Name | ForEach-Object { $_.FullName }
        }
    }
    # SoC 级模块（core / mem_bus）例化了存储器，而单测（tb_alu_*）既不需要、
    # 也提供不了存储器模型，默认不编；跑整核/SoC 测试台时用 -WithCore，
    # 此时由 testbench 自己提供 imem/bram 的行为级模型。
    $socModules = @("core.v", "mem_bus.v")
    if (-not $WithCore) {
        $files = $files | Where-Object { $socModules -notcontains [System.IO.Path]::GetFileName($_) }
    }
    return $files
}

function Invoke-Testbench([string]$RelativeTestbench, [switch]$NoWave) {
    $filePath = Resolve-Path (Join-Path $repoRoot $RelativeTestbench)
    $simDir = Split-Path $filePath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $vvpPath = Join-Path $simDir "$baseName.vvp"
    $vcdPath = Join-Path $simDir "$baseName.vcd"

    if (Test-Path $vvpPath) { Remove-Item $vvpPath -Force }
    if (Test-Path $vcdPath) { Remove-Item $vcdPath -Force }

    $compileArgs = @("-g2012")
    foreach ($d in $rtlDirs) { $compileArgs += @("-I", (Join-Path $repoRoot $d)) }
    $compileArgs += @("-o", $vvpPath, $filePath.Path)
    $compileArgs += (Get-RtlFiles)

    Push-Location $simDir
    try {
        Write-Host "Compiling $RelativeTestbench"
        & iverilog @compileArgs
        if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $RelativeTestbench" }

        Write-Host "Running VVP"
        & vvp $vvpPath
        if ($LASTEXITCODE -ne 0) { throw "vvp failed for $RelativeTestbench" }

        if ((Test-Path $vcdPath) -and -not $NoWave) {
            Write-Host "Opening GTKWave for $vcdPath"
            Start-Process -FilePath "gtkwave" -ArgumentList "$vcdPath" -WindowStyle Hidden | Out-Null
        }
    }
    finally {
        Pop-Location
    }
}

if (-not [string]::IsNullOrWhiteSpace($Testbench)) {
    # 用法：run_sim.ps1 -Testbench "sim/tb_alu_div.v"
    if ($Testbench -notlike "*.v") { $Testbench += ".v" }
    Invoke-Testbench $Testbench -NoWave:$NoWave
}
else {
    # 未指定参数：跑 sim/ 下所有 tb_*.v（模板与需要外部 hex 的除外）
    $testbenches = @(Get-ChildItem -Path $simRoot -Filter "tb_*.v" |
        Where-Object { $externalProgramTbs -notcontains $_.Name } |
        Sort-Object Name |
        ForEach-Object { "sim/$($_.Name)" })

    if ($testbenches.Count -eq 0) {
        Write-Host "没有可自动运行的 tb_*.v（tb_riscv / tb_coremark 请用专用脚本）"
        exit 0
    }

    foreach ($testbench in $testbenches) {
        Invoke-Testbench $testbench -NoWave:$NoWave
    }
}
