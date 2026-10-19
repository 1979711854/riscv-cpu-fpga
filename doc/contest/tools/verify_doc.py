# -*- coding: utf-8 -*-
"""交付前自检：口径一致性 + 敏感信息 + 字数。"""
import re
import sys
from docx import Document

PATH = r"D:\riscv-cpu-fpga_merged\doc\contest\技术文档_v1.docx"

BAD = [
    ("学校", "不得出现学校信息"),
    ("大学", "不得出现学校信息"),
    ("学院", "不得出现学校信息"),
    ("指导老师", "不得出现可识别信息"),
    ("导师", "不得出现可识别信息"),
    ("参赛队", "不得出现队伍信息"),
    ("RT-Thread 跑出", "错误表述：RT 跑 CoreMark"),
    ("RT-Thread 跑 CoreMark", "错误表述：RT 跑 CoreMark"),
    ("当前交付带 I+D", "错误表述：交付带 I+D Cache"),
    ("带 I+D Cache 的交付", "错误表述：交付带 I+D Cache"),
    ("85.0051 MHz 交付", "错误表述：历史频率当交付"),
]

MUST = ["352.5", "4.6075", "78.3269", "7,740", "b45941d6", "846,440,591",
        "6E2D6020", "1,440", "49 PASS", "76.5052"]

HIST = ["391.66", "365.93", "325.96"]


def main():
    d = Document(PATH)
    text = "\n".join(p.text for p in d.paragraphs)
    for t in d.tables:
        for row in t.rows:
            text += "\n" + " | ".join(c.text for c in row.cells)

    print("字数(汉字):", len(re.findall(r"[\u4e00-\u9fff]", text)))
    print("段落:", len(d.paragraphs), " 表格:", len(d.tables),
          " 内嵌图:", len(d.inline_shapes))

    ok = True
    for key, why in BAD:
        if key in text:
            print("[!] 命中禁用词:", key, "->", why)
            ok = False
    for key in MUST:
        if key not in text:
            print("[!] 缺少必备数字:", key)
            ok = False
    for key in HIST:
        n = text.count(key)
        print("历史数字 %-7s 出现 %d 次（应仅出现在对照表/说明中）" % (key, n))
    # 每个历史数字所在段落是否带“历史/对照”字样
    for p in d.paragraphs:
        for key in HIST:
            if key in p.text and "历史" not in p.text and "对照" not in p.text:
                print("[!] 历史数字缺少标注:", key, "|", p.text[:60])
                ok = False
    for t in d.tables:
        for row in t.rows:
            rowtxt = " ".join(c.text for c in row.cells)
            for key in HIST:
                if key in rowtxt and "历史" not in rowtxt and "对照" not in rowtxt:
                    print("[!] 表格中历史数字缺少标注:", key, "|", rowtxt[:60])
                    ok = False
    print("自检:", "通过" if ok else "有告警")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
