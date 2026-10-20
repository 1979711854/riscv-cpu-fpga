# -*- coding: utf-8 -*-
"""快速看一段 VCD 的 PC 分布，判断窗口是否落在有效代码区（临时诊断用）。"""
import re
import sys
import io

path = sys.argv[1]
txt = io.open(path, encoding="utf-8", errors="replace").read()
names = {vid: (name, int(w)) for w, vid, name in
         re.findall(r"\$var\s+wire\s+(\d+)\s+(\S+)\s+(\S+)", txt)}
pc_ids = [vid for vid, (n, w) in names.items() if n.upper().endswith("PC") and w >= 15]
print("PC 总线:", [(names[i][0], names[i][1]) for i in pc_ids])

body = txt.split("$enddefinitions $end", 1)[1]
pcs = []
for line in body.splitlines():
    line = line.strip()
    if not line or line[0] == "#" or line[0] == "$":
        continue
    if line[0] in "bB":
        try:
            bits, vid = line[1:].split()
        except ValueError:
            continue
        if vid in pc_ids:
            pcs.append(int(bits.replace("x", "0").replace("z", "0"), 2))

from collections import Counter
c = Counter(pcs)
print("PC 取值数:", len(pcs), " 不同 PC:", len(c))
print("Top8:", [(hex(k), v) for k, v in c.most_common(8)])
print("前 20 个 PC:", [hex(p) for p in pcs[:20]])
