//============================================================================
// pc.v — 程序计数器
// 功能：每个时钟沿把 next_pc 锁存为当前 pc；复位时 pc <= 0。
//       本模块是"顺序/跳转"的交接点：next_pc 由顶层根据分支/jump 决定。
// 设计要点：
//   - 同步复位 rst=1 时 pc 清零；复位释放后从 0 开始取指。
//   - stall 保留端口：单周期阶段始终拉 0，之后做流水线会用到"暂停"。
//============================================================================
`include "defs.v"

module pc (
    input  wire        clk,
    input  wire        rst,      // 同步复位（高有效）
    input  wire        stall,    // 暂停：stall=1 时 pc 保持（单周期置 0）
    input  wire [31:0] next_pc,  // 下一条指令地址（顶层算好）
    output reg  [31:0] pc        // 当前取指地址
);

    // TODO 实现：
    // always @(posedge clk) begin
    //    if (rst)   pc <= 32'b0;
    //    else if (!stall) pc <= next_pc;
    // end

endmodule
