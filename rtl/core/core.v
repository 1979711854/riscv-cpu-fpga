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
    parameter EARLY_LD = 0,

    // ---- [B1-BTB] 分支目标缓冲（赛题点名项）----
    // 1 = 开；0 = 关（逐位回退成 RAS-only 的行为）。
    // 只预测【间接跳转 jalr】的目标（条件分支/jal 的目标 PC+imm 由 p_target 现算已正确）。
    // 为什么给开关：BTB 要新增一条"PC 索引的表读"进取指路径，可能吃时序余量；
    //   若综合后 CPU 域 WNS 变负、或收益为负，就把它默认关掉（v10 §6.5）。
    parameter BTB_EN = 1,

    // ---- [面积优化] A 扩展（RV32A：AMO / LR / SC）----
    // 0 = 关（**默认**）：opcode `0101111` 判为非法指令，`amo_unit` 整个不例化、
    //     连同配套的 mux/前递门控一起被综合裁掉。
    //     依据（2026-10-15 决策）：赛题公式 Score = Iterations/(Total_Time×Frequency)
    //     = CoreMark/MHz ⇒ **主频与面积不进主分**，而面积进指标(3) CoreMark/LUTs。
    //     两个交付固件都不含原子指令（CoreMark 用 `-march=rv32im_zicsr`，编译器发不出；
    //     RT-Thread 档实测 ELF 里 0 条，原子走软实现）⇒ 关掉对分数**零影响**，纯省面积。
    // 1 = 开：逐位回到原行为。`sim/tb_amo_int.v`（A 扩展的整核测试）必须显式传 1。
    parameter A_EXT = 0,

    // ---- [lane B 访存] lane B 放 load（任务书方案 A：只放 load，不放 store）----
    // **1 = 开（默认，2026-10-16 P3 翻转）**：lane B 可放 load，且【顺带收窄
    //      pair_now 的 M 扩展排除】（p_f7_b 只对 OP_REG 生效，见 pair_now 处说明）。
    //      PDS/上板本参数走默认值（cpu_top 不传）⇒ 交付位流即 1 档；仿真侧另有
    //      `-DLANEBMEM` 显式开关（tb 用 localparam 覆盖），保留 0/1 两档对照能力。
    // 0 = 关（P2 阶段值，仅作回退/对照）：行为与"lane B 只放纯 ALU"【逐位相同】——
    //      流水线寄存器、访存口 mux 腿、前递门控全部"接线在位但不可达"，
    //      id_ex_b_mem_read 恒 0 ⇒ b_mem_sel / load-use 停顿 / 未对齐异常 /
    //      WB 解包全部折叠回基线行为（判据 = 四条 CoreMark 基线逐位不变）。
    // [!] lane B 的 load 一律走【旧通路】（慢路径），永不使用 EARLY_LD 快通路 ——
    //     收益全部来自配对率，不为它加第二根 ld_addr / 第二份 ld_snap / 第 4 份
    //     阵列（任务书 §3；快通路本身收益为 0 却全落在最贵的时序链上）。
    // [!] 本参数同时是 2026-10-16 那 7 处**时序门控**的判据：0 档综合器把
    //     lane B 的访存消费者整条常量折叠（恢复 rev1023 网表），1 档语义不变。
    // [!] **1 档的 PDS 实测（2026-10-16 P3）：CPU 域 WNS −0.701 ns / Fmax 80.22 MHz
    //     @85.0051 MHz ⇒ 85 MHz 生产档过不了 P4 时序闸门**。关键路径是
    //     video palette DRAM → lane B load 解包(wb_data_b) → lane B ALU(alu_result_b)
    //     → load_misaligned_b → if_addr_d → imem_addr（16 级）——
    //     即 P2 任务书预警过的"alu_result_b 锥并进取指 mux"，1 档下它是活逻辑、
    //     门控折叠不掉。**在摘掉这条腿（P3.5）之前，别用本默认值出 85 MHz 交付位流**；
    //     交付仍是 rev1023 的 `55fae69e`（0 档口径）。
    parameter LANEB_MEM = 1
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
    output wire [14:0] ld_addr,       // word 索引（15 位 = 32768 word = 128KB）
    input  wire [31:0] ld_rdata,      // 同步读 1 拍延迟

    // ---- 取指口（A1 口）----
    // 契约：同步读、恰好 1 拍延迟（第 T 拍给地址 → 第 T+1 拍出数据）、只读、
    // 且【不做任何仲裁/冲突检测】。本模块的 stall/flush 补偿逻辑依赖 A 口
    // 每拍都能独立工作，加仲裁会直接破坏取指时序。
    output wire [14:0] imem_addr,     // word 索引；注意是 stall mux 之后的值（128KB = 32768 word）
    input  wire [31:0] imem_rd,       // 同步读 1 拍延迟
    // ---- 取指口（A2 口，双发射第二读口）----
    // 与 A1 同拍、同延迟，读 unified_mem 的复制阵列。DUAL_ISSUE=0 时被丢弃。
    // [!] 宽度必须与 imem_addr **一致**（15 位 = 32768 word = 128KB）。
    //     2026-10-10 实查：存储器扩到 64KB 时漏了这里，它还是 32KB 时代的
    //     13 位，而 `imem_addr + 1` 是在 14 位宽里算的 → **赋给 13 位线时丢掉
    //     最高位** → imem_addr2 在 8192 word（字节 0x8000）处回绕。
    //     后果：取指地址 ≥ 0x8000 时 lane B 从低 32KB 取错地方
    //     （pair_now 判据用的就是 imem_rd2），会执行错指令。
    //     当时没炸只是因为没有程序的代码大过 32KB —— 而扩容的全部意义就是
    //     让代码能大过它。别再把这两根线的宽度写成不一样的。
    output wire [14:0] imem_addr2,
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
    // [P3a] lane B 放 JAL：`fetch_addr`（下面几十行）就要消费它们，故先声明后赋值。
    wire        p_jal_b;
    wire [31:0] p_imm_b;          // lane B 的立即数（到达级 imm_gen 的输出）
    wire [31:0] p_jal_target_b;   // = (if_addr_d+4) + imm_B

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
    // [B1-RAS / v10 §7] 该指令被预测时所用的【目标地址】。仅当 id_ex_pred_taken=1 时有意义，
    //   用于 EX 级校验"预测目标是否正确"：RAS 预测 ret 目标一旦错（栈顶不是真正链接值），
    //   靠它冲刷纠正；对 branch/jal 它恒等于 ex_target（同一个 pc+imm）⇒ 不改变原行为。
    reg [31:0] id_ex_pred_target;
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
    // [A1] mul 判据必须【声明在前】—— 下面 ID 段的 stall 要用它，而 stall 比
    //   EX 段的乘法器例化早得多。iverilog 14 严格"先声明后使用"（约定 1）。
    //   alu_op 10..13 → MUL/MULH/MULHSU/MULHU；与 14..17 的除法不重叠。
    wire       id_ex_is_mul = (id_ex_alu_op >= 5'd10) && (id_ex_alu_op <= 5'd13);
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
    // [A1] 本条是 mul —— 结果 2 拍后才由流水线乘法器给出，WB 级据此选它（见 wb_data）
    reg        ex_mem_is_mul;
    // MEM/WB
    reg        mem_wb_reg_write;
    reg [1:0]  mem_wb_wb_sel;
    reg [31:0] mem_wb_alu_result, mem_wb_pc, mem_wb_imm;
    reg [4:0]  mem_wb_rd;
    reg [2:0]  mem_wb_funct3;
    reg [1:0]  mem_wb_addr_low;
    // [A 扩展] 本条是 AMO —— WB 级据此选 amo_wb_data 作为写回值
    reg        mem_wb_is_amo;
    // [A1] 本条是 mul —— WB 级据此选 mul_result 作为写回值（见 wb_data）
    reg        mem_wb_is_mul;

    // ---- [任务 C] load 地址提前（EARLY_LD）：级间标志与提前读回的数据 ----
    // ID/EX：这条 load 是否走快通路 + 它在 ID 级算好的地址
    reg        id_ex_ld_fast;
    reg [31:0] id_ex_ld_addr;
    // EX/MEM：快通路 load 的标志（EX 级前递与未对齐判据要用）
    reg        ex_mem_ld_fast;
    // （MEM/WB 不再需要快通路专用寄存器：数据走 wb_rdata_snap，见 WB 段）
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
    // 基础字段只带 ALU 类指令用得到的；LANEB_MEM=1 时 lane B 还可以是【load】，
    // 于是多带 mem_read / funct3 /（WB 级）地址低两位 —— 任务书 §4A。
    // [!] R6（任务书 §7）：`ex_mem_b_valid` 是 lane B 访存与写回的【总门控】——
    //    访存口的 b_mem_sel 用它门控，而【不是】给 lane B 的 read 单加一项
    //    `!ex_flush`：ex_mem_b_valid 的锁存式本身就是 `id_ex_b_valid && !ex_flush`
    //    （见 EX/MEM 段）。承重，别当冗余清掉。
    // ID/EX
    reg        id_ex_b_reg_write, id_ex_b_alu_a_sel, id_ex_b_alu_b_sel, id_ex_b_valid;
    reg [4:0]  id_ex_b_alu_op;
    reg [1:0]  id_ex_b_wb_sel;
    reg [31:0] id_ex_b_pc, id_ex_b_rdata1, id_ex_b_rdata2, id_ex_b_imm;
    reg [4:0]  id_ex_b_rd, id_ex_b_rs1, id_ex_b_rs2;
    // [lane B 访存] load 专用（LANEB_MEM=0 时恒 0 / 无关值，见各处门控注释）
    reg        id_ex_b_mem_read;
    reg [2:0]  id_ex_b_funct3;
    // EX/MEM
    reg        ex_mem_b_reg_write, ex_mem_b_valid;
    reg [1:0]  ex_mem_b_wb_sel;
    reg [31:0] ex_mem_b_alu_result, ex_mem_b_pc, ex_mem_b_imm;
    reg [4:0]  ex_mem_b_rd;
    // [lane B 访存] load 专用（LANEB_MEM=0 时恒 0 / 无关值）
    reg        ex_mem_b_mem_read;
    reg [2:0]  ex_mem_b_funct3;
    // MEM/WB
    reg        mem_wb_b_reg_write;
    reg [1:0]  mem_wb_b_wb_sel;
    reg [31:0] mem_wb_b_alu_result, mem_wb_b_pc, mem_wb_b_imm;
    reg [4:0]  mem_wb_b_rd;
    // [lane B 访存] WB 级 load 解包专用（LANEB_MEM=0 时恒 0 / 无关值）
    reg [2:0]  mem_wb_b_funct3;
    reg [1:0]  mem_wb_b_addr_low;
    // lane B 写回数据（LANEB_MEM=1 时多一路 load 解包，见 WB 段）
    wire [31:0] wb_data_b;
    // ------------------------------------------------------------------

    // [lane B 访存] lane B 的 load 驱动访存口（任务书 §4C）。
    // [!] 为什么用 ex_mem_b_valid 门控、而【不是】给 read 单加一项 `!ex_flush`（R6）：
    //    ex_mem_b_valid 的锁存式就是 `id_ex_b_valid && !ex_flush`（EX/MEM 段）——
    //    ex_flush 那拍 lane A（分支/跳转）与 lane B 正同躺在 ID/EX 里，lane B 是
    //    【更年轻】的那条、必被杀死；不抑制它就会误触发一次读口（有 D-Cache 时
    //    还会污染 LRU 与快照）。把门控落在 valid 上、read 直传，是为了让
    //    "lane B 不得驱动访存口"这件事只有一个出处 —— 将来若有人为了"对称"
    //    把 valid 的门控去掉，幽灵读立刻回来，故此处注释承重。
    //    mc_stall / trap 那些沿 EX/MEM 本就被清或保持，mem_read 与 valid 同进同退。
    // [!] LANEB_MEM=0 时 ex_mem_b_mem_read 恒 0：pair_now 不放 lane B load ⇒
    //    if_id_pair=1 时 control_b 译出的必是 OP_REG/OP_IMM/LUI/AUIPC，
    //    mem_read_b=0 ⇒ id_ex_b_mem_read 恒 0 ⇒ b_mem_sel 恒 0，
    //    mem_re / mem_addr 与基线【逐位相同】。
    //    与 AMO 互斥：p_amo_a 禁止配对 ⇒ lane B valid 时 lane A 不可能是 AMO。
    // [!] 时序门控（2026-10-16，任务书 §4-3）：还必须显式带 `(LANEB_MEM != 0)`。
    //    功能上 0 档 b_mem_sel 已恒 0，但综合器证明不了（id_ex_b_mem_read 是
    //    真寄存器）⇒ 会把 mem_re/mem_addr 的 lane B mux 腿建出来。门控后 0 档
    //    折成常量、两条腿被删 ⇒ 与 rev1023 逐位同网表；1 档语义不变。
    wire b_mem_sel = (LANEB_MEM != 0) && ex_mem_b_valid && ex_mem_b_mem_read;
    // 访存口：MEM 级组合输出，一拍的稳定窗口，直接进总线（写通路零寄存器）
    // [A 扩展] AMO 自己驱动访存端口（它要读-改-写，占两拍）。
    // control.v 的 AMO 分支【没有】置 mem_read/mem_write，所以两者互斥，
    // 这里做 or 而不是 mux。
    assign mem_we   = ex_mem_mem_write | amo_mem_we;   // lane B 不放 store：本行不动
    // [任务 C] 快通路 load 的数据由【提前读口】给（它自己的 MEM 级就拿到了），
    //   所以它不再占用 B 口这次读 —— 否则会白占端口、还会被 mem_ready/多拍总线
    //   当成"一次在途访存"而多冻一拍。EARLY_LD=0 时 ex_mem_ld_fast 恒 0 ⇒ 逐位不变。
    // [lane B 访存] lane B 的 load 走【旧通路】（无快通路），mux 优先级高于 lane A 腿：
    //   "每对最多一条访存"（pair_now 的 `!(p_mem_a && p_ld_b)`）保证同拍至多
    //   一条访存 ⇒ 两者永远不会同时要读口，一次 2 路 mux 就够，不需要仲裁器。
    assign mem_re   = b_mem_sel ? 1'b1 :
                      ((ex_mem_mem_read && !ex_mem_ld_fast) | amo_mem_re);
    // [A 扩展] AMO 占 MEM 期间 mem_addr 切到它自己的地址：
    //   ex_mem_amo_addr 就是【前递后的 rs1】（AMO 的地址语义是 rs1，不是 rs1+imm，
    //   所以绝不能用 ex_mem_alu_result）。它在整个占用期间稳定不变（EX/MEM 被
    //   amo_hold 冻住）—— 这一点【承重】：B 口的读地址必须一直保持，amo_unit 才
    //   能在 ST_LATCH 拍到正确的旧值。（历史 bug：地址中途掉成 0，锁回的是地址 0
    //   的指令字，写也写到了 0。写数据/字节使能的 mux 在下面的 always 块里。）
    // [lane B 访存] lane B 的 load 地址 = ex_mem_b_alu_result：control_b 给 load 译出
    //   alu_a_sel=0 / alu_b_sel=1 / alu_op=ADD ⇒ alu_result_b = rs1_val_b + imm_b，
    //   就是 base+offset，【不需要】新增加法器（R7：依赖 control_b 的既有译码）。
    assign mem_addr = b_mem_sel ? ex_mem_b_alu_result :
                      (ex_mem_is_amo ? ex_mem_amo_addr : ex_mem_alu_result);
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
    // [P3a] `pair_now && p_jal_b` 那一腿：lane B 是 jal 时，本组两条一起发射，
    //   下一条未消费的指令【不是】if_addr_d+8，而是 jal 的目标。
    //   位置必须在 stall/mem_ready 那一腿**之后** —— 冻结期取指必须退回 if_addr_d
    //   重发（承重，见上面 [!]），B-jal 改道只在流水线真前进的那拍生效。
    //   优先级低于 p_redirect 是安全的：A 被预测 taken 时 pair_now 恒 0（上面门控），
    //   所以两条腿不可能同拍成立（`pair_now` 在条件里就是这条互斥的保险）。
    wire [31:0] fetch_addr = trap                ? trap_target :
                             ex_flush            ? ex_target :
                             ex_mispred          ? ex_mispred_target :
                             p_redirect          ? p_target :
                             (stall_int || mc_stall || !mem_ready_int) ? if_addr_d :
                             (pair_now && p_jal_b) ? p_jal_target_b :
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
    reg [31:0] if_id_pred_target; // [B1-RAS] 到达级那次预测所用的目标（随 pred_taken 一起带进 EX）

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

    // ---- [面积优化] A_EXT 门控（语义见文件头 parameter A_EXT 处）----
    // A_EXT=0 时：
    //   ① `id_is_amo_g` 恒 0 ⇒ 这个标志不带进流水线，下游所有吃它的地方
    //      （访存口 mux、写回 mux、前递门控、load 快通路门控、mem_ready 冻结）
    //      全部常数化并被综合裁掉 —— 这才是"砍 RV32A"真正省面积的地方；
    //   ② 但 AMO 的 opcode 必须【报非法指令】而不是静默当 NOP：
    //      control.v 仍旧把 `0101111` 译成 AMO，所以在这里补一条 illegal。
    //      RISC-V 规定"未实现的扩展 ⇒ mcause=2 非法指令"，这正是规范表现。
    // [!] 为什么门控加在这里、而不是给 control.v 加参数：
    //     `sim/tb_control.v` 是 control 的独立单测，动它的默认值会把那个单测一起带偏；
    //     在 core 里补两条 wire 是纯增量、对 control 零侵入。
    wire id_is_amo_g = (A_EXT != 0) && id_is_amo;
    wire id_illegal_g = id_illegal || ((A_EXT == 0) && id_is_amo);

    wire [31:0] rdata1, rdata2;
    wire [31:0] rdata1_b, rdata2_b;
    // [双发射] 4 读 2 写寄存器堆。lane A = 现有单发射通路；lane B = 第二槽。
    //   写口 B 在 A 之后写，所以同址（[P1] 现在**允许**同对 rd_a==rd_b）B 赢 ——
    //   正好等于"B 更年轻、它的值才是最终值"。这条是 P1 删掉 `p_rd_a != p_rd_b`
    //   判据的**唯一依据**，改 regfile 写序会立刻让 WAW 配对变成静默错值。
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
    //   消费 {reg_write, alu_a_sel, alu_b_sel, alu_op, wb_sel, imm}；
    //   [lane B 访存] LANEB_MEM=1 时还消费 mem_read（load 译码）—— funct3 不经过
    //   control，直接取 if_id_instr_b[14:12]（见 ID/EX 锁存处）。
    //   其余输出（branch/jump/jump_reg/csr/sys/illegal）对 lane B 恒无意义，
    //   综合会裁掉：pairable_b 保证 lane B 只会是
    //   {OP_REG, OP_IMM, LUI, AUIPC} +（LANEB_MEM=1 时）LOAD。
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
    // 索引 idx=PC[9:2]、tag=PC[17:10]（L3 后；原 tag=PC[31:8]），直接映射 256 项。
    // 预测错不影响正确性：EX 级冲刷兜住。
    // [阶段1] 查询点从 ID 级（if_id_pc）挪到【到达级】（if_addr_d，见下面的 bht_idx_p）：
    //   到达级同一拍 imem_rd 已给出指令字，可当场算出目标 p_target 并立即重定向，
    //   被预测 taken 的分支不再付那 1 拍取指重定向气泡。
    // [L3 减 LUT] 深度保持 256，tag 24 → **8 位**（PC[17:10]）。
    //   索引仍是 idx = PC[9:2]，tag = PC[17:10] ⇒ 索引+tag 唯一覆盖 PC[17:2] = 256KB；
    //   两份镜像都落在 0x0~0x1FFFF（128KB）内 ⇒ **零别名、预测率逐位不变**
    //   （实测 region cycles 仍是 217,088 / mispredict 仍是 1,543）。
    //   只缩 tag 宽度不缩深度：深度一变，深层 LUT-RAM 阵列外圈的地址译码/输出 mux
    //   会被综合成额外逻辑，反而更亏（实测 128 项版多了 804 拍、命中率掉）。
    reg [7:0]   bht_tag  [0:255];
    reg [1:0]   bht_ctr  [0:255];
    reg [255:0] bht_valid;

    // ================= [B1-RAS] 返回地址栈 =================
    // 目的：让 `ret`（= jalr x0,0(x1|x5)）也能在【到达级】当场拿到目标并重定向，
    //   不再走"EX 级才发现要跳"那条要付 2~3 拍气泡的冲刷路径。
    //   `ret` 是调用密集代码里最常见、也最贵的跳转；CoreMark 里 jalr 全部是 ret。
    //
    // 存储：16 项返回地址栈。push 在 EX 级（call 提交那拍写 id_ex_pc+4），
    //   pop/读在到达级（ret 到达级直接读栈顶当预测目标）。
    //   [!] 到达级读 vs EX 写是【同一拍】的寄存器读写——call 紧邻 ret（相隔 1 条）时
    //   ret 读到的是 call 进 EX 之前的值（上一层），预测错 ⇒ 被 §7 目标校验冲刷纠正。
    //   这是"EX 更新、到达级读"的固有属性，只损失这次预测、不影响正确性。
    //
    // 精度：v10 §5 实测 8 项与 16 项预测命中率都是 99.93%（CoreMark），
    //   取 16 是为了防 RT-Thread 那种更深的调用嵌套。溢出时饱和丢弃 push（罕见）。
    localparam integer RAS_DEPTH = 16;
    reg [31:0] ras_mem [0:RAS_DEPTH-1];
    reg [4:0]  ras_sp;                                  // 0..RAS_DEPTH
    wire       ras_empty = (ras_sp == 5'd0);
    // 栈顶 = ras_mem[ras_sp-1]。sp=0 时 [3:0]-1 回绕到 15，但被 ras_empty 挡掉，语义无碍。
    // sp=RAS_DEPTH 时 [3:0]=0，0-1 回绕到 15 —— 正好是最后 push 的那一项。
    wire [31:0] ras_top = ras_mem[ras_sp[3:0] - 4'd1];

    // ================= [B1-BTB] 分支目标缓冲 =================
    // 目的：给【间接跳转 jalr】预测目标（赛题原文点名的"动态分支预测器（如 BTB）"）。
    //   条件分支与 jal 的目标 = PC+imm，到达级由 p_target 现算、已经是对的，所以
    //   BTB 不复存它们（只存 jalr），不与 BHT（方向）打架。
    //
    // 形态完全照 BHT：直接映射 32 项，索引 idx=PC[6:2]、tag=PC[31:8]。
    //   读在到达级（if_addr_d），训练在 EX 级（id_ex_pc），读写同拍读旧值可接受
    //   （最多一次误预测，被 §7 目标校验兜住）。
    //   [!] 优先级 RAS > BTB > PC+imm（ret 的目标由栈给，比 BTB 准）；BTB 命中时
    //   p_pred_taken=1 ⇒ jalr 独占发射（pair_now=0），与它原来"不被预测、不配对"一致。
    //   [!] 目标只折进【已有的 p_target 腿】，绝不新增 fetch_addr 的腿（Fmax 第一风险点）。
    //   [L2 减 LUT] 256 → 32 项：btb_tag 96→12、btb_target 124→16 个 RAM64X1（−192 LUT-RAM）。
    //   tag 保持 24 位（PC[31:8]）⇒ 索引只看 PC[6:2]，**PC[7] 不参与匹配** ⇒
    //   相差 128 字节的两个 jalr 别名（共用一条目）。只影响命中率、不影响正确性：
    //   目标错由 §7 的 ex_target_wrong（id_ex_pred_taken && rs1_val&~1 != 预测目标）冲刷兜住。
    reg [23:0] btb_tag    [0:31];
    reg [31:0] btb_target [0:31];
    reg [31:0] btb_valid;

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
    //   lane A 这条是原有通路；[lane B 访存] lane B 若也是 load（LANEB_MEM=1）则它的
    //   rd 同样是 load-use 的生产者，另立一条同构子句（见下）。
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
                     (if_id_pair && ((id_ex_rd == rs1_b) || (id_ex_rd == rs2_b))))) ||
                   // [A1] mul 的结果要到 WB 级才由流水线乘法器给出（latency 2），
                   //   所以"紧邻下一条就消费"必须停 1 拍 —— 判据与上面 load-use 同构
                   //   （含 lane B 的 if_id_pair 门控，理由见上）。
                   //   实测 CoreMark 每迭代 9,396 条 mul 里只有 **108 条**落这一类，
                   //   于是停顿从"每条 mul 都停 1 拍"收窄成"只有紧邻消费者停 1 拍"。
                   (id_ex_is_mul && (id_ex_rd != 5'd0) &&
                    ((id_ex_rd == rs1) || (id_ex_rd == rs2) ||
                     (if_id_pair && ((id_ex_rd == rs1_b) || (id_ex_rd == rs2_b))))) ||
                   // [lane B 访存] lane B 的 load 也是 load-use 的生产者 —— 与 lane A
                   // 那条完全同构（含 if_id_pair 门控，理由同上）。
                   //   [!] 不需要 `!id_ex_b_ld_fast`：lane B 的 load 永远不走 EARLY_LD
                   //   快通路（ld_fast 只由 lane A 的译码驱动，任务书 §3）⇒ 紧跟的
                   //   消费者必须停一拍，数据由 MEM/WB 级的 fwd_*_wbb 前递（wb_data_b）。
                   //   LANEB_MEM=0 时 id_ex_b_mem_read 恒 0 ⇒ 本项恒 0、逐位不变。
                   // [!] 时序门控（2026-10-16，任务书 §4-4）：整条子句再前置
                   //   `(LANEB_MEM != 0)`。stall 是流水线控制信号，0 档综合器会把
                   //   id_ex_b_mem_read 的比较器树建出来挂到 stall → ID/EX 清的路径上。
                   //   门控后 0 档整条折成常量删除 ⇒ 恢复 rev1023 网表；1 档语义不变。
                   ((LANEB_MEM != 0) && id_ex_b_mem_read && (id_ex_b_rd != 5'd0) &&
                    ((id_ex_b_rd == rs1) || (id_ex_b_rd == rs2) ||
                     (if_id_pair && ((id_ex_b_rd == rs1_b) || (id_ex_b_rd == rs2_b)))));

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
    //   [P1 2026-10-17] 原规则里"rd_a 与 rs1_b/rs2_b/rd_b 一律不许相等"已放宽：
    //   A 是纯 ALU 时结果在 EX 同拍可得（A→B 旁路），同址写回由 regfile
    //   "B 后写 ⇒ B 赢"兜住。详见本段末尾 pair_now 的说明。
    wire [6:0] p_op_a  = imem_rd[6:0];
    wire [6:0] p_f7_a  = imem_rd[31:25];
    wire [4:0] p_rd_a  = imem_rd[11:7];
    // [B1-RAS] 到达级 ret 检测需要的两个字段（原先只有 op/f7/rd）。
    wire [4:0] p_rs1_a = imem_rd[19:15];
    wire [2:0] p_f3_a  = imem_rd[14:12];
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
    // [lane B 访存] lane A / lane B 的访存属性（任务书 §4B）
    wire p_mem_a = (p_op_a == 7'b0000011) || (p_op_a == 7'b0100011);   // load / store
    wire p_ld_b  = (p_op_b == 7'b0000011);                             // 只放 load

    // [P1 · A→B 同拍旁路] lane A 是否能在 EX 同拍把结果送给 lane B。
    //   白名单 = **写回值骑在 `alu_result` 上**的三类：
    //     OP / OP_IMM（wb_sel=00，ALU 结果）、AUIPC（wb_sel=00，pc+imm）。
    //   [!] **LUI 不能进这个白名单**：它 wb_sel=2'b11，写回值取 `id_ex_imm`
    //       而 `alu_result` 那拍不是它（见 control.v 的 wb_sel 编码）。放进来会
    //       出现"配了对、B 却拿到陈旧寄存器值"的静默错值 —— 这类判据必须与
    //       EX 段 `ab_bypass` 的 `wb_sel==00` **逐位同源**。
    //   load 也不在白名单：数据要到 MEM/WB 才回来 —— 这类依赖仍由 stall 处理
    //   （见 hazard 段），A 是 load 时 pair_now 仍按"源冲突就不配对"走。
    //   [!] 本判据是**放宽**不是收紧：去掉的是三条 5 位比较器里的两条，
    //   取指环（pair_now → fetch_addr → BRAM 地址）反而少一级逻辑。
    wire p_alu_a     = (p_op_a == 7'b0110011) || (p_op_a == 7'b0010011) ||
                       (p_op_a == 7'b0010111);
    wire p_ab_bypass = p_alu_a && !p_muldiv_a;

    wire p_branch = (p_op_a == 7'b1100011);
    wire p_jump   = (p_op_a == 7'b1101111);
    // [P3a] lane B 是 JAL：无条件跳转、目标 = (if_addr_d+4) + imm_B 完全由取指给出。
    //   **不需要预测、也不需要 EX 校验/冲刷** —— 这是"B 放控制指令"里唯一
    //   零风险的一档：jal 的目标是架构常量，不存在"预测对方向、目标算错"。
    //   它只多出两件事：① 下一组取指改道到 target；② 链接值 = B_pc+4 = if_addr_d+8
    //   （wb_sel_b=2'b10 已经由 control_b 给出，`wb_data_b` 直接算 mem_wb_b_pc+4）。
    assign p_jal_b  = (p_op_b == 7'b1101111);
    assign p_jal_target_b = if_addr_d + 32'd4 + p_imm_b;
    wire [7:0] bht_idx_p   = if_addr_d[9:2];
    wire       bht_hit_p   = bht_valid[bht_idx_p] && (bht_tag[bht_idx_p] == if_addr_d[17:10]);
    wire       bht_taken_p = bht_ctr[bht_idx_p][1];
    // [B1-RAS] 到达级 `ret` 检测。ret = jalr x0,0(x1|x5)：
    //   opcode=1100111(JALR)、funct3=000、rd=x0、rs1∈{x1(ra),x5(t0)}。
    //   命中且栈非空 ⇒ 预测目标 = 栈顶（call 时压的 id_ex_pc+4）。
    //   [!] 这是【绝对地址】预测（不是 pc+imm），所以必须走 §7 的目标校验：
    //   栈顶一旦不是真正链接值，EX 级比对 ex_target 就会冲刷纠正。
    wire       p_is_ret  = (p_op_a == 7'b1100111) && (p_f3_a == 3'b000) &&
                           (p_rd_a == 5'd0) && ((p_rs1_a == 5'd1) || (p_rs1_a == 5'd5));
    wire       p_ras_hit = p_is_ret && !ras_empty;
    // [B1-BTB] 间接跳转 jalr（opcode 1100111）的 BTB 目标预测。优先级低于 RAS：
    //   ret 也是 jalr，但目标该由栈给；只有"非 RAS 命中"的 jalr 才查 BTB。
    //   BTB_EN=0 时 p_btb_pred 恒 0 ⇒ 逐位回退成 RAS-only 的行为。
    wire       p_is_jalr  = (p_op_a == 7'b1100111);
    wire [4:0] btb_idx_p  = if_addr_d[6:2];
    wire       btb_hit_p  = btb_valid[btb_idx_p] && (btb_tag[btb_idx_p] == if_addr_d[31:8]);
    wire       p_btb_pred = (BTB_EN != 0) && p_is_jalr && !p_ras_hit && btb_hit_p;
    // 静态规则兜底：BHT 未命中时后向条件分支 / jal 预测跳转（到达级 pc = if_addr_d）
    //   [B1-RAS] 最高优先级是 RAS 命中（ret 一定跳、且目标已知）；它取 1 会让 pair_now=0，
    //   ret 独占发射，与它原来"不被预测、不配对"的行为一致。
    //   [B1-BTB] 次高优先级是 BTB 命中（jalr 目标已知）；同样让 pair_now=0。
    wire       p_pred_taken = p_ras_hit  ? 1'b1
                            : p_btb_pred ? 1'b1
                            : (p_branch && bht_hit_p) ? bht_taken_p
                            : ((p_branch && imem_rd[31]) || p_jump);
    // [阶段1] 到达级预测目标与重定向。目标 = if_addr_d + imm，imm 由 imem_rd 译出
    //   （第三个 imm_gen 实例，专门给到达级用）。p_redirect 的门控注释见上面
    //   "动态预测（保守版）"那一段（mem_ready 那条承重逻辑）。
    wire [31:0] p_imm;
    imm_gen u_imm_p (.instr(imem_rd), .imm(p_imm));
    // [P3a] lane B 放 JAL 需要它自己的立即数（目标 = (if_addr_d+4) + imm_B）。
    //   到达级就得算出来 —— 不能等 ID/EX 的 imm_b（那要晚一拍）。
    //   （`p_imm_b` 的声明在文件顶部，与 `p_jal_b / p_jal_target_b` 一起，
    //     因为 fetch_addr 比这里更早就消费它们。）
    imm_gen u_imm_pb (.instr(imem_rd2), .imm(p_imm_b));
    // [B1-RAS] 目标折进【已有的 p_target 腿】：RAS 命中时取栈顶，否则保持 pc+imm。
    // [B1-BTB] 再加一档：RAS 不中但 BTB 中时取 BTB 里的目标。优先级 RAS > BTB > PC+imm。
    //   [!] 绝不新增 fetch_addr 的腿（那是 Fmax 第一风险点，同当年 MRET 的处理）。
    assign      p_target   = p_ras_hit  ? ras_top
                           : p_btb_pred ? btb_target[btb_idx_p]
                           : (if_addr_d + p_imm);
    assign      p_redirect = p_pred_taken && !ex_flush && !stall_int && !mc_stall && mem_ready_int;
    // [lane B 访存] M 扩展排除【只对 OP_REG 生效】。
    // [!] 任务书 §7 R3：load 的 instr[31:25] 是【立即数高位】而不是 funct7 ——
    //     无条件排除会把 imm[11:5]==0000001 的合法 load 误排，表现为"少配一对"，
    //     不报错、CRC 也不变（只是分数少）。
    // [!] 但收窄【必须门控在 LANEB_MEM 上】：OP_IMM 的 instr[31:25] 同样是立即数
    //     高位，无条件收窄会顺带放行一批 `addi rd,rs1,0x20` 一类的 OPIMM ——
    //     pairtrace 实测会多配 ~927 对（229,597 拍会变）⇒ 破坏 P2"基线逐位不变"
    //     的判据。故 0 档保持原判据（逐位回退）、1 档用收窄判据；模型 ④ 档
    //     （pair_analyze.py）早已按收窄后的规则算，P3 两件事一起生效。
    wire p_f7_b_ok = p_jal_b ? 1'b1 :
                     ((LANEB_MEM != 0) ? !((p_op_b == 7'b0110011) && (p_f7_b == 7'b0000001))
                                       : (p_f7_b != 7'b0000001));
    wire p_opcode_b_ok = (p_op_b == 7'b0110011) || (p_op_b == 7'b0010011) ||
                         (p_op_b == 7'b0110111) || (p_op_b == 7'b0010111) ||
                         ((LANEB_MEM != 0) && p_ld_b) ||
                         p_jal_b;                        // [P3a] lane B 放 JAL

    assign pair_now = (DUAL_ISSUE != 0) &&
                      (imem_rd != 32'd0) && (imem_rd2 != 32'd0) && !p_pred_taken &&
                      !p_muldiv_a && !p_amo_a &&
                      // [P3a] `(p_rd_b != 5'd0)` 对 JAL 不适用：`j label` 就是
                      //   `jal x0,label`（rd=0），它照样占一个发射槽、照样要占拍。
                      p_opcode_b_ok && p_f7_b_ok && (p_jal_b || (p_rd_b != 5'd0)) &&
                      // [lane B 访存] 每对最多一条访存（任务书 §2 的前提）：lane A/B
                      // 同对同拍锁存 ⇒ 任一拍 MEM 级至多一条访存 ⇒ 访存口一次 2 路
                      // mux 就够，不需要仲裁器/ready 握手。LANEB_MEM=0 时 lane B 是
                      // load 已让 p_opcode_b_ok=0，本项冗余（逐位不变）；写上为自明。
                      // [!] 时序门控（2026-10-16，任务书 §4-2）：还必须显式带
                      // `(LANEB_MEM != 0)`。p_mem_a && p_ld_b 这条腿在 0 档虽恒不
                      // 成立，但综合器会把 p_ld_b 的译码逻辑建出来并挂到 pair_now
                      // → fetch_addr 的组合路径上（Fmax 第一风险点）。门控后 0 档
                      // 折成常量删除该腿 ⇒ 恢复 rev1023 网表；1 档语义不变。
                      !(p_mem_a && p_ld_b && (LANEB_MEM != 0)) &&
                      // [P1 · A→B 同拍旁路] 原先这里有三个"同对不许有寄存器耦合"的
                      //   条件，本版按数据通路能力放宽：
                      //   ① `p_rd_a != p_rs1_b` / ② `p_rd_a != p_rs2_b`：A 是纯 ALU 时
                      //      结果在 EX 同拍可得，B 的两个源直接从 `alu_result` 取
                      //      （见 EX 段 `fwd_ba_ab/fwd_bb_ab`）。A 不是纯 ALU
                      //      （load / mul / jal / CSR…）时仍然完全不配对，语义与旧版一致。
                      //   ③ `p_rd_a != p_rd_b`（同址写回）**整条删除**：regfile 是
                      //      4 读 2 写，写口 B 在 A 之后写 ⇒ 同址时 B 赢，正好等于
                      //      "B 更年轻、它的值才是最终值"。删掉顺带省一级比较器。
                      //   [P3a] `p_jal_b` 直接短路：JAL 的 instr[19:15]/[24:20] 是
                      //      立即数位，不是 rs1/rs2 —— 拿它们比 rd_a 只会随机杀掉配对
                      //      （性能问题，不是正确性问题，但白丢收益）。
                      (p_jal_b || p_ab_bypass ||
                       ((p_rd_a != p_rs1_b) && (p_rd_a != p_rs2_b)));

    // 取指地址：stall 时退一格到在途指令 if_addr_d 让同步读重新锁存正确数据，
    // 跳转时当拍旁路到目标（见上面 fetch_addr 的说明）。
    assign imem_addr = fetch_addr[16:2];   // 128KB = 32768 word

    // 第二取指地址：固定指向下一个 word。
    // [!] 常量必须写 `15'd1`（与 imem_addr 同宽）。写成窄常量的话，一旦接收端
    //     也是窄的就会截位 —— 见端口声明处的 [!]。这里写全宽是让"谁在哪个宽度上算"
    //     一目了然，两边一起改不难。
    //     DUAL_ISSUE=0 时它在核内没有任何消费者，综合会连同 A2 口的读结果一起裁掉。
    // [!] 2026-10-16 P3.5(B)：必须从 `fetch_addr[16:2]` 直接算，**不要**写成
    //     `imem_addr + 15'd1` —— 后者把这条 15 位加法【串】在 imem_addr 之后：
    //     关键路径多一级 LUT + 一条进 BRAM 的长线（P3.5(A) 后的实测路径：
    //     if_addr_d → imem_addr → N247_1_8/COUT → imem_addr2[11] → DRM ADB0）。
    //     两式逐位等价（都是 15 位模 2^15 加法，`imem_addr` 恒 = `fetch_addr[16:2]`），
    //     改写只是把"两个平级加法器"的自由度还给综合器，语义零变化。
    assign imem_addr2 = fetch_addr[16:2] + 15'd1;

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
    // [lane B 访存] lane B 若是 load（LANEB_MEM=1）同理：wb_sel=01 时
    //   ex_mem_b_alu_result 是【地址】不是数据 —— 四个 fwd_*_exb 与 ld_f_exb 都
    //   必须排除它（任务书 §4F，R1：漏了就是"把地址当数据前递"的静默错）。
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

    // [任务 C] 快通路 load 的【解包后】结果：EX/MEM 里那条若走快通路，它的原始字这一拍
    //   就在 ld_early_data 上（地址是它上一拍在 EX 级发的）—— 也正是"它的 MEM 级"。
    //   两个消费者：① 消费者的 EX 操作数前递 ② ID 级算地址时的基址（见下）。
    //
    // [!] 必须是【解包后】的值，不能是原始字 —— lb/lbu/lh/lhu 要按 funct3 与地址低两位
    //     取字节/半字。2026-10-11 实踩：只前递原始字时 `lw` 全过、`lb/lbu/lh` 全 FAIL
    //     （`lhu` 因测试数据高半字恰好为 0 而蒙混），CoreMark 的 matrix/state CRC 也全错
    //     （它用的是 u16）。WB 段那条解包逻辑服务的是写回，这里必须【另来一份】。
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
    // [lane B 访存] R1：lane B 若是 load，ex_mem_forward_val_b 会落到
    //   ex_mem_b_alu_result = 【地址】而不是数据 —— 必须排除 wb_sel==01，与 lane A
    //   的 ld_f_ex 同构。LANEB_MEM=0 时 lane B 不可能是 load（wb_sel_b 恒不为 01）
    //   ⇒ 本门控恒真、逐位不变。
    // [!] 时序门控（2026-10-16，任务书 §4-5）：五处（ld_f_exb + 四个 fwd_*_exb）
    //   共用一个 `exb_wb_ok`，且它带 `|| (LANEB_MEM == 0)` 兜底 —— 0 档恒真、
    //   综合器把五个比较器整批折叠掉，不给前递网白建 lane B load 的解码逻辑；
    //   1 档就是原来的"排除 wb_sel==01"语义。
    wire        exb_wb_ok = (ex_mem_b_wb_sel != 2'b01) || (LANEB_MEM == 0);
    wire        ld_f_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == rs1) &&
                          exb_wb_ok;
    wire        ld_f_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == rs1) &&
                           (ex_mem_wb_sel != 2'b01) && !ex_mem_is_amo;
    wire        ld_f_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == rs1);
    wire        ld_f_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == rs1);
    // [!] 最上面那一路是"基址来自 EX/MEM 里【另一条快通路 load】"——链式指针解引用
    //     `lw a5,0(a0) ; ... ; lw a1,0(a5)`。它在 CoreMark 里占 load 的 22%，不接进来
    //     就等于把这批 load 全部留在旧通路上（2026-10-11 实测：接进来多兑现 8.6% 的停顿）。
    // [!] 但**只接【字 load】**：byte/half 的消费者要先解包（字节选择 + 符号扩展），
    //     那几级会直接压在这条 ID 链上 —— 综合实测它一度顶替乘法器成了 CPU 域最差路径
    //     （`ld_rdata → ld_early_val → ld_base mux → ld_id_addr 加法器`，slack 掉到 +0.035 ns）。
    //     字 load 的数据【不需要解包】，直接就是寄存器将写入的值，等于白省 3~4 级。
    //     非字 load 作为基址来源时退回旧通路（保守，只是慢）。
    wire        ld_f_ld  = (EARLY_LD != 0) && ex_mem_ld_fast &&
                           (ex_mem_funct3 == 3'b010) &&
                           (ex_mem_rd != 5'd0) && (ex_mem_rd == rs1);
    wire [31:0] ld_base  = ld_f_ld  ? ld_early_data :
                           ld_f_exb ? ex_mem_forward_val_b :
                           ld_f_ex  ? ex_mem_forward_val :
                           ld_f_wbb ? wb_data_b :
                           ld_f_wb  ? wb_data : rdata1;
    // load 的地址 = base + imm（control.v 里 load 恒 alu_op=ADD、alu_b_sel=1 取 imm）
    assign      ld_id_addr = ld_base + imm;

    wire ld_bad_base = (id_ex_reg_write   && (id_ex_rd   != 5'd0) && (id_ex_rd   == rs1)) ||
                       (id_ex_b_reg_write && (id_ex_b_rd != 5'd0) && (id_ex_b_rd == rs1)) ||
                       ((ex_mem_rd != 5'd0) && (ex_mem_rd == rs1) &&
                        (ex_mem_is_amo ||
                         (ex_mem_mem_read &&
                          (!ex_mem_ld_fast || (ex_mem_funct3 != 3'b010))))) ||   // 判据①
                       // [lane B 访存] R2：EX/MEM 里 lane B 那条是【load】时，它的数据
                       // 要到 MEM/WB 才回来（lane B 无快通路）⇒ 基址算拿不到，必须判
                       // bad_base。不补这一条：ld_f_exb 被上面的 wb_sel 门控挡掉后会
                       // 【静默回落】到 id_ex_rdata1（陈旧值）⇒ ld_id_addr 算错、而
                       // ld_fast 仍判"可走快通路" ⇒ load 读到错地址。只有"lane A load
                       // 的基址来自同拍 lane B load"的链式指针解引用才触发，静默错。
                       // LANEB_MEM=0 时 ex_mem_b_mem_read 恒 0 ⇒ 本项恒 0、逐位不变。
                       // [!] 时序门控（2026-10-16，任务书 §4-6）：整条再前置
                       //   `(LANEB_MEM != 0)`。ld_bad_base 喂 ld_fast → 提前读口，
                       //   0 档综合器会把 ex_mem_b_rd 的比较器建到这条 ID 级 AGU 链上
                       //   （历史上它一度是 CPU 域最差路径）。门控后 0 档整条折成
                       //   常量删除 ⇒ 恢复 rev1023 网表；1 档语义不变。
                       ((LANEB_MEM != 0) && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == rs1) &&
                        ex_mem_b_mem_read);
    //   注意：EX/MEM 里那条是【字快通路 load】时不算拿不到 —— 它的数据这一拍就在
    //   ld_early_data 上（上面 ld_base 的第一路）。旧通路 load、byte/half 快通路 load、
    //   AMO 都仍然算拿不到（数据还没回来 / 要解包，见 ld_f_ld 处的说明）。
    // 128KB：RAM = 0x0~0x1FFEF；兼容区只挖低 64KB 的 0xFFF0~0xFFFF
    // （0x1FFF0 的 addr[15:4] 也是 0xFFF，必须用 addr[16] 区分，见 mem_bus.v）
    wire ld_bad_ram  = !((ld_id_addr[31:17] == 15'd0) &&
                         !((ld_id_addr[16] == 1'b0) &&
                           (ld_id_addr[15:4] == 12'hFFF)));                   // 判据②
    wire ld_bad_st   = id_ex_mem_write;                                       // 判据③
    wire ld_bad_amo  = id_ex_is_amo || ex_mem_is_amo;                         // 判据④

    assign ld_fast = (EARLY_LD != 0) && mem_read &&
                     !ld_bad_base && !ld_bad_ram && !ld_bad_st && !ld_bad_amo;

    // 提前读口地址：由 ID/EX 驱动（= 该 load 的 EX 级）。非快通路时指 0（无用）。
    assign ld_addr = id_ex_ld_fast ? id_ex_ld_addr[16:2] : 15'd0;

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

    wire        ld_fwd_en = (EARLY_LD != 0) && ex_mem_ld_fast && (ex_mem_rd != 5'd0);
    wire        ld_fwd_a  = ld_fwd_en && (ex_mem_rd == id_ex_rs1);
    wire        ld_fwd_b  = ld_fwd_en && (ex_mem_rd == id_ex_rs2);
    wire        ld_fwd_ba = ld_fwd_en && (ex_mem_rd == id_ex_b_rs1);
    wire        ld_fwd_bb = ld_fwd_en && (ex_mem_rd == id_ex_b_rs2);

    // lane A 操作数 1（id_ex_rs1）
    // [lane B 访存] `&& exb_wb_ok`：lane B 是 load 时不得把
    //   【地址】当数据前递（R1）。LANEB_MEM=0 时 lane B 不可能是 load ⇒ 恒真。
    wire fwd_a_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_rs1) &&
                     exb_wb_ok;
    wire fwd_a_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                     (ex_mem_rd == id_ex_rs1) && (ex_mem_wb_sel != 2'b01);
    wire fwd_a_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_rs1);
    wire fwd_a_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1);
    // lane A 操作数 2（id_ex_rs2）
    // [lane B 访存] 同 fwd_a_exb：排除 lane B load 的地址前递（R1）。
    wire fwd_b_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_rs2) &&
                     exb_wb_ok;
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


    // ================= [面积优化] A_EXT 门控：AMO 单元是否例化 =================
    // [!] 只把 `start` 接 0 是**不够**的 —— amo_unit 内部的地址/操作数锁存、以及
    //     状态机寄存器并不依赖 start 的常量性，综合器不会去证明它们恒为常量，
    //     面积省不下来。**必须用 generate 把整个例化包起来**，单元连同它的
    //     输出 mux 才会被裁掉。这才是"砍 RV32A"真正省面积的那一下。
    // A_EXT=0（默认）时 amo_hold 恒 0 ⇒ `mem_ready_int ≡ mem_ready` —— 这正是
    //   2026-10-14 那两处修复（约定 56/57）所依赖的等式，语义逐位不变。
    generate if (A_EXT != 0) begin : g_amo

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

    end else begin : g_no_amo
        // A_EXT=0：AMO 通路整条不存在。下面这几根线在原实现里全部由 amo_unit 驱动，
        //   这里给常量，下游 mux 折向另一条腿之后被综合裁掉。
        assign amo_mem_re      = 1'b0;
        assign amo_mem_we      = 1'b0;
        assign amo_byte_en     = 4'b0000;
        assign amo_wdata       = 32'd0;
        assign amo_stall       = 1'b0;
        assign amo_mem_release = 1'b0;
        assign amo_wb_data     = 32'd0;
        assign amo_illegal     = 1'b0;
        assign amo_hold        = 1'b0;
    end
    endgenerate

    assign mem_ready_int = mem_ready && !amo_hold;

    wire [31:0] alu_a = id_ex_alu_a_sel ? id_ex_pc  : rs1_val;
    wire [31:0] alu_b = id_ex_alu_b_sel ? id_ex_imm : rs2_val;
    wire [31:0] alu_raw;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(id_ex_alu_op), .result(alu_raw));

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
    //   * [P1] 本赋值上移到 lane B 的 EX **之前**：lane B 的 A→B 同拍旁路要用它
    //     （iverilog 先声明后使用）。依赖的 csr_rdata / div_result / mul_result /
    //     alu_raw / id_ex_is_div 全部在此行之前已声明，语义与位置无关。
    // ------------------------------------------------------------------
    // 多拍除法（DIV/DIVU/REM/REMU）：alu_op 14..17 ⇒ 由迭代除法器接管。
    //   [P1] 声明上移：`alu_result` 的四选一要用它（下面 div_start 只消费）。
    wire id_ex_is_div = (id_ex_alu_op >= 5'd14);
    wire [31:0] alu_result = id_ex_is_csr ? csr_rdata :
                             id_ex_is_div ? div_result :
                             id_ex_is_mul ? mul_result : alu_raw;

    // ---- lane B 的 EX：ALU +（LANEB_MEM=1 时）load ----
    // lane B 操作数 1（id_ex_b_rs1）
    // [lane B 访存] 同 fwd_a_exb：排除 lane B load 的地址前递（R1）。
    wire fwd_ba_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_b_rs1) &&
                      exb_wb_ok;
    wire fwd_ba_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                      (ex_mem_rd == id_ex_b_rs1) && (ex_mem_wb_sel != 2'b01);
    wire fwd_ba_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_b_rs1);
    wire fwd_ba_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_b_rs1);
    // lane B 操作数 2（id_ex_b_rs2）
    // [lane B 访存] 同 fwd_a_exb：排除 lane B load 的地址前递（R1）。
    wire fwd_bb_exb = ex_mem_b_reg_write && (ex_mem_b_rd != 5'd0) && (ex_mem_b_rd == id_ex_b_rs2) &&
                      exb_wb_ok;
    wire fwd_bb_ex  = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                      (ex_mem_rd == id_ex_b_rs2) && (ex_mem_wb_sel != 2'b01);
    wire fwd_bb_wbb = mem_wb_b_reg_write && (mem_wb_b_rd != 5'd0) && (mem_wb_b_rd == id_ex_b_rs2);
    wire fwd_bb_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_b_rs2);

    // [P1 · A→B 同拍旁路] lane A 与 lane B 同处 EX 时，A 的 ALU 结果这一拍就能用。
    //   `ab_bypass` 的三个条件缺一不可：
    //     ① A 写非 x0 寄存器（否则 B 的源与它无关）；
    //     ② A 的写回值就骑在 `alu_result` 上（`wb_sel==00`）。**必须是 00**：
    //        wb_sel=01 是 load（数据在 MEM/WB 才回来）、10 是 jal/jalr 的链接值
    //        （走 `ex_mem_pc+4`）、11 是 LUI（`id_ex_imm`）⇒ 三者都不能旁路。
    //        ALU / OP_IMM / AUIPC / CSR 是 00，与 pair_now 的 `p_ab_bypass`
    //        白名单（OP / OP_IMM / AUIPC）一致；CSR 不进配对，保守收窄。
    //     ③ **优先级最高** —— A 比 EX/MEM、MEM/WB 里的指令都年轻。
    //   [!] 这条链是 `reg → A 的 ALU → B 的 ALU → B 的结果寄存器`（两级 ALU），
    //   不在取指环上；但它是本设计第一次让 EX 内部出现**同拍串联**，
    //   出流前必须看 PDS 报告里 lane B 的 `alu_result_b` 锥有没有变长。
    wire        ab_bypass  = id_ex_reg_write && (id_ex_rd != 5'd0) && (id_ex_wb_sel == 2'b00);
    wire        fwd_ba_ab  = ab_bypass && (id_ex_rd == id_ex_b_rs1);
    wire        fwd_bb_ab  = ab_bypass && (id_ex_rd == id_ex_b_rs2);

    wire [31:0] rs1_val_b = fwd_ba_ab ? alu_result :            // [P1] A→B 同拍旁路
                            ld_fwd_ba ? ld_early_val :         // [任务 C] 快通路 load
                            fwd_ba_exb ? ex_mem_forward_val_b :
                            fwd_ba_ex  ? ex_mem_forward_val :
                            fwd_ba_wbb ? wb_data_b :
                            fwd_ba_wb  ? wb_data : id_ex_b_rdata1;
    wire [31:0] rs2_val_b = fwd_bb_ab ? alu_result :            // [P1] A→B 同拍旁路
                            ld_fwd_bb ? ld_early_val :         // [任务 C] 快通路 load
                            fwd_bb_exb ? ex_mem_forward_val_b :
                            fwd_bb_ex  ? ex_mem_forward_val :
                            fwd_bb_wbb ? wb_data_b :
                            fwd_bb_wb  ? wb_data : id_ex_b_rdata2;

    wire [31:0] b_alu_a = id_ex_b_alu_a_sel ? id_ex_b_pc  : rs1_val_b;
    wire [31:0] b_alu_b = id_ex_b_alu_b_sel ? id_ex_b_imm : rs2_val_b;
    wire [31:0] alu_result_b;
    alu u_alu_b (.a(b_alu_a), .b(b_alu_b), .alu_op(id_ex_b_alu_op), .result(alu_result_b));

    // 多拍除法：DIV/DIVU/REM/REMU 由迭代除法器接管（单拍组合除法会拖垮 Fmax）
    // （`id_ex_is_div` 的声明已上移到 `alu_result` 之前 —— 见该处的 [P1] 说明。）
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
    //   [!] `id_ex_is_mul` 的声明已【提前】到 ID/EX 寄存器声明处 —— stall 要用它。
    wire mul_start    = id_ex_is_mul;       // [A1] II=1 ⇒ 不再看 busy，每拍高就是收一条
    // alu_op 10/11/12/13 → op 0/1/2/3（MUL/MULH/MULHSU/MULHU）
    wire [1:0] mul_op = id_ex_alu_op[1:0] - 2'd2;
    multiplier u_multiplier (
        .clk(clk), .resetn(resetn),
        // [A1] en 必须与 EX/MEM、MEM/WB 寄存器同源 —— 否则 mem_ready 停顿时
        //   乘法器继续前进、*_is_mul 却保持，写回值会错位（+MEMWAIT=3 抓到的坑）。
        .en(mem_ready_int),
        .start(mul_start),
        .a(alu_a), .b(alu_b),
        .op(mul_op),
        .result(mul_result),
        .busy(mul_busy),
        .done(mul_done)
    );
    // （`alu_result` 的赋值已上移到 lane B 的 EX 之前 —— P1 的 A→B 旁路要用它。）
    // 访存地址 = base + offset，恒为 ADD（load/store 的 alu_op 固定为 0，
    // 见 control.v 的 OP_LOAD / OP_STORE —— 它们不写 alu_op，保持 default 的 0）。
    // 单独用一个加法器产生地址，把 32×32 乘法器从
    // "未对齐判据 → 异常 → pc_r 写使能" 这条【假路径】上切下来：
    // mul 指令从不访存，乘法结果根本不该出现在 pc_r 的时序弧里。
    // [!] 只用于未对齐判据与 mtval，不改变任何流水线语义（见 §关键路径）。
    wire [31:0] addr_result = alu_a + alu_b;
    assign      div_stall  = id_ex_is_div && !div_done;
    // [A1] 乘法器改成 II=1 流水线后【不再产生前端冻结】—— mul 只占 1 拍 EX，
    //   结果 2 拍后由 WB 级取走（`mem_wb_is_mul ? mul_result`）。停顿已收窄成
    //   "只有紧邻消费者停 1 拍"，那一条并进了上面的 `stall`（与 load-use 同一条路）。
    //   [!] 所以这里不再有 mul_stall；`mul_busy` / `mul_done` 保留端口但已无人使用。
    // 前端冻结判据只有这一根 —— 理由见文件顶部声明处的 [!]。
    // [A 扩展] AMO 是唯一的例外：它是【MEM 级】多拍单元，不能并进 mc_stall ——
    //   mc_stall 把 EX/MEM 清成气泡，而跑状态机的正是 EX/MEM 里那条 AMO。
    //   它改走 amo_hold / mem_ready_int（保持语义），见 amo_unit 例化处。
    assign      mc_stall   = div_stall;

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
    // [!] 2026-10-14（根因 #2 同族）：`mret` 的 CSR 副作用（mstatus.MIE ← MPIE）
    //     也必须与"这条指令离开 EX"同拍（= mem_ready_int）。冻结期间会重复施加，
    //     而第二次施加时 MPIE 已被写成 1，若原 MPIE=0 就会把 MIE 错误地置 1。
    //     重定向仍走 mret_commit（冻结时 fetch_addr 本来就退回 if_addr_d，等价）。
    wire        mret_commit_ex = mret_commit && mem_ready_int;
    assign      ex_target     = id_ex_mret   ? csr_mepc :
                                id_ex_jump_reg ? jalr_target : branch_target;

    // ---- EX 级：验证 ID 级的预测（预测器本身在 ID 级，EX 只做裁决） ----
    // 实际是否跳转。注意这与"是否冲刷"是两回事：预测正确时这里为 1 但不冲刷。
    wire ex_resolve_taken = (id_ex_branch && branch_taken) ||
                            id_ex_jump || id_ex_jump_reg || mret_commit;
    // [!] 2026-10-14（根因 #2 同族）：EX 的分支/跳转解析结果必须与"这条指令离开
    //     EX"同拍（= mem_ready_int）。AMO/LR/SC 占住 MEM 的 4 拍里，前递的
    //     amo_wb_data 还是【上一条】AMO 的陈旧值，紧跟其后的分支会据此解析出错误
    //     方向并拉高 ex_flush。而 ex_flush 在 fetch_addr 里的优先级【高于】冻结兜底，
    //     IF/ID 冲刷清空又没被门控 ⇒ 错误路径被取出并提交（tb_amo_cpu testnum 9 实测：
    //     连续第二条 sc.w 本应失败 a0=0，bnez a0 却用上一条 SC 的 1 解析成 taken，
    //     把取指拽到 fail_sc_noq 的 li gp,9 并提交）。
    //     门控后：冻结期 fetch_addr 退回 if_addr_d、IF/ID 保持；放开那拍再用【正确】
    //     的前递值重解析，方向因此总是对的。与 ID/EX 清、MEM/WB 捕获、mret CSR
    //     副作用（见各段）同一个门控，属同一族修复。
    // [B1-RAS/BTB / v10 §7] 预测【目标】校验：预测过（id_ex_pred_taken=1）但实际目标 != 预测目标
    //   ⇒ 冲刷纠正。这是 RAS（栈顶错）与 BTB（间接跳转目标错）的唯一纠错路径。
    //   [!] 校验只用 `rs1_val` 直比，**不经 ex_target** —— ex_target 的 32 位加法器
    //   是 fetch_addr 临界路径上最贵的一段（P&R 实测 rs1_val→ex_target ≈ 2 ns，
    //   且它下游还要串 comparator→ex_flush→fetch mux→imem_addr→imem_addr2→BRAM）。
    //   对 jalr：imm=0（ABI 约定）时 ex_target = (rs1_val+0)&~1 = rs1_val&~1，
    //   直接比 rs1_val&~1 逐位等价；imm≠0 的 `jalr x0,off(ra)` 极罕见，一律判错、冲刷
    //   （这样"猜错"最多与"不预测"同代价，不会更差）。
    //   [B1-BTB] 校验范围从"仅 ret（rd=x0）"放宽到【所有 jalr】—— BTB 预测的是非 ret 的
    //   间接跳转，同样要校验。安全性靠 `id_ex_pred_taken` 门控：没被预测的 jalr 恒不校验
    //   （走 ex_resolve_taken && !pred 那条原有冲刷）；branch/jal（id_ex_jump_reg=0）逐位不变。
    //   必须门控 mem_ready_int，与 ex_flush 的其它项同族。
    wire ex_is_jalr_ex = id_ex_jump_reg;
    wire ex_tgt_mm     = ex_is_jalr_ex && ((id_ex_imm != 32'd0) ||
                                           ((rs1_val & 32'hFFFF_FFFE) != id_ex_pred_target));
    wire ex_target_wrong = id_ex_pred_taken && ex_tgt_mm;
    // 预测 not-taken 但实际 taken  → 原有冲刷路径（含未被预测的 jalr）
    assign ex_flush   = (ex_resolve_taken && !id_ex_pred_taken && mem_ready_int) ||
                        (ex_target_wrong && mem_ready_int);
    // 预测 taken 但实际 not-taken  → 误判恢复：回到 fall-through
    assign ex_mispred = !ex_resolve_taken && id_ex_pred_taken && mem_ready_int;
    assign ex_mispred_target = id_ex_pc + 32'd4;

    // ---- BHT 训练（EX 级，用解析结果，与是否冲刷无关）----
    // 每条条件分支真正解析出方向后都要更新（预测对错都学）。未命中时【每个分支都分配】、
    // 按方向初始化计数器（taken→weakly taken，not-taken→weakly not-taken），这样后向
    // not-taken 分支也能学到（若只在 taken 时分配，这类分支永远分配不上）。预测表是纯
    // 建议性的：读写同拍无转发、读到旧值是允许的（最多一次误预测，被冲刷兜住）。
    wire [7:0] bht_idx_w = id_ex_pc[9:2];
    wire       bht_hit_w = bht_valid[bht_idx_w] && (bht_tag[bht_idx_w] == id_ex_pc[17:10]);
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
                bht_tag[bht_idx_w]   <= id_ex_pc[17:10];
                bht_ctr[bht_idx_w]   <= branch_taken ? 2'b10 : 2'b01;
            end
        end
    end

    // ================= [B1-RAS] EX 级 push/pop =================
    // 判定用【EX 级寄存器】id_ex_*（EX 级指令就是 ID/EX 里那条）：
    //   call = (jal | jalr) 且 rd∈{x1(ra),x5(t0)} —— 写链接寄存器的跳转即调用
    //   ret  = jalr 且 rd=x0 且 rs1∈{x1,x5}
    //   [P3a] lane B 现在可以是 **JAL**（只能是 jal：条件分支/jalr 还没放），
    //   所以 call 可能来自 lane B —— 见下面的 `ex_is_call_b`。
    //   只有【提交到 EX】的指令才更新栈：EX 是顺序的，能冲刷某条指令的只有比它更老、
    //   已在 EX 的分支/跳转；更年轻的指令在到达 EX 之前就被清 ⇒ 到达 EX = 在正确路径上
    //   ⇒ 无需影子栈/回滚。
    wire ex_is_call = (id_ex_jump || id_ex_jump_reg) &&
                      ((id_ex_rd == 5'd1) || (id_ex_rd == 5'd5));
    wire ex_is_ret  = id_ex_jump_reg && (id_ex_rd == 5'd0) &&
                      ((id_ex_rs1 == 5'd1) || (id_ex_rs1 == 5'd5));
    // [P3a] lane B 的 jal 也可能是 call（rd = ra/t0）。**必须一起压栈**：
    //   否则配进 lane B 的那批 call 之后，所有 ret 都会丢预测（EX 级冲刷 2~3 拍/次），
    //   足以把配对赚到的拍数吃回去。
    //   [!] 判据用 `wb_sel==2'b10` + rd∈{1,5}：wb_sel=2'b10 只有 jal/jalr 两种，
    //   而 P3a 的 lane B 只可能是 jal ⇒ 不会误判。**不能**照 lane A 那样用
    //   `id_ex_b_jump` —— 这个标志没进 ID/EX 寄存器（lane B 只带 ALU/访存/wb 字段）。
    //   [!] 同拍 A、B 都是 call 时**只压 A**（栈只有一个写口）。丢一次压栈只影响
    //   预测率、不影响正确性：RAS 是纯预测器，EX 级 §7 目标校验永远兜底。
    //   [!] `&& !ex_flush`：lane A 冲刷那拍 lane B 一起被杀（EX/MEM 的
    //   `ex_mem_b_reg_write && !ex_flush` 同款），被杀的 call 不得压栈。
    wire ex_is_call_b = id_ex_b_valid && id_ex_b_reg_write && !ex_flush &&
                        (id_ex_b_wb_sel == 2'b10) &&
                        ((id_ex_b_rd == 5'd1) || (id_ex_b_rd == 5'd5));
    // [!] 更新必须与"这条指令离开 EX / 提交到 EX/MEM"同拍 = mem_ready_int && !mc_stall && !trap。
    //   门控 mem_ready_int 是硬要求：冻结期 ID/EX【保持】，不门控会把同一条 call/ret 每拍
    //   重复 push/pop（与根因 #1/#2 同族）。mc_stall 期 ID/EX 保持、EX/MEM 被清 ⇒ 不计提交；
    //   trap 杀该指令 ⇒ 不计。push 写返回地址 = 该 call 的下一条（id_ex_pc+4）。
    wire ras_upd_en = mem_ready_int && !mc_stall && !trap;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ras_sp <= 5'd0;
        end else if (ras_upd_en) begin
            if (ex_is_call && (ras_sp != RAS_DEPTH)) begin   // 满则饱和丢弃（罕见，只影响预测率）
                ras_mem[ras_sp[3:0]] <= id_ex_pc + 32'd4;
                ras_sp               <= ras_sp + 5'd1;
            end else if (ex_is_call_b && (ras_sp != RAS_DEPTH)) begin   // [P3a] lane B 的 call
                ras_mem[ras_sp[3:0]] <= id_ex_b_pc + 32'd4;
                ras_sp               <= ras_sp + 5'd1;
            end else if (ex_is_ret && !ras_empty) begin
                ras_sp <= ras_sp - 5'd1;
            end
        end
    end

    // ================= [B1-BTB] EX 级训练 =================
    // 每条【间接跳转 jalr】在 EX 解析出真实目标 jalr_target=(rs1_val+imm)&~1 后，
    // 把该 PC 的目标写进表：下次这条 jalr 在到达级就能被预测（省下"到 EX 才知道目标"的拍数）。
    // 存 ret 的目标也行（RAS 空时由 BTB 兜底）；同一 PC 多目标时条目抖动 → 预测错 → §7 纠正。
    // 与 BHT 训练同构：读写同拍读到旧值可接受，最多一次误预测，被 §7/ex_flush 兜住。
    // 门控与 RAS 同（= 该指令【提交到 EX】那拍）：mem_ready_int && !mc_stall && !trap。
    //   冻结期 ID/EX 保持 ⇒ 不门控会每拍重复训练（与根因 #1/#2 同族）。
    wire       btb_upd_en = (BTB_EN != 0) && mem_ready_int && !mc_stall && !trap && id_ex_jump_reg;
    wire [4:0] btb_idx_w  = id_ex_pc[6:2];
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            btb_valid <= 32'd0;
        end else if (btb_upd_en) begin
            btb_valid[btb_idx_w]  <= 1'b1;
            btb_tag[btb_idx_w]    <= id_ex_pc[31:8];
            btb_target[btb_idx_w] <= jalr_target;    // 实际目标（含 ret；RAS 空时兜底）
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
    // [lane B 访存] lane B 的 load 未对齐判据：地址 = alu_result_b（control_b 译 load
    //   恒 alu_op=ADD / alu_b_sel=1 ⇒ rs1+imm）。LB/LBU 任意地址合法；LH/LHU 要求
    //   addr[0]==0；LW 要求 addr[1:0]==00（与 lane A 同一套编码，funct3[1:0]）。
    //   LANEB_MEM=0 时 id_ex_b_mem_read 恒 0 ⇒ 本信号恒 0，ex_exception/exc_cause/
    //   exc_tval/trap_pc 全部逐位回退基线行为。
    //   [!] 时序门控（2026-10-16 rev1024 时序回归修复，任务书
    //   `2026-10-16_laneb_timing_fix_taskbook.md` §4-1）：必须显式带
    //   `(LANEB_MEM != 0)`。功能上 0 档本信号已恒 0，但综合器证明不了 ——
    //   b_mem_unaligned 背后的 alu_result_b 是 32 位加法器 cone，它喂
    //   load_misaligned_b → ex_exception → trap → fetch_addr 的【最高优先级
    //   mux 腿】（core.v 预警的"Fmax 第一风险点"）。实测该 cone 被并进
    //   if_addr_d 的关键 LUT，CPU 域余量 +0.330 → −0.165 ns。门控后 0 档
    //   折成常量、整条 cone 被删 ⇒ 逐位恢复 rev1023 网表与时序；1 档语义不变。
    //   [!] lane B 是 load 时 lane A 只可能是 ALU/branch/jal/jalr/CSR/SYSTEM
    //   （pair_now 排掉 p_mem_a）—— 这些在"先陷异常、mret 后整对重放"下都幂等，
    //   安全性论证见 EX/MEM 段 lane B 锁存处的注释。
    //   [P3.5 2026-10-16] 未对齐判定只用到地址低 2 位 ⇒ 改用 2 位窄加法，
    //   把 32 位 `alu_result_b` 加法器锥从取指路径上摘掉（P3 的 PDS 关键路径 16 级：
    //   vid_rdata → wb_data_b → b_alu_a → u_alu_b(32 位加法器) → alu_result_b[0]
    //   → load_misaligned_b → if_addr_d → imem_addr → imem_addr2 → BRAM）。
    //   等价性（严格）：OP_LOAD 的译码是 alu_a_sel=0 / alu_b_sel=1 / alu_op=ADD
    //   （control.v 的 OP_LOAD 分支不写 alu_op，取 always 块默认值 5'd0）
    //   ⇒ b_alu_a=rs1_val_b、b_alu_b=id_ex_b_imm ⇒ alu_result_b ≡ rs1_val_b+id_ex_b_imm；
    //   低 2 位模 4 加法与全 32 位加法逐位相同（进位不跨出 bit1）。
    //   且 b_mem_unaligned 只经 load_misaligned_b（已 AND id_ex_b_mem_read）被使用
    //   ⇒ 只在 lane B 是 load 时有意义，替换不改变任何可观测行为。
    //   [!] 下方 exc_tval 仍用全 32 位 alu_result_b：它进 CSR 寄存器，不在取指路径。
    wire [1:0] b_addr_low = rs1_val_b[1:0] + id_ex_b_imm[1:0];
    wire b_mem_unaligned = (id_ex_b_funct3[1:0] == 2'b01) ? b_addr_low[0] :
                           (id_ex_b_funct3[1:0] == 2'b10) ? |b_addr_low : 1'b0;
    wire load_misaligned_b = (LANEB_MEM != 0) && id_ex_b_mem_read && b_mem_unaligned;

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
    // [!] 2026-10-14 修复（Cache + RT-Thread 挂死【根因 #2】）—— 必须再与
    //     `mem_ready_int` 相与，理由和 ID/EX、EX/MEM、乘法器（约定 51）同源：
    //
    //   CSR 写在【EX 级提交】（约定 21），而"这条指令离开 EX"这件事发生在
    //   `mem_ready_int=1` 的那个沿（EX/MEM <= ID/EX 就是同一个条件）。
    //   不门控时，访存冻结那一拍 CSR 就已经被写进去了，而 ID/EX【保持不动】
    //   （约定 56 的修复正是让它在冻结期间保持）⇒ 同一沿 `alu_result` 里的
    //   `csr_rdata` 已经是【写后】的值，下一拍冻结放开时 EX/MEM 收下的就是它
    //   —— 于是 `csrrw rd, csr, rs1` 的 rd 读到【新值】而不是规范要求的旧值。
    //
    //   实测（根因 #2，`scripts\rtthread\run_sim.ps1 -ICache`）：RT-Thread 的
    //   中断入口/出口各有一条 `csrrw sp, mscratch, sp`（interrupt_gcc.S:101/109），
    //   rd 就是 sp —— 冻结撞上它时 sp【没被切到中断栈】，中断处理函数于是跑在
    //   线程栈上；出口那条再把 mscratch 写坏 ⇒ 之后每次中断的 sp 都在漂移，
    //   最终把内核链表（_timer_remove 的 next 指针）踩坏 → cause=6 死循环转储。
    //   判据：无 Cache 时 mem_ready_int 恒 1 ⇒ 逐位不变（CoreMark/riscv-tests 全不受影响）。
    assign csr_wr_en = csr_wr_en_raw && !trap && mem_ready_int;

    // ---- 同步异常 ----
    // 判据之间天然互斥（非法指令的 mem_read/mem_write 必为 0，ecall/ebreak 同理），
    // 所以下面的优先级只为把编码写清楚，不承担正确性。
    // [!] 必须用 csr_wr_en_raw（"这条指令真的在写吗"），不能用 csr_wr_illegal 单独判断。
    //    csr_wr_illegal 只看地址是不是只读区，而【只读 CSR 是可以读的】——
    //    `csrr a0, mhartid` 是 RS 且 rs1=x0，根本不写，却被判成非法指令，
    //    导致 riscv-tests 的 init 段每轮都 trap → 重启 → 50 个测试全 TIMEOUT。
    //    也不能用 csr_wr_en（它含 !trap），否则 trap ← ex_exception ← csr_wr_en ← trap 成环。
    wire exc_illegal = id_ex_illegal || (csr_wr_en_raw && csr_wr_illegal);
    // lane A（更老）的同步异常集合
    wire ex_exception_a = exc_illegal || id_ex_sys_ecall || id_ex_sys_ebreak ||
                          load_misaligned || store_misaligned;
    assign ex_exception = ex_exception_a || load_misaligned_b;
    wire [31:0] exc_cause = exc_illegal       ? 32'd2  :   // Illegal instruction
                            id_ex_sys_ecall   ? 32'd11 :   // Environment call from M
                            id_ex_sys_ebreak  ? 32'd3  :   // Breakpoint
                            load_misaligned   ? 32'd4  :   // Load addr misaligned
                            store_misaligned  ? 32'd6  :   // Store addr misaligned
                            load_misaligned_b ? 32'd4  :   // [lane B] Load addr misaligned
                                                32'd0;
    // mtval：未对齐给出错地址；非法指令给 0 —— 规范允许 0 或指令本身，
    // 本设计取 0 以免把整条指令再多带一级流水线寄存器。其余为 0。
    wire [31:0] exc_tval = (load_misaligned || store_misaligned) ? addr_result :
                           load_misaligned_b                    ? alu_result_b : 32'd0;
    // [lane B 访存] trap 的肇事指令按【最老】选：lane A 有异常 ⇒ 仍是 lane A；
    //   只有"lane B 的未对齐 load 是唯一肇事者"时，mepc 才取 lane B 的 PC。
    //   [!] 中断（int_take）没有同步异常 ⇒ trap_from_b 恒 0 ⇒ mepc 恒取 lane A 的
    //   id_ex_pc（中断恢复点必须是 EX 里那条指令，与 lane B 是谁无关）。
    //   ⇒ LANEB_MEM=0 时 trap_pc 恒等于 id_ex_pc，与基线逐位相同。
    wire trap_from_b  = load_misaligned_b && !ex_exception_a;
    wire [31:0] trap_pc = trap_from_b ? id_ex_b_pc : id_ex_pc;

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
        .trap_pc    (trap_pc),      // [lane B 访存] 唯一肇事者是 lane B 的未对齐 load 时取 id_ex_b_pc
        .trap_cause (trap_cause),
        .trap_tval  (trap_tval),
        .mret       (mret_commit_ex),
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
    // [任务 C] 快通路 load 的数据【也走这个寄存器】：它在自己 MEM→WB 那个沿就抓进来，
    //   于是 WB 段的 load_src 表达式与基线【逐字相同】，不需要再为它加一级 mux。
    //   这条链（BRAM 出 → load_data → wb_data → 前递 → 分支 → 重定向 → 取指地址）
    //   本身就是时序敏感路径，**每一级都贵**（2026-10-11 综合实测：加那一级 mux 时
    //   它一度成为 CPU 域最差路径）。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            wb_rdata_snap    <= 32'd0;
            wb_rdata_snap_en <= 1'b0;
        end else if (mem_ready_int && ex_mem_ld_fast) begin
            // 快通路 load 的 MEM→WB 沿：它自己的数据在 ld_early_data 上（原始字）
            wb_rdata_snap    <= ld_early_data;
            wb_rdata_snap_en <= 1'b1;
        end else if (mem_ready_int) begin
            wb_rdata_snap_en <= 1'b0;          // WB 正常推进：下条指令用实时 mem_rdata
        end else if (!wb_rdata_snap_en) begin  // 停顿第一个沿：抓一次（此后实时值已失效）
            // [!] 只能取 mem_rdata。冻在 MEM/WB 的指令若需要本快照，它一定是
            //     【普通 load】—— 快通路 load 在它自己的前进沿已被上面第一支抓过
            //     （snap_en=1），走不到本支。
            //     历史上这里写成 `ex_mem_ld_fast ? ld_early_data : mem_rdata`，
            //     用【EX/MEM 级】指令的信号选源，而本快照服务的是【MEM/WB 级】
            //     指令：I-Cache 缺失冻结下实测——普通 load 冻在 WB、快通路 load
            //     占着 EX/MEM 时，抓到的是后者的提前读数据（2026-10-12：
            //     `lw s2,36(sp)` 写回了下一条 `lw s1,40(sp)` 的值，CoreMark
            //     跑几万拍后 trap，riscv-tests 因代码短碰不到）。
            wb_rdata_snap    <= mem_rdata;
            wb_rdata_snap_en <= 1'b1;
        end
    end
    // [任务 C] 快通路 load 的原始字由 wb_rdata_snap 在它的 MEM→WB 沿抓下（见上），
    //   所以这一行与基线【逐字相同】—— 快通路没给这条链加任何一级。
    wire [31:0] load_src = wb_rdata_snap_en ? wb_rdata_snap : mem_rdata;
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
    assign wb_data = mem_wb_is_mul      ? mul_result :        // [A1] 流水线乘法器的结果
                     mem_wb_is_amo      ? amo_wb_data :
                     (mem_wb_wb_sel == 2'b01) ? load_data :
                     (mem_wb_wb_sel == 2'b10) ? (mem_wb_pc + 32'd4) :
                     (mem_wb_wb_sel == 2'b11) ? mem_wb_imm :
                     mem_wb_alu_result;

    // [lane B 访存] lane B 的 load 解包：与 lane A 完全同构，但用 mem_wb_b_* 的
    //   funct3 / addr_low。[!] 数据源复用【同一份】load_src（= wb_rdata_snap 或
    //   mem_rdata）："每对最多一条访存" ⇒ 任一拍至多一条 load 在途 ⇒ mem_rdata
    //   至多一个消费者，不需要第二份快照、第二根链（任务书 §2 的承重结论：
    //   core.v 早年"load_src 与基线逐字相同、不给这条链加级"才得以保持）。
    //   解包逻辑【并行】另起一份，不串在 lane A 的 load_data 前面 —— 那条链
    //   (BRAM→load_src→load_data→wb_data→前递→分支→取指) 是时序敏感路径，
    //   每一级都贵（2026-10-11 综合实测）。
    wire [7:0]  load_byte_b = (mem_wb_b_addr_low == 2'd0) ? load_src[7:0]   :
                              (mem_wb_b_addr_low == 2'd1) ? load_src[15:8]  :
                              (mem_wb_b_addr_low == 2'd2) ? load_src[23:16] :
                                                            load_src[31:24];
    wire [15:0] load_half_b = mem_wb_b_addr_low[1] ? load_src[31:16] : load_src[15:0];
    wire [31:0] load_data_b =
        (mem_wb_b_funct3 == 3'b000) ? {{24{load_byte_b[7]}}, load_byte_b} : // LB
        (mem_wb_b_funct3 == 3'b001) ? {{16{load_half_b[15]}}, load_half_b} : // LH
        (mem_wb_b_funct3 == 3'b100) ? {24'd0, load_byte_b} :                // LBU
        (mem_wb_b_funct3 == 3'b101) ? {16'd0, load_half_b} :                // LHU
        load_src;                                                           // LW

    // lane B 写回数据（LANEB_MEM=1 时多一路 load 解包；=0 时 lane B 不可能是
    // load ⇒ wb_sel_b 恒不为 01，与基线逐位相同）
    // [!] 时序门控（2026-10-16，任务书 §4-7）：load 腿再带 `&& (LANEB_MEM != 0)`。
    //   load_data_b 是并行解包逻辑（字节选择 + 符号扩展），0 档综合器证明不了
    //   wb_sel_b 恒不为 01 ⇒ 会把整份解包 mux 树建出来挂在写回/前递路径上。
    //   门控后 0 档折成常量、整棵树被删 ⇒ 恢复 rev1023 网表；1 档语义不变。
    assign wb_data_b = ((mem_wb_b_wb_sel == 2'b01) && (LANEB_MEM != 0)) ? load_data_b :
                       (mem_wb_b_wb_sel == 2'b10) ? (mem_wb_b_pc + 32'd4) :
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
    // fetch_addr 的 mux 把取指地址【退回 if_addr_d[16:2]】—— 也就是重读上一拍
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
            if_id_pred_target <= 32'd0;
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
            if_id_pred_target <= 32'd0;
        end else if (!stall_int && !mc_stall && mem_ready_int) begin
            if_id_valid <= (imem_rd != 32'd0);
            if_id_pc    <= if_addr_d;
            if_id_instr <= imem_rd;
            // lane B 与 lane A 同拍锁存，pc 恒为 lane A 的 +4（A2 口取的就是这个字）
            // pair_now 就是这一对 (imem_rd, imem_rd2) 的发射判定 —— 同拍寄存。
            if_id_pair    <= pair_now;
            if_id_pred_taken <= p_redirect;
            if_id_pred_target <= p_target;   // [B1-RAS] 与 pred_taken 同拍锁存预测目标
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
    // [!] 2026-10-14 修复（Cache + RT-Thread 挂死的根因）—— 清 ID/EX 必须像
    //     EX/MEM（见下面的 A.0 修复）一样【门控 mem_ready_int】，且 trap 保持无条件：
    //
    //   `ex_flush` / `ex_mispred` / `stall_int` 都是【EX 里那条指令自己】发出的
    //   （jal/jalr/分支 / load-use）。流水线被访存停顿冻结（mem_ready_int=0）时，
    //   整条流水线不能平移 —— ID/EX 里躺着的就是那条发冲刷的指令【本身】。
    //   这时清 ID/EX = 把它自己杀掉 ⇒ 它进不了 EX/MEM ⇒ 它的寄存器写回（jal/jalr
    //   的链接值 ra）【永久丢失】。EX/MEM 侧有同样的门控（A.0 修复），ID/EX 侧漏了。
    //
    //   实测（cmd：scripts\rtthread\run_sim.ps1 -ICache；冷启动取指几乎每拍缺失、
    //   mem_ready 0/1 交替 ⇒ 撞上概率≈1）：`_start` 里 0x2ac 的 `jalr -1956(ra)`
    //   在 EX 发 ex_flush 的那拍正好 mem_ready=0 ⇒ 它被清掉 ⇒ ra 只剩前一条
    //   `auipc ra,0x7` 写的 0x72a8 ⇒ 0x6b08 的 `ret` 跳回 0x72a8 ⇒ 执行流跑飞、
    //   55360 拍挂死（仿真与板上逐字节一致：只剩 13 字节 ` turn=WHITE`）。
    //   无 Cache 时 mem_ready_int=0 只在真访存停顿出现，撞上跳转解析那拍的概率极低
    //   ⇒ CoreMark（无 trap、冷启动命中率高）与 riscv-tests 一直看不出来。
    //
    //   为什么 trap 不门控：肇事指令【必须】死（约定 20：不得产生副作用）；冻结
    //   期间清掉它、放开后 EX/MEM <= 气泡，与当场清等价（同 A.0 注释的推理）。
    //   pair / ex_flush 那条 lane B 抑制（见 EX/MEM 段）不受影响。
    always @(posedge clk or negedge resetn) begin
        if (!resetn || trap || ((ex_flush || ex_mispred || stall_int) && mem_ready_int)) begin
            id_ex_reg_write <= 1'b0;
            id_ex_alu_a_sel <= 1'b0;
            id_ex_alu_b_sel <= 1'b0;
            id_ex_mem_read  <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_branch    <= 1'b0;
            id_ex_jump      <= 1'b0;
            id_ex_jump_reg  <= 1'b0;
            id_ex_pred_taken <= 1'b0;
            id_ex_pred_target <= 32'd0;
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
            // [lane B 访存] 新字段在【每一个清分支】都必须出现（任务书 §7 R4：
            // 漏一处 = 气泡里残留 load 标志 = 静默错）
            id_ex_b_mem_read  <= 1'b0;
            id_ex_b_funct3    <= 3'd0;
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
            id_ex_pred_target <= if_id_pred_target;   // [B1-RAS] 预测目标随指令带到 EX 供校验
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
            id_ex_is_amo     <= id_is_amo_g;
            id_ex_amo_funct5 <= id_amo_funct5;
            id_ex_illegal   <= id_illegal_g;
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
            // [lane B 访存] mem_read 用 if_id_pair 门控（与 reg_write 等同款约定）：
            // 未配对时 lane B 是气泡，mem_read 必须为 0 —— 否则 load-use 停顿、
            // 未对齐异常、访存口都会被一条不存在的 load 触发。
            // funct3 直传（与 lane A 的 id_ex_funct3 同款）：只在 mem_read=1 时被消费。
            id_ex_b_mem_read  <= if_id_pair ? mem_read_b : 1'b0;
            id_ex_b_funct3    <= if_id_instr_b[14:12];
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
            ex_mem_is_mul     <= 1'b0;      // [A1]
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
            // [lane B 访存] 新字段在清分支一并清（R4）
            ex_mem_b_mem_read   <= 1'b0;
            ex_mem_b_funct3     <= 3'd0;
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
            ex_mem_is_mul     <= id_ex_is_mul;      // [A1]
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
            // [lane B 访存] [!] mem_read 【不】加 `&& !ex_flush` —— 承重（R6）：
            //   "ex_flush 拍 lane B 不得驱动访存口"由 ex_mem_b_valid 的
            //   `&& !ex_flush`（上面两行）保证，b_mem_sel 看的是 valid。
            //   read 本身保持直传：与 lane A 的 ex_mem_mem_read 同一约定
            //   （它也没有 !ex_flush —— ex_flush 由 lane A 自己的分支/跳转发出，
            //   那条指令的 mem_read 恒 0，从来不需要这个门控）。
            //   若将来有人"为了对称"给这里补 !ex_flush，就会连带以为 valid 的
            //   门控冗余而把它去掉 —— 那时幽灵读立刻回来，故注释在此承重。
            ex_mem_b_mem_read   <= id_ex_b_mem_read;
            ex_mem_b_funct3     <= id_ex_b_funct3;
        end
    end

    // [lane B 访存] 为什么"lane B 的未对齐 load 陷异常、mepc 取 id_ex_b_pc、
    //   lane A 被杀死后随 mret 重放"是安全的（任务书 §4H，必须写进注释）：
    //   1. "每对最多一条访存"且 lane B 是 load ⇒ lane A 只可能是
    //      ALU / branch / jal / jalr / CSR / SYSTEM（pair_now 排掉 p_mem_a）；
    //   2. 这些在"先陷异常、后重放"下都幂等：ALU 重算同值；分支/jal/jalr 重放
    //      走同一条路径（写 rd 同值）；CSR 的 RW/RS/RC 也幂等；
    //   3. 唯一不显然的 csrrw 被 `csr_wr_en = csr_wr_en_raw && !trap &&
    //      mem_ready_int` 救掉 —— lane B 的异常并进 trap 后，lane A 那拍不写
    //      CSR，重放时读到旧值，rd 正确（这正是 2026-10-14 根因 #2 修复的副产品）；
    //   4. mret 同理被 `mret_commit = id_ex_mret && !trap` 抑制；
    //   5. lane B 的错【不会真写内存】：它还在 EX（未对齐判据在 EX 级），trap 清
    //      ID/EX ⇒ 下一拍进不了 EX/MEM，读口从未被它驱动（b_mem_sel 要
    //      ex_mem_b_valid，而它已含 !ex_flush；trap 时 ID/EX 直接被清）。

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
            mem_wb_is_mul     <= 1'b0;      // [A1]
            mem_wb_addr_low   <= 2'd0;
            mem_wb_b_reg_write  <= 1'b0;
            mem_wb_b_wb_sel     <= 2'b00;
            mem_wb_b_alu_result <= 32'd0;
            mem_wb_b_pc         <= 32'd0;
            mem_wb_b_imm        <= 32'd0;
            mem_wb_b_rd         <= 5'd0;
            // [lane B 访存] WB 级 load 解包字段的复位值（R4：复位分支也要有）
            mem_wb_b_funct3     <= 3'd0;
            mem_wb_b_addr_low   <= 2'd0;
        end else if (mem_ready_int) begin
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_wb_sel     <= ex_mem_wb_sel;
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_pc         <= ex_mem_pc;
            mem_wb_imm        <= ex_mem_imm;
            mem_wb_rd         <= ex_mem_rd;
            mem_wb_funct3     <= ex_mem_funct3;
            mem_wb_is_amo     <= ex_mem_is_amo;
            mem_wb_is_mul     <= ex_mem_is_mul;     // [A1]
            mem_wb_addr_low   <= ex_mem_alu_result[1:0];
            mem_wb_b_reg_write  <= ex_mem_b_reg_write;
            mem_wb_b_wb_sel     <= ex_mem_b_wb_sel;
            mem_wb_b_alu_result <= ex_mem_b_alu_result;
            mem_wb_b_pc         <= ex_mem_b_pc;
            mem_wb_b_imm        <= ex_mem_b_imm;
            mem_wb_b_rd         <= ex_mem_b_rd;
            // [lane B 访存] WB 级 load 解包字段（地址低两位取自 ex_mem_b_alu_result
            // = lane B load 的 base+offset，与 lane A 的 mem_wb_addr_low 同源同款）
            mem_wb_b_funct3     <= ex_mem_b_funct3;
            mem_wb_b_addr_low   <= ex_mem_b_alu_result[1:0];
        end
    end

    // [!] 上面 MEM/WB 那处是 mem_ready=0 时唯一【必须】门控的地方：
    //     不门控的话，被停住的那条 load 会带着还没回来的 mem_rdata 提前写回。
    //     EX/MEM 走的是 mem_ready_int：常态下与 mem_ready 逐位相同，只在 AMO
    //     占 MEM 期间多出一个 0 —— 那时它必须【保持】AMO，绝不能推进成气泡。

endmodule
