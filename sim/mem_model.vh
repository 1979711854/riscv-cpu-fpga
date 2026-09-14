// ============================================================================
// 行为级统一存储器模型（仿真专用，由各 testbench `include）
// ----------------------------------------------------------------------------
// 端口与 rtl/mem/unified_mem.v 完全一致。之所以单独一份、而不是直接编
// rtl/mem/：仿真需要从 plusarg 动态指定固件路径（一个 vvp 跑几十个测试），
// 而 rtl/mem/ 那份是给 PDS 综合用的固定路径。
//
// 用 `include 而不是每个 tb 抄一遍，是为了避免三份拷贝各自漂移。
//
// 固件加载：+IMEM=programs/imem.hex  +DMEM=programs/dmem.hex
//   两个文件都用 @word索引 形式，且索引集合【不相交】（elf2mem.py 有断言），
//   所以先后 $readmemh 进同一个数组是安全的。合并后的 mem.hex 也可以直接
//   用 +IMEM= 传进来。
// ============================================================================
module unified_mem (
    // ---- A 口：取指（只读，同步读 1 拍）----
    input  wire [12:0] a_addr,
    output reg  [31:0] a_rd_data,
    input  wire        a_clk,
    input  wire        a_rst,

    // ---- B 口：访存（读写，按字节写，同步读 1 拍）----
    input  wire [12:0] b_addr,
    input  wire [31:0] b_wr_data,
    input  wire        b_wr_en,
    input  wire [3:0]  b_byte_en,
    output reg  [31:0] b_rd_data,
    input  wire        b_clk,
    input  wire        b_rst
);
    reg [31:0] mem [0:8191];
    reg [1023:0] hexpath;
    integer i;

    initial begin
        // 必须先清零：未初始化地址读出 X，会让比较类测试莫名失败
        for (i = 0; i < 8192; i = i + 1) mem[i] = 32'd0;
        if ($value$plusargs("IMEM=%s", hexpath)) begin
            // 显式给了 IMEM 就认它是主镜像（可以是 elf2mem.py 出的 mem.hex
            // 完整镜像，也可以是拆分的 imem.hex）；再给了 DMEM 才叠一份上去。
            $readmemh(hexpath, mem);
            if ($value$plusargs("DMEM=%s", hexpath)) $readmemh(hexpath, mem);
        end else begin
            // 都没给：用默认的拆分镜像
            $readmemh("programs/imem.hex", mem);
            $readmemh("programs/dmem.hex", mem);
        end
    end

    // A 口：同步读（非阻塞 ⇒ 与 B 口写同址时读到旧值，即 read_first）
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a_rd_data <= 32'd0;
        else       a_rd_data <= mem[a_addr];
    end

    // B 口：按字节写 + 同步读
    always @(posedge b_clk) begin
        if (b_wr_en) begin
            if (b_byte_en[0]) mem[b_addr][ 7: 0] <= b_wr_data[ 7: 0];
            if (b_byte_en[1]) mem[b_addr][15: 8] <= b_wr_data[15: 8];
            if (b_byte_en[2]) mem[b_addr][23:16] <= b_wr_data[23:16];
            if (b_byte_en[3]) mem[b_addr][31:24] <= b_wr_data[31:24];
        end
    end

    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) b_rd_data <= 32'd0;
        else       b_rd_data <= mem[b_addr];
    end
endmodule
