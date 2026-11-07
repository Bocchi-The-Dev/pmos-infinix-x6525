#!/usr/bin/env python3
"""Probe how the JPEG codec's quantisation window (0x1000..) maps onto coefficient positions.

Usage: jpeg-window-probe.py libjpeg_hw_sprd.so OUTDIR
Builds a hand-made entropy stream of 64 blocks (one MCU row, 512x8): block j has a single +3 at zigzag position j
(standard Annex K luma Huffman tables, which are the codec's defaults), and fills the quantisation
window with the slot numbers 1..64. The decoded pixels are then 128 + IDCT(W[r]) where W[r] is the slot
number that dequantised raster position r, so a least-squares fit (tools/re/jpeg-window-fit.py) gives
the position <- slot map directly. Output: OUTDIR/probe.sh (run as root on the phone).
"""
import base64, os, struct, sys

so, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
# standard Annex K luma AC Huffman table, taken from a JPEG that Pillow writes
import io
from PIL import Image
_b = io.BytesIO(); Image.new("L", (8, 8)).save(_b, "JPEG"); _j = _b.getvalue()
_p = 2
while _j[_p + 1] != 0xC4 or _j[_p + 4] != 0x10:
    _p += 2 + struct.unpack(">H", _j[_p + 2:_p + 4])[0]
AC_BITS = list(_j[_p + 5:_p + 21])
AC_VALS = _j[_p + 21:_p + 21 + sum(AC_BITS)]
codes, c, k = {}, 0, 0
for ln in range(1, 17):
    for _ in range(AC_BITS[ln - 1]):
        codes[AC_VALS[k]] = format(c, "0%db" % ln); k += 1; c += 1
    c <<= 1
assert len(codes) == 162
NB = 64                                   # one MCU row of 64 blocks, 512 x 8 pixels
bits = ""
for j in range(NB):                       # block j: a single coefficient +1 at zigzag position j
    if j == 0:
        bits += "010" + "1" + codes[0x00]             # DC +1, EOB
    else:
        bits += "00"                                    # DC diff 0 (category 0)
        run = j - 1
        while run >= 16:
            bits += codes[0xF0]; run -= 16
        bits += codes[(run << 4) | 2] + "11" + (codes[0x00] if j < 63 else "")   # size 2, value +3
bits += "1" * (-len(bits) % 8)
scan = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)).replace(b"\xff", b"\xff\x00")   # byte stuffing

d = open(so, "rb").read()
maxc = struct.unpack("<66I", d[0x8208:0x8208 + 264])
sym = struct.unpack("<162I", d[0x8310:0x8310 + 648])
t = []
t.append("w 0x48 0x%x" % maxc[0]); t.append("w 0x4c 0x%x" % maxc[1])
for i in range(64): t.append("w 0x%x 0x%x" % (0x50 + 4 * i, maxc[2 + i]))
for i, v in enumerate(sym): t.append("w 0x%x 0x%x" % (0x2000 + 4 * i, v))
for tab in (0, 1):                       # slot numbers 1..64: word w = (2w+1) | (2w+2) << 16
    for w in range(32): t.append("w 0x%x 0x%x" % (0x1000 + 0x80 * tab + 4 * w, (2 * w + 1) | (2 * w + 2) << 16))
tab = "\n".join(t) + "\n"
W, H = 512, 8
L = ["clear", "buf 1 4096", "buf 2 4096", "buf 3 4096",
     "w 0x158 0xff0005", "w 0x154 0x0",
     "w 0x0c 0x%x" % ((((W + 15) >> 4) << 20) + W),
     "w 0x10 0x%x" % ((4 << 29) | (1 << 13) | 64),
     "w 0x14 0x0", "w 0x04 0x10140080", "w 0x18 0x%x" % len(scan),
     "wb 0x1c 1", "wb 0x20 2", "wb 0x24 2", "w 0x28 0x0", "wb 0x28 0",
     "w 0x30 0x960711", "w 0x34 0x1",
     "w 0x04 0x10140281", "irq 200", "r 0x15c 1", "r 0x2c 1", "r 0x38 4", "bufdump 1 0 4096"]
lab = "\n".join(L) + "\n"
b = lambda x: base64.b64encode(x).decode()
open(out + "/probe.sh", "w").write("""#!/bin/sh
# run as root with nothing unsaved
D=/sys/kernel/debug/sprd-jpg
feed() { while IFS= read -r l; do [ -n "$l" ] && printf '%%s\\n' "$l" > $D/lab_cmd; done; }
echo off > $D/lab_cmd; sleep 1; echo on > $D/lab_cmd
echo "buf 0 4096" > $D/lab_cmd
echo %s | base64 -d | dd of=$D/lab_buf0 conv=notrunc 2>/dev/null
echo %s | base64 -d | feed
echo clear > $D/lab_cmd
echo %s | base64 -d | feed
cat $D/lab_out
""" % (b(scan), b(tab.encode()), b(lab.encode())))
print("scan bytes", len(scan))
