`timescale 1ns/1ps
// ============================================================================
// tb_run —— 通用程序运行测试台
// ----------------------------------------------------------------------------
// 跑【任意】程序，把串口输出实时打到控制台。不做任何判定，就是让你看见输出。
// 适合开发自己的 C 程序时快速迭代 —— 比烧板子快得多。
//
// 用法（一般由 scripts\build_c.ps1 -Run 调用）：
//   vvp tb_run.vvp +IMEM=programs/mem.hex +MAXCYC=20000000
//
// 结束条件（任一）：
//   1. 程序写 done（0x7FF8 = 1）—— CoreMark 的结束协议
//   2. 程序执行 EBREAK          —— 自定义程序推荐这么收尾
//   3. 达到 +MAXCYC= 指定的周期数（默认 1000 万）
//
// 注意：这里拦的是【CPU 对 UART 发送寄存器的写】，不是解码 uart_tx 串行线。
//       这样最快，且不受波特率拖累。UART 发送器本身的正确性由 tb_uart_fifo
//       和 tb_demo 覆盖。
// ============================================================================

// 统一存储器行为模型（指令+数据共用一块）
`include "mem_model.vh"

module tb_run;
    reg         clk = 1'b0;
    reg         resetn;
    reg  [7:0]  key    = 8'hFF;    // 全部松开
    reg         uart_rx = 1'b1;    // 空闲高
    wire [7:0]  led;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;

    always #5 clk = ~clk;          // 100MHz 仿真时钟

    cpu_top u_soc (
        .clk     (clk),
        .resetn  (resetn),
        .pc      (pc),
        .uart_tx (uart_tx),
        .uart_rx (uart_rx),
        .led     (led),
        .key     (key),
        .done    (done)
    );

    integer maxcyc;
    integer cyc = 0;
    reg     finished = 1'b0;

    initial begin
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 10000000;
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
        $display("=== 开始运行（上限 %0d 周期 = %0.2f 秒 @27MHz）===", maxcyc, maxcyc / 27000000.0);
    end

    // ---- 串口输出：拦 CPU 对两个 UART 发送地址的写 ----
    //   0x7FFC 是 CoreMark 移植层用的兼容地址，0x8000_0008 是外设区的正规地址
    always @(posedge clk) begin
        if (resetn && !finished && u_soc.mem_we &&
            (u_soc.mem_addr == 32'h7FFC || u_soc.mem_addr == 32'h8000_0008))
            $write("%c", u_soc.mem_wdata[7:0]);
    end

    // ---- 结束条件 1：写 done ----
    always @(posedge clk) begin
        if (resetn && !finished && u_soc.mem_we && u_soc.mem_addr == 32'h7FF8
            && u_soc.mem_byte_en[0] && u_soc.mem_wdata[7:0] == 8'd1) begin
            finished <= 1'b1;
            $display("\n=== 程序写了 done（0x7FF8），正常结束 ===");
        end
    end

    // ---- 结束条件 2：执行 EBREAK ----
    always @(posedge clk) begin
        if (resetn && !finished && u_soc.ebreak) begin
            finished <= 1'b1;
            $display("\n=== 程序执行了 EBREAK，停机 ===");
        end
    end

    // ---- 结束条件 3：超时 ----
    always @(posedge clk) begin
        if (resetn && !finished) begin
            cyc <= cyc + 1;
            if (cyc >= maxcyc) begin
                finished <= 1'b1;
                $display("\n=== 达到周期上限，强制结束（pc=0x%h）===", pc);
            end
        end
    end

    initial begin
        wait(finished);
        #100;
        $display("总周期: %0d  (%.3f 秒 @27MHz)", cyc, cyc / 27000000.0);
        $finish;
    end
endmodule
