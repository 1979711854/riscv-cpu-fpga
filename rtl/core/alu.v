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

endmodule
