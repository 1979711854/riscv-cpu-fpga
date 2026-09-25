# =============================================================================
# ila_capture.tcl —— Fabric Debugger 抓波形脚本（RISC-V CPU 项目）
# -----------------------------------------------------------------------------
# 用法：在 PDS 的 Debugger 里打开 TCLConsole（底部信息打印区，View -> Console），
#       然后：  source D:/riscv-cpu-fpga/scripts/ila_capture.tcl
#
# [!] 跑之前先确认两件事：
#   1) 已经连上 JTAG Server（`dbg_connect -ip 127.0.0.1 -port 65420`），
#      否则会报 "the connection is disconnected, please connect to server first"。
#   2) FPGA 里是【调试版】比特流。判据：`dbg_list` 应显示
#      "Data sample width = 86" 和 "Number of trigger ports = 4"。
#
# 通道映射（数据端口 0，共 86 位）见 doc/ila_analysis.md §7.1，也见 core.v 末尾
# 探针束的块头注释。摘要：
#   [0..14]   pc[14:0]        [15..29]  if_id_pc[14:0]
#   [30..44]  id_ex_pc[14:0]  [45..59]  ex_mem_pc[14:0]
#   [60..66]  if_id_instr[6:0]
#   [67] stall  [68] div_stall  [69] ex_flush  [70] id_ex_mem_read
#   [71..74] fwd_a_ex / fwd_b_ex / fwd_a_wb / fwd_b_wb
#   [75] id_ex_branch  [76] branch_taken  [77] mem_we  [78] mem_re
#   [79] mem_wb_reg_write  [80] bht_hit  [81] bht_taken  [82] id_pred_taken
#   [83] id_redirect  [84] ex_mispred  [85] id_ex_pred_taken
#
# 触发端口：t0=ex_flush  t1=stall  t2=bht_hit  t3=ex_mispred（各 1 位）
# =============================================================================

set FIC  D:/riscv-cpu-fpga/pds/RV32I_1/cpu_top_board.fic

# -----------------------------------------------------------------------------
# 第 1 步：导入 .fic —— 给 86 个通道安上信号名
# 不做这一步的话，波形里全是无名的裸通道，没法读。
# 注意：本地板的 Debugger 走工程里登记的那份也行，但这里显式指定最稳。
# -----------------------------------------------------------------------------
dbg_import_fic -file $FIC

# -----------------------------------------------------------------------------
# 第 2 步：把全部信号加进波形窗口
# -----------------------------------------------------------------------------
dbg_add_all_to_waveform

# -----------------------------------------------------------------------------
# 第 3 步：建 PC 总线（省得对着 15 根裸线数 bit）
# [!] 总线进制的编号和 TriggerUnit 不一样，别混：
#       总线(db_set_bus_radix)： 0=二进制 1=八进制 2=十六进制 3=无符号 4=有符号
#       TriggerUnit(set_unit) ： 0=Hex   1=Octal   2=Binary   3=Unsigned
# [!] 位序如果不对（PC 值看起来像位反转），取消下面那行 reverse 的注释再跑一次。
# -----------------------------------------------------------------------------
dbg_add_bus -name PC        -channel 0-14
dbg_set_bus_radix -name PC -radix 2
# dbg_reverse_bus -name PC

dbg_add_bus -name IFID_PC   -channel 15-29
dbg_set_bus_radix -name IFID_PC -radix 2
# dbg_reverse_bus -name IFID_PC

dbg_add_bus -name IDEX_PC   -channel 30-44
dbg_set_bus_radix -name IDEX_PC -radix 2
# dbg_reverse_bus -name IDEX_PC

dbg_add_bus -name EXMEM_PC  -channel 45-59
dbg_set_bus_radix -name EXMEM_PC -radix 2
# dbg_reverse_bus -name EXMEM_PC

dbg_add_bus -name OPCODE    -channel 60-66
dbg_set_bus_radix -name OPCODE -radix 2

# -----------------------------------------------------------------------------
# 第 4 步：冒烟测试 —— 强制触发一次，确认整条链路是通的
# TriggerImmediate 忽略触发条件，立刻抓满一个窗口。
# 波形里应该有数据；PC 应该在 0x0000 ~ 0x4200 之间跳动。
# 如果这一步没数据，别往下走，先查链路。
# -----------------------------------------------------------------------------
dbg_trig_immd

# -----------------------------------------------------------------------------
# 第 5 步：正式触发 —— 抓"分支冲刷"
# 手册对 Binary 进制的 Value 要求：每一位都必须显式给出。我们的触发端口是
# 1 位，所以只写一个字符即可：R=上升沿  F=下降沿  1=高电平  0=低电平
#                            X=不关心  B=任意翻转  N=不翻转
# 四个候选触发信号各占一个 1 位触发端口，换触发只需改 -unit 和下面的条件：
#       -unit 0  -> t0 = ex_flush    （分支/跳转冲刷）
#       -unit 1  -> t1 = stall       （load-use 停顿）
#       -unit 2  -> t2 = bht_hit     （BHT 查表命中）
#       -unit 3  -> t3 = ex_mispred  （预测 taken 但实际 not-taken）
# -----------------------------------------------------------------------------
dbg_set_unit -unit 0 -func "==" -value R -radix 2

# 触发条件：先看现有的（不带选项就是列出全部），再建一个用 TU0 的
dbg_set_condition
dbg_set_condition -add 1
dbg_set_condition -select 1 -set "TU0"
dbg_set_condition -active 1

# -----------------------------------------------------------------------------
# 第 6 步：捕获设置 —— 单窗口 / 深度 1024 / 触发点居中（看到触发前后各一半）
# 用 -windows 1 时深度自动等于核的最大深度(1024)，不能同时给 -depth。
# -----------------------------------------------------------------------------
dbg_set_capture -type 0 -windows 1 -position 512

# -----------------------------------------------------------------------------
# 第 7 步：开抓。满足一次 ex_flush 上升沿后，buffer 填满即停，
#          数据自动显示在 Waveform / Listing 窗口。
# -----------------------------------------------------------------------------
dbg_run

# -----------------------------------------------------------------------------
# 换别的触发（不用重烧板，只改这两行再 dbg_run 即可）：
#   BHT 命中且预测跳转：
#       dbg_set_unit -unit 2 -func "==" -value R -radix 2
#       dbg_set_condition -select 1 -set "TU2"
#       dbg_run
#   load-use 停顿：
#       dbg_set_unit -unit 1 -func "==" -value R -radix 2
#       dbg_set_condition -select 1 -set "TU1"
#       dbg_run
#   预测误判恢复：
#       dbg_set_unit -unit 3 -func "==" -value R -radix 2
#       dbg_set_condition -select 1 -set "TU3"
#       dbg_run
#
# 停抓并卸掉触发条件：  dbg_stop
# 导出这次波形设置：    dbg_export_fic -file D:/riscv-cpu-fpga/pds/RV32I_1/ila_captured.fic
# 查所有命令：          dbg_help       （每条都支持 -help，如 dbg_set_unit -help）
# =============================================================================
