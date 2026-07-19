#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"
WORK="${PLAYOS_WORKDIR:-/var/tmp/playos-mkimage}"
APORTS="${PLAYOS_APORTS_DIR:-/var/tmp/aports}"
APORTS_BRANCH="${PLAYOS_APORTS_BRANCH:-3.24-stable}"
TAG="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"

if [[ "$TAG" == "edge" ]]; then
  echo "error: unpinned Alpine edge builds are forbidden" >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$OUT" "$WORK"

if [[ ! -d "$APORTS/.git" ]]; then
  git clone --depth 1 --branch "$APORTS_BRANCH"     https://gitlab.alpinelinux.org/alpine/aports.git "$APORTS"
else
  git -C "$APORTS" fetch --depth 1 origin "$APORTS_BRANCH"
  git -C "$APORTS" checkout --detach FETCH_HEAD
fi

install -m 0755 "$ROOT/alpine/mkimg.playos.sh" "$APORTS/scripts/mkimg.playos.sh"
install -m 0755 "$ROOT/alpine/genapkovl-playos.sh" "$APORTS/scripts/genapkovl-playos.sh"

if ! ls /root/.abuild/*.rsa >/dev/null 2>&1; then
  abuild-keygen -a -n
fi

cd "$APORTS"
sh scripts/mkimage.sh   --tag "$TAG"   --outdir "$OUT"   --workdir "$WORK"   --arch "$ARCH"   --repository "https://dl-cdn.alpinelinux.org/alpine/$TAG/main"   --repository "https://dl-cdn.alpinelinux.org/alpine/$TAG/community"   --profile playos

echo "PlayOS Alpine image written to $OUT"
