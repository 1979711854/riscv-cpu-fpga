`timescale 1ns/1ps
module cpu_top (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] pc,
    output wire        uart_tx,
    output reg         done
);
    wire        mem_write;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;

    // 32 位周期计数器（27MHz 自由跑），映射 0x7FF4，供 CoreMark get_time() 读
    reg [31:0] cycle_cnt;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) cycle_cnt <= 32'd0;
        else         cycle_cnt <= cycle_cnt + 32'd1;
    end

    core u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .store_we(mem_write), .store_addr(mem_addr), .store_wdata(mem_wdata),
        .mmio_rd_data(cycle_cnt)
    );

    // CoreMark 字符输出：写 0x7FFC 的低字节送 UART（uart_send_char）
    // 注意：若 UART busy 期间又来一个字符会被忽略，CoreMark 打印间隔大，实际不会撞。
    wire char_store = mem_write && (mem_addr == 32'h7FFC);
    uart_tx u_uart (
        .clk(clk), .resetn(resetn),
        .tx_data (mem_wdata[7:0]),
        .tx_start(char_store),
        .tx      (uart_tx),
        .busy    ()
    );

    // 结束标志：start.S 里 main 返回后写 0x7FF8=1，拉高 done 接 LED 指示跑完
    always @(posedge clk or negedge resetn) begin
        if (!resetn) done <= 1'b0;
        else if (mem_write && (mem_addr == 32'h7FF8) && (mem_wdata == 32'd1))
            done <= 1'b1;
    end
endmodule
