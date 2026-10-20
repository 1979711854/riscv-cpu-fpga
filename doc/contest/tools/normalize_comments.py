# -*- coding: utf-8 -*-
"""对 Verilog 注释做规范化清理（只改注释，不碰代码）。

处理范围（纯机械、安全）：
1. 去掉注释里的强调符号：【】、**
2. 去掉任务/阶段编号前缀：[A1] [A 扩展] [B1-RAS] [B1-BTB] [阶段1]
   [lane B 访存] [任务 C] [TASK-C 探针] [面积优化]（保留 [双发射]、[!]）
3. [重点] 统一改 [!]
4. 去掉括号引用：（任务书 §x）（v10 §x.x）（R1/R6/R7）（约定 n）（赛题…）

用法：python normalize_comments.py rtl/core/core.v [更多文件...]
"""
import re
import sys

MARKERS = [
    r"\[A1\]\s*", r"\[A 扩展\]\s*", r"\[B1-RAS\]\s*", r"\[B1-BTB\]\s*",
    r"\[阶段1\]\s*", r"\[lane B 访存\]\s*", r"\[任务 C\]\s*",
    r"\[TASK-C 探针\]\s*", r"\[面积优化\]\s*",
]
PARENS = [
    r"（任务书[^）]*）", r"（v10 §[^）]*）", r"（v6 任务书[^）]*）",
    r"（R\d）", r"（约定 \d+(?:/\d+)?）", r"（赛题[^）]*）", r"（任务书）",
]


def clean_line(line):
    # 找到注释起点（简单场景：本工程没有字符串里带 // 的情况）
    idx = line.find("//")
    if idx < 0:
        return line, False
    code, comment = line[:idx], line[idx:]
    orig = comment
    comment = comment.replace("【", "").replace("】", "")
    comment = comment.replace("**", "")
    comment = re.sub(r"\[重点\]", "[!]", comment)
    for m in MARKERS:
        comment = re.sub(m, "", comment)
    for p in PARENS:
        comment = re.sub(p, "", comment)
    changed = comment != orig
    return code + comment, changed


def main():
    total = 0
    for path in sys.argv[1:]:
        with open(path, "r", encoding="utf-8", newline="") as f:
            lines = f.read().split("\n")
        n = 0
        for i, line in enumerate(lines):
            new, changed = clean_line(line)
            if changed:
                lines[i] = new
                n += 1
        if n:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write("\n".join(lines))
        print("%-40s 清理 %d 行注释" % (path, n))
        total += n
    print("合计清理 %d 行" % total)


if __name__ == "__main__":
    main()
