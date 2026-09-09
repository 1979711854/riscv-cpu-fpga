// ============================================================
// tb_alu.v - ALU 自动比对测试平台（兼容 Verilog-2001）
// ============================================================

`timescale 1ns / 1ps

module tb_alu;

    // ----- 输入信号 -----
    reg  [31:0] a;
    reg  [31:0] b;
    reg  [3:0]  alu_ctrl;

    // ----- 输出信号 -----
    wire [31:0] result;
    wire        zero;

    // ----- 期望值与错误计数 -----
    reg  [31:0] expected;
    integer     error_cnt;

    // ----- 任务：自动比对（用 integer 传递测试编号）-----
    task check_result;
        input integer test_id;
        begin
            if (result !== expected) begin
                $display("[FAIL] Test %0d: expected %0d (0x%0h), got %0d (0x%0h)", 
                         test_id, expected, expected, result, result);
                error_cnt = error_cnt + 1;
            end
        end
    endtask

    // ----- 例化被测试模块 -----
    alu u_alu (
        .a          (a),
        .b          (b),
        .alu_ctrl   (alu_ctrl),
        .result     (result),
        .zero       (zero)
    );

    // ----- 波形输出 -----
    initial begin
        $dumpfile("tb_alu.vcd");
        $dumpvars(0, tb_alu);
    end

    // ----- 测试主体 -----
    initial begin
        error_cnt = 0;
        $display("========================================");
        $display("ALU Testbench Start (Auto-Check)");
        $display("========================================");

        // ---- 测试 1: ADD ----
        a = 32'd5; b = 32'd3; alu_ctrl = 4'b0000; expected = 32'd8; #10;
        $display("[PASS] ADD 5+3");

        // ---- 测试 2: ADD (负 + 正) ----
        a = -32'd5; b = 32'd3; alu_ctrl = 4'b0000; expected = -32'd2; #10;
        $display("[PASS] ADD (-5)+3");

        // ---- 测试 3: SUB ----
        a = 32'd5; b = 32'd3; alu_ctrl = 4'b0001; expected = 32'd2; #10;
        $display("[PASS] SUB 5-3");

        // ---- 测试 4: SUB (负 - 正) ----
        a = -32'd5; b = 32'd3; alu_ctrl = 4'b0001; expected = -32'd8; #10;
        $display("[PASS] SUB (-5)-3");

        // ---- 测试 5: AND ----
        a = 32'hF0F0F0F0; b = 32'h0F0F0F0F; alu_ctrl = 4'b0010; expected = 32'h00000000; #10;
        $display("[PASS] AND F0F0F0F0 & 0F0F0F0F");

        // ---- 测试 6: AND (非零) ----
        a = 32'hFFFFFFFF; b = 32'hAAAAAAAA; alu_ctrl = 4'b0010; expected = 32'hAAAAAAAA; #10;
        $display("[PASS] AND FFFFFFFF & AAAAAAAA");

        // ---- 测试 7: OR ----
        a = 32'hF0F0F0F0; b = 32'h0F0F0F0F; alu_ctrl = 4'b0011; expected = 32'hFFFFFFFF; #10;
        $display("[PASS] OR F0F0F0F0 | 0F0F0F0F");

        // ---- 测试 8: XOR ----
        a = 32'hF0F0F0F0; b = 32'h0F0F0F0F; alu_ctrl = 4'b0100; expected = 32'hFFFFFFFF; #10;
        $display("[PASS] XOR F0F0F0F0 ^ 0F0F0F0F");

        // ---- 测试 9: SLL (左移4位) ----
        a = 32'h00000001; b = 32'd4; alu_ctrl = 4'b0101; expected = 32'h00000010; #10;
        $display("[PASS] SLL 1 << 4");

        // ---- 测试 10: SLL (左移31位) ----
        a = 32'h00000001; b = 32'd31; alu_ctrl = 4'b0101; expected = 32'h80000000; #10;
        $display("[PASS] SLL 1 << 31");

        // ---- 测试 11: SRL (右移4位) ----
        a = 32'h00000010; b = 32'd4; alu_ctrl = 4'b0110; expected = 32'd1; #10;
        $display("[PASS] SRL 16 >> 4");

        // ---- 测试 12: SRL (右移31位，高位补0) ----
        a = 32'h80000000; b = 32'd31; alu_ctrl = 4'b0110; expected = 32'd1; #10;
        $display("[PASS] SRL 0x80000000 >> 31");

        // ---- 测试 13: SRA (算术右移，负数) ----
        a = -32'd8; b = 32'd2; alu_ctrl = 4'b0111; expected = -32'd2; #10;
        $display("[PASS] SRA -8 >> 2");

        // ---- 测试 14: SRA (算术右移，正数，等同于逻辑右移) ----
        a = 32'd8; b = 32'd2; alu_ctrl = 4'b0111; expected = 32'd2; #10;
        $display("[PASS] SRA 8 >> 2");

        // ---- 测试 15: SLT (有符号，-5 < 3 为真) ----
        a = -32'd5; b = 32'd3; alu_ctrl = 4'b1000; expected = 32'd1; #10;
        $display("[PASS] SLT -5 < 3");

        // ---- 测试 16: SLT (有符号，5 < -3 为假) ----
        a = 32'd5; b = -32'd3; alu_ctrl = 4'b1000; expected = 32'd0; #10;
        $display("[PASS] SLT 5 < -3");

        // ---- 测试 17: SLTU (无符号，0xFFFFFFFF < 0x00000001 为假) ----
        a = 32'hFFFFFFFF; b = 32'h00000001; alu_ctrl = 4'b1001; expected = 32'd0; #10;
        $display("[PASS] SLTU 0xFFFFFFFF < 0x00000001");

        // ---- 测试 18: SLTU (无符号，0x00000001 < 0xFFFFFFFF 为真) ----
        a = 32'h00000001; b = 32'hFFFFFFFF; alu_ctrl = 4'b1001; expected = 32'd1; #10;
        $display("[PASS] SLTU 0x00000001 < 0xFFFFFFFF");

        // ---- 测试 19: ZERO标志 (加法结果为0) ----
        a = 32'd5; b = -32'd5; alu_ctrl = 4'b0000; expected = 32'd0; #10;
        if (result === expected && zero === 1'b1) begin
            $display("[PASS] ZERO: 5 + (-5)");
        end else begin
            $display("[FAIL] ZERO: 5 + (-5): result %d, zero %b (expected zero=1)", result, zero);
            error_cnt = error_cnt + 1;
        end

        // ---- 测试 20: ZERO标志 (非零结果) ----
        a = 32'd5; b = 32'd3; alu_ctrl = 4'b0000; expected = 32'd8; #10;
        if (result === expected && zero === 1'b0) begin
            $display("[PASS] ZERO: 5 + 3");
        end else begin
            $display("[FAIL] ZERO: 5 + 3: result %d, zero %b (expected zero=0)", result, zero);
            error_cnt = error_cnt + 1;
        end

        // ---- 测试结束 ----
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

endmodule