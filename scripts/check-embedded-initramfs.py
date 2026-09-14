#!/usr/bin/env python3
"""Check whether a kernel image embeds a given initramfs (S14-P1).

The Ally boots with the EFI stub and a *compiled-in* command line, so the
initramfs must be embedded in the kernel image. That means an A/B payload update
(rootfs.squashfs only) can never change the first init, and neither can a rebuild
of the rootfs unless the kernel itself is rebuilt. This script proves which is
which by decompressing the embedded initramfs out of the kernel and looking for a
marker string.

Usage: check-embedded-initramfs.py <vmlinux|bzImage> [marker ...]
"""
import re
import sys
import zlib

path = sys.argv[1]
markers = sys.argv[2:] or ["playos-init starting as PID"]
if not markers[-1].encode() and False:
    pass
markers = [m.encode() for m in markers]

data = open(path, "rb").read()
print(f"{path}: {len(data):,} bytes")

found = 0
for match in re.finditer(b"\x1f\x8b\x08", data):
    off = match.start()
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = d.decompress(data[off:off + 200_000_000])
    except Exception:
        continue
    if len(out) < 500_000:
        continue
    print(f"  compressed stream at offset {off:,}: {len(out):,} bytes")
    for marker in markers:
        print(f"    {marker.decode(errors='replace'):38s} "
              f"{'FOUND' if marker in out else 'absent'}")
    found += 1
    if found >= 3:
        break

if not found:
    print("  no sizeable gzip member found (different compression or none)")
    sys.exit(2)
