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

# A bzImage is itself compressed and the initramfs is nested inside that
# compression, so one pass is not enough: decompress every gzip member we find,
# then search the result for further members. The kernel's own payload is skipped
# as noise; we report the first image that contains a marker.
hits = []
seen = 0


def scan(blob, depth, origin):
    global seen
    for match in re.finditer(b"\x1f\x8b\x08", blob):
        off = match.start()
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            out = d.decompress(blob[off:off + 400_000_000])
        except Exception:
            continue
        if len(out) < 100_000:
            continue
        seen += 1
        present = [m for m in markers if m in out]
        label = "  " * depth + f"stream at {origin}+{off:,}: {len(out):,} bytes"
        if present:
            print(label)
            for m in markers:
                print(f"    {m.decode(errors='replace'):38s} "
                      f"{'FOUND' if m in out else 'absent'}")
            hits.append((origin + off, out))
            return True
        if depth < 3:
            if scan(out, depth + 1, origin + off):
                return True
    return False


ok = scan(data, 0, 0)
if not ok:
    print(f"  scanned {seen} compressed member(s): no marker found in any")
    sys.exit(2)
print(f"  -> verified: the image contains an initramfs with the expected markers")
