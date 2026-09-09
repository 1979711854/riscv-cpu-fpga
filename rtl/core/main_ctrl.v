//============================================================================
// main_ctrl.v — 主译码器（组合，根据 opcode 出控制信号）
// 功能：根据 inst[6:0] 判断指令类别，输出全部控制信号。
// 输出含义（顶层据此连线）：
//   reg_write  寄存器堆写使能
//   mem_write  数据存储器写使能（sw 才为 1）
//   mem_read   数据存储器读使能（lw 才为 1）
//   mem_to_reg 回写源：0=alu结果，1=存储器读数据
//   alu_src    操作数 B 源：0=rs2，1=立即数 imm
//   alu_src_a  操作数 A 源：ASRC_RS1 / ASRC_ZERO(LUI) / ASRC_PC(AUIPC)
//   branch     B 型跳转标志
//   jal        JAL（pc+imm）
//   jalr       JALR（(rs1+imm)&~1）
//   alu_op     2 bit 粗 ALU 控制（见 defs.v / alu_ctrl.v）
// 设计要点：
//   - 用 case(inst[6:0])，逐类填控制字，像真值表一样核对：
//       R-type: reg_write=1, alu_src=0, alu_src_a=RS1, alu_op=10, …
//       lw    : reg_write=1, mem_read=1, mem_to_reg=1, alu_src=1, alu_op=00
//       sw    : mem_write=1, alu_src=1, alu_op=00
//       beq…  : branch=1, alu_src=0(比较由 branch_unit 做), alu_op=00
//       jal   : jal=1, reg_write=1, alu_src_a=PC? 见你打算把 rd 的 pc+4 放哪
//       jalr  : jalr=1, reg_write=1
//       lui   : reg_write=1, alu_src=1, alu_src_a=ZERO, alu_op=00
//       auipc : reg_write=1, alu_src=1, alu_src_a=PC,  alu_op=00
//       addi… : reg_write=1, alu_src=1, alu_src_a=RS1, alu_op=10
//   - 未识别 opcode 归为默认：全部拉 0（安全）。
//   - 逐条填好后，配合 alu_ctrl 一起，用 iverilog 全指令试一遍（W2 的回归）。
//============================================================================
`include "defs.v"

module main_ctrl (
    input  wire [6:0] opcode,
    output reg        reg_write,
    output reg        mem_write,
    output reg        mem_read,
    output reg        mem_to_reg,
    output reg        alu_src,
    output reg  [1:0] alu_src_a,
    output reg        branch,
    output reg        jal,
    output reg        jalr,
    output reg  [1:0] alu_op
);

    // TODO：case(opcode) 逐类赋值；default 全 0。
    // 建议把 9~10 个控制信号合成一个向量（如 {…}），用一条 case 一条 case 填，
    // 减少漏赋值造成的锁存器。

endmodule
