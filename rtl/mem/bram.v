`timescale 1ns/1ps
// 行为级数据 RAM（综合用，替代 PDS BRAM IP）
// 端口与 ipcore/bram/bram.v 完全一致，可原位替换。
// 初始化：$readmemh 读 dmem.hex（放在 PDS 工程根目录 RV32I_1/）。
module bram (
    input  wire [31:0] wr_data,
    input  wire [12:0] wr_addr,
    input  wire        wr_en,
    input  wire        wr_clk,
    input  wire        wr_rst,
    input  wire [3:0]  wr_byte_en,
    input  wire [12:0] rd_addr,
    output reg  [31:0] rd_data,
    input  wire        rd_clk,
    input  wire        rd_rst
);
    (* syn_ramstyle = "block_ram" *) reg [31:0] mem [0:8191];

    initial begin
        $readmemh("dmem.hex", mem);
    end

    always @(posedge wr_clk) begin
        if (wr_en) begin
            if (wr_byte_en[0]) mem[wr_addr][ 7: 0] <= wr_data[ 7: 0];
            if (wr_byte_en[1]) mem[wr_addr][15: 8] <= wr_data[15: 8];
            if (wr_byte_en[2]) mem[wr_addr][23:16] <= wr_data[23:16];
            if (wr_byte_en[3]) mem[wr_addr][31:24] <= wr_data[31:24];
        end
    end

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) rd_data <= 32'd0;
        else        rd_data <= mem[rd_addr];
    end
endmodule
