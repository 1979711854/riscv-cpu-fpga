<#
============================================================================
 build_c.ps1 —— 编译任意目录下的 C 程序，生成可烧进 BRAM 的 mem.hex

 用法:
   scripts\build_c.ps1 -Dir scripts\myprog              # 编译
   scripts\build_c.ps1 -Dir scripts\myprog -Sync        # 编译并同步到 PDS 工程
   scripts\build_c.ps1 -Dir scripts\myprog -Name hello  # 指定输出名

 目录里需要有:
   *.c / *.S    你的源码（start.S 负责设 sp、清 .bss、调 main）
   link.ld      链接脚本，决定内存布局（直接抄 scripts\template\link.ld）

 产出:
   sim\programs\<名字>.elf        可调试的 ELF
   sim\programs\mem.hex           BRAM 能加载的固件（统一存储器只用这一份）

 之后到 PDS 里: compile -> synthesize -> ... -> generate bitstream
============================================================================
#>
param(
    [Parameter(Mandatory=$true)][string]$Dir,   # 程序目录（相对仓库根或绝对路径）
    [string]$Name = "",                          # 输出名，默认取目录名
    [string]$March = "rv32im",                   # 指令集：rv32i 或 rv32im（本 CPU 都支持）
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$Run,                                # 生成后在仿真里跑一遍，实时打印串口输出
    [int]$MaxCyc = 20000000,                     # -Run 的周期上限（默认 2000 万 ≈ 0.74 秒 @27MHz）
    [switch]$Sync                                # 生成后同步到 PDS 工程目录
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain

# ---- 定位程序目录 ----
if (-not [System.IO.Path]::IsPathRooted($Dir)) { $Dir = Join-Path $repo $Dir }
if (-not (Test-Path $Dir)) { throw "找不到程序目录：$Dir" }
$Dir = (Resolve-Path $Dir).Path

$ld = Join-Path $Dir "link.ld"
if (-not (Test-Path $ld)) { throw "$Dir 下没有 link.ld（可抄 scripts\template\link.ld）" }

# 注意：不要用 Get-ChildItem -Include，它不加 -Recurse 时不生效（PowerShell 的经典坑）
$srcs = @(Get-ChildItem -Path $Dir -File |
            Where-Object { $_.Name -match '\.(c|S)$' } |
            Sort-Object Name)
if ($srcs.Count -eq 0) { throw "$Dir 下没有 .c / .S 文件" }
$hasStart = $srcs | Where-Object { $_.Name -match "start" }
if (-not $hasStart) { Write-Warning "目录里没有 start.S —— 程序会从 0x0 直接跑，没设栈也没清 .bss" }

if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Split-Path $Dir -Leaf }

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null
$elf  = Join-Path $prog "$Name.elf"

Write-Host "[1/2] 编译 $Name  ($($srcs.Count) 个源文件, -march=$March) ..."
foreach ($s in $srcs) { Write-Host "        $($s.Name)" }

$gccArgs = @(
    "-march=$March", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
    "-nostdlib", "-nostartfiles",
    "-I$Dir",
    "-T$ld"
) + ($srcs | ForEach-Object { $_.FullName }) + @("-o", $elf)

& riscv-none-elf-gcc @gccArgs
if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }

Write-Host "[2/2] 拆 ELF -> mem.hex ..."
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

Write-Host ""
Write-Host "固件已生成: $prog\mem.hex"

# ---- 可选：在仿真里跑一遍，实时看串口输出 ----
if ($Run) {
    $sim = Join-Path $repo "sim"
    $vvp = Join-Path $sim "tb_run.vvp"
    $rtl = @()
    foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus", "rtl\top")) {
        $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
    }
    Write-Host ""
    Write-Host "编译仿真测试台 ..."
    & iverilog -g2012 -I (Join-Path $repo "rtl\core") -I (Join-Path $repo "rtl\periph") `
        -I (Join-Path $repo "rtl\bus") -I $sim `
        -o $vvp (Join-Path $sim "tb_run.v") @rtl
    if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

    Write-Host ""
    Push-Location $sim
    try {
        & vvp $vvp "+IMEM=programs/mem.hex" "+MAXCYC=$MaxCyc"
    }
    finally { Pop-Location }
    Write-Host ""
}

if ($Sync) {
    Write-Host "同步到 PDS 工程目录 ..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "sync_firmware.ps1")
    Write-Host ""
    Write-Host "下一步: 在 PDS 里重新 compile -> synthesize -> place&route -> bitstream"
}
else {
    Write-Host "下一步: scripts\sync_firmware.ps1  同步到 PDS 工程目录"
}
