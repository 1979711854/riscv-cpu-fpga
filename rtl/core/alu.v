//============================================================================
// alu.v — 算术逻辑单元（纯组合）
// 功能：根据 alu_ctrl 对 a、b 做运算。
//   运算码常量见 defs.v（ALU_ADD/SUB/…），请保持与 alu_ctrl.v 输出一致。
// 端口：
//   a, b      = 两个 32 位操作数（来源由顶层 mux 决定）
//   alu_ctrl  = 4 bit 运算选择
//   result    = 运算结果
//   zero      = result==0（方便 beq/bne；也可不用）
// 设计要点：
//   - 纯组合：assign result = …；不要出现 clk。
//   - SLL/SRL/SRA 的移位量用 b[4:0]（5 bit，RV32 规定）。
//   - SLT/SLTU 输出 0 或 1（比较结果）；减法用 a-b；判断溢出不是本阶段重点。
//   - 若想减法/比较都统一走“a+~b+1”要小心 b 取反的时机（见 alu_ctrl）。
//============================================================================

//已完成 2026.9.9 zjn
`include "defs.v"

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_ctrl,
    output reg  [31:0] result,
    output wire        zero
);

    // TODO 实现：assign zero = (result==0)；
    // always @(*) case(alu_ctrl) … endcase
    assign zero = (result == 0);

    always @(*) begin
        case(alu_ctrl)
            4'b0000: result = a + b;
            4'b0001: result = a - b;
            4'b0010: result = a & b;
            4'b0011: result = a | b;
            4'b0100: result = a ^ b;
            4'b0101: result = a << b[4:0];//逻辑左移，右侧低位补0
            4'b0110: result = a >> b[4:0];//逻辑右移，左侧高位补0
            4'b0111: result = $signed(a) >>> b[4:0];//算术右移，需要先把a转为有符号数
            4'b1000: result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;//有符号整数比较，a<b则输出1
            4'b1001: result = (a < b) ? 32'd1 : 32'd0;//无符号整数比较
            default: result = 32'd0;
        endcase
    end

endmodule
