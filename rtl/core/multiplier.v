`timescale 1ns/1ps
// ============================================================================
// multiplier —— 两拍乘法器（操作数寄存一拍，组合乘法，第二拍出结果）
// ----------------------------------------------------------------------------
// 【为什么要它】M 扩展的 32×32→64 乘法原本是【单拍组合】的，综合报告显示它占
// 关键路径的约 56%（10.05 ns），而且那条路径的起点是 BRAM —— 也就是
//      lw 之后紧跟一条 mul
// 这种序列：访存数据从 BRAM 出来（Tco + 布线 2.98 ns），穿过按字节解包
// （1.87 ns）、前递 mux（1.64 ns），最后还要在同一个周期里走完 4 级 APM 乘法链。
//
// 把乘法器摘出来单独占两拍，那 10 ns 就从关键路径上消失了。
//
// 【代价】每条 mul 多占 1 拍 EX —— 实测【恰好】是 1 拍，不是估计值。
//   [!] 条数【不能靠静态推算】：`core_bench_matrix` 并不是每迭代调一次，
//       它是被 core_list_join.c 的 calc_func（链表遍历，带"结果缓存"）按
//       【数据相关】的次数调用的。按"每迭代一次 matrix_test"推会得到
//       2N² + 2N³ = 1,620 条（N=9，CoreMark Size 666），**比真值小 5.8 倍**。
//       2026-09-28 实测（+PROF 的 c_mul / tc_mul 计数器）：
//           region mul exec = **9,396 条/迭代**
//       即 +9,396 / 354,119 = **+2.65%**，区间周期 354,119 → 363,515。
//   闭合验证：288,056（提交）+ 20,720（load-use）+ 9,396（mul）+ 45,343（分支）
//             = 363,515 —— 分支损失 45,343 与改动前文档记录完全一致，
//             说明这次改动【只】动了 mul 这一项，其余分毫未动。
//
// 【握手】完全照抄 divider.v 的 start/busy/done 约定，core.v 那边复用同一套
//   多拍停顿逻辑（mc_stall），不新增任何冻结路径 —— 这是刻意的：那套冻结逻辑
//   在 +MEMWAIT 下被反复验证过，复用它远比重写一套安全。
//
// 【时序】
//   第 T   拍：start=1（core 里 = id_ex_is_mul && !busy），锁存 a/b/op；
//             本拍 result 是【陈旧值】，但 core 那边 mc_stall=1 会清 EX/MEM，
//             不会有人采它（与 divider 在迭代期间的中间值同理）。
//   第 T+1 拍：done=1，result 有效（组合逻辑，输入是寄存器 ⇒ 有整拍时间）。
//   core 在 T+1 把 result 打进 EX/MEM，T+2 起下一条指令进 EX。
// ============================================================================
module multiplier (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,       // 电平：idle 且 start=1 时锁存操作数
    input  wire [31:0] a,           // 已前递的操作数 1
    input  wire [31:0] b,           // 已前递的操作数 2
    input  wire [1:0]  op,          // 0=MUL 1=MULH 2=MULHSU 3=MULHU
    output wire [31:0] result,      // 组合输出，done=1 时有效
    output wire        busy,
    output wire        done
);
    reg [31:0] r_a, r_b;
    reg [1:0]  r_op;

    // 只用一个"操作数有效"标志就够 —— 它同时是 busy 和 done：
    //   busy=1 → core 不会再发 start（start = is_mul && !busy）；
    //   done=1 → core 认为结果已就绪，把 result 打进 EX/MEM。
    // 两者在时间上完全重合（操作数锁存后的那一拍），所以合成一根信号。
    // （与 divider 不同：divider 要迭代 33 拍，busy 与 done 是两回事。）
    reg        r_valid;

    assign busy = r_valid;
    assign done = r_valid;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            r_valid <= 1'b0;
            r_a     <= 32'd0;
            r_b     <= 32'd0;
            r_op    <= 2'd0;
        end else begin
            r_valid <= start;
            if (start) begin
                r_a  <= a;
                r_b  <= b;
                r_op <= op;
            end
        end
    end

    // 组合乘法，输入是寄存器 ⇒ 有整拍时间。
    // 数学与 alu.v 里那一版完全一致：一个 32×32 无符号乘法 + 符号修正。
    //   * 三种符号组合的【低 32 位相同】—— (a·b) mod 2^32 与符号无关；
    //   * 高 32 位只差修正项，而修正项都带 <<32，不会向位 31 借位。
    // 详见 alu.v 顶部的推导。
    wire [63:0] pu     = {32'd0, r_a} * {32'd0, r_b};
    wire [31:0] corr_a = r_a[31] ? r_b : 32'd0;
    wire [31:0] corr_b = r_b[31] ? r_a : 32'd0;
    wire [31:0] hi_ss  = pu[63:32] - corr_a - corr_b;   // MUL/MULH 的高半
    wire [31:0] hi_su  = pu[63:32] - corr_a;            // MULHSU  的高半

    assign result = (r_op == 2'd0) ? pu[31:0]  :   // MUL
                    (r_op == 2'd1) ? hi_ss     :   // MULH
                    (r_op == 2'd2) ? hi_su     :   // MULHSU
                                     pu[63:32];     // MULHU
endmodule
