# C 程序模板 —— 从这里开始写你自己的程序

把这个目录整个复制一份，改 `main.c`，就能跑在自己的 CPU 上。

```powershell
# 1) 复制
xcopy /E /I scripts\template scripts\myprog

# 2) 改 scripts\myprog\main.c

# 3) 编译 + 在电脑上跑一遍看输出（十几秒）
scripts\build_c.ps1 -Dir scripts\myprog -Run

# 4) 满意了就同步到 PDS 工程，回 PDS 重跑综合→布局布线→比特流
scripts\build_c.ps1 -Dir scripts\myprog -Sync
```

---

## 目录里的 4 个文件

| 文件 | 作用 | 要改吗 |
|---|---|---|
| `main.c` | **你的程序** | ✅ 改这里 |
| `uart.h` | 串口输出、延时、外设地址的小工具 | 一般不用 |
| `start.S` | 启动代码：设栈指针、清 `.bss`、调 `main` | 不用 |
| `link.ld` | 链接脚本：决定代码/数据/栈放哪 | 不用 |

**为什么需要 `start.S` 和 `link.ld`？** 因为这是裸机环境，没有操作系统帮你准备。
C 语言假定"栈已经就绪、未初始化的全局变量是 0"，这两件事得自己干。

---

## ⚠️ 五条硬约束

这是**裸机**（freestanding）环境，没有操作系统、没有 libc：

1. **`main` 不能 return** —— 没有 `exit()`。用 `__asm__ volatile("ebreak");` 停机，
   或者 `for(;;);` 挂住
2. **没有 `printf` / `malloc` / `free`** —— 输出用 `uart.h` 里的
   `uart_puts` / `uart_putc` / `uart_putdec` / `uart_puthex8`
   （`memcpy`/`memset` 可以用，gcc 会内联展开，不会真的调用库函数）
3. **栈很小** —— 32KB 以内，别在函数里开大数组
4. **不要依赖未对齐访问** —— 本 CPU 不支持，但 gcc 也不会生成，正常写就行
5. **没有堆** —— 要用 `malloc` 得自己实现一个简单的分配器

---

## 仿真比上板快得多

改代码 → `-Run` 看输出，比每次烧板子快一个数量级。但有两个注意点：

- **`delay_ms` 是真实时间**：1ms = 27000 周期，而仿真大约每秒只能跑 3 万周期。
  也就是说**仿真里 1ms 延迟 ≈ 1 秒实际等待**。调试阶段把延时去掉或调小。
- **程序结束得掉**：用 `ebreak` 停机，仿真会立刻结束；
  写成 `for(;;);` 的话要跑满 `-MaxCyc`（默认 2000 万周期）才停，很慢。

`tb_run` 的结束条件有三个：写 `done`（0x7FF8）、执行 `EBREAK`、或者到达周期上限。

---

## 外设怎么用

地址定义在 `rtl/bus/addr_map.vh`（RTL 侧唯一真相），`uart.h` 里取了常用的几个：

```c
#define UART_TX   0x80000008u   // W：发一个字符（取低字节）
#define TIMER     0x80000010u   // R：32 位周期计数器
#define GPIO      0x80000000u   // W：LED[7:0]   R：{key[7:0], led[7:0]}

REG8(UART_TX)  = 'A';            // 发一个字符（sb）
REG32(GPIO)    = 0x0F;           // 点亮低 4 个 LED
unsigned k = (~(REG32(GPIO) >> 8)) & 0xFF;   // 读按键，1 = 按下
```

更完整的例子看 `scripts/demo/demo.c`（读按键 → 写 LED → 串口打印）。

---

## 找不到问题的时候

| 现象 | 先查这个 |
|---|---|
| 板上啥都没反应 | `pds/RV32I_1/mem.hex` 存在吗？缺失时 PDS 会**静默**生成空 BRAM 的比特流 |
| 编译报找不到 `_bss_start` | `link.ld` 是不是没抄过来 |
| 仿真卡住不结束 | 程序是不是没走 `ebreak`；或调大 `-MaxCyc` |
| 打印乱码/丢字 | 波特率对不上（固定 115200）；或写 UART 太快，但 `uart_tx` 有 1024 深 FIFO，正常不会丢 |
