`timescale 1ns/1ps
// ============================================================================
// cpu_top_board —— 上板专用顶层（PDS 综合/布线的 top module）
// ----------------------------------------------------------------------------
// 与 cpu_top 的唯一区别：**不引出 pc[31:0] 和 done 这两个板级调试口**，
// 并把 cpu_top 的 key[7:4] 固定接 1（未按下）。
//
// 为什么要单独一层（踩过的坑）：
//   PDS 会把【未在 .fdc 里指定 LOC 的输出端口】自动布到 BANKR5 的任意引脚上 ——
//   实测 pc[0]→M2、pc[10]→M5、led[0]→P6 … 而本板 BANKR5 接了 SFP/HSST 等
//   高速接口，32 位输出乱布上去有驱动冲突风险。所以上板这一层不引出它们。
//
// 为什么不在 cpu_top 里直接删端口：
//   pc 是仿真侧的分析数据源 —— tb_coremark 的 +TRACE/+PROF 逐拍 dump 和
//   各测试台的 TIMEOUT 诊断（`$display("TIMEOUT (pc=0x%h)", pc)`）都依赖它，
//   删掉会废掉 doc/ila_analysis.md 里那套分析方法。故仿真仍用 cpu_top 原样。
//
// 板上只有 5 个按键，其中手册 KEY0（丝印 KEY1）已用作 resetn，
// 剩手册 KEY1..KEY4（丝印 KEY2..KEY5）→ key[3:0]。
// 引脚表见 pds/RV32I_1/RV32I_1.fdc 头部注释（手册 3.4.1 节）。
// 已实测：从左到右依次按 key[0..3]，串口输出 0x01/0x02/0x04/0x08。
// ============================================================================
module cpu_top_board (
    input  wire        clk,         // D18：板载 27MHz
    input  wire        resetn,      // C22：KEY0，低有效

    // ---- UART：经 CP2102 接 USB Type-C ----
    output wire        uart_tx,     // C24：FPGA_UART_TXD
    input  wire        uart_rx,     // B24：FPGA_UART_RXD

    // ---- GPIO ----
    output wire [7:0]  led,         // LED0..LED7，输出高电平点亮
    input  wire [3:0]  key          // KEY1..KEY4，按下 = 0
);
    cpu_top u_soc (
        .clk      (clk),
        .resetn   (resetn),

        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),

        .led      (led),
        .key      ({4'b1111, key}),   // 高位恒定"未按下"

        // 板级调试口：上板不引出（见文件头注释）
        .pc       (),
        .done     ()
    );
endmodule
