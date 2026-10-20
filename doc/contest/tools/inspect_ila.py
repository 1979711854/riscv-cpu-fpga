# -*- coding: utf-8 -*-
"""统计 ila_probes.vh 的通道占用，供 PDS Fabric Inserter 配置核对。"""
import io
import os
import re

REPO = r"D:\riscv-cpu-fpga_merged"
PROBE = os.path.join(REPO, "rtl", "core", "ila_probes.vh")

s = io.open(PROBE, encoding="utf-8").read()
marks = re.findall(r'PAP_MARK_DEBUG="([^"]+)"', s)

d, t, c = set(), set(), set()
for m in marks:
    for part in m.split(","):
        part = part.strip()
        mm = re.match(r"<0/([dtc])(\d+)/(\d+)>", part)
        if not mm:
            print("unparsed:", part)
            continue
        {"d": d, "t": t, "c": c}[mm.group(1)].add(int(mm.group(3)))

print("PAP_MARK_DEBUG 条数:", len(marks))
print("data 通道数:", len(d), "范围", (min(d), max(d)) if d else None)
print("trigger 通道:", sorted(t))
print("clock 通道:", sorted(c))

# 分组注释
print("\n分组:")
for line in s.splitlines():
    if line.startswith("// ---- "):
        print("  ", line[8:])
