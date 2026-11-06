#!/usr/bin/env python3
"""Emit register-lab commands that load the JPEG codec's default max-code tables.

Usage: jpeg-lab-tables.py libjpeg_hw_sprd.so > tables.lab
       cat tables.lab > /sys/kernel/debug/sprd-jpg/lab_cmd

The window at 0x48..0x14c takes 66 words: 0x48, 0x4c, then 64 words in four
groups of 16 (0x50, 0x90, 0xd0, 0x110). The source is the library's
jpeg_fw_vld_default_max_code (264 bytes at vaddr 0x8208 of the 32-bit library in
the stock Infinix X6525 image; the first LOAD maps file offset = vaddr).

Measured on the phone with the lab: every register in the two first groups
keeps only its low N bits, N = 1..16 along the group, and the last two groups
keep two N-bit fields (bits 0.. and 8..), so the right source has to fit those
masks. An earlier version of this script used jpeg_fw_vld_default_huffTab (the
648-byte symbol table at 0x8310), which does not fit (39 of 66 writes read
back different); that table is not for this window.
"""
import struct
import sys

VADDR, SIZE = 0x8208, 264

d = open(sys.argv[1], "rb").read()
words = struct.unpack("<%dI" % (SIZE // 4), d[VADDR:VADDR + SIZE])
print("# jpeg_fw_vld_default_max_code (%d words)" % len(words))
print("on")
print("w 0x48 0x%x" % words[0])
print("w 0x4c 0x%x" % words[1])
for i in range(64):
    print("w 0x%x 0x%x" % (0x50 + 4 * i, words[2 + i]))
