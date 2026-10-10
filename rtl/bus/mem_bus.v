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
//   3) 视频区（0x8001_0000 起）也遵守上面两条：写通路组合打进显存 A 口，
//      读数据由显存 A 口自己寄存。视频区跟 RAM 一样是"1 拍必回"，所以
//      mem_ready 对它恒 1 —— 显示不走等待状态，见 §7.1。
//
// 地址映射见 addr_map.vh。
// ============================================================================
module mem_bus (
    input  wire        clk,
    input  wire        resetn,

    // ---- 取指口（直通统一存储器的 A1/A2 口，不做任何仲裁/缓冲）----
    // A2 是双发射的第二取指读口：与 A1 同拍、同延迟，读 unified_mem 的复制阵列。
    // 单发射（DUAL_ISSUE=0）时 core 仍驱动它、但结果被丢弃，行为逐位不变。
    input  wire [13:0] imem_addr,
    output wire [31:0] imem_rd,
    input  wire [12:0] imem_addr2,
    output wire [31:0] imem_rd2,

    // ---- 访存口（来自 core 的 MEM 级）----
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,     // 已按 sb/sh/sw 做过字节复制
    input  wire [3:0]  mem_byte_en,
    input  wire        mem_we,
    input  wire        mem_re,
    output wire [31:0] mem_rdata,

    // ---- 访存就绪（core.v 的访存等待机制）----
    // 恒 1 = 这次访存在固定 1 拍内完成（现在的行为，逐位不变）。
    // 拉低 = 这次访存还没完成，core 会把 MEM/WB 和上游一起冻住，直到它拉高。
    // 现在只有 RAM 的 b_ready 接上来（恒 1）；日后 APB/AXI 桥在这里驱动它。
    output wire        mem_ready,

    // ---- 外设：写选通 / 读回（外设寄存器本体在 rtl/periph/ 里）----
    output wire        gpio_we,       // 0x8000_0000 写 LED
    output wire        uart_tx_we,    // 0x8000_0008 或 0xFFFC 写一个字符
    output wire        uart_rx_ack,   // 0x8000_000C 读，清 rx valid
    output wire [31:0] periph_wdata,  // 送外设的写数据（字节复制后）
    input  wire [31:0] gpio_rdata,
    input  wire [31:0] uart_rx_rdata,

    // ---- 视频：显存 CPU 口 + 控制寄存器（本体在 rtl/video/video_top.v）----
    // 与其它外设不同，视频显存住在另一个模块、跨到 pix_clk 域，所以这里只出
    // 「一次访问落在哪个子窗口」+ 数据，由 video_top 自己分派。地址映射见
    // addr_map.vh 的视频区小节。
    output wire        vid_we,        // 写使能（子窗口由 vid_vsel 决定）
    output wire [1:0]  vid_vsel,      // 0=nametable 1=pattern 2=palette 3=寄存器
    output wire [13:0] vid_waddr,     // 区域相对【字】地址（写口用）
    output wire [3:0]  vid_be,        // = mem_byte_en，字节使能直通
    output wire [31:0] vid_wdata,
    output reg  [1:0]  vid_vsel_d,    // 与读数据同拍（= rsel_d 那一族）
    output reg  [13:0] vid_waddr_d,   // 同上，寄存器读回要按字偏移选
    input  wire [31:0] vid_rdata,

    // ---- 兼容区状态 ----
    output reg         done,          // 0xFFF8 写 1 → 拉高（板级 LED / 结束标志）

    // ---- 中断 ----
    // 定时器中断（mip.MTIP，bit7）。电平信号，直连 core.irq_timer。
    output wire        irq_timer
);

    // ------------------------------------------------------------------
    // 32 位自由跑周期计数器（27MHz），兼容区 0xFFF4 与外设区 TIMER 共用同一个。
    // CoreMark 的 get_time() 与 ee_printf 的忙等都靠它，必须保持 1 拍可读。
    // ------------------------------------------------------------------
    reg [31:0] cyc;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) cyc <= 32'd0;
        else         cyc <= cyc + 32'd1;
    end

    // ------------------------------------------------------------------
    // CLINT：mtime 就复用上面的 cyc（不另起一个计数器，避免两处漂移）；
    //        mtimecmp 可写。
    //
    // [重点] MTIP 必须是【纯电平比较器】，绝不做锁存或脉冲：
    //   软件写新的 mtimecmp → 下一拍比较自然翻低 → MTIP 自动落下。
    //   这正是"中断返回后能继续正常工作"的前提：`mret` 恢复 mstatus.MIE 后，
    //   若 MTIP 还是高的，会立刻再次 trap，PC 被钉死在 mtvec。
    //   做成"置位保持到软件清除"就会踩这个死循环。
    //
    // [重点] mtimecmp 复位值必须是【全 1】，不能是 0：
    //   复位为 0 会让 `mtime >= mtimecmp` 恒真 → 上电起 MTIP 就一直是 1。
    //   虽然默认 mie.MTIE=0 与 mstatus.MIE=0 能挡住，但那是免费的第二道防线，
    //   只要有一处 tie 写错就会从上电起反复 trap。
    //
    // 比较器单独打一拍（mtip_r）：把 32 位比较从 pc_r 的临界路径上切下来。
    // 电平语义下多这 1 拍无害（mtimecmp 是极低频写的，mtime 单调递增）。
    // ------------------------------------------------------------------
    reg [31:0] mtimecmp;
    reg        mtip_r;

    wire mtime_ge_cmp = (cyc >= mtimecmp);

    always @(posedge clk or negedge resetn) begin
        if (!resetn)              mtip_r <= 1'b0;
        else                      mtip_r <= mtime_ge_cmp;
    end

    // （mtimecmp 的写逻辑在文件末尾 —— 它要用到下面才声明的 periph_hit/periph_off，
    //   iverilog 14 严格要求先声明后使用。）

    assign irq_timer = mtip_r;

    // ------------------------------------------------------------------
    // 地址译码（只在这里做一次）
    // ------------------------------------------------------------------
    wire legacy_hit = (mem_addr[31:16] == 16'd0) && (mem_addr[15:4] == 12'hFFF);
    wire ram_hit    = (mem_addr[31:16] == 16'd0) && !legacy_hit;  // 0x0~0xFFFF 挖掉兼容区

    // 高半区（addr[31]=1）一分为二，分界线在 addr[16]：
    //   addr[17:16] == 2'b00 → 外设区 0x8000_0000~0x8000_FFFF
    //   addr[17:16] != 2'b00 → 视频区 0x8001_0000~0x8003_FFFF
    // [!] 原来 periph_hit 就是 mem_addr[31]，视频区一落进来就会命中 GPIO
    //     （periph_off=0）—— 写显存会顺带点 LED。所以必须把高半区切开。
    wire periph_hit = mem_addr[31] && (mem_addr[17:16] == 2'b00);
    wire video_hit  = mem_addr[31] && (mem_addr[17:16] != 2'b00);

    wire [1:0] legacy_off = mem_addr[3:2];
    wire [3:0] periph_off = mem_addr[5:2];                        // 字内偏移

    wire legacy_cycle = legacy_hit && (legacy_off == 2'b01);      // 0xFFF4
    wire legacy_done  = legacy_hit && (legacy_off == 2'b10);      // 0xFFF8
    wire legacy_utx   = legacy_hit && (legacy_off == 2'b11);      // 0xFFFC

    // ------------------------------------------------------------------
    // 视频区子窗口（地址含基址 0x8001_0000，即下面都是 mem_addr 的绝对值）
    //   四个窗口互斥，见 addr_map.vh 的视频区小节
    // ------------------------------------------------------------------
    wire v_nt_sel  = video_hit && (mem_addr[17:13] == 5'b01000);  // 0x8001_0000 8KB
    wire v_pat_sel = video_hit && (mem_addr[17:16] == 2'b10);     // 0x8002_0000 64KB
    wire v_pal_sel = video_hit && (mem_addr[17:10] == 8'hC0);     // 0x8003_0000 1KB
    wire v_reg_sel = video_hit && (mem_addr[17:10] == 8'hC1);     // 0x8003_0400 1KB

    wire [1:0] vsel = v_pat_sel ? 2'd1 :
                      v_pal_sel ? 2'd2 :
                      v_reg_sel ? 2'd3 : 2'd0;

    // 视频区里有大片未分配的地址（如 0x8003_0800 以上）。它们不能让 vsel 的
    // 默认值 0 变成"悄悄写 nametable"——所以写使能只在真命中四个子窗口时给。
    // （读方向未分配地址会读回 nametable 数据，属于"别这么干"，不额外防。）
    wire v_sel_any = v_nt_sel | v_pat_sel | v_pal_sel | v_reg_sel;

    assign vid_we      = mem_we && v_sel_any;
    assign vid_vsel    = vsel;
    assign vid_waddr   = mem_addr[15:2];   // 区域相对字地址：NT[10:0] PAT[13:0] PAL[7:0] REG[1:0]
    assign vid_be      = mem_byte_en;
    assign vid_wdata   = mem_wdata;

    // ------------------------------------------------------------------
    // 统一存储器：A 口取指 / B 口访存
    //   指令与数据共用一块，所以 store 写进去的东西，后续取指能读到 ——
    //   这正是 fence_i（自修改代码）能通过的原因。
    // ------------------------------------------------------------------
    wire [13:0] ram_word = mem_addr[15:2];
    wire [31:0] ram_rdata;
    wire        ram_ready;      // RAM 的就绪（恒 1；仿真里可被 +MEMWAIT 拉低）

    unified_mem u_mem (
        // A1 口：取指 1（只读）
        .a_addr   (imem_addr),
        .a_rd_data(imem_rd),
        .a_clk    (clk),
        .a_rst    (~resetn),
        // A2 口：取指 2（只读，双发射第二读口；与 A1 同域）
        .a2_addr  (imem_addr2),
        .a2_rd_data(imem_rd2),
        // B 口：访存（读写）
        .b_addr   (ram_word),
        .b_wr_data(mem_wdata),
        .b_wr_en  (ram_hit && mem_we),
        .b_byte_en(mem_byte_en),
        .b_rd_data(ram_rdata),
        .b_clk    (clk),
        .b_rst    (~resetn),
        // [!] 输出端口只能接一根线，不能写条件表达式（iverilog 会报
        //     "expression not valid in assign l-value"）。选择逻辑放在下面。
        .b_ready  (ram_ready)
    );

    // [!] 现在只有 RAM 参与就绪。命中 RAM 时听 RAM 的 b_ready；其余地址
    //     （兼容区 / 外设区 / 视频区）都是 1 拍必回，直接给 1 —— 视频显存的
    //     A 口也是同步 BRAM，地址进、次拍数据出，与统一存储器同拍。
    //     日后加 APB/AXI 桥时，把桥的 ready 也并进来（相与）。
    assign mem_ready = ram_hit ? ram_ready : 1'b1;

    // ------------------------------------------------------------------
    // 读数据选择位 + 非 RAM 源的读数据，都在 MEM→WB 沿寄存（约束 2）
    // ------------------------------------------------------------------
    reg [1:0]  rsel_d;            // 0 = RAM，1 = 兼容区，2 = 外设区，3 = 视频区
    reg [31:0] legacy_rdata_d;
    reg [31:0] periph_rdata_d;

    wire [31:0] periph_rmux =
        (periph_off == `PERIPH_GPIO)     ? gpio_rdata    :
        (periph_off == `PERIPH_UART_RX)  ? uart_rx_rdata :
        (periph_off == `PERIPH_TIMER)    ? cyc           :   // = mtime
        (periph_off == `PERIPH_MTIMECMP) ? mtimecmp      : 32'd0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rsel_d         <= 2'd0;
            legacy_rdata_d <= 32'd0;
            periph_rdata_d <= 32'd0;
            vid_vsel_d     <= 2'd0;
            vid_waddr_d    <= 14'd0;
        end else begin
            rsel_d         <= video_hit  ? 2'd3 :
                              legacy_hit ? 2'd1 : periph_hit ? 2'd2 : 2'd0;
            legacy_rdata_d <= legacy_cycle ? cyc : 32'd0;
            periph_rdata_d <= periph_hit ? periph_rmux : 32'd0;
            // 视频区：子窗口选择与字地址都要拖到与读数据同拍。显存本身在
            // video_top 里由 BRAM 寄存了 1 拍，寄存器读回是稳定的寄存器值、
            // 只靠这两根选择线对齐，所以 [1:0] 必须一起延。
            vid_vsel_d     <= vsel;
            vid_waddr_d    <= mem_addr[15:2];
        end
    end

    assign mem_rdata = (rsel_d == 2'd3) ? vid_rdata :
                       (rsel_d == 2'd1) ? legacy_rdata_d :
                       (rsel_d == 2'd2) ? periph_rdata_d : ram_rdata;

    // ------------------------------------------------------------------
    // 外设写选通（组合，零拍；u8 写入按低字节取，与 sb/sh/sw 都兼容）
    // ------------------------------------------------------------------
    // [!] 这三个选通是【电平敏感】的，外设不是在沿上"看一眼"：
    //       uart_tx.v:  if (tx_start && !fifo_full) → 高 N 拍就入队 N 个字符
    //       uart_rx.v:  if (ack && !empty) rptr++   → 高 N 拍就弹掉 N 个字节
    //     **现在安全**，因为外设访问恒不等待（上面 mem_ready 对非 RAM 地址直接给 1），
    //     而这些条件里本来就含 mem_we/mem_re，所以只高 1 拍。
    //
    //     [!!] 但**加 APB/AXI 桥并让外设等待之后就不安全了** —— 访问被停住时
    //     选通会一直高着，于是"发一次字符"变成"发 N 次"、"读一次"变成"弹 N 个"，
    //     而且是静默数据损坏。**那时必须把这三个选通与"本次访问的首次那一拍"
    //     相与**（桥里锁存一个 one-shot，或者在 core 引出 mem_req）。
    //     详见 doc/reports/2026-09-27_bus_upgrade_plan.md §3。
    assign gpio_we      = periph_hit && mem_we && (periph_off == `PERIPH_GPIO);
    assign uart_tx_we   = (periph_hit && mem_we && (periph_off == `PERIPH_UART_TX))
                          || (legacy_utx && mem_we);
    assign uart_rx_ack  = periph_hit && mem_re && (periph_off == `PERIPH_UART_RX);
    assign periph_wdata = mem_wdata;

    // ------------------------------------------------------------------
    // 结束标志：写 0xFFF8 低字节 = 1。
    // 用 byte_en[0] + 低字节比较（而不是整字 ==1），这样 sb/sh/sw 都能触发；
    // 对 CoreMark start.S 的 `sw a0=1, 0(0xFFF8)` 行为与旧版完全一致。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge resetn) begin
        if (!resetn) done <= 1'b0;
        else if (mem_we && legacy_done && mem_byte_en[0] && (mem_wdata[7:0] == 8'd1))
            done <= 1'b1;
    end

    // ------------------------------------------------------------------
    // CLINT：mtimecmp 写口
    // 只接受【整字写】（sw），sb/sh 静默忽略 —— 规范里 mtimecmp 也是按字访问的。
    // 复位值全 1 而不是 0，理由见上面 mtip_r 附近的注释。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge resetn) begin
        if (!resetn) mtimecmp <= 32'hFFFF_FFFF;
        else if (periph_hit && mem_we && (periph_off == `PERIPH_MTIMECMP) &&
                 (mem_byte_en == 4'b1111))
            mtimecmp <= mem_wdata;
    end

endmodule
