/* ============================================================================
 * tb_amo_cpu.S —— A 扩展在【整颗CPU】上的端到端测试
 * ----------------------------------------------------------------------------
 * 与 sim/tb_amo.v（单元级）互补：那个只验 amo_unit 本身，这个验
 * 「译码→ 前递 → 流水线冻结 → MEM 读写 → 写回寄存器」整条链路。
 *
 * 为什么必须有这个：单元级全过≠ 集成正确。AMO 特别容易在两个地方出错：
 *   1) rs2 的前递 —— "amoadd a0,a1,a2" 里 a2 刚被上一条写过，
 *      若 AMO 的 rs2 没走前递网，会读到陈旧值；
 *   2) 流水线冻结 —— amo_stall 期间前端的取指/重定向必须被正确抑制，
 *      否则会重复取指或漏写。
 *
 * 判据：把结果写进 UART(0x7FFC)，测试台逐字节比对。
 * ==========================================================================*/
    .section .text.init
    .globl _start
_start:
    li      sp, 0x8000

    # ============================================================
    # t0 = 计数器（AMO 最典型的用法：多线程递增同一个变量）
    # ============================================================
    li      t0, 0x2000            # 计数器地址
    li      t1, 0
    sw      t1, 0(t0)             # 计数器 = 0

    # --- 连续 10 次 amoadd，期望结果 = 10 ---
    li      t2, 10
    li      t3, 0                 # 期望值累加器
amo_loop:
    addi    t3, t3, 1
    li      t4, 1
    amoadd.w t5, t4, (t0)         # t5 = 旧值；[t0] += 1
    addi    t2, t2, -1
    bnez    t2, amo_loop

    lw      a0, 0(t0)             # 读回计数器
    li      a1, 10
    bne     a0, a1, fail_amoadd   # 应为 10

    # --- amoswap：应换值并返回旧值 ---
    li      t4, 0x1234
    amoswap.w t5, t4, (t0)        # t5 = 旧值(10)
    li      a1, 10
    bne     t5, a1, fail_aswap    # 旧值应是 10
    lw      a0, 0(t0)
    li      a1, 0x1234
    bne     a0, a1, fail_aswap    # 内存应变成 0x1234

    # --- amoswap 返回值本身就是"被换掉的那个值"，可直接当立即数来源 ---
    li      t4, 0x5678
    amoswap.w t5, t4, (t0)
    amoswap.w a2, t4, (t0)        # 连续两次：a2 应拿到上一次的 0x5678
    li      a1, 0x5678
    bne     a2, a1, fail_chain

    # ============================================================
    # 有符号 vs 无符号：0x80000000 是关键用例
    #   amomaxu（无符号）：0x80000000 > 1⇒ 取原值，不变
    #   amomax（有符号）  ：-2^31 > 1 ?否 ⇒ 取 rs2(=1)
    # ============================================================
    li      t0, 0x2010
    li      t1, 0x80000000
    sw      t1, 0(t0)
    li      t4, 1
    amomaxu.w a0, t4, (t0)        # 写回旧值 = 0x80000000
    lw      a1, 0(t0)
    bne     a1, t1, fail_maxu     # 内存应不变

    li      t1, 0x80000000
    sw      t1, 0(t0)
    li      t4, 1
    amomax.w  a0, t4, (t0)        # 写回旧值 = 0x80000000
    lw      a1, 0(t0)
    li      a2, 1
    bne     a1, a2, fail_max      # 有符号下应取 1

    # ============================================================
    # LR / SC 配对
    # ============================================================
    li      t0, 0x2020
    li      t1, 0x0000AAAA
    sw      t1, 0(t0)

    lr.w    a0, (t0)              # a0 = 0xAAAA
    li      a1, 0xAAAA
    bne     a0, a1, fail_lr

    li      t4, 0x5555
    sc.w    a0, t4, (t0)          # 预约匹配 ⇒ a0 = 1
    li      a1, 1
    bne     a0, a1, fail_sc

    lw      a2, 0(t0)
    li      a1, 0x5555
    bne     a2, a1, fail_sc_mem   # 内存应已被写入

    # --- SC 在没有预约时必须失败 ---
    li      t4, 0x6666
    sc.w    a0, t4, (t0)          # 上一次 SC 已清预约 ⇒ 应失败(a0=0)
    bnez    a0, fail_sc_noq

    # ============================================================
    # AMO 与普通访存混合：AMO 之后普通 lw 必须能看到 AMO 写入的值
    # （验访存端口 or 在 AMO 与 load/store 之间没打架）
    # ============================================================
    li      t0, 0x2030
    li      t1, 0
    sw      t1, 0(t0)
    li      t4, 5
    amoadd.w zero, t4, (t0)       # 内存 = 5（zero 丢弃写回值）
    lw      a0, 0(t0)
    li      a1, 5
    bne     a0, a1, fail_mix
    sw      zero, 0(t0)
    amoadd.w zero, t4, (t0)       # 内存 = 5
    lw      a0, 0(t0)
    li      a1, 5
    bne     a0, a1, fail_mix2

    # ============================================================
    # 全部通过
    # ============================================================
    li      a0, 0xAC              # 'PASS' 的首字节标记
    j       report

fail_amoadd:
    li      a0, 0xE1
    j       report
fail_aswap:
    li      a0, 0xE2
    j       report
fail_chain:
    li      a0, 0xE3
    j       report
fail_maxu:
    li      a0, 0xE4
    j       report
fail_max:
    li      a0, 0xE5
    j       report
fail_lr:
    li      a0, 0xE6
    j       report
fail_sc:
    li      a0, 0xE7
    j       report
fail_sc_mem:
    li      a0, 0xE8
    j       report
fail_sc_noq:
    li      a0, 0xE9
    j       report
fail_mix:
    li      a0, 0xEA
    j       report
fail_mix2:
    li      a0, 0xEB
    j       report

report:
    li      t0, 0x7FFC            # UART
    sb      a0, 0(t0)
    li      t0, 0x7FF8            # done
    sw      x0, 0(t0)
1:  j       1b