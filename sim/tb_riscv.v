`timescale 1ns/1ps
// ============================================================================
// riscv-tests 运行测试台（不改 CPU，不动 riscv-tests 仓库）
// ----------------------------------------------------------------------------
// * 行为级统一存储器（sim/mem_model.vh）加载 elf2mem.py 生成的 imem.hex / dmem.hex
// * 监控 core 对 tohost 的 store，判 PASS/FAIL
//   - tohost 写 1            => PASS
//   - tohost 写奇数(>1)      => FAIL，testnum = (值-1)>>1
// ============================================================================

// 统一存储器行为模型（指令/数据共用一块，A 口取指、B 口访存）
`include "mem_model.vh"

// 顶层
module cpu_tb_riscv;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

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

    // 统一存储器（指令+数据）的行为模型由本 tb 提供（sim/mem_model.vh）
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

    // ------------------------------------------------------------------
    // tohost 监控：core 对 tohost 做 store 即判定
    // ------------------------------------------------------------------
    // tohost 地址从 elf2mem.py 生成的 tohost_addr.hex 读（不同测试 .tohost 段 VMA 不同，
    // 例如 ld_st 在 0x2000），别硬编码 0x1000。
    reg [31:0] tohost_addr_mem [0:0];
    reg [1023:0] hexpath_tohost;
    initial begin
        tohost_addr_mem[0] = 32'h1000;  // 兜底
        if (!$value$plusargs("TOHOST=%s", hexpath_tohost)) hexpath_tohost = "programs/tohost_addr.hex";
        $readmemh(hexpath_tohost, tohost_addr_mem);
    end
    wire [31:0] TOHOST_ADDR = tohost_addr_mem[0];
    reg [31:0] tohost_val;
    reg        tohost_written;
    initial begin
        tohost_val = 32'd0;
        tohost_written = 1'b0;
    end
    // 用 core 的【真访存端口】而不是层次化引用内部信号；mem_wdata 已按 sb/sh/sw
    // 做过字节复制，riscv-tests 写 tohost 一律用 sw，故与原始 store 数据一致。
    always @(posedge clk) begin
        if (!resetn) begin
            tohost_written <= 1'b0;
        end else if (u_core.mem_we && u_core.mem_addr == TOHOST_ADDR) begin
            tohost_written <= 1'b1;
            tohost_val     <= u_core.mem_wdata;
        end
    end

    initial begin
        wait(tohost_written);
        #1;
        if (tohost_val == 32'd1)
            $display("=== PASS ===");
        else if (tohost_val[0])
            $display("=== FAIL (testnum %0d) ===", (tohost_val - 32'd1) >> 1);
        else
            $display("=== UNEXPECTED tohost=0x%h ===", tohost_val);
        $finish;
    end

    // 超时保护：50000 周期
    initial begin
        #500000;
        if (!tohost_written) begin
            $display("=== TIMEOUT (pc=0x%h) ===", pc);
            $finish;
        end
    end

    // 波形导出（批量跑时注释掉以提速；调试单个失败测试时再打开）
    // initial begin
    //     $dumpfile("cpu_tb_riscv.vcd");
    //     $dumpvars(0, cpu_tb_riscv);
    // end
endmodule
