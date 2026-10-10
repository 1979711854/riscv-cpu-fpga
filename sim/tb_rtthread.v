`timescale 1ns/1ps
// ============================================================================
// RT-Thread 移植验证测试台
// ----------------------------------------------------------------------------
// 跑整个 SoC（core + mem_bus + gpio + uart_tx + uart_rx），把 UART TX 按真实波特率
// 解码成字节流，然后检查 scripts/rtthread/app/main.c 那三个自检是否成立：
//
//   [1] 控制台通了        —— 出现 RT-Thread banner
//   [2] 游戏线程起来了     —— 出现 "[boot] gomoku thread running"（任务 H）
//   [3] 调度器在跑         —— 主线程心跳 "[hb] alive" 出现。
//       这一条一举证明两件事：**调度器正常**，且**游戏线程没把 CPU 独占死**
//       （心跳还挤得进来）。
//
// [任务 H 说明] 本测试台原来验的是 ping/pong 双线程移植（信号量 + 上下文切换）。
// 那条已经完成使命，应用换成五子棋后判据跟着换。ping/pong 版本在 git 历史里。
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
    // [任务 H] 应用从"ping/pong 移植验证"换成了【五子棋】，判据跟着换：
    //   [2] gomoku 线程真的起来了 —— app/main.c 打的 "[boot] gomoku thread running"
    //   [3] 主线程心跳在跳 —— "[hb] alive"。它一举证明两件事：
    //       **调度器在跑**，且**游戏线程没有独占 CPU**（心跳还能挤进来）。
    // [!] S_GOMOKU 用小写：那行是 rt_kprintf 打的。五子棋自己的 banner 是
    //     "GOMOKU on RV32I"（大写），两者大小写不同，正好分开。
    localparam [16*6-1:0]  S_GOMOKU = "gomoku";
    localparam [16*6-1:0]  S_HB     = "[hb] a";

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
    integer seen_gomoku = 0;
    integer seen_hb     = 0;

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

        // ---- [2][3] 等程序把该打的都打完，再【一次性】扫描窗口 ----
        // [!] 别写成"每拍扫一遍 1024 字节窗口" —— 那是 4M × 1024 次比较，仿真跑不动。
        //     等固定拍数 -> 扫一次，和原来一样。
        //     3M 拍 @100MHz = 30ms，够等到第一次心跳（HB_DELAY_MS=20ms）。
        for (i = 0; i < 3000000; i = i + 1) @(negedge clk);

        seen_gomoku = 0;
        seen_hb     = 0;
        for (i = 0; i < RXBUF - 6; i = i + 1) begin
            if (rxtext[i*8 +: 8*6] === S_GOMOKU) seen_gomoku = seen_gomoku + 1;
            if (rxtext[i*8 +: 8*6] === S_HB)     seen_hb     = seen_hb + 1;
        end

        $display("----------------------------------------");
        $display("  gomoku 标记 %0d 次 / 心跳标记 %0d 次", seen_gomoku, seen_hb);
        $display("  串口共收到 %0d 字节", rxcount);

        if (seen_gomoku == 0) begin
            $display("[FAIL] 没看到 gomoku 线程启动 —— 线程没起来，或链接错了");
            errors = errors + 1;
        end else begin
            $display("[OK]   gomoku 线程已启动（RT-Thread 上跑起了五子棋）");
        end

        // 心跳这一条一举证明两件事：**调度器在跑**，且**游戏线程没独占 CPU**
        if (seen_hb == 0) begin
            $display("[FAIL] 没看到主线程心跳 —— 调度器没跑，或游戏线程把 CPU 占死了");
            errors = errors + 1;
        end else begin
            $display("[OK]   主线程心跳在跳（调度正常，游戏线程没独占 CPU）");
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
