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
    input  wire [31:0] mem_rdata
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
    wire        stall;
    wire [31:0] div_result;
    wire        div_busy, div_done;
    wire        div_stall;
    wire        ex_flush;
    // ID/EX
    reg        id_ex_reg_write, id_ex_alu_a_sel, id_ex_alu_b_sel, id_ex_mem_read, id_ex_mem_write;
    reg        id_ex_branch, id_ex_jump, id_ex_jump_reg;
    reg [4:0]  id_ex_alu_op;
    reg [1:0]  id_ex_wb_sel;
    reg [31:0] id_ex_pc, id_ex_rdata1, id_ex_rdata2, id_ex_imm;
    reg [4:0]  id_ex_rd, id_ex_rs1, id_ex_rs2;
    reg [2:0]  id_ex_funct3;
    // EX/MEM
    reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    reg [1:0]  ex_mem_wb_sel;
    reg [31:0] ex_mem_alu_result, ex_mem_wdata, ex_mem_pc, ex_mem_imm;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
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

    // 指令存储器已移出到 mem_bus（与数据共用一块双端口 BRAM 的 A 口）。
    // 注意：这里送出的 imem_addr 必须是下面 mux 【之后】的值，不是 pc_r ——
    // stall 时要靠它退回 if_addr_d 重读同一 word，详见 PC 段注释。

    // 取指地址对齐：imem_rd 在下一拍 = mem[本拍 pc_r]，用 if_addr_d 记录本拍 pc_r
    reg [31:0] if_addr_d;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) if_addr_d <= 32'd0;
        else if (!stall && !div_stall) if_addr_d <= pc_r;
    end

    // 跳转后双拍 flush（同步读取指多 1 拍，跳转目标指令要多等 1 拍）
    reg ex_flush_d;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) ex_flush_d <= 1'b0;
        else         ex_flush_d <= ex_flush;
    end

    // ================= IF/ID =================
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // ================= ID =================
    wire [4:0] rs1 = if_id_instr[19:15];
    wire [4:0] rs2 = if_id_instr[24:20];
    wire [4:0] rd  = if_id_instr[11:7];

    wire        reg_write, alu_a_sel, alu_b_sel, mem_read, mem_write, branch, jump, jump_reg;
    wire [4:0]  alu_op;
    wire [1:0]  wb_sel;
    control u_ctrl (
        .instr     (if_id_instr),
        .reg_write (reg_write),
        .alu_a_sel (alu_a_sel),
        .alu_b_sel (alu_b_sel),
        .alu_op    (alu_op),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .branch    (branch),
        .jump      (jump),
        .jump_reg  (jump_reg),
        .wb_sel    (wb_sel)
    );

    wire [31:0] rdata1, rdata2;
    regfile u_regfile (
        .clk(clk), .resetn(resetn), .we(mem_wb_reg_write),
        .rs1(rs1), .rs2(rs2), .rd(mem_wb_rd),
        .wd(wb_data), .rdata1(rdata1), .rdata2(rdata2)
    );

    wire [31:0] imm;
    imm_gen u_imm (.instr(if_id_instr), .imm(imm));

    // ================= hazard (load-use stall only；其余 RAW 由 forwarding 解决) =================
    assign stall = (id_ex_mem_read && (id_ex_rd != 5'd0) &&
                    ((id_ex_rd == rs1) || (id_ex_rd == rs2)));

    // stall 时 imem 读地址退一格到在途指令 if_addr_d，让同步读重新锁存正确数据
    assign imem_addr = (stall || div_stall) ? if_addr_d[14:2] : pc_r[14:2];

    // ================= ID/EX =================
    // （级间寄存器声明已提前到文件顶部，避免 forward reference）

    // ================= EX =================
    // ---- EX 阶段 forwarding（优先级：EX/MEM > MEM/WB > 寄存器读） ----
    // EX/MEM 写回候选值；load(wb_sel=01) 的数据要 WB 才有效，不从此处前递
    wire [31:0] ex_mem_forward_val =
        (ex_mem_wb_sel == 2'b10) ? (ex_mem_pc + 32'd4) :
        (ex_mem_wb_sel == 2'b11) ? ex_mem_imm :
        ex_mem_alu_result;
    wire fwd_a_ex = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                    (ex_mem_rd == id_ex_rs1) && (ex_mem_wb_sel != 2'b01);
    wire fwd_a_wb = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1);
    wire fwd_b_ex = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                    (ex_mem_rd == id_ex_rs2) && (ex_mem_wb_sel != 2'b01);
    wire fwd_b_wb = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2);
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
    wire [31:0] alu_result = id_ex_is_div ? div_result : alu_raw;
    assign      div_stall  = id_ex_is_div && !div_done;

    wire equal         = (rs1_val == rs2_val);
    wire less_signed   = ($signed(rs1_val) < $signed(rs2_val));
    wire less_unsigned = (rs1_val < rs2_val);
    reg branch_taken;
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
    assign      ex_flush      = (id_ex_branch && branch_taken) || id_ex_jump || id_ex_jump_reg;
    wire [31:0] ex_target     = id_ex_jump_reg ? jalr_target : branch_target;

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
    // 同步读 BRAM 使取指有 2 拍延迟，稳态不变量：
    //     imem_rd   = mem[pc_r-4]   （在途，下一拍进 IF/ID）
    //     if_id_pc  = pc_r-8        （正在 ID 译码）
    //     id_ex_pc  = pc_r-12       （正在 EX 执行）
    //
    // stall / div_stall 时：pc_r 与 if_addr_d 都【保持不动】，同时上面
    // imem_addr 的 mux 把取指地址【退回 if_addr_d[14:2]】—— 也就是重读上一拍
    // 已经读过一遍的同一个 word，让它落在 imem_rd 上、在 stall 结束那一拍被
    // if_id 采走，从而拿到 (pc, 指令) 同址的一对。
    //
    // 注意：是 imem_addr 后退，【不是 pc_r 后退】。若把 pc_r 真的往后推 4 字节，
    // 连续两拍 stall 会让同一条指令被取两次（非幂等指令被重复执行），历史上
    // 就踩过这个坑（见 doc/test_report_riscv-tests.md）。
    always @(posedge clk or negedge resetn) begin
        if (!resetn)
            pc_r <= 32'd0;
        else if (ex_flush)
            pc_r <= ex_target;
        else if (!stall && !div_stall)
            pc_r <= pc_r + 32'd4;
    end

    // ================= IF/ID 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013;
        end else if (ex_flush || ex_flush_d) begin
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013;
        end else if (!stall && !div_stall) begin
            if_id_pc    <= if_addr_d;
            if_id_instr <= imem_rd;
        end
    end

    // ================= ID/EX 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn || ex_flush || stall) begin
            id_ex_reg_write <= 1'b0;
            id_ex_alu_a_sel <= 1'b0;
            id_ex_alu_b_sel <= 1'b0;
            id_ex_mem_read  <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_branch    <= 1'b0;
            id_ex_jump      <= 1'b0;
            id_ex_jump_reg  <= 1'b0;
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
        end else if (!div_stall) begin
            id_ex_reg_write <= reg_write;
            id_ex_alu_a_sel <= alu_a_sel;
            id_ex_alu_b_sel <= alu_b_sel;
            id_ex_mem_read  <= mem_read;
            id_ex_mem_write <= mem_write;
            id_ex_branch    <= branch;
            id_ex_jump      <= jump;
            id_ex_jump_reg  <= jump_reg;
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
        end
    end

    // ================= EX/MEM 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn || div_stall) begin
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
