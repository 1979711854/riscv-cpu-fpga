`timescale 1ns/1ps
module core #(
    // 0 = 位不变的单发射回退版（slot B 恒 invalid、第二取指结果丢弃、相关逻辑被综合裁掉）
    // 1 = 有限度 2-wide in-order 双发射
    parameter DUAL_ISSUE = 0,

    // ---- [TASK-C 探针] 假 AGU（默认关）。开着只为综合量时序，功能不正确、不上板。----
    parameter AGU_PROBE = 0,

    // ---- [任务 C] load 地址提前（EARLY_LD）----
    // 1 = 把 load 的地址算到 ID 级、用【专用提前读口】早一拍取回数据，从而消掉
    //     紧跟其后的 load-use 停顿；0 = 逐位回退到旧行为（load 数据在 WB 才到）。
    // 只有"基址在 ID 级拿得到 + 地址落在 RAM 段 + 紧前不是 store/AMO"的 load
    // 才走快通路，其余退回旧通路（有停顿，但正确）—— 判据见 ld_fast 那一段。
    parameter EARLY_LD = 0
) (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] pc,

    // ---- [TASK-C 探针] 假 AGU 观测口（AGU_PROBE=0 时恒 0、无逻辑）----
    // 用途：量"把地址计算搬到 ID 级"要多少时序（任务书 v7 §5.C 的判据）。
    output wire [31:0] agu_probe,

    // ---- [任务 C] 提前 load 读口（只读、同步读 1 拍、与 A1/A2/B 同域）----
    // 地址由【ID/EX 寄存器】驱动（即 load 的 EX 级），数据下一拍回来 —— 正好是
    // 该 load 的 MEM 级，于是紧跟其后的指令在 EX 级就能前递到它，不用停一拍。
    // 后端是 unified_mem 里【第三份数组 mem2】（写口同样广播），所以它与 B 口
    // （store/AMO/旧通路 load 在用）不争端口。
    output wire [13:0] ld_addr,       // word 索引
    input  wire [31:0] ld_rdata,      // 同步读 1 拍延迟

    // ---- 取指口（A1 口）----
    // 契约：同步读、恰好 1 拍延迟（第 T 拍给地址 → 第 T+1 拍出数据）、只读、
    // 且【不做任何仲裁/冲突检测】。本模块的 stall/flush 补偿逻辑依赖 A 口
    // 每拍都能独立工作，加仲裁会直接破坏取指时序。
    output wire [13:0] imem_addr,     // word 索引；注意是 stall mux 之后的值
    input  wire [31:0] imem_rd,       // 同步读 1 拍延迟
    // ---- 取指口（A2 口，双发射第二读口）----
    // 与 A1 同拍、同延迟，读 unified_mem 的复制阵列。DUAL_ISSUE=0 时被丢弃。
    // [!] 宽度必须与 imem_addr **一致**（14 位 = 16384 word = 64KB）。
    //     2026-10-10 实查：存储器扩到 64KB 时漏了这里，它还是 32KB 时代的
    //     13 位，而 `imem_addr + 1` 是在 14 位宽里算的 → **赋给 13 位线时丢掉
    //     最高位** → imem_addr2 在 8192 word（字节 0x8000）处回绕。
    //     后果：取指地址 ≥ 0x8000 时 lane B 从低 32KB 取错地方
    //     （pair_now 判据用的就是 imem_rd2），会执行错指令。
    //     当时没炸只是因为没有程序的代码大过 32KB —— 而扩容的全部意义就是
    //     让代码能大过它。别再把这两根线的宽度写成不一样的。
    output wire [13:0] imem_addr2,
    input  wire [31:0] imem_rd2,

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

    // ---- 访存就绪（访存等待机制）----
    // 恒 1 时行为与"固定 1 拍"完全一致（逐位不变）。
    // 为 0 时本模块把 MEM/WB 与上游一起冻住，等它拉高 —— 这是接 APB/AXI
    // 等多拍总线的前提（那些协议一次传输要 2 拍以上，或要 valid/ready 握手）。
    // [!] 冻结方向必须和 stall/mc_stall 一致：【保持】而不是【清】。
    //     清成气泡会把还没写回的那条指令丢掉。
    input  wire        mem_ready,

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
    // 冒险 / 多拍功能单元（除法器 + 乘法器）
    wire        stall;
    wire [31:0] div_result, mul_result;
    wire        div_busy, div_done;
    wire        mul_busy, mul_done;
    wire        div_stall;      // 多拍除法停顿
    wire        mul_stall;      // 多拍乘法停顿
    // 二者的并 =「EX 里那条多拍指令还没算完」，流水线前端必须冻住。
    // [!] 前端所有冻结判据一律用 mc_stall，【不要】直接用 div_stall 或 mul_stall ——
    //     漏掉任何一路都会静默丢/重复执行指令（与历史上漏 mem_ready 同类）。
    wire        mc_stall;
    wire        ex_flush;
    wire [31:0] ex_target;      // EX 级解析出的跳转目标（在 EX 段才被赋值）
    // 分支预测：到达级预测重定向 / EX 级误判恢复（三段都在后文才被赋值）
    // [阶段1] 重定向从 ID 级提前到【到达级】（if_addr_d + imem_rd 一出现就重定向），
    //   被预测 taken 的分支省掉那 1 拍取指重定向气泡（v6 任务书阶段1）。
    wire        p_redirect;     // 到达级预测重定向
    wire [31:0] p_target;       // 到达级预测目标（= if_addr_d + imm）
    wire        ex_mispred;     // 预测 taken 但实际 not-taken
    wire [31:0] ex_mispred_target;
    // [双发射] 本拍 ID 是否把 lane A + lane B 两条一起放走。恒 0 即单发射。
    //   它同时决定【取指跳步】：pair=0 → 下次取 +4；pair=1 → 下次取 +8。
    //   因为 fetch_addr 直接由它组合算出（见下），lane A/B 无需队列即可自对齐：
    //   A2 口恒取 lane A 的相邻字，正好就是 lane B。
    wire        pair_now;

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
    // A 扩展：ID 级译码出来的 AMO 控制
    wire        id_is_amo;
    wire [4:0]  id_amo_funct5;
    wire        csr_wr_illegal;
    wire [31:0] csr_wdata;
    wire        csr_wr_en;
    // ID/EX
    reg        id_ex_reg_write, id_ex_alu_a_sel, id_ex_alu_b_sel, id_ex_mem_read, id_ex_mem_write;
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
    // ---- A 扩展（AMO/LR/SC）----
    // [!] AMO 的地址来自 rs1（不是 rs1+imm），第二个操作数是 rs2。
    //   两者都必须带进 MEM，且 rs2 要走前递 —— 否则 "amoadd a0,a1,a2"
    //   在 a2 刚被前一条指令写过时会读到陈旧值。
    reg        id_ex_is_amo;
    reg  [4:0] id_ex_amo_funct5;
    // EX/MEM
    reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    reg [1:0]  ex_mem_wb_sel;
    reg [31:0] ex_mem_alu_result, ex_mem_wdata, ex_mem_pc, ex_mem_imm;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_sys_ebreak;
    // AMO 专用（把 id_ex 的操作数与操作码带进 MEM）
    reg        ex_mem_is_amo;
    reg  [4:0] ex_mem_amo_funct5;
    reg  [31:0] ex_mem_amo_addr;
    // MEM/WB
    reg        mem_wb_reg_write;
    reg [1:0]  mem_wb_wb_sel;
    reg [31:0] mem_wb_alu_result, mem_wb_pc, mem_wb_imm;
    reg [4:0]  mem_wb_rd;
    reg [2:0]  mem_wb_funct3;
    reg [1:0]  mem_wb_addr_low;
    // [A 扩展] 本条是 AMO —— WB 级据此选 amo_wb_data 作为写回值
    reg        mem_wb_is_amo;

    // ---- [任务 C] load 地址提前（EARLY_LD）：级间标志与提前读回的数据 ----
    // ID/EX：这条 load 是否走快通路 + 它在 ID 级算好的地址
    reg        id_ex_ld_fast;
    reg [31:0] id_ex_ld_addr;
    // EX/MEM：快通路 load 的标志（EX 级前递与未对齐判据要用）
    reg        ex_mem_ld_fast;
    // MEM/WB：快通路 load 的原始字（在它 MEM→WB 那个沿抓，旧通路抓的是实时
    //   mem_rdata —— 快通路的数据早一拍到，必须在沿上寄存下来）
    reg        mem_wb_ld_fast;
    reg [31:0] mem_wb_ld_raw;
    // 提前读回的"抢救快照"：与 wb_rdata_snap 同构 —— 访存冻结会让实时 ld_rdata
    // 在下一拍跟到别人的地址上，所以停顿第一个沿先把它抓下来（理由见 WB 段）。
    reg        ld_snap_en;
    reg [31:0] ld_snap;
    wire [31:0] ld_early_data;     // = 快通路 load 在【它的 MEM 级】的数据
    // ID 级算出来的 load 地址与"能否走快通路"
    wire [31:0] ld_id_addr;
    wire        ld_fast;

    // ---- [A 扩展] AMO 单元输出（提前声明：访存口的 assign 在下面要用到它们）----
    wire        amo_stall;
    wire        amo_mem_re, amo_mem_we;
    wire [3:0]  amo_byte_en;
    wire [31:0] amo_wdata, amo_wb_data;
    wire        amo_illegal;
    wire        amo_mem_release;     // amo_unit：本拍 = ST_WRITE（写回拍）
    // ---- [A 扩展] "AMO 占住 MEM 级" 的冻结网 ----
    // AMO 是【MEM 级】多拍单元（读-改-写），必须把 EX/MEM 连同整个前端一起
    // 【保持】到写回拍 —— 不能走 mc_stall：那条路把 EX/MEM 清成气泡，清掉的正是
    // 在跑状态机的那条 AMO。改用既有的 mem_ready 冻结机制（同为"保持"语义）：
    //   amo_hold      : AMO 已在 EX/MEM 且尚未到 ST_WRITE
    //   mem_ready_int : 把 amo_hold 并进访存就绪
    //   stall_int     : 停顿的"效果"只在流水线真的前进那拍才允许发生
    wire        amo_hold;
    wire        mem_ready_int;
    wire        stall_int;
    // 写回数据
    wire [31:0] wb_data;

    // ---- lane B（双发射第二槽）流水线寄存器 ----
    // 只带 ALU 类指令用得到的字段：pairable_b 保证 lane B 不是 load/store/branch/
    //   jump/csr/sys，所以不需要 funct3、不需要任何访存/重定向/系统标志。
    // ID/EX
    reg        id_ex_b_reg_write, id_ex_b_alu_a_sel, id_ex_b_alu_b_sel, id_ex_b_valid;
    reg [4:0]  id_ex_b_alu_op;
    reg [1:0]  id_ex_b_wb_sel;
    reg [31:0] id_ex_b_pc, id_ex_b_rdata1, id_ex_b_rdata2, id_ex_b_imm;
    reg [4:0]  id_ex_b_rd, id_ex_b_rs1, id_ex_b_rs2;
    // EX/MEM
    reg        ex_mem_b_reg_write, ex_mem_b_valid;
    reg [1:0]  ex_mem_b_wb_sel;
    reg [31:0] ex_mem_b_alu_result, ex_mem_b_pc, ex_mem_b_imm;
    reg [4:0]  ex_mem_b_rd;
    // MEM/WB
    reg        mem_wb_b_reg_write;
    reg [1:0]  mem_wb_b_wb_sel;
    reg [31:0] mem_wb_b_alu_result, mem_wb_b_pc, mem_wb_b_imm;
    reg [4:0]  mem_wb_b_rd;
    // lane B 写回数据（无 load 分支：wb_sel=01 对 lane B 不可能）
    wire [31:0] wb_data_b;
    // ------------------------------------------------------------------

    // 访存口：MEM 级组合输出，一拍的稳定窗口，直接进总线（写通路零寄存器）
    // [A 扩展] AMO 自己驱动访存端口（它要读-改-写，占两拍）。
    // control.v 的 AMO 分支【没有】置 mem_read/mem_write，所以两者互斥，
    // 这里做 or 而不是 mux。
    assign mem_we   = ex_mem_mem_write | amo_mem_we;
    // [任务 C] 快通路 load 的数据由【提前读口】给（它自己的 MEM 级就拿到了），
    //   所以它不再占用 B 口这次读 —— 否则会白占端口、还会被 mem_ready/多拍总线
    //   当成"一次在途访存"而多冻一拍。EARLY_LD=0 时 ex_mem_ld_fast 恒 0 ⇒ 逐位不变。
    assign mem_re   = (ex_mem_mem_read && !ex_mem_ld_fast) | amo_mem_re;
    // [A 扩展] AMO 占 MEM 期间 mem_addr 切到它自己的地址：
    //   ex_mem_amo_addr 就是【前递后的 rs1】（AMO 的地址语义是 rs1，不是 rs1+imm，
    //   所以绝不能用 ex_mem_alu_result）。它在整个占用期间稳定不变（EX/MEM 被
    //   amo_hold 冻住）—— 这一点【承重】：B 口的读地址必须一直保持，amo_unit 才
    //   能在 ST_LATCH 拍到正确的旧值。（历史 bug：地址中途掉成 0，锁回的是地址 0
    //   的指令字，写也写到了 0。写数据/字节使能的 mux 在下面的 always 块里。）
    assign mem_addr = ex_mem_is_amo ? ex_mem_amo_addr : ex_mem_alu_result;
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
    //   3. p_redirect  —— 到达级预测重定向（本身已用 !ex_flush 门控，这里再排一次
    //                     只为把优先级写成自明的）
    //   4. stall/div    —— 退格重读，不改变地址流
    //
    // 互斥性说明：ex_flush 来自 EX 是分支/跳转、mc_stall 来自 EX 是除法或乘法
    // （id_ex_is_div / id_ex_is_mul）、stall 来自 EX 是 load（id_ex_mem_read）
    // —— 四者在 EX 级由同一条指令的性质决定，互斥。
    //   trap 优先级最高：异常/中断时 EX 级那条指令必须被丢弃，
    //   它比任何分支重定向都优先。（mret 不在这里 —— 它折进了 ex_flush，见 EX 段。）
    //
    // [!] `!mem_ready` 必须和 stall/mc_stall 一起退回 if_addr_d ——
    //     这不是"顺手加的"，是【承重】的，漏了会静默丢指令：
    //
    //     访存停顿的第一拍会把 IF/ID 冻结，而那一拍本来要收下的是上一拍发出的
    //     那次取指（地址 = if_addr_d）。冻结把它拦掉了，所以必须【重发同一个
    //     地址】—— 这正是 if_addr_d 这条支路存在的理由，和 stall 完全同理。
    //
    //     若这里退回 pc_r（错），则会去取"下一条"，于是那条被拦掉的指令
    //     永远补不回来 → 程序从停顿点开始整段错位。
    //     2026-09-27 实测：漏了它时 +MEMWAIT=2 下 RT-Thread 一个字节都打不出来，
    //     pc 停在 0x18d0；补上后同样的等待周期下全部自检通过。
    // [!] 单发射回退路径（pair_now=0）下，`if_addr_d + 4` 与原来的 `pc_r` 逐拍等价：
    //     pc_r 正常推进 +4 且 fetch_addr=pc_r，故 fetch_addr[N]=pc_r[N]=pc_r[N-1]+4
    //     =if_addr_d[N]+4。三路重定向下面两者都旁路成同一个目标；stall 都退回
    //     if_addr_d。所以 DUAL_ISSUE=0 时行为逐位不变。
    //
    // [双发射] 取指源头由 pc_r 改成「最后发出的地址 + 4」，并再加「本拍配对了就 +4」。
    //   这样【本拍发射的地址 = 本拍槽 A 的地址 + 4*(1+pair)】——正好是下一条未消费
    //   指令，A/B 两槽于是每拍天然对齐，不需要取指队列去吸收可变宽度弹出。
    //   代价是 pair→fetch_addr 组合路径（BRAM 出 → 译码 → pair → 本 mux → BRAM 地址），
    //   无环路（中间隔 BRAM 寄存器），正是 Stage B/C 要测的 Fmax 风险点。
    wire [31:0] fetch_addr = trap                ? trap_target :
                             ex_flush            ? ex_target :
                             ex_mispred          ? ex_mispred_target :
                             p_redirect          ? p_target :
                             (stall_int || mc_stall || !mem_ready_int) ? if_addr_d :
                             if_addr_d + 32'd4 + (pair_now ? 32'd4 : 32'd0);
    // （pair_now 的实际赋值在下面到达级预测/stall 之后 —— 它要引用 p_pred_taken。）

    // 更新【无门控】：fetch_addr 在 stall/mc_stall 时就等于 if_addr_d 自身，
    // 所以"照抄回去"是空操作，等价于原来的 `if (!stall && !mc_stall)` 门控。
    //
    // [!] 原来那个门控必须去掉，因为 `trap && stall` 是**可达的**
    //（EX 里是未对齐的 load 时，ex_exception 与 load-use stall 同拍成立）。
    // 那时 fetch_addr = trap_target 而门控会拦住更新 → if_addr_d 停在旧值
    // → 下一拍的 if_id_pc 与指令对不上。这个坑基线测试碰不到，只有自写的
    // trap handler 会炸，属于"静默错位"那一类。
    // [!] 复位值必须是 **-4**（不是 0）：取指源头是「if_addr_d + 4」，只有初值 -4
    //     才能让上电第一拍发出地址 0（= 复位向量）。复位期间 imem_rd 是 BRAM 的
    //     复位值 0，所以第一拍 IF/ID 锁到的是气泡（valid=0），-4 不会变成一条
    //     带错误 pc 的真指令；第二拍起 if_id_pc 就与 imem_rd 对齐。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) if_addr_d <= 32'hFFFF_FFFC;
        else if_addr_d <= fetch_addr;
    end

    // ================= IF/ID =================
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    // [双发射] lane B（较年轻的槽）。A2 口恒取 lane A 的相邻字，所以 lane B 的
    //   (pc, instr) 与 lane A 同拍对齐：(if_addr_d+4, imem_rd2)，延迟与 lane A 一致。
    reg [31:0] if_id_pc_b;
    reg [31:0] if_id_instr_b;
    // [双发射] lane B 与 lane A 同拍发射的判定，在【到达级】算好、随 IF/ID 一起寄存。
    //   之后 ID/EX 用这个寄存值收 lane B —— 不能用当拍的 pair_now：pair_now 描述的是
    //   【下一组取指】，比 IF/ID 里这两条指令年轻一拍，用它收 lane B 会错位。
    reg        if_id_pair;
    reg        if_id_pred_taken;  // [阶段1] 到达级预测结果随指令进 IF/ID（EX 级判误用）

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

    // ---- lane B 的译码源 ----
    wire [4:0] rs1_b = if_id_instr_b[19:15];
    wire [4:0] rs2_b = if_id_instr_b[24:20];
    wire [4:0] rd_b  = if_id_instr_b[11:7];
    wire [6:0] opcode_b = if_id_instr_b[6:0];
    wire [6:0] funct7_b = if_id_instr_b[31:25];

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
        .illegal    (id_illegal),
        // ---- A 扩展 ----
        .is_amo     (id_is_amo),
        .amo_funct5 (id_amo_funct5)
    );

    wire [31:0] rdata1, rdata2;
    wire [31:0] rdata1_b, rdata2_b;
    // [双发射] 4 读 2 写寄存器堆。lane A = 现有单发射通路；lane B = 第二槽。
    //   写口 B 在 A 之后写，所以同址（理论上不会，pairable_b 排掉 rd_a==rd_b）B 赢。
    //   DUAL_ISSUE=0 时 pair_now 恒 0 ⇒ lane B 恒气泡，B 侧端口无消费者，综合裁掉。
    regfile u_regfile (
        .clk(clk), .resetn(resetn),
        // 写口 A（lane A）
        .we_a(mem_wb_reg_write), .rd_a(mem_wb_rd), .wd_a(wb_data),
        // 写口 B（lane B）
        .we_b(mem_wb_b_reg_write), .rd_b(mem_wb_b_rd), .wd_b(wb_data_b),
        // 读口 1/2（lane A）
        .rs1_a(rs1), .rdata1_a(rdata1),
        .rs2_a(rs2), .rdata2_a(rdata2),
        // 读口 3/4（lane B）
        .rs1_b(rs1_b), .rdata1_b(rdata1_b),
        .rs2_b(rs2_b), .rdata2_b(rdata2_b)
    );

    wire [31:0] imm;
    imm_gen u_imm (.instr(if_id_instr), .imm(imm));

    // ---- lane B 的第二套 control/imm_gen（原文件不改，只多实例化）----
    //   只消费其中 {reg_write, alu_a_sel, alu_b_sel, alu_op, wb_sel, imm}；
    //   其余输出（mem/branch/jump/csr/sys/illegal）对 lane B 恒无意义，综合会裁掉。
    //   pairable_b 已保证 lane B 只能是 {OP_REG, OP_IMM, LUI, AUIPC}，它们在这套
    //   译码下 mem_read/mem_write/branch/jump/jump_reg/is_csr/sys_* 全为 0。
    wire        reg_write_b, alu_a_sel_b, alu_b_sel_b;
    wire [4:0]  alu_op_b;
    wire [1:0]  wb_sel_b;
    wire        mem_read_b, mem_write_b, branch_b, jump_b, jump_reg_b;
    wire        sys_ebreak_b, is_csr_b, csr_imm_b, sys_ecall_b, sys_mret_b, id_illegal_b;
    wire [11:0] csr_addr_b;
    wire [1:0]  csr_cmd_b;
    control u_ctrl_b (
        .instr      (if_id_instr_b),
        .reg_write  (reg_write_b),
        .alu_a_sel  (alu_a_sel_b),
        .alu_b_sel  (alu_b_sel_b),
        .alu_op     (alu_op_b),
        .mem_read   (mem_read_b),
        .mem_write  (mem_write_b),
        .branch     (branch_b),
        .jump       (jump_b),
        .jump_reg   (jump_reg_b),
        .wb_sel     (wb_sel_b),
        .sys_ebreak (sys_ebreak_b),
        .is_csr     (is_csr_b),
        .csr_addr   (csr_addr_b),
        .csr_cmd    (csr_cmd_b),
        .csr_imm    (csr_imm_b),
        .sys_ecall  (sys_ecall_b),
        .sys_mret   (sys_mret_b),
        .illegal    (id_illegal_b)
    );
    wire [31:0] imm_b;
    imm_gen u_imm_b (.instr(if_id_instr_b), .imm(imm_b));

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
    // jal 无条件必跳、目标只依赖 PC+imm，仍走静态预测；jalr 目标依赖 rs1、到达级无
    // 前递通路，仍【不预测】走 EX 冲刷。保守版因此不需要 BTB 的 target 部分：branch/jal 的
    // 目标与 EX 级算出的必然相同，不存在"预测对方向但目标算错"（那只可能由 jalr 引起）。
    // 索引 idx=PC[9:2]、tag=PC[31:8]，直接映射 256 项。预测错不影响正确性：EX 级冲刷兜住。
    // [阶段1] 查询点从 ID 级（if_id_pc）挪到【到达级】（if_addr_d，见下面的 bht_idx_p）：
    //   到达级同一拍 imem_rd 已给出指令字，可当场算出目标 p_target 并立即重定向，
    //   被预测 taken 的分支不再付那 1 拍取指重定向气泡。
    reg [23:0] bht_tag  [0:255];
    reg [1:0]  bht_ctr  [0:255];
    reg [255:0] bht_valid;

    // ex_flush 优先：EX 级是更老的指令，它重定向时到达级/ID 级指令本来就会被杀掉。
    // stall / mc_stall 时 ID/EX 不前进或保持，重定向必须一并抑制，否则 pc_r 与
    // 流水线状态会脱节。
    // [!] `mem_ready` 必须或进来 —— 这一条不加会【静默破坏分支预测的一致性】：
    //
    //   `id_ex_pred_taken <= if_id_pred_taken`（见 ID/EX 段）锁存的是"是否真的重定向过"
    //   这一事实，而 p_redirect 的另外三个因子（ex_flush/stall/mc_stall）来自【后级】、
    //   逐拍在变。没有访存停顿时，分支在到达级只停 1 拍，两边天然一致；
    //   一旦访存停住多拍，分支会在到达级滞留好几拍，于是可能出现
    //   "某一拍真的重定向了、锁存那一拍却没置上 pred 标志" —— 状态不一致。
    //
    //   后果：那条分支进 EX 后 id_ex_pred_taken=0，于是
    //     ex_flush   = ex_resolve_taken && !pred   → 该跳时冲刷（看起来正常）
    //     ex_mispred = !ex_resolve_taken && pred    → 该【不】跳时【不】恢复 ✗
    //   即"预测 taken 但实际 not-taken"这条恢复路径永远不触发 → 分支预测
    //   一旦预测 taken 就再也纠不回来，循环退不出去。
    //   2026-09-27 实测：漏了它时 +MEMWAIT=2 下 BSS 清零循环冲过上限 0x6128
    //   一直转（pc 停在 0x24，rs1_val 已到 0x6200）。
    //
    //   抑制到 mem_ready 释放那拍再统一生效是安全的：停顿期间取指本来就冻着
    //   （fetch_addr 走 if_addr_d），重定向晚一拍执行正好跟着一起释放。
    //   （p_redirect 本体的赋值在下面【到达级预测】那一小段，和 p_target 一起。）

    // ================= hazard (load-use stall only；其余 RAW 由 forwarding 解决) =================
    // [双发射] load 的 rd 要对 **4 个** ID 源比较：lane A 的 rs1/rs2 + lane B 的 rs1/rs2。
    //   lane B 自己不会是 load（pairable_b 只放 ALU 类），所以只需 lane A 这一侧。
    //   若漏掉 rs1_b/rs2_b，"load 后紧跟一条同拍发射、依赖它的 lane B" 会拿到陈旧值。
    // [!] lane B 那两项必须用 if_id_pair 门控 —— if_id_instr_b 每拍都在锁存（它就是
    //   imem_addr2 的读结果），但只有 if_id_pair=1 时那条指令才真会进 ID/EX。
    //   不门控的话，单发射（pair 恒 0）下"load 后面恰好跟着一条用到该 rd 的指令"
    //   也会误报一次停拍 —— 那条指令根本不在同拍发射，停它纯属浪费。
    //   实测（CoreMark ITER=1）：漏门控时每迭代多 9,906 拍（363,515 → 373,421），
    //   且 riscv-tests 全 PASS 也照样查不出来（那批测试几乎没有 load 后紧接依赖）。
    // [任务 C] `!id_ex_ld_fast` 是新增的：走快通路的 load 数据早在 MEM 级就前递得到
    //   （见下面 EX 段新增的 ld_fwd_* 一路），再停一拍就是纯浪费。
    //   快通路 load 的判据保证它"一定"能在 MEM 级给出数据，所以这里可以无条件免停。
    assign stall = (id_ex_mem_read && !id_ex_ld_fast && (id_ex_rd != 5'd0) &&
                    ((id_ex_rd == rs1) || (id_ex_rd == rs2) ||
                     (if_id_pair && ((id_ex_rd == rs1_b) || (id_ex_rd == rs2_b)))));

    // [A 扩展] stall 的【效果】（清 ID/EX、插气泡）只允许在流水线真的前进那一拍发生。
    //   AMO 占 MEM 期间 mem_ready_int=0：此刻必须"保持"——清了就把冻在 ID/EX 的那条
    //   load 丢了（它还没来得及进 EX/MEM）。到 AMO 放开那拍 mem_ready_int 恢复 1，
    //   stall_int 正好重新等于 stall：load 进 EX/MEM、ID/EX 插气泡，标准 load-use
    //   时序一步不少。mem_ready=1 的常态下 stall_int 与 stall 逐位相同。
    assign stall_int = stall && mem_ready_int;

    // ================= 保守配对规则（lane B 是否随 lane A 同拍发射）=================
    // [!] 判据必须建立在【BRAM 数据到达级】的原始信号上（imem_rd / imem_rd2 /
    //     if_addr_d），【不能】用 ID 级已寄存的 if_id_*。
    //     原因：pair 要驱动取指跳步（+4 / +8），而取指比 ID 早 2 拍（BRAM 1 拍 +
    //     IF/ID 1 拍）。决定若在 ID 做，取指永远慢一拍，IF/ID 会把 lane B 重复
    //     消费一次 —— 这正是"必须加取指队列"那个结论的来源。把决定提前到达级，
    //     队列就不需要了：fetch_addr 直接由 pair 组合算出，A/B 两槽天然对齐。
    //     代价是 imem_rd → pair → fetch_addr → BRAM 地址 这条组合路径（无环路，
    //     中间隔 BRAM 寄存器），正是要测的 Fmax 风险点。
    //
    // 规则：lane B 只允许 OP_REG / OP_IMM / LUI / AUIPC —— 这四个 opcode 结构上
    //   不产生 branch/jump/mem/csr/sys，所以 B **永远不碰**重定向、陷阱、BHT、
    //   访存、乘除单元，控制/重定向逻辑一个门都不加（只多驱动 1 份寄存器）。
    //   排除 M 扩展（funct7=1）是因为 mul/div 走共享多拍单元。
    //   rd_a 与 rs1_b/rs2_b/rd_b 相等：同拍无 A→B 旁路，且同址写回语义会打架。
    wire [6:0] p_op_a  = imem_rd[6:0];
    wire [6:0] p_f7_a  = imem_rd[31:25];
    wire [4:0] p_rd_a  = imem_rd[11:7];
    wire [6:0] p_op_b  = imem_rd2[6:0];
    wire [6:0] p_f7_b  = imem_rd2[31:25];
    wire [4:0] p_rd_b  = imem_rd2[11:7];
    wire [4:0] p_rs1_b = imem_rd2[19:15];
    wire [4:0] p_rs2_b = imem_rd2[24:20];

    // [!] lane A 是 M 扩展（mul/div/rem，funct7=0000001 且 OP_REG）时【禁止配对】。
    //   它们是唯一会让 lane A 走多拍单元（mc_stall）的指令，而 mc_stall 期间：
    //     * EX/MEM 被清成气泡、MEM/WB 照常前进 ⇒ 前递窗口在下游"排空"；
    //     * 但 lane B 却和 lane A 一起【冻在 ID/EX 里】不动。
    //   等到 mc_stall 释放那一拍，lane B 要用的源可能已经滑出 EX/MEM 与 MEM/WB，
    //   只能回落到进入 ID/EX 时锁存的 id_ex_b_rdata*，而那是【陈旧】的寄存器值。
    //   实测（mul.elf）：`li tp,0` 与 `mul` 相隔两条，lane B 的 `addi tp,tp,1` 读到
    //   未更新的 tp=2，得到 3 而不是 1 ⇒ 循环永不退出 ⇒ TIMEOUT。
    //   单发射永远不会有这个"两条同处 ID/EX 又同时被冻"的局面，所以只在此排除即可；
    //   其余停顿源（stall 清 ID/EX、mem_ready=0 冻结整个前递窗口）都不受影响。
    wire p_muldiv_a = (p_op_a == 7'b0110011) && (p_f7_a == 7'b0000001);
    // [A 扩展] AMO 也不做 lane A 配对。理由与 mul/div 同源（多拍单元 + lane B
    //   一起冻在 ID/EX，前递窗口在下游排空）。AMO 的冻结机制后来已改成
    //   amo_hold/mem_ready_int（EX/MEM 是【保持】而不是被清），所以这一条已不是
    //   "必须"；保守保留：AMO 占比极小、配对收益可忽略，而"lane B 跨 4 拍 AMO
    //   冻结后的前递"还没有逐拍验证过。
    wire p_amo_a = (p_op_a == 7'b0101111);

    wire p_branch = (p_op_a == 7'b1100011);
    wire p_jump   = (p_op_a == 7'b1101111);
    wire [7:0] bht_idx_p   = if_addr_d[9:2];
    wire       bht_hit_p   = bht_valid[bht_idx_p] && (bht_tag[bht_idx_p] == if_addr_d[31:8]);
    wire       bht_taken_p = bht_ctr[bht_idx_p][1];
    // 静态规则兜底：BHT 未命中时后向条件分支 / jal 预测跳转（到达级 pc = if_addr_d）
    wire       p_pred_taken = (p_branch && bht_hit_p) ? bht_taken_p
                            : ((p_branch && imem_rd[31]) || p_jump);
    // [阶段1] 到达级预测目标与重定向。目标 = if_addr_d + imm，imm 由 imem_rd 译出
    //   （第三个 imm_gen 实例，专门给到达级用）。p_redirect 的门控注释见上面
    //   "动态预测（保守版）"那一段（mem_ready 那条承重逻辑）。
    wire [31:0] p_imm;
    imm_gen u_imm_p (.instr(imem_rd), .imm(p_imm));
    assign      p_target   = if_addr_d + p_imm;
    assign      p_redirect = p_pred_taken && !ex_flush && !stall_int && !mc_stall && mem_ready_int;
    wire p_opcode_b_ok = (p_op_b == 7'b0110011) || (p_op_b == 7'b0010011) ||
                         (p_op_b == 7'b0110111) || (p_op_b == 7'b0010111);

    assign pair_now = (DUAL_ISSUE != 0) &&
                      (imem_rd != 32'd0) && (imem_rd2 != 32'd0) && !p_pred_taken &&
                      !p_muldiv_a && !p_amo_a &&
                      p_opcode_b_ok && (p_f7_b != 7'b0000001) && (p_rd_b != 5'd0) &&
                      (p_rd_a != p_rs1_b) && (p_rd_a != p_rs2_b) && (p_rd_a != p_rd_b);

    // 取指地址：stall 时退一格到在途指令 if_addr_d 让同步读重新锁存正确数据，
    // 跳转时当拍旁路到目标（见上面 fetch_addr 的说明）。
    assign imem_addr = fetch_addr[15:2];   // 64KB = 16384 word

    // 第二取指地址：固定指向下一个 word。
    // [!] 常量必须写 `14'd1`（与 imem_addr 同宽）。写成 `13'd1` 的话加法仍在
    //     14 位宽里做，本身不错，但一旦接收端也是窄的就会截位 —— 见端口声明处的
    //     [!]。这里写全宽是让"谁在哪个宽度上算"一目了然，两边一起改不难。
    //     DUAL_ISSUE=0 时它在核内没有任何消费者，综合会连同 A2 口的读结果一起裁掉。
    assign imem_addr2 = imem_addr + 14'd1;

    // ================= ID/EX =================
    // （级间寄存器声明已提前到文件顶部，避免 forward reference）

    // ================= EX =================
    // ---- EX 阶段 forwarding ----
    // [双发射] 优先级（同 stage 内【年轻的赢】）：
    //     ex_mem_b > ex_mem_a > mem_wb_b > mem_wb_a > regfile
    //   两个 lane 的源操作数都用这同一套源。intra-pair 依赖（lane B 依赖同拍 lane A）
    //   已被 pairable_b 排掉，所以不需要 A→B 同拍旁路（那是 Stage D 的可选项）。
    //
    // EX/MEM 写回候选值；lane A 的 load(wb_sel=01) 数据要 WB 才有效，不从此处前递。
    // lane B 结构上不会是 load，故无需排除。
    wire [31:0] ex_mem_forward_val =
        // [A 扩展] AMO 的结果不在 ex_mem_alu_result 里（wb_sel 保持 00），而在
        //   amo_unit 的 wb_data。它在 ST_WRITE（= mem_release）那拍有效，正好是
        //   后一条指令从 ID/EX 进 EX/MEM 的那拍 —— 这一路必须补上，否则
        //   "amoadd 之后紧跟一条读 rd 的指令"会前递到 ALU 的垃圾值。
        ex_mem_is_amo ? amo_wb_data :
        (ex_mem_wb_sel == 2'b10) ? (ex_mem_pc + 32'd4) :
        (ex_mem_wb_sel == 2'b11) ? ex_mem_imm :
        ex_mem_alu_result;
    wire [31:0] ex_mem_forward_val_b =
        (ex_mem_b_wb_sel == 2'b10) ? (ex_mem_b_pc + 32'd4) :
        (ex_mem_b_wb_sel == 2'b11) ? ex_mem_b_imm :
        ex_mem_b_alu_result;

    // ==================================================================
    // [任务 C] ID 级地址生成（AGU）+ 快通路判据（EARLY_LD=0 时 ld_fast 恒 0）
    // ------------------------------------------------------------------
    // 为什么要提前：load 地址若在 EX 级才算，数据要 WB 才回来，紧跟其后的消费者
    //   必须停一拍 —— 这就是区间内 27,181 拍 / 10.4% 的 load-use 停顿。
    //   地址提前到 ID + 专用读口早一拍取回 ⇒ 消费者在 EX 级就能前递到数据。
    //
    // [!] 只让【能安全提前】的 load 走快通路，其余原样退回旧通路（旧通路一行未改）。
    //     "判据先行"实测（+LDANAL，2026-10-11）：区间内 86.3% 的 load 可走快通路，
    //     被挡住的只有 696（基址在 EX）+ 1,869（紧前是 store）+ 48（非 RAM）。
    //       ① 基址在 ID 级拿得到 —— 不含"被 EX 级那条指令刚写出"（结果还在 ALU 里），
    //          也不含"被 EX/MEM 里的 load/AMO 写"（数据还没回来）
    //       ② 地址必须落在 RAM 段 —— 提前读口只镜像 RAM（外设/视频/兼容区没有）
    //       ③ 紧前一条不能是 store —— 它与提前读口同址时是同拍写/读，读到旧值
    //          （同理：紧前一条若是 AMO，它的写与冻结放开在同一沿）
    //       ④ 前/后不能有 AMO
    //     四条都是【保守】判据：判错只是退回旧通路（慢一拍、但一定对）。
    // ==================================================================
    // ---- ID 级 rs1 前递网（只服务 load 的地址计算；不含 EX 级本身 = 判据①）----
    wire        ld_f_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == rs1);
    wire        ld_f_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == rs1) &&
                           (ex_mem_wb_sel != 2'b01) && !ex_mem_is_amo;
    wire        ld_f_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == rs1);
    wire        ld_f_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == rs1);
    wire [31:0] ld_base  = ld_f_exb ? ex_mem_forward_val_b :
                           ld_f_ex  ? ex_mem_forward_val :
                           ld_f_wbb ? wb_data_b :
                           ld_f_wb  ? wb_data : rdata1;
    // load 的地址 = base + imm（control.v 里 load 恒 alu_op=ADD、alu_b_sel=1 取 imm）
    assign      ld_id_addr = ld_base + imm;

    wire ld_bad_base = (id_ex_reg_write   && (id_ex_rd   != 5'd0) && (id_ex_rd   == rs1)) ||
                       (id_ex_b_reg_write && (id_ex_b_rd != 5'd0) && (id_ex_b_rd == rs1)) ||
                       ((ex_mem_rd != 5'd0) && (ex_mem_rd == rs1) &&
                        (ex_mem_mem_read || ex_mem_is_amo));                  // 判据①
    wire ld_bad_ram  = !((ld_id_addr[31:16] == 16'd0) &&
                         (ld_id_addr[15:4] != 12'hFFF));                      // 判据②
    wire ld_bad_st   = id_ex_mem_write;                                       // 判据③
    wire ld_bad_amo  = id_ex_is_amo || ex_mem_is_amo;                         // 判据④

    assign ld_fast = (EARLY_LD != 0) && mem_read &&
                     !ld_bad_base && !ld_bad_ram && !ld_bad_st && !ld_bad_amo;

    // 提前读口地址：由 ID/EX 驱动（= 该 load 的 EX 级）。非快通路时指 0（无用）。
    assign ld_addr = id_ex_ld_fast ? id_ex_ld_addr[15:2] : 14'd0;

    // 快通路 load 的数据：正常取实时 ld_rdata；访存冻结期间取快照（理由同 WB 段）
    assign ld_early_data = (EARLY_LD != 0 && ld_snap_en) ? ld_snap : ld_rdata;

    // 抢救快照：与 wb_rdata_snap 同构 —— 冻结的下一拍实时 ld_rdata 已经跟到
    // 别人的地址上（ID/EX 里的后继指令重新驱动了读口），所以第一个停顿沿先抓。
    always @(posedge clk or negedge resetn) begin
        if (!resetn || (EARLY_LD == 0)) begin
            ld_snap    <= 32'd0;
            ld_snap_en <= 1'b0;
        end else if (mem_ready_int) begin
            ld_snap_en <= 1'b0;
        end else if (!ld_snap_en) begin
            ld_snap    <= ld_rdata;
            ld_snap_en <= 1'b1;
        end
    end

    // [任务 C] 快通路 load 的数据前递：EX/MEM 里那条是快通路 load，它的数据【这一拍】
    //   就在 ld_early_data 上（地址是它上一拍在 EX 级发的）—— 也正是"它 MEM 级"这一拍。
    //   优先级最高：它是 EX/MEM 里那条更年轻的来源之一（同 lane A），而 lane B 比它更新。
    //
    // [!] 前递出去的必须是【解包后】的值，不能是原始字 —— lb/lbu/lh/lhu 要按 funct3
    //     与地址低两位取字节/半字。2026-10-11 实踩：只前递原始字时 `lw` 全过、
    //     `lb/lbu/lh` 全 FAIL（`lhu` 因为测试数据高半字恰好为 0 而蒙混过去），
    //     CoreMark 的 matrix/state CRC 也全错（它用的是 u16）。
    //     WB 段那条解包逻辑服务的是写回，这里必须【另来一份】服务前递。
    wire [7:0]  ld_fwd_byte = (ex_mem_alu_result[1:0] == 2'd0) ? ld_early_data[7:0]   :
                              (ex_mem_alu_result[1:0] == 2'd1) ? ld_early_data[15:8]  :
                              (ex_mem_alu_result[1:0] == 2'd2) ? ld_early_data[23:16] :
                                                                 ld_early_data[31:24];
    wire [15:0] ld_fwd_half = ex_mem_alu_result[1] ? ld_early_data[31:16] : ld_early_data[15:0];
    wire [31:0] ld_early_val =
        (ex_mem_funct3 == 3'b000) ? {{24{ld_fwd_byte[7]}}, ld_fwd_byte} :    // LB
        (ex_mem_funct3 == 3'b001) ? {{16{ld_fwd_half[15]}}, ld_fwd_half} :   // LH
        (ex_mem_funct3 == 3'b100) ? {24'd0, ld_fwd_byte} :                   // LBU
        (ex_mem_funct3 == 3'b101) ? {16'd0, ld_fwd_half} :                   // LHU
        ld_early_data;                                                       // LW

    wire        ld_fwd_en = (EARLY_LD != 0) && ex_mem_ld_fast && (ex_mem_rd != 5'd0);
    wire        ld_fwd_a  = ld_fwd_en && (ex_mem_rd == id_ex_rs1);
    wire        ld_fwd_b  = ld_fwd_en && (ex_mem_rd == id_ex_rs2);
    wire        ld_fwd_ba = ld_fwd_en && (ex_mem_rd == id_ex_b_rs1);
    wire        ld_fwd_bb = ld_fwd_en && (ex_mem_rd == id_ex_b_rs2);

    // lane A 操作数 1（id_ex_rs1）
    wire fwd_a_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_rs1);
    wire fwd_a_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                     (ex_mem_rd == id_ex_rs1) && (ex_mem_wb_sel != 2'b01);
    wire fwd_a_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_rs1);
    wire fwd_a_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1);
    // lane A 操作数 2（id_ex_rs2）
    wire fwd_b_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_rs2);
    wire fwd_b_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                     (ex_mem_rd == id_ex_rs2) && (ex_mem_wb_sel != 2'b01);
    wire fwd_b_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_rs2);
    wire fwd_b_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2);

    wire [31:0] rs1_val = ld_fwd_a  ? ld_early_val :           // [任务 C] 快通路 load
                          fwd_a_exb ? ex_mem_forward_val_b :
                          fwd_a_ex  ? ex_mem_forward_val :
                          fwd_a_wbb ? wb_data_b :
                          fwd_a_wb  ? wb_data : id_ex_rdata1;
    wire [31:0] rs2_val = ld_fwd_b  ? ld_early_val :           // [任务 C] 快通路 load
                          fwd_b_exb ? ex_mem_forward_val_b :
                          fwd_b_ex  ? ex_mem_forward_val :
                          fwd_b_wbb ? wb_data_b :
                          fwd_b_wb  ? wb_data : id_ex_rdata2;

    // ================= [A 扩展] AMO 单元 =================
    // 地址来自【前递后的 rs1】（AMO/LR/SC 都是rs1，不是 rs1+imm）。
    // rs2 同样取前递值 —— 见下面 rs2_val_amo 的说明。
    wire [31:0] rs1_val_amo = fwd_a_exb ? ex_mem_forward_val_b :
                              fwd_a_ex  ? ex_mem_forward_val :
                              fwd_a_wbb ? wb_data_b :
                              fwd_a_wb  ? wb_data : id_ex_rdata1;

    // [!] rs2 必须走与 rs1 同一套前递网。本文件已有两套前递：
    //   `rs1_val/rs2_val` 给 lane A，`rs1_val_b/rs2_val_b` 给 lane B。
    //   AMO 只会出现在 lane A（pair_now 排除了它），所以这里复用 lane A 那套 ——
    //   但不能直接用 id_ex_rdata2，必须是【前递后】的值。
    wire [31:0] rs2_val_amo = fwd_b_exb ? ex_mem_forward_val_b :
                              fwd_b_ex  ? ex_mem_forward_val :
                              fwd_b_wbb ? wb_data_b :
                              fwd_b_wb  ? wb_data : id_ex_rdata2;


    // [重点] store_commit 的含义：任何【会改内存】的指令落到 MEM 时拉高，
    //   用来让 LR 的预约失效（规格要求）。AMO 自己的写在 amo_unit 内部处理，
    //   所以这里只送普通 store —— 也就是 ex_mem_mem_write。
    amo_unit u_amo (
        .clk(clk), .resetn(resetn),
        .start(ex_mem_is_amo),
        .addr(ex_mem_amo_addr),
        // [A 扩展] rs2 复用 ex_mem_wdata —— EX/MEM 那条 `ex_mem_wdata <= rs2_val`
        //   存的本来就是【前递后】的 rs2。原来接在一个从未被赋值的
        //   ex_mem_amo_rs2 上 ⇒ amo_wdata 恒 xxxxxxxx（写进内存的是垃圾）。
        .rs2_val(ex_mem_wdata),
        .funct5(ex_mem_amo_funct5),
        .funct3(ex_mem_funct3[1:0]),
        .mem_rdata(mem_rdata),
        .amo_mem_re(amo_mem_re),
        .amo_mem_we(amo_mem_we),
        .amo_byte_en(amo_byte_en),
        .amo_wdata(amo_wdata),
        .amo_stall(amo_stall),
        .mem_release(amo_mem_release),
        .wb_data(amo_wb_data),
        .illegal(amo_illegal),
        // [A 扩展] AMO 的写也要让 LR 预约失效（规格要求"任何写别的地址"）。
        //   amo_mem_we 只在 ST_WRITE 高 1 拍，且 amo_unit 内部已对"写自己的预约
        //   地址"那一拍做了排除，所以并进来是安全的。
        .store_commit(ex_mem_mem_write | amo_mem_we)
    );

    // [A 扩展] "AMO 占住 MEM 级"：从进 EX/MEM 起，直到状态机走到写回拍
    //   （mem_release）为止，把 mem_ready 压成 0 ⇒ EX/MEM / MEM/WB / IF/ID / ID/EX
    //   全部【保持】不动，AMO 独占访存口 4 拍。放开那拍 EX/MEM 恰好推进到 MEM/WB，
    //   不早不晚。
    assign amo_hold      = ex_mem_is_amo && !amo_mem_release;
    assign mem_ready_int = mem_ready && !amo_hold;

    wire [31:0] alu_a = id_ex_alu_a_sel ? id_ex_pc  : rs1_val;
    wire [31:0] alu_b = id_ex_alu_b_sel ? id_ex_imm : rs2_val;
    wire [31:0] alu_raw;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(id_ex_alu_op), .result(alu_raw));

    // ---- lane B 的 EX：只有 ALU ----
    // lane B 操作数 1（id_ex_b_rs1）
    wire fwd_ba_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_b_rs1);
    wire fwd_ba_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                      (ex_mem_rd == id_ex_b_rs1) && (ex_mem_wb_sel != 2'b01);
    wire fwd_ba_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_b_rs1);
    wire fwd_ba_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_b_rs1);
    // lane B 操作数 2（id_ex_b_rs2）
    wire fwd_bb_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_b_rs2);
    wire fwd_bb_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                      (ex_mem_rd == id_ex_b_rs2) && (ex_mem_wb_sel != 2'b01);
    wire fwd_bb_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_b_rs2);
    wire fwd_bb_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_b_rs2);

    wire [31:0] rs1_val_b = ld_fwd_ba ? ld_early_val :         // [任务 C] 快通路 load
                            fwd_ba_exb ? ex_mem_forward_val_b :
                            fwd_ba_ex  ? ex_mem_forward_val :
                            fwd_ba_wbb ? wb_data_b :
                            fwd_ba_wb  ? wb_data : id_ex_b_rdata1;
    wire [31:0] rs2_val_b = ld_fwd_bb ? ld_early_val :         // [任务 C] 快通路 load
                            fwd_bb_exb ? ex_mem_forward_val_b :
                            fwd_bb_ex  ? ex_mem_forward_val :
                            fwd_bb_wbb ? wb_data_b :
                            fwd_bb_wb  ? wb_data : id_ex_b_rdata2;

    wire [31:0] b_alu_a = id_ex_b_alu_a_sel ? id_ex_b_pc  : rs1_val_b;
    wire [31:0] b_alu_b = id_ex_b_alu_b_sel ? id_ex_b_imm : rs2_val_b;
    wire [31:0] alu_result_b;
    alu u_alu_b (.a(b_alu_a), .b(b_alu_b), .alu_op(id_ex_b_alu_op), .result(alu_result_b));

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

    // ---- 多拍乘法：MUL/MULH/MULHSU/MULHU 由两拍乘法器接管 ----
    // [重点] 为什么必须摘出来：综合报告显示单拍组合乘法占关键路径 10.05 ns
    //   （整条数据通路的 56%），而且路径起点是 BRAM —— 即 "lw 紧跟 mul" 时，
    //   访存数据从 BRAM 出来要在一个周期内穿过解包、前递、再走完 4 级 APM 乘法链。
    //   摘出来单独占两拍后，那 10 ns 就不在关键路径上了。
    //   代价是每条 mul 多 1 拍。实测 CoreMark 每迭代执行 **9,396 条 mul**
    //   （+PROF 的 c_mul；注意不能用静态推算，会小 5.8 倍），
    //   即区间周期 354,119 → 363,515（+2.65%）。
    //   详见 rtl/core/multiplier.v 头注释。
    wire id_ex_is_mul = (id_ex_alu_op >= 5'd10) && (id_ex_alu_op <= 5'd13);
    wire mul_start    = id_ex_is_mul && !mul_busy;
    // alu_op 10/11/12/13 → op 0/1/2/3（MUL/MULH/MULHSU/MULHU）
    wire [1:0] mul_op = id_ex_alu_op[1:0] - 2'd2;
    multiplier u_multiplier (
        .clk(clk), .resetn(resetn),
        .start(mul_start),
        .a(alu_a), .b(alu_b),
        .op(mul_op),
        .result(mul_result),
        .busy(mul_busy),
        .done(mul_done)
    );
    // ------------------------------------------------------------------
    // EX 结果四选一：CSR 读 > 多拍除法 > 多拍乘法 > ALU
    //   * CSR 读值【骑在这里】才能白拿前递与写回通路 —— 对下游而言它就是
    //     "EX 算出来的结果"，不需要任何额外旁路。
    //   * 多拍单元的结果同理骑在这里：它们在 done 那一拍给出组合输出，
    //     所以对前递网络和 EX/MEM 而言与"单拍 ALU 结果"没有区别。
    //   * [!] 绝不能用 `alu_op >= 14` 去编码 CSR 读 —— 那会撞上下面的
    //     `id_ex_is_div`，误触发除法停顿 → mc_stall 永不释放 → 死锁。
    //     所以 CSR 用**独立的** id_ex_is_csr 标志，alu_op 保持 0。
    //   * [!] `id_ex_is_mul` 判的是 10..13，与 14..17 的除法**不重叠**，
    //     两者也互斥（同一条指令不可能既是 mul 又是 div）。
    // ------------------------------------------------------------------
    wire [31:0] alu_result = id_ex_is_csr ? csr_rdata :
                             id_ex_is_div ? div_result :
                             id_ex_is_mul ? mul_result : alu_raw;
    // 访存地址 = base + offset，恒为 ADD（load/store 的 alu_op 固定为 0，
    // 见 control.v 的 OP_LOAD / OP_STORE —— 它们不写 alu_op，保持 default 的 0）。
    // 单独用一个加法器产生地址，把 32×32 乘法器从
    // "未对齐判据 → 异常 → pc_r 写使能" 这条【假路径】上切下来：
    // mul 指令从不访存，乘法结果根本不该出现在 pc_r 的时序弧里。
    // [!] 只用于未对齐判据与 mtval，不改变任何流水线语义（见 §关键路径）。
    wire [31:0] addr_result = alu_a + alu_b;
    assign      div_stall  = id_ex_is_div && !div_done;
    assign      mul_stall  = id_ex_is_mul && !mul_done;
    // 前端冻结判据只有这一根 —— 理由见文件顶部声明处的 [!]。
    // [A 扩展] AMO 是唯一的例外：它是【MEM 级】多拍单元，不能并进 mc_stall ——
    //   mc_stall 把 EX/MEM 清成气泡，而跑状态机的正是 EX/MEM 里那条 AMO。
    //   它改走 amo_hold / mem_ready_int（保持语义），见 amo_unit 例化处。
    assign      mc_stall   = div_stall || mul_stall;

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
    //   !mc_stall   —— 护住多拍除法器/乘法器，避免残留状态/陈旧结果
    //   !amo_hold   —— 同理护住 AMO：中断若在其读-改-写中途受理，EX/MEM 会被
    //                  清 ⇒ AMO 的 rd 写回丢失（内存写仍会落下，但寄存器错）。
    //                  中断是电平信号，AMO 放开后自然重来，不会丢事件。
    //   !id_ex_mret —— 抑制"打断 mret"的嵌套角落
    // 同步异常无需门控：肇事指令下一拍已被清成气泡，ex_exception 自然为 0；
    // 而气泡的 id_ex_illegal/ecall/ebreak/mem_read 全为 0，也判不出异常。
    assign int_take = csr_mstatus_mie && int_pending && id_ex_valid &&
                      !mc_stall && !amo_hold && !id_ex_mret;

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
        if (ex_mem_is_amo) begin
            // [A 扩展] AMO 占 MEM：写数据来自 amo_unit 的"旧值 ⊕ rs2"结果
            //   （SC 则是要存的 rs2）。不 mux 的话总线上永远只有 ex_mem_wdata。
            mem_wdata = amo_wdata;
        end else begin
            case (ex_mem_funct3)
                3'b000: mem_wdata = {4{ex_mem_wdata[7:0]}};    // SB
                3'b001: mem_wdata = {2{ex_mem_wdata[15:0]}};   // SH
                default: mem_wdata = ex_mem_wdata;             // SW
            endcase
        end
    end

    always @(*) begin
        if (ex_mem_is_amo) begin
            // [A 扩展] AMO 恒整字访问：使能由 amo_unit 给（只有写回拍是 1111）
            mem_byte_en = amo_byte_en;
        end else begin
            case (ex_mem_funct3)
                3'b000: mem_byte_en = 4'b0001 << ex_mem_alu_result[1:0]; // SB
                3'b001: mem_byte_en = 4'b0011 << ex_mem_alu_result[1:0]; // SH
                3'b010: mem_byte_en = 4'b1111;                           // SW
                default: mem_byte_en = 4'b0000;
            endcase
        end
    end

    // ================= MEM/WB =================
    // （级间寄存器声明已提前到文件顶部，避免 forward reference）

    // ================= WB =================
    // mem_rdata 由 mem_bus 在 MEM→WB 沿给出（RAM / 兼容区 / 外设区一律 1 拍
    // 延迟，无特例），load 指令进入 WB 阶段时正好有效。
    //
    // [A.0 修复] 但 mem_rdata 是【实时】的，只在"WB 恰好一拍"时才对：
    //   mem_ready=0 会把 MEM/WB 冻住（见文件尾），同一条 load 于是在 WB 里滞留
    //   多拍。第二拍起 mem_rdata 已经跟到 MEM 级【更年轻那条】指令的地址上，
    //   写回值 wb_data 与 WB→EX 前递值一起被改错 —— MEMWAIT=0 时看不出来
    //   （永不冻结），+MEMWAIT 下每对相邻访存就炸一次。
    //   所以停顿的第一个沿把当时（仍属于本条 load）的读数据抓进快照、之后一直
    //   用它。mem_ready_int=1 时快照恒不生效 ⇒ MEMWAIT=0 逐位不变。
    reg [31:0] wb_rdata_snap;
    reg        wb_rdata_snap_en;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            wb_rdata_snap    <= 32'd0;
            wb_rdata_snap_en <= 1'b0;
        end else if (mem_ready_int) begin
            wb_rdata_snap_en <= 1'b0;          // WB 正常推进：下条指令用实时 mem_rdata
        end else if (!wb_rdata_snap_en) begin  // 停顿第一个沿：抓一次（此后 mem_rdata 已失效）
            wb_rdata_snap    <= mem_rdata;
            wb_rdata_snap_en <= 1'b1;
        end
    end
    // [任务 C] 快通路 load 的原始字来自 MEM/WB 里寄存的那一份（见 MEM/WB 段），
    //   旧通路仍用实时 mem_rdata（含 A.0 的冻结快照）。
    wire [31:0] load_src = mem_wb_ld_fast ? mem_wb_ld_raw :
                           (wb_rdata_snap_en ? wb_rdata_snap : mem_rdata);
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

    // [A 扩展] AMO 的写回值来自 amo_unit（AMO/LR = 读回旧值，SC = 成功标志）。
    //   它在 MEM 级多拍才产生，所以不进 MEM/WB 寄存器，直接在 WB 级取。
    assign wb_data = mem_wb_is_amo      ? amo_wb_data :
                     (mem_wb_wb_sel == 2'b01) ? load_data :
                     (mem_wb_wb_sel == 2'b10) ? (mem_wb_pc + 32'd4) :
                     (mem_wb_wb_sel == 2'b11) ? mem_wb_imm :
                     mem_wb_alu_result;

    // lane B 写回数据：无 load 分支（wb_sel=01 对 lane B 不可能）
    assign wb_data_b = (mem_wb_b_wb_sel == 2'b10) ? (mem_wb_b_pc + 32'd4) :
                       (mem_wb_b_wb_sel == 2'b11) ? mem_wb_b_imm :
                       mem_wb_b_alu_result;

    // ================= PC =================
    // 同步读 BRAM 使取指有 2 拍延迟，【无跳转的稳态】不变量：
    //     imem_rd   = mem[pc_r-4]   （在途，下一拍进 IF/ID）
    //     if_id_pc  = pc_r-8        （正在 ID 译码）
    //     id_ex_pc  = pc_r-12       （正在 EX 执行）
    // 跳转那一拍 fetch_addr 被旁路，此后 pc_r 与"已发出的地址"相差 4。
    //
    // stall / mc_stall 时：pc_r 与 if_addr_d 都【保持不动】，同时上面
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
        else if (p_redirect)
            pc_r <= p_target + 32'd4;
        // [!] mem_ready 也要或进来：访存没完成时 pc_r 必须停住，
        //     否则取指会跑到前面去、把停在 MEM 的那条指令的后续全冲掉。
        // [双发射] 配对时一步跨两条（+8）。pc_r 现在只作 pc 输出/调试用，
        //   取指实际源头是 if_addr_d（见 fetch_addr）。
        else if (!stall_int && !mc_stall && mem_ready_int)
            pc_r <= pc_r + (pair_now ? 32'd8 : 32'd4);
    end

    // ================= IF/ID 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013;
            if_id_valid <= 1'b0;
            if_id_pc_b    <= 32'd0;
            if_id_instr_b <= 32'h00000013;
            if_id_pair    <= 1'b0;
            if_id_pred_taken <= 1'b0;
        end else if (ex_flush || ex_mispred || trap) begin
            // 三条都只清【一拍】：重定向那一拍 fetch_addr 已经把新地址发出去了，
            // 目标指令的数据下一拍就回来，多清一拍反而会把它杀掉。
            // （原 ex_flush_d 的第二拍冲刷已随地址旁路一并移除。）
            //
            //   ex_flush   杀掉跳转前那次读（旧路）
            //   ex_mispred 杀掉预测路径上取回的错误指令
            //
            // [阶段1] p_redirect（到达级预测重定向）【不】清 IF/ID —— 它重定向时
            //   fall-through 那一次取指根本没发出去（fetch_addr 当拍就指向目标），
            //   IF/ID 里躺着的是更早的正确指令，不能清。
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013;
            if_id_valid <= 1'b0;          // 冲刷插入的是气泡，不是真指令
            if_id_pc_b    <= 32'd0;
            if_id_instr_b <= 32'h00000013;
            if_id_pair    <= 1'b0;
            if_id_pred_taken <= 1'b0;
        end else if (!stall_int && !mc_stall && mem_ready_int) begin
            if_id_valid <= (imem_rd != 32'd0);
            if_id_pc    <= if_addr_d;
            if_id_instr <= imem_rd;
            // lane B 与 lane A 同拍锁存，pc 恒为 lane A 的 +4（A2 口取的就是这个字）
            // pair_now 就是这一对 (imem_rd, imem_rd2) 的发射判定 —— 同拍寄存。
            if_id_pair    <= pair_now;
            if_id_pred_taken <= p_redirect;
            if_id_pc_b    <= if_addr_d + 32'd4;
            if_id_instr_b <= imem_rd2;
        end
        // [!] 注意这里是"三者都不成立就【保持】"，不是清 ——
        //     访存停顿（mem_ready=0）属于这一类：停住不动，不清成气泡。
    end

    // ==================================================================
    // [TASK-C 探针] 假 AGU —— 只为【综合量时序】，默认关（任务书 v7 §5.C 的判据）
    // ------------------------------------------------------------------
    // 任务 C（消除 load-use 停顿）要把访存地址计算提前到 ID 级。这里插一条
    // 【结构等价】的路径量它值多少 ns：
    //     ID 级寄存器堆读 → 前递 mux → 32 位加法器 → ID/EX 寄存器
    // 也就是"把 EX 里那个 ALU 加法器整体往前搬一级"。
    //
    // [!] 必须用【真实信号】喂，否则综合器会把整块当冗余删掉，得到假的"零影响"
    //     结论（A.1 假 tag 探针的教训，见 doc/reports/2026-10-11_A1_cache_tag_probe.md）。
    //     这里 rs1 取 rdata1（寄存器堆输出）与前递值做 2:1 mux，imm 取真实立即数，
    //     选择端用真实的 ex_mem_reg_write —— 都消不掉。
    // [!] AGU_PROBE=1 时 agu_probe 的值无功能意义（不上板、不跑分）；
    //     =0 时恒 0、综合后无任何逻辑。
    // ==================================================================
    generate
    if (AGU_PROBE != 0) begin : g_agu_probe
        wire [31:0] agu_rs1 = ex_mem_reg_write ? ex_mem_forward_val : rdata1;
        reg  [31:0] agu_r;
        always @(posedge clk or negedge resetn) begin
            if (!resetn) agu_r <= 32'd0;
            else         agu_r <= agu_rs1 + imm;
        end
        assign agu_probe = agu_r;
    end else begin : g_no_agu_probe
        assign agu_probe = 32'd0;
    end
    endgenerate

    // ================= ID/EX 寄存器 =================
    always @(posedge clk or negedge resetn) begin
        if (!resetn || ex_flush || ex_mispred || stall_int || trap) begin
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
            id_ex_is_amo     <= 1'b0;
            id_ex_amo_funct5 <= 5'd0;
            id_ex_illegal   <= 1'b0;
            id_ex_sys_ecall <= 1'b0;
            id_ex_mret      <= 1'b0;
            id_ex_valid     <= 1'b0;
            // [任务 C]
            id_ex_ld_fast   <= 1'b0;
            id_ex_ld_addr   <= 32'd0;
            // lane B 一并清成气泡（pair_now=0 时本来就该是气泡）
            id_ex_b_reg_write <= 1'b0;
            id_ex_b_alu_a_sel <= 1'b0;
            id_ex_b_alu_b_sel <= 1'b0;
            id_ex_b_alu_op    <= 5'd0;
            id_ex_b_wb_sel    <= 2'b00;
            id_ex_b_pc        <= 32'd0;
            id_ex_b_rdata1    <= 32'd0;
            id_ex_b_rdata2    <= 32'd0;
            id_ex_b_imm       <= 32'd0;
            id_ex_b_rd        <= 5'd0;
            id_ex_b_rs1       <= 5'd0;
            id_ex_b_rs2       <= 5'd0;
            id_ex_b_valid     <= 1'b0;
        // [!] mem_ready=0 时和 mc_stall 一样【保持】：停在 MEM 的那条指令
        //     还在 ID/EX 的下游，这里必须冻住，不能推进也不能清。
        end else if (!mc_stall && mem_ready_int) begin
            id_ex_reg_write <= reg_write;
            id_ex_alu_a_sel <= alu_a_sel;
            id_ex_alu_b_sel <= alu_b_sel;
            id_ex_mem_read  <= mem_read;
            id_ex_mem_write <= mem_write;
            id_ex_branch    <= branch;
            id_ex_jump      <= jump;
            id_ex_jump_reg  <= jump_reg;
            // 必须寄存【实际生效的重定向】p_redirect（经 if_id_pred_taken 传下来），
            // 而不是预测意图 p_pred_taken —— 两者在有 stall / ex_flush / mc_stall
            // 时会分叉（那三种情况 p_redirect 被抑制，但 p_pred_taken 仍为 1）。
            // 若寄存错了，会出现"记着预测过、但 pc_r 根本没重定向"的状态，
            // EX 级据此判定预测正确而不冲刷，流水线就沿错误路径一路跑下去。
            id_ex_pred_taken <= if_id_pred_taken;
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
            id_ex_is_amo     <= id_is_amo;
            id_ex_amo_funct5 <= id_amo_funct5;
            id_ex_illegal   <= id_illegal;
            id_ex_sys_ecall <= sys_ecall;
            id_ex_mret      <= sys_mret;
            // [任务 C] 这条 load 能否走快通路 + 它在 ID 级算好的地址
            id_ex_ld_fast   <= ld_fast;
            id_ex_ld_addr   <= ld_id_addr;
            // 跟随 IF/ID 的实际内容：冲刷/填充期的气泡不能算有效，
            // 否则中断会拿气泡的 id_ex_pc(=0) 去写 mepc
            id_ex_valid     <= if_id_valid;
            // ---- lane B ----
            // if_id_pair（随 IF/ID 一起寄存的发射判定）才把 lane B 收进 ID/EX；
            // 否则恒气泡。用 if_id_pair 而非当拍 pair_now：后者属于更年轻的一组取指。
            id_ex_b_valid     <= if_id_pair;
            id_ex_b_reg_write <= if_id_pair ? reg_write_b : 1'b0;
            id_ex_b_alu_a_sel <= if_id_pair ? alu_a_sel_b : 1'b0;
            id_ex_b_alu_b_sel <= if_id_pair ? alu_b_sel_b : 1'b0;
            id_ex_b_alu_op    <= if_id_pair ? alu_op_b    : 5'd0;
            id_ex_b_wb_sel    <= if_id_pair ? wb_sel_b    : 2'b00;
            id_ex_b_pc        <= if_id_pc_b;
            id_ex_b_rdata1    <= rdata1_b;
            id_ex_b_rdata2    <= rdata2_b;
            id_ex_b_imm       <= imm_b;
            id_ex_b_rd        <= rd_b;
            id_ex_b_rs1       <= rs1_b;
            id_ex_b_rs2       <= rs2_b;
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
        // [!] AMO 占 MEM 期间必须【保持】EX/MEM —— 跑状态机的就是它，
        //     清掉它 = 读-改-写被拦腰截断（trap/mc_stall 同理一律压住）。
        // [A.0 修复] 还必须门控 mem_ready_int：访存停顿（EX/MEM 里是一条尚未
        //     完成的 load/store）与 EX 级 mc_stall（mul/div 多拍）可以【同时】成立
        //     —— 前一条是访存、紧邻一条是 mul/div 时就会撞上。若此时仍按 mc_stall
        //     把 EX/MEM 清成气泡，停在 MEM 的那条访存就【永久丢失】其寄存器写/内存写。
        //     实测：+MEMWAIT=1 下 matrix_test 内层的 lh 紧邻 mul，lh 写回被吃、
        //     后续 mul 拿错操作数，matrix CRC 全错。
        //     mem_ready_int=0 时整条流水线冻结、任何平移都不能发生，故清 EX/MEM
        //     也必须一起压住。对 trap 同样安全：那拍 ID/EX 已被 trap 清空，
        //     放开后 EX/MEM <= 气泡，效果与当场清等价；而更老的访存得以正常退休。
        if (!resetn || ((mc_stall || trap) && !amo_hold && mem_ready_int)) begin
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
            // [A 扩展] 清 AMO 标志
            ex_mem_is_amo     <= 1'b0;
            ex_mem_amo_funct5 <= 5'd0;
            ex_mem_amo_addr   <= 32'd0;
            // [任务 C]
            ex_mem_ld_fast    <= 1'b0;
            // lane B（trap/mc_stall 一并清）
            ex_mem_b_reg_write  <= 1'b0;
            ex_mem_b_valid      <= 1'b0;
            ex_mem_b_wb_sel     <= 2'b00;
            ex_mem_b_alu_result <= 32'd0;
            ex_mem_b_pc         <= 32'd0;
            ex_mem_b_imm        <= 32'd0;
            ex_mem_b_rd         <= 5'd0;
        // [!] mem_ready=0 时必须【保持】EX/MEM —— 这一处不能省，实测踩过：
        //     冻结和"EX/MEM <= ID/EX"是【同一个沿】发生的，而那一拍的 ID/EX 里
        //     已经是【下一条】指令了。不门控的话，没完成的 store 会被下一条覆盖，
        //     于是这次写【永久丢失】，还会伴随 mem_addr 变成下一条的垃圾地址
        //     （实测出现过 0x00000000，会砸掉 _start）。
        //
        //     2026-09-27 实测：漏了这里时 +MEMWAIT=2 下 RT-Thread 卡在启动，
        //     pc 停在 0x2c 的 jalr；逐拍 trace 显示 store 的 mem_we 只高 1 拍就
        //     被换掉、地址从 0x5748 跳到 0x574c。
        end else if (mem_ready_int) begin
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
            // ---- [A 扩展] ----
            // [!] 地址用【前递后的 rs1】。AMO 的地址语义就是 rs1（不是 rs1+imm），
            //   所以不能用 ex_mem_alu_result（那是 rs1+imm 的和）。
            ex_mem_is_amo     <= id_ex_is_amo;
            ex_mem_amo_funct5 <= id_ex_amo_funct5;
            ex_mem_amo_addr   <= rs1_val_amo;
            // [任务 C]
            ex_mem_ld_fast    <= id_ex_ld_fast;
            // rs2 不单独存 —— ex_mem_wdata<= rs2_val 已经是前递后的值，AMO 直接复用。
            // ---- lane B ----
            // [!] `&& !ex_flush` 是承重的：ex_flush 那拍 lane A（跳转）与其同拍
            //     lane B 一起躺在 ID/EX 里，而 EX/MEM <= ID/EX 是同一个沿发生的。
            //     lane B 是【更年轻】的那条、【更不会】走错的路径上的写寄存器指令
            //     （jalr、或预测 not-taken 实际 taken 的分支后的那条）。不抑制它
            //     就会漏写一次寄存器 —— 静默错算。lane A 本身不写（分支/跳转的
            //     reg_write=0），所以只需压 lane B。
            ex_mem_b_reg_write  <= id_ex_b_reg_write && !ex_flush;
            ex_mem_b_valid      <= id_ex_b_valid && !ex_flush;
            ex_mem_b_wb_sel     <= id_ex_b_wb_sel;
            ex_mem_b_alu_result <= alu_result_b;
            ex_mem_b_pc         <= id_ex_b_pc;
            ex_mem_b_imm        <= id_ex_b_imm;
            ex_mem_b_rd         <= id_ex_b_rd;
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
            mem_wb_is_amo     <= 1'b0;
            mem_wb_addr_low   <= 2'd0;
            // [任务 C]
            mem_wb_ld_fast    <= 1'b0;
            mem_wb_ld_raw     <= 32'd0;
            mem_wb_b_reg_write  <= 1'b0;
            mem_wb_b_wb_sel     <= 2'b00;
            mem_wb_b_alu_result <= 32'd0;
            mem_wb_b_pc         <= 32'd0;
            mem_wb_b_imm        <= 32'd0;
            mem_wb_b_rd         <= 5'd0;
        end else if (mem_ready_int) begin
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_wb_sel     <= ex_mem_wb_sel;
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_pc         <= ex_mem_pc;
            mem_wb_imm        <= ex_mem_imm;
            mem_wb_rd         <= ex_mem_rd;
            mem_wb_funct3     <= ex_mem_funct3;
            mem_wb_is_amo     <= ex_mem_is_amo;
            mem_wb_addr_low   <= ex_mem_alu_result[1:0];
            // [任务 C] 快通路 load 的原始字：它【在 MEM 级】就已经在 ld_early_data 上
            //   （旧通路那条 load 要等 WB 级的实时 mem_rdata），所以必须在这里寄存。
            //   [A.0 同类] 加 mem_ready_int 之外不用再做快照 —— ld_snap 已经承担了。
            mem_wb_ld_fast    <= ex_mem_ld_fast;
            mem_wb_ld_raw     <= ld_early_data;
            mem_wb_b_reg_write  <= ex_mem_b_reg_write;
            mem_wb_b_wb_sel     <= ex_mem_b_wb_sel;
            mem_wb_b_alu_result <= ex_mem_b_alu_result;
            mem_wb_b_pc         <= ex_mem_b_pc;
            mem_wb_b_imm        <= ex_mem_b_imm;
            mem_wb_b_rd         <= ex_mem_b_rd;
        end
    end

    // [!] 上面 MEM/WB 那处是 mem_ready=0 时唯一【必须】门控的地方：
    //     不门控的话，被停住的那条 load 会带着还没回来的 mem_rdata 提前写回。
    //     EX/MEM 走的是 mem_ready_int：常态下与 mem_ready 逐位相同，只在 AMO
    //     占 MEM 期间多出一个 0 —— 那时它必须【保持】AMO，绝不能推进成气泡。

endmodule
