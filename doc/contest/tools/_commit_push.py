# -*- coding: utf-8 -*-
"""一次性：提交并推送 README / 技术文档 / 监控屏固件改动（消息走 -F 文件，避免 PowerShell 编码问题）。"""
import os
import subprocess
import sys
import tempfile

REPO = r"D:\riscv-cpu-fpga_merged"


def run(args, check=True):
    p = subprocess.run(args, cwd=REPO, text=True, encoding="utf-8",
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print("$", " ".join(args))
    print(p.stdout.strip())
    if check and p.returncode != 0:
        sys.exit(p.returncode)
    return p


def commit(paths, message):
    run(["git", "add", "--"] + paths)
    fd, tmp = tempfile.mkstemp(suffix=".txt")
    os.close(fd)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(message)
    try:
        run(["git", "commit", "-F", tmp])
    finally:
        os.remove(tmp)


commit(["scripts/gomoku/coremark_screen.c"],
       "fix(gomoku): CoreMark 监控屏堆余量改字节制显示\n\n"
       "旧显示 HEAP FREE : 0.0K —— 本系统堆仅 1,440 B，按 KB 取整恒为 0.0K，\n"
       "容易被误读成分配失败或假数据。改为 <剩余>/<总量>B：\n"
       "  * cm_mon_heap_free() 增加 total_out 出参，值仍来自 rt_memory_info()\n"
       "  * 剩余字节用 GREEN8（8x8 亮绿）绘制\n"
       "  * \"/1440B\" 用通用 8x8 字补（GREEN8 子集不含 / 与 B）\n"
       "主机预览编译通过；真实值需重出位流后从板上取。\n")

commit(["README.md", "doc/contest"],
       "docs: README 补 CPU/软件设计章节；新增比赛技术文档 v1\n\n"
       "README：\n"
       "  * 补系统总览（Mermaid 框图 + 模块职责 + 三路径/镜像布局）\n"
       "  * 补 CPU 微架构：参数表、取指时序不变量、双发射配对规则、\n"
       "    4 读 2 写寄存器堆、冒险/预测/异常、Cache 口径、拍数演进\n"
       "  * 补软件栈：RT-Thread 方式一移植、五子棋规则/AI/渲染/输入、\n"
       "    CoreMark 移植与终端屏、三路径引导\n"
       "  * 修过期口径：64KB 地址映射改 128KB、85MHz/ITER=4280 改 76.5052/3900\n"
       "doc/contest：技术文档 v1（docx + pdf + 数据来源 + 待补清单 + 生成脚本）\n")

run(["git", "push", "origin", "main"])
run(["git", "log", "--oneline", "-3"])
