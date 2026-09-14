`timescale 1ns/1ps
// CoreMark 运行测试台：周期计数 + UART 字符拦截 + tohost 结束判分
//   - core 对 0x7FFC 的 store 视为输出一个字符（uart_send_char）
//   - core 对 0x7FF8 的 store 1 视为结束（start.S 里 main 返回后写）
//   - CoreMark/MHz = ITERATIONS * 1e6 / 总周期数

module imem (
    input  wire [12:0] a_addr,
    input  wire [31:0] a_wr_data,
    output reg  [31:0] a_rd_data,
    input  wire        a_wr_en,
    input  wire        a_clk,
    input  wire        a_rst,
    input  wire [12:0] b_addr,
    input  wire [31:0] b_wr_data,
    output reg  [31:0] b_rd_data,
    input  wire        b_wr_en,
    input  wire        b_clk,
    input  wire        b_rst
);
    reg [31:0] mem [0:8191];
    reg [1023:0] hexpath;   // 由 +IMEM= / +DMEM= 覆盖；默认相对运行目录(sim/)
    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 32'd0;
        if (!$value$plusargs("IMEM=%s", hexpath)) hexpath = "programs/imem.hex";
        $readmemh(hexpath, mem);
    end
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a_rd_data <= 32'd0;
        else begin
            if (a_wr_en) mem[a_addr] <= a_wr_data;
            a_rd_data <= mem[a_addr];
        end
    end
    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) b_rd_data <= 32'd0;
        else begin
            if (b_wr_en) mem[b_addr] <= b_wr_data;
            b_rd_data <= mem[b_addr];
        end
    end
endmodule

module bram (
    input  wire [31:0] wr_data,
    input  wire [12:0] wr_addr,
    input  wire        wr_en,
    input  wire [3:0]  wr_byte_en,
    input  wire        wr_clk,
    input  wire        wr_rst,
    input  wire [12:0] rd_addr,
    output reg  [31:0] rd_data,
    input  wire        rd_clk,
    input  wire        rd_rst
);
    reg [31:0] mem [0:8191];
    reg [1023:0] hexpath;   // 由 +IMEM= / +DMEM= 覆盖；默认相对运行目录(sim/)
    integer i, k;
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 32'd0;
        if (!$value$plusargs("DMEM=%s", hexpath)) hexpath = "programs/dmem.hex";
        $readmemh(hexpath, mem);
    end
    always @(posedge wr_clk) begin
        if (wr_en) begin
            for (k = 0; k < 4; k = k + 1)
                if (wr_byte_en[k]) mem[wr_addr][k*8 +: 8] <= wr_data[k*8 +: 8];
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) rd_data <= 32'd0;
        else rd_data <= mem[rd_addr];
    end
endmodule

module coremark_tb;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    // 周期计数（提前声明：下面 core 例化就要用到 cycle_count）
    reg [63:0] cycle_count;

    core u_core (.clk(clk), .resetn(resetn), .pc(pc),
                 .mmio_rd_data(cycle_count[31:0]));

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100MHz

    initial begin
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    // 周期计数
    initial cycle_count = 0;
    always @(posedge clk) begin
        if (resetn) cycle_count <= cycle_count + 1;
    end

    // 迭代次数（+ITER=）
    integer iter;
    initial begin
        if (!$value$plusargs("ITER=%d", iter)) iter = 1;
    end

    // UART：core 对 0x7FFC 的 store 视为输出一个字符
    always @(posedge clk) begin
        if (resetn && u_core.ex_mem_mem_write
            && u_core.ex_mem_alu_result == 32'h7FFC)
            $write("%c", u_core.ex_mem_wdata[7:0]);
    end

    // tohost：core 对 0x7FF8 store 1 视为结束
    reg done;
    initial done = 0;
    always @(posedge clk) begin
        if (resetn && !done && u_core.ex_mem_mem_write
            && u_core.ex_mem_alu_result == 32'h7FF8
            && u_core.ex_mem_wdata == 32'd1) begin
            done <= 1;
            $display("\n=== CoreMark finished ===");
            $display("iterations   : %0d", iter);
            $display("total cycles : %0d", cycle_count);
            if (cycle_count > 0)
                $display("CoreMark/MHz : %f",
                         (iter * 1000000.0) / cycle_count);
            $finish;
        end
    end

    // 超时保护
    initial begin
        #1000000000;
        $display("\n=== TIMEOUT (pc=0x%h) ===", pc);
        $finish;
    end
endmodule
