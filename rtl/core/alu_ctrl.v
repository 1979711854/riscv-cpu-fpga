//============================================================================
// alu_ctrl.v — ALU 精细译码（组合）
// 功能：结合 main_ctrl 的粗粒度 ALUOp 与指令的 funct3/funct7/opcode，
//       输出 4 bit 的 alu_ctrl 来控制 alu.v。
// 端口：
//   alu_op    = 2 bit（来自 main_ctrl，建议语义见 defs.v 注释）
//   funct3    = inst[14:12]
//   opcode5   = inst[5]（用来区分 R 型与 I 型：OP=1, OP_IMM=0）
//   funct7b5  = inst[30]（移位/加减区分 sub/sra 用）
//   alu_ctrl  = 4 bit 输出，编码见 defs.v 的 ALU_* 常量
// 设计要点（这是最容易写错的地方，建议先列出 funct3 真值表再 case）：
//   alu_op==00 -> 一律 ADD（lw/sw/lui/auipc/jal/jalr/addi 的路径）
//   alu_op==10 -> 按指令类型译码：
//     funct3=000: (opcode5 & funct7b5) ? SUB : ADD   // sub 仅 R 型有
//     funct3=001: SLL
//     funct3=010: SLT
//     funct3=011: SLTU
//     funct3=100: XOR
//     funct3=101: funct7b5 ? SRA : SRL
//     funct3=110: OR
//     funct3=111: AND
//   注意：OP_IMM 的 addi(000)/sltiu/slti/xori/ori/andi/slli/srli/srai
//   与 R 型共用上面的译码，靠 opcode5 区分 add/sub、srl/sra 等。

//============================================================================
`include "defs.v"

module alu_ctrl (
    input  wire [1:0] alu_op,   
    input  wire [2:0] funct3,
    input  wire       opcode5,  //inst[5]
    input  wire       inst30,  //指令第30位，inst[30]
    output reg  [3:0] alu_ctrl
);


    always@(*) begin
        case(alu_op)
            `ALU_OP_ADD: begin
            // ALU_OP_ADD：恒加法 
            // 适用于：lw, sw, lui, auipc, jal, jalr, addi
                alu_ctrl = `ALU_ADD;
            end

            `ALU_OP_SUB: begin
            // LU_OP_BRANCH：恒减法
            // 适用于：beq, bne, blt, bge, bltu, bgeu
                alu_ctrl = `ALU_SUB;
            end

            `ALU_OP_ALU: begin
                case(funct3)
                    3'b000: begin
                    // opcode5=1（R型）且 inst30=1 → SUB，否则 → ADD
                        alu_ctrl = (opcode5 & inst30) ? `ALU_SUB : `ALU_ADD;
                    end

                    3'b001: alu_ctrl = `ALU_SLL;
                    3'b010: alu_ctrl = `ALU_SLT;
                    3'b011: alu_ctrl = `ALU_SLTU;
                    3'b100: alu_ctrl = `ALU_XOR;

                    3'b101: begin
                    // inst30=1 → SRA，否则 → SRL
                        alu_ctrl = inst30 ? `ALU_SRA : `ALU_SRL;
                    end
                
                    3'b110: alu_ctrl = `ALU_OR;
                    3'b111: alu_ctrl = `ALU_AND;

                    default: alu_ctrl = `ALU_ADD;
                endcase
            end

            default: alu_ctrl = `ALU_ADD;
        endcase
    end
    
endmodule
