#!/usr/bin/env bash
# Build PlayOS compositor and shell inside nspawn container.
# Runs inside the nspawn container before disk population.
# Auto-detects Alpine vs Arch and uses the right package manager.
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
SHELL_SRC="${PLAYOS_SHELL_SRC:-/mnt/playos-shell}"
RUNTIME_SRC="${PLAYOS_RUNTIME_SRC:-/mnt/playos-runtime}"
PLATFORM_SRC="${PLAYOS_PLATFORM_SRC:-/mnt/playos-platform-api}"
BUILD_DIR=/var/tmp/playos-build

# ── Detect distro and install build deps if needed ──────────────────
if command -v apk >/dev/null 2>&1; then
    echo "==> Installing PlayOS build dependencies (Alpine)"
    apk add --no-cache \
        cmake ninja g++ make git ccache \
        wlroots0.19-dev wayland-dev wayland-protocols \
        libxkbcommon-dev libdrm-dev mesa-dev \
        glfw-dev seatd curl \
        libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev \
        gptfdisk parted e2fsprogs zstd \
        dosfstools util-linux coreutils sgdisk \
        2>&1 | tail -5
elif command -v pacman >/dev/null 2>&1; then
    echo "==> Arch build deps should be pre-installed (setup-ubuntu-build-host.sh)"
    # Verify cmake is available
    command -v cmake >/dev/null 2>&1 || {
        echo "error: cmake not found — run setup-ubuntu-build-host.sh first" >&2
        exit 1
    }
else
    echo "error: neither apk nor pacman found — unsupported build environment" >&2
    exit 1
fi

# ccache: speed up repeated C++ builds with compiler cache.
export CCACHE_DIR=/var/cache/ccache
export PATH="/usr/lib/ccache/bin:$PATH"
mkdir -p "$CCACHE_DIR"

mkdir -p "$BUILD_DIR"

# ── Build Raylib 6.0 from source ──────────────────────────────────
# Alpine 3.24 ships raylib 5.0 (libraylib.so.450).  Build 6.0
# (libraylib.so.600) from source and install to /usr so the shell
# and samples pick it up via pkg-config.
RAYLIB_VER=6.0
RAYLIB_SRC=/var/tmp/raylib-${RAYLIB_VER}
if [ ! -f "$RAYLIB_SRC/CMakeLists.txt" ]; then
    echo "==> Downloading Raylib ${RAYLIB_VER}"
    curl -sSL "https://github.com/raysan5/raylib/archive/refs/tags/${RAYLIB_VER}.tar.gz" \
        -o /var/tmp/raylib-${RAYLIB_VER}.tar.gz
    tar xzf /var/tmp/raylib-${RAYLIB_VER}.tar.gz -C /var/tmp
fi
echo "==> Building Raylib ${RAYLIB_VER}"
cmake -B /var/tmp/raylib-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DBUILD_SHARED_LIBS=ON \
    -DUSE_EXTERNAL_GLFW=ON \
    -DBUILD_EXAMPLES=OFF \
    "$RAYLIB_SRC"
cmake --build /var/tmp/raylib-build
cmake --install /var/tmp/raylib-build

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
# Use system-installed Raylib 6.0 instead of FetchContent.
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

# ── Init script — OpenRC for Alpine, systemd for Arch ──────────────
if command -v apk >/dev/null 2>&1; then
    install -m 0755 "$ROOT/alpine/init.d/playos-compositor" /etc/init.d/playos-compositor
    ln -sf /etc/init.d/playos-compositor /etc/runlevels/playos-visual/playos-compositor 2>/dev/null || true
else
    echo "    Skipping OpenRC init (Arch uses systemd units in build-disk-image-arch.sh)"
fi

# ── Build samples (hello-playos, space-invaders, input-debug) ──────────────────
SAMPLES_SRC="${PLAYOS_SAMPLES_SRC:-/mnt/playos-samples}"
SAMPLES_OUT="${PLAYOS_SAMPLES_OUT:-/workspace/.build/samples-out}"
if [ -f "$SAMPLES_SRC/CMakeLists.txt" ]; then
    echo "==> Building PlayOS samples (system raylib)"
    cmake -B "$BUILD_DIR/samples" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DPLAYOS_USE_SYSTEM_RAYLIB=ON \
        "$SAMPLES_SRC"
    cmake --build "$BUILD_DIR/samples" --target hello-playos space-invaders input-debug
    mkdir -p "$SAMPLES_OUT"
    cp "$BUILD_DIR/samples/hello-playos"   "$SAMPLES_OUT/hello-playos"
    cp "$BUILD_DIR/samples/space-invaders" "$SAMPLES_OUT/space-invaders"
    cp "$BUILD_DIR/samples/input-debug"    "$SAMPLES_OUT/input-debug"
    echo "==> Samples built: $(ls "$SAMPLES_OUT")"
fi

# ── Build hid-asus-ally kernel module (ROG Ally controller driver) ──
# Only needed on Alpine — CachyOS kernels include asus-armoury in-tree.
if command -v apk >/dev/null 2>&1; then
    /workspace/scripts/build-hid-asus-ally.sh
else
    echo "==> Skipping hid-asus-ally (CachyOS kernel bundles it in-tree)"
fi

echo "==> PlayOS compositor and shell built successfully"
