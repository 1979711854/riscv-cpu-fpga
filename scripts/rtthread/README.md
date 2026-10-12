# RT-Thread 移植（scripts/rtthread/）

把 **RT-Thread Nano（v5.3.0 内核子集）** 移植到本项目自制的 RV32IM CPU 上。

> 目录分工跟 `scripts/coremark_port/` 一个路子：
> - `third_party/rt-thread/` —— RT-Thread 源码子集（Apache-2.0，带 LICENSE）
> - `scripts/rtthread/` —— 我们的 BSP + 应用 + 构建脚本

## 当前状态（2026-09-27）

| 项 | 状态 |
|---|---|
| 编译链接 | **[OK] 通过** |
| 镜像占用 | `.text` 18,801 / `.data` 188 / `.bss` 2,528 = **21,517 字节 (65.7%)** |
| 堆剩余 | **7,155 字节** |
| **仿真验证** | **[OK] 通过** —— 见下面「仿真验证结果」 |
| **上板验证** | **[OK] 已上板**（2026-10-12 确认；判据同仿真：banner / tick delta 精确 / ping-pong 交替）。原始串口日志待补入 `doc/board/` |

## 上板（2026-09-27 起 `build_bitstream.ps1` 已支持 `rtthread` 变体）

**一条命令搞定固件 + 综合布线出比特流**（约 5 分钟）：

```powershell
scripts\build_bitstream.ps1 rtthread
```

它做的事（全部串好，不用手工分步）：编 RT-Thread 固件（**上板口径** 85.0051MHz /
乒乓 500ms）→ 同步进 PDS 工程 → **sha256 校验**（9498 行 / 4749 字）→ 综合布线出 `.sbit`。

> [!] **别用 `scripts\rtthread\build.ps1 -Sim` 的产物上板** —— 那是仿真口径
> （100MHz / 乒乓 5ms），上板会算错 tick。`build_bitstream.ps1 rtthread` 用的是正确口径。

**然后烧板并看串口**：

1. **插两根 USB 线** —— Jtag（FTDI，两个 COM 口）+ USB UART（CP2102 一个 COM 口）。
   **只插 Jtag，串口永远没输出**，这是最容易卡住的一步。
2. **PDS → TOOL → Programmer**，**必须重新 Browse** 选
   `pds\RV32I_1\generate_bitstream\cpu_top_board.sbit`
   （Programmer 会记住上次的文件；不重选极易烧成上一版）
3. **抓串口**：
   ```powershell
   scripts\serial_monitor.ps1 -Port COM4 -Seconds 30
   ```
   （COM 号认 `Silicon Labs CP210x` 那个；不带 `-Port` 会列出全部串口）

**期望看到**（板上时基 1ms、乒乓节奏 500ms，所以 30 秒能看约 30 轮）：

```
 \ | /
- RT -     Thread Operating System
 / | \     5.3.1 build ...
 2006 - 2026 Copyright by RT-Thread team

========================================
 RISC-V RV32IM @ 85.0051MHz  RT-Thread
========================================
[boot] tick period  = 1000 Hz
[boot] heap         = 7151 bytes
[pong] got semaphore, total 1
[ping] round 1  tick 500 (delta 500, expect 500)     <- delta 必须精确等于 500
[pong] got semaphore, total 2
[ping] round 2  tick 1000 (delta 500, expect 500)
...
```

**判据**（三条，与仿真一致）：

| 判据 | 期望 |
|---|---|
| 控制台 | 打出 RT-Thread banner（**串口不乱码** —— 顺带验了 85.0051MHz 下 `UART_DIV=738` 对上了）|
| **系统 tick** | `delta` **精确等于 500**，且连续多轮不漂 |
| **上下文切换** | ping / pong 交替，`total` 递增 |

**板级辅助判据**：`led[0]` = `pll_locked` = **丝印 D19**，常亮 = PLL 已锁（不亮说明 CPU 一直被复位）。

> [!] `led[2]` = `done` 在 RT-Thread 版上**不会亮** —— RT-Thread 的应用
> 没有写 `0xFFF8`（那是 CoreMark 的结束标志）。**别把它当成"没跑起来"。**
> （`led[1]` = `video_locked` 是视频 PLL 的锁定指示，RT-Thread 版不用管它。）

版本：**RT-Thread v5.3.1**（内核子集，`libcpu/risc-v/common` 的 RV32 通用移植层）。

## 怎么跑

```powershell
# 一条命令：编 RT-Thread -> 编测试台 -> 跑仿真 -> 报三个自检
scripts\rtthread\run_sim.ps1

# 只编不跑
scripts\rtthread\build.ps1              # 上板口径（85.0051MHz）
scripts\rtthread\build.ps1 -Firmware    # 再出 mem.hex（送 PDS 综合）
scripts\rtthread\build.ps1 -Sim         # 仿真口径（100MHz + 短延时 + 出 hex）
```

## 仿真验证结果（2026-09-27）

`scripts\rtthread\run_sim.ps1` 的输出：

```
 \ | /
- RT -     Thread Operating System
 / | \     5.3.1 build Sep 27 2026
 2006 - 2026 Copyright by RT-Thread team

========================================
 RISC-V RV32IM @ 85.0051MHz  RT-Thread
========================================
[boot] tick         = 0
[boot] tick period  = 1000 Hz
[boot] heap         = 3800 bytes
[boot] both threads started -- watching ping/pong alternate
[pong] got semaphore, total 1
[ping] round 1  tick 20 (delta 20, expect 20)
[pong] got semaphore, total 2
[ping] round 2  tick 40 (delta 20, expect 20)
...
=== PASS ===
```

| 自检 | 判据 | 结果 |
|---|---|---|
| 控制台通了 | 出现 RT-Thread banner | **[OK]** |
| **系统 tick 在走** | ping 的 tick 差值 == `APP_DELAY_MS`，且连续多轮 | **[OK]** `delta 20, expect 20` 精确相等 |
| **上下文切换正确** | ping / pong 靠信号量交替，次数成对 | **[OK]** ping 6 次 / pong 7 次 |

**这三条一起通过，说明**：异常/中断入口（`mtvec` → `SW_handler` → `rt_rv32_system_irq_handler`）
是对的、`mscratch` 中断栈切换是对的、`mstatus` 的保存恢复是对的、调度器能正常切线程。
**RT-Thread 的内核在这颗 CPU 上真的跑起来了。**

> [!] **仿真口径与上板不同**：仿真时钟 **100MHz**（`sim/` 下所有测试台都是 `always #5`），
> 所以 tick 换算按 100MHz；上板是 85.0051MHz。`-Sim` 会自动传对。
> （CLAUDE.md 里说的"仿真 27MHz"指的是 UART_DIV 默认值 234 那套**标称**口径 ——
> 意思是"别把 85.0051MHz 的 738 带进仿真"，不是说仿真节拍是 27MHz。）

## 目录

```
scripts/rtthread/
  bsp/
    rtconfig.h        RT-Thread 配置（手工裁剪到最小，不是 menuconfig 生成）
    board.c           板级初始化 / 控制台 / tick 中断
    board.h           MMIO 地址与中断号（源头是 rtl/bus/addr_map.vh）
    trap_gcc.S        中断入口（官方「RV32 移植指南」的方式一）
    startup.S         复位入口 _start → rtthread_startup()
    link.ld           链接脚本（32KB 布局 + __rt_rvstack）
    libc_shim.c       把编译器生成的 memset/memcpy 等接到 klibc
  app/
    main.c            验证程序（见下）
  build.ps1           构建脚本
```

## 移植的关键事实（都是查官方手册/源码 + 实测出来的）

### 为什么走「方式一」

`libcpu/risc-v/common/readme.md` 就是官方的**「RV32 移植指南」**，给了两种方式：

| | 方式一（非向量中断）| 方式二（向量中断）|
|---|---|---|
| 要写什么 | 只写 `rt_hw_do_after_save_above`（官方给了现成代码）| 还要写 `rt_trigger_software_interrupt` |
| 中断入口 | `mtvec = SW_handler`（direct 模式）| 向量表 |

**我们的 `mtvec` 只支持 direct 模式**（`csr_file.v` 写入时强制 `{addr[31:2], 2'b00}`），
所以走方式一 —— 恰好也是最省事的那条。

### 中断路径

```
mtvec = SW_handler                     ← board.c 里设置
  ↓
SW_handler（interrupt_gcc.S 提供）：
  关 MIE → 存线程上下文到线程栈 → csrrw sp,mscratch,sp 切到中断栈
  → rt_interrupt_enter → rt_hw_do_after_save_above（trap_gcc.S）
  → rt_rv32_system_irq_handler(mcause)（trap_common.c 提供，按 mcause&0x1F 分发）
  → rt_interrupt_leave → 按需切线程 → mret
```

- **`mscratch` 里存的是中断栈指针**，值是链接脚本里的 `__rt_rvstack`
- **中断号 `irq_id = mcause & 0x1F`** —— MTIP 是 `0x80000007` → **7** ✓ 与官方示例一致

### [!] 三个踩过的坑

1. **`-march` 必须带 `_zicsr`**
   现代 RISC-V 规范把 CSR 指令从基础 `I` 里**拆出去**了，只写 `rv32im` 汇编器会报
   `unrecognized opcode 'csrr ...' extension 'zicsr' required`。
   RT-Thread 从上下文切换到 trap 分发到处读写 CSR。
   **CoreMark 那边用纯 `-march=rv32im` 也能过，因为它不碰 CSR —— 别照抄那边。**

2. ~~**我们的 CPU 没有 A 扩展，必须用软原子**~~ **[OK] 已过时（2026-10-08 起 CPU 有 A 扩展）**
   RV32A（AMO/LR/SC）已实现（`rtl/core/amo_unit.v`），`atomic_riscv.c` 可以编入，
   RT-Thread `--Atomic` 构建已验证可用。软原子分支（`rt_soft_atomic_*`）保留作回退。
   > 历史：A 扩展之前 `amoswap.w`/`lr.w`/`sc.w` 编不过，做法是不编 `atomic_riscv.c`。

3. **`src/klibc` 必须单独列进源码目录**
   构建脚本的 `Get-ChildItem` 不递归，漏了它会在链接期报一大串
   `undefined reference to 'rt_memset' / 'rt_vsnprintf' / 'rt_strlen'`。
   （官方 `src/SConscript` 末尾就是用 SConscript 递归子目录的。）
   另外 `klibc` 里两份 `vsnprintf` 二选一，我们选 **tiny 版**（32KB 下唯一合理的选择）。

### [!] 编码坑：`.ps1` 必须带 UTF-8 BOM

PowerShell 5.1 读**无 BOM** 的 `.ps1` 时按 GBK 解析，中文注释会把语法搞崩
（实测报 `UnexpectedToken` / `MissingExpressionAfterToken`）。
本项目所有 `.ps1` 都带 BOM，新增的也要带。

## 验证程序做什么

`app/main.c` 三件事，正好覆盖移植是否成功的三个必要条件：

| # | 验证什么 | 怎么看 |
|---|---|---|
| 1 | 控制台通了 | 开机能打出 banner |
| 2 | **系统 tick 在走** | `rt_thread_mdelay(500)` 真的会等，且 `rt_tick_get()` 的差值 ≈ 500 |
| 3 | **上下文切换正确** | ping / pong 两个静态线程用信号量你一下我一下地交替，顺序错乱或卡死都说明有问题 |

用**静态线程**（`rt_thread_init` + 自己的栈数组）而不是 `rt_thread_create`：
32KB 下更省，且栈不够时链接期就报错，不会运行期莫名崩。

## 内存账（[!] 2026-10-10 起 RAM 为 64 KB；下表数字出自 32 KB 布局的构建 —— 拆线程/合入 CoreMark 前按 64 KB 重划并重测）

| 项 | 字节 | 说明 |
|---|---|---|
| 内核代码 `.text` | 18,805 | 只链接真正用到的（`-Os` + `--gc-sections`）|
| `.data` | 188 | 已初始化全局量 |
| `.bss` | 2,528 | 含两个静态线程栈 512×2 = 1KB |
| **静态合计** | **21,521** | **65.7%** |
| 堆 | 7,151 | `_end` .. `0xF000` |
| 中断栈 / 引导栈 | 0xF000..0xFFF0 | 4KB，栈顶 0xFFF0（兼容区在 0xFFF0 以上，不能越）|

> **余量不多但够用。** 代码一大堆就变小；不够时先裁 `rtconfig.h`（关组件），
> 别去动栈 —— 栈顶 0xFFF0 那条线是硬的。
