#!/bin/sh
# export-sdk.sh — populate the playos-tools SDK tree from a Buildroot output.
#
# Usage:
#   scripts/export-sdk.sh [buildroot-output] [playos-tools-root]
#
# Copies the musl sysroot headers, the device libplayos/libraylib libraries,
# and the x86_64-buildroot-linux-musl cross toolchain into
# <playos-tools>/sdk/ so third parties can build games without Buildroot.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="${1:-$WORKSPACE/playos-refdistro/output/ally}"
TOOLS="${2:-$WORKSPACE/playos-tools}"

SDK="$TOOLS/sdk"
PREFIX=x86_64-buildroot-linux-musl
TOOLCHAIN_SRC="$OUT/host"
SYSROOT="$TOOLCHAIN_SRC/$PREFIX/sysroot"
TARGET_LIB="$OUT/target/usr/lib"

if [ ! -d "$SYSROOT/usr/include/playos" ]; then
    echo "ERROR: musl sysroot headers not found at $SYSROOT/usr/include/playos" >&2
    exit 1
fi

echo "==> Exporting SDK from $OUT"
mkdir -p "$SDK/include/playos" "$SDK/lib" "$SDK/toolchain/bin" "$SDK/toolchain/$PREFIX"

# Headers
cp "$SYSROOT/usr/include/playos/"*.h "$SDK/include/playos/"
if [ -f "$SYSROOT/usr/include/raylib.h" ]; then
    cp "$SYSROOT/usr/include/raylib.h" "$SDK/include/"
else
    echo "WARN: raylib.h not found in sysroot" >&2
fi

# Libraries (prefer sysroot staging, fall back to target)
copy_lib() {
    name="$1"
    if ls "$SYSROOT/usr/lib/$name"* >/dev/null 2>&1; then
        cp -a "$SYSROOT/usr/lib/$name"* "$SDK/lib/"
    elif ls "$TARGET_LIB/$name"* >/dev/null 2>&1; then
        cp -a "$TARGET_LIB/$name"* "$SDK/lib/"
    else
        echo "WARN: $name not found" >&2
    fi
}
copy_lib libplayos.so
copy_lib libplayos.a
copy_lib libraylib.so
copy_lib libraylib.a

# Toolchain: the cross prefix directory, the wrapper the symlinks point at, and
# the compiler proper.
#
# The bin/<prefix>-* entries are *symlinks* to bin/toolchain-wrapper, so copying
# only them produced an SDK whose compiler could not run at all - "No such file or
# directory", not even a wrong-path error. The real compiler lives in libexec/gcc
# (cc1, cc1plus, collect2) and lib/gcc (specs and support files); the wrapper finds
# them relative to its own location, which is what makes the tree relocatable, so
# the whole set has to move together.
cp -a "$TOOLCHAIN_SRC/$PREFIX/." "$SDK/toolchain/$PREFIX/"

if [ -f "$TOOLCHAIN_SRC/bin/toolchain-wrapper" ]; then
    cp -a "$TOOLCHAIN_SRC/bin/toolchain-wrapper" "$SDK/toolchain/bin/"
else
    echo "warning: no toolchain-wrapper in $TOOLCHAIN_SRC/bin" >&2
fi

for part in libexec/gcc lib/gcc; do
    if [ -d "$TOOLCHAIN_SRC/$part" ]; then
        mkdir -p "$SDK/toolchain/$(dirname "$part")"
        cp -a "$TOOLCHAIN_SRC/$part" "$SDK/toolchain/$(dirname "$part")/"
    else
        echo "warning: $TOOLCHAIN_SRC/$part missing" >&2
    fi
done

# The bin/<prefix>-* symlinks go last, once their target exists.
if ls "$TOOLCHAIN_SRC/bin/$PREFIX"-* >/dev/null 2>&1; then
    cp -a "$TOOLCHAIN_SRC/bin/$PREFIX"-* "$SDK/toolchain/bin/"
fi

echo "==> SDK ready at $SDK"
ls "$SDK/include/playos" | wc -l | xargs echo "    headers:"
ls "$SDK/lib" | sed 's/^/    /'
du -sh "$SDK/toolchain" 2>/dev/null | sed 's/^/    toolchain: /'
