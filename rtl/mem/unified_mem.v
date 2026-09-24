`timescale 1ns/1ps
// ============================================================================
// unified_mem —— 统一（冯诺依曼）存储器 · 双端口 BRAM
// ----------------------------------------------------------------------------
// 指令与数据共用同一块存储器，A 口供取指、B 口供访存。这是 doc/spec.md 里
// 写的 modified-Harvard 的落地：软件看到的地址空间统一，核内部取指/访存通路
// 仍然分离（将来加 I/D Cache 时，两块 Cache 共用这份 backing store）。
//
// 为什么必须统一：riscv-tests 的 fence_i 测的是【自修改代码】—— 用 sh 把新
// 指令写进代码区，fence.i 后跳过去执行。哈佛结构（指令/数据各一块 BRAM）下
// store 永远改不到指令，该测试必然 TIMEOUT。
//
// 端口时序（mem_bus 与 core 都依赖）：
//   A 口：同步读，恰好 1 拍延迟，只读，无仲裁
//   B 口：同步读 1 拍 + 按字节写；写与读同址时读到【旧值】(read_first)，
//         与 Pango BRAM 的 read-during-write 默认模式一致
//
// 本文件是【PDS 综合用】的行为模型；仿真时由 testbench 提供同名模型
// （见 sim/mem_model.vh），所以 run_sim.ps1 显式不编译 rtl/mem/。
// ============================================================================
module unified_mem (
    // ---- A 口：取指（只读）----
    input  wire [12:0] a_addr,
    output reg  [31:0] a_rd_data,
    input  wire        a_clk,
    input  wire        a_rst,

    // ---- B 口：访存（读写）----
    input  wire [12:0] b_addr,
    input  wire [31:0] b_wr_data,
    input  wire        b_wr_en,
    input  wire [3:0]  b_byte_en,
    output reg  [31:0] b_rd_data,
    input  wire        b_clk,
    input  wire        b_rst
);
    // 8192 word = 32KB。若要扩容，必须同步改 mem_bus 与 core 里的 [14:2] 切片，
    // 否则高位被静默截断。
    (* syn_ramstyle = "block_ram" *) reg [31:0] mem [0:8191];

    // [重点] 这里【不要】加整数组清零的 for 循环。
    //   PDS 的循环展开上限是 2000 次（Verilog-4092: Loop limit 2000 exceeded），
    //   8192 次的清零循环会直接让 compile 失败。
    //   仿真侧需要清零是另一回事 —— 那是为了防 X 传播，写在 sim/mem_model.vh 里，
    //   iverilog 没有这个限制，而且本文件在仿真时根本不参与编译。
    //   硬件上 BRAM 由下面这行 $readmemh 初始化，未覆盖到的位置按上电默认值（0）。
    initial begin
        $readmemh("mem.hex", mem);
    end

    // A 口：同步读（非阻塞赋值 ⇒ 与写同址时读到旧值）
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a_rd_data <= 32'd0;
        else       a_rd_data <= mem[a_addr];
    end

    // B 口：按字节写 + 同步读。必须按字节写 —— fence_i 用两条 sh 分别改写同一
    // word 的低半字和高半字，整字写会连带打坏相邻半字。
    always @(posedge b_clk) begin
        if (b_wr_en) begin
            if (b_byte_en[0]) mem[b_addr][ 7: 0] <= b_wr_data[ 7: 0];
            if (b_byte_en[1]) mem[b_addr][15: 8] <= b_wr_data[15: 8];
            if (b_byte_en[2]) mem[b_addr][23:16] <= b_wr_data[23:16];
            if (b_byte_en[3]) mem[b_addr][31:24] <= b_wr_data[31:24];
        end
    end

    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) b_rd_data <= 32'd0;
        else       b_rd_data <= mem[b_addr];
    end
endmodule
