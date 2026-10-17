/* ============================================================================
 * ila_probes.vh —— ILA 硬件在环探针束（供 Pango Fabric Inserter 用）
 *
 * [!] 本文件【默认不被 core.v 包含】。抓 ILA 波形时：
 *      1) 在 rtl/core/core.v 末尾（endmodule 之前）加一行：
 *             `include "ila_probes.vh"
 *      2) 综合 → Fabric Inserter 生成 .fic → 登记进 .pds → P&R 出调试位流
 *      3) 采完【必须】把那行删掉、重出生产位流（探针会改净表 ⇒ 钉住的
 *         gplace_seed 5 余量作废，见 2026-10-16_a1_laneb_store.md §6）
 *
 * 通道分配见 doc/ila_analysis.md §7.1（本文按 rev1027 更新：BHT 信号改名为
 * bht_hit_p / bht_taken_p / p_pred_taken / p_redirect，并新增 lane B 与 RAS/BTB）
 *
 * [重点] 三个承重约束（踩过）：
 *   - 约定 30：属性必须挂在【声明】上、且在【分号之前】；syn_keep 与
 *     PAP_MARK_DEBUG 两个都要写（前者防优化，后者才让 Inserter 列出来）
 *   - 约定 31：**多比特 wire 上的 PAP_MARK_DEBUG 会被综合整条丢弃**
 *     ⇒ PC/opcode 这类总线必须【拆成一根一根的单 bit wire】
 *   - 约定 32：Inserter 的网线树【不列出模块端口】⇒ 探针要指向【内部 wire】
 *     的别名，不能直接标端口
 *============================================================================ */

/* 通道位 -> 信号（按 doc/ila_analysis.md §7.1 的顺序） */

// ---- pc[14:0]  [0:14]  取指 PC（网表里叫 pc，不是 pc_r） ----
wire ila_pc_0                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<0>" */ = pc[0];
wire ila_pc_1                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<1>" */ = pc[1];
wire ila_pc_2                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<2>" */ = pc[2];
wire ila_pc_3                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<3>" */ = pc[3];
wire ila_pc_4                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<4>" */ = pc[4];
wire ila_pc_5                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<5>" */ = pc[5];
wire ila_pc_6                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<6>" */ = pc[6];
wire ila_pc_7                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<7>" */ = pc[7];
wire ila_pc_8                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<8>" */ = pc[8];
wire ila_pc_9                       /* synthesis syn_keep=1, PAP_MARK_DEBUG="<9>" */ = pc[9];
wire ila_pc_10                      /* synthesis syn_keep=1, PAP_MARK_DEBUG="<10>" */ = pc[10];
wire ila_pc_11                      /* synthesis syn_keep=1, PAP_MARK_DEBUG="<11>" */ = pc[11];
wire ila_pc_12                      /* synthesis syn_keep=1, PAP_MARK_DEBUG="<12>" */ = pc[12];
wire ila_pc_13                      /* synthesis syn_keep=1, PAP_MARK_DEBUG="<13>" */ = pc[13];
wire ila_pc_14                      /* synthesis syn_keep=1, PAP_MARK_DEBUG="<14>" */ = pc[14];

// ---- if_id_pc[14:0]  [15:29]  ID 级 PC ----
wire ila_if_id_pc_0                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<15>" */ = if_id_pc[0];
wire ila_if_id_pc_1                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<16>" */ = if_id_pc[1];
wire ila_if_id_pc_2                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<17>" */ = if_id_pc[2];
wire ila_if_id_pc_3                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<18>" */ = if_id_pc[3];
wire ila_if_id_pc_4                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<19>" */ = if_id_pc[4];
wire ila_if_id_pc_5                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<20>" */ = if_id_pc[5];
wire ila_if_id_pc_6                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<21>" */ = if_id_pc[6];
wire ila_if_id_pc_7                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<22>" */ = if_id_pc[7];
wire ila_if_id_pc_8                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<23>" */ = if_id_pc[8];
wire ila_if_id_pc_9                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<24>" */ = if_id_pc[9];
wire ila_if_id_pc_10                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<25>" */ = if_id_pc[10];
wire ila_if_id_pc_11                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<26>" */ = if_id_pc[11];
wire ila_if_id_pc_12                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<27>" */ = if_id_pc[12];
wire ila_if_id_pc_13                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<28>" */ = if_id_pc[13];
wire ila_if_id_pc_14                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<29>" */ = if_id_pc[14];

// ---- id_ex_pc[14:0]  [30:44]  EX 级 PC ----
wire ila_id_ex_pc_0                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<30>" */ = id_ex_pc[0];
wire ila_id_ex_pc_1                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<31>" */ = id_ex_pc[1];
wire ila_id_ex_pc_2                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<32>" */ = id_ex_pc[2];
wire ila_id_ex_pc_3                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<33>" */ = id_ex_pc[3];
wire ila_id_ex_pc_4                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<34>" */ = id_ex_pc[4];
wire ila_id_ex_pc_5                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<35>" */ = id_ex_pc[5];
wire ila_id_ex_pc_6                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<36>" */ = id_ex_pc[6];
wire ila_id_ex_pc_7                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<37>" */ = id_ex_pc[7];
wire ila_id_ex_pc_8                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<38>" */ = id_ex_pc[8];
wire ila_id_ex_pc_9                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<39>" */ = id_ex_pc[9];
wire ila_id_ex_pc_10                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<40>" */ = id_ex_pc[10];
wire ila_id_ex_pc_11                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<41>" */ = id_ex_pc[11];
wire ila_id_ex_pc_12                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<42>" */ = id_ex_pc[12];
wire ila_id_ex_pc_13                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<43>" */ = id_ex_pc[13];
wire ila_id_ex_pc_14                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<44>" */ = id_ex_pc[14];

// ---- ex_mem_pc[14:0]  [45:59]  MEM 级 PC ----
wire ila_ex_mem_pc_0                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<45>" */ = ex_mem_pc[0];
wire ila_ex_mem_pc_1                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<46>" */ = ex_mem_pc[1];
wire ila_ex_mem_pc_2                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<47>" */ = ex_mem_pc[2];
wire ila_ex_mem_pc_3                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<48>" */ = ex_mem_pc[3];
wire ila_ex_mem_pc_4                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<49>" */ = ex_mem_pc[4];
wire ila_ex_mem_pc_5                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<50>" */ = ex_mem_pc[5];
wire ila_ex_mem_pc_6                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<51>" */ = ex_mem_pc[6];
wire ila_ex_mem_pc_7                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<52>" */ = ex_mem_pc[7];
wire ila_ex_mem_pc_8                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<53>" */ = ex_mem_pc[8];
wire ila_ex_mem_pc_9                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<54>" */ = ex_mem_pc[9];
wire ila_ex_mem_pc_10               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<55>" */ = ex_mem_pc[10];
wire ila_ex_mem_pc_11               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<56>" */ = ex_mem_pc[11];
wire ila_ex_mem_pc_12               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<57>" */ = ex_mem_pc[12];
wire ila_ex_mem_pc_13               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<58>" */ = ex_mem_pc[13];
wire ila_ex_mem_pc_14               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<59>" */ = ex_mem_pc[14];

// ---- if_id_instr[6:0]  [60:66]  只取 opcode[6:0] ----
wire ila_if_id_instr_0              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<60>" */ = if_id_instr[0];
wire ila_if_id_instr_1              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<61>" */ = if_id_instr[1];
wire ila_if_id_instr_2              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<62>" */ = if_id_instr[2];
wire ila_if_id_instr_3              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<63>" */ = if_id_instr[3];
wire ila_if_id_instr_4              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<64>" */ = if_id_instr[4];
wire ila_if_id_instr_5              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<65>" */ = if_id_instr[5];
wire ila_if_id_instr_6              /* synthesis syn_keep=1, PAP_MARK_DEBUG="<66>" */ = if_id_instr[6];
wire ila_stall                      /* synthesis syn_keep=1, PAP_MARK_DEBUG="<67>" */ = stall;   // [67] load-use 停顿
wire ila_div_stall                  /* synthesis syn_keep=1, PAP_MARK_DEBUG="<68>" */ = div_stall;   // [68] 多拍除法停顿
wire ila_ex_flush                   /* synthesis syn_keep=1, PAP_MARK_DEBUG="<69>" */ = ex_flush;   // [69] 冲刷（首推触发信号）
wire ila_id_ex_mem_read             /* synthesis syn_keep=1, PAP_MARK_DEBUG="<70>" */ = id_ex_mem_read;   // [70] EX 级是 load
wire ila_fwd_a_ex                   /* synthesis syn_keep=1, PAP_MARK_DEBUG="<71>" */ = fwd_a_ex;   // [71] EX/MEM 前递 rs1
wire ila_fwd_b_ex                   /* synthesis syn_keep=1, PAP_MARK_DEBUG="<72>" */ = fwd_b_ex;   // [72] EX/MEM 前递 rs2
wire ila_fwd_a_wb                   /* synthesis syn_keep=1, PAP_MARK_DEBUG="<73>" */ = fwd_a_wb;   // [73] MEM/WB 前递 rs1
wire ila_fwd_b_wb                   /* synthesis syn_keep=1, PAP_MARK_DEBUG="<74>" */ = fwd_b_wb;   // [74] MEM/WB 前递 rs2
wire ila_id_ex_branch               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<75>" */ = id_ex_branch;   // [75] EX 级是分支
wire ila_branch_taken               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<76>" */ = branch_taken;   // [76] 分支条件结果
wire ila_mem_we                     /* synthesis syn_keep=1, PAP_MARK_DEBUG="<77>" */ = mem_we;   // [77] 访存写使能
wire ila_mem_re                     /* synthesis syn_keep=1, PAP_MARK_DEBUG="<78>" */ = mem_re;   // [78] 访存读使能
wire ila_mem_wb_reg_write           /* synthesis syn_keep=1, PAP_MARK_DEBUG="<79>" */ = mem_wb_reg_write;   // [79] WB 回写
wire ila_bht_hit_p                  /* synthesis syn_keep=1, PAP_MARK_DEBUG="<80>" */ = bht_hit_p;   // [80] BHT 命中
wire ila_bht_taken_p                /* synthesis syn_keep=1, PAP_MARK_DEBUG="<81>" */ = bht_taken_p;   // [81] BHT 预测方向
wire ila_p_pred_taken               /* synthesis syn_keep=1, PAP_MARK_DEBUG="<82>" */ = p_pred_taken;   // [82] 到达级预测结果（跳/不跳）
wire ila_p_redirect                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<83>" */ = p_redirect;   // [83] 到达级实际生效的重定向
wire ila_ex_mispred                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<84>" */ = ex_mispred;   // [84] 预测 taken 实际 not-taken
wire ila_id_ex_pred_taken           /* synthesis syn_keep=1, PAP_MARK_DEBUG="<85>" */ = id_ex_pred_taken;   // [85] 该指令在 ID 级实际发生过预测重定向
wire ila_pair_now                   /* synthesis syn_keep=1, PAP_MARK_DEBUG="<86>" */ = pair_now;   // [86] 双发射：本拍真的配成一对
wire ila_if_id_pair                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<87>" */ = if_id_pair;   // [87] IF/ID 里这一对是否成立
wire ila_ex_mem_b_valid             /* synthesis syn_keep=1, PAP_MARK_DEBUG="<88>" */ = ex_mem_b_valid;   // [88] lane B 在 MEM 级有效
wire ila_p_ras_hit                  /* synthesis syn_keep=1, PAP_MARK_DEBUG="<89>" */ = p_ras_hit;   // [89] RAS 命中（ret）
wire ila_p_btb_pred                 /* synthesis syn_keep=1, PAP_MARK_DEBUG="<90>" */ = p_btb_pred;   // [90] BTB 预测 jalr 目标命中

/* 合计 91 位（DebugCore 触发比较单元上限 256 位，doc §7.1） */
