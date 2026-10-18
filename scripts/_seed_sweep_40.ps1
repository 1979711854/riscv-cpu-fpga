param(
    [int]$StartSeed = 1,
    [int]$Batches   = 5,
    [int]$Times     = 8
)
# 40 seed 采样 v2：每批 gplace_times 8（seed S..S+7）
# 关键：seed_N/run.log 要"始终覆盖"地抢拷 —— 首版按"每个 tag 只拷一次"，
# 结果拷到的是刚建目录时的半截文件（没有 Worst slack 行）。
$ErrorActionPreference = 'Continue'
$pdir = 'D:\_lut\pds\RV32I_1'
$proj = Join-Path $pdir 'RV32I_1.pds'
$cap  = 'D:\_lut\pds\_capture_40seed'
$log  = Join-Path $cap 'sweep.log'
New-Item -ItemType Directory -Force -Path $cap | Out-Null

function Log([string]$m) {
    $s = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $s -Encoding UTF8
}

function Set-SeedOptions([int]$seed, [int]$times) {
    $t = [System.IO.File]::ReadAllText($proj, [System.Text.Encoding]::UTF8)
    $t = $t -replace '\(\s*_option gplace_times \(_integer \d+\)\)', ''
    $t = $t -replace '\(\s*_option gplace_seed \(_integer \d+\)\)', ''
    $t = $t -replace '\(\s*_option parallel \(_integer \d+\)\)', ''
    $ins = "(_option gplace_times (_integer $times))`r`n    (_option gplace_seed (_integer $seed))`r`n    (_option parallel (_integer 4))`r`n    "
    $i = $t.IndexOf('(_command cmd_pnr')
    if ($i -lt 0) { throw 'cmd_pnr not found' }
    $j = $t.IndexOf("`n", $i) + 1
    $t = $t.Insert($j, "    " + $ins)
    [System.IO.File]::WriteAllText($proj, $t, (New-Object System.Text.UTF8Encoding($false)))
}

Log "=== sweep start: seeds $StartSeed..$($StartSeed + $Batches*$Times - 1), times=$Times ==="
$pds = 'D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe'

for ($b = 0; $b -lt $Batches; $b++) {
    $seed = $StartSeed + $b * $Times
    Set-SeedOptions -seed $seed -times $Times
    Log "batch $b : gplace_seed=$seed gplace_times=$Times"
    $p = Start-Process -FilePath $pds -ArgumentList '-project','RV32I_1.pds','-run','gen_bit_stream' `
                       -WorkingDirectory $pdir -NoNewWindow -PassThru
    while (-not $p.HasExited) {
        $dirs = Get-ChildItem -Path (Join-Path $pdir 'place_route') -Directory -Filter 'seed_*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $r = Join-Path $d.FullName 'run.log'
            if (Test-Path $r) {
                try { Copy-Item $r (Join-Path $cap ("{0}_b{1}.log" -f $d.Name, $b)) -Force -ErrorAction Stop } catch { }
            }
        }
        Start-Sleep -Seconds 3
    }
    # 收尾再抢一次（PDS 退出瞬间可能还在写）
    Get-ChildItem -Path (Join-Path $pdir 'place_route') -Directory -Filter 'seed_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $r = Join-Path $_.FullName 'run.log'
        if (Test-Path $r) { Copy-Item $r (Join-Path $cap ("{0}_b{1}.log" -f $_.Name, $b)) -Force -ErrorAction SilentlyContinue }
    }
    $n = (Get-ChildItem (Join-Path $cap "seed_*_b$b.log") -ErrorAction SilentlyContinue).Count
    Log "batch $b done, seed logs on disk = $n"
}
Log '=== ALL DONE ==='

# 排序：取每个 log 里最后一次 "Worst slack is N"
Get-ChildItem (Join-Path $cap 'seed_*_b*.log') | ForEach-Object {
    $m = Select-String -Path $_.FullName -Pattern 'Worst slack is (-?\d+)' | Select-Object -Last 1
    if ($m) {
        "{0}`t{1}" -f $_.BaseName, [int]$m.Matches[0].Groups[1].Value
    } else {
        "{0}`tnone" -f $_.BaseName
    }
} | Set-Content -Path (Join-Path $cap 'slack_ranking.txt') -Encoding UTF8
Log 'ranking written to slack_ranking.txt'
