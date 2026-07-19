#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"
WORK="${PLAYOS_WORKDIR:-/var/tmp/playos-mkimage}"
APORTS="${PLAYOS_APORTS_DIR:-/var/cache/playos-aports}"
APORTS_BRANCH="${PLAYOS_APORTS_BRANCH:-3.24-stable}"
TAG="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"

if [[ "$TAG" == "edge" ]]; then
    echo "error: unpinned Alpine edge builds are forbidden" >&2
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$OUT" "$WORK"

# Ensure git trusts the aports directory (ownership may differ in nspawn)
git config --global --add safe.directory "$APORTS" 2>/dev/null || true

if [[ ! -d "$APORTS/.git" ]]; then
    git clone --depth 1 --branch "$APORTS_BRANCH"         https://gitlab.alpinelinux.org/alpine/aports.git "$APORTS"
else
    git -C "$APORTS" fetch --depth 1 origin "$APORTS_BRANCH"
    git -C "$APORTS" checkout --detach FETCH_HEAD
fi

install -m 0755 "$ROOT/alpine/mkimg.playos.sh"     "$APORTS/scripts/mkimg.playos.sh"
install -m 0755 "$ROOT/alpine/genapkovl-playos.sh"     "$APORTS/scripts/genapkovl-playos.sh"

# apk-tools 3.0.6+: --no-chown conflicts with root (implies usermode).
# Remove it — we run as root in nspawn, so chown is fine.
sed -i 's/--no-chown//g' "$APORTS/scripts/mkimage.sh"

# Create a non-root build user for abuild-keygen (Alpine-native requirement).
if ! id build >/dev/null 2>&1; then
    adduser -D build
    addgroup build abuild
fi

if ! find /home/build/.abuild -maxdepth 1 -name '*.rsa' -print -quit 2>/dev/null | grep -q .; then
    su -s /bin/sh -c "abuild-keygen -a -n" build
fi

# Copy the generated key to /etc/apk/keys so mkimage finds it.
mkdir -p /etc/apk/keys
cp /home/build/.abuild/*.rsa.pub /etc/apk/keys/ 2>/dev/null || true

# Alpine mkimage.sh uses sudo internally; running as root in nspawn so
# set SUDO to empty (skip sudo) and ensure abuild keys are in place.
cd "$APORTS"
export SUDO=
mkdir -p "$HOME/.abuild"
cp /home/build/.abuild/*.rsa /home/build/.abuild/*.rsa.pub "$HOME/.abuild/" 2>/dev/null || true

sh scripts/mkimage.sh     --tag "$TAG"     --outdir "$OUT"     --workdir "$WORK"     --arch "$ARCH"     --repository "https://dl-cdn.alpinelinux.org/alpine/$TAG/main"     --repository "https://dl-cdn.alpinelinux.org/alpine/$TAG/community"     --profile playos

echo "PlayOS Alpine image written to $OUT"
