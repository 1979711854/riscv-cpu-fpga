# rtl

RTL 源码（Verilog-2001 / iverilog `-g2012` 可编译）。

```
core/     CPU 核
          core.v      5 级流水线数据通路（冒险、前递、分支冲刷、访存口、256 项 BHT 动态分支预测）
          control.v   主译码
          alu.v       算术逻辑 + M 扩展乘法
          divider.v   多拍迭代除法器
          imm_gen.v   立即数扩展
          regfile.v   寄存器堆 32×32
mem/      存储器（**仅 PDS 综合用**，仿真时由 testbench 通过 sim/mem_model.vh 提供同名模型）
          unified_mem.v   统一存储器：指令+数据共用一块双端口 BRAM
bus/      总线
          addr_map.vh     地址映射单点定义（RTL 侧唯一真相）
          mem_bus.v       存储总线：唯一的地址译码处 + 读数据 mux
periph/   外设
          uart_tx.v   UART 发送（1024 深 FIFO）
          uart_rx.v   UART 接收（16 深 FIFO，读弹出）
          gpio.v      8 位 LED 输出 + 8 位按键输入
top/      cpu_top.v   SoC 顶层，只做连线（仿真用）
          cpu_top_board.v  上板顶层（PDS 的 top）：包住 cpu_top，PLL 27→62.03MHz，不引出 pc/done
top.v     早期 LED 点灯练习工程顶层（保留，不在 PDS 源文件列表里）
```

## 两条改动前必读的约定

1. **取指补偿逻辑是承重的**：stall 时是 `imem_addr` 退回 `if_addr_d`，
   **不是 `pc_r` 后退**。搞反会复现"指令被复制执行"的老 bug。见 `core/core.v` PC 段注释。
2. **总线时序契约**（`bus/mem_bus.v` 头注释）：写通路零寄存器、读路径固定 1 拍。
   破坏任一条都会让 load 读到错值，且没有 stall 机制能救。

改完 RTL 请跑回归：riscv-tests 的 **49/1/0** 与 CoreMark 的**计时区间 363,515 拍**（两拍乘法器后的新基线，原 354,119）
（测试台总周期 1,457,776）必须同时不变。
详见 `doc/test_report_riscv-tests.md`。

> 上板还有一步容易漏：**同步固件**（`scripts\sync_firmware.ps1`）。PDS 综合读的是
> `pds/RV32I_1/mem.hex`，不是 `sim/programs/mem.hex`，而且不看时间戳 ——
> 不同步就会烧出一个「RTL 是新的、程序是旧的」的比特流，PDS 全程零报错。
