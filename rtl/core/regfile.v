`timescale 1ns/1ps
module regfile (
    input  wire        clk,
    input  wire        resetn,
    input  wire        we,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    input  wire [4:0]  rd,
    input  wire [31:0] wd,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);
    reg [31:0] rf [0:31];
    integer i;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            for (i = 0; i < 32; i = i + 1) rf[i] <= 32'd0;
        end else if (we && (rd != 5'd0)) begin
            rf[rd] <= wd;
        end
    end

    // write-first: same-cycle WB write is visible to ID read
    assign rdata1 = (rs1 == 5'd0) ? 32'd0 : ((we && rd == rs1) ? wd : rf[rs1]);
    assign rdata2 = (rs2 == 5'd0) ? 32'd0 : ((we && rd == rs2) ? wd : rf[rs2]);
endmodule
