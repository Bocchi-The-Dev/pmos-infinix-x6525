#!/usr/bin/env python3
"""Emit register-lab commands that load the JPEG codec's default entropy tables.

Usage: jpeg-lab-tables.py libjpeg_hw_sprd.so > tables.lab
       cat tables.lab > /sys/kernel/debug/sprd-jpg/lab_cmd

Replays JPEGFW_configure_vld_reg_jpegDec's "default tables" path: g_huffTab
(0x288 bytes at vaddr 0x1dc88 in the 32-bit library of the stock Infinix X6525
image) word 0 -> 0x48, word 1 -> 0x4c, words 2..65 -> 0x50..0x14c.
"""
import struct
import sys

VADDR, SIZE, DATA_VADDR, DATA_OFF = 0x1dc88, 0x288, 0x1cc2c, 0x19c2c

d = open(sys.argv[1], "rb").read()
off = VADDR - DATA_VADDR + DATA_OFF
words = struct.unpack("<%dI" % (SIZE // 4), d[off:off + SIZE])
print("# g_huffTab default tables (%d words)" % len(words))
print("on")
print("w 0x48 0x%x" % words[0])
print("w 0x4c 0x%x" % words[1])
for i in range(64):
    print("w 0x%x 0x%x" % (0x50 + 4 * i, words[2 + i]))
