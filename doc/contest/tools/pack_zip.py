# -*- coding: utf-8 -*-
"""打一个"干净"的交接包给队友。

内容 = git archive HEAD（只含已跟踪文件，天然排除 .sbit / 综合产物 / 未跟踪的 bmp）
      + 本次未提交但必须交付的文件（新版 README、比赛技术文档 v1）
      + 根目录 00_先看这里.md

不含 .git（队友只读/复现，不需要历史；需要历史的走 clone）。

用法：
    python doc/contest/tools/pack_zip.py [输出路径.zip]
"""
import os
import shutil
import subprocess
import sys
import zipfile

REPO = r"D:\riscv-cpu-fpga_merged"
DEFAULT_OUT = r"C:\Users\zjn\Desktop\RV32I\交接文件\riscv-cpu-fpga_main_20261019.zip"

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

INDEX = """# 先看这里（交接包说明）

这是一个**只读交接包**：用于阅读源码、文档与证据，不含 `.git`、不含位流。

## 包里是什么

- `rtl/`          CPU 与 SoC 的全部 RTL（core / mem / bus / periph / video / top）
- `scripts/`      一键脚本：出位流、跑仿真、五子棋主机预览、RT-Thread 构建
- `pds/RV32I_1/`  PDS 工程 + 引脚约束 + `mem.hex` 固件快照 + `bitstreams/README.md` 位流索引
- `sim/`          Icarus 测试台与回归
- `doc/`          架构文档、97 份报告、板上串口日志、界面取像
- `doc/contest/`  **比赛技术文档 v1**（docx / pdf / 数据来源 / 待补清单）
- `third_party/`  CoreMark、RT-Thread、riscv-tests 基线 ELF

## 5 分钟上手顺序

1. `README.md` —— 项目定位、系统框图、CPU 微架构、软件栈、构建流程
2. `doc/reports/2026-10-17_delivery_rev1028.md` —— **交付唯一数字源**（位流 b45941d6）
3. `doc/reports/2026-10-19_t7_coremark_demo_handoff.md` —— T7 演示线（CoreMark 监控屏）
4. `doc/spec.md` —— 流水线取指时序、总线契约、地址映射、已知限制
5. `doc/contest/技术文档_v1.docx` —— 比赛技术文档（可直接用 Word 打开；同目录有 PDF 预览）
6. `pds/RV32I_1/bitstreams/README.md` —— 各档位流 md5 / 镜像字数 / 时序

## 包里有、但要注意的三件事

- **没有 `.sbit` 位流**（9 MB/个，仓库一律不入库）。要复现就本地综合；要现成位流找我要，并核对 md5。
- **没有 `.rtr` 时序报告**（PDS 生成物）。结论已写进 `doc/reports/`，原始报告需自己综合后生成。
- **`pds/RV32I_1/mem.hex` 是提交版快照**（与 `main` 提交一致，可用于复现 rev1028 位流）；
  若你要 T7 的三路径镜像（24,135 字 / 48,270 行），用 `scripts\\build_bitstream.ps1 combined` 重新生成。

## 想跑起来需要什么

| 用途 | 依赖 |
|---|---|
| 综合 / 上板 | Pango Design Suite 2022.2-SP6.4 + 盘古 PG2L200H 开发板 |
| 编译 C 固件 | `D:\\riscv-toolchain\\xpack-riscv-none-elf-gcc-15.2.0-1`（路径写死在脚本里，可改） |
| 仿真 | `scoop install iverilog gtkwave` |
| 只读代码/文档 | 不需要任何环境 |

```powershell
scripts\\run_riscv_tests.ps1   # 49 PASS / 1 FAIL / 0 TIMEOUT
scripts\\build_bitstream.ps1 combined
```

## 版本

- 基线提交：`main` @ `cd57222`（2026-10-19）
- 包内 `README.md` 与 `doc/contest/` 是打包时尚**未提交**的最新版（比基线提交更新）

有任何对不上的地方，以 `doc/reports/` 里的报告与串口日志为准，不要以聊天记录为准。
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

    added, replaced, dropped = [], [], []
    src_names = set()
    overlay_set = set(OVERLAY)
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

            # 未提交的交付文件 + 说明
            zout.writestr("00_先看这里.md", INDEX.encode("utf-8"))
            added.append("00_先看这里.md")
            for rel in OVERLAY:
                path = os.path.join(REPO, rel)
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
