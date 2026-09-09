//============================================================================
// imem.v — 指令存储器（独立，哈佛结构）
// 功能：按 pc 取 32 位指令。先用寄存器数组 + $readmemh 在仿真里加载 hex。
// 参数：
//   DEPTH     = 容量（字），默认 1024 条
//   INIT_FILE = 要加载的 hex 文件路径（如 "../../sim/programs/milestone_a.hex"）
// 端口：
//   addr = 字节地址（实际是 pc，用高若干位做索引）
//   inst = 读出的指令
// 设计要点：
//   - 仿真阶段用组合读（mem[addr[11:2]] 直接 assign），单周期时序简单。
//   - 提示：真正上板用 Pango 的 Block RAM IP 时，读会变成同步的，
//     到时再改（这是单周期->流水线、仿真->上板时要处理的差异之一）。
//   - $readmemh 读不到文件会告警并全部为 0，先确认路径。
//============================================================================
module imem #(
    parameter DEPTH     = 1024,
    parameter INIT_FILE = ""   // 例："sim/programs/prog.hex"，留空则全 0
) (
    input  wire [31:0] addr,
    output wire [31:0] inst
);

    reg [31:0] mem [0:DEPTH-1];

    // initial begin
    //   if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    // end

    // TODO：assign inst = mem[addr[11:2]];  // 字对齐；注意 addr 上下边界

endmodule
