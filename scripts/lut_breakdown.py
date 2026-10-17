#!/usr/bin/env python
# -*- coding: ascii -*-
"""Per-module LUT breakdown from a PDS/Gowin-style mapped Verilog netlist.

Why this exists: PDS GUI "Report Area" needs the GUI, and the CLI flow does not
emit a per-module table. The post-synthesis mapped netlist keeps the module
hierarchy, so counting primitive cells per hierarchical instance reproduces the
same numbers as `synthesize/run.log`:

    Total LUTs        = LUTs as logic + LUTs as dram
    LUTs as logic     = GTP_LUT1..LUT6 + GTP_LUT6CARRY + GTP_LUT6D
                        (GTP_MUX2LUT7/8 are internal wide-mux cells, not sites)
    LUTs as dram      = GTP_RAM*x*  cells (site count is reported separately)

Usage:
    python scripts/lut_breakdown.py pds/RV32I_1/synthesize/cpu_top_board_syn.vm
    python scripts/lut_breakdown.py <vm> --depth 2 --filter u_core
"""

import argparse
import re
import sys
from collections import OrderedDict

LUT_CELLS = {
    "GTP_LUT1", "GTP_LUT2", "GTP_LUT3", "GTP_LUT4",
    "GTP_LUT5", "GTP_LUT6", "GTP_LUT6CARRY", "GTP_LUT6D",
}
MUX_CELLS = {"GTP_MUX2LUT7", "GTP_MUX2LUT8"}
FF_PREFIX = "GTP_DFF"
RAM_PREFIX = "GTP_RAM"

MODULE_RE = re.compile(r"^module\s+(\S+)")
END_RE = re.compile(r"^endmodule")
# primitive cell:      GTP_LUT6 /* n123 */ #( ... )
CELL_RE = re.compile(r"^\s+(GTP_\w+)\s+/\*\s*([^\s*]+)\s*\*/")
# module instance:     mem_bus u_bus (        |  core /* u_core */ (
INST_RE = re.compile(r"^\s+([A-Za-z_]\w*)\s+(\S+)\s*\(\s*$")
INST_CMT_RE = re.compile(r"^\s+([A-Za-z_]\w*)\s+/\*\s*([^\s*]+)\s*\*/\s*\(\s*$")


class Mod(object):
    __slots__ = ("name", "cells", "children")

    def __init__(self, name):
        self.name = name
        self.cells = OrderedDict()
        self.children = []  # (module_type, instance_name)

    def add_cell(self, cell):
        self.cells[cell] = self.cells.get(cell, 0) + 1


def parse(path):
    mods = OrderedDict()
    pending = []  # (mod, type, inst) resolved after the whole file is read
    cur = None
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = MODULE_RE.match(line)
            if m:
                cur = Mod(m.group(1))
                mods[cur.name] = cur
                continue
            if END_RE.match(line):
                cur = None
                continue
            if cur is None:
                continue
            m = CELL_RE.match(line)
            if m:
                cur.add_cell(m.group(1))
                continue
            m = INST_CMT_RE.match(line) or INST_RE.match(line)
            if m:
                pending.append((cur, m.group(1), m.group(2)))
    for mod, mtype, inst in pending:
        if mtype in mods:
            mod.children.append((mtype, inst))
    return mods


def leaf_counts(mod, mods, depth=0, stack=None):
    """Return dict cell -> count for a module, expanding child instances."""
    stack = stack or set()
    out = dict(mod.cells)
    if mod.name in stack:  # recursive/feedback module: ignore the loop
        return out
    stack.add(mod.name)
    for mtype, _inst in mod.children:
        child = mods.get(mtype)
        if child is None:
            continue
        for k, v in leaf_counts(child, mods, depth + 1, stack).items():
            out[k] = out.get(k, 0) + v
    stack.discard(mod.name)
    return out


def walk(name, mod, mods, depth, maxdepth, prefix, rows, seen):
    cells = leaf_counts(mod, mods)
    lut = sum(v for k, v in cells.items() if k in LUT_CELLS)
    mux = sum(v for k, v in cells.items() if k in MUX_CELLS)
    ff = sum(v for k, v in cells.items() if k.startswith(FF_PREFIX))
    ramc = sum(v for k, v in cells.items() if k.startswith(RAM_PREFIX))
    rows.append((prefix or name, lut, mux, ff, ramc))
    if depth >= maxdepth:
        return
    for mtype, inst in mod.children:
        child = mods.get(mtype)
        if child is None:
            continue
        walk(mtype, child, mods, depth + 1, maxdepth, (prefix + "/" if prefix else "") + inst, rows, seen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("netlist")
    ap.add_argument("--top", default="cpu_top_board")
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--filter", default=None, help="only paths containing this substring")
    args = ap.parse_args()

    mods = parse(args.netlist)
    if not mods:
        sys.exit("no modules parsed")
    top = mods.get(args.top)
    if top is None:
        sys.exit("top module %r not found (have: %s)" % (args.top, ", ".join(list(mods)[:8])))

    rows = []
    walk(args.top, top, mods, 0, args.depth, "", rows, set())

    root = rows[0]
    print("netlist : %s" % args.netlist)
    print("top     : %s" % args.top)
    print()
    print("%-52s %7s %7s %7s %7s" % ("hierarchy", "LUT", "MUX78", "FF", "RAMcell"))
    print("-" * 86)
    for path, lut, mux, ff, ramc in rows:
        if args.filter and args.filter not in path:
            continue
        print("%-52s %7d %7d %7d %7d" % (path, lut, mux, ff, ramc))
    print("-" * 86)
    print("%-52s %7d %7d %7d %7d" % ("TOTAL", root[1], root[2], root[3], root[4]))
    print()
    print("cross-check against synthesize/run.log:")
    print("  LUTs as logic : %d" % root[1])
    print("  LUTs as dram  : %d cells (run.log counts %d sites)" % (root[4], root[4]))
    print("  Total LUTs    : %d (expect LUTs as logic + dram sites)" % (root[1] + root[4]))


if __name__ == "__main__":
    main()
