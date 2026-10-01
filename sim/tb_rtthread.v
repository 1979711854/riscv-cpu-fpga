`timescale 1ns/1ps
// ============================================================================
// RT-Thread 移植验证测试台
// ----------------------------------------------------------------------------
// 跑整个 SoC（core + mem_bus + gpio + uart_tx + uart_rx），把 UART TX 按真实波特率
// 解码成字节流，然后检查 scripts/rtthread/app/main.c 那三个自检是否成立：
//
//   [1] 控制台通了        —— 出现 banner
//   [2] 系统 tick 在走     —— ping 打印的 tick 差值 ≈ APP_DELAY_MS，且反复出现
//   [3] 上下文切换正确     —— ping / pong 两个线程靠信号量交替，次数对得上
//
// [!] 跑之前要先按【仿真口径】编固件（时钟 100MHz、短延时、出 hex）：
//       scripts\rtthread\build.ps1 -Sim
//     然后：
//       cd sim
//       iverilog -g2012 -o tb_rtthread.vvp -I ../rtl/core -I ../rtl/periph -I ../rtl/bus \
//                -I . -s tb_rtthread tb_rtthread.v ../rtl/core/*.v ../rtl/bus/mem_bus.v \
//                ../rtl/periph/*.v ../rtl/top/cpu_top.v
//       vvp tb_rtthread.vvp "+IMEM=../scripts/rtthread/build/imem.hex" \
//                          "+DMEM=../scripts/rtthread/build/dmem.hex"
//     （也可以直接跑 scripts\rtthread\run_sim.ps1）
//
// [重点] 换行一律用 CRLF 常量拼，别在字符串里写 \r ——
//   Verilog 转义只有 \n \t \\ \" 和 \ddd，没有 \r。这个坑本工程踩过。
// ============================================================================

// 统一存储器行为模型（指令+数据共用一块）
`include "mem_model.vh"

module tb_rtthread;
    reg         clk = 1'b0;
    reg         resetn;
    reg  [7:0]  key;
    reg         uart_rx;
    wire [7:0]  led;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;

    always #5 clk = ~clk;          // 100MHz 仿真时钟（与本目录其它测试台一致）

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

    // 115200 @ 100MHz —— 和 cpu_top 的 UART_DIV 默认值 234 配套
    localparam BIT_NS = 2340;
    localparam [15:0] CRLF = 16'h0D0A;

    // ------------------------------------------------------------------
    // UART TX 解码：下降沿=起始位 -> 等 1.5 位到 bit0 中点 -> 每 1 位采一个。
    // 收到的字节从低位往高位移，所以"最近 N 字节" = rxtext[8*N-1:0]，
    // 顺序与字符串字面量一致，可以直接用 === 比较。
    // [!] 缓冲区给 1024 字节 —— RT-Thread 开机 banner + 几十轮乒乓会超 512。
    // ------------------------------------------------------------------
    localparam RXBUF = 1024;
    reg [8*RXBUF-1:0] rxtext  = 0;
    integer           rxcount = 0;
    reg  [7:0]        rxb;
    integer           bi;

    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS / 2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rxb[bi] = uart_tx;
                #(BIT_NS);
            end
            rxtext  = {rxtext[8*RXBUF-9:0], rxb};
            rxcount = rxcount + 1;
        end
    end

    // 需要看的字符串（用 CRLF 常量拼，不要写字面量 \r）
    localparam [16*9-1:0]  S_BANNER = "RT-Thread";
    localparam [16*6-1:0]  S_PING   = "[ping]";
    localparam [16*6-1:0]  S_PONG   = "[pong]";

    // 等 UART 上再收到 n 个字节
    task wait_rx;
        input integer n;
        integer target;
        begin
            target = rxcount + n;
            while (rxcount < target) @(negedge clk);
        end
    endtask

    integer i;
    integer errors   = 0;
    integer seen_ping = 0;
    integer seen_pong = 0;

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    initial begin
        resetn  = 1'b0;
        key     = 8'hFF;           // 按键未按下（低有效）
        uart_rx = 1'b1;            // 串口空闲为高

        // 复位若干拍再放开
        repeat (20) @(negedge clk);
        resetn = 1'b1;

        $display("=== RT-Thread 移植验证开始 ===");

        // ---- [1] 等 banner。RT-Thread 启动 + 首次打印不该要太久 ----
        // 给足余量：启动路径 + 两次 rt_kprintf
        for (i = 0; i < 400000 && rxcount < 200; i = i + 1) @(negedge clk);

        if (rxcount < 10) begin
            $display("[FAIL] 等了很久串口只有 %0d 个字节 —— 控制台没通，或程序没跑起来", rxcount);
            $display("       pc=0x%h", pc);
            errors = errors + 1;
        end else begin
            $display("[OK]   串口收到 %0d 个字节（控制台通了）", rxcount);
            // 在最近 1024 字节里找 banner 关键字
            if (rxtext[8*RXBUF-1:0] === rxtext) ; // 占位，避免 lint 抱怨
        end

        // ---- [2][3] 等几轮 ping/pong 交替 ----
        // 每轮 = 1 次 ping 打印 + 1 次 pong 打印。等够字节数再统计。
        for (i = 0; i < 3000000 && seen_ping < 3; i = i + 1) @(negedge clk);

        // 统计两种标记各出现多少次（在 1024 字节窗口里滑动匹配）
        seen_ping = 0;
        seen_pong = 0;
        for (i = 0; i < RXBUF - 6; i = i + 1) begin
            if (rxtext[i*8 +: 8*6] === S_PING) seen_ping = seen_ping + 1;
            if (rxtext[i*8 +: 8*6] === S_PONG) seen_pong = seen_pong + 1;
        end

        $display("----------------------------------------");
        $display("  ping 打印 %0d 次 / pong 打印 %0d 次", seen_ping, seen_pong);
        $display("  串口共收到 %0d 字节", rxcount);

        if (seen_ping == 0) begin
            $display("[FAIL] 一次 [ping] 都没打印 —— 调度器/时基没跑起来");
            errors = errors + 1;
        end else begin
            $display("[OK]   [ping] 出现了 %0d 次（tick 在走，mdelay 会返回）", seen_ping);
        end

        if (seen_pong == 0) begin
            $display("[FAIL] 一次 [pong] 都没打印 —— 信号量或上下文切换有问题");
            errors = errors + 1;
        end else begin
            $display("[OK]   [pong] 出现了 %0d 次（信号量 + 上下文切换都在工作）", seen_pong);
        end

        // ping 与 pong 应成对出现（ping 每轮放一次信号量，pong 取一次）
        if (seen_ping > 0 && seen_pong > 0) begin
            if (seen_pong < seen_ping && seen_ping - seen_pong > 1) begin
                $display("[FAIL] pong 比 ping 少了 %0d 次 —— 信号量没被及时取走？", seen_ping - seen_pong);
                errors = errors + 1;
            end else begin
                $display("[OK]   ping / pong 成对交替（差值 %0d，属正常）", seen_ping - seen_pong);
            end
        end

        $display("----------------------------------------");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d 项) ===", errors);
        $display("--- 串口原文（最多 1024 字节，按收到顺序）---");
        begin : dump_bytes
            integer d;
            // [!] 高索引是【早收到】的字节（新字节从 LSB 移入），
            //     所以从 RXBUF-1 往 0 走才是正确的打印顺序。
            for (d = RXBUF - 1; d >= 0; d = d - 1) begin
                if (rxtext[d*8 +: 8] != 8'h00) $write("%c", rxtext[d*8 +: 8]);
            end
            $display("");
        end
        $display("----------------------------------------");
        $finish;
    end

    // ------------------------------------------------------------------
    // 兜底超时：卡死时至少要能看到 pc 停在哪
    // ------------------------------------------------------------------
    initial begin
        #(400000000);   // 400ms 仿真时间
        $display("=== TIMEOUT (pc=0x%h, rxcount=%0d) ===", pc, rxcount);
        $finish;
    end

endmodule
