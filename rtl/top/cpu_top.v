`timescale 1ns/1ps
// ============================================================================
// cpu_top —— SoC 顶层
// ----------------------------------------------------------------------------
//    core ──访存口──> mem_bus ──> RAM / 兼容区 MMIO / 外设区
//                      │
//                      └──写选通──> uart_tx（外设在 rtl/periph/）
//
// 地址比较全部收敛到 mem_bus（见 rtl/bus/addr_map.vh），顶层不再自己比地址。
// ============================================================================
module cpu_top (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] pc,
    output wire        uart_tx,
    output wire        done
);
    // ---- core ↔ mem_bus 的访存口 ----
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;

    // ---- mem_bus ↔ 外设 ----
    wire        uart_tx_we;
    wire [31:0] periph_wdata;
    wire [31:0] cycle_cnt;          // 暂未使用（Step 3 接 TIMER 读回）

    // ---- 程序结束标志 ----
    // 两个来源：CoreMark 的 0x7FF8 协议（start.S 里 main 返回后写），
    // 以及程序执行 EBREAK。
    // 注意 EBREAK 是【软停机】：只置标志、不停 PC —— 程序应在 EBREAK 后跟一个
    // 自旋循环（riscv-tests 的 pass/fail 例程、CoreMark 的 start.S 都是这么做的）。
    wire        ebreak;
    wire        done_mmio;
    reg         halt;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)     halt <= 1'b0;
        else if (ebreak) halt <= 1'b1;
    end
    assign done = done_mmio | halt;

    mem_bus u_bus (
        .clk         (clk),
        .resetn      (resetn),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_byte_en (mem_byte_en),
        .mem_we      (mem_we),
        .mem_re      (mem_re),
        .mem_rdata   (mem_rdata),
        .gpio_we     (),                       // Step 3 接 gpio
        .uart_tx_we  (uart_tx_we),
        .uart_rx_ack (),                       // Step 3 接 uart_rx
        .periph_wdata(periph_wdata),
        .gpio_rdata  (32'd0),                  // Step 3 接 gpio
        .uart_rx_rdata(32'd0),                 // Step 3 接 uart_rx
        .done        (done_mmio),
        .cycle_cnt   (cycle_cnt)
    );

    core u_core (
        .clk         (clk),
        .resetn      (resetn),
        .pc          (pc),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_byte_en (mem_byte_en),
        .mem_we      (mem_we),
        .mem_re      (mem_re),
        .mem_rdata   (mem_rdata),
        .ebreak      (ebreak)
    );

    // UART 发送：兼容区 0x7FFC 与外设区 0x8000_0008 共用（见 mem_bus 的 uart_tx_we）。
    // 注意：UART busy 期间来的字符会被 FIFO 排队，不会丢（uart_tx 内含 1024 深 FIFO）。
    uart_tx u_uart (
        .clk     (clk),
        .resetn  (resetn),
        .tx_data (periph_wdata[7:0]),
        .tx_start(uart_tx_we),
        .tx      (uart_tx),
        .busy    ()
    );
endmodule
