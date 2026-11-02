#!/usr/bin/env python3
"""
Put the two filesystems of the split install onto one microSD card image.

    python3 -I tools/make-sd-image.py pmos-boot-fs.img pmos-root-fs.img x6525-sdcard.img

The ROM build is a split install (a boot filesystem for the eMMC's `cache`
partition and a root filesystem for `userdata`). U-Boot reads a card through its
partition table, so this writes an MBR with two Linux partitions (boot first,
marked active, then root) and copies the filesystems into them byte for byte.
The UUIDs and labels survive, and those are what the extlinux command line
and the initramfs find the disk by, so it boots from the card the same way
it does from the eMMC. No root, no loop device; zero blocks are skipped, so
the output stays sparse.

The boot filesystem is grown to --boot-mib (default 256) first, because the
one made for the 64 MiB `cache` partition has little room for kernel updates.

Write the result to a card with: dd if=x6525-sdcard.img of=/dev/sdX bs=4M conv=fsync
The root filesystem is not grown to the card's size; run resize2fs on it after.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

MIB = 1 << 20
SECTOR = 512
BLOCK = 1 << 20


def copy_sparse(src, dst, offset):
    with open(src, "rb") as s:
        pos = 0
        while True:
            chunk = s.read(BLOCK)
            if not chunk:
                break
            if chunk.count(0) != len(chunk):
                dst.seek(offset + pos)
                dst.write(chunk)
            pos += len(chunk)


def run(*cmd, ok=(0,)):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode not in ok:
        sys.exit(f"{' '.join(cmd)} failed:\n{r.stdout}{r.stderr}")


def grown_boot(path, mib, tmp):
    out = os.path.join(tmp, "boot.img")
    shutil.copyfile(path, out)
    if os.path.getsize(out) >= mib * MIB:
        return out
    run("e2fsck", "-fy", out, ok=(0, 1))
    with open(out, "r+b") as f:
        f.truncate(mib * MIB)
    run("resize2fs", out)
    return out


def mbr_entry(active, start, count):
    return struct.pack("<B3sB3sII", 0x80 if active else 0, b"\xfe\xff\xff", 0x83,
                       b"\xfe\xff\xff", start, count)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("boot")
    ap.add_argument("root")
    ap.add_argument("out")
    ap.add_argument("--boot-mib", type=int, default=256)
    a = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        boot = grown_boot(a.boot, a.boot_mib, tmp)
        bsize = os.path.getsize(boot)
        rsize = os.path.getsize(a.root)
        p1 = MIB
        p2 = p1 + (bsize + MIB - 1) // MIB * MIB
        total = p2 + (rsize + MIB - 1) // MIB * MIB + MIB   # a MiB of slack at the end

        with open(a.out, "wb") as o:
            o.truncate(total)
            mbr = bytearray(512)
            mbr[446:446 + 16] = mbr_entry(True, p1 // SECTOR, bsize // SECTOR)
            mbr[462:462 + 16] = mbr_entry(False, p2 // SECTOR, rsize // SECTOR)
            mbr[440:444] = os.urandom(4)       # disk signature
            mbr[510:512] = b"\x55\xaa"
            o.write(mbr)
            copy_sparse(boot, o, p1)
            copy_sparse(a.root, o, p2)
    print(f"{a.out}: {total // MIB} MiB; boot at {p1 // MIB} MiB ({bsize // MIB} MiB), "
          f"root at {p2 // MIB} MiB ({rsize // MIB} MiB)")


if __name__ == "__main__":
    main()
