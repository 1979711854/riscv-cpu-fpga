`timescale 1ns/1ps
// ============================================================================
// 一次性调试台：把 core 的 trap / 重定向 / 停顿信号逐拍打出来
// ----------------------------------------------------------------------------
// 用途：定位"加了 CSR/异常之后基线测试卡住"这类问题。
// 它不是回归的一部分，查清问题后可以删。
//
// 用法： iverilog ... -o tb_debug_trap.vvp sim/tb_debug_trap.v rtl/...
//        vvp tb_debug_trap.vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
//        "+MAXCYC=200"
// ============================================================================
`include "mem_model.vh"

module tb_debug_trap;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    wire [12:0] imem_addr;
    wire [31:0] imem_rd;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;

    // 注意：故意【不连】 irq_timer / irq_ext —— 这样同一份测试台既能编新版 core
    //（端口悬空，因 MIE=0 而无害），也能编加中断端口之前的旧版 core，
    // 便于做逐拍 diff 定位行为差异。
    core u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .ebreak()
    );

    mem_bus u_bus (
        .clk(clk), .resetn(resetn),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .gpio_we(), .uart_tx_we(), .uart_rx_ack(),
        .periph_wdata(), .gpio_rdata(32'd0), .uart_rx_rdata(32'd0),
        .done()
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer maxcyc, cyc;
    initial begin
        maxcyc = 200;
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 200;
        cyc = 0;
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    always @(posedge clk) begin
        if (resetn) begin
            cyc = cyc + 1;
            // 紧凑格式：逐拍 pc + 四级 pc + 重定向来源 + 关键控制位，便于两版本 diff
            $display("%0d pc=%h ifid=%h idex=%h exmem=%h memwb=%h st=%b dv=%b fl=%b mp=%b rd=%b | trap=%b mc=%b aexp=%h aext=%h acs=%h",
                cyc, pc,
                u_core.if_id_pc, u_core.id_ex_pc, u_core.ex_mem_pc, u_core.mem_wb_pc,
                u_core.stall, u_core.div_stall,
                u_core.ex_flush, u_core.ex_mispred, u_core.id_redirect,
                u_core.trap, u_core.id_ex_mret,
                u_core.alu_result, u_core.ex_target, u_core.csr_rdata);
            $display("      exp=%b ill=%b iscsr=%b wril=%b wren=%b ec=%b eb=%b misL=%b misS=%b ifins=%h",
                u_core.ex_exception, u_core.id_ex_illegal, u_core.id_ex_is_csr,
                u_core.csr_wr_illegal, u_core.csr_wr_en_raw,
                u_core.id_ex_sys_ecall, u_core.id_ex_sys_ebreak,
                u_core.load_misaligned, u_core.store_misaligned,
                u_core.if_id_instr);
            if (cyc >= maxcyc) $finish;
        end
    end
endmodule
