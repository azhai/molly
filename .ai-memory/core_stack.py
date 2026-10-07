#!/usr/bin/env python3
"""从 aarch64 core 的栈区间里捞出像返回地址的 8 字节值，并用 nm 符号表标名。

用法：python3 core_stack.py /tmp/molly.core 0x7f88aecee0 65536 /tmp/molly-syms.txt
"""
import struct
import sys


def load_segments(path):
    with open(path, "rb") as f:
        data = f.read()
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != 1:  # PT_LOAD
            continue
        p_offset, = struct.unpack_from("<Q", data, off + 0x08)
        p_vaddr, = struct.unpack_from("<Q", data, off + 0x10)
        p_filesz, = struct.unpack_from("<Q", data, off + 0x20)
        if p_filesz == 0:
            continue
        segs.append((p_vaddr, p_offset, p_filesz))
    return data, segs


def read_mem(data, segs, vaddr, size):
    for start, off, filesz in segs:
        if start <= vaddr < start + filesz:
            end = min(vaddr + size, start + filesz)
            fo = off + (vaddr - start)
            return data[fo : fo + (end - vaddr)]
    return None


def load_syms(path):
    syms = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                addr = int(parts[0], 16)
            except ValueError:
                continue
            syms.append((addr, parts[1]))
    syms.sort()
    return syms


def symbolize(syms, addr):
    lo, hi = 0, len(syms) - 1
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= addr:
            best = syms[mid]
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:
        return "?"
    return f"{best[1]}+0x{addr - best[0]:x}"


def main():
    core, sp = sys.argv[1], int(sys.argv[2], 16)
    size = int(sys.argv[3])
    syms = load_syms(sys.argv[4])
    lo = syms[0][0]
    hi = max(a for a, _ in syms) + 0x1000
    data, segs = load_segments(core)
    mem = read_mem(data, segs, sp, size)
    if mem is None:
        print("该地址不在 core 的 PT_LOAD 里")
        return 1
    print(f"扫描 0x{sp:x} .. 0x{sp + len(mem):x}（molly 代码区间 0x{lo:x}-0x{hi:x}）")
    for i in range(0, len(mem) - 7, 8):
        v, = struct.unpack_from("<Q", mem, i)
        if lo <= v < hi:
            print(f"  0x{sp + i:x} -> 0x{v:x}  {symbolize(syms, v)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())