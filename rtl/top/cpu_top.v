`timescale 1ns/1ps
// ============================================================================
// cpu_top —— SoC 顶层
// ----------------------------------------------------------------------------
//   core ──取指口──┐
//                  ├─> mem_bus ──> 统一存储器（指令+数据）
//   core ──访存口──┘      │
//                         ├──写选通──> uart_tx / uart_rx / gpio
//                         └──读数据<── 外设读回 mux
//
// 地址译码全部收敛在 mem_bus（映射见 rtl/bus/addr_map.vh），顶层只做连线。
// ============================================================================
module cpu_top (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] pc,          // 板级调试/示波用

    // ---- UART ----
    output wire        uart_tx,
    input  wire        uart_rx,

    // ---- GPIO ----
    output wire [7:0]  led,         // 输出高电平点亮
    input  wire [7:0]  key,         // 按键低有效：按下 = 0

    // ---- 程序结束标志 ----
    output wire        done
);
    // UART 波特率分频 = f_clk / 115200。
    //   * 仿真测试台例化 cpu_top 时【不传参数】→ 取 27MHz 的 234，仿真语义不变。
    //   * 上板顶层 cpu_top_board 传 390（45MHz），见该文件头的 PLL 说明。
    parameter [9:0] UART_DIV = 10'd234;   // 27MHz→234（误差 0.16%），45MHz→390

    // ---- core ↔ mem_bus：取指口 ----
    wire [12:0] imem_addr;
    wire [31:0] imem_rd;

    // ---- core ↔ mem_bus：访存口 ----
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_ready;   // 访存就绪：mem_bus 出，core 入（见 core.v 的访存等待机制）
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;

    // ---- mem_bus ↔ 外设 ----
    wire        gpio_we, uart_tx_we, uart_rx_ack;
    wire [31:0] periph_wdata;
    wire [31:0] gpio_rdata, uart_rx_rdata;

    // ---- 中断 ----
    wire        irq_timer;      // mem_bus 里的 CLINT：mtime >= mtimecmp

    // ---- 程序结束标志 ----
    // 两个来源：CoreMark 的 0x7FF8 协议（start.S 里 main 返回后写），
    // 以及程序执行 EBREAK。
    // 注意 EBREAK 是【软停机】：只置标志、不停 PC —— 程序应在 EBREAK 后跟一个
    // 自旋循环（riscv-tests 的 pass/fail 例程、CoreMark 的 start.S 都是这么做的）。
    wire        ebreak;
    wire        done_mmio;
    reg         halt;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)     halt <= 1'b0;
        else if (ebreak) halt <= 1'b1;
    end
    assign done = done_mmio | halt;

    mem_bus u_bus (
        .clk          (clk),
        .resetn       (resetn),
        .imem_addr    (imem_addr),
        .imem_rd      (imem_rd),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_byte_en  (mem_byte_en),
        .mem_we       (mem_we),
        .mem_re       (mem_re),
        .mem_rdata    (mem_rdata),
        .mem_ready    (mem_ready),
        .gpio_we      (gpio_we),
        .uart_tx_we   (uart_tx_we),
        .uart_rx_ack  (uart_rx_ack),
        .periph_wdata (periph_wdata),
        .gpio_rdata   (gpio_rdata),
        .uart_rx_rdata(uart_rx_rdata),
        .done         (done_mmio),
        .irq_timer    (irq_timer)
    );

    core u_core (
        .clk         (clk),
        .resetn      (resetn),
        .pc          (pc),
        .imem_addr   (imem_addr),
        .imem_rd     (imem_rd),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_byte_en (mem_byte_en),
        .mem_we      (mem_we),
        .mem_re      (mem_re),
        .mem_rdata   (mem_rdata),
        .mem_ready   (mem_ready),
        .ebreak      (ebreak),
        // ---- 中断 ----
        // 定时器中断：由 mem_bus 里的 CLINT（mtime/mtimecmp 比较器）驱动。
        // 默认 mie.MTIE=0 与 mstatus.MIE=0 保证上电时不会被受理。
        .irq_timer   (irq_timer),
        // 外部中断：UART 接收 FIFO 非空（rdata[31] 就是 valid 位）。
        // 电平信号 —— 读一次 0x8000_000C 弹出队头后自然落下。
        // [!] 本轮只做到"接口具备"，未写针对它的中断测试（见 doc/spec.md 已知限制）。
        .irq_ext     (uart_rx_rdata[31])
    );

    // ------------------------------------------------------------------
    // 外设
    // ------------------------------------------------------------------
    // UART 发送：兼容区 0x7FFC 与外设区 0x8000_0008 共用（见 mem_bus 的 uart_tx_we）。
    // uart_tx 内含 1024 深 FIFO，短时间连续写不会丢字符。
    uart_tx #(.DIV(UART_DIV)) u_uart_tx (
        .clk     (clk),
        .resetn  (resetn),
        .tx_data (periph_wdata[7:0]),
        .tx_start(uart_tx_we),
        .tx      (uart_tx),
        .busy    ()
    );

    // UART 接收：0x8000_000C，读操作会弹出 FIFO 头部（见 uart_rx.v 头注释）
    uart_rx #(.DIV(UART_DIV)) u_uart_rx (
        .clk    (clk),
        .resetn (resetn),
        .ack    (uart_rx_ack),
        .rdata  (uart_rx_rdata),
        .rx     (uart_rx)
    );

    // GPIO：0x8000_0000 写 LED / 读回 {key, led}
    gpio u_gpio (
        .clk    (clk),
        .resetn (resetn),
        .we     (gpio_we),
        .wdata  (periph_wdata),
        .rdata  (gpio_rdata),
        .led    (led),
        .key    (key)
    );
endmodule
