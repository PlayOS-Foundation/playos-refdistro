#!/usr/bin/env bash
# build-playos-binaries.sh — clone, build, and stage PlayOS compositor + shell
# into the ISO airootfs. Called by build-iso-*.sh before mkarchiso.
set -euo pipefail

AIROOTFS="${1:?usage: $0 <airootfs-dir>}"

BUILD_DIR="/var/tmp/playos-iso-build"
REPOS=(
  "https://github.com/PlayOS-Foundation/playos-platform-api.git"
  "https://github.com/PlayOS-Foundation/playos-runtime.git"
  "https://github.com/PlayOS-Foundation/playos-shell.git"
  "https://github.com/PlayOS-Foundation/playos-samples.git"
)

echo "==> Cloning PlayOS repos"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
for url in "${REPOS[@]}"; do
  name="$(basename "$url" .git)"
  git clone --depth 1 "$url" "$BUILD_DIR/$name"
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
echo "==> Building playos-samples"
cmake -B "$BUILD_DIR/playos-samples/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPLAYOS_SHELL_WAYLAND=ON \
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

# ── Cleanup ───────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
echo "==> PlayOS binaries staged successfully"
