`timescale 1ns/1ps
// ============================================================================
// multiplier —— 【A1】II=1 流水线乘法器（latency 2，每拍可收一条）
// ----------------------------------------------------------------------------
// 【为什么是现在这样（2026-10-12 改，路径 A / 任务 A1）】
//   上一版是"锁存操作数 → 组合乘法 → done"的【阻塞】两拍乘法器：每条 mul 占
//   EX 两拍（core 的 mul_stall 插 1 拍气泡）。实测代价 = 每条 1 拍；
//   CoreMark 每迭代 9,396 条 mul ⇒ 9,396 拍（3.89%）。
//
//   本版把它改成流水线：仍然锁存操作数（第 0 级），但把【已选中的乘法结果】再打
//   一拍（第 1 级），于是
//       第 T   拍：start 有效 → 锁存 a/b/op，并用它们组合算出结果（→ q_res 的 D 端）
//       第 T+1 拍：q_res 有效；同拍 core 已让这条 mul 前进到 EX/MEM
//       第 T+2 拍：这条 mul 在 MEM/WB，core 用 mem_wb_is_mul 选中 q_res 写回
//   ⇒ latency 2、II=1（busy 恒 0，每拍都能收新的一条）。
//
// 【时序为什么是中性的】新旧两版的**路径深度完全一样**，只是终点寄存器换了名字：
//   旧：r_a/r_b(寄存器) → 4 级 APM 链 + 符号修正减法 + 4 选 1 → ex_mem 寄存器
//   新：r_a/r_b(寄存器) → 4 级 APM 链 + 符号修正减法 + 4 选 1 → q_res 寄存器
//   多出来的一拍只是把结果又寄存一次 ⇒ 关键路径不变长（q_res → WB mux 是纯布线）。
//   [!] 这也是当初把单拍组合乘法"摘出来"的同一个理由：起点若是 BRAM
//       （`lw` 之后紧跟一条 `mul`），那段 Tco + 解包 + 前递 mux 才是要躲开的东西。
//
// 【消费者侧的代价转移】latency 变 2 后，"紧邻下一条就读本结果"的消费者必须停
//   1 拍 —— core.v 的 stall 里为此加了 mul 项（判据与 load-use 同构）。
//   实测（+PROF 的 `region mul near` 计数器，2026-10-12）：
//       CoreMark 每迭代 9,396 条 mul 里**只有 108 条**落在这一类（1.15%）
//       ⇒ 净省 9,396 − 108 = **9,288 拍（3.84%）**。
//   [!] 这个数【不能靠静态推算】：162 个静态 mul 站点里 83.3% 在后续 5 条内没有
//       消费者，但静态条数与动态次数差得远（老注释记的教训：静态推算曾小 5.8 倍）。
// 【[!] 使能必须与流水线寄存器同源（2026-10-12 实踩，+MEMWAIT=3 抓到）】
//   乘法器是【自由流动】的两级流水线，而 core 的 EX/MEM / MEM/WB 在
//   `mem_ready_int=0` 时是【保持】的。若乘法器不跟着冻住，`q_res` 会继续前进而
//   `ex_mem_is_mul` / `mem_wb_is_mul` 停住 ⇒ **错位**，WB 取到的是别的 mul 的结果。
//   症状极隐蔽：`+MEMWAIT=0/1/2` 全对，只有 `+MEMWAIT=3`（停顿足够密）CRC 变。
//   所以 `en` 必须接 core 的 `mem_ready_int`（EX/MEM 与 MEM/WB 的同一个条件）：
//       第 0 级在"EX/MEM 收 ID/EX"那一拍锁操作数；
//       第 1 级在"MEM/WB 收 EX/MEM"那一拍锁结果。
//   两者同源 ⇒ 无论怎么停顿，`mem_wb_is_mul` 与 `q_res` 永远对齐。
// ============================================================================
module multiplier (
    input  wire        clk,
    input  wire        resetn,
    input  wire        en,          // 流水线使能：必须与 EX/MEM、MEM/WB 寄存器同源
    input  wire        start,       // 电平：en=1 且每拍高就收一条（II=1，无握手）
    input  wire [31:0] a,           // 已前递的操作数 1
    input  wire [31:0] b,           // 已前递的操作数 2
    input  wire [1:0]  op,          // 0=MUL 1=MULH 2=MULHSU 3=MULHU
    output wire [31:0] result,      // start 之后【第 2 拍】有效
    output wire        busy,        // II=1 ⇒ 恒 0（保留端口，core 侧不再用它停顿）
    output wire        done         // = result 有效
);
    // ---- 第 0 级：操作数 ----
    reg [31:0] r_a, r_b;
    reg [1:0]  r_op;
    reg        v0;
    // ---- 第 1 级：已选中的结果 ----
    reg [31:0] q_res;
    reg        v1;

    assign busy   = 1'b0;
    assign done   = v1;
    assign result = q_res;

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

    wire [31:0] sel = (r_op == 2'd0) ? pu[31:0]  :      // MUL
                      (r_op == 2'd1) ? hi_ss     :      // MULH
                      (r_op == 2'd2) ? hi_su     :      // MULHSU
                                       pu[63:32];       // MULHU

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            r_a   <= 32'd0;
            r_b   <= 32'd0;
            r_op  <= 2'd0;
            v0    <= 1'b0;
            q_res <= 32'd0;
            v1    <= 1'b0;
        end else if (en) begin
            // 第 0 级：每拍都收（II=1）
            v0 <= start;
            if (start) begin
                r_a  <= a;
                r_b  <= b;
                r_op <= op;
            end
            // 第 1 级：把组合结果打一拍 —— 第 T 拍收的，第 T+2 拍出现在 result 上
            q_res <= sel;
            v1    <= v0;
        end
        // [!] en=0 时整体【保持】—— 这一条是承重的，见文件头"使能必须同源"。
    end
endmodule
