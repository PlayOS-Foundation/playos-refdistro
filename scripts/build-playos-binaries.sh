#!/usr/bin/env bash
# build-playos-binaries.sh — clone/pull, build, and stage PlayOS compositor
# + shell into the ISO airootfs. Called by build-iso-*.sh before mkarchiso.
#
# Incremental: repos and build dirs are kept between runs. Only changed
# source files are recompiled (ninja). Delete /var/tmp/playos-iso-build
# manually if you need a clean build.
set -euo pipefail
export TMPDIR=/var/tmp   # ensure cmake/ninja/cc never use /tmp

AIROOTFS="${1:?usage: $0 <airootfs-dir>}"

BUILD_DIR="/var/tmp/playos-iso-build"
REPOS=(
  "https://github.com/PlayOS-Foundation/playos-platform-api.git"
  "https://github.com/PlayOS-Foundation/playos-runtime.git"
  "https://github.com/PlayOS-Foundation/playos-shell.git"
  "https://github.com/PlayOS-Foundation/playos-samples.git"
  "https://github.com/PlayOS-Foundation/playos-reference-devices.git"
)

echo "==> Syncing PlayOS repos"
mkdir -p "$BUILD_DIR"
for url in "${REPOS[@]}"; do
  name="$(basename "$url" .git)"
  if [ -d "$BUILD_DIR/$name/.git" ]; then
    git -C "$BUILD_DIR/$name" pull --ff-only
  else
    git clone --depth 1 "$url" "$BUILD_DIR/$name"
  fi
done

# ── Generate missing protocol headers (Arch wlroots packaging quirk) ─────
echo "==> Generating Wayland protocol headers"
PROTO_DIR="$BUILD_DIR/protocols"
mkdir -p "$PROTO_DIR"
wayland-scanner server-header \
  /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  "$PROTO_DIR/xdg-shell-protocol.h"

PROTO_CFLAGS="-I$PROTO_DIR"

# ── Build platform-api (core library) ─────────────────────────────────────
echo "==> Building playos-platform-api"
cmake -B "$BUILD_DIR/playos-platform-api/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -S "$BUILD_DIR/playos-platform-api"
cmake --build "$BUILD_DIR/playos-platform-api/build"

# ── Build runtime + compositor ────────────────────────────────────────────
echo "==> Building playos-runtime + compositor"
cmake -B "$BUILD_DIR/playos-runtime/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPLAYOS_BUILD_COMPOSITOR=ON \
  -DCMAKE_C_FLAGS="$PROTO_CFLAGS" \
  -S "$BUILD_DIR/playos-runtime"
cmake --build "$BUILD_DIR/playos-runtime/build"

# ── Build shell ───────────────────────────────────────────────────────────
echo "==> Building playos-shell"
cmake -B "$BUILD_DIR/playos-shell/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPLAYOS_SHELL_WAYLAND=ON \
  -S "$BUILD_DIR/playos-shell"
cmake --build "$BUILD_DIR/playos-shell/build"

# ── Build samples ─────────────────────────────────────────────────────────
echo "==> Building playos-samples (Wayland-only)"
cmake -B "$BUILD_DIR/playos-samples/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPLAYOS_SHELL_WAYLAND=ON \
  -DGLFW_BUILD_WAYLAND=ON \
  -DGLFW_BUILD_X11=OFF \
  -S "$BUILD_DIR/playos-samples"
cmake --build "$BUILD_DIR/playos-samples/build"

# ── Stage binaries into airootfs ──────────────────────────────────────────
echo "==> Staging binaries into airootfs"
mkdir -p "$AIROOTFS/usr/bin"

install -m 755 "$BUILD_DIR/playos-runtime/build/compositor/playos-compositor" \
  "$AIROOTFS/usr/bin/playos-compositor"
install -m 755 "$BUILD_DIR/playos-shell/build/playos-shell" \
  "$AIROOTFS/usr/bin/playos-shell"
install -m 755 "$BUILD_DIR/playos-runtime/build/playos-run" \
  "$AIROOTFS/usr/bin/playos-run"

# Stage samples where the shell finds them (../../playos-samples/build from /usr/bin)
mkdir -p "$AIROOTFS/playos-samples/build"
install -m 755 "$BUILD_DIR/playos-samples/build/hello-playos" \
  "$AIROOTFS/playos-samples/build/hello-playos"
install -m 755 "$BUILD_DIR/playos-samples/build/space-invaders" \
  "$AIROOTFS/playos-samples/build/space-invaders"

# ── Deploy device profiles (RFC-0006) ────────────────────────────────────
echo "==> Deploying device profiles"
mkdir -p "$AIROOTFS/etc/playos/device-profiles"

# Copy every device profile found in the reference-devices repo.
for device_dir in "$BUILD_DIR/playos-reference-devices"/*/; do
    profile="$device_dir/device-profile.toml"
    if [ -f "$profile" ]; then
        dev_name=$(basename "$device_dir")
        cp "$profile" "$AIROOTFS/etc/playos/device-profiles/$dev_name.toml"
        echo "    $dev_name"
    fi
done

echo "==> PlayOS binaries staged successfully"
