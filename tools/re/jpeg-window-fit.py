#!/usr/bin/env python3
"""Fit the quantisation-window map from the output of jpeg-window-probe.py.

Usage: jpeg-window-fit.py < paste-of-probe-output   (the 256 'bufdump 1' lines of 4 words)
The probe decodes 64 blocks (one MCU row, 512x8): block 0 has only DC=+1, block j>0 has DC=+1 (the
predictor carries it) and a single +3 at zigzag position j. With the window filled with slot numbers
1..64 (slot = 2*word + half + 1), the amplitude of block j is the slot that dequantised position zz[j].
"""
import re, struct, sys
import numpy as np

words = []
for line in sys.stdin:
    m = re.match(r"^([0-9a-f]{6}): ((?:[0-9a-f]{8} ?){4})\s*$", line.strip())
    if m:
        words.append([int(x, 16) for x in m.group(2).split()])
data = []
for ws in words[-256:]:
    data += list(b"".join(struct.pack("<I", w) for w in ws))
img = np.array(data).reshape(8, 512).astype(float) - 128
zz = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
      35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
C = np.array([[(np.sqrt(.125) if u == 0 else .5) * np.cos((2 * x + 1) * u * np.pi / 16) for x in range(8)] for u in range(8)])
slot = np.zeros(64)
dc0 = C @ img[:, 0:8] @ C.T
slot[0] = dc0[0][0]
for j in range(1, 64):
    D = C @ img[:, 8 * j:8 * j + 8] @ C.T
    D[0][0] -= slot[0]                       # remove the DC every block carries
    r = zz[j]
    slot[r] = D[r // 8][r % 8] / 3.0
np.set_printoptions(linewidth=200, precision=1, suppress=True)
print("effective window value at raster position (row = vertical frequency):")
print(slot.reshape(8, 8))
print("as slot number s (slot = 2*word + half + 1):")
from scipy.optimize import linear_sum_assignment   # the slots are a permutation of 1..64
cost = np.abs(slot[:, None] - np.arange(1, 65)[None, :])
ri, ci = linear_sum_assignment(cost)
S = np.zeros(64, dtype=int)
S[ri] = ci + 1
S = S.reshape(8, 8)
print(S)
print("word, half:")
print([[("%d,%d" % ((S[v][u] - 1) // 2, (S[v][u] - 1) % 2) if S[v][u] > 0 else "-") for u in range(8)] for v in range(8)])
