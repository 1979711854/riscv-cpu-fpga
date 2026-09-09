//============================================================================
// defs.v — 单周期 RV32I 全局常量（用 `include "defs.v" 引入）
// 所有文件共用这一份约定，避免模块间常数不一致
//============================================================================
`ifndef CPU_DEFS_V
`define CPU_DEFS_V

//------ RV32I 主 opcode（7 bit） ------
`define OP_LUI     7'b0110111
`define OP_AUIPC   7'b0010111
`define OP_JAL     7'b1101111
`define OP_JALR    7'b1100111
`define OP_BRANCH  7'b1100011
`define OP_LOAD    7'b0000011
`define OP_STORE   7'b0100011
`define OP_OP_IMM  7'b0010011
`define OP_OP      7'b0110011

//------ ALU 运算码（自己实现 alu 与 alu_ctrl 时保持一致）------
`define ALU_ADD  4'b0000    //加法
`define ALU_SUB  4'b0001    //减法
`define ALU_AND  4'b0010    //与
`define ALU_OR   4'b0011    //或
`define ALU_XOR  4'b0100    //异或
`define ALU_SLL  4'b0101    //逻辑左移
`define ALU_SRL  4'b0110    //逻辑右移
`define ALU_SRA  4'b0111    //算术右移
`define ALU_SLT  4'b1000    //有符号小于则置位
`define ALU_SLTU 4'b1001    //无符号小于则置位
// 若你还想加 ALU_PASS_B 之类（LUI 直接用），自行扩展并在 defs 说明

//------ 操作数 A 选择（main_ctrl 输出 alu_src_a）------
`define ASRC_RS1  2'b00   // 默认：rs1
`define ASRC_ZERO 2'b01   // LUI：0 + imm
`define ASRC_PC   2'b10   // AUIPC：pc + imm

//------ ALUOp（main_ctrl -> alu_ctrl 的粗粒度控制，2 bit）------
//   00 -> 恒 ADD（lw/sw/lui/auipc/jal/jalr/addi）
//   01 -> 恒 SUB（若分支想用减法判定，本设计有 branch_unit 可不用）
//   10 -> 需要按 funct3/funct7 细译码（R-type / I-type 算术）

`define ALU_OP_ADD  2'b00   // lw/sw/lui/auipc/jal/jalr/addi 只需要加法
`define ALU_OP_SUB  2'b01   // beq, bne, blt, bge, bltu, bgeu 分支比较，减法
`define ALU_OP_ALU  2'b10   // R型 I型运算，需要 funct3 译码

`endif
