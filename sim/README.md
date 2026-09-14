# sim

功能仿真：testbench、程序镜像(hex)、波形。

## 测试台

| 层次 | 文件 | 说明 |
|---|---|---|
| 单元 | `tb_alu_inst.v` | ALU 指令级 |
| 单元 | `tb_alu_div.v` | 多拍除法器 |
| 单元 | `tb_uart_fifo.v` | UART 发送 + FIFO |
| 单元 | `tb_control.v` | 译码器（重点覆盖 FENCE/FENCE.I/ECALL/EBREAK） |
| 单元 | `tb_gpio.v` | GPIO（LED 输出 / 按键输入同步） |
| 单元 | `tb_uart_rx.v` | UART 接收（保序、FIFO 深度、帧错误丢弃、空读安全） |
| 集成 | `tb_riscv.v` | riscv-tests 全量回归（监控 tohost） |
| 集成 | `tb_coremark.v` | CoreMark 跑分 + 周期计数 |
| 集成 | `tb_demo.v` | 整个 SoC + 演示程序端到端 |

`tb_template.v` 是模板，不参与自动扫描。

## 存储器模型

`mem_model.vh` 是**共用**的行为级 `unified_mem`（指令+数据一块 RAM），由各集成测试台
`` `include `` 进来 —— 之所以不直接编 `rtl/mem/`：仿真需要从 plusarg 动态指定固件
（一个 vvp 跑几十个测试），而 `rtl/mem/` 那份是给 PDS 综合用的固定路径。

```
+IMEM=programs/imem.hex  +DMEM=programs/dmem.hex   # 拆分的两个镜像（一起用）
+IMEM=programs/mem.hex                             # 或用合并的单一镜像
```

## 跑法

```powershell
scripts\run_sim.ps1                       # 全部单测
scripts\run_sim.ps1 -Testbench sim/tb_gpio.v -NoWave
scripts\run_riscv_tests.ps1 -ElfDir <含 *.elf 的目录>
scripts\run_coremark.ps1 -Iter 1
scripts\run_demo.ps1
```

## 写测试台的两个坑（都踩过）

1. **Verilog 的字符串转义里没有 `\r`**（标准只有 `\n \t \\ \" \ddd`）。iverilog 会把
   `"\r\n"` 里的 `\r` 当成字面字符 `'r'`，期望串永远对不上。换行请用
   `localparam [15:0] CRLF = 16'h0D0A;` 拼。
2. **驱动同步信号要避开 posedge 竞态**。`ack=1; @(posedge clk); ack=0;` 这种写法里，
   任务恢复执行与 always 块采样是同一时间步内的不确定顺序，信号可能被提前清零而丢掉
   这一拍（表现为 FIFO 头永远不动）。在 **negedge 之后**驱动就没这个问题 ——
   真实硬件里这类信号来自同步逻辑，本来就是对齐的。

`sim/programs/` 里是生成的 hex/ELF，**不入库**。
