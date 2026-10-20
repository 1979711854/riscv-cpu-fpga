# -*- coding: utf-8 -*-
"""ILA 探针束编译冒烟测试：把 ila_probes.vh 临时 include 进 core.v 的一份副本，
用 iverilog 做一次 elaborate，确认探针引用的信号在作用域内（不改仓库里的 core.v）。"""
import io
import os
import shutil
import subprocess
import sys
import tempfile

REPO = r"D:\riscv-cpu-fpga_merged"
CORE = os.path.join(REPO, "rtl", "core", "core.v")
SUBS = ["alu.v", "control.v", "imm_gen.v", "regfile.v", "divider.v",
        "multiplier.v", "amo_unit.v", "csr_file.v", "rvc_expand.v"]

src = io.open(CORE, encoding="utf-8").read()
idx = src.rfind("endmodule")
if '`include "ila_probes.vh"' in src:
    patched = src                     # core.v 里已经加过，直接用，别重复 include
else:
    patched = src[:idx] + '\n`include "ila_probes.vh"\n' + src[idx:]

tmp = tempfile.mkdtemp(prefix="ila_")
core_tmp = os.path.join(tmp, "core_ila.v")
io.open(core_tmp, "w", encoding="utf-8").write(patched)

files = [core_tmp] + [os.path.join(REPO, "rtl", "core", f) for f in SUBS
                      if os.path.exists(os.path.join(REPO, "rtl", "core", f))]

cmd = ["iverilog", "-g2012", "-t", "null", "-s", "core",
       "-I", os.path.join(REPO, "rtl", "core"),
       "-I", os.path.join(REPO, "rtl", "bus")] + files
p = subprocess.run(cmd, text=True, encoding="utf-8", errors="replace",
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(p.stdout.strip() or "(no output)")
print("exit:", p.returncode, "->", "PASS" if p.returncode == 0 else "FAIL")
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(0 if p.returncode == 0 else 1)
