// ============================================================
// tb_alu_ctrl.v — ALU 控制单元独立测试
// 功能：验证 alu_ctrl 模块在不同 alu_op / funct3 / opcode5 / inst30
//       组合下，输出的 alu_ctrl 是否正确
// ============================================================

`timescale 1ns / 1ps

`include "defs.v"    // 引入 ALU_ADD / ALU_OP_* 等宏（编译时用 -I rtl/core）

module tb_alu_ctrl;

    // ----- 输入信号 -----
    reg  [1:0] alu_op;
    reg  [2:0] funct3;
    reg        opcode5;
    reg        inst30;

    // ----- 输出信号 -----
    wire [3:0] alu_ctrl;

    // ----- 期望值 -----
    reg  [3:0] expected;
    integer    error_cnt;

    // ----- 例化被测试模块 -----
    alu_ctrl u_alu_ctrl (
        .alu_op   (alu_op),
        .funct3   (funct3),
        .opcode5  (opcode5),
        .inst30   (inst30),
        .alu_ctrl (alu_ctrl)
    );

    // ----- 波形输出 -----
    initial begin
        $dumpfile("tb_alu_ctrl.vcd");
        $dumpvars(0, tb_alu_ctrl);
    end

    // ----- 测试主体 -----
    initial begin
        error_cnt = 0;
        $display("========================================");
        $display("ALU Control Testbench Start");
        $display("========================================");

        // =====================================================
        // 第一部分：ALU_OP_ADD（恒加法）
        // 预期：无论 funct3/opcode5/inst30 是什么，都输出 ALU_ADD
        // =====================================================
        $display("--- Testing ALU_OP_ADD ---");

        alu_op = `ALU_OP_ADD; funct3 = 3'b000; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_ADD; #10;
        check_result("ALU_OP_ADD | funct3=000");

        alu_op = `ALU_OP_ADD; funct3 = 3'b111; opcode5 = 1'b1; inst30 = 1'b1; expected = `ALU_ADD; #10;
        check_result("ALU_OP_ADD | funct3=111 (should still be ADD)");

        // =====================================================
        // 第二部分：ALU_OP_BRANCH（恒减法）
        // 预期：无论 funct3/opcode5/inst30 是什么，都输出 ALU_SUB
        // =====================================================
        $display("--- Testing ALU_OP_BRANCH ---");

        alu_op = `ALU_OP_SUB; funct3 = 3'b000; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_SUB; #10;
        check_result("ALU_OP_BRANCH | funct3=000");

        alu_op = `ALU_OP_SUB; funct3 = 3'b111; opcode5 = 1'b1; inst30 = 1'b1; expected = `ALU_SUB; #10;
        check_result("ALU_OP_BRANCH | funct3=111 (should still be SUB)");

        // =====================================================
        // 第三部分：ALU_OP_RTYPE（精细译码）
        // =====================================================
        $display("--- Testing ALU_OP_RTYPE ---");

        // ----- funct3=000: ADD vs SUB -----
        // R型：opcode5=1, inst30=0 → ADD
        alu_op = `ALU_OP_ALU; funct3 = 3'b000; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_ADD; #10;
        check_result("RTYPE | funct3=000 | R-type ADD");

        // R型：opcode5=1, inst30=1 → SUB
        alu_op = `ALU_OP_ALU; funct3 = 3'b000; opcode5 = 1'b1; inst30 = 1'b1; expected = `ALU_SUB; #10;
        check_result("RTYPE | funct3=000 | R-type SUB");

        // I型（addi）：opcode5=0 → ADD（不管 inst30）
        alu_op = `ALU_OP_ALU; funct3 = 3'b000; opcode5 = 1'b0; inst30 = 1'b1; expected = `ALU_ADD; #10;
        check_result("RTYPE | funct3=000 | I-type ADDI (opcode5=0)");

        // ----- funct3=001: SLL / SLLI -----
        alu_op = `ALU_OP_ALU; funct3 = 3'b001; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_SLL; #10;
        check_result("RTYPE | funct3=001 | SLL");

        alu_op = `ALU_OP_ALU; funct3 = 3'b001; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_SLL; #10;
        check_result("RTYPE | funct3=001 | SLLI");

        // ----- funct3=010: SLT / SLTI -----
        alu_op = `ALU_OP_ALU; funct3 = 3'b010; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_SLT; #10;
        check_result("RTYPE | funct3=010 | SLT");

        alu_op = `ALU_OP_ALU; funct3 = 3'b010; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_SLT; #10;
        check_result("RTYPE | funct3=010 | SLTI");

        // ----- funct3=011: SLTU / SLTIU -----
        alu_op = `ALU_OP_ALU; funct3 = 3'b011; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_SLTU; #10;
        check_result("RTYPE | funct3=011 | SLTU");

        alu_op = `ALU_OP_ALU; funct3 = 3'b011; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_SLTU; #10;
        check_result("RTYPE | funct3=011 | SLTIU");

        // ----- funct3=100: XOR / XORI -----
        alu_op = `ALU_OP_ALU; funct3 = 3'b100; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_XOR; #10;
        check_result("RTYPE | funct3=100 | XOR");

        alu_op = `ALU_OP_ALU; funct3 = 3'b100; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_XOR; #10;
        check_result("RTYPE | funct3=100 | XORI");

        // ----- funct3=101: SRL vs SRA -----
        // R型 + SRL：opcode5=1, inst30=0 → SRL
        alu_op = `ALU_OP_ALU; funct3 = 3'b101; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_SRL; #10;
        check_result("RTYPE | funct3=101 | R-type SRL");

        // R型 + SRA：opcode5=1, inst30=1 → SRA
        alu_op = `ALU_OP_ALU; funct3 = 3'b101; opcode5 = 1'b1; inst30 = 1'b1; expected = `ALU_SRA; #10;
        check_result("RTYPE | funct3=101 | R-type SRA");

        // I型 + SRLI：opcode5=0, inst30=0 → SRL
        alu_op = `ALU_OP_ALU; funct3 = 3'b101; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_SRL; #10;
        check_result("RTYPE | funct3=101 | I-type SRLI");

        // I型 + SRAI：opcode5=0, inst30=1 → SRA
        alu_op = `ALU_OP_ALU; funct3 = 3'b101; opcode5 = 1'b0; inst30 = 1'b1; expected = `ALU_SRA; #10;
        check_result("RTYPE | funct3=101 | I-type SRAI");

        // ----- funct3=110: OR / ORI -----
        alu_op = `ALU_OP_ALU; funct3 = 3'b110; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_OR; #10;
        check_result("RTYPE | funct3=110 | OR");

        alu_op = `ALU_OP_ALU; funct3 = 3'b110; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_OR; #10;
        check_result("RTYPE | funct3=110 | ORI");

        // ----- funct3=111: AND / ANDI -----
        alu_op = `ALU_OP_ALU; funct3 = 3'b111; opcode5 = 1'b1; inst30 = 1'b0; expected = `ALU_AND; #10;
        check_result("RTYPE | funct3=111 | AND");

        alu_op = `ALU_OP_ALU; funct3 = 3'b111; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_AND; #10;
        check_result("RTYPE | funct3=111 | ANDI");

        // ----- default 分支测试 -----
        alu_op = 2'b11; funct3 = 3'b000; opcode5 = 1'b0; inst30 = 1'b0; expected = `ALU_ADD; #10;
        check_result("DEFAULT | alu_op=2'b11 (fallback to ADD)");

        // =====================================================
        // 测试结束
        // =====================================================
        $display("========================================");
        if (error_cnt == 0) begin
            $display("ALL TESTS PASSED!");
        end else begin
            $display("%0d TEST(S) FAILED!", error_cnt);
        end
        $display("========================================");
        #10;
        $finish;
    end

    // ----- 自动比对任务 -----
    task check_result;
        input string test_name;
        begin
            if (alu_ctrl !== expected) begin
                $display("[FAIL] %s: expected %b (0x%0h), got %b (0x%0h)",
                         test_name, expected, expected, alu_ctrl, alu_ctrl);
                error_cnt = error_cnt + 1;
            end else begin
                $display("[PASS] %s -> alu_ctrl = %b", test_name, alu_ctrl);
            end
        end
    endtask

endmodule