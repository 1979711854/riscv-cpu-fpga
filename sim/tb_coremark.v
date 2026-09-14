`timescale 1ns/1ps
// CoreMark 运行测试台：周期计数 + UART 字符拦截 + tohost 结束判分
//   - core 对 0x7FFC 的 store 视为输出一个字符（uart_send_char）
//   - core 对 0x7FF8 的 store 1 视为结束（start.S 里 main 返回后写）
//   - CoreMark/MHz = ITERATIONS * 1e6 / 总周期数

// 统一存储器行为模型（指令/数据共用一块，A 口取指、B 口访存）
`include "mem_model.vh"


module coremark_tb;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    // 周期计数（提前声明：下面 core 例化就要用到 cycle_count）
    reg [63:0] cycle_count;

    // core ↔ mem_bus 的取指口与访存口
    wire [12:0] imem_addr;
    wire [31:0] imem_rd;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;

    core u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata)
    );

    // mem_bus 自带周期计数器（0x7FF4 的读回源），与 tb 的 cycle_count 同时复位、
    // 同步递增，故 get_time() 读数与改造前一致。
    mem_bus u_bus (
        .clk(clk), .resetn(resetn),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .gpio_we(), .uart_tx_we(), .uart_rx_ack(),
        .periph_wdata(), .gpio_rdata(32'd0), .uart_rx_rdata(32'd0),
        .done(), .cycle_cnt()
    );

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
    // （用真访存端口；mem_wdata 已按 sb 字节复制，[7:0] 与原始 store 数据一致）
    always @(posedge clk) begin
        if (resetn && u_core.mem_we && u_core.mem_addr == 32'h7FFC)
            $write("%c", u_core.mem_wdata[7:0]);
    end

    // tohost：core 对 0x7FF8 store 1 视为结束
    reg done;
    initial done = 0;
    always @(posedge clk) begin
        if (resetn && !done && u_core.mem_we
            && u_core.mem_addr == 32'h7FF8
            && u_core.mem_byte_en[0] && u_core.mem_wdata[7:0] == 8'd1) begin
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
