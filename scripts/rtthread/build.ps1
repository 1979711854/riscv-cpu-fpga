<#
============================================================================
 build.ps1 —— 编译 RT-Thread 应用到本 CPU（RV32IM / 32KB 统一存储器）
----------------------------------------------------------------------------
 用法：
   scripts\rtthread\build.ps1                只编译+链接，打印镜像占用
   scripts\rtthread\build.ps1 -Firmware      再出 mem.hex（可送 PDS 综合）

 为什么不用 scripts\run_coremark.ps1 那套：那个脚本是为"单文件 C 程序 + runtime\"
 设计的，源码扫描不递归。RT-Thread 是深目录树 + 多个 -I 路径，得自己走。

 [!] 32KB 是硬上限。每次编译都会打印 .text/.data/.bss 的占用和堆的剩余，
     超了会直接报错停下 —— 别等上板才发现。
============================================================================
#>
param(
    [switch]$Firmware,           # 出 mem.hex（送 PDS 用）
    [switch]$Clean,              # 先清干净再编
    [switch]$Sim,                # 按【仿真口径】编：27MHz + 短延时 + 出 hex
    [switch]$Atomic              # 硬件原子：rv32ima + atomic_riscv.c + RT_USING_STDC_ATOMIC
)

$ErrorActionPreference = "Stop"
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo    = Split-Path -Parent (Split-Path -Parent $Here)   # D:\riscv-cpu-fpga
$Tool    = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$GCC     = Join-Path $Tool "riscv-none-elf-gcc.exe"
$SIZE    = Join-Path $Tool "riscv-none-elf-size.exe"

$RtRoot  = Join-Path $Repo "third_party\rt-thread"
$Build   = Join-Path $Here "build"
$Elf     = Join-Path $Build "rtthread.elf"
$Map     = Join-Path $Build "rtthread.map"

if ($Clean -and (Test-Path $Build)) { Remove-Item $Build -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Build | Out-Null

# ---- 源文件 ----------------------------------------------------------------
# [!] scheduler_mp.c / cpu_mp.c 是 SMP（多核）用的，我们单核，靠 --gc-sections
#     丢掉；scheduler_up.c / cpu_up.c 才是走的那条路。
$srcDirs = @(
    (Join-Path $RtRoot "src"),
    # [!] src\klibc 必须单独列：上面的 Get-ChildItem 不递归，漏了它就会在链接期报
    #     undefined reference to `rt_memset' / `rt_vsnprintf' / `rt_strlen' 一大串。
    #     （RT-Thread 官方 src/SConscript 末尾就是用 SConscript 递归子目录的。）
    #     src\utest 是单元测试框架，不要。
    (Join-Path $RtRoot "src\klibc"),
    (Join-Path $RtRoot "libcpu\risc-v\common"),
    (Join-Path $Here   "bsp"),
    (Join-Path $Here   "app")
)
$cSrcs = @()
$sSrcs = @()
foreach ($d in $srcDirs) {
    if (-not (Test-Path $d)) { throw "源目录不存在：$d" }
    $cSrcs += Get-ChildItem $d -Filter *.c -File | ForEach-Object { $_.FullName }
    $sSrcs += Get-ChildItem $d -Filter *.S -File | ForEach-Object { $_.FullName }
}

# ---- 按 rtconfig.h 排除不编的源文件 ----------------------------------------
# 依据：RT-Thread 官方 src/SConscript 的 SrcRemove 规则，逐条对应到我们的 rtconfig.h。
# 我们没开的组件，其 .c 一律不编 —— 既省编译时间，也避免它们引用不存在的配置宏。
#   没开 RT_USING_SLAB      -> slab.c
#   没开 RT_USING_MEMPOOL   -> mempool.c
#   没开 RT_USING_MEMHEAP   -> memheap.c
#   没开 RT_USING_SIGNALS   -> signal.c
#   没开 RT_USING_DEVICE    -> device.c
#   没开 RT_USING_SMP       -> cpu_mp.c / scheduler_mp.c（单核走 *_up.c）
# [!] 原子默认走【软实现】：不编 atomic_riscv.c，rtatomic.h 的软分支
#     （rt_soft_atomic_*，关中断临界区）在单核下完全正确，不需要 A 扩展。
#   --Atomic 才切到硬件原子：-march=rv32ima + 编 atomic_riscv.c + 定义
#     RT_USING_STDC_ATOMIC（rttypes.h 会转成 _Atomic/stdatomic.h，gcc 用
#     amoadd.w / amoswap.w / lr.w+sc.w 生成）。这是【验证 A 扩展真的在固件里
#     跑起来】的那条口径：objdump 里必须能看到那些指令，否则就是没开对。
#   klibc 两份 vsnprintf 二选一：官方 SConscript 的规则是"没定义
#   RT_KLIBC_USING_VSNPRINTF_STANDARD 就用 tiny 版" —— 我们选 tiny，
#   32KB 下这是唯一合理的选择（std 版大一截，功能我们用不到）。
$excludeC = @('slab.c','mempool.c','memheap.c','signal.c','device.c','cpu_mp.c','scheduler_mp.c','rt_vsnprintf_std.c')
$atomicDefs = @()
if ($Atomic) {
    $march      = "rv32ima_zicsr_zifencei"
    $atomicDefs = @("-DRT_USING_STDC_ATOMIC")
    Write-Host "      [硬件原子] rv32ima + atomic_riscv.c + RT_USING_STDC_ATOMIC" -ForegroundColor Yellow
} else {
    $march      = "rv32im_zicsr_zifencei"
    $excludeC  += 'atomic_riscv.c'
}
$before = $cSrcs.Count
$cSrcs = $cSrcs | Where-Object { $excludeC -notcontains [IO.Path]::GetFileName($_) }
Write-Host ("      按 rtconfig.h 排除 $($before - $cSrcs.Count) 个源文件（未开启的组件）") -ForegroundColor DarkGray

# ---- 编译选项 --------------------------------------------------------------
$incs = @(
    (Join-Path $RtRoot "include"),
    (Join-Path $RtRoot "libcpu\risc-v\common"),
    (Join-Path $Here   "bsp")
) | ForEach-Object { "-I$_" }

# -Os                          体积优先（32KB 硬墙，这个最重要）
# -ffunction-sections/-fdata-sections + --gc-sections
#                              没被调用的函数/数据全部丢掉 —— RT-Thread 里
#                              大量代码我们根本用不到，不丢的话装不下
# -fno-builtin                 不要让 gcc 把循环换成 memset/memcpy（那些是 libc 的）
# -D__riscv_32e 不定义         我们用 RV32I，是完整 32 寄存器（32e 只有 16 个）
$cflags = @(
    # [!] 必须带 _zicsr：现代 RISC-V 规范把 CSR 指令从基础 I 里【拆出去了】，
    #     只写 rv32im 的话汇编器报 "unrecognized opcode 'csrr ...' extension 'zicsr' required"。
    #     RT-Thread 从上下文切换到 trap 分发到处要读写 CSR，所以这条不能省。
    #     _zifencei 同理（我们的 CPU 实现了 FENCE.I）。
    #     > 注意 CoreMark 那边用纯 "-march=rv32im" 也能过，因为它不碰 CSR —— 别照抄那边。
    "-march=$march", "-mabi=ilp32",
    "-Os", "-g",
    "-ffunction-sections", "-fdata-sections",
    "-fno-builtin", "-fno-common",
    "-Wall", "-Wno-unused-parameter",
    # [!] 这两个宏必须加，否则内核源码编不过：
    #   __RTTHREAD__           RT-Thread 自己的标识
    #   __RT_KERNEL_SOURCE__   RT-Thread v5 的"内部 API 封装门槛" —— rtsched.h 里
    #                          只有定义了它才声明 rt_sched_tick_increase 等内部函数，
    #                          不加就报 "implicit declaration of rt_sched_tick_increase"。
    #                          官方 BSP 是在 rtconfig.py 里传的（见 bsp/xuantie/*/rtconfig.py）。
    # [!] 不要加 -nostdinc：rttypes.h 要 <stdint.h>，那是工具链自带的头，
    #     -nostdinc 会把 gcc 的 include 目录一起去掉（实测报
    #     "fatal error: stdint.h: No such file or directory"）。
    #     不用 libc 的代码靠链接期的 -nostdlib 保证，头在不在不影响。
    "-D__RTTHREAD__", "-D__RT_KERNEL_SOURCE__"
) + $atomicDefs + $incs

# ---- 仿真口径：-Sim 时覆盖时钟与延时 ----
# [!] 仿真时钟是 **100MHz**，不是 27MHz —— sim/ 下所有测试台都写 `always #5 clk = ~clk`。
#     （CLAUDE.md 里说的"仿真 27MHz"指的是 UART_DIV 默认值 234 那套标称口径，
#      指的是别把 85.0051MHz 的 738 带进仿真；实际仿真节拍是 100MHz。）
#     mtime 数的是 CPU 时钟周期，所以 tick 换算必须按 100MHz，否则 tick 不是 1ms。
# APP_DELAY_MS 调小是为了让仿真跑得动：500ms @100MHz = 5000 万周期，几轮就几分钟。
if ($Sim) {
    $cflags += @("-DBOARD_SYSTEM_CLOCK_HZ=100000000", "-DAPP_DELAY_MS=5")
    $Firmware = $true
    Write-Host "      [仿真口径] 时钟 100MHz，乒乓节奏 5ms，并生成 hex" -ForegroundColor Yellow
}

$ldflags = @(
    # [!] 必须带 _zicsr：现代 RISC-V 规范把 CSR 指令从基础 I 里【拆出去了】，
    #     只写 rv32im 的话汇编器报 "unrecognized opcode 'csrr ...' extension 'zicsr' required"。
    #     RT-Thread 从上下文切换到 trap 分发到处要读写 CSR，所以这条不能省。
    #     _zifencei 同理（我们的 CPU 实现了 FENCE.I）。
    #     > 注意 CoreMark 那边用纯 "-march=rv32im" 也能过，因为它不碰 CSR —— 别照抄那边。
    "-march=$march", "-mabi=ilp32",
    "-nostartfiles", "-nostdlib", "-static",
    "-Wl,--gc-sections",
    "-Wl,--no-relax",              # 我们的 CPU 没实现 RVC/压缩指令，别让链接器塞压缩跳转
    "-T", (Join-Path $Here "bsp\link.ld"),
    "-Wl,-Map=$Map"
)

# ---- 编译 ------------------------------------------------------------------
Write-Host "[1/3] 编译 $($cSrcs.Count) 个 .c + $($sSrcs.Count) 个 .S ..." -ForegroundColor Cyan
$objs = @()
$idx = 0
foreach ($src in ($cSrcs + $sSrcs)) {
    $idx++
    $obj = Join-Path $Build ("{0:d3}_{1}.o" -f $idx, [IO.Path]::GetFileNameWithoutExtension($src))
    $objs += $obj
    if ($src -like "*.S") {
        & $GCC @cflags -c $src -o $obj
    } else {
        & $GCC @cflags -c $src -o $obj
    }
    if ($LASTEXITCODE -ne 0) { throw "编译失败：$src" }
}

# ---- 链接 ------------------------------------------------------------------
Write-Host "[2/3] 链接 ..." -ForegroundColor Cyan
& $GCC @ldflags @objs -o $Elf
if ($LASTEXITCODE -ne 0) { throw "链接失败（多半是 32KB 装不下，看上面的 undefined / overflow）" }

# ---- 占用报告 --------------------------------------------------------------
Write-Host "[3/3] 镜像占用：" -ForegroundColor Cyan
& $SIZE $Elf
$sizeLine = (& $SIZE $Elf | Select-Object -Last 1) -split '\s+' | Where-Object { $_ -ne '' }
$text = [int]$sizeLine[0]; $data = [int]$sizeLine[1]; $bss = [int]$sizeLine[2]

# RAM 占用 = .text + .data + .bss（统一存储器，代码和数据抢同一块 32KB）
$ramUsed = $text + $data + $bss
$ramTotal = 0xF000          # 可用 RAM = 0x0~0xEFFF = 60KB（栈顶 0xF000）
$stackTop = 0xFFF0
$heapEnd  = 0xF000
Write-Host ("      代码 .text = {0,6} 字节" -f $text)
Write-Host ("      数据 .data = {0,6} 字节   .bss = {1,6} 字节" -f $data, $bss)
Write-Host ("      静态占用   = {0,6} 字节 / {1} 字节 ({2:p1})" -f $ramUsed, $ramTotal, ($ramUsed / $ramTotal))
# [!] 堆的大小必须用【链接脚本算出来的 _end】，不能用 text+data+bss 相加 ——
#     后者没算段间对齐填充（link.ld 里 `. = ALIGN(0x1000)` 把数据段推到 0x1000），
#     2026-09-27 实测：相加减法给出 7151 字节，而真实 _end=0x6128、堆只有 3800 字节，
#     **差近一倍**。板上程序打印的 heap 值就是 3800，与 _end 一致。
$NM = Join-Path $Tool "riscv-none-elf-nm.exe"
$endAddr = 0
foreach ($l in (& $NM $Elf)) {
    if ($l -match '^([0-9a-fA-F]+)\s+\S\s+_end$') { $endAddr = [Convert]::ToInt32($matches[1], 16) }
}
if ($endAddr -gt 0) {
    Write-Host ("      堆可用     = {0,6} 字节  (_end 0x{1:X} .. __heap_end 0x{2:X})" -f ($heapEnd - $endAddr), $endAddr, $heapEnd)
} else {
    Write-Host "      [!] 取不到 _end 符号，堆大小无法准确报告" -ForegroundColor Yellow
}

if ($ramUsed -ge $ramTotal) {
    throw "镜像 $ramUsed 字节 >= 可用 RAM，装不下！先裁 rtconfig.h（关组件）或缩应用。"
}
if ($ramUsed -ge $heapEnd) {
    throw "静态占用 $ramUsed 已越过栈底 0x$('{0:X}' -f $heapEnd)，堆被挤没了。先裁代码。"
}

# ---- 出固件（可选）---------------------------------------------------------
if ($Firmware) {
    Write-Host "生成 hex 镜像 ..." -ForegroundColor Cyan
    # [!] elf2mem.py 的第二个参数是【输出目录】，不是文件名 ——
    #     写成 ...\mem.hex 的话它会建一个叫 mem.hex 的目录，然后"成功"退出。
    #     它一次产出 4 份：imem.hex / dmem.hex / mem.hex / tohost_addr.hex
    #     （仿真用 imem+dmem，PDS 综合用 mem.hex）
    & python (Join-Path $Repo "scripts\elf2mem.py") $Elf $Build
    if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }
    Write-Host "  -> $Build\{imem,dmem,mem}.hex" -ForegroundColor Green
}

Write-Host "完成：$Elf" -ForegroundColor Green
