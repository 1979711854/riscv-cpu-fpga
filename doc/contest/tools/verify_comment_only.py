# -*- coding: utf-8 -*-
"""校验工作区 RTL 相对 git HEAD 只改了注释、代码零变化。

用法：
    python doc/contest/tools/verify_comment_only.py            # 检查 rtl/ 全部差异文件
    python doc/contest/tools/verify_comment_only.py rtl/x.v    # 只检查指定文件

原理：去掉 // 与块注释、去空白后，逐行比较代码 token 流。
例外：ila_probes.vh 相对 HEAD 有未提交的代码新增（探针），会单独标出。
"""
import re
import subprocess
import sys

REPO = r"D:\riscv-cpu-fpga_merged"
KNOWN_CODE_DIFF = {"rtl/core/ila_probes.vh"}   # 已知有合法代码新增的文件


def strip_code(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    out = []
    for line in text.splitlines():
        line = re.sub(r"//.*", "", line)
        line = re.sub(r"\s+", "", line)
        if line:
            out.append(line)
    return out


def git_text(path, rev="HEAD"):
    raw = subprocess.check_output(
        ["git", "-C", REPO, "show", "%s:%s" % (rev, path.replace("\\", "/"))])
    return raw.decode("utf-8", errors="replace")


def worktree_text(path):
    with open(REPO + "\\" + path.replace("/", "\\"), "rb") as f:
        return f.read().decode("utf-8", errors="replace")


def main():
    args = sys.argv[1:]
    if args:
        files = [a.replace("\\", "/") for a in args]
    else:
        out = subprocess.check_output(
            ["git", "-C", REPO, "diff", "--name-only", "HEAD", "--", "rtl/"],
            text=True)
        files = [l.strip() for l in out.splitlines() if l.strip()]

    if not files:
        print("rtl/ 下与 HEAD 无差异")
        return 0

    bad = []
    for path in files:
        a = strip_code(git_text(path))
        b = strip_code(worktree_text(path))
        if a == b:
            print("[OK]   %-40s 代码零变化（仅注释）" % path)
            continue
        # 找第一处差异，便于定位
        i = 0
        while i < min(len(a), len(b)) and a[i] == b[i]:
            i += 1
        print("[!!]   %-40s 代码有差异 @第 %d 个 token 行" % (path, i + 1))
        print("       HEAD    : %s" % (a[i:i + 1] or ["<EOF>"])[0][:90])
        print("       工作区   : %s" % (b[i:i + 1] or ["<EOF>"])[0][:90])
        if path not in KNOWN_CODE_DIFF:
            bad.append(path)

    print("-" * 60)
    if bad:
        print("结论：以下文件存在非注释代码改动，必须检查：%s" % ", ".join(bad))
        return 1
    known = [p for p in files
             if p in KNOWN_CODE_DIFF and strip_code(git_text(p)) != strip_code(worktree_text(p))]
    if known:
        print("结论：全部文件仅注释变化（%s 的代码新增为已知合法改动）" % ", ".join(known))
    else:
        print("结论：全部文件仅注释变化")
    return 0


if __name__ == "__main__":
    sys.exit(main())
