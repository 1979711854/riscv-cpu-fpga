//============================================================================
// tb_template.v — 仿真测试台模板（自己复制改名，逐个模块单测用）
// 两种常用模板都在下面，按需启用并删掉另一半。
// 编译运行：
//   iverilog -g2012 -o tb.vvp tb_xxx.v ../rtl/core/xxx.v
//   vvp tb.vvp
//   想看波形就在 testbench 里加：
//     initial begin $dumpfile("xxx.vcd"); $dumpvars(0, 被测模块名); end
//   gtkwave xxx.vcd
//============================================================================

// ---------- 模板A：组合模块（如 alu / imm_gen / alu_ctrl / branch_unit） ----------
module tb_comb;

    // 声明被测模块的输入/输出
    reg  [31:0] a, b;
    reg  [3:0]  ctrl;
    wire [31:0] result;

    // 例化被测模块
    alu u_dut (
        .a(a), .b(b), .alu_ctrl(ctrl), .result(result), .zero(zero)
    );

    // 测例：给一组输入，$display 打印期望 vs 实际，肉眼核对
    initial begin
        $dumpfile("alu.vcd"); $dumpvars(0, u_dut);
        // 例：5 + 3
        a = 32'h5; b = 32'h3; ctrl = 4'b0000; // 编码要与你的 alu 一致
        #10;
        if (result !== 32'h8)
            $display("FAIL: 5+3 => %0d (期望 8)", result);
        else
            $display("OK:   5+3 => 8");
        $finish;
    end

endmodule


// ---------- 模板B：时序模块（如 pc / regfile / imem 写入） ----------
module tb_seq;

    reg clk = 0;
    always #5 clk = ~clk;      // 10ns 周期

    // ... 声明输入输出，例化被测模块，initial 里给激励 ...
    // 记得先复位几拍、再开始正常操作，结尾 $finish。

endmodule
