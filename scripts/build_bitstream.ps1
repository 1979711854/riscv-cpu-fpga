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
    rtthread = RT-Thread Nano 版五子棋（T1/G3：render 高优 + AI 低优两条线程，
               AI 思考期间光标照闪；串口见 render/ai 两条 "thread running" + [hb] 心跳）
    video    = HDMI 彩条版（填显存画 8 条竖条 + 串口显存读回自检）
    gomoku   = 五子棋版（HDMI 出棋盘，4 个按键操作，串口打印 AI 节点数/耗时）
[!] 各变体会自动设置 cpu_top_board 的 DEBUG_LED 开关：
         coremark -> DEBUG_LED=1（led[1:0] 显示 pll_locked/done，看跑分状态）
         demo     -> DEBUG_LED=0（led[7:0] 全给 GPIO，恢复 LED=KEY 演示映射）
         rtthread -> DEBUG_LED=1（同 coremark；led[0]=pll_locked 仍是上板首要判据）
         video    -> DEBUG_LED=1（led[1]=video_locked，HDMI 黑屏先看这一颗）

.PARAMETER Iter
    仅 coremark 用，默认 4332。
[!] **改了流水线/取指逻辑、主频或编译选项必须重算**：
        ITER = 时钟频率 × 10s ÷ 每迭代周期数
    当前（双发射 + -O3 + 到达级重定向 + 任务C 的 EARLY_LD + A1 的 II=1 乘法器
    + **B1-RAS/BTB（rev1022）**，**本机实测**）：
        85,005,100 × 10 ÷ 229,597 = 3,702（恰好 10s），
    默认取 4332 → **11.70s（余量 17%）**，与本项目一贯的余量政策一致。
    > [!] 2026-10-14 B1-RAS 之前是 ITER=4280（232,345 拍口径，11.6961s）—— 仍有效但
    >     与归档位流对不上，别再用；**RAS 后每迭代 229,597 拍 ⇒ 必须重算**。
    > [!] 2026-10-13 A1 之前是 ITER=4116（241,633 拍口径）—— **用它会跑成 11.24s，仍有效但余量掉到 12%**，
    >     且与归档位流的对不上，别再用。
    > 历史：262,018 拍时代用 3796；282,777 用 3518（**别再用，那是阶段0 的账**）。
[!] 每迭代周期数**取决于配置与编译选项**（都是本机实测，**2026-10-14 已更新到 B1-RAS/BTB 之后**）：
    双发射 + EARLY_LD **229,597**（RAS 前 232,345；A1 前 241,633）/ 双发射 EARLY_LD=0 **252,730**（A1 前 262,018）
    / 单发射 **303,140**（A1 前 312,428）/ 双发射 + I+D Cache **235,628**（A1 前 243,933；**均未含 RAS，未重测**）。
    **板上跑的是双发射 + EARLY_LD=1**，所以算 ITER 用 229,597。
    改完 RTL 或编译选项要量它，跑仿真加 `+PROF`（默认脚本不打印 region cycles 这一行），
    读 `region cycles`；板上的 `Total ticks` 要再 ÷ 当前时钟。别把两个口径混用。
    > [!] 判据：`+PROF` 的 **`region cycles` 必须等于 `Total ticks`**。
    > 看到 **1** 就是 `portable_init` 里的版本号打印踩了 `0xFFF4`（见约定 42）。
[!] 主频 62.03 → 85.01 MHz（2026-10-04）是按"PDS 满足约束即收敛"实测定的：
    请求 85.01 → 达 91.87、slack +0.879；请求 99.79 → 失败。上限 ≈90，取 85 留 ~7% 余量。

.PARAMETER NoBuild
    只生成并同步固件，不跑 PDS 综合（想自己在 GUI 里点时用）。

.PARAMETER Cache
    综合【带 I/D Cache】版（高阶任务①）：把 cpu_top.v 的 DCACHE_EN / ICACHE_EN 临时改成 1，
    结束后自动还原（同 DEBUG_LED / DUAL_ISSUE 的做法 —— PDS 命令行传不了 -D 宏）。
    [!] Cache 会吃时序余量（A.1 假路径实测约 0.45 ns / 余量只有 0.525 ns），
        85 MHz 下大概率不收敛，通常要配合降频（改 ipcore/pll/pll.idf 的 STATIC_RATIO0）
        一起用 —— 降频记得同步 CLAUDE.md 约定 27 的 4 处常量 + ITER + expectLines。

.PARAMETER DCacheOnly
    [任务C 之后新增] 只开 **D-Cache**（DCACHE_EN=1 / ICACHE_EN=0）。
    用途：实测（2026-10-11）D-Cache 在 85 MHz 下**不再吃余量**（+0.151 ns），
    所以这一版是"85 MHz 下带 2 路组相联 D-Cache"的可交付位流；
    而 I+D 全开仍不收敛（−0.844 ns），要用 -Cache + 降频。

.PARAMETER Single
    综合【单发射】回退版（把 cpu_top.v 的 DUAL_ISSUE 临时改成 0，结束后自动还原）。
    默认是双发射(1)。
[!] 回退版会**自动**把期望值换成单发射口径（**303,140 / 280.4**，本机实测）——
    因为脚本按 DUAL_ISSUE 自动选，不会把双发射的秒数套到单发射上。
[!] 位流归档名要带配置后缀（`..._dual_...` / `..._single_...`）——
    两种位流的文件名和字节数完全一样，分不出来（这个坑踩过好几次）。

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

    [int]$Iter = 4332,

    [switch]$Single,      # 综合【单发射】回退版（DUAL_ISSUE=0）；结束后自动还原
    [switch]$Cache,
    [switch]$DCacheOnly,       # 综合【带 I/D Cache】版（高阶任务①）：DCACHE_EN=ICACHE_EN 临时改 1，结束还原

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
#       EE_TICKS_PER_SEC = 85,005,100  -> 4208 字（8416 行）  （2026-10-04 提频到 85MHz）
#     差 1 个字是**除数常量变了**导致编译器把 `/ EE_TICKS_PER_SEC` 的常量除法
#     优化成少一条指令 —— 与 ITER 无关（ITER=1500/1663/820/1 都一样是 4208）。
#     所以 guard 一旦挡住你，**先确认是不是又改了编译期常量**，别急着放宽。
#
# [!] 2026-10-10 三份固件各涨了一截 —— 原因是加了**版本自证**那行：
#     `[build] FW=... RTL=0x%x`（字符串 + ~20 字节代码），且 gomoku/coremark
#     的 `-march` 补了 `_zicsr`（`COMPILER_FLAGS` 字符串也长了几字节）。
#       coremark  4208 -> 4228 字
#       rtthread  4749 -> 9562 字   （gdb 符号/长字符串一起进 .rodata，涨得多）
#       gomoku    5604 -> 5634 字
#     这三个数就是用 `scripts\rtthread\build.ps1 -Firmware` / `scripts\gomoku\build.ps1`
#     各自的 elf2mem 输出**实测**出来的，不是估的。`demo` / `video` 没动过源码，
#     保持原值。
# [!] coremark 2026-10-11 由 16846 改成 17104：portable_fini 里加了 Cache 命中/缺失
#     计数器（0x8000_0018~0x24）的串口上报，+129 字。
# [!] rtthread 2026-10-13 由 9562 改成 10135 字（19124 -> 20270 行）：任务 T1/G3
#     把五子棋拆成 render + AI 两条线程，+AI 线程栈 4KB、+2 个邮箱、+game_t.ai_snap
#     （232B），静态占用 44,021 -> 51,193 B（/61,440）。实测值，非估计。
#     [!] 这个数必须用【非 -Sim】的 `rtthread\build.ps1 -Firmware` 量（本脚本正是这么调的）
#     —— `-Sim` 会改 INPUT_*/GOMOKU_AI_LEVEL 等常量，.text 差 8 字节、行数差 4
#     （20266 vs 20270）。拿仿真口径的数来填，守卫必挂。
# [!] 2026-10-14 更新 rtthread 的期望值，并改成【一组可接受值】：固件大小**取决于时钟口径**
#     （board.h 的 BOARD_SYSTEM_CLOCK_HZ 参与 tick/延时换算，会改变 .text）：
#       85.0051 MHz ⇒ 20274 行（10137 字）   ← 生产档
#       76.5052 MHz ⇒ 20276 行（10138 字）   ← 带 Cache 的降频档
#     另：横幅主频从写死的字面量改成从宏算（app/main.c）也让 .text 从 10135 → 10137/10138 字。
#     这个守卫拦下过两次"源码/口径变了但没意识到固件变了"的构建 —— **别顺手把守卫放宽到任意值**。
# [!] 2026-10-14 任务 T2/T3（标题屏多级菜单 + HUD 重排）：game.c/main.c 大改，
#     gomoku 与 rtthread 两个固件的 .text 尺寸都变了 —— 已用非 -Sim 的
#     `gomoku\build.ps1` / `rtthread\build.ps1 -Firmware` 重新量过 elf2mem 输出：
#       gomoku    5634 -> 6276 字（11268 -> 12552 行，+642 字）
#       rtthread  10137/10138 -> 10523/10524 字（20274/20276 -> 21046/21048 行）
#                 85.0051MHz ⇒ 21046 行（10523 字）← 生产档
#                 76.5052MHz ⇒ 21048 行（10524 字）← 带 Cache 的降频档
#     （.text：gomoku 25,104 B；rtthread 40,548 → 41,901/41,905 B，静态占用
#       52,761 B / 61,440 = 85.9%，仍留 5,144 B 堆）
$expectLines = @{ coremark = @(17104); demo = @(326); rtthread = @(21046, 21048);
                  video = @(758); gomoku = @(12552) }
$expectDesc  = @{ coremark = "8552 字"; demo = "163 字";
                  rtthread = "10523 字（85.0051MHz）/ 10524 字（76.5052MHz）";
                  video = "379 字"; gomoku = "6276 字" }

# DEBUG_LED 开关（见 rtl/top/cpu_top_board.v）：PDS 综合取 parameter 默认值，
# 命令行没法传 -D 宏，所以这里**直接改默认值再综合**，结束后还原。
#   coremark -> 1：led[1:0] 显示 pll_locked / done，板上能一眼看出卡在哪
#   demo     -> 0：led[7:0] 全给 GPIO，恢复"按开关位置重排"的 LED=KEY 映射
$topBoard = Join-Path $repo "rtl\top\cpu_top_board.v"
$debugLed = @{ coremark = 1; demo = 0; rtthread = 1; video = 1; gomoku = 1 }[$Variant]

# ---- 拟综合的双发射开关：从 cpu_top.v 读（这是"板上是哪一版"的唯一真相）----
# cpu_top_board 例化 cpu_top 时不传该参数，所以综合取 cpu_top.v 里的默认值。
# 打印它、并写进含 md5 的完成摘要，是为了让比特流口径可追溯：板上跑的必须是
# 双发射(1)；若这里读到 0，就与仿真默认(1)不一致 —— 正是"两边不是一个配置"的坑
# （2026-10-06 修）。注意：PDS 命令行传不了 -D 宏，只能靠这个参数默认值。
$cpuTopFile = Join-Path $repo "rtl\top\cpu_top.v"
$cpuTopTxt  = [System.IO.File]::ReadAllText($cpuTopFile)
if ($cpuTopTxt -notmatch 'parameter\s+DUAL_ISSUE\s*=\s*(\d+)') {
    Write-Host "!! 在 cpu_top.v 里找不到 parameter DUAL_ISSUE —— 版本不匹配，停下。" -ForegroundColor Red
    exit 1
}
$dualOrig  = [int]$Matches[1]   # cpu_top.v 里的原值（还原时要用）
$utf8NoBomCpuTop = New-Object System.Text.UTF8Encoding($false)
$dualIssue = $dualOrig

# ---- -Single：综合【单发射】回退版 ----
# [!] 和 DEBUG_LED 同一个理由：PDS 综合取 parameter 默认值、命令行传不了 -D 宏，
#     所以只能"改默认值 → 综合 → 还原"。以前切回退版要【手改 cpu_top.v:52】——
#     那正是"配置靠人记"这类坑的温床（2026-10-06 加）。
#     还原在下面的 finally 里，和 DEBUG_LED 一起。
$cpuTopOrig = $cpuTopTxt
if ($Single -and $dualIssue -ne 0) {
    [System.IO.File]::WriteAllText($cpuTopFile,
        ($cpuTopTxt -replace 'parameter\s+DUAL_ISSUE\s*=\s*\d+', 'parameter DUAL_ISSUE = 0'),
        $utf8NoBomCpuTop)
    $dualIssue = 0
    Write-Host "    -Single：cpu_top.v 的 DUAL_ISSUE 临时改为 0（结束时自动还原）" -ForegroundColor Green
}

# ---- -Cache：综合【带 I/D Cache】版（高阶任务①）----
# [!] 同 DUAL_ISSUE/DEBUG_LED：PDS 命令行传不了 -D 宏，只能"改 parameter 默认值 →
#     综合 → 还原"。还原在下面的 finally 里。
$cacheOrigTxt = [System.IO.File]::ReadAllText($cpuTopFile, $utf8NoBomCpuTop)
if ($Cache -or $DCacheOnly) {   # [!] -DCacheOnly 必须【单独可用】：只传它、不传 -Cache 时也要进这里
    if ($cacheOrigTxt -notmatch 'parameter\s+DCACHE_EN\s*=\s*\d+' -or
        $cacheOrigTxt -notmatch 'parameter\s+ICACHE_EN\s*=\s*\d+') {
        Write-Host "!! 在 cpu_top.v 里找不到 parameter DCACHE_EN / ICACHE_EN —— 版本不匹配，停下。" -ForegroundColor Red
        exit 1
    }
    $cacheNewTxt = $cacheOrigTxt -replace 'parameter\s+DCACHE_EN\s*=\s*\d+', 'parameter DCACHE_EN = 1'
    if ($DCacheOnly) {
        # 只开 D：I-Cache 那条取指链在 85 MHz 下仍不收敛（实测 −0.844 ns）
        $cacheNewTxt = $cacheNewTxt -replace 'parameter\s+ICACHE_EN\s*=\s*\d+', 'parameter ICACHE_EN = 0'
        Write-Host "    -DCacheOnly：cpu_top.v 的 DCACHE_EN=1 / ICACHE_EN=0（结束时自动还原）" -ForegroundColor Green
    } else {
        $cacheNewTxt = $cacheNewTxt -replace 'parameter\s+ICACHE_EN\s*=\s*\d+', 'parameter ICACHE_EN = 1'
        Write-Host "    -Cache：cpu_top.v 的 DCACHE_EN / ICACHE_EN 临时改为 1（结束时自动还原）" -ForegroundColor Green
    }
    # [!] 2026-10-12 实踩：这一行曾经被误删 ⇒ 脚本只【打印】"DCACHE_EN=1"、**根本没改文件**，
    #     于是"带 Cache 的位流"其实是 Cache 全关版（网表里 dcache 0 处、时序数也是关着的那组），
    #     而**日志、文件名、md5 全都看不出来**。归档前必须验网表（见 CLAUDE.md 约定 46）。
    [System.IO.File]::WriteAllText($cpuTopFile, $cacheNewTxt, $utf8NoBomCpuTop)
    Write-Host "    [!] 固件侧要把 0x8000_0018~0x24 的命中/缺失计数打出来看效果" -ForegroundColor DarkGray
}

# 每迭代周期数（取决于配置与编译选项）—— 别再写死：算 ITER 和算得分都用它
# [阶段0+1 本机实测] 双发射 262,018（-O3 282,777 → 阶段1 再 −7.34%）；
# 单发射 312,428（-O3 + 阶段1；-O2 时代是 363,515）。
# [A1] 2026-10-13 更新到乘法器 II=1 之后：双发射 + EARLY_LD=1 是 232,345；单发射 303,140。
#   （A1 前是 241,633 / 312,428 —— 别再拿旧值算期望 ticks。）
# [B1-RAS/BTB] 2026-10-14：双发射 + EARLY_LD=1 降到 **229,597**（−1.18%，region commit 逐位不变）；
#   单发射/其他配置未重测，暂留 A1 值。
$cpiCycles = if ($dualIssue -eq 1) { 229597 } else { 303140 }
$dualNote  = if ($dualIssue -eq 1) { "双发射（与仿真默认一致）" } else { "单发射（-Single 回退版）" }

Write-Host ""
Write-Host "=== 构建【$Variant】版比特流 ===" -ForegroundColor Cyan
Write-Host "    DUAL_ISSUE = $dualIssue  $dualNote"
if ($dualIssue -ne 1 -and -not $Single) {
    Write-Host "!! 本次将综合【单发射】比特流(DUAL_ISSUE=0)，而仿真脚本默认跑双发射(1)。" -ForegroundColor Yellow
    Write-Host "   要烧回退版请用 -Single（它临时改、结束自动还原）；" -ForegroundColor Yellow
    Write-Host "   否则说明 cpu_top.v:52 被手工改过 —— 改回 1 再跑。" -ForegroundColor Yellow
}
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
        # [!] 默认（不带 -Sim）就是【上板口径】：时钟 85.0051MHz、延时 500ms。
        #     带 -Sim 会变成仿真的 100MHz/5ms —— 那个不能上板。
        & (Join-Path $PSScriptRoot "rtthread\build.ps1") -Firmware
        if ($LASTEXITCODE -ne 0) { throw "RT-Thread 固件编译失败" }
        Copy-Item (Join-Path $PSScriptRoot "rtthread\build\*.hex") `
                  (Join-Path $repo "sim\programs\") -Force
        # [!] 别在这里写死频率（2026-10-14 踩过：76.5 档的构建也打"85.0051MHz"）。
        #     固件的时钟口径真相在 scripts\rtthread\bsp\board.h 的 BOARD_SYSTEM_CLOCK_HZ，
        #     而降频时它是被改过的 —— 直接读出来打印，别再写字面量（CLAUDE.md 约定 58）。
        $rtClk = (Select-String -Path (Join-Path $PSScriptRoot "rtthread\bsp\board.h") `
                                 -Pattern 'define\s+BOARD_SYSTEM_CLOCK_HZ\s+(\d+)u').Matches[0].Groups[1].Value
        Write-Host ("    RT-Thread 固件已放进 sim\programs\（按 board.h 的 $rtClk Hz 口径编译）") -ForegroundColor Green
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
    if ($expectLines[$Variant] -notcontains $lines) {
        Write-Host "!! mem.hex 行数与预期不符：期望 $(($expectLines[$Variant] | Sort-Object) -join ' 或 ')（$($expectDesc[$Variant])），实际 $lines" -ForegroundColor Yellow
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
    # 同样还原 cpu_top.v 的 DCACHE_EN / ICACHE_EN（-Cache 时临时改过）
    if ($Cache -and $cacheOrigTxt -ne $null) {
        [System.IO.File]::WriteAllText($cpuTopFile, $cacheOrigTxt, $utf8NoBomCpuTop)
        Write-Host "    （DCACHE_EN / ICACHE_EN 已还原为 0）" -ForegroundColor DarkGray
    }
    # 同样还原 cpu_top.v 的 DUAL_ISSUE（-Single 时临时改过）
    if ($cpuTopOrig -ne [System.IO.File]::ReadAllText($cpuTopFile, $utf8NoBom)) {
        [System.IO.File]::WriteAllText($cpuTopFile, $cpuTopOrig, $utf8NoBom)
        Write-Host "    （DUAL_ISSUE 已还原为 $dualOrig）" -ForegroundColor DarkGray
    }
}

$fi = Get-Item $sbit
$md5 = (Get-FileHash $sbit -Algorithm MD5).Hash.Substring(0, 8).ToLower()

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "  比特流：$sbit"
Write-Host "  配置  ：DUAL_ISSUE=$dualIssue [$dualNote]"
Write-Host "  时间  ：$($fi.LastWriteTime)   大小：$([math]::Round($fi.Length/1MB,2)) MB   md5：$md5..."
Write-Host ""
Write-Host "接下来：" -ForegroundColor Cyan
Write-Host "  1) PDS -> TOOL -> Programmer，器件选 PG2L200H，"
Write-Host "     配置文件就是上面这个路径（**别用备份/旧文件**）"
if ($Variant -eq "coremark") {
    Write-Host "  2) 烧完立刻抓串口（一轮约 12 秒，慢一拍就错过）："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60"
    $expTicks = $Iter * $cpiCycles
    Write-Host " [重点] 板上时钟 85.0051MHz，期望 Total ticks ≈ $expTicks -> /85,005,100 = $([math]::Round($expTicks / 85005100, 2)) s"
    Write-Host "       （**别再用 ÷62.03e6 / ÷49.89e6 / ÷45e6 / ÷27e6** —— 那都是旧口径。以 PDS 时序报告里的实际频率为准）"
    Write-Host "       得分预期：85.0051e6 / $cpiCycles = $([math]::Round(85005100 / $cpiCycles, 1)) CoreMark（DUAL_ISSUE=$dualIssue；单发射 280.4，双发射 370.2）"
} elseif ($Variant -eq "rtthread") {
    Write-Host "  2) 烧完开串口，应打印 RT-Thread banner + gomoku 的 render/AI 两条线程："
    Write-Host "     powershell -ExecutionPolicy Bypass -File scripts\serial_monitor.ps1 -Port COM4 -Seconds 60"
    Write-Host " [重点] 四条判据：banner 出来 / [boot] gomoku render thread running /"
    Write-Host "       [boot] gomoku ai thread running / [hb] alive 且 rt_tick 单调递增"
    Write-Host "       （[hb] 能挤进来 = render 没独占 CPU，这正是 G3 的前提）"
    Write-Host "       G3 真效果（AI 思考期间画面/光标不卡）要按键实测，见"
    Write-Host "       doc\reports\2026-10-13_T1_rtthread_g3_checklist.md 的 Stage 3"
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
