`timescale 1ns/1ps
// ============================================================================
// control.v 定向单测 —— 重点验证 P1 补的 4 条指令
// ----------------------------------------------------------------------------
// FENCE / FENCE.I  -> 全部控制信号为 0（NOP）
// ECALL            -> 全部控制信号为 0（NOP）
// EBREAK           -> 全部控制信号为 0，且 sys_ebreak = 1（停机钩子）
// 非法指令          -> 全部控制信号为 0（NOP）
// 以及一条已知正常的指令，确认译码器没被改坏。
// ============================================================================
module tb_control;
    reg  [31:0] instr;
    wire        reg_write, alu_a_sel, alu_b_sel, mem_read, mem_write;
    wire        branch, jump, jump_reg, sys_ebreak;
    wire [4:0]  alu_op;
    wire [1:0]  wb_sel;

    control u_ctrl (
        .instr      (instr),
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
        .sys_ebreak (sys_ebreak)
    );

    integer errors = 0;

    // 断言：所有控制信号必须全 0（即该指令不产生任何副作用 = NOP）
    task expect_nop;
        input [31:0]        ins;
        input [8*48-1:0]    name;   // 留足空间，太窄会被静默截断
        begin
            instr = ins; #1;
            if (reg_write | alu_a_sel | alu_b_sel | mem_read | mem_write |
                branch | jump | jump_reg | sys_ebreak |
                (alu_op != 5'd0) | (wb_sel != 2'b00)) begin
                $display("FAIL  %0s (0x%08x): 期望全 0，实际 rw=%b aas=%b abs=%b mr=%b mw=%b br=%b j=%b jr=%b eb=%b op=%0d wbs=%b",
                         name, ins, reg_write, alu_a_sel, alu_b_sel, mem_read,
                         mem_write, branch, jump, jump_reg, sys_ebreak, alu_op, wb_sel);
                errors = errors + 1;
            end else begin
                $display("ok    %0s (0x%08x) -> NOP", name, ins);
            end
        end
    endtask

    initial begin
        $display("---- P1: the 4 newly decoded instructions ----");
        expect_nop(32'h0FF0000F, "FENCE  fence iorw,iorw");
        expect_nop(32'h0000000F, "FENCE  fence(all-zero imm)");
        expect_nop(32'h0000100F, "FENCE.I");

        expect_nop(32'h00000073, "ECALL");

        // EBREAK 特殊：其余全 0，但 sys_ebreak 必须为 1
        instr = 32'h00100073; #1;
        if (sys_ebreak === 1'b1 &&
            !(reg_write | alu_a_sel | alu_b_sel | mem_read | mem_write |
              branch | jump | jump_reg | (alu_op != 5'd0) | (wb_sel != 2'b00)))
            $display("ok    EBREAK  (0x00100073) -> sys_ebreak=1，其余为 NOP");
        else begin
            $display("FAIL  EBREAK: 期望 sys_ebreak=1 且其余全 0，实际 eb=%b rw=%b mw=%b op=%0d",
                     sys_ebreak, reg_write, mem_write, alu_op);
            errors = errors + 1;
        end

        $display("---- boundary + regression ----");
        expect_nop(32'h0000007F, "illegal instr (opcode=1111111)");
        // FENCE 的 funct3=001 但 opcode 正确；以及 SYSTEM 里 funct3!=000 的编码
        expect_nop(32'h00002073, "SYSTEM funct3=010 (not ECALL/EBREAK)");

        // 已知正常的指令：add a0, a1, x5  ->  opcode 0110011, rd=01010, funct3=000
        instr = 32'h00B50533; #1;
        if (reg_write === 1'b1 && alu_op === 5'd0 && wb_sel === 2'b00 &&
            !mem_read && !mem_write && !sys_ebreak)
            $display("ok    ADD     (0x00B50533) -> reg_write=1 alu_op=ADD");
        else begin
            $display("FAIL  ADD: 译码异常 rw=%b op=%0d wbs=%b", reg_write, alu_op, wb_sel);
            errors = errors + 1;
        end

        // EBREAK 必须只由 imm=0x001 触发；imm=0x000 是 ECALL，不能误触发停机
        instr = 32'h00000073; #1;
        if (sys_ebreak === 1'b0)
            $display("ok    ECALL (0x00000073) -> sys_ebreak=0（不会误停机）");
        else begin
            $display("FAIL  ECALL 误触发 sys_ebreak=1");
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d 处) ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #10000;
        $display("=== TIMEOUT ===");
        $finish;
    end
endmodule
