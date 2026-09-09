//============================================================================
// branch_unit.v — 分支判定（组合）
// 功能：对 B 型指令比较 rs1、rs2，结合 funct3 判断是否跳转。
// 为什么单独成模块：beq/bne/blt/bge/bltu/bgeu 需要“等于/有符号小于/
//   无符号小于”多种比较，单独做比硬塞进 ALU 好理解、也好测。
// 端口：
//   rs1, rs2     = 两操作数（寄存器堆读出值）
//   funct3       = inst[14:12]（区分 beq/bne/blt/bge/bltu/bgeu）
//   branch_taken = 1 表示该分支成立
// 设计要点：
//   - 纯组合；先判断是否 B 型由顶层用 branch 信号门控，本模块只做条件比较：
//       beq(000) : rs1==rs2
//       bne(001) : rs1!=rs2
//       blt(100) : 有符号 rs1<rs2     （看最高位差异/用 $signed 思路）
//       bge(101) : 有符号 rs1>=rs2
//       bltu(110): 无符号 rs1<rs2
//       bgeu(111): 无符号 rs1>=rs2
//   - 顶层：next_pc = branch & branch_taken ? pc+imm_B : 正常 next。
//   提示：可拆两个比较器（等于判断 + 符号比较），符号比较用
//   {rs1[31]^rs2[31]} 处理符号不同时的取反关系，避免写出歧义。
//============================================================================
module branch_unit (
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    input  wire [2:0]  funct3,
    output wire        branch_taken
);

    // TODO：实现上面的比较逻辑

endmodule
