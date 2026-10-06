#!/usr/bin/env python3
"""
双发射可行性探针（Stage 0）：动态配对率分析器

读 tb_coremark.v 的 +PAIRTRACE 输出（计时区间内逐条 retired {pc,instr}），
复放【保守配对规则】，估算动态配对率 p 与预测得分。纯离线，不碰 RTL。

保守配对规则（见 doc：plans/generic-brewing-alpaca.md 决策）：
  slot A = 老，任意指令；slot B = 新，只在下面条件全满足时才与 A 同拍发射：

    - B 是纯 ALU：opcode ∈ {OP, OP-IMM, LUI, AUIPC}
    - B 不是 M 扩展（OP 且 funct7==0b0000001 排除）
    - B 写非 x0 寄存器（rd_b != 0）
    - B 不依赖 A：A 的 rd_a（非 x0）不在 B 读的源寄存器里
    - 同对不写同一寄存器：rd_a != rd_b

  另外，A 是"打断"类指令时该组只能是 1 宽（A 单独发射），因为机器必然重定向/停顿：
    branch / jal / jalr / mul / div

  说明：本模型**保守**——把每条分支都当作打断（不利用"预测为不跳转的分支"与
  后继配对的可能），因此算出的 p 是下界。
"""

import sys
import re

# ---- RISC-V 指令字段 ----
OP     = 0x33   # 0110011  reg-reg ALU
OPIMM  = 0x13   # 0010011  reg-imm ALU
LUI    = 0x37   # 0110111
AUIPC  = 0x17   # 0010111
LOAD   = 0x03
STORE  = 0x23
BRANCH = 0x63
JAL    = 0x6f
JALR   = 0x67
SYSTEM = 0x73
FENCE  = 0x0f

PURE_ALU = {OP, OPIMM, LUI, AUIPC}
# 打断类：A 是这些则本组 1 宽（不尝试配对）
BREAK = {BRANCH, JAL, JALR, SYSTEM, FENCE}

# 当前基线（用于算预测改进）
BASE_REGION_CYCLES = 363515
BASE_SCORE         = 233.85
CLOCK_MHZ          = 85.0051
STALL_CYCLES       = 20720 + 9396 + 45343   # load-use + mul + 分支，合计 75459（双发射不消除这些）


def fields(instr):
    op   = instr & 0x7f
    rd   = (instr >> 7) & 0x1f
    f3   = (instr >> 12) & 0x7
    rs1  = (instr >> 15) & 0x1f
    rs2  = (instr >> 20) & 0x1f
    f7   = (instr >> 25) & 0x7f
    return op, rd, f3, rs1, rs2, f7


def reads(instr):
    """B 实际读的源寄存器集合（LUI/AUIPC 不读 reg）。"""
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op == OP:
        return {rs1, rs2}
    if op == OPIMM:
        return {rs1}
    return set()   # LUI / AUIPC


def is_simple_alu_b(instr):
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op not in PURE_ALU:
        return False
    if op == OP and f7 == 0x01:      # M 扩展排除
        return False
    if rd == 0:                       # 不写寄存器则配对无意义
        return False
    return True


def is_break_a(instr):
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op in BREAK:
        return True
    if op == OP and f7 == 0x01:       # mul/div：多拍共享单元，需独占发射
        return True
    return False


def is_pure_alu_a(a):
    """A 是纯 ALU（结果在 EX 同拍组合可得）——A→B 旁路的前提（load 不行）。"""
    op, rd, f3, rs1, rs2, f7 = fields(a)
    if op in PURE_ALU:
        return not (op == OP and f7 == 0x01)
    return False


def _pair_reason(a, b, allow_bypass, skip_break=False):
    """返回 'ok' 或失败原因。allow_bypass 时允许 B 依赖纯 ALU 的 A。
    skip_break=True 时不把 A 的打断性算作失败（用于"预测不跳转的分支"放宽）。"""
    op_a, rd_a, _, _, _, _ = fields(a)
    if not skip_break and is_break_a(a):
        return 'break_a'
    if not is_simple_alu_b(b):
        return 'b_not_alu'
    op_b, rd_b, _, _, _, _ = fields(b)
    if rd_a != 0 and rd_a == rd_b:       # 同对 WAW
        return 'waw'
    if rd_a != 0 and rd_a in reads(b):   # B 依赖 A
        if allow_bypass and is_pure_alu_a(a):
            return 'ok'
        return 'b_dep_a'
    return 'ok'


def pairable(a, b, allow_bypass=False):
    return _pair_reason(a, b, allow_bypass) == 'ok'


def analyze(path):
    insts = []   # (pc, instr)
    with open(path) as f:
        for line in f:
            m = re.match(r'^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})', line)
            if m:
                insts.append((int(m.group(1), 16), int(m.group(2), 16)))
    n = len(insts)

    def taken_branch_at(i):
        """i 处是条件分支且实际跳转 = 下一条 retired 的 PC != pc+4。"""
        pc, ins = insts[i]
        op = ins & 0x7f
        if op != BRANCH:
            return False
        nxt = insts[i + 1][0] if i + 1 < n else (pc + 4)
        return nxt != (pc + 4) & 0xffffffff

    def reason(a, b, mode):
        # mode: 0=保守; 1=+A→B旁路; 2=+分支配对(预测不跳转的分支可与后继配对)
        pc_a = None
        r = _pair_reason(a[1], b[1], mode == 1 or mode == 2)
        if r != 'break_a':
            return r
        # break_a：看是否能靠"分支配对"救
        if mode == 2:
            op_a = a[1] & 0x7f
            if op_a == BRANCH and not taken_branch_at_by_pc(a, b):
                return _pair_reason(a[1], b[1], False, skip_break=True)
        return 'break_a'

    def taken_branch_at_by_pc(a, b):
        pc, ins = a
        return b[0] != ((pc + 4) & 0xffffffff)

    def run(mode):
        k = 0
        i = 0
        reasons = {}
        while i < n:
            if i + 1 < n:
                r = reason(insts[i], insts[i + 1], mode)
            else:
                r = 'end'
            if r == 'ok':
                k += 1
                i += 2
            else:
                reasons[r] = reasons.get(r, 0) + 1
                i += 1
        g = n - k
        p = k / g if g else 0.0
        pred_region = g + STALL_CYCLES
        pred_cmhz = 1e6 / pred_region
        return k, g, p, pred_region, pred_cmhz, reasons

    def report(tag, mode):
        k, g, p, pred_region, pred_cmhz, reasons = run(mode)
        score85 = pred_cmhz * CLOCK_MHZ
        be = BASE_SCORE / pred_cmhz
        print("=" * 62)
        print(f"[{tag}]")
        print(f"  指令数 n          : {n:,}")
        print(f"  2 宽组合 k        : {k:,}   配对率 p = {p:.4f}")
        print(f"  组合总数 g=n-k    : {g:,}")
        for r in ('break_a', 'b_not_alu', 'b_dep_a', 'waw', 'end'):
            if reasons.get(r):
                print(f"    单独发射-{r:<10}: {reasons[r]:>8,}  ({reasons[r]/g*100:4.1f}% of g)")
        print(f"  预测区间周期数    : {pred_region:,.0f}   (基线 {BASE_REGION_CYCLES:,})")
        print(f"  预测 CoreMark/MHz : {pred_cmhz:.3f}   (基线 2.751，单发射天花板 3.472)")
        print(f"  预测得分 @85.0051 : {score85:.1f}   (基线 {BASE_SCORE})")
        print(f"  break-even 时钟    : {be:.1f} MHz")
        return p, score85, be

    p0, s0, be0 = report("① 保守配对（Stage C 目标）", mode=0)
    print()
    p1, s1, be1 = report("② ① + A→B 旁路（Stage D，实测只值 +1 分）", mode=1)
    print()
    p2, s2, be2 = report("③ ① + 允许预测不跳转的分支配对（放宽，上界）", mode=2)
    print("=" * 62)
    print()
    print("门限判定（以 ① 为准）：")
    if p0 < 0.15:
        print(f"  p={p0:.3f} < 0.15  -> 放弃，保留 85MHz 版")
    elif p0 < 0.35:
        print(f"  0.15 <= p={p0:.3f} < 0.35  -> 可做但收益有限：需 Fmax 保住 ~{be0:.0f}MHz")
    else:
        print(f"  p={p0:.3f} >= 0.35  -> 达标，值得进 Stage A/B/C")
    print(f"  Stage D 旁路      : 得分 {s0:.0f} -> {s1:.0f}（+{s1-s0:.0f}）")
    print(f"  放宽分支配对(上界): 得分 {s0:.0f} -> {s2:.0f}（+{s2-s0:.0f}）")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "programs/pairtrace.txt"
    analyze(path)
