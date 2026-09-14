`timescale 1ns/1ps
// ============================================================================
// riscv-tests 运行测试台（不改 CPU，不动 riscv-tests 仓库）
// ----------------------------------------------------------------------------
// * 行为级 imem / bram 加载 elf2mem.py 生成的 imem.hex / dmem.hex
// * 监控 core 对地址 0x1000(tohost) 的 store，判 PASS/FAIL
//   - tohost 写 1            => PASS
//   - tohost 写奇数(>1)      => FAIL，testnum = (值-1)>>1
// ============================================================================

// 行为级指令存储器（同步读 1 拍延迟，与 cpu_tb.v 一致）
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

// 行为级数据存储器（写口带 byte_en，同步读 1 拍）
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

// 顶层
module cpu_tb_riscv;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    // core ↔ mem_bus 的访存口
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;

    core u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata)
    );

    // 存储器本体（imem 仍由 core 例化，bram 由 mem_bus 例化）由本 tb 提供行为级模型
    mem_bus u_bus (
        .clk(clk), .resetn(resetn),
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
