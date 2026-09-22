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
# Fresh each run: Buildroot's sysroot files are read-only, so a plain re-copy onto
# them fails with "Permission denied" rather than replacing them. Re-running the
# export has to work - it is how the SDK is refreshed.
rm -rf "$SDK/toolchain" "$SDK/lib" "$SDK/include" "$SDK/desktop"

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

# ── Desktop profile (host) ────────────────────────────────────────────────────
# Built here rather than left to the developer:
#   * raylib, from the same source the device uses, but with its default desktop
#     backend - one source of truth, and no system raylib required.
#   * libplayos with PLAYOS_BACKEND=stub, the host shim.
# Decision and rationale: playos-spec/src/sdk-desktop-shim.md.
DESKTOP="$SDK/desktop"
BUILD_D="$DESKTOP/.build"
RAYLIB_SRC="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/playos-shell/external/raylib"
API_SRC="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/playos-platform-api"

mkdir -p "$DESKTOP/install/lib" "$DESKTOP/install/include" \
         "$DESKTOP/raylib/lib" "$DESKTOP/raylib/include"

if [ -d "$RAYLIB_SRC" ]; then
    cmake -S "$RAYLIB_SRC" -B "$BUILD_D/raylib" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_EXAMPLES=OFF -DBUILD_SHARED_LIBS=ON \
        -DGLFW_BUILD_WAYLAND=ON -DGLFW_BUILD_X11=ON \
        > /dev/null
    cmake --build "$BUILD_D/raylib" -j"$(nproc 2>/dev/null || echo 4)" > /dev/null
    cp -a "$BUILD_D/raylib/raylib/libraylib.so"* "$DESKTOP/raylib/lib/"
    cp "$RAYLIB_SRC/src/raylib.h" "$DESKTOP/raylib/include/"
else
    echo "warning: no raylib source at $RAYLIB_SRC - desktop profile incomplete" >&2
fi

if [ -d "$API_SRC" ]; then
    cmake -S "$API_SRC" -B "$BUILD_D/api" -DPLAYOS_BACKEND=stub \
        -DCMAKE_BUILD_TYPE=Release > /dev/null
    cmake --build "$BUILD_D/api" -j"$(nproc 2>/dev/null || echo 4)" > /dev/null
    cp -a "$BUILD_D/api/libplayos.so"* "$DESKTOP/install/lib/"
    cp -a "$API_SRC/include/playos" "$DESKTOP/install/include/"
else
    echo "warning: no platform-api source at $API_SRC - desktop profile incomplete" >&2
fi

echo "==> Desktop profile: $(ls "$DESKTOP/raylib/lib" 2>/dev/null | wc -l) raylib file(s), $(ls "$DESKTOP/install/lib" 2>/dev/null | wc -l) libplayos file(s)"

echo "==> SDK ready at $SDK"
ls "$SDK/include/playos" | wc -l | xargs echo "    headers:"
ls "$SDK/lib" | sed 's/^/    /'
du -sh "$SDK/toolchain" 2>/dev/null | sed 's/^/    toolchain: /'
