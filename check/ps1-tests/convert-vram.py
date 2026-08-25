#!/usr/bin/env python3
"""Convert an upstream ps1-tests vram.png (hardware VRAM capture) to the
raw blob the gate runner diffs against: 1024x512 little-endian RGB555,
bit 15 always 0 (the PNGs are RGB888 with 5-bit levels <<3 and carry no
mask bit — the runner therefore compares `ours & 0x7FFF`).

Stdlib only (zlib): no PIL/ImageMagick needed.

  python3 check/ps1-tests/convert-vram.py <vram.png> <out.vram>
"""
import struct, sys, zlib

def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, meta, plte = 8, b"", {}, b""
    while pos < len(d):
        ln, typ = struct.unpack_from(">I4s", d, pos)
        data = d[pos + 8 : pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct = struct.unpack_from(">IIBB", data)
            meta = dict(w=w, h=h, bd=bd, ct=ct)
        elif typ == b"IDAT":
            idat += data
        elif typ == b"PLTE":
            plte = data
        pos += 12 + ln
    assert meta["ct"] in (2, 3, 6), f"unsupported color type {meta}"
    meta["plte"] = plte
    return meta, zlib.decompress(idat)

def unfilter(meta, raw):
    w, h = meta["w"], meta["h"]
    if meta["ct"] == 2:
        bpp = 3
    elif meta["ct"] == 6:
        bpp = 4
    else:
        bpp = 1 if meta["bd"] == 8 else 1  # sub-byte handled below via stride
    if meta["ct"] == 3 and meta["bd"] < 8:
        # palettized sub-byte rows: stride in BYTES
        stride_bits = w * meta["bd"]
        stride = (stride_bits + 7) // 8
        out = bytearray()
        prev = bytearray(stride)
        pos = 0
        for _ in range(h):
            f = raw[pos]
            row = bytearray(raw[pos + 1 : pos + 1 + stride])
            pos += 1 + stride
            if f == 1:
                for i in range(1, stride):
                    row[i] = (row[i] + row[i - 1]) & 0xFF
            elif f == 2:
                for i in range(stride):
                    row[i] = (row[i] + prev[i]) & 0xFF
            elif f == 3:
                for i in range(stride):
                    a = row[i - 1] if i >= 1 else 0
                    row[i] = (row[i] + ((a + prev[i]) >> 1)) & 0xFF
            elif f == 4:
                for i in range(stride):
                    a = row[i - 1] if i >= 1 else 0
                    b = prev[i]
                    cc = prev[i - 1] if i >= 1 else 0
                    p = a + b - cc
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - cc)
                    pr = a if pa <= pb and pa <= pc else (b if pb <= pc else cc)
                    row[i] = (row[i] + pr) & 0xFF
            # expand to one index byte per pixel
            exp = bytearray()
            per = 8 // meta["bd"]
            mask = (1 << meta["bd"]) - 1
            for x in range(w):
                byte = row[x // per]
                shift = (per - 1 - (x % per)) * meta["bd"]
                exp.append((byte >> shift) & mask)
            out += exp
            prev = row
        meta["bpp"] = 1
        return bytes(out)
    meta["bpp"] = bpp
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(h):
        f = raw[pos]
        row = bytearray(raw[pos + 1 : pos + 1 + stride])
        pos += 1 + stride
        if f == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif f == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                cc = prev[i - bpp] if i >= bpp else 0
                p = a + b - cc
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - cc)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else cc)
                row[i] = (row[i] + pr) & 0xFF
        out += row
        prev = row
    return bytes(out)

def main():
    src, dst = sys.argv[1], sys.argv[2]
    meta, raw = read_png(src)
    assert (meta["w"], meta["h"]) == (1024, 512), f"unexpected size {meta}"
    data = unfilter(meta, raw)
    out = bytearray()
    ct = meta["ct"]
    if ct == 2:
        for i in range(0, len(data), 3):
            px = (data[i] >> 3) | ((data[i + 1] >> 3) << 5) | ((data[i + 2] >> 3) << 10)
            out += struct.pack("<H", px)
    elif ct == 6:
        # RGBA: alpha ignored (sampled — carries no mask information in
        # the upstream captures; bit 15 stays 0 like the other variants)
        for i in range(0, len(data), 4):
            px = (data[i] >> 3) | ((data[i + 1] >> 3) << 5) | ((data[i + 2] >> 3) << 10)
            out += struct.pack("<H", px)
    else:
        plte = meta["plte"]
        for idx in data:
            r, g, b = plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2]
            px = (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
            out += struct.pack("<H", px)
    open(dst, "wb").write(out)
    print(f"{dst}: {len(out)} bytes")

if __name__ == "__main__":
    main()
