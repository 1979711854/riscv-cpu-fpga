`timescale 1ns/1ps
// ============================================================================
// cache_i —— L1 指令 Cache（**默认 4 KB / 侧**、2 路组相联、行 = 1 字；16 KB/侧 把 IDX_BITS 改 11）
// ----------------------------------------------------------------------------
// 定位：赛题高阶任务①「2 路组相联 I/D Cache」。**默认关**（ICACHE_EN=0 时本模块
// 不被例化，取指通路逐位不变）。与 cache_d.v 同构，但有两处**结构性的**不同，
// 都必须先看懂再改：
//
// ============================================================================
// [重点] 一、停顿信号必须是【寄存过的】，否则和 fetch_addr 成组合环
// ----------------------------------------------------------------------------
// 取指口没有就绪信号（core.v 的契约是"地址发出后恰好 1 拍数据有效"），所以只能
// 借 mem_ready 当取指停顿 —— core 的 freeze 通路（fetch_addr 退回 if_addr_d、
// IF/ID 保持）本来就把"重读同一个地址"做得严丝合缝。
//
// 但**取指地址就是 fetch_addr 本身**，而 fetch_addr 的组合 mux 里有一项是
// `!mem_ready_int`。于是：
//
//     hit_any(fetch_addr) → stall → mem_ready → fetch_addr → hit_any(fetch_addr)
//
// 这是一个真组合环（PDS 会报，仿真会解成不定态）。**破法是让 stall 先过一级寄存器**：
//
//     i_stall_c(N) = !hit_any(N) && !stall_r(N) && !rst_busy   ← 纯"观察"
//     stall_r(N+1) = i_stall_c(N)                              ← 寄存器
//     mem_ready    = mem_ready_core && !stall_r                ← 环被寄存器切断
//
// 代价是停顿比缺失晚一拍，于是时序变成（A = 缺失那一下的取指地址）：
//
//   N    : 发出地址 A，命中判定 miss → i_stall_c=1。IF/ID 照常锁存上一条。
//   N+1  : stall_r=1 → mem_ready=0 → 冻结。fetch_addr 退回 if_addr_d = A（同一个地址）。
//          后端 BRAM 这一拍读的正是 A ⇒ bram_rdata(N+2) = mem[A]。
//          **本沿把这一行回填**（数据就是 bram_rdata(N+1) = mem[A]，见下）。
//   N+2  : stall_r=0 → mem_ready=1 → 放行。
//          imem_rd(N+2) 走 bypass = bram_rdata(N+2) = mem[A]（阵列同址刚写过，不能用），
//          IF/ID 在 N+2→N+3 沿锁存 (if_addr_d(N+2)=A, imem_rd(N+2)=mem[A]) —— 对齐。
//
//   所以一次缺失花 2 拍；**bypass 也只要一拍**（就是 N+2 那一拍）。
//   [重点] 回填地址直接用当拍的 idx —— 因为停顿期间地址被冻在 A，idx 就是 A 的索引，
//   不需要另外存 idx_r（这一点和"地址会继续往前跑"的第一版设计不同，踩过）。
//
// ============================================================================
// [重点] 二、只缓存 A1（imem_addr），A2（imem_addr2）仍然直通 BRAM
// ----------------------------------------------------------------------------
//   A2 = A1 + 1，是双发射的第二读口、只喂 pair 判定。给它也做一份 Cache 要多
//   两个数据阵列（+16KB BRAM）+ 两套 tag，面积翻倍，换来的只是"配对取指少
//   一次缺失"。而 A2 恒 1 拍就绪、与 A1 天然同拍对齐（都是"地址发在 T、数据
//   在 T+1"），**不缓存它不引入任何停顿**，也不破坏 A1/A2 的对齐关系。
//   [!] 停顿期间 A1 冻住、A2 也跟着冻（imem_addr2 = imem_addr + 1 是组合推导的），
//       所以两者的对齐在任何情况下都成立。
//
// 组织结构、替换策略、复位清扫同 cache_d.v（指令不被写，所以这里没有 store 通路）。
// ============================================================================
module cache_i #(
    parameter IDX_BITS = 9,         // set 索引位宽 → 512 组（4KB/侧；16KB 用 11）
    parameter TAG_BITS = 5          // tag 位宽 = 14 − IDX_BITS（IDX=9 → 5）
) (
    input  wire        clk,
    input  wire        resetn,

    // ---- 取指口 A1（每个周期都在取指，所以没有 req）----
    input  wire [13:0] word,        // = imem_addr（fetch_addr[15:2]）
    input  wire [31:0] bram_rdata,  // 后端 BRAM 的 A1 读数据（T+1 有效）

    // ---- 输出 ----
    output wire        stall,       // 【已寄存】的取指停顿，mem_bus 直接压 mem_ready
    output wire [31:0] rdata,       // T+1 的取指数据（= imem_rd）
    output wire        hit_pulse,
    output wire        miss_pulse
);

    localparam NSET = (1 << IDX_BITS);

    // ------------------------------------------------------------------
    // 地址切片
    // ------------------------------------------------------------------
    wire [IDX_BITS-1:0] idx      = word[IDX_BITS-1:0];
    wire [TAG_BITS-1:0] addr_tag = word[13:IDX_BITS];

    // ------------------------------------------------------------------
    // 复位清扫：2048 拍逐个把 tag 阵列的有效位清 0（理由同 cache_d.v）
    // ------------------------------------------------------------------
    reg              rst_busy;
    reg [IDX_BITS:0] rst_cnt;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rst_busy <= 1'b1;
            rst_cnt  <= {IDX_BITS+1{1'b0}};
        end else if (rst_busy) begin
            rst_cnt <= rst_cnt + 1'b1;
            if (rst_cnt == NSET - 1) rst_busy <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // tag 阵列（组合读 → LUTRAM；每项 5 位 = {valid, recent, tag[2:0]}）
    // ------------------------------------------------------------------
    reg [TAG_BITS+1:0] tag0 [0:NSET-1];
    reg [TAG_BITS+1:0] tag1 [0:NSET-1];

    wire [TAG_BITS+1:0] t0 = tag0[idx];
    wire [TAG_BITS+1:0] t1 = tag1[idx];

    wire v0 = t0[TAG_BITS+1];
    wire r0 = t0[TAG_BITS];
    wire v1 = t1[TAG_BITS+1];
    wire r1 = t1[TAG_BITS];
    wire hit0 = !rst_busy && v0 && (t0[TAG_BITS-1:0] == addr_tag);
    wire hit1 = !rst_busy && v1 && (t1[TAG_BITS-1:0] == addr_tag);
    wire hit_any = hit0 | hit1;

    // ------------------------------------------------------------------
    // 数据阵列（同步读 1 拍 —— 与 unified_mem 的 A1 口同相）
    // ------------------------------------------------------------------
    reg [31:0] d0 [0:NSET-1];
    reg [31:0] d1 [0:NSET-1];
    reg [31:0] d0_q, d1_q;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            d0_q <= 32'd0;
            d1_q <= 32'd0;
        end else begin
            d0_q <= d0[idx];
            d1_q <= d1[idx];
        end
    end

    // ------------------------------------------------------------------
    // 停顿（必须是寄存过的，理由见文件头）
    // ------------------------------------------------------------------
    reg stall_r;
    // [!] `&& !stall_r` 是必需的：缺了它，停顿那一拍重新查同一行（还没回填）仍是
    //     miss，会把停顿无限延长。加上它，一次缺失恰好停 1 拍（共 2 拍完成）。
    wire stall_c = !hit_any && !stall_r && !rst_busy;

    // [!] 缺失那一下的 index / tag / 两路 tag 快照必须【存下来】。
    //   理由：停顿那一拍 fetch_addr 虽然被冻在 if_addr_d，但 **trap / ex_flush /
    //   ex_mispred 有更高优先级**（core.v 的 mux 顺序），它们不受 mem_ready 门控，
    //   所以那一拍的 imem_addr 可能已经跳到重定向目标上了。
    //   若回填直接用当拍的 idx，就会"把 A 的数据写进重定向目标那一行的索引" ——
    //   缓存被静默写坏，之后命中的就是错指令（实测 CoreMark 死循环在 0x84/0x88，
    //   而小测试因为边角场景少，49/1/0 全过，看不出来）。
    reg [IDX_BITS-1:0] idx_r;
    reg [TAG_BITS-1:0] tag_r;
    reg [TAG_BITS+1:0] t0_r, t1_r;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) stall_r <= 1'b0;
        else         stall_r <= stall_c;
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            idx_r <= {IDX_BITS{1'b0}};
            tag_r <= {TAG_BITS{1'b0}};
            t0_r  <= {TAG_BITS+2{1'b0}};
            t1_r  <= {TAG_BITS+2{1'b0}};
        end else if (stall_c) begin
            idx_r <= idx;
            tag_r <= addr_tag;
            t0_r  <= t0;
            t1_r  <= t1;
        end
    end

    assign stall = stall_r;

    // 回填的 way：优先无效路，其次 recent=0 的那路（NRU）
    // [!] 用的是【缺失那一下的快照】t0_r/t1_r，理由见上面 idx_r 的注释。
    wire fv0 = t0_r[TAG_BITS+1];
    wire fv1 = t1_r[TAG_BITS+1];
    wire fr0 = t0_r[TAG_BITS];
    wire fr1 = t1_r[TAG_BITS];
    wire way_fill = !fv0       ? 1'b0 :
                    !fv1       ? 1'b1 :
                    (fr0 & ~fr1) ? 1'b1 : 1'b0;

    // ------------------------------------------------------------------
    // tag 写入：清扫 > 回填 > 命中更新（三级优先）
    // ------------------------------------------------------------------
    wire [TAG_BITS+1:0] upd0 = hit0 ? {1'b1, 1'b1, t0[TAG_BITS-1:0]} :
                             {v0,   1'b0, t0[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] upd1 = hit1 ? {1'b1, 1'b1, t1[TAG_BITS-1:0]} :
                             {v1,   1'b0, t1[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] fil_hit  = {1'b1, 1'b1, tag_r};
    wire [TAG_BITS+1:0] fil_oth0 = {fv0, 1'b0, t0_r[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] fil_oth1 = {fv1, 1'b0, t1_r[TAG_BITS-1:0]};

    wire tag_req = hit_any && !stall_r;         // 命中：更新 recent
    wire tag_fil = stall_r && !rst_busy;        // 停顿那一拍：回填

    wire       tag_we   = rst_busy | tag_fil | tag_req;
    wire [IDX_BITS-1:0] tag_widx = rst_busy ? rst_cnt[IDX_BITS-1:0] :
                                   tag_fil ? idx_r : idx;

    reg [TAG_BITS+1:0] tag0_nxt, tag1_nxt;
    always @(*) begin
        if (rst_busy) begin
            tag0_nxt = {TAG_BITS+2{1'b0}};
            tag1_nxt = {TAG_BITS+2{1'b0}};
        end else if (tag_fil) begin
            tag0_nxt = way_fill ? fil_oth0 : fil_hit;
            tag1_nxt = way_fill ? fil_hit  : fil_oth1;
        end else begin
            tag0_nxt = upd0;
            tag1_nxt = upd1;
        end
    end

    always @(posedge clk) begin
        if (tag_we) begin
            tag0[tag_widx] <= tag0_nxt;
            tag1[tag_widx] <= tag1_nxt;
        end
    end

    // ------------------------------------------------------------------
    // 数据阵列写入：只有回填一条路（指令不被写）
    // ------------------------------------------------------------------
    wire data_fil = tag_fil;

    always @(posedge clk) begin
        if (data_fil) begin
            if (way_fill == 1'b0) d0[idx_r] <= bram_rdata;
            else                  d1[idx_r] <= bram_rdata;
        end
    end

    // ------------------------------------------------------------------
    // 读数据选择
    // ------------------------------------------------------------------
    // [!] 只有"上一拍真的命中"才用阵列数据，**其余一律回退后端 BRAM**。
    //   这一条同时解决三件事，比单用一个 bypass 标志稳：
    //     1) 复位清扫期（forced miss）—— 阵列还是未初始化的 X，用它会
    //        把 X 送进 imem_rd → IF/ID → PC（实测 pc 变 0xxxxxxxxx，整颗 CPU 死掉）。
    //     2) 回填那一沿是"同址读+写"，数据阵列输出不定。
    //     3) 后端 BRAM 本来就是每个周期都在读同一个地址，数据永远是对的
    //        （地址要么被冻住、要么没变），所以回退零代价。
    reg hit0_r, hit1_r;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            hit0_r <= 1'b0;
            hit1_r <= 1'b0;
        end else begin
            hit0_r <= hit0;
            hit1_r <= hit1;
        end
    end

    assign rdata = (hit0_r | hit1_r) ? (hit0_r ? d0_q : d1_q)
                                     : bram_rdata;

    // ------------------------------------------------------------------
    // 计数器脉冲
    // ------------------------------------------------------------------
    assign hit_pulse  = hit_any && !stall_r && !rst_busy;
    assign miss_pulse = stall_c;

endmodule
