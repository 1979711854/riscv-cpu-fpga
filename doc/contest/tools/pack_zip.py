# -*- coding: utf-8 -*-
"""打"竞赛提交包"（评审用）。

内容 = git archive HEAD（只含已跟踪文件，天然排除 .sbit / 综合产物 / 未跟踪的 bmp）
      + 工作树中已修改的已跟踪文件（未提交的注释规范化等改动，逐文件覆盖）
      + 未提交但必须交付的文件（README、比赛技术文档 v1 等）
      + 根目录 00_先看这里.md

不含 .git（评审不需要历史）。

用法：
    python doc/contest/tools/pack_zip.py [输出路径.zip]
"""
import os
import shutil
import subprocess
import sys
import zipfile

REPO = r"D:\riscv-cpu-fpga_merged"
DEFAULT_OUT = r"C:\Users\zjn\Desktop\RV32I\交接文件\riscv-cpu-fpga_submit_20261020.zip"

# 未提交但必须随包交付的文件（相对仓库根）
OVERLAY = [
    "README.md",
    "doc/contest/技术文档_v1.docx",
    "doc/contest/技术文档_v1.pdf",
    "doc/contest/技术文档_v1_数据来源.md",
    "doc/contest/技术文档_v1_待补清单.md",
    "doc/contest/figs/fig1_soc.svg",
    "doc/contest/figs/fig1_soc.png",
    "doc/contest/tools/build_doc.py",
    "doc/contest/tools/verify_doc.py",
    "doc/contest/tools/export_pdf.ps1",
    "doc/contest/tools/dump_tpl.py",
]

# 包里剔除：厂商手册（16 MB，装 PDS 就有）+ 本地调试残留
EXCLUDE = [
    "doc/User_Constraint_Editor_User_Guide.pdf",
    "doc/Physical_Constraint_Editor_User_Guide.pdf",
]
EXCLUDE_PREFIX = [".rvcprobe/"]

INDEX = """# 作品提交包说明

本包为竞赛提交的**设计代码 + 设计文档**完整包：源码、脚本、工程、文档与证据，
不含 `.git`、不含位流文件（`.sbit` 体积大且与代码一一对应，可按下述脚本重新生成）。

## 包里是什么

- `rtl/`          CPU 与 SoC 的全部 RTL（core / mem / bus / periph / video / top）
- `scripts/`      一键脚本：出位流、跑仿真、五子棋主机预览、RT-Thread 构建
- `pds/RV32I_1/`  PDS 工程 + 引脚约束 + `mem.hex` 固件快照 + `bitstreams/README.md` 位流索引
- `sim/`          Icarus 测试台与回归
- `doc/`          架构文档、报告、板上串口日志、ILA 波形与判读
- `doc/contest/`  **比赛技术文档 v1**（docx / pdf / 数据来源对照 / 待补清单）
- `third_party/`  CoreMark、RT-Thread、riscv-tests 基线 ELF

## 5 分钟上手顺序

1. `README.md` —— 项目定位、系统框图、CPU 微架构、软件栈、构建流程
2. `doc/reports/2026-10-17_delivery_rev1028.md` —— **交付唯一数字源**（位流 b45941d6）
3. `doc/reports/2026-10-19_t7_coremark_demo_handoff.md` —— T7 演示线（CoreMark 监控屏）
4. `doc/spec.md` —— 流水线取指时序、总线契约、地址映射、已知限制
5. `doc/contest/技术文档_v1.docx` —— 比赛技术文档（同目录有 PDF 预览）
6. `pds/RV32I_1/bitstreams/README.md` —— 各档位流 md5 / 镜像字数 / 时序

## 一键复现

| 用途 | 依赖 |
|---|---|
| 综合 / 上板 | Pango Design Suite 2022.2-SP6.4 + 盘古 PG2L200H 开发板 |
| 编译 C 固件 | RISC-V GCC 15.2.0（路径写在脚本内，可改） |
| 仿真 | iverilog + gtkwave |
| 只读代码/文档 | 不需要任何环境 |

```powershell
scripts\\run_riscv_tests.ps1   # 49 PASS / 1 FAIL / 0 TIMEOUT（FAIL 为已知设计内用例）
scripts\\build_bitstream.ps1 combined
```

## 说明

- `pds/RV32I_1/mem.hex` 是提交版固件快照，可用于复现 rev1028 交付位流；
  三路径演示镜像用 `scripts\\build_bitstream.ps1 combined` 生成。
- `.rtr` 时序报告为 PDS 生成物，不随包携带；结论已写进 `doc/reports/`。
- 包内代码与文档以打包日工作树为准（比基线提交更新）；如有出入，以
  `doc/reports/` 的报告与板上串口日志为准。
"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    if os.path.exists(out):
        os.remove(out)

    head = subprocess.check_output(
        ["git", "-C", REPO, "rev-parse", "--short", "HEAD"], text=True).strip()
    branch = subprocess.check_output(
        ["git", "-C", REPO, "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip()

    subprocess.check_call(["git", "-C", REPO, "archive", "--format=zip",
                           "-o", tmp, "HEAD"])

    # 工作树中已修改/未跟踪但需要带上的已跟踪文件（如未提交的注释规范化）。
    dirty = []
    status = subprocess.check_output(
        ["git", "-C", REPO, "-c", "core.quotepath=false", "status",
         "--porcelain", "--untracked-files=no"],
        text=True, encoding="utf-8")
    for line in status.splitlines():
        if line[:2].strip() and len(line) > 3 and line[3:].strip():
            dirty.append(line[3:].strip().replace("\\", "/"))
    dirty = [n for n in dirty
             if n not in EXCLUDE
             and not any(n.startswith(p) for p in EXCLUDE_PREFIX)
             and not n.endswith("/")]

    added, replaced, dropped = [], [], []
    overlay_set = set(OVERLAY) | set(dirty)
    with zipfile.ZipFile(tmp) as zin:
        src_names = set(zin.namelist())
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zout:
            for info in zin.infolist():
                n = info.filename
                if n in EXCLUDE or any(n.startswith(p) for p in EXCLUDE_PREFIX):
                    dropped.append(n)
                    continue
                if n in overlay_set:          # 用工作树里的最新版覆盖，避免重名
                    continue
                zout.writestr(info, zin.read(n))

            # 未提交的交付文件 + 说明（工作树最新版覆盖写入）
            zout.writestr("00_先看这里.md", INDEX.encode("utf-8"))
            added.append("00_先看这里.md")
            for rel in list(dict.fromkeys(list(OVERLAY) + list(dirty))):
                path = os.path.join(REPO, rel.replace("/", os.sep))
                if not os.path.exists(path):
                    print("[!] 缺少文件:", rel)
                    continue
                zout.write(path, rel.replace(os.sep, "/"))
                (replaced if rel in src_names else added).append(rel)

    os.remove(tmp)

    size = os.path.getsize(out) / 1024 / 1024
    print("branch=%s head=%s" % (branch, head))
    print("输出:", out)
    print("大小: %.1f MB" % size)
    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        print("文件数:", len(z.namelist()), " 完整性:", "OK" if bad is None else bad)
        print("额外加入:", len(added), "  覆盖提交版:", len(replaced),
              "  剔除:", len(dropped))
        for n in added:
            print("   + ", n)
        for n in replaced:
            print("   ~ ", n)
        for n in dropped:
            print("   - ", n)


if __name__ == "__main__":
    main()
