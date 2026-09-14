param(
    [string]$TestsDir = "",     # riscv-tests 源码目录（含 isa/rv32ui）。默认 third_party/riscv-tests
    [int]$FirstN = 0,           # >0 时只跑前 N 个测试（快速回归用）
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
)

# riscv-tests (rv32ui) 一键：编译全部 .S -> 逐个跑 tb_riscv -> 汇总 PASS/FAIL
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain

if ([string]::IsNullOrWhiteSpace($TestsDir)) { $TestsDir = Join-Path $repo "third_party\riscv-tests" }
$isaDir = Join-Path $TestsDir "isa\rv32ui"
$macroDir = Join-Path $TestsDir "isa\macros\scalar"
$linkLd = Join-Path $repo "scripts\riscv_tests_link.ld"

if (-not (Test-Path $isaDir)) {
    Write-Host "找不到 riscv-tests 源码：$isaDir"
    Write-Host "获取方式（需联网，建议挂代理）："
    Write-Host "  git clone --depth 1 https://github.com/riscv-software-src/riscv-tests third_party/riscv-tests"
    Write-Host "  或把队友机器上的 riscv-tests 目录拷到 third_party/riscv-tests"
    exit 1
}

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null

# ---- 1) 编译全部测试 ELF ----
Write-Host "[1/3] 编译 rv32ui 测试 ..."
$elfs = @()
foreach ($f in Get-ChildItem (Join-Path $isaDir "*.S") | Sort-Object Name) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $elf = Join-Path $prog "$name.elf"
    & riscv-none-elf-gcc -march=rv32i_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany `
        -nostdlib -nostartfiles -I"$isaDir" -I"$macroDir" -T"$linkLd" $f.FullName -o $elf
    if ($LASTEXITCODE -eq 0) { $elfs += $elf }
}
Write-Host "      编译出 $($elfs.Count) 个 ELF"
if ($FirstN -gt 0) { $elfs = $elfs[0..([Math]::Min($FirstN, $elfs.Count) - 1)] }

# ---- 2) 编译 testbench（只编一次）----
Write-Host "[2/3] 编译 testbench ..."
$sim = Join-Path $repo "sim"
$vvp = Join-Path $sim "tb_riscv.vvp"
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
}
& iverilog -g2012 -I (Join-Path $repo "rtl\core") -I (Join-Path $repo "rtl\periph") `
    -I (Join-Path $repo "rtl\bus") -I $sim `
    -o $vvp (Join-Path $sim "tb_riscv.v") @rtl
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

# ---- 3) 逐个跑 ----
Write-Host "[3/3] 逐个仿真 ..."
$pass = 0; $fail = 0; $timeout = 0; $other = 0
$lines = @()
foreach ($elf in $elfs) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($elf)
    & python (Join-Path $repo "scripts\elf2mem.py") $elf $prog | Out-Null
    Push-Location $sim
    try {
        $out = & vvp $vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+TOHOST=programs/tohost_addr.hex" 2>&1
    }
    finally { Pop-Location }
    $hit = ($out | Select-String -Pattern "PASS|FAIL|TIMEOUT|UNEXPECTED" | Select-Object -First 1)
    $txt = if ($hit) { $hit.Line } else { "???" }
    if     ($txt -match "PASS")     { $pass++;    $lines += "PASS     $name" }
    elseif ($txt -match "FAIL")     { $fail++;    $lines += "FAIL     $name   $txt" }
    elseif ($txt -match "TIMEOUT")  { $timeout++; $lines += "TIMEOUT  $name" }
    else                            { $other++;   $lines += "???      $name   $txt" }
    Write-Host ("  {0,-10} {1}" -f $name, $txt)
}

$lines | Set-Content (Join-Path $prog "results.txt")
Write-Host ""
Write-Host "======== 汇总 ========"
Write-Host "PASS=$pass  FAIL=$fail  TIMEOUT=$timeout  OTHER=$other"
Write-Host "明细: sim/programs/results.txt"
