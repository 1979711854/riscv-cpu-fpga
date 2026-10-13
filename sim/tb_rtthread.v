`timescale 1ns/1ps
// ============================================================================
// RT-Thread 移植验证测试台
// ----------------------------------------------------------------------------
// 跑整个 SoC（core + mem_bus + gpio + uart_tx + uart_rx），把 UART TX 按真实波特率
// 解码成字节流，然后检查 scripts/rtthread/app/main.c 那四个自检是否成立：
//
//   [1] 控制台通了        —— 出现 RT-Thread banner
//   [2] render 线程起来了 —— 出现 "[boot] gomoku render thread running"
//   [3] AI 线程起来了      —— 出现 "[boot] gomoku ai thread running"（任务 T1/G3 拆线程）
//   [4] 调度器在跑         —— 主线程心跳 "[hb] alive" 出现。
//       这一条一举证明两件事：**调度器正常**，且**render 线程没把 CPU 独占死**
//       （心跳还挤得进来）。
//
// [任务 H 说明] 本测试台原来验的是 ping/pong 双线程移植（信号量 + 上下文切换）。
// 那条已经完成使命，应用换成五子棋后判据跟着换。ping/pong 版本在 git 历史里。
// 任务 T1/G3 又把单线程五子棋拆成 render + AI，于是多了 [3] 这条 AI 线程判据。
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
//
// [!] **本测试台必须接【视频口】**（2026-10-10 实踩，CPU 被 X 污染的根因）。
//     cpu_top 的 vid_* 是"显存/控制寄存器 → video_top"的透传口，注释里写着
//     "仿真里这几个测试台不接，而它们也从不访问 0x8001_0000 以上 ⇒ vid_rdata
//      的浮空值不会进 mem_rdata"。**任务 H 之后这句话的前提没了**：
//     五子棋要 video_set_scroll / video_wait_vblank / draw_frame，
//     第一次读 0x8003_0408（VIDEO_STATUS）就让 `mem_rdata = vid_rdata`（悬空 → Z）
//     进了寄存器堆 → Z 参与运算变 X → **PC 变成 0xxxxxxxxx，整颗 CPU 在 ~16ms 死掉**。
//     症状极具迷惑性：串口把 banner 打完就静默、心跳永远不出现，
//     看着像"调度器没跑"或"延时没到"，其实是 CPU 已经没了。
//     （这正是 CLAUDE.md 关键约定 4 / 13：外设任何时候都不该把 X 放上总线。）
//     所以这里照 tb_gomoku.v 的接法接上真正的 video_core（不接的话见上）。
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

    // 视频口（mem_bus 译码出来的显存/控制寄存器口）—— 必须接，见文件头 [!]
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;
    wire [31:0] vid_rdata;

    wire [23:0] v_rgb;
    wire        v_de, v_hs, v_vs;

    always #5 clk = ~clk;          // 100MHz 仿真时钟（与本目录其它测试台一致）

    // ---- 配置开关（照 tb_coremark.v 的写法：脚本必须【显式】传，默认关）----
    // [!] 2026-10-14：本测试台原来一个 -D 都不吃，全靠 cpu_top 的参数默认值
    //     （DUAL_ISSUE=1 / EARLY_LD=1 / Cache 关）⇒ rtthread 线的仿真从来没覆盖过
    //     Cache 配置。rtthread + I+D @76.5 位流（c10a2478）上板确定性挂死
    //     （AI 第一手后第一张棋盘快照处数据损坏）就是这么漏过去的（CLAUDE.md 约定 55）。
    //     现在四个开关全部显式化：run_sim.ps1 默认传 -DDUAL -DEARLYLD（= 板上口径），
    //     -DCache/-ICache 追加；vvp 首行 SIM CONFIG 自证，别再靠默认值。
`ifdef DUAL
    localparam DUAL_OUT = 1;
`else
    localparam DUAL_OUT = 0;
`endif
`ifdef DCACHE
    localparam DCACHE_OUT = 1;
`else
    localparam DCACHE_OUT = 0;
`endif
`ifdef ICACHE
    localparam ICACHE_OUT = 1;
`else
    localparam ICACHE_OUT = 0;
`endif
`ifdef EARLYLD
    localparam EARLYLD_OUT = 1;
`else
    localparam EARLYLD_OUT = 0;
`endif

    // 自证配置：t=0 打印本测试台编译进去的四个开关，每份日志首行自带口径
    //（与 tb_riscv/tb_coremark 同一格式，回归脚本靠它核对，见 CLAUDE.md 约定 37）。
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d DCACHE_EN=%0d ICACHE_EN=%0d EARLY_LD=%0d",
                     DUAL_OUT, DCACHE_OUT, ICACHE_OUT, EARLYLD_OUT);

    cpu_top #(.DUAL_ISSUE(DUAL_OUT), .DCACHE_EN(DCACHE_OUT),
              .ICACHE_EN(ICACHE_OUT), .EARLY_LD(EARLYLD_OUT)) u_soc (
        .clk        (clk),
        .resetn     (resetn),
        .pc         (pc),
        .uart_tx    (uart_tx),
        .uart_rx    (uart_rx),
        .led        (led),
        .key        (key),
        .done       (done),
        .vid_we     (vid_we),
        .vid_vsel   (vid_vsel),
        .vid_waddr  (vid_waddr),
        .vid_be     (vid_be),
        .vid_wdata  (vid_wdata),
        .vid_vsel_d (vid_vsel_d),
        .vid_waddr_d(vid_waddr_d),
        .vid_rdata  (vid_rdata)
    );

    // video_top 那层壳（pll_video / rgb2tmds / OSERDES）是 PDS 专有原语，
    // iverilog 里不存在，所以直接例化 video_core —— 与 tb_gomoku.v 同一套接法。
    // [!] 时钟：clk 同时当 pix_clk 和 clk_sys（显存是真双口，仿真里同源无妨）。
    //     本测试台不检查 rgb/de/hs/vs（那是 tb_gomoku / tb_video_bars 的事），
    //     接上它只是为了让 vid_rdata 有确定的驱动源。
    video_core u_vid (
        .pix_clk    (clk),
        .vid_resetn (resetn),
        .clk_sys    (clk),
        .sys_resetn (resetn),
        .vid_we     (vid_we),
        .vid_vsel   (vid_vsel),
        .vid_waddr  (vid_waddr),
        .vid_be     (vid_be),
        .vid_wdata  (vid_wdata),
        .vid_vsel_d (vid_vsel_d),
        .vid_waddr_d(vid_waddr_d),
        .vid_rdata  (vid_rdata),
        .rgb        (v_rgb),
        .de         (v_de),
        .hs         (v_hs),
        .vs         (v_vs)
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
            // [调试 2026-10-14] 挂死现场用：逐字节打 pc —— 每个 UART 字节是哪个 pc
            // 写出来的，配合"写之前 pc 停在哪"定位损坏点（与无 Cache 跑同一条固件对拍）。
            // [!] 默认【关】：一次正常跑也有 168 行，会把日志淹掉。要开就
            //     scripts\rtthread\run_sim.ps1 -RxTrace
`ifdef RXTRACE
            $display("[rx#%0d] pc=0x%h byte=0x%02x", rxcount, pc, rxb);
`endif
        end
    end

    // 需要看的字符串（用 CRLF 常量拼，不要写字面量 \r）
    localparam [16*9-1:0]  S_BANNER = "RT-Thread";
    // [任务 T1/G3] 应用从"单线程五子棋"拆成了 render + AI 两条线程，判据跟着换：
    //   [2] render 线程起来了 —— app/main.c 打的 "[boot] gomoku render thread running"
    //       AI   线程起来了 —— "[boot] gomoku ai thread running"（S_AI 单独验这条，
    //       证明"拆线程"真的生效，不只是有一个 gomoku 线程）。
    //   [3] 主线程心跳在跳 —— "[hb] alive"。它一举证明两件事：
    //       **调度器在跑**，且**render 线程没有独占 CPU**（心跳还能挤进来）。
    // [!] S_GOMOKU 用小写：那行是 rt_kprintf 打的。五子棋自己的 banner 是
    //     "GOMOKU on RV32I"（大写），两者大小写不同，正好分开。
    // [!] S_AI 取 "ai thr"（小写）：只匹配 AI 线程启动行，不碰 render 行/HUD 的 "AI"（大写）。
    localparam [16*6-1:0]  S_GOMOKU = "gomoku";
    localparam [16*6-1:0]  S_AI     = "ai thr";
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
    integer seen_ai     = 0;
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
        seen_ai     = 0;
        seen_hb     = 0;
        for (i = 0; i < RXBUF - 6; i = i + 1) begin
            if (rxtext[i*8 +: 8*6] === S_GOMOKU) seen_gomoku = seen_gomoku + 1;
            if (rxtext[i*8 +: 8*6] === S_AI)     seen_ai     = seen_ai + 1;
            if (rxtext[i*8 +: 8*6] === S_HB)     seen_hb     = seen_hb + 1;
        end

        $display("----------------------------------------");
        $display("  收尾时 pc=0x%h（挂死调试用：与无 Cache 跑对拍）", pc);
        $display("  gomoku 标记 %0d 次 / AI 线程标记 %0d 次 / 心跳标记 %0d 次", seen_gomoku, seen_ai, seen_hb);
        $display("  串口共收到 %0d 字节", rxcount);

        if (seen_gomoku == 0) begin
            $display("[FAIL] 没看到 gomoku 线程启动 —— 线程没起来，或链接错了");
            errors = errors + 1;
        end else begin
            $display("[OK]   gomoku 线程已启动（RT-Thread 上跑起了五子棋）");
        end

        // G3 拆线程的专属判据：AI 线程单独起了一条启动行
        if (seen_ai == 0) begin
            $display("[FAIL] 没看到 AI 线程启动 —— 拆线程没生效，还是单线程在跑");
            errors = errors + 1;
        end else begin
            $display("[OK]   AI 线程已启动（render + AI 拆线程生效）");
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
