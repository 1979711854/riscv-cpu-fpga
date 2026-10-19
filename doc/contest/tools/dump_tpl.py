# -*- coding: utf-8 -*-
"""Dump docx structure: paragraph index / style / text, and tables."""
import sys
from docx import Document
from docx.table import Table
from docx.text.paragraph import Paragraph
from docx.oxml.ns import qn


def iter_block_items(parent):
    from docx.document import Document as _Doc
    if isinstance(parent, _Doc):
        parent_elm = parent.element.body
    else:
        parent_elm = parent._tc
    for child in parent_elm.iterchildren():
        if child.tag == qn('w:p'):
            yield Paragraph(child, parent)
        elif child.tag == qn('w:tbl'):
            yield Table(child, parent)


def main(path):
    out = open(sys.argv[2], "w", encoding="utf-8") if len(sys.argv) > 2 else sys.stdout

    def P(*a):
        print(*a, file=out)

    doc = Document(path)
    sec = doc.sections[0]
    print("PAGE  w=%d h=%d" % (sec.page_width, sec.page_height))
    print("MARGIN t=%d r=%d b=%d l=%d" % (sec.top_margin, sec.right_margin,
                                          sec.bottom_margin, sec.left_margin))
    print("-" * 70)
    i = 0
    for blk in iter_block_items(doc):
        if isinstance(blk, Paragraph):
            txt = blk.text.replace("\n", "\\n")
            runs = len(blk.runs)
            sizes = set()
            for r in blk.runs:
                if r.font.size:
                    sizes.add(r.font.size.pt)
            align = blk.paragraph_format.alignment
            print("[P%03d] style=%-16s align=%-10s size=%-12s runs=%d | %s"
                  % (i, blk.style.name, str(align), str(sorted(sizes)), runs, txt))
        else:
            rows = len(blk.rows)
            cols = len(blk.columns)
            print("[T%03d] TABLE style=%-14s rows=%d cols=%d" % (i, blk.style.name if blk.style else None, rows, cols))
            for ri, row in enumerate(blk.rows):
                cells = []
                for c in row.cells:
                    cells.append(c.text.replace("\n", "/"))
                print("        r%02d: %s" % (ri, " | ".join(cells)))
        i += 1
    print("-" * 70)
    print("styles:", [s.name for s in doc.styles if s.type is not None][:40])


if __name__ == "__main__":
    main(sys.argv[1])
