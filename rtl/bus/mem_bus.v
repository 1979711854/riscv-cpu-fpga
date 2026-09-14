`timescale 1ns/1ps
`include "addr_map.vh"
// ============================================================================
// mem_bus —— 存储总线 / 地址译码（SoC 里【唯一】做地址译码的地方）
// ----------------------------------------------------------------------------
// 时序契约（core.v 依赖它，改这里必须同步看 core.v 的 MEM/WB 段）：
//
//   第 T   拍 (MEM)：core 给出 mem_addr / mem_wdata / mem_we / mem_byte_en
//   第 T+1 拍 (WB)：mem_rdata 必须是 mem_addr(T) 对应地址的读数据
//
// 由此推出两条【硬约束】，破坏任何一条都会让 load 读到错值：
//
//   1) 写通路零寄存器。mem_we/mem_addr/mem_wdata/mem_byte_en 必须组合打进
//      RAM 写口。若把写地址或写数据寄存一拍，store 在 T 提交、load 在 T+1
//      读回，就会读到旧值 —— st_ld / ld_st 这类"存完立刻读回"的用例直接翻车。
//
//   2) 读选择位与读数据都必须在 MEM→WB 那个沿寄存（rsel_d 一族）。不能给
//      读通路再插一级寄存器，否则读数据被推到 T+2，而 WB 在 T+1 采样，
//      没有任何 stall 机制能救（冒险单元不知道内存有几拍）。
//      所有地址源（RAM / 兼容区 / 外设区）一律 1 拍延迟，不搞特例。
//
// 注：RAM 的读数据由 bram/unified_mem 内部在同一个沿寄存，天然满足约束 2。
//
// 地址映射见 addr_map.vh。
// ============================================================================
module mem_bus (
    input  wire        clk,
    input  wire        resetn,

    // ---- 访存口（来自 core 的 MEM 级）----
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,     // 已按 sb/sh/sw 做过字节复制
    input  wire [3:0]  mem_byte_en,
    input  wire        mem_we,
    input  wire        mem_re,
    output wire [31:0] mem_rdata,

    // ---- 外设：写选通 / 读回（外设寄存器本体在 rtl/periph/ 里）----
    output wire        gpio_we,       // 0x8000_0000 写 LED
    output wire        uart_tx_we,    // 0x8000_0008 或 0x7FFC 写一个字符
    output wire        uart_rx_ack,   // 0x8000_000C 读，清 rx valid
    output wire [31:0] periph_wdata,  // 送外设的写数据（字节复制后）
    input  wire [31:0] gpio_rdata,
    input  wire [31:0] uart_rx_rdata,

    // ---- 兼容区状态 ----
    output reg         done,          // 0x7FF8 写 1 → 拉高（板级 LED / 结束标志）
    output wire [31:0] cycle_cnt      // 0x7FF4 / 0x8000_0010 共用的周期计数器
);

    // ------------------------------------------------------------------
    // 32 位自由跑周期计数器（27MHz），兼容区与外设区 TIMER 同一个计数器。
    // CoreMark 的 get_time() 与 ee_printf 的忙等都靠它，必须保持 1 拍可读。
    // ------------------------------------------------------------------
    reg [31:0] cyc;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) cyc <= 32'd0;
        else         cyc <= cyc + 32'd1;
    end
    assign cycle_cnt = cyc;

    // ------------------------------------------------------------------
    // 地址译码（只在这里做一次）
    // ------------------------------------------------------------------
    wire legacy_hit = (mem_addr[31:16] == 16'd0) && (mem_addr[15:4] == 12'h7FF);
    wire ram_hit    = (mem_addr[31:15] == 17'd0) && !legacy_hit;  // 0x0~0x7FFF 挖掉兼容区
    wire periph_hit =  mem_addr[31];                              // 0x8000_0000 起

    wire [1:0] legacy_off = mem_addr[3:2];
    wire [3:0] periph_off = mem_addr[5:2];                        // 字内偏移

    wire legacy_cycle = legacy_hit && (legacy_off == 2'b01);      // 0x7FF4
    wire legacy_done  = legacy_hit && (legacy_off == 2'b10);      // 0x7FF8
    wire legacy_utx   = legacy_hit && (legacy_off == 2'b11);      // 0x7FFC

    // ------------------------------------------------------------------
    // RAM（B 口：读写）
    // ------------------------------------------------------------------
    wire [12:0] ram_word = mem_addr[14:2];
    wire [31:0] ram_rdata;

    bram u_bram (
        .wr_data   (mem_wdata),
        .wr_addr   (ram_word),
        .wr_en     (ram_hit && mem_we),
        .wr_byte_en(mem_byte_en),
        .wr_clk    (clk),
        .wr_rst    (~resetn),
        .rd_addr   (ram_word),
        .rd_data   (ram_rdata),
        .rd_clk    (clk),
        .rd_rst    (~resetn)
    );

    // ------------------------------------------------------------------
    // 读数据选择位 + 非 RAM 源的读数据，都在 MEM→WB 沿寄存（约束 2）
    // ------------------------------------------------------------------
    reg [1:0]  rsel_d;            // 0 = RAM，1 = 兼容区，2 = 外设区
    reg [31:0] legacy_rdata_d;
    reg [31:0] periph_rdata_d;

    wire [31:0] periph_rmux =
        (periph_off == `PERIPH_GPIO)    ? gpio_rdata    :
        (periph_off == `PERIPH_UART_RX) ? uart_rx_rdata :
        (periph_off == `PERIPH_TIMER)   ? cyc           : 32'd0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rsel_d         <= 2'd0;
            legacy_rdata_d <= 32'd0;
            periph_rdata_d <= 32'd0;
        end else begin
            rsel_d         <= legacy_hit ? 2'd1 : periph_hit ? 2'd2 : 2'd0;
            legacy_rdata_d <= legacy_cycle ? cyc : 32'd0;
            periph_rdata_d <= periph_hit ? periph_rmux : 32'd0;
        end
    end

    assign mem_rdata = (rsel_d == 2'd1) ? legacy_rdata_d :
                       (rsel_d == 2'd2) ? periph_rdata_d : ram_rdata;

    // ------------------------------------------------------------------
    // 外设写选通（组合，零拍；u8 写入按低字节取，与 sb/sh/sw 都兼容）
    // ------------------------------------------------------------------
    assign gpio_we      = periph_hit && mem_we && (periph_off == `PERIPH_GPIO);
    assign uart_tx_we   = (periph_hit && mem_we && (periph_off == `PERIPH_UART_TX))
                          || (legacy_utx && mem_we);
    assign uart_rx_ack  = periph_hit && mem_re && (periph_off == `PERIPH_UART_RX);
    assign periph_wdata = mem_wdata;

    // ------------------------------------------------------------------
    // 结束标志：写 0x7FF8 低字节 = 1。
    // 用 byte_en[0] + 低字节比较（而不是整字 ==1），这样 sb/sh/sw 都能触发；
    // 对 CoreMark start.S 的 `sw a0=1, 0(0x7FF8)` 行为与旧版完全一致。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge resetn) begin
        if (!resetn) done <= 1'b0;
        else if (mem_we && legacy_done && mem_byte_en[0] && (mem_wdata[7:0] == 8'd1))
            done <= 1'b1;
    end

endmodule
