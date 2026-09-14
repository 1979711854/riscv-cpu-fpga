#!/usr/bin/env python3
"""把 riscv-tests 的 ELF 拆成 imem.hex(指令) 和 dmem.hex(数据+tohost)。

用法: python elf2mem.py <test.elf>
输出: 同目录下 imem.hex / dmem.hex
  - imem 收 .text.init/.text 段，按 word 索引 (VMA>>2) 放置
  - dmem 收 .tohost/.data/.bss 段
  - 用 $readmemh 的 @addr 形式，addr 是 word 索引
"""
import subprocess, sys, os, struct

# 工具链路径：可用环境变量 RISCV_TOOLS 覆盖（便于换机器/换队友）
TOOLS = os.environ.get("RISCV_TOOLS", "D:/riscv-toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin")
OBJCOPY = os.path.join(TOOLS, "riscv-none-elf-objcopy.exe")
OBJDUMP = os.path.join(TOOLS, "riscv-none-elf-objdump.exe")

IMEM_SECTIONS = {".text.init", ".text", ".text.startup"}
DMEM_SECTIONS = {".tohost", ".data", ".bss", ".sdata", ".sbss", ".rodata", ".srodata"}


def parse_sections(elf):
    """从 objdump -h 提取 (name, size, vma) 列表。"""
    out = subprocess.check_output([OBJDUMP, "-h", elf], text=True)
    secs = []
    in_table = False
    for line in out.splitlines():
        if line.startswith("Sections:"):
            in_table = True
            continue
        if not in_table or not line.strip():
            continue
        # 只取形如 "  0 .text.init  000004bc  00000000 ..." 的数据行
        parts = line.split()
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        name = parts[1]
        size = int(parts[2], 16)
        vma = int(parts[3], 16)
        secs.append((name, size, vma))
    return secs


def extract(elf, name, tmp):
    subprocess.check_call(
        [OBJCOPY, "-O", "binary", "--only-section=" + name, elf, tmp]
    )
    with open(tmp, "rb") as f:
        return f.read()


def group_words(data, base_vma):
    """把字节流按小端 32 位拼成 word，返回 {word_index: value}。"""
    words = {}
    for i in range(0, len(data), 4):
        chunk = data[i:i + 4]
        if len(chunk) < 4:
            chunk = chunk + b"\x00" * (4 - len(chunk))
        val = struct.unpack("<I", chunk)[0]
        words[(base_vma + i) >> 2] = val
    return words


def write_hex(path, words):
    with open(path, "w") as f:
        for idx in sorted(words):
            f.write("@%x\n%08x\n" % (idx, words[idx]))


def main():
    # 用法: python elf2mem.py <test.elf> [outdir]
    #   outdir 省略时输出到 ELF 同目录
    elf = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(elf))
    os.makedirs(outdir, exist_ok=True)
    tmp = os.path.join(outdir, "_sec.tmp.bin")
    imem = {}
    dmem = {}
    for name, size, vma in parse_sections(elf):
        if size == 0:
            continue
        if name in IMEM_SECTIONS:
            target = imem
        elif name in DMEM_SECTIONS:
            target = dmem
        else:
            continue
        data = extract(elf, name, tmp)
        target.update(group_words(data, vma))
    if os.path.exists(tmp):
        os.remove(tmp)
    write_hex(os.path.join(outdir, "imem.hex"), imem)
    write_hex(os.path.join(outdir, "dmem.hex"), dmem)
    # 顺便报 tohost 位置，并写入 tohost_addr.hex 供 testbench 运行时读取
    tohost = None
    for name, size, vma in parse_sections(elf):
        if name == ".tohost":
            tohost = vma
    if tohost is None:
        tohost = 0x1000  # 兜底：没有 .tohost 段时用默认地址
    with open(os.path.join(outdir, "tohost_addr.hex"), "w") as f:
        f.write("%08x\n" % tohost)
    print("tohost = 0x%x (word 0x%x)" % (tohost, tohost >> 2))


if __name__ == "__main__":
    main()
