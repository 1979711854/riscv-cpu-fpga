<#
.SYNOPSIS
    一条命令走完「生成固件 -> 同步进 PDS 工程 -> 综合布线出比特流」。

.DESCRIPTION
    这是**上板唯一的可靠入口**，原因：

      * `.sbit` 被 .gitignore 排除（每个 9 MB），**仓库里不存比特流** ——
        队友 clone 下来一个 .sbit 都没有，必须自己生成。
      * `generate_bitstream\cpu_top_board.sbit` 这个名字**看不出里面是哪个固件**，
        它只代表「最后一次综合的那版」。2026-09-23 实踩：想烧 CoreMark 跑分版，
        在 PDS Programmer 里直接点了 Program（沿用了上次的路径），结果烧成了
        演示程序版，现象是按键/串口而不是跑分。
      * PDS **不检查** `mem.hex` 的时间戳 —— 固件没同步过去，它也会照常综合出
        一个"能烧但跑的是旧程序"的比特流。

    所以：**要烧哪一版，就用本脚本生成哪一版**，别去猜 `generate_bitstream\` 里
    现在躺着的是什么。

.PARAMETER Variant
    coremark = CoreMark ITER=2000 跑分版（板上约 11.72 s，赛题硬指标）
    demo     = 演示程序版（读按键 -> 写 LED -> 串口打印）
    rtthread = RT-Thread Nano 版（开机能打 banner，ping/pong 两个线程交替打印）
    video    = HDMI 彩条版（填显存画 8 条竖条 + 串口显存读回自检）
    gomoku   = 五子棋版（HDMI 出棋盘，4 个按键操作，串口打印 AI 节点数/耗时）
[!] 各变体会自动设置 cpu_top_board 的 DEBUG_LED 开关：
         coremark -> DEBUG_LED=1（led[1:0] 显示 pll_locked/done，看跑分状态）
         demo     -> DEBUG_LED=0（led[7:0] 全给 GPIO，恢复 LED=KEY 演示映射）
         rtthread -> DEBUG_LED=1（同 coremark；led[0]=pll_locked 仍是上板首要判据）
         video    -> DEBUG_LED=1（led[1]=video_locked，HDMI 黑屏先看这一颗）

.PARAMETER Iter
    仅 coremark 用，默认 2000。
[!] **改了流水线/取指逻辑或主频必须重算**：
        ITER = 时钟频率 × 10s ÷ 每迭代周期数
    当前：62,030,900 × 10 ÷ 363,515 = 1,706（恰好 10s），默认取 2000 → 11.72s（余量 17%）。
    （仿真/远程平台是 27MHz，那边用 270,000,000。别混。）
[!] 每迭代周期数当前是 **363,515**（两拍乘法器之后）；再往前是 354,119。
    改完 RTL 先跑 `run_coremark.ps1 -Iter 1` 看 Total ticks 现是多少，再套上面的式子。

.PARAMETER NoBuild
    只生成并同步固件，不跑 PDS 综合（想自己在 GUI 里点时用）。

.EXAMPLE
    scripts\build_bitstream.ps1 coremark
    scripts\build_bitstream.ps1 demo
    scripts\build_bitstream.ps1 rtthread
    scripts\build_bitstream.ps1 video
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("coremark", "demo", "rtthread", "video", "gomoku")]
    [string]$Variant,

    [int]$Iter = 2000,

    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$repo    = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$pdsDir  = Join-Path $repo "pds\RV32I_1"
$memHex  = Join-Path $pdsDir "mem.hex"
$sbit    = Join-Path $pdsDir "generate_bitstream\cpu_top_board.sbit"
$pdsShell = "D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe"

# 期望的 mem.hex 行数（每字两行：@地址 + 数据）—— 只作**粗筛**，真正的判据是下面的逐字节比对。
#
# [!] 这个数字**会随编译期常量变**，别当成硬约束。实测：
#       EE_TICKS_PER_SEC = 45,000,000  -> 4209 字（8418 行）
#       EE_TICKS_PER_SEC = 49,892,700  -> 4208 字（8416 行）
#       EE_TICKS_PER_SEC = 62,030,900  -> 4209 字（8418 行）  （2026-09-28 提频）
#     差 1 个字是**除数常量变了**导致编译器把 `/ EE_TICKS_PER_SEC` 的常量除法
#     优化成少一条指令 —— 与 ITER 无关（ITER=1500/1663/820/1 都一样是 4208）。
#     所以 guard 一旦挡住你，**先确认是不是又改了编译期常量**，别急着放宽。
$expectLines = @{ coremark = 8418; demo = 326; rtthread = 9498; video = 758; gomoku = 9186 }
$expectDesc  = @{ coremark = "4209 字"; demo = "163 字"; rtthread = "4749 字"; video = "379 字"; gomoku = "4593 字" }

# DEBUG_LED 开关（见 rtl/top/cpu_top_board.v）：PDS 综合取 parameter 默认值，
# 命令行没法传 -D 宏，所以这里**直接改默认值再综合**，结束后还原。
#   coremark -> 1：led[1:0] 显示 pll_locked / done，板上能一眼看出卡在哪
#   demo     -> 0：led[7:0] 全给 GPIO，恢复"按开关位置重排"的 LED=KEY 映射
$topBoard = Join-Path $repo "rtl\top\cpu_top_board.v"
$debugLed = @{ coremark = 1; demo = 0; rtthread = 1; video = 1; gomoku = 1 }[$Variant]

Write-Host ""
Write-Host "=== 构建【$Variant】版比特流 ===" -ForegroundColor Cyan
Write-Host ""

# ---- 0) 设置 DEBUG_LED（try/finally 保证还原）----
# [!] 必须用 .NET 的 File::ReadAllText/WriteAllText 配 no-BOM 编码：
#    Windows PowerShell 5.1 的 `Set-Content -Encoding utf8` 会**写 BOM**，
#    在 .v 文件开头插三个字节，iverilog/PDS 可能因此拒收。
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$topOrig = [System.IO.File]::ReadAllText($topBoard, $utf8NoBom)
if ($topOrig -notmatch 'parameter\s+DEBUG_LED\s*=\s*[01]') {
    Write-Host "!! 在 cpu_top_board.v 里找不到 parameter DEBUG_LED —— 版本不匹配，停下。" -ForegroundColor Red
    exit 1
}
$topNew = $topOrig -replace 'parameter\s+DEBUG_LED\s*=\s*[01]', "parameter DEBUG_LED = $debugLed"
if ($topNew -ne $topOrig) {
    [System.IO.File]::WriteAllText($topBoard, $topNew, $utf8NoBom)
    Write-Host "    DEBUG_LED = $debugLed（按【$Variant】变体设置）" -ForegroundColor Green
} else {
    Write-Host "    DEBUG_LED = $debugLed（已是该值，无需改）" -ForegroundColor Green
}

# ---- 1)~3)：全程包在 try/finally 里，保证 DEBUG_LED 无论怎么退出都还原 ----
try {
    # ---- 1) 生成固件 ----
    Write-Host "[1/3] 生成固件 ..." -ForegroundColor Yellow
    if ($Variant -eq "rtthread") {
        # RT-Thread 的固件由它自己的 build 脚本产出（它有独立的 BSP 与链接脚本），
        # 先把产物放进 sim\programs\，这样下面的 sync_firmware 与 sha256 校验
        # 都能照常走，不必为它开一条特例路径。
        # [!] 默认（不带 -Sim）就是【上板口径】：时钟 62.0309MHz、延时 500ms。
        #     带 -Sim 会变成仿真的 100MHz/5ms —— 那个不能上板。
        & (Join-Path $PSScriptRoot "rtthread\build.ps1") -Firmware
        if ($LASTEXITCODE -ne 0) { throw "RT-Thread 固件编译失败" }
        Copy-Item (Join-Path $PSScriptRoot "rtthread\build\*.hex") `
                  (Join-Path $repo "sim\programs\") -Force
        Write-Host "    RT-Thread 固件已放进 sim\programs\（上板口径 62.0309MHz）" -ForegroundColor Green
    } elseif ($Variant -eq "coremark") {
        & (Join-Path $PSScriptRoot "run_coremark.ps1") -Iter $Iter -SkipSim
    } elseif ($Variant -eq "video") {
        & (Join-Path $PSScriptRoot "run_video.ps1") -SkipSim
    } elseif ($Variant -eq "gomoku") {
        # 五子棋有自己的一套源码与构建脚本（7 个模块 + 图块表）
        & (Join-Path $PSScriptRoot "gomoku\build.ps1")
    } else {
        & (Join-Path $PSScriptRoot "run_demo.ps1") -SkipSim
    }

    # ---- 2) 同步进 PDS 工程 + 校验 ----
    Write-Host "[2/3] 同步进 PDS 工程 ..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "sync_firmware.ps1")

    # ---- 2a) 主判据：PDS 工程里的 mem.hex 必须与刚生成的那份【逐字节相同】----
    # 这才是"已同步"的真正定义，比数行数牢靠得多（行数会随编译期常量变，见上面的注释）。
    # [!] 这一条挡的是 CLAUDE.md 里那个"文件在、但内容过期"的坑：PDS 从不检查
    #     mem.hex 的时间戳，工程里留着旧镜像也会照常综合、全程零报错。
    $memHexSrc = Join-Path $repo "sim\programs\mem.hex"
    $hSrc = (Get-FileHash $memHexSrc -Algorithm SHA256).Hash
    $hDst = (Get-FileHash $memHex    -Algorithm SHA256).Hash
    if ($hSrc -ne $hDst) {
        Write-Host "!! 同步失败：PDS 工程里的 mem.hex 与刚生成的不是同一份" -ForegroundColor Red
        Write-Host "     生成: $memHexSrc  sha256 $($hSrc.Substring(0,16))" -ForegroundColor Red
        Write-Host "     工程: $memHex     sha256 $($hDst.Substring(0,16))" -ForegroundColor Red
        Write-Host "   板上会跑旧程序，而 PDS 全程不报错 —— 停下，别往下走。" -ForegroundColor Red
        exit 1
    }

    # ---- 2b) 粗筛：字数是否落在预期附近（挡住"根本是别的程序"）----
    $lines = (Get-Content $memHex).Count
    if ($lines -ne $expectLines[$Variant]) {
        Write-Host "!! mem.hex 行数与预期不符：期望 $($expectLines[$Variant])（$($expectDesc[$Variant])），实际 $lines" -ForegroundColor Yellow
        Write-Host "   若本次确实改过编译期常量（EE_TICKS_PER_SEC / ITER 等），属正常，更新本脚本的 expectLines 即可。" -ForegroundColor Yellow
        Write-Host "   否则说明固件不对 —— 停下查清楚再往下走。" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "    mem.hex 已同步并校验：$lines 行（$($expectDesc[$Variant])），sha256 一致" -ForegroundColor Green

    if ($NoBuild) {
        Write-Host ""
        Write-Host "已按 -NoBuild 停在同步步骤。请在 PDS GUI 里 Compile -> Synthesize -> Device Map -> P&R -> Generate Bitstream。" -ForegroundColor Yellow
        Write-Host "（DEBUG_LED 会还原成默认的 1 —— GUI 里若想要 demo 映射，手工把参数改成 0。）" -ForegroundColor Yellow
        exit 0
    }

    # ---- 3) 综合布线出比特流 ----
    if (-not (Test-Path $pdsShell)) {
        Write-Host "找不到 pds_shell.exe：$pdsShell" -ForegroundColor Red
        Write-Host "请在 PDS GUI 里手工走 Compile -> Synthesize -> Device Map -> P&R -> Generate Bitstream。" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "[3/3] PDS 综合布线（约 5 分钟，每个 -run 都会重跑前面所有步骤）..." -ForegroundColor Yellow
    $t0 = Get-Date
    Push-Location $pdsDir
    try {
        & $pdsShell -project RV32I_1.pds -run gen_bit_stream
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $sbit) -or (Get-Item $sbit).LastWriteTime -lt $t0) {
        Write-Host "!! 比特流没有更新（$sbit）—— 综合失败或没跑起来。" -ForegroundColor Red
        exit 1
    }
}
finally {
    # 还原 cpu_top_board.v 的 DEBUG_LED，别把"为本次变体改的默认值"留在工作区
    if ($topNew -ne $topOrig) {
        [System.IO.File]::WriteAllText($topBoard, $topOrig, $utf8NoBom)
        Write-Host "    （DEBUG_LED 已还原为 1）" -ForegroundColor DarkGray
    }
}

$fi = Get-Item $sbit
$md5 = (Get-FileHash $sbit -Algorithm MD5).Hash.Substring(0, 8).ToLower()

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "  比特流：$sbit"
Write-Host "  时间  ：$($fi.LastWriteTime)   大小：$([math]::Round($fi.Length/1MB,2)) MB   md5：$md5..."
Write-Host ""
Write-Host "接下来：" -ForegroundColor Cyan
Write-Host "  1) PDS -> TOOL -> Programmer，器件选 PG2L200H，"
Write-Host "     配置文件就是上面这个路径（**别用备份/旧文件**）"
if ($Variant -eq "coremark") {
    Write-Host "  2) 烧完立刻抓串口（一轮约 12 秒，慢一拍就错过）："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60"
    Write-Host " [重点] 板上时钟 62.0309MHz，期望 Total ticks ≈ 727,030,000 -> /62,030,900 = 11.72 s"
    Write-Host "       （**别再用 ÷49.89e6 / ÷45e6 / ÷27e6** —— 那都是旧口径。以 PDS 时序报告里的实际频率为准）"
    Write-Host "       得分预期：62.0309e6 / 363,515 × 1000 = 170.6 CoreMark（改前 140.89）"
} elseif ($Variant -eq "rtthread") {
    Write-Host "  2) 烧完开串口，应打印 RT-Thread banner + ping/pong 交替（乒乓 500ms）："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 30"
    Write-Host " [重点] 三条判据：banner 出来 / [ping] 的 delta 精确等于 500 / [pong] total 递增"
    Write-Host "       板级：led[0]=pll_locked 常亮；led[2]=done 本变体【不会亮】，别误判"
} elseif ($Variant -eq "gomoku") {
    Write-Host "  2) 先看板上的灯（DEBUG_LED=1）："
    Write-Host "     led[1]=video_locked 不亮 -> 视频 PLL 没锁，屏幕不会亮，先查这个"
    Write-Host "     （丝印：D18=video_locked  D19=pll_locked  D13=done）"
    Write-Host "  3) 再接 HDMI 显示器，应看到【15×15 棋盘 + 红色光标圈】；"
    Write-Host "     串口会打印按键用法，AI 每走一步会打印 nodes/depth/耗时："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 30"
    Write-Host "  4) 操作：SW4/5/6/7 = 左/右/上/下；短按移动光标，长按 0.6 秒落子；"
    Write-Host "     标题屏长按任意键开始；SW3 复位"
} elseif ($Variant -eq "video") {
    Write-Host "  2) 先看板上的灯（DEBUG_LED=1）："
    Write-Host "     led[0]=pll_locked  led[1]=video_locked  —— led[1] 不亮先查视频 PLL，别去看 HDMI"
    Write-Host "  3) 再抓串口，应打印 banner + 各读回值 + SELFCHECK OK（共 187 字节，一次性，之后不再输出）："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 30"
    Write-Host "     SELFCHECK FAIL -> 问题在 CPU 侧写/读显存，与 TMDS 无关"
    Write-Host "  4) 接 HDMI 显示器，期望【8 条等宽竖条铺满整屏】，从左到右 白 黄 青 绿 品红 蓝 黑"
    Write-Host "     黑屏/无信号/雪花 的排查顺序见 rtl\video\video_top.v 文件头那 5 条"
} else {
    Write-Host "  2) 烧完开串口，应反复打印 KEY=0x00 LED=0x00；按 SW4..SW7 看对应灯亮"
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4"
    Write-Host "     （本变体 DEBUG_LED=0，led[0..7] 全是 GPIO，LED=KEY 对应关系成立）"
}
Write-Host ""
Write-Host "  详细步骤与排障：doc\board_bringup.md" -ForegroundColor DarkGray
