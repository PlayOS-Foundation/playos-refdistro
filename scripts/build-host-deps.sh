#!/usr/bin/env bash
# build-host-deps.sh — Build the pinned native Wayland/wlroots dependency stack
#                       required for HOST-NATIVE builds of playos-compositor and
#                       playos-shell.
#
# WHY THIS EXISTS
#   playos-compositor requires wlroots 0.20 (see CMakeLists.txt:
#   pkg_check_modules(WLROOTS wlroots-0.20 REQUIRED)). Ubuntu 24.04 LTS ships
#   versions that are too old for wlroots 0.20:
#     wayland          1.22.0  (wlroots needs >= 1.24.0)
#     wayland-protocols 1.45    (wlroots needs >= 1.47)
#     libdrm           2.4.125 (wlroots needs >= 2.4.129)
#     libxkbcommon     1.6.0   (wlroots needs >= 1.8.0)
#     pixman           0.42.2  (wlroots needs >= 0.43.0)
#   so a newer stack must be built from source. It is installed into an ISOLATED
#   prefix (default /opt/playos-deps) and activated per-shell with env.sh.
#
# WHY NOT /usr/local
#   A previous attempt installed these into /usr/local, but /usr/local/lib* is on
#   the global ldconfig path, so the newer libraries shadowed the distro's own
#   copies at RUNTIME for every program. The isolated prefix avoids that entirely:
#   nothing sees these libraries unless env.sh is sourced.
#
# USAGE
#   sudo bash scripts/build-host-deps.sh
#   PLAYOS_DEPS_PREFIX=$HOME/playos-deps bash scripts/build-host-deps.sh
#
#   Activate afterwards:
#   source /opt/playos-deps/env.sh
#
# Version pins live in versions.lock (HOST-native build dependencies section).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/playos_log.sh"

# ── Configuration ───────────────────────────────────────────────────
PREFIX="${PLAYOS_DEPS_PREFIX:-/opt/playos-deps}"
JOBS="${PLAYOS_DEPS_JOBS:-$(nproc)}"

# Pinned versions — keep in sync with versions.lock
WAYLAND_TAG=1.24.0
WAYLAND_PROTOCOLS_TAG=1.47
LIBDRM_TAG=libdrm-2.4.134
XKBCOMMON_TAG=xkbcommon-1.9.2
PIXMAN_TAG=pixman-0.46.4
SEATD_TAG=0.9.1
WLROOTS_TAG=0.20.2

WAYLAND_GIT=https://gitlab.freedesktop.org/wayland/wayland.git
WAYLAND_PROTOCOLS_GIT=https://gitlab.freedesktop.org/wayland/wayland-protocols.git
LIBDRM_GIT=https://gitlab.freedesktop.org/mesa/drm.git
XKBCOMMON_GIT=https://github.com/xkbcommon/libxkbcommon.git
PIXMAN_GIT=https://gitlab.freedesktop.org/pixman/pixman.git
SEATD_GIT=https://git.sr.ht/~kennylevinsen/seatd
WLROOTS_GIT=https://gitlab.freedesktop.org/wlroots/wlroots.git

SRC_DIR="$PREFIX/src"
BUILD_DIR="$PREFIX/build"

# Debian-style multiarch libdir so pkg-config and ld both find the libs.
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
: "${MULTIARCH:=$(gcc -print-multiarch 2>/dev/null || true)}"
: "${MULTIARCH:=lib}"
LIBDIR="lib/$MULTIARCH"

export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/$LIBDIR/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$PREFIX/$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

playos_log_step "PlayOS host dependency build"
playos_log_info "deps" "prefix=$PREFIX  libdir=$LIBDIR  jobs=$JOBS"

# ── Permission check ────────────────────────────────────────────────
if ! mkdir -p "$PREFIX" 2>/dev/null || [[ ! -w "$PREFIX" ]]; then
    playos_log_fatal "deps" "Prefix $PREFIX is not writable. Run with sudo, or set PLAYOS_DEPS_PREFIX to a writable path."
fi
mkdir -p "$SRC_DIR" "$BUILD_DIR"

# ── Helpers ─────────────────────────────────────────────────────────
_clone() {
    local name="$1" git_url="$2" tag="$3"
    local dst="$SRC_DIR/$name"
    if [[ -d "$dst/.git" ]]; then
        playos_log_debug "deps" "$name already cloned"
    else
        playos_log_info "deps" "Cloning $name ($tag)..."
        rm -rf "$dst"
        git clone --depth 1 --branch "$tag" "$git_url" "$dst"
    fi
}

_meson_build() {
    local name="$1"
    shift
    local src="$SRC_DIR/$name"
    local bdir="$BUILD_DIR/$name"
    rm -rf "$bdir"
    meson setup "$bdir" "$src" --prefix="$PREFIX" --libdir="$LIBDIR" "$@"
    meson compile -C "$bdir" -j "$JOBS"
    meson install -C "$bdir"
    playos_log_ok "deps" "$name installed"
}

# ── Fast path: already built ────────────────────────────────────────
FINAL_PC="$PREFIX/$LIBDIR/pkgconfig/wlroots-0.20.pc"
if [[ -f "$FINAL_PC" ]] && [[ "${FORCE:-0}" != "1" ]]; then
    v="$(grep -m1 '^Version:' "$FINAL_PC" | awk '{print $2}')"
    playos_log_ok "deps" "Dependencies already built (wlroots $v). Set FORCE=1 to rebuild."
    playos_log_info "deps" "Activate with: source $PREFIX/env.sh"
    exit 0
fi

# ── Build in dependency order ───────────────────────────────────────
playos_log_step "Building Wayland $WAYLAND_TAG"
_clone wayland "$WAYLAND_GIT" "$WAYLAND_TAG"
_meson_build wayland -Ddocumentation=false -Ddtd_validation=false

playos_log_step "Building wayland-protocols $WAYLAND_PROTOCOLS_TAG"
_clone wayland-protocols "$WAYLAND_PROTOCOLS_GIT" "$WAYLAND_PROTOCOLS_TAG"
_meson_build wayland-protocols -Dtests=false

playos_log_step "Building libdrm $LIBDRM_TAG"
_clone libdrm "$LIBDRM_GIT" "$LIBDRM_TAG"
_meson_build libdrm -Dtests=false

playos_log_step "Building pixman $PIXMAN_TAG"
_clone pixman "$PIXMAN_GIT" "$PIXMAN_TAG"
_meson_build pixman

playos_log_step "Building libxkbcommon $XKBCOMMON_TAG"
_clone libxkbcommon "$XKBCOMMON_GIT" "$XKBCOMMON_TAG"
_meson_build libxkbcommon \
    -Denable-docs=false \
    -Denable-tools=false \
    -Denable-x11=true \
    -Denable-wayland=false

# wlroots 0.20 session support needs libseat >= 0.9, newer than Ubuntu 22.04
# ships, so build it into the isolated prefix (logind backend off: we only
# need the library for linking; CI does not run a session).
playos_log_step "Building seatd $SEATD_TAG"
_clone seatd "$SEATD_GIT" "$SEATD_TAG"
_meson_build seatd \
    -Dlibseat-logind=disabled \
    -Dman-pages=disabled \
    -Dexamples=disabled

playos_log_step "Building wlroots $WLROOTS_TAG"
_clone wlroots "$WLROOTS_GIT" "$WLROOTS_TAG"
_meson_build wlroots \
    -Dbackends=x11,libinput \
    -Dxwayland=enabled \
    -Drenderers=gles2,vulkan \
    -Dallocators=gbm \
    -Dsession=enabled \
    -Dexamples=false

# ── Emit env.sh ─────────────────────────────────────────────────────
ENV_FILE="$PREFIX/env.sh"
cat > "$ENV_FILE" <<EOF
# PlayOS host deps environment — source this before native host builds of
# playos-compositor or playos-shell. Do NOT add $PREFIX to ldconfig.
export PATH="$PREFIX/bin:\$PATH"
export PKG_CONFIG_PATH="$PREFIX/$LIBDIR/pkgconfig:$PREFIX/share/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$PREFIX\${CMAKE_PREFIX_PATH:+:\$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/$LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
chmod +x "$ENV_FILE"

playos_log_step "Complete"
playos_log_ok "deps" "Host dependencies installed to $PREFIX"
playos_log_info "deps" "Activate with: source $PREFIX/env.sh"
