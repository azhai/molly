#!/usr/bin/env python3
"""从 aarch64 core 里解出 NT_FILE 映射表，定位某个地址落在哪个 .so 里。
用法：python3 core_maps.py /tmp/molly.core 0x7f88b60640
"""
import struct
import sys


def read_notes(path):
    with open(path, "rb") as f:
        data = f.read()
    # ELF64 头
    assert data[:4] == b"\x7fELF" and data[4] == 2
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    notes = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != 4:  # PT_NOTE
            continue
        p_offset, = struct.unpack_from("<Q", data, off + 0x08)
        p_filesz, = struct.unpack_from("<Q", data, off + 0x20)
        cur = p_offset
        end = p_offset + p_filesz
        while cur + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, cur)
            cur += 12
            name = data[cur : cur + namesz].rstrip(b"\x00")
            cur += (namesz + 3) & ~3
            desc = data[cur : cur + descsz]
            cur += (descsz + 3) & ~3
            notes.append((name, ntype, desc))
    return data, notes


def main():
    path = sys.argv[1]
    targets = [int(a, 16) for a in sys.argv[2:]] or [0]
    data, notes = read_notes(path)
    for name, ntype, desc in notes:
        if name == b"CORE" and ntype == 0x46494C45:  # NT_FILE
            count, page_size = struct.unpack_from("<QQ", desc, 0)
            entries = []
            # 三元组 (start, end, file_ofs) 是虚拟地址，file_ofs 以 page 为单位
            for i in range(count):
                start, end, fofs = struct.unpack_from("<QQQ", desc, 16 + i * 24)
                entries.append((start, end, fofs))
            names = desc[16 + count * 24 :].split(b"\x00")
            names = [n.decode() for n in names if n]
            for idx, (start, end, fofs) in enumerate(entries):
                fn = names[idx] if idx < len(names) else "?"
                for t in targets:
                    if start <= t < end:
                        print(
                            f"0x{t:x} 落在 {fn}\n  段 0x{start:x}-0x{end:x} "
                            f"file_ofs=0x{fofs * page_size:x} → 文件偏移 0x{t - start + fofs * page_size:x}"
                        )
            print(f"（共 {count} 个映射，page_size={page_size}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())