# RT-Thread 移植（scripts/rtthread/）

把 **RT-Thread Nano（v5.3.0 内核子集）** 移植到本项目自制的 RV32IM CPU 上。

> 目录分工跟 `scripts/coremark_port/` 一个路子：
> - `third_party/rt-thread/` —— RT-Thread 源码子集（Apache-2.0，带 LICENSE）
> - `scripts/rtthread/` —— 我们的 BSP + 应用 + 构建脚本

## 当前状态（2026-09-27）

| 项 | 状态 |
|---|---|
| 编译链接 | **[OK] 通过** |
| 镜像占用 | `.text` 18,805 / `.data` 188 / `.bss` 2,528 = **21,521 字节 (65.7%)** |
| 堆剩余 | **7,151 字节** |
| 仿真验证 | [ ] 待做 |
| 上板验证 | [ ] 待做 |

## 怎么编译

```powershell
scripts\rtthread\build.ps1              # 编译+链接，打印占用
scripts\rtthread\build.ps1 -Firmware    # 再出 mem.hex
```

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

2. **我们的 CPU 没有 A 扩展，必须用软原子**
   `libcpu/risc-v/common/atomic_riscv.c` 无条件用 `amoswap.w` / `lr.w` / `sc.w`，编不过。
   `rtatomic.h` 本来就有软实现分支：**没定义 `RT_USING_STDC_ATOMIC` 时走
   `rt_soft_atomic_*`**（`rt_inline` 写在头文件里，用关中断临界区做读改写）。
   所以正确做法是**不编 `atomic_riscv.c`**，而不是去凑 A 扩展。
   > 单核下这样是正确的。日后 CPU 若加了 A 扩展，删掉排除项即可用硬件原子（更快）。

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

## 内存账（32KB 怎么花的）

| 项 | 字节 | 说明 |
|---|---|---|
| 内核代码 `.text` | 18,805 | 只链接真正用到的（`-Os` + `--gc-sections`）|
| `.data` | 188 | 已初始化全局量 |
| `.bss` | 2,528 | 含两个静态线程栈 512×2 = 1KB |
| **静态合计** | **21,521** | **65.7%** |
| 堆 | 7,151 | `_end` .. `0x7000` |
| 中断栈 / 引导栈 | 0x7000..0x7FF0 | 4KB，栈顶 0x7FF0（兼容区在 0x7FF0 以上，不能越）|

> **余量不多但够用。** 代码一大堆就变小；不够时先裁 `rtconfig.h`（关组件），
> 别去动栈 —— 栈顶 0x7FF0 那条线是硬的。
