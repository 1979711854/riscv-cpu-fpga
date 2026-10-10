`timescale 1ns/1ps
// CoreMark 运行测试台：周期计数 + UART 字符拦截 + tohost 结束判分
//   - core 对 0xFFFC 的 store 视为输出一个字符（uart_send_char）
//   - core 对 0xFFF8 的 store 1 视为结束（start.S 里 main 返回后写）
//   - CoreMark/MHz = ITERATIONS * 1e6 / 总周期数

// 统一存储器行为模型（指令/数据共用一块，A 口取指、B 口访存）
`include "mem_model.vh"


module coremark_tb;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    // 周期计数（提前声明：下面 core 例化就要用到 cycle_count）
    reg [63:0] cycle_count;

    // core ↔ mem_bus 的取指口与访存口
    wire [13:0] imem_addr;     // 与 core / mem_bus 的端口同宽（64KB = 16384 word），别改窄
    wire [31:0] imem_rd;
    wire [13:0] imem_addr2;    // 与 core / mem_bus 的端口同宽（64KB），别改窄
    wire [31:0] imem_rd2;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_ready;   // 访存就绪：mem_bus 出，core 入（访存等待机制）
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;
    wire        irq_timer;      // mem_bus 里的 CLINT：mtime >= mtimecmp

    // 双发射开关：编译时加 -DDUAL 即用 DUAL_ISSUE=1 核跑分。
    // [!] 脚本必须【显式】传该宏：run_coremark.ps1 默认双发射，加 -Single 才切单发射。
    //     不传 = 单发射，会与板上（双发射）比特流对不上 —— 每迭代周期数也随之不同
    //     （单发射 363,515 / 双发射 313,886），混了会把得分算错（2026-10-06 修）。
`ifdef DUAL
    localparam DUAL_OUT = 1;
`else
    localparam DUAL_OUT = 0;
`endif

    // 自证配置：t=0 打印本测试台编译进去的 DUAL_ISSUE，每份日志首行自带口径。
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d", DUAL_OUT);

    core #(.DUAL_ISSUE(DUAL_OUT)) u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .ebreak(),
        // CoreMark 全程不碰 CSR、中断关闭（mstatus.MIE=0、mie=0），
        // 接真实 MTIP 也不会被受理；接上是为了不让端口悬空成 Z。
        .irq_timer(irq_timer),
        .irq_ext  (1'b0)
    );

    // mem_bus 自带周期计数器（0xFFF4 的读回源），与 tb 的 cycle_count 同时复位、
    // 同步递增，故 get_time() 读数与改造前一致。
    mem_bus u_bus (
        .clk(clk), .resetn(resetn),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .gpio_we(), .uart_tx_we(), .uart_rx_ack(),
        .periph_wdata(), .gpio_rdata(32'd0), .uart_rx_rdata(32'd0),
        .done(),           // 周期计数器已从 mem_bus 去掉（无使用者）
        // 接真实 MTIP：CoreMark 全程 MIE=0 且 mtimecmp 复位为全 1，
        // 所以它恒为低、不影响结果；接上是为了不让端口悬空成 Z。
        .irq_timer(irq_timer)
    );

    // ========================================================================
    // 流水线效率剖析（+PROF / +TRACE，默认关闭）
    // ------------------------------------------------------------------------
    // 设计原则：**纯被动观测**。这里只读 core 的内部信号，不驱动 core 的任何
    // 输入。prof_on=0 时计数器不递增、不打印，所以 run_coremark.ps1 的默认运行
    // （不带 +PROF）周期数与加入本段之前完全一致 —— 这是回归纪律的硬要求。
    //
    // 之所以能这样做：core 的 stall / mc_stall / ex_flush / 四路
    // 前递判定都是模块内部信号，用层次引用（u_core.xxx）即可观测，不需要为了
    // 测量去改 RTL（改 RTL 会触发全量回归）。
    //
    //   +PROF              打印周期构成统计 + 每 5 万拍直方图
    //   +TRACE_START=<n>   第 n 拍起逐拍打印五级流水线状态
    //   +TRACE_LEN=<m>     连续打印 m 拍（默认 64）
    //   +TRACE_FILE=<path> trace 输出文件（默认 programs/trace.txt）
    // ========================================================================
    integer      prof_on;
    integer      trace_start_cyc, trace_len, trace_left, trace_fd;
    reg [1023:0] trace_fname;

    // +PAIRTRACE：默认关。**纯被动观测**（同 +PROF 纪律），不影响周期数。
    // 在 CoreMark 计时区间内逐条流出 retired {pc, instr}，供 Python 复放双发射
    // 配对规则、估算动态配对率 p。影子链镜像 v_* 的推进/清零，{pc,instr} 取自 IF/ID。
    integer      pairtr_on, pairtr_fd;
    reg [63:0]   pr_ex, pr_mem, pr_wb;   // {pc[31:0], instr[31:0]}

    // 周期构成累计
    reg [63:0] c_stall, c_div, c_mul, c_flush;
    reg [63:0] c_fwdex, c_fwdwb, c_mem, c_br_taken, c_jump;
    reg [63:0] c_commit, c_inst_in;

    // 条件分支的方向细分。
    // **设计分支预测器需要 not-taken 的条数** —— 现在 not-taken 是零代价的，
    // 预测器一旦猜错就会给它加上惩罚，所以必须知道分母。
    // 同时按 imm[31]（偏移正负）分出前向/后向，用来评估"后向分支预测跳转"
    // 这条静态规则的命中率。
    //
    // 这些计数一律挂在**解析结果**（id_ex_branch / branch_taken / id_ex_jump*）上，
    // 【不】挂在 ex_flush 上 —— 加了预测之后，预测正确的 taken 不再产生 ex_flush，
    // 挂在冲刷信号上的计数会塌掉，改造前后也就没法比。
    //   c_br_tot  = 到达 EX 的条件分支总数（每条恰好计一次：分支的 id_ex_is_div=0，
    //               所以 mc_stall=0，ID/EX 必在下一拍推进；stall/ex_flush 会清零
    //               id_ex_branch，也不会重复计）
    //   c_br_bwd  = 其中偏移为负（后向，通常是循环回边）
    reg [63:0] c_br_tot, c_br_bwd, c_br_bwd_tk;
    // jal / jalr 拆分：前者目标只依赖 if_id_pc+imm，ID 级就能算，可静态预测；
    // 后者目标是 (rs1+imm)&~1，依赖寄存器值，ID 级没有前递通路，预测不了。
    // 两者的条数比直接决定"ID 级预测"能覆盖多少冲刷事件。
    reg [63:0] c_jal, c_jalr;
    // 分支预测事件：ID 级重定向（预测生效）与 EX 级误判恢复
    reg [63:0] c_redir, c_mispred;

    // CoreMark 计时区间内的同类统计。
    // 依据：core_portme.c 里 start_time()/stop_time() 各是一次读 MMIO 0xFFF4
    // （barebones_clock），在访存口上是 mem_re && mem_addr==0xFFF4，可精确观测。
    // 有了区间边界才能把"纯 CoreMark 算法"的 CPI 从"含串口打印"的总 CPI 里剥出来
    // —— 打印区间是纯轮询，会把 CPI 严重拉高，两者混算没有意义。
    reg [63:0] t_timer_cyc [0:7];
    integer    t_timer_n;
    reg        in_timed;
    reg [63:0] tc_all, tc_stall, tc_div, tc_mul, tc_flush;
    reg [63:0] tc_fwdex, tc_fwdwb, tc_mem, tc_commit;
    reg [63:0] tc_br_tot, tc_br_tk, tc_br_bwd, tc_br_bwd_tk;
    reg [63:0] tc_jal, tc_jalr;
    reg [63:0] tc_redir, tc_mispred;

    // 影子流水线 valid：逐级镜像 core 的清零/暂停条件，用来数"真正提交的指令数"。
    // 不能直接用 mem_wb_reg_write 计数 —— store/branch/jump 不回写寄存器，会被漏掉。
    reg v_id, v_ex, v_mem, v_wb;

    // 直方图：32 桶 × 5 万拍 = 160 万拍，覆盖 ITER=1 全程
    localparam NH = 32, HBUCKET = 50000;
    reg [63:0] h_stall [0:NH-1];
    reg [63:0] h_flush [0:NH-1];
    reg [63:0] h_mem   [0:NH-1];
    reg [63:0] h_cmt   [0:NH-1];
    integer    h_idx, h_cnt, pi, ph;

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100MHz

    initial begin
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    // 周期计数
    initial cycle_count = 0;
    always @(posedge clk) begin
        if (resetn) cycle_count <= cycle_count + 1;
    end

    // 迭代次数（+ITER=）
    integer iter;
    initial begin
        if (!$value$plusargs("ITER=%d", iter)) iter = 1;
    end

    // 剖析开关与 trace 参数
    initial begin
        prof_on         = 0;
        pairtr_on       = 0;
        pairtr_fd       = 0;
        trace_start_cyc = -1;
        trace_len       = 64;
        trace_left      = 0;
        trace_fd        = 0;
        trace_fname     = "programs/trace.txt";
        if ($test$plusargs("PROF")) prof_on = 1;
        if ($test$plusargs("PAIRTRACE")) begin
            pairtr_on = 1;
            pairtr_fd = $fopen("programs/pairtrace.txt", "w");
        end
        $value$plusargs("TRACE_START=%d", trace_start_cyc);
        $value$plusargs("TRACE_LEN=%d",   trace_len);
        $value$plusargs("TRACE_FILE=%s",  trace_fname);
        t_timer_n = 0;
        for (pi = 0; pi < 8; pi = pi + 1) t_timer_cyc[pi] = 64'd0;
        for (pi = 0; pi < NH; pi = pi + 1) begin
            h_stall[pi] = 64'd0; h_flush[pi] = 64'd0;
            h_mem[pi]   = 64'd0; h_cmt[pi]   = 64'd0;
        end
    end

    // UART：core 对 0xFFFC 的 store 视为输出一个字符
    // （用真访存端口；mem_wdata 已按 sb 字节复制，[7:0] 与原始 store 数据一致）
    always @(posedge clk) begin
        if (resetn && u_core.mem_we && u_core.mem_addr == 32'hFFFC)
            $write("%c", u_core.mem_wdata[7:0]);
    end

    // tohost：core 对 0xFFF8 store 1 视为结束
    reg done;
    initial done = 0;
    always @(posedge clk) begin
        if (resetn && !done && u_core.mem_we
            && u_core.mem_addr == 32'hFFF8
            && u_core.mem_byte_en[0] && u_core.mem_wdata[7:0] == 8'd1) begin
            done <= 1;
            $display("\n=== CoreMark finished ===");
            $display("iterations   : %0d", iter);
            $display("total cycles : %0d", cycle_count);
            if (cycle_count > 0)
                $display("CoreMark/MHz : %f",
                         (iter * 1000000.0) / cycle_count);
            // ---- 流水线效率剖析（+PROF 时才有内容）----
            if (prof_on) begin
                $display("");
                $display("=== pipeline profile ===");
                $display("committed instr  : %0d", c_commit);
                $display("if/id loads      : %0d", c_inst_in);
                if (c_commit > 0)
                    $display("CPI              : %f",
                             cycle_count / (c_commit * 1.0));
                $display("--- cycle composition ---");
                $display("load-use stall   : %0d  %f%%", c_stall,
                         (c_stall * 100.0) / cycle_count);
                $display("div stall        : %0d  %f%%", c_div,
                         (c_div * 100.0) / cycle_count);
                // mul 条数（每条恰好多占 1 拍 EX）。这是"乘法器拆成两拍"代价的
                // 唯一可靠口径 —— 静态推算（按每迭代一次 matrix_test 算 N 和条数）
                // 会小 5.8 倍：core_bench_matrix 其实是被 core_list_join.c 的
                // calc_func 在链表遍历中按数据相关次数调用的。
                // 2026-09-28 实测区间值 = 9,396 条/迭代。
                $display("mul executed     : %0d", c_mul);
                $display("br/jmp redirect  : %0d  %f%%", c_flush,
                         (c_flush * 100.0) / cycle_count);
                // 气泡数 = 总周期 − 提交指令数。这是【与冲刷实现无关】的口径：
                // 不去假设每次冲刷值几拍，直接看有多少拍没提交指令。
                // 历史教训：此前文档把分支惩罚误记为 2 拍，就是"拍数假设"惹的祸。
                $display("pipeline bubbles : %0d  %f%%", cycle_count - c_commit,
                         ((cycle_count - c_commit) * 100.0) / cycle_count);
                $display("--- events ---");
                $display("taken branches   : %0d", c_br_taken);
                $display("jumps jal/jalr   : %0d", c_jump);
                // 全局分支构成 —— 回归探针（total cycles）是【全局】周期数，
                // 所以推演"这次改动能省多少拍"必须用全局计数，
                // 拿 coremark 计时区间的计数去减全局周期是口径错误。
                $display("  cond branches  : %0d  (bwd %0d, bwd&taken %0d)",
                         c_br_tot, c_br_bwd, c_br_bwd_tk);
                $display("  jal %0d  jalr %0d", c_jal, c_jalr);
                $display("  arrival redirect %0d  mispredict %0d", c_redir, c_mispred);
                $display("fwd from ex/mem  : %0d", c_fwdex);
                $display("fwd from mem/wb  : %0d", c_fwdwb);
                $display("mem accesses     : %0d", c_mem);
                $display("--- coremark timed region (start_time -> stop_time) ---");
                $display("timer reads seen : %0d", t_timer_n);
                if (t_timer_n >= 1) $display("start_time cycle : %0d", t_timer_cyc[0]);
                if (t_timer_n >= 2) $display("stop_time  cycle : %0d", t_timer_cyc[1]);
                $display("region cycles    : %0d", tc_all);
                $display("region commit    : %0d", tc_commit);
                if (tc_commit > 0)
                    $display("region CPI       : %f", tc_all / (tc_commit * 1.0));
                if (tc_all > 0) begin
                    $display("region stall     : %0d  %f%%", tc_stall,
                             (tc_stall * 100.0) / tc_all);
                    $display("region div stall : %0d  %f%%", tc_div,
                             (tc_div * 100.0) / tc_all);
                    $display("region mul exec  : %0d", tc_mul);
                    $display("region flush     : %0d  %f%%", tc_flush,
                             (tc_flush * 100.0) / tc_all);
                    $display("region fwd ex    : %0d", tc_fwdex);
                    $display("region fwd wb    : %0d", tc_fwdwb);
                    $display("region mem acc   : %0d", tc_mem);
                    $display("--- branch direction (region) ---");
                    $display("cond branches    : %0d", tc_br_tot);
                    $display("  taken          : %0d", tc_br_tk);
                    $display("  not taken      : %0d", tc_br_tot - tc_br_tk);
                    $display("  backward       : %0d", tc_br_bwd);
                    $display("  bwd & taken    : %0d", tc_br_bwd_tk);
                    $display("  bwd & not-taken: %0d", tc_br_bwd - tc_br_bwd_tk);
                    $display("  forward        : %0d", tc_br_tot - tc_br_bwd);
                    $display("  fwd & taken    : %0d", tc_br_tk - tc_br_bwd_tk);
                    $display("--- jumps (region) ---");
                    $display("  jal            : %0d", tc_jal);
                    $display("  jalr           : %0d", tc_jalr);
                    $display("  arrival redirect : %0d", tc_redir);
                    $display("  mispredict     : %0d", tc_mispred);
                    if (tc_br_bwd > 0)
                        $display("  bwd taken rate : %f%%",
                                 (tc_br_bwd_tk * 100.0) / tc_br_bwd);
                    // 这里【只报原始计数】，不报"预测器能省多少拍" —— 那取决于
                    // 具体实现能达到几拍惩罚，是要随设计变的假设，混进测试台
                    // 会让人把假设当成实测。推演见 doc/ila_analysis.md 的优化章节。
                end
                $display("--- histogram (bucket = %0d cycles) ---", HBUCKET);
                for (ph = 0; ph < NH; ph = ph + 1)
                    $display("h %0d stall=%0d flush=%0d mem=%0d commit=%0d",
                             ph, h_stall[ph], h_flush[ph], h_mem[ph], h_cmt[ph]);
            end
            if (pairtr_on && pairtr_fd != 0) $fclose(pairtr_fd);
            $finish;
        end
    end

    // 超时保护
    initial begin
        #1000000000;
        $display("\n=== TIMEOUT (pc=0x%h) ===", pc);
        $finish;
    end

    // ========================================================================
    // 剖析主逻辑（只在 +PROF 时工作）
    // ========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            c_stall <= 64'd0; c_div <= 64'd0; c_mul <= 64'd0; c_flush <= 64'd0;
            c_fwdex <= 64'd0; c_fwdwb <= 64'd0; c_mem <= 64'd0;
            c_br_taken <= 64'd0; c_jump <= 64'd0;
            c_br_tot <= 64'd0; c_br_bwd <= 64'd0; c_br_bwd_tk <= 64'd0;
            c_jal <= 64'd0; c_jalr <= 64'd0;
            c_redir <= 64'd0; c_mispred <= 64'd0;
            c_commit <= 64'd0; c_inst_in <= 64'd0;
            v_id <= 1'b0; v_ex <= 1'b0; v_mem <= 1'b0; v_wb <= 1'b0;
            pr_ex <= 64'd0; pr_mem <= 64'd0; pr_wb <= 64'd0;
            h_idx <= 0; h_cnt <= 0;
            t_timer_n <= 0;
            in_timed  <= 1'b0;
            tc_all <= 64'd0; tc_stall <= 64'd0; tc_div <= 64'd0; tc_mul <= 64'd0;
            tc_flush <= 64'd0;
            tc_fwdex <= 64'd0; tc_fwdwb <= 64'd0; tc_mem <= 64'd0;
            tc_commit <= 64'd0;
            tc_br_tot <= 64'd0; tc_br_tk <= 64'd0;
            tc_br_bwd <= 64'd0; tc_br_bwd_tk <= 64'd0;
            tc_jal <= 64'd0; tc_jalr <= 64'd0;
            tc_redir <= 64'd0; tc_mispred <= 64'd0;
        end else if (prof_on || pairtr_on) begin
            // ---- 影子流水线（镜像 core 各段寄存器的清零/暂停条件）----
            // [!] 冻结判据一律用 core 的 mc_stall（多拍功能单元停顿的并集：
            //     除法 or 乘法），不能只用 div_stall —— 那样乘法的 1 拍停顿
            //     会被当成"流水线正常推进"，提交指令数会被多算。
            v_wb  <= v_mem;
            v_mem <= u_core.mc_stall ? 1'b0 : v_ex;
            v_ex  <= (u_core.ex_flush || u_core.ex_mispred || u_core.stall) ? 1'b0 :
                     (u_core.mc_stall ? v_ex : v_id);
            v_id  <= (u_core.ex_flush || u_core.ex_mispred) ? 1'b0 :
                     ((!u_core.stall && !u_core.mc_stall) ? 1'b1 : v_id);
            if (v_wb) c_commit <= c_commit + 64'd1;

            // ---- +PAIRTRACE 影子链：镜像 v_* 的推进/清零，携带 {pc,instr} ----
            pr_wb  <= pr_mem;
            pr_mem <= u_core.mc_stall ? 64'd0 : pr_ex;
            pr_ex  <= (u_core.ex_flush || u_core.ex_mispred || u_core.stall) ? 64'd0 :
                      (u_core.mc_stall ? pr_ex : {u_core.if_id_pc, u_core.if_id_instr});
            if (pairtr_on && in_timed && v_wb)
                $fdisplay(pairtr_fd, "%08h %08h", pr_wb[63:32], pr_wb[31:0]);
            if (!u_core.ex_flush && !u_core.ex_mispred &&
                !u_core.stall && !u_core.mc_stall)
                c_inst_in <= c_inst_in + 64'd1;

            // ---- 周期构成 ----
            if (u_core.stall)      c_stall  <= c_stall + 64'd1;
            if (u_core.div_stall)  c_div    <= c_div + 64'd1;
            // mul_start 每条 mul 恰好高 1 拍（见 multiplier.v），所以它直接就是
            // 动态 mul 条数 —— 这也是"乘法器拆成两拍"代价的唯一实测口径。
            if (u_core.mul_start)  c_mul    <= c_mul + 64'd1;
            if (u_core.ex_flush)   c_flush  <= c_flush + 64'd1;
            if (u_core.fwd_a_ex || u_core.fwd_b_ex) c_fwdex <= c_fwdex + 64'd1;
            if (u_core.fwd_a_wb || u_core.fwd_b_wb) c_fwdwb <= c_fwdwb + 64'd1;
            if (u_core.mem_re  || u_core.mem_we)    c_mem   <= c_mem + 64'd1;
            // 事件计数一律挂在【解析结果】上，而不是 ex_flush。
            // 理由：加了分支预测之后，预测正确的 taken 不再产生 ex_flush，
            // 挂在冲刷信号上的计数会直接塌掉，改造前后也就没法比。
            // 每条指令在 EX 只停留一拍（见声明处注释），所以不会重复计数。
            if (u_core.id_ex_branch) begin
                c_br_tot <= c_br_tot + 64'd1;
                if (u_core.id_ex_imm[31]) c_br_bwd <= c_br_bwd + 64'd1;
                if (u_core.branch_taken) begin
                    c_br_taken <= c_br_taken + 64'd1;
                    if (u_core.id_ex_imm[31]) c_br_bwd_tk <= c_br_bwd_tk + 64'd1;
                end
            end
            if (u_core.p_redirect) c_redir   <= c_redir   + 64'd1;
            if (u_core.ex_mispred)  c_mispred <= c_mispred + 64'd1;
            if (u_core.id_ex_jump)     c_jal  <= c_jal  + 64'd1;
            if (u_core.id_ex_jump_reg) c_jalr <= c_jalr + 64'd1;
            if (u_core.id_ex_jump || u_core.id_ex_jump_reg)
                c_jump <= c_jump + 64'd1;

            // ---- CoreMark 计时区间（start_time→stop_time，即两次读 0xFFF4）----
            if (u_core.mem_re && u_core.mem_addr == 32'hFFF4) begin
                if (t_timer_n < 8) begin
                    t_timer_cyc[t_timer_n] <= cycle_count;
                    t_timer_n <= t_timer_n + 1;
                end
                in_timed <= (t_timer_n == 0) ? 1'b1 : 1'b0;
            end
            if (in_timed) begin
                tc_all <= tc_all + 64'd1;
                if (u_core.stall)     tc_stall  <= tc_stall + 64'd1;
                if (u_core.div_stall) tc_div    <= tc_div + 64'd1;
                if (u_core.mul_start) tc_mul    <= tc_mul + 64'd1;
                if (u_core.ex_flush)  tc_flush  <= tc_flush + 64'd1;
                if (u_core.fwd_a_ex || u_core.fwd_b_ex) tc_fwdex <= tc_fwdex + 64'd1;
                if (u_core.fwd_a_wb || u_core.fwd_b_wb) tc_fwdwb <= tc_fwdwb + 64'd1;
                if (u_core.mem_re || u_core.mem_we)     tc_mem   <= tc_mem + 64'd1;
                if (v_wb)             tc_commit <= tc_commit + 64'd1;
                if (u_core.id_ex_branch) begin
                    tc_br_tot <= tc_br_tot + 64'd1;
                    if (u_core.id_ex_imm[31]) tc_br_bwd <= tc_br_bwd + 64'd1;
                    if (u_core.branch_taken) begin
                        tc_br_tk <= tc_br_tk + 64'd1;
                        if (u_core.id_ex_imm[31])
                            tc_br_bwd_tk <= tc_br_bwd_tk + 64'd1;
                    end
                end
                if (u_core.p_redirect) tc_redir   <= tc_redir   + 64'd1;
                if (u_core.ex_mispred)  tc_mispred <= tc_mispred + 64'd1;
                if (u_core.id_ex_jump)     tc_jal  <= tc_jal  + 64'd1;
                if (u_core.id_ex_jump_reg) tc_jalr <= tc_jalr + 64'd1;
            end

            // ---- 直方图 ----
            if (h_idx < NH) begin
                if (u_core.stall)     h_stall[h_idx] <= h_stall[h_idx] + 64'd1;
                if (u_core.ex_flush)  h_flush[h_idx] <= h_flush[h_idx] + 64'd1;
                if (u_core.mem_re || u_core.mem_we)
                                      h_mem[h_idx]   <= h_mem[h_idx] + 64'd1;
                if (v_wb)             h_cmt[h_idx]   <= h_cmt[h_idx] + 64'd1;
            end
            if (h_cnt == HBUCKET - 1) begin
                h_cnt <= 0;
                if (h_idx < NH - 1) h_idx <= h_idx + 1;
            end else begin
                h_cnt <= h_cnt + 1;
            end
        end
    end

    // ========================================================================
    // 逐拍五级流水线 trace（+TRACE_START/+TRACE_LEN），用于画时序波形图。
    // 输出到独立文件，避免与 UART 的 $write 字符流混在一起。
    // ========================================================================
    always @(posedge clk) begin
        if (resetn && prof_on && trace_start_cyc >= 0) begin
            if (trace_left == 0 && cycle_count == trace_start_cyc) begin
                trace_fd   = $fopen(trace_fname, "w");
                trace_left = trace_len;
            end
            if (trace_left > 0 && trace_fd != 0) begin
                $fdisplay(trace_fd,
                    "T cyc=%0d pc=%h ipc=%h ins=%h epc=%h eop=%h erd=%h mpc=%h mrd=%h mwe=%b mre=%b wrd=%h wwe=%b st=%b dv=%b fl=%b fd=%b ir=%b faex=%b fbex=%b fawb=%b fbwb=%b vid=%b vex=%b vmem=%b vwb=%b br=%b bt=%b jmp=%b jr=%b",
                    cycle_count, pc,
                    u_core.if_id_pc, u_core.if_id_instr,
                    u_core.id_ex_pc, u_core.id_ex_alu_op, u_core.id_ex_rd,
                    u_core.ex_mem_pc, u_core.ex_mem_rd,
                    u_core.mem_we, u_core.mem_re,
                    u_core.mem_wb_rd, u_core.mem_wb_reg_write,
                    u_core.stall, u_core.mc_stall,
                    u_core.ex_flush, u_core.ex_mispred, u_core.p_redirect,
                    u_core.fwd_a_ex, u_core.fwd_b_ex,
                    u_core.fwd_a_wb, u_core.fwd_b_wb,
                    v_id, v_ex, v_mem, v_wb,
                    u_core.id_ex_branch, u_core.branch_taken,
                    u_core.id_ex_jump, u_core.id_ex_jump_reg);
                trace_left = trace_left - 1;
                if (trace_left == 0) $fclose(trace_fd);
            end
        end
    end
endmodule
