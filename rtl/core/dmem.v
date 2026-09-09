//============================================================================
// dmem.v — 数据存储器（独立，哈佛结构；单周期阶段先只支持 lw/sw 字访问）
// 功能：读写数据。写地址 = ALU 结果（字节地址），写数据 = regfile rs2 值。
// 参数：DEPTH 容量（字）
// 端口：
//   clk       = 时钟
//   we        = 写使能（main_ctrl.mem_write）
//   re        = 读使能（main_ctrl.mem_read，单周期可恒 1/不用）
//   addr      = 字节地址（真正做字访问时索引用 addr[11:2]）
//   wdata     = 写数据（来自 rs2）
//   rdata     = 读数据（回写选通用）
// 设计要点：
//   - 单周期用“组合读”（rdata 直接 assign mem[addr[11:2]]），写法同 imem。
//   - 同步写：always @(posedge clk) if(we) mem[addr[11:2]] <= wdata;
//   - lb/lbu/lh/lhu/sb/sh 属于“字节/半字扩展”扩展点：先不做，留 TODO 注释，
//     等字访问跑通后再加（那一步会用到 addr[1:0] 与 wdata 移位、rdata 符号扩展）。
//============================================================================
`include "defs.v"

module dmem #(
    parameter DEPTH = 1024
) (
    input  wire        clk,
    input  wire        we,
    input  wire        re,      // 单周期可先恒 1
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
);

    reg [31:0] mem [0:DEPTH-1];

    // TODO：组合读 + 同步写，同 imem 注意

endmodule
