//============================================================================
// single_cycle.v — 单周期 RV32I 顶层（数据通路连线）
// 功能：把 pc/imem/regfile/imm_gen/alu/alu_ctrl/main_ctrl/branch_unit/dmem
//       按教材数据通路连起来，形成一个“一周期一条指令”的 CPU。
// 本文件先只给接口与【连线清单】，等你把各子模块写完、单测通过后，
// 再回来逐条例化。这样每步都能用 iverilog 单独验证。
//
// 外部接口：
//   clk, rst           时钟 / 复位
//   dbg_pc, dbg_inst   观察用输出（testbench 可据此打印/对比，方便调 bug）
//============================================================================
`include "defs.v"

module single_cycle (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] dbg_pc,     // 可选：当前 pc
    output wire [31:0] dbg_inst    // 可选：当前指令
);

    // ============ 连线清单（拿到子模块后照着例化） ============
    // 1) 取指：pc -> imem
    //    wire [31:0] pc, inst, next_pc;
    //    pc U0 (.clk(clk), .rst(rst), .stall(1'b0), .next_pc(next_pc), .pc(pc));
    //    imem U1 (.addr(pc), .inst(inst));
    //
    // 2) 拆字段（信号可 wire 直接连，不必显式再命名，但为了清晰建议命名）
    //    wire [4:0] rs1=inst[19:15], rs2=inst[24:20], rd=inst[11:7];
    //    wire [2:0] funct3=inst[14:12]; wire [6:0] opcode=inst[6:0];
    //
    // 3) 控制：main_ctrl / alu_ctrl
    //    按 opcode 出 reg_write…；按 alu_op+funct3+opcode[5]+inst[30] 出 alu_ctrl
    //
    // 4) 寄存器堆 + 立即数 + ALU 操作数 mux
    //    regfile U2(.clk(clk), .we(reg_write), .rs1(rs1), .rs2(rs2),
    //               .rd(rd), .wdata(wb_data), .rdata1(rs1_val), .rdata2(rs2_val));
    //    imm_gen U3(.inst(inst), .imm(imm));
    //    alu_src_a mux:  A = (alu_src_a==ASRC_ZERO)?0 :
    //                    (alu_src_a==ASRC_PC)?pc : rs1_val;
    //    alu_src    mux: B = alu_src ? imm : rs2_val;
    //    alu U4(.a(A), .b(B), .alu_ctrl(alu_ctrl), .result(alu_res), .zero(zero));
    //
    // 5) 数据存储器（lw/sw）
    //    dmem U5(.clk(clk), .we(mem_write), .re(mem_read), .addr(alu_res),
    //            .wdata(rs2_val), .rdata(mem_rdata));
    //
    // 6) 写回 mux + 跳转/分支目标
    //    wb_data = mem_to_reg ? mem_rdata : alu_res;   // rd 写回（jal 写 pc+4）
    //    jalr 目标: rs1_val + imm（然后最低位清 0）
    //    jal/branch 目标: pc + imm
    //    next_pc 选择（优先级：jalr > jal > 分支 > pc+4）
    //
    // 7) dbg_pc = pc; dbg_inst = inst;
    //
    // 注意点：
    //   - imem/dmem 的“字索引”要用地址的高位（如 addr[11:2]），别把整个
    //     32 位地址当数组下标（iverilog 会吃内存）。
    //   - branch 只有 B 型才参与 next_pc；branch_taken 与 branch 做与。
    //   - 一开始只求“能跑通”，加 dbg 打印帮你看状态，再谈精简。

    // TODO：待子模块就绪后例化并连线

    assign dbg_pc   = 32'b0;   // 占位，防止未驱动告警
    assign dbg_inst = 32'b0;

endmodule
