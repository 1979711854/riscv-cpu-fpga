`timescale 1ns/1ps
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  alu_op,
    output reg  [31:0] result
);
    // M 扩展：64 位乘法中间结果（符号/无符号），乘法映射到 DSP
    wire signed [63:0] sa_ext = $signed({{32{a[31]}}, a});
    wire signed [63:0] sb_ext = $signed({{32{b[31]}}, b});
    wire        [63:0] ub_ext = {32'd0, b};
    wire        [63:0] mul_signed   = sa_ext * sb_ext;      // MUL/MULH
    wire        [63:0] mul_signed_u = sa_ext * ub_ext;      // MULHSU
    wire        [63:0] mul_unsigned = {32'd0, a} * ub_ext;  // MULHU

    // DIV/DIVU/REM/REMU (alu_op 14-17) 由 core.v 的多拍迭代除法器接管，
    // ALU 不再做组合除法（32 位单拍除法会形成 ~32 级连减的关键路径，拖垮 Fmax）。

    always @(*) begin
        case (alu_op)
            4'd0  : result = a + b;
            4'd1  : result = a - b;
            4'd2  : result = a << b[4:0];
            4'd3  : result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            4'd4  : result = (a < b) ? 32'd1 : 32'd0;
            4'd5  : result = a ^ b;
            4'd6  : result = a >> b[4:0];
            4'd7  : result = $signed(a) >>> b[4:0];
            4'd8  : result = a | b;
            4'd9  : result = a & b;
            // M 扩展（乘法）
            5'd10 : result = mul_signed[31:0];    // MUL
            5'd11 : result = mul_signed[63:32];   // MULH
            5'd12 : result = mul_signed_u[63:32]; // MULHSU
            5'd13 : result = mul_unsigned[63:32]; // MULHU
            default : result = a + b;
        endcase
    end
endmodule
