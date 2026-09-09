param(
    [string]$File = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$simRoot = Join-Path $repoRoot "sim"
$rtlCoreRoot = Join-Path $repoRoot "rtl\core"

function Invoke-Testbench([string]$RelativeTestbench) {
    $filePath = Resolve-Path (Join-Path $repoRoot $RelativeTestbench)
    $simDir = Split-Path $filePath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $vvpPath = Join-Path $simDir "$baseName.vvp"
    $vcdPath = Join-Path $simDir "$baseName.vcd"

    if (Test-Path $vvpPath) { Remove-Item $vvpPath -Force }
    if (Test-Path $vcdPath) { Remove-Item $vcdPath -Force }

    $rtlFiles = Get-ChildItem -Path $rtlCoreRoot -Filter "*.v" | Sort-Object Name | ForEach-Object { $_.FullName }
    $compileArgs = @("-g2012", "-I", $rtlCoreRoot, "-o", $vvpPath, $filePath.Path)
    $compileArgs += $rtlFiles

    Push-Location $simDir
    try {
        Write-Host "Compiling $RelativeTestbench"
        & iverilog @compileArgs
        if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $RelativeTestbench" }

        Write-Host "Running VVP"
        & vvp $vvpPath
        if ($LASTEXITCODE -ne 0) { throw "vvp failed for $RelativeTestbench" }

        if (Test-Path $vcdPath) {
            Write-Host "Opening GTKWave for $vcdPath"
            Start-Process -FilePath "gtkwave" -ArgumentList "$vcdPath" -WindowStyle Hidden | Out-Null
        }
    }
    finally {
        Pop-Location
    }
}

if (-not [string]::IsNullOrWhiteSpace($File)) {
    Invoke-Testbench $File
}
else {
    $testbenches = @(Get-ChildItem -Path $simRoot -Filter "tb_*.v" |
        Where-Object { $_.Name -ne "tb_template.v" } |
        Sort-Object Name |
        ForEach-Object { "sim/$($_.Name)" })

    if ($testbenches.Count -eq 0) {
        throw "No runnable tb_*.v testbench files found under $simRoot"
    }

    foreach ($testbench in $testbenches) {
        Invoke-Testbench $testbench
    }
}
