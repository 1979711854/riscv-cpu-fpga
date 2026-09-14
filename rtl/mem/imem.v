`timescale 1ns/1ps
// 行为级指令 ROM（综合用，替代 PDS BRAM IP）
// 端口与 ipcore/imem/imem.v 完全一致，可原位替换。
// 初始化：$readmemh 读 imem.hex（放在 PDS 工程根目录 RV32I_1/）。
module imem (
    input  wire [12:0] a_addr,
    input  wire [31:0] a_wr_data,
    output reg  [31:0] a_rd_data,
    input  wire        a_wr_en,
    input  wire        a_rst,
    input  wire        a_clk,
    input  wire [12:0] b_addr,
    input  wire [31:0] b_wr_data,
    output reg  [31:0] b_rd_data,
    input  wire        b_wr_en,
    input  wire        b_rst,
    input  wire        b_clk
);
    (* syn_ramstyle = "block_ram" *) reg [31:0] mem [0:8191];

    initial begin
        $readmemh("imem.hex", mem);
    end

    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a_rd_data <= 32'd0;
        else       a_rd_data <= mem[a_addr];
    end

    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) b_rd_data <= 32'd0;
        else       b_rd_data <= mem[b_addr];
    end
endmodule
