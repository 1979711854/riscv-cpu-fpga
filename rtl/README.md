# rtl

RTL 源码（Verilog / SystemVerilog）。按模块组织，建议先建如下骨架：

- `core/`      CPU 核心（取指 IF、译码 ID、执行 EX、访存 MEM、写回 WB、寄存器堆、CSR 等）
- `periph/`    片上外设（如需要，UART/GPIO 等）
