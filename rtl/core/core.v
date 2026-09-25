`timescale 1ns/1ps
module core (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] pc,            // = pc_r，板级调试/示波用

    // ---- 取指口（A 口）----
    // 契约：同步读、恰好 1 拍延迟（第 T 拍给地址 → 第 T+1 拍出数据）、只读、
    // 且【不做任何仲裁/冲突检测】。本模块的 stall/flush 补偿逻辑依赖 A 口
    // 每拍都能独立工作，加仲裁会直接破坏取指时序。
    output wire [12:0] imem_addr,     // word 索引；注意是 stall mux 之后的值
    input  wire [31:0] imem_rd,       // 同步读 1 拍延迟

    // ---- 访存口（MEM 级）----
    // 时序契约见 rtl/bus/mem_bus.v 头注释：
    //   第 T   拍 (MEM)：本模块给出 mem_addr / mem_wdata / mem_byte_en / mem_we
    //   第 T+1 拍 (WB) ：mem_rdata 必须是 mem_addr(T) 对应地址的读数据
    // 本模块【不知道存储器映射】——译码、RAM、外设全在 mem_bus 里。
    output wire [31:0] mem_addr,      // = ex_mem_alu_result（完整 32 位）
    output reg  [31:0] mem_wdata,     // 已按 sb/sh/sw 做过字节复制
    output reg  [3:0]  mem_byte_en,
    output wire        mem_we,
    output wire        mem_re,
    input  wire [31:0] mem_rdata,

    // ---- 中断源（电平，高有效）----
    // 直接对应 mip 的两个位，内核把它们与 mie / mstatus.MIE 相与后裁决。
    // 之所以是电平而不是脉冲：中断的采样点在 EX 级，且要求"软件清源后自动落下"
    // （见 csr_file.v / mem_bus.v 的说明）。
    input  wire        irq_timer,     // → mip.MTIP（bit7）  定时器
    input  wire        irq_ext,       // → mip.MEIP（bit11） 外部

    // ---- 系统指令钩子 ----
    // EBREAK 提交时给出一拍脉冲。顶层用它"停机"（点亮 done LED）。
    // 注意：EBREAK 现在【同时】是 mcause=3 的异常 —— 本输出只保留"停机钩子"这一
    // 职责，供演示程序与 tb_demo.v 使用；异常路径由 csr_file 处理。
    output wire        ebreak
);

    // ================= IF =================
    reg [31:0] pc_r;
    assign pc = pc_r;

    // ------------------------------------------------------------------
    // 前置声明：这些级间寄存器/关键信号在模块后段才被赋值，但前面的
    // assign 与例化要先用到。原文件把声明写在后面，iverilog 14 会报
    // "Unable to bind wire/reg/memory ... declaration after use"（旧版容忍）。
    // 这里【只把声明提前】，逻辑一行未改。
    // ------------------------------------------------------------------
    // 冒险 / 除法
    wire        stall /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;
    wire [31:0] div_result;
    wire        div_busy, div_done;
    wire        div_stall /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;
    wire        ex_flush /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;
    wire [31:0] ex_target;      // EX 级解析出的跳转目标（在 EX 段才被赋值）
    // 分支预测：ID 级重定向 / EX 级误判恢复（三段都在后文才被赋值）
    wire        id_redirect /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;    // ID 级已按预测重定向（三处都要引用它）
    wire [31:0] id_target;      // ID 级算出的预测目标
    wire        ex_mispred /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;     // 预测 taken 但实际 not-taken
    wire [31:0] ex_mispred_target;

    // ---- 异常 / 中断 ----
    wire        trap;           // 本拍在 EX 级发生异常或中断（最高优先级重定向）
    wire [31:0] trap_target;    // = mtvec 的 BASE
    wire [31:0] trap_cause;     // 写进 mcause
    wire [31:0] trap_tval;      // 写进 mtval
    wire        ex_exception;   // 同步异常（不含中断）
    wire        int_take;       // 中断被受理
    wire        mret_commit;    // EX 级正在执行 mret（要跳 mepc）
    // CSR 通路（csr_file 的输出）
    wire [31:0] csr_rdata;
    wire [31:0] csr_mtvec_base, csr_mepc;
    wire        csr_mstatus_mie, csr_mie_mtie, csr_mie_meie;
    wire        csr_wr_illegal;
    wire [31:0] csr_wdata;
    wire        csr_wr_en;
    // ID/EX
    reg        id_ex_reg_write, id_ex_alu_a_sel, id_ex_alu_b_sel, id_ex_mem_write;
    // 单独声明：要给它挂 ILA 调试属性，故从上面那行拆出
    reg        id_ex_mem_read /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;
    reg        id_ex_branch, id_ex_jump, id_ex_jump_reg;
    reg        id_ex_pred_taken;   // 该指令在 ID 级是否【实际发生过】预测重定向
    // ID/EX 里是否真的有一条指令（不是气泡）。
    // [重点] 中断受理必须看它：否则在"上一条指令刚重定向、ID/EX 已清空"的那一拍，
    //   若此时 MIE 恰好为 1（例如 mret 刚把 MIE 从 MPIE 恢复），中断会被受理，
    //   而 mepc 取的是 id_ex_pc —— 气泡的 id_ex_pc 是 0，于是 mepc 被写成 0，
    //   随后的 mret 直接跳到地址 0。2026-09-23 实测踩到，现象是测试莫名重启。
    reg        id_ex_valid;
    reg [4:0]  id_ex_alu_op;
    reg [1:0]  id_ex_wb_sel;
    reg [31:0] id_ex_pc, id_ex_rdata1, id_ex_rdata2, id_ex_imm;
    reg [4:0]  id_ex_rd, id_ex_rs1, id_ex_rs2;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_sys_ebreak;
    // CSR / 系统指令（随指令带进 EX）
    reg        id_ex_is_csr, id_ex_illegal, id_ex_sys_ecall, id_ex_mret;
    reg [11:0] id_ex_csr_addr;
    reg [1:0]  id_ex_csr_cmd;
    reg        id_ex_csr_imm;
    // EX/MEM
    reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    reg [1:0]  ex_mem_wb_sel;
    reg [31:0] ex_mem_alu_result, ex_mem_wdata, ex_mem_pc, ex_mem_imm;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_sys_ebreak;
    // MEM/WB
    reg        mem_wb_reg_write;
    reg [1:0]  mem_wb_wb_sel;
    reg [31:0] mem_wb_alu_result, mem_wb_pc, mem_wb_imm;
    reg [4:0]  mem_wb_rd;
    reg [2:0]  mem_wb_funct3;
    reg [1:0]  mem_wb_addr_low;
    // 写回数据
    wire [31:0] wb_data;
    // ------------------------------------------------------------------

    // 访存口：MEM 级组合输出，一拍的稳定窗口，直接进总线（写通路零寄存器）
    assign mem_we   = ex_mem_mem_write;
    assign mem_re   = ex_mem_mem_read;
    assign mem_addr = ex_mem_alu_result;
    // EBREAK 现在走异常路径（mcause=3），指令在 EX 就被杀掉、永远到不了 EX/MEM，
    // 所以顶层停机钩子改从 trap 事件上取。板级 done LED 的语义因此从
    // "EBREAK 提交了"变成"发生了 EBREAK 断点"，更贴切。
    // （实测不破坏任何东西：demo.c 是死循环，走不到 start.S 里的 ebreak；
    //   tb_demo.v 的检查项恰恰是"done 未被拉起"。）
    assign ebreak   = trap && (trap_cause == 32'd3);

    // 指令存储器已移出到 mem_bus（与数据共用一块双端口 BRAM 的 A 口）。
    // 注意：这里送出的 imem_addr 必须是下面 mux 【之后】的值，不是 pc_r ——
    // stall 时要靠它退回 if_addr_d 重读同一 word，详见 PC 段注释。

    // 取指地址对齐：if_addr_d 记录【本拍实际发出的取指地址】—— imem_rd 下一拍
    // 给的就是它的数据，而它随后又当 if_id_pc 用。
    //   注意语义是"实际发出的地址"，【不是 pc_r】：跳转那一拍地址被下面的
    //   fetch_addr 旁路成目标地址，此后 pc_r 与已发出的地址不再相等。
    //   必须保持 32 位、不能截断成 13 位 —— 它要当 if_id_pc 进 id_ex_pc，
    //   是 jal 链接值与分支目标的来源，截断会让 0x2000 以上代码算错返回值。
    reg [31:0] if_addr_d;

    // 本拍真正发出的取指地址。
    // 跳转目标在这里【当拍】旁路进去，而不是等 pc_r 下一拍更新 —— 同步读 BRAM
    // 使取指有 1 拍延迟，提前一拍发地址就能省下一拍惩罚。三路重定向共用这一个
    // 出口，pc_r 那边也必须相应跳过已发出的地址（见 PC 段注释）。
    //
    // 优先级：
    //   1. ex_flush    —— EX 级是【更老】的指令，它要跳转时 ID 级指令本来就会被
    //                     杀掉，所以它永远优先
    //   2. ex_mispred  —— 次老，同理
    //   3. id_redirect —— ID 级预测重定向（本身已用 !ex_flush 门控，这里再排一次
    //                     只为把优先级写成自明的）
    //   4. stall/div    —— 退格重读，不改变地址流
    //
    // 互斥性说明：ex_flush 来自 EX 是分支/跳转、div_stall 来自 EX 是除法
    // （id_ex_is_div）、stall 来自 EX 是 load（id_ex_mem_read）—— 三者在 EX 级由
    // 同一条指令的性质决定，互斥。
    //   trap 优先级最高：异常/中断时 EX 级那条指令必须被丢弃，
    //   它比任何分支重定向都优先。（mret 不在这里 —— 它折进了 ex_flush，见 EX 段。）
    wire [31:0] fetch_addr = trap                ? trap_target :
                             ex_flush            ? ex_target :
                             ex_mispred          ? ex_mispred_target :
                             id_redirect         ? id_target :
                             (stall || div_stall) ? if_addr_d :
                                                    pc_r;

    // 更新【无门控】：fetch_addr 在 stall/div_stall 时就等于 if_addr_d 自身，
    // 所以"照抄回去"是空操作，等价于原来的 `if (!stall && !div_stall)` 门控。
    //
    // [!] 原来那个门控必须去掉，因为 `trap && stall` 是**可达的**
    //（EX 里是未对齐的 load 时，ex_exception 与 load-use stall 同拍成立）。
    // 那时 fetch_addr = trap_target 而门控会拦住更新 → if_addr_d 停在旧值
    // → 下一拍的 if_id_pc 与指令对不上。这个坑基线测试碰不到，只有自写的
    // trap handler 会炸，属于"静默错位"那一类。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) if_addr_d <= 32'd0;
        else if_addr_d <= fetch_addr;
    end

    // ================= IF/ID =================
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // IF/ID 里是否是一条【真指令】（而不是冲刷或取指填充期留下的气泡）。
    // 判据 `|imem_rd` 与"全零字按气泡处理"的约定一致 —— 0x00000000 既不是
    // 合法指令，也正是取指同步读的填充期会自然产生的值（见 control.v 的说明）。
    //
    // 它最终决定 id_ex_valid，而 id_ex_valid 决定"中断能不能在这一拍被受理"。
    // 少了它，气泡的 id_ex_pc(=0) 会被写进 mepc，mret 之后直接跳到地址 0。
    reg if_id_valid;

    // ================= ID =================
    wire [4:0] rs1 = if_id_instr[19:15];
    wire [4:0] rs2 = if_id_instr[24:20];
    wire [4:0] rd  = if_id_instr[11:7];

    wire        reg_write, alu_a_sel, alu_b_sel, mem_read, mem_write, branch, jump, jump_reg;
    wire [4:0]  alu_op;
    wire [1:0]  wb_sel;
    wire        sys_ebreak;
    wire        is_csr, csr_imm, sys_ecall, sys_mret, id_illegal;
    wire [11:0] csr_addr;
    wire [1:0]  csr_cmd;
    control u_ctrl (
        .instr      (if_id_instr),
        .reg_write  (reg_write),
        .alu_a_sel  (alu_a_sel),
        .alu_b_sel  (alu_b_sel),
        .alu_op     (alu_op),
        .mem_read   (mem_read),
        .mem_write  (mem_write),
        .branch     (branch),
        .jump       (jump),
        .jump_reg   (jump_reg),
        .wb_sel     (wb_sel),
        .sys_ebreak (sys_ebreak),
        .is_csr     (is_csr),
        .csr_addr   (csr_addr),
        .csr_cmd    (csr_cmd),
        .csr_imm    (csr_imm),
        .sys_ecall  (sys_ecall),
        .sys_mret   (sys_mret),
        .illegal    (id_illegal)
    );

    wire [31:0] rdata1, rdata2;
    regfile u_regfile (
        .clk(clk), .resetn(resetn), .we(mem_wb_reg_write),
        .rs1(rs1), .rs2(rs2), .rd(mem_wb_rd),
        .wd(wb_data), .rdata1(rdata1), .rdata2(rdata2)
    );

    wire [31:0] imm;
    imm_gen u_imm (.instr(if_id_instr), .imm(imm));

    // ================= ID 级分支预测 =================
    // 静态规则（作为 BHT 未命中 / jal 的兜底）：条件分支且偏移为负（后向）→ 预测跳转；
    //                      无条件 jal → 必跳转，同样预测。
    //
    // 为什么选这条静态规则而不是 2 位饱和计数器 BHT —— 实测支撑：
    //   CoreMark 计时区间内条件分支 53,173 条，其中后向 25,664 条、90.8% 都是
    //   taken；前向 27,509 条里只有 6,101 条 taken。后向占近半且绝大多数跳转，
    //   静态规则已能捕获绝大部分收益；BHT 只多拿约 1%（那 6,101 条前向 taken），
    //   却要付出 PC 索引表与更多流水线标志位的面积和验证风险。
    //
    // 为什么不需要 BTB：这两类的目标都只依赖 if_id_pc + imm，ID 级就齐备，
    // 而且与 EX 级算出的目标【必然相同】（id_ex_pc == if_id_pc、id_ex_imm == imm），
    // 所以不存在"预测对了方向但目标算错"的情形。
    // jalr 的目标依赖 rs1，ID 级没有前递通路，因此【不预测】，仍走 EX 冲刷
    // （实测约占冲刷事件的 5%）。
    // ---- 动态预测（保守版）：带 tag 的 256 项 2 位饱和计数器 BHT，只预测条件分支方向 ----
    // jal 无条件必跳、目标只依赖 if_id_pc+imm，仍走静态预测；jalr 目标依赖 rs1、ID 级无
    // 前递通路，仍【不预测】走 EX 冲刷。保守版因此不需要 BTB 的 target 部分：branch/jal 的
    // 目标与 EX 级算出的必然相同，不存在"预测对方向但目标算错"（那只可能由 jalr 引起）。
    // 索引 idx=PC[9:2]、tag=PC[31:8]，直接映射 256 项。预测错不影响正确性：EX 级冲刷兜住。
    reg [23:0] bht_tag  [0:255];
    reg [1:0]  bht_ctr  [0:255];
    reg [255:0] bht_valid;

    wire [7:0] bht_idx   = if_id_pc[9:2];
    wire       bht_hit /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */   = bht_valid[bht_idx] && (bht_tag[bht_idx] == if_id_pc[31:8]);
    wire       bht_taken /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */ = bht_ctr[bht_idx][1];

    wire        id_pred_taken /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */ = (branch && bht_hit) ? bht_taken
                                                    : ((branch && imm[31]) || jump);
    assign      id_target     = if_id_pc + imm;

    // ex_flush 优先：EX 级是更老的指令，它重定向时 ID 级指令本来就会被杀掉。
    // stall / div_stall 时 ID/EX 不前进或保持，重定向必须一并抑制，否则 pc_r 与
    // 流水线状态会脱节。
    assign      id_redirect   = id_pred_taken && !ex_flush && !stall && !div_stall;

    // ================= hazard (load-use stall only；其余 RAW 由 forwarding 解决) =================
    assign stall = (id_ex_mem_read && (id_ex_rd != 5'd0) &&
                    ((id_ex_rd == rs1) || (id_ex_rd == rs2)));

    // 取指地址：stall 时退一格到在途指令 if_addr_d 让同步读重新锁存正确数据，
    // 跳转时当拍旁路到目标（见上面 fetch_addr 的说明）。
    assign imem_addr = fetch_addr[14:2];

    // ================= ID/EX =================
    // （级间寄存器声明已提前到文件顶部，避免 forward reference）

    // ================= EX =================
    // ---- EX 阶段 forwarding（优先级：EX/MEM > MEM/WB > 寄存器读） ----
    // EX/MEM 写回候选值；load(wb_sel=01) 的数据要 WB 才有效，不从此处前递
    wire [31:0] ex_mem_forward_val =
        (ex_mem_wb_sel == 2'b10) ? (ex_mem_pc + 32'd4) :
        (ex_mem_wb_sel == 2'b11) ? ex_mem_imm :
        ex_mem_alu_result;
    wire fwd_a_ex /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */ = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                    (ex_mem_rd == id_ex_rs1) && (ex_mem_wb_sel != 2'b01);
    wire fwd_a_wb /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */ = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1);
    wire fwd_b_ex /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */ = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                    (ex_mem_rd == id_ex_rs2) && (ex_mem_wb_sel != 2'b01);
    wire fwd_b_wb /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */ = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2);
    wire [31:0] rs1_val = fwd_a_ex ? ex_mem_forward_val :
                          fwd_a_wb ? wb_data : id_ex_rdata1;
    wire [31:0] rs2_val = fwd_b_ex ? ex_mem_forward_val :
                          fwd_b_wb ? wb_data : id_ex_rdata2;

    wire [31:0] alu_a = id_ex_alu_a_sel ? id_ex_pc  : rs1_val;
    wire [31:0] alu_b = id_ex_alu_b_sel ? id_ex_imm : rs2_val;
    wire [31:0] alu_raw;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(id_ex_alu_op), .result(alu_raw));

    // 多拍除法：DIV/DIVU/REM/REMU 由迭代除法器接管（单拍组合除法会拖垮 Fmax）
    wire id_ex_is_div = (id_ex_alu_op >= 5'd14);
    wire div_start    = id_ex_is_div && !div_busy;
    // （div_result / div_busy / div_done 声明已提前到文件顶部）
    divider u_divider (
        .clk(clk), .resetn(resetn),
        .start(div_start),
        .a(alu_a), .b(alu_b),
        .is_signed(~id_ex_alu_op[0]),
        .is_rem(id_ex_alu_op[4]),
        .result(div_result),
        .busy(div_busy),
        .done(div_done)
    );
    // ------------------------------------------------------------------
    // EX 结果三选一：CSR 读 > 多拍除法 > ALU
    //   * CSR 读值【骑在这里】才能白拿前递与写回通路 —— 对下游而言它就是
    //     "EX 算出来的结果"，不需要任何额外旁路。
    //   * [!] 绝不能用 `alu_op >= 14` 去编码 CSR 读 —— 那会撞上下面的
    //     `id_ex_is_div`，误触发除法停顿 → div_stall 永不释放 → 死锁。
    //     所以 CSR 用**独立的** id_ex_is_csr 标志，alu_op 保持 0。
    // ------------------------------------------------------------------
    wire [31:0] alu_result = id_ex_is_csr ? csr_rdata :
                             id_ex_is_div ? div_result : alu_raw;
    // 访存地址 = base + offset，恒为 ADD（load/store 的 alu_op 固定为 0，
    // 见 control.v 的 OP_LOAD / OP_STORE —— 它们不写 alu_op，保持 default 的 0）。
    // 单独用一个加法器产生地址，把 32×32 乘法器从
    // "未对齐判据 → 异常 → pc_r 写使能" 这条【假路径】上切下来：
    // mul 指令从不访存，乘法结果根本不该出现在 pc_r 的时序弧里。
    // [!] 只用于未对齐判据与 mtval，不改变任何流水线语义（见 §关键路径）。
    wire [31:0] addr_result = alu_a + alu_b;
    assign      div_stall  = id_ex_is_div && !div_done;

    wire equal         = (rs1_val == rs2_val);
    wire less_signed   = ($signed(rs1_val) < $signed(rs2_val));
    wire less_unsigned = (rs1_val < rs2_val);
    reg branch_taken /* synthesis PAP_MARK_DEBUG="1" syn_keep=1 */;
    always @(*) begin
        case (id_ex_funct3)
            3'b000: branch_taken = equal;          // BEQ
            3'b001: branch_taken = ~equal;         // BNE
            3'b100: branch_taken = less_signed;    // BLT
            3'b101: branch_taken = ~less_signed;   // BGE
            3'b110: branch_taken = less_unsigned;  // BLTU
            3'b111: branch_taken = ~less_unsigned; // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    wire [31:0] branch_target = id_ex_pc + id_ex_imm;
    wire [31:0] jalr_target   = (rs1_val + id_ex_imm) & 32'hFFFF_FFFE;
    // MRET 本质就是"目标为 mepc 的无条件跳转"，所以【折进 ex_flush 通路】，
    // 不为它在 fetch_addr 上再加一条腿 —— 那条路径在 pc_r 的临界路径上，
    // 直接关系到 Fmax 与 CoreMark/LUTs 两项评分。
    assign      mret_commit   = id_ex_mret && !trap;
    assign      ex_target     = id_ex_mret   ? csr_mepc :
                                id_ex_jump_reg ? jalr_target : branch_target;

    // ---- EX 级：验证 ID 级的预测（预测器本身在 ID 级，EX 只做裁决） ----
    // 实际是否跳转。注意这与"是否冲刷"是两回事：预测正确时这里为 1 但不冲刷。
    wire ex_resolve_taken = (id_ex_branch && branch_taken) ||
                            id_ex_jump || id_ex_jump_reg || mret_commit;
    // 预测 not-taken 但实际 taken  → 原有冲刷路径（含 jalr，它从不被预测）
    assign ex_flush   = ex_resolve_taken && !id_ex_pred_taken;
    // 预测 taken 但实际 not-taken  → 误判恢复：回到 fall-through
    assign ex_mispred = !ex_resolve_taken && id_ex_pred_taken;
    assign ex_mispred_target = id_ex_pc + 32'd4;

    // ---- BHT 训练（EX 级，用解析结果，与是否冲刷无关）----
    // 每条条件分支真正解析出方向后都要更新（预测对错都学）。未命中时【每个分支都分配】、
    // 按方向初始化计数器（taken→weakly taken，not-taken→weakly not-taken），这样后向
    // not-taken 分支也能学到（若只在 taken 时分配，这类分支永远分配不上）。预测表是纯
    // 建议性的：读写同拍无转发、读到旧值是允许的（最多一次误预测，被冲刷兜住）。
    wire [7:0] bht_idx_w = id_ex_pc[9:2];
    wire       bht_hit_w = bht_valid[bht_idx_w] && (bht_tag[bht_idx_w] == id_ex_pc[31:8]);
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            bht_valid <= 256'd0;
        end else if (id_ex_branch) begin
            if (bht_hit_w) begin
                if (branch_taken)
                    bht_ctr[bht_idx_w] <= (bht_ctr[bht_idx_w] == 2'b11) ? 2'b11
                                                                        : bht_ctr[bht_idx_w] + 2'd1;
                else
                    bht_ctr[bht_idx_w] <= (bht_ctr[bht_idx_w] == 2'b00) ? 2'b00
                                                                        : bht_ctr[bht_idx_w] - 2'd1;
            end else begin
                bht_valid[bht_idx_w] <= 1'b1;
                bht_tag[bht_idx_w]   <= id_ex_pc[31:8];
                bht_ctr[bht_idx_w]   <= branch_taken ? 2'b10 : 2'b01;
            end
        end
    end

    // ================= EX 级：异常与中断 =================
    // 统一在【EX 级】产生（PC、前递后的值、访存地址此刻全部齐备）。
    //
    // 为什么必须落在 EX：EX 里的指令是【最老的未提交指令】。trap 时
    // mepc = id_ex_pc，该指令被杀死并在 mret 后重放 —— 它此刻还没写任何状态
    //（store 到 MEM 才写、CSR 写从 EX 提交、rd 写从 WB）。
    // 若采在 MEM/WB，那条指令已经写出去了而 mepc 又指向它 → 提交一次再执行一次
    //（复制执行）；或 mepc 指向下一条 → 漏执行一条。

    // ---- 未对齐访存的判据 ----
    // LB/LBU 任意地址合法；LH/LHU 要求 addr[0]==0；LW 要求 addr[1:0]==0。
    // funct3[1:0]：00=字节 01=半字 10=字（load 与 store 同一套编码）
    wire [1:0] mem_addr_low = addr_result[1:0];
    wire mem_unaligned = (id_ex_funct3[1:0] == 2'b01) ? mem_addr_low[0] :
                         (id_ex_funct3[1:0] == 2'b10) ? |mem_addr_low : 1'b0;
    wire load_misaligned  = id_ex_mem_read  && mem_unaligned;
    wire store_misaligned = id_ex_mem_write && mem_unaligned;

    // ---- CSR 写数据与写使能 ----
    // 立即数形式的源在 instr[19:15]（零扩展），它已随指令带到 id_ex_rs1。
    wire [31:0] csr_src = id_ex_csr_imm ? {27'd0, id_ex_rs1} : rs1_val;
    wire [31:0] csr_new = (id_ex_csr_cmd == 2'b01) ? csr_src :                // CSRRW
                          (id_ex_csr_cmd == 2'b10) ? (csr_rdata |  csr_src) : // CSRRS
                                                     (csr_rdata & ~csr_src);  // CSRRC
    // CSRRS/CSRRC 的源为 x0 时【不写】（规范要求：不产生副作用）；CSRRW 无条件写
    wire csr_wr_en_raw = id_ex_is_csr &&
                         ((id_ex_csr_cmd == 2'b01) || (id_ex_rs1 != 5'd0));
    assign csr_wdata = csr_new;
    // 被 trap 杀掉的指令不得写 CSR
    assign csr_wr_en = csr_wr_en_raw && !trap;

    // ---- 同步异常 ----
    // 判据之间天然互斥（非法指令的 mem_read/mem_write 必为 0，ecall/ebreak 同理），
    // 所以下面的优先级只为把编码写清楚，不承担正确性。
    // [!] 必须用 csr_wr_en_raw（"这条指令真的在写吗"），不能用 csr_wr_illegal 单独判断。
    //    csr_wr_illegal 只看地址是不是只读区，而【只读 CSR 是可以读的】——
    //    `csrr a0, mhartid` 是 RS 且 rs1=x0，根本不写，却被判成非法指令，
    //    导致 riscv-tests 的 init 段每轮都 trap → 重启 → 50 个测试全 TIMEOUT。
    //    也不能用 csr_wr_en（它含 !trap），否则 trap ← ex_exception ← csr_wr_en ← trap 成环。
    wire exc_illegal = id_ex_illegal || (csr_wr_en_raw && csr_wr_illegal);
    assign ex_exception = exc_illegal || id_ex_sys_ecall || id_ex_sys_ebreak ||
                          load_misaligned || store_misaligned;
    wire [31:0] exc_cause = exc_illegal      ? 32'd2  :   // Illegal instruction
                            id_ex_sys_ecall  ? 32'd11 :   // Environment call from M
                            id_ex_sys_ebreak ? 32'd3  :   // Breakpoint
                            load_misaligned  ? 32'd4  :   // Load addr misaligned
                            store_misaligned ? 32'd6  :   // Store addr misaligned
                                               32'd0;
    // mtval：未对齐给出错地址；非法指令给 0 —— 规范允许 0 或指令本身，
    // 本设计取 0 以免把整条指令再多带一级流水线寄存器。其余为 0。
    wire [31:0] exc_tval = (load_misaligned || store_misaligned) ? addr_result : 32'd0;

    // ---- 中断 ----
    // mip 的两个位直接由外部电平驱动（只读），与 mie / mstatus.MIE 相与
    wire int_timer   = csr_mie_mtie & irq_timer;
    wire int_ext     = csr_mie_meie & irq_ext;
    wire int_pending = int_timer | int_ext;
    // 门控：
    //   id_ex_valid —— [重点] EX 里必须真的有指令。缺了它会在"上一条指令刚重定向、
    //                  ID/EX 已清空"的那一拍误受理中断，而 mepc 取的是气泡的
    //                  id_ex_pc(=0) → mret 跳到地址 0。2026-09-23 实测踩到。
    //   !div_stall  —— 护住多拍除法器，避免残留状态/陈旧结果
    //   !id_ex_mret —— 抑制"打断 mret"的嵌套角落
    // 同步异常无需门控：肇事指令下一拍已被清成气泡，ex_exception 自然为 0；
    // 而气泡的 id_ex_illegal/ecall/ebreak/mem_read 全为 0，也判不出异常。
    assign int_take = csr_mstatus_mie && int_pending && id_ex_valid &&
                      !div_stall && !id_ex_mret;

    assign trap_cause  = ex_exception ? exc_cause :
                         int_timer    ? 32'h8000_0007 :   // Machine timer
                                        32'h8000_000B;    // Machine external
    assign trap_tval   = ex_exception ? exc_tval : 32'd0;
    assign trap        = ex_exception || int_take;
    assign trap_target = csr_mtvec_base;

    // ---- CSR 文件 ----
    // 注意本模块的端口只有 trap/wr_en 进到它的时序块，rd_data 是纯组合的
    //（只依赖寄存器与 irq_*），所以 trap ← alu_result ← csr_rdata 这条链
    // 【不构成组合环】。
    csr_file u_csr (
        .clk(clk), .resetn(resetn),
        .rd_addr    (id_ex_csr_addr),
        .rd_data    (csr_rdata),
        .wr_en      (csr_wr_en),
        .wr_addr    (id_ex_csr_addr),
        .wr_data    (csr_wdata),
        .wr_illegal (csr_wr_illegal),
        .trap       (trap),
        .trap_pc    (id_ex_pc),
        .trap_cause (trap_cause),
        .trap_tval  (trap_tval),
        .mret       (mret_commit),
        .irq_timer  (irq_timer),
        .irq_ext    (irq_ext),
        .mtvec_base (csr_mtvec_base),
        .mepc_out   (csr_mepc),
        .mstatus_mie(csr_mstatus_mie),
        .mie_mtie   (csr_mie_mtie),
        .mie_meie   (csr_mie_meie)
    );

    // ================= EX/MEM =================
    // （级间寄存器声明已提前到文件顶部，避免 forward reference）

    // ================= MEM =================
    // RAM 本体已移出到 rtl/bus/mem_bus.v。这里只保留"把 store 数据按
    // 字节/半字复制到整字"的格式化 —— 它是 RISC-V 编码（funct3）的函数，
    // 属于指令语义，总线不该懂 SB/SH/SW，所以留在核内。
    // 副作用：外设可直接取 mem_wdata[7:0]，sb/sh/sw 三种宽度都能用。
    always @(*) begin
        case (ex_mem_funct3)
            3'b000: mem_wdata = {4{ex_mem_wdata[7:0]}};    // SB
            3'b001: mem_wdata = {2{ex_mem_wdata[15:0]}};   // SH
            default: mem_wdata = ex_mem_wdata;             // SW
        endcase
    end

    always @(*) begin
        case (ex_mem_funct3)
            3'b000: mem_byte_en = 4'b0001 << ex_mem_alu_result[1:0]; // SB
            3'b001: mem_byte_en = 4'b0011 << ex_mem_alu_result[1:0]; // SH
            3'b010: mem_byte_en = 4'b1111;                           // SW
            default: mem_byte_en = 4'b0000;
        endcase
    end

    // ================= MEM/WB =================
    // （级间寄存器声明已提前到文件顶部，避免 forward reference）

    // ================= WB =================
    // mem_rdata 由 mem_bus 在 MEM→WB 沿给出（RAM / 兼容区 / 外设区一律 1 拍
    // 延迟，无特例），load 指令进入 WB 阶段时正好有效。
    wire [31:0] load_src = mem_rdata;
    wire [7:0]  load_byte = (mem_wb_addr_low == 2'd0) ? load_src[7:0]   :
                            (mem_wb_addr_low == 2'd1) ? load_src[15:8]  :
                            (mem_wb_addr_low == 2'd2) ? load_src[23:16] :
                                                        load_src[31:24];
    wire [15:0] load_half = mem_wb_addr_low[1] ? load_src[31:16] : load_src[15:0];

    wire [31:0] load_data =
        (mem_wb_funct3 == 3'b000) ? {{24{load_byte[7]}}, load_byte} : // LB
        (mem_wb_funct3 == 3'b001) ? {{16{load_half[15]}}, load_half} : // LH
        (mem_wb_funct3 == 3'b100) ? {24'd0, load_byte} :              // LBU
        (mem_wb_funct3 == 3'b101) ? {16'd0, load_half} :              // LHU
        load_src;                                                     // LW

    assign wb_data = (mem_wb_wb_sel == 2'b01) ? load_data :
                     (mem_wb_wb_sel == 2'b10) ? (mem_wb_pc + 32'd4) :
                     (mem_wb_wb_sel == 2'b11) ? mem_wb_imm :
                     mem_wb_alu_result;

    // ================= PC =================
    // 同步读 BRAM 使取指有 2 拍延迟，【无跳转的稳态】不变量：
    //     imem_rd   = mem[pc_r-4]   （在途，下一拍进 IF/ID）
    //     if_id_pc  = pc_r-8        （正在 ID 译码）
    //     id_ex_pc  = pc_r-12       （正在 EX 执行）
    // 跳转那一拍 fetch_addr 被旁路，此后 pc_r 与"已发出的地址"相差 4。
    //
    // stall / div_stall 时：pc_r 与 if_addr_d 都【保持不动】，同时上面
    // fetch_addr 的 mux 把取指地址【退回 if_addr_d[14:2]】—— 也就是重读上一拍
    // 已经读过一遍的同一个 word，让它落在 imem_rd 上、在 stall 结束那一拍被
    // if_id 采走，从而拿到 (pc, 指令) 同址的一对。
    //
    // 注意：是取指地址后退，【不是 pc_r 后退】。若把 pc_r 真的往后推 4 字节，
    // 连续两拍 stall 会让同一条指令被取两次（非幂等指令被重复执行），历史上
    // 就踩过这个坑（见 doc/test_report_riscv-tests.md）。
    //
    // ------------------------------------------------------------------
    // 三路重定向一律置 pc_r = 目标 + 4，【不是目标本身】。
    // ------------------------------------------------------------------
    // 因为 fetch_addr 已经在【本拍】把目标地址发出去了，而 pc_r 是"下一拍要发的
    // 地址"，必须跳过它。若这里写目标本身，下一拍会重发同一个地址，两次读回的
    // 同一 word 会在相邻两拍先后被采进 IF/ID —— 目标指令执行两遍，且此后
    // (pc, instruction) 整体错位。这就是本文件另一处注释警告的
    // "指令被复制执行"那类 bug 的新形态（历史上 stall 时把 pc_r 后退也是同一个病）。
    //
    // 三路优先级与 fetch_addr 保持一致，不能各写各的：pc_r 与 fetch_addr 必须
    // 描述同一条地址流，否则两者会分叉。
    always @(posedge clk or negedge resetn) begin
        if (!resetn)
            pc_r <= 32'd0;
        else if (trap)
            pc_r <= trap_target + 32'd4;
        else if (ex_flush)
            pc_r <= ex_target + 32'd4;
        else if (ex_mispred)
            pc_r <= ex_mispred_target + 32'd4;
        else if (id_redirect)
            pc_r <= id_target + 32'd4;
        else if (!stall && !div_stall)
            pc_r <= pc_r + 32'd4;
    end

    // ================= IF/ID 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013;
            if_id_valid <= 1'b0;
        end else if (ex_flush || ex_mispred || id_redirect || trap) begin
            // 三条都只清【一拍】：重定向那一拍 fetch_addr 已经把新地址发出去了，
            // 目标指令的数据下一拍就回来，多清一拍反而会把它杀掉。
            // （原 ex_flush_d 的第二拍冲刷已随地址旁路一并移除。）
            //
            //   ex_flush   杀掉跳转前那次读（旧路）
            //   ex_mispred 杀掉预测路径上取回的错误指令
            //   id_redirect 杀掉 fall-through 取指
            //
            // id_redirect 这一拍【不会误清分支自己】：ID/EX 是在同一个时钟沿从
            // IF/ID 的组合译码结果采样的，清 IF/ID 与分支进 ID/EX 互不影响。
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013;
            if_id_valid <= 1'b0;          // 冲刷插入的是气泡，不是真指令
        end else if (!stall && !div_stall) begin
            if_id_valid <= (imem_rd != 32'd0);
            if_id_pc    <= if_addr_d;
            if_id_instr <= imem_rd;
        end
    end

    // ================= ID/EX 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn || ex_flush || ex_mispred || stall || trap) begin
            id_ex_reg_write <= 1'b0;
            id_ex_alu_a_sel <= 1'b0;
            id_ex_alu_b_sel <= 1'b0;
            id_ex_mem_read  <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_branch    <= 1'b0;
            id_ex_jump      <= 1'b0;
            id_ex_jump_reg  <= 1'b0;
            id_ex_pred_taken <= 1'b0;
            id_ex_alu_op    <= 5'd0;
            id_ex_wb_sel    <= 2'b00;
            id_ex_pc        <= 32'd0;
            id_ex_rdata1    <= 32'd0;
            id_ex_rdata2    <= 32'd0;
            id_ex_imm       <= 32'd0;
            id_ex_rd        <= 5'd0;
            id_ex_rs1       <= 5'd0;
            id_ex_rs2       <= 5'd0;
            id_ex_funct3    <= 3'd0;
            id_ex_sys_ebreak <= 1'b0;
            // [!] 下面这几个新增标志【一个都不能漏】：冲刷后残留旧标志
            //    会让气泡被当成非法指令或 CSR 指令 → 假异常。且是静默的。
            id_ex_is_csr    <= 1'b0;
            id_ex_csr_addr  <= 12'd0;
            id_ex_csr_cmd   <= 2'b00;
            id_ex_csr_imm   <= 1'b0;
            id_ex_illegal   <= 1'b0;
            id_ex_sys_ecall <= 1'b0;
            id_ex_mret      <= 1'b0;
            id_ex_valid     <= 1'b0;
        end else if (!div_stall) begin
            id_ex_reg_write <= reg_write;
            id_ex_alu_a_sel <= alu_a_sel;
            id_ex_alu_b_sel <= alu_b_sel;
            id_ex_mem_read  <= mem_read;
            id_ex_mem_write <= mem_write;
            id_ex_branch    <= branch;
            id_ex_jump      <= jump;
            id_ex_jump_reg  <= jump_reg;
            // 必须寄存【实际生效的重定向】id_redirect，而不是预测意图
            // id_pred_taken —— 两者在有 stall / ex_flush / div_stall 时会分叉
            // （那三种情况 id_redirect 被抑制，但 id_pred_taken 仍为 1）。
            // 若寄存错了，会出现"记着预测过、但 pc_r 根本没重定向"的状态，
            // EX 级据此判定预测正确而不冲刷，流水线就沿错误路径一路跑下去。
            id_ex_pred_taken <= id_redirect;
            id_ex_alu_op    <= alu_op;
            id_ex_wb_sel    <= wb_sel;
            id_ex_pc        <= if_id_pc;
            id_ex_rdata1    <= rdata1;
            id_ex_rdata2    <= rdata2;
            id_ex_imm       <= imm;
            id_ex_rd        <= rd;
            id_ex_rs1       <= rs1;
            id_ex_rs2       <= rs2;
            id_ex_funct3    <= if_id_instr[14:12];
            id_ex_sys_ebreak <= sys_ebreak;
            id_ex_is_csr    <= is_csr;
            id_ex_csr_addr  <= csr_addr;
            id_ex_csr_cmd   <= csr_cmd;
            id_ex_csr_imm   <= csr_imm;
            id_ex_illegal   <= id_illegal;
            id_ex_sys_ecall <= sys_ecall;
            id_ex_mret      <= sys_mret;
            // 跟随 IF/ID 的实际内容：冲刷/填充期的气泡不能算有效，
            // 否则中断会拿气泡的 id_ex_pc(=0) 去写 mepc
            id_ex_valid     <= if_id_valid;
        end
    end

    // ================= EX/MEM 寄存器 =================
    // [重点] trap 必须清 EX/MEM，只清 ID/EX 是不够的（2026-09-23 实测踩到）：
    //   `EX/MEM <= ID/EX` 是在【同一个时钟沿】发生的。trap 那拍肇事指令正躺在
    //   ID/EX 里，清 ID/EX 只能保证【下一拍】的 EX/MEM 是气泡，而【这一拍】
    //   EX/MEM 照样把它收下 —— 于是下拍访存口就真的把它写出去了。
    //   实测现象：未对齐 sw 既正确陷入了 mcause=6 异常，内存却也被改了。
    //
    //   清它不会丢数据：此时 EX/MEM 里那条【更老】的指令已经在这个沿推进到
    //   MEM/WB 了（MEM/WB 与 EX/MEM 是同一个沿更新的），写回不受影响。
    always @(posedge clk or negedge resetn) begin
        if (!resetn || div_stall || trap) begin
            ex_mem_reg_write  <= 1'b0;
            ex_mem_mem_read   <= 1'b0;
            ex_mem_mem_write  <= 1'b0;
            ex_mem_wb_sel     <= 2'b00;
            ex_mem_alu_result <= 32'd0;
            ex_mem_wdata      <= 32'd0;
            ex_mem_pc         <= 32'd0;
            ex_mem_imm        <= 32'd0;
            ex_mem_rd         <= 5'd0;
            ex_mem_funct3     <= 3'd0;
            ex_mem_sys_ebreak <= 1'b0;
        end else begin
            ex_mem_reg_write  <= id_ex_reg_write;
            ex_mem_mem_read   <= id_ex_mem_read;
            ex_mem_mem_write  <= id_ex_mem_write;
            ex_mem_wb_sel     <= id_ex_wb_sel;
            ex_mem_alu_result <= alu_result;
            ex_mem_wdata      <= rs2_val;
            ex_mem_pc         <= id_ex_pc;
            ex_mem_imm        <= id_ex_imm;
            ex_mem_rd         <= id_ex_rd;
            ex_mem_funct3     <= id_ex_funct3;
            ex_mem_sys_ebreak <= id_ex_sys_ebreak;
        end
    end

    // ================= MEM/WB 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mem_wb_reg_write  <= 1'b0;
            mem_wb_wb_sel     <= 2'b00;
            mem_wb_alu_result <= 32'd0;
            mem_wb_pc         <= 32'd0;
            mem_wb_imm        <= 32'd0;
            mem_wb_rd         <= 5'd0;
            mem_wb_funct3     <= 3'd0;
            mem_wb_addr_low   <= 2'd0;
        end else begin
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_wb_sel     <= ex_mem_wb_sel;
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_pc         <= ex_mem_pc;
            mem_wb_imm        <= ex_mem_imm;
            mem_wb_rd         <= ex_mem_rd;
            mem_wb_funct3     <= ex_mem_funct3;
            mem_wb_addr_low   <= ex_mem_alu_result[1:0];
        end
    end

endmodule
