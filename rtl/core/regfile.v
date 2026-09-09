//============================================================================
// regfile.v — 32 x 32 寄存器堆（RV32I）
// 功能：2 个异步读口（rs1/rs2）+ 1 个同步写口（rd）。x0 恒为 0。
//       单周期里读口是组合的（本周期就能用 rs1/rs2 的值）。
// 端口含义：
//   rs1/rs2 = 读地址（来自指令字段）
//   rd      = 写地址（来自指令字段，写回目标）
//   we      = 写使能，接 main_ctrl 的 reg_write
//   wdata   = 写数据（来自顶层 mem_to_reg 的 mux：alu结果 or 存储器读）
//   rdata1/2 = 读出值
// 设计要点：
//   - x0 不可写、读出恒 0（硬件保证：读 x0 给 0，写 rd==5'd0 时忽略）。
//   - 单周期"先读后写"不冲突：同一周期既有读又写同一寄存器时按写后读？
//     （单周期中同步写发生在边沿，组合读发生在边沿前，天然=旧值；
//      若你的程序同一周期又读又写同一 reg，行为你要想清楚，可留待流水线处理）
//============================================================================
module regfile (
    input  wire        clk,
    input  wire        we,       // 写使能（reg_write）
    input  wire [4:0]  rs1,      // 源寄存器1 地址
    input  wire [4:0]  rs2,      // 源寄存器2 地址
    input  wire [4:0]  rd,       // 目的寄存器地址
    input  wire [31:0] wdata,    // 写回数据
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);

    reg [31:0] rf [0:31];        // 32 个 32 位寄存器

    // TODO 实现：
    // 组合读： rdata1 = (rs1==0)?0:rf[rs1]; rdata2 同理
    // 同步写： always @(posedge clk) if(we && rd!=0) rf[rd] <= wdata;

endmodule
