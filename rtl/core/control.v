`timescale 1ns/1ps
module control (
    input  wire [31:0] instr,
    output reg         reg_write,
    output reg         alu_a_sel,   // 0 = rs1, 1 = pc
    output reg         alu_b_sel,   // 0 = rs2, 1 = imm
    output reg  [4:0]  alu_op,
    output reg         mem_read,
    output reg         mem_write,
    output reg         branch,
    output reg         jump,
    output reg         jump_reg,
    output reg  [1:0]  wb_sel       // 0 = alu, 1 = mem, 2 = pc+4, 3 = imm(lui)
);
    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];

    always @(*) begin
        reg_write = 1'b0;
        alu_a_sel = 1'b0;
        alu_b_sel = 1'b0;
        alu_op    = 5'd0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        branch    = 1'b0;
        jump      = 1'b0;
        jump_reg  = 1'b0;
        wb_sel    = 2'b00;

        case (opcode)
            7'b0110011: begin  // OP_REG
                reg_write = 1'b1;
                if (funct7 == 7'b0000001) begin  // M 扩展
                    case (funct3)
                        3'b000: alu_op = 5'd10;  // MUL
                        3'b001: alu_op = 5'd11;  // MULH
                        3'b010: alu_op = 5'd12;  // MULHSU
                        3'b011: alu_op = 5'd13;  // MULHU
                        3'b100: alu_op = 5'd14;  // DIV
                        3'b101: alu_op = 5'd15;  // DIVU
                        3'b110: alu_op = 5'd16;  // REM
                        3'b111: alu_op = 5'd17;  // REMU
                        default: alu_op = 5'd0;
                    endcase
                end else begin
                    case (funct3)
                        3'b000: alu_op = funct7[5] ? 5'd1 : 5'd0;  // ADD / SUB
                        3'b001: alu_op = 5'd2;                     // SLL
                        3'b010: alu_op = 5'd3;                     // SLT
                        3'b011: alu_op = 5'd4;                     // SLTU
                        3'b100: alu_op = 5'd5;                     // XOR
                        3'b101: alu_op = funct7[5] ? 5'd7 : 5'd6;  // SRA / SRL
                        3'b110: alu_op = 5'd8;                     // OR
                        3'b111: alu_op = 5'd9;                     // AND
                        default: alu_op = 5'd0;
                    endcase
                end
            end

            7'b0010011: begin  // OP_IMM
                reg_write = 1'b1;
                alu_b_sel = 1'b1;
                case (funct3)
                    3'b000: alu_op = 5'd0;                     // ADDI
                    3'b001: alu_op = 5'd2;                     // SLLI
                    3'b010: alu_op = 5'd3;                     // SLTI
                    3'b011: alu_op = 5'd4;                     // SLTIU
                    3'b100: alu_op = 5'd5;                     // XORI
                    3'b101: alu_op = funct7[5] ? 5'd7 : 5'd6;  // SRAI / SRLI
                    3'b110: alu_op = 5'd8;                     // ORI
                    3'b111: alu_op = 5'd9;                     // ANDI
                    default: alu_op = 5'd0;
                endcase
            end

            7'b0000011: begin  // OP_LOAD
                reg_write = 1'b1;
                alu_b_sel = 1'b1;
                mem_read  = 1'b1;
                wb_sel    = 2'b01;
            end

            7'b0100011: begin  // OP_STORE
                alu_b_sel = 1'b1;
                mem_write = 1'b1;
            end

            7'b1100011: begin  // OP_BRANCH
                branch = 1'b1;
            end

            7'b1101111: begin  // OP_JAL
                reg_write = 1'b1;
                jump      = 1'b1;
                wb_sel    = 2'b10;
            end

            7'b1100111: begin  // OP_JALR
                reg_write = 1'b1;
                jump_reg  = 1'b1;
                alu_b_sel = 1'b1;
                wb_sel    = 2'b10;
            end

            7'b0110111: begin  // OP_LUI
                reg_write = 1'b1;
                wb_sel    = 2'b11;
            end

            7'b0010111: begin  // OP_AUIPC
                reg_write = 1'b1;
                alu_a_sel = 1'b1;
                alu_b_sel = 1'b1;
                alu_op    = 5'd0;
            end

            default: begin
                // OP_FENCE / OP_SYSTEM / illegal -> no-op
            end
        endcase
    end
endmodule
