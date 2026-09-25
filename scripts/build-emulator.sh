#!/bin/sh
# build-emulator.sh — deliver a device-profile PlayOS game to the emulator and run it.
#
# The device artifact is a musl binary, so there is no emulator-specific build: only
# delivery. This is the *delivery* half of the emulator profile; scripts/emulator-run.sh
# is the run half. The runner stages the payload onto a playos-data image as
# /data/games/<id>/ — the only path init's `playos.autostart=<id>` lookup reads — boots
# the minimal `playos_emulator_defconfig` image, and asserts that init launched the game
# and that the compositor rendered it.
#
# There is deliberately no second staging location. An earlier version also copied the
# binary into the guest as usr/share/playos/emulator/game; nothing launches that path,
# so keeping it only invites "why doesn't my game start?".
#
# Design: playos-spec/src/sdk-emulator-profile.md
#
# Usage:
#   ./build-emulator.sh <device-build-dir | game-dir> [emulator-run.sh options...]
#
#   A game dir already carrying manifest.json is used as-is. A device build dir
#   (bin/game, no manifest) gets a synthesised manifest in a temp dir, so the existing
#   SDK output can be handed straight to the runner.
#
# Env:
#   PLAYOS_EMULATOR_PREPARE_ONLY=1   validate the artifact and print the recipe, do not run
#   PLAYOS_EMULATOR_OUTPUT=DIR       Buildroot output (default: output/emulator)
set -eu

SRC="${1:?usage: build-emulator.sh <device-build-dir | game-dir> [emulator-run.sh options...]}"
shift
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUTPUT="${PLAYOS_EMULATOR_OUTPUT:-$REPO/output/emulator}"
RUNNER="$HERE/emulator-run.sh"

[ -f "$RUNNER" ] || { echo "error: $RUNNER not found" >&2; exit 1; }

# ── Locate the artifact ────────────────────────────────────────────────────
GAME=""
for candidate in "$SRC/bin/game" "$SRC/game" "$SRC"; do
    [ -f "$candidate" ] && [ -x "$candidate" ] && GAME="$candidate" && break
done
if [ -z "$GAME" ]; then
    echo "error: no game binary under $SRC (build the device profile first:" >&2
    echo "       PLAYOS_SDK=.../playos-sdk ./sdk/scripts/build-device.sh <sample> $SRC)" >&2
    exit 1
fi

# The guest cannot run a glibc binary, and a silent failure here would look like an
# emulator bug rather than a wrong artifact.
if ! file "$GAME" | grep -q "ld-musl"; then
    echo "error: $GAME is not a musl binary - build it with the device profile" >&2
    file "$GAME" >&2
    exit 1
fi

for f in "$OUTPUT/images/bzImage" "$OUTPUT/images/rootfs.cpio"; do
    if [ ! -f "$f" ]; then
        echo "error: missing $f — run 'make emulator-build' first" >&2
        exit 1
    fi
done

# ── Hand the runner a game dir it understands ─────────────────────────────
WORK=""
if [ -f "$SRC/manifest.json" ]; then
    GAME_DIR="$SRC"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    GAME_DIR="$WORK"
    mkdir -p "$GAME_DIR/bin"
    cp "$GAME" "$GAME_DIR/bin/game"
    ID="$(basename "$(cd "$SRC" && pwd)")"
    cat > "$GAME_DIR/manifest.json" <<EOF
{"id": "com.playos.emulator.$ID", "name": "$ID", "executable": "bin/game", "api_version": 1}
EOF
    echo "==> no manifest.json in $SRC - synthesised id com.playos.emulator.$ID"
fi

echo "==> Emulator profile"
echo "    game:   $GAME"
echo "    image:  $OUTPUT  (minimal emulator defconfig)"
echo "    stages: /data/games/<id>/ in the guest"

if [ "${PLAYOS_EMULATOR_PREPARE_ONLY:-0}" = "1" ]; then
    echo "==> Prepared only; the runner command would be:"
    echo "    emulator-run.sh --game-dir $GAME_DIR --output $OUTPUT $*"
    exit 0
fi

exec bash "$RUNNER" --game-dir "$GAME_DIR" --output "$OUTPUT" "$@"
