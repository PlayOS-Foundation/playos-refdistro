#!/usr/bin/env bash
# Build PlayOS compositor and shell inside Alpine nspawn.
# Run inside the nspawn container before mkimage.sh.
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
SHELL_SRC="${PLAYOS_SHELL_SRC:-/mnt/playos-shell}"
RUNTIME_SRC="${PLAYOS_RUNTIME_SRC:-/mnt/playos-runtime}"
PLATFORM_SRC="${PLAYOS_PLATFORM_SRC:-/mnt/playos-platform-api}"
BUILD_DIR=/var/tmp/playos-build

echo "==> Installing PlayOS build dependencies"
apk add --no-cache \
    cmake ninja g++ make git ccache \
    wlroots0.19-dev wayland-dev wayland-protocols \
    libxkbcommon-dev libdrm-dev mesa-dev \
    raylib-dev glfw-dev seatd \
    2>&1 | tail -5

# ccache: speed up repeated C++ builds with compiler cache.
export CCACHE_DIR=/var/cache/ccache
export PATH="/usr/lib/ccache/bin:$PATH"
mkdir -p "$CCACHE_DIR"

mkdir -p "$BUILD_DIR"

# ── Build playos-platform-api ─────────────────────────────────────
echo "==> Building playos-platform-api"
cmake -B "$BUILD_DIR/platform-api" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "$PLATFORM_SRC"
cmake --build "$BUILD_DIR/platform-api"

# ── Build playos-runtime (compositor) ─────────────────────────────
echo "==> Building playos-runtime + compositor"
cmake -B "$BUILD_DIR/runtime" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DPLAYOS_BUILD_COMPOSITOR=ON \
    "$RUNTIME_SRC"
cmake --build "$BUILD_DIR/runtime"

# ── Build playos-shell ────────────────────────────────────────────
# Use Alpine system raylib (5.0) instead of FetchContent raylib 6.0.
# Mount sibling repos so the shell finds them locally.
echo "==> Building playos-shell (Wayland)"
cmake -B "$BUILD_DIR/shell" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DPLAYOS_SHELL_WAYLAND=ON \
    -DPLAYOS_USE_SYSTEM_RAYLIB=ON \
    "$SHELL_SRC"
cmake --build "$BUILD_DIR/shell"

# ── Install ────────────────────────────────────────────────────────
echo "==> Installing binaries"
install -m 0755 "$BUILD_DIR/runtime/compositor/playos-compositor" /usr/bin/playos-compositor
install -m 0755 "$BUILD_DIR/shell/playos-shell"             /usr/bin/playos-shell

# ── OpenRC init scripts ────────────────────────────────────────────
install -m 0755 "$ROOT/alpine/init.d/playos-compositor"     /etc/init.d/playos-compositor
install -m 0755 "$ROOT/alpine/init.d/playos-installer"      /etc/init.d/playos-installer

# ── Add to playos-visual runlevel ──────────────────────────────────
ln -sf /etc/init.d/playos-compositor /etc/runlevels/playos-visual/playos-compositor 2>/dev/null || true

# ── Build samples (hello-playos, space-invaders) ──────────────────
SAMPLES_SRC="${PLAYOS_SAMPLES_SRC:-/mnt/playos-samples}"
SAMPLES_OUT="${PLAYOS_SAMPLES_OUT:-/workspace/.build/samples-out}"
if [ -f "$SAMPLES_SRC/CMakeLists.txt" ]; then
    echo "==> Building PlayOS samples (system raylib)"
    cmake -B "$BUILD_DIR/samples" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DPLAYOS_USE_SYSTEM_RAYLIB=ON \
        "$SAMPLES_SRC"
    cmake --build "$BUILD_DIR/samples" --target hello-playos space-invaders
    mkdir -p "$SAMPLES_OUT"
    cp "$BUILD_DIR/samples/hello-playos"   "$SAMPLES_OUT/hello-playos"
    cp "$BUILD_DIR/samples/space-invaders" "$SAMPLES_OUT/space-invaders"
    echo "==> Samples built: $(ls "$SAMPLES_OUT")"
fi

echo "==> PlayOS compositor and shell built successfully"
