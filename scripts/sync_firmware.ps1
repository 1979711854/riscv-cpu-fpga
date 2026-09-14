param(
    [string]$Prog = "",     # 默认 sim/programs
    [string]$PdsProject = "" # 默认 pds/RV32I_1
)

# 把仿真用的固件镜像（imem.hex / dmem.hex）同步到 PDS 工程目录，
# 供 rtl/mem/*.v 的 $readmemh 在综合时初始化 BRAM。
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
if ([string]::IsNullOrWhiteSpace($Prog)) { $Prog = Join-Path $repo "sim\programs" }
if ([string]::IsNullOrWhiteSpace($PdsProject)) { $PdsProject = Join-Path $repo "pds\RV32I_1" }

if (-not (Test-Path $Prog)) { throw "找不到固件目录：$Prog（先运行 scripts\run_coremark.ps1）" }
if (-not (Test-Path $PdsProject)) { throw "找不到 PDS 工程目录：$PdsProject" }

foreach ($f in @("imem.hex", "dmem.hex")) {
    $src = Join-Path $Prog $f
    if (-not (Test-Path $src)) { throw "缺少 $src" }
    Copy-Item $src (Join-Path $PdsProject $f) -Force
    Write-Host "已同步 $f -> $PdsProject"
}
Write-Host "完成。在 PDS 里重新 compile / synthesize / P&R 即可。"
