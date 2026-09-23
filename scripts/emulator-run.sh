#!/usr/bin/env bash
# emulator-run.sh — boot a device (musl) build in the PlayOS emulator (S15-T7)
#
# Installs a built device-profile game onto a `playos-data` disk and boots the
# minimal `playos_emulator_defconfig` image with `playos.autostart=<game-id>`,
# so a device artifact can be exercised without hardware. init launches the
# game through the same path as the shell's LaunchGame IPC request.
#
# Design: playos-spec/src/sdk-emulator-profile.md
#
# Usage:
#   bash scripts/emulator-run.sh --game-dir DIR [--game-id ID] [options]
#
# Options:
#   --game-dir DIR    payload: manifest.json + the executable + assets
#                     (see sdk/scripts/build-emulator.sh, which stages it)
#   --game-id ID      game id; default: read from DIR/manifest.json "id"
#   --output DIR      Buildroot output (default: output/emulator)
#   --timeout SECS    QEMU run time before it is stopped (default: 90)
#   --display MODE    none (headless, default) | sdl (interactive window)
#   --gamepad EVDEV   pass a host input device through to the guest, e.g.
#                     /dev/input/event5 (-object input-linux); needs read access
#   --keep            keep the data disk, serial log and extracted guest logs
#
# Exit: 0 when init launched the game and the compositor rendered it; non-zero
# with the evidence printed otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GAME_DIR=""
GAME_ID=""
OUTPUT="${QEMU_OUTPUT:-$REPO_DIR/output/emulator}"
TIMEOUT=90
TIMEOUT_SET=0
DISPLAY_MODE="none"
GAMEPAD=""
KEEP=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --game-dir)    GAME_DIR="${2:-}"; shift 2 ;;
        --game-dir=*)  GAME_DIR="${1#*=}"; shift ;;
        --game-id)     GAME_ID="${2:-}"; shift 2 ;;
        --game-id=*)   GAME_ID="${1#*=}"; shift ;;
        --output)      OUTPUT="${2:-}"; shift 2 ;;
        --output=*)    OUTPUT="${1#*=}"; shift ;;
        --timeout)     TIMEOUT="${2:-}"; TIMEOUT_SET=1; shift 2 ;;
        --timeout=*)   TIMEOUT="${1#*=}"; TIMEOUT_SET=1; shift ;;
        --display)     DISPLAY_MODE="${2:-}"; shift 2 ;;
        --display=*)   DISPLAY_MODE="${1#*=}"; shift ;;
        --gamepad)     GAMEPAD="${2:-}"; shift 2 ;;
        --gamepad=*)   GAMEPAD="${1#*=}"; shift ;;
        --keep)        KEEP=1; shift ;;
        -h|--help)     sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

# Without /dev/kvm QEMU falls back to TCG, which is roughly an order of
# magnitude slower to boot and render. Give the run room unless the caller
# chose a timeout explicitly (`sudo usermod -aG kvm $USER` for the fast path).
if [[ "$TIMEOUT_SET" == "0" && ! -r /dev/kvm ]]; then
    TIMEOUT=300
    echo "==> note: /dev/kvm is not readable — QEMU will use TCG; timeout extended to ${TIMEOUT}s" >&2
fi

[[ -n "$GAME_DIR" ]] || die "--game-dir is required"
[[ -d "$GAME_DIR" ]] || die "game dir not found: $GAME_DIR"
[[ -f "$GAME_DIR/manifest.json" ]] || die "no manifest.json in $GAME_DIR"

# ── Game id (from the manifest unless given) ──────────────────────────────
if [[ -z "$GAME_ID" ]]; then
    if command -v jq >/dev/null 2>&1; then
        GAME_ID="$(jq -r '.id // empty' "$GAME_DIR/manifest.json")"
    else
        GAME_ID="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
                       "$GAME_DIR/manifest.json" | head -1)"
    fi
fi
[[ -n "$GAME_ID" ]] || die "could not determine the game id (pass --game-id)"

GAME_EXE="bin/game"
if command -v jq >/dev/null 2>&1; then
    tmp_exe="$(jq -r '.executable // empty' "$GAME_DIR/manifest.json")"
    [[ -n "$tmp_exe" ]] && GAME_EXE="$tmp_exe"
fi
[[ -x "$GAME_DIR/$GAME_EXE" ]] || die "game executable not found/executable: $GAME_DIR/$GAME_EXE"

# ── Boot artifacts ────────────────────────────────────────────────────────
BZIMAGE=""
INITRAMFS=""
for candidate in "$OUTPUT/images/bzImage" "$OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    [[ -f "$candidate" ]] && BZIMAGE="$candidate" && break
done
for candidate in "$OUTPUT/images/rootfs.cpio" "$OUTPUT/images/rootfs.initramfs"; do
    [[ -f "$candidate" ]] && INITRAMFS="$candidate" && break
done
[[ -n "$BZIMAGE" ]]   || die "kernel not found under $OUTPUT — run 'make emulator-build' first"
[[ -n "$INITRAMFS" ]] || die "initramfs not found under $OUTPUT — run 'make emulator-build' first"

OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
for candidate in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
                 /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF.fd; do
    if [[ ! -f "$OVMF_CODE" && -f "$candidate" ]]; then OVMF_CODE="$candidate"; fi
done
[[ -f "$OVMF_CODE" ]] || die "OVMF firmware not found (install the 'ovmf' package)"

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found"
command -v mke2fs >/dev/null 2>&1 || die "mke2fs not found (install e2fsprogs)"

echo "==> PlayOS emulator run"
echo "    game:      $GAME_ID ($GAME_DIR/$GAME_EXE)"
echo "    image:     $OUTPUT"
echo "    kernel:    $BZIMAGE"
echo "    initramfs: $INITRAMFS"

# ── Assemble the playos-data disk ─────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/playos-emulator.XXXXXX")"
cleanup() {
    if [[ "$KEEP" == "1" ]]; then
        echo "==> Kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

DATA_ROOT="$WORK/root"
mkdir -p "$DATA_ROOT/games/$GAME_ID"
cp -a "$GAME_DIR/." "$DATA_ROOT/games/$GAME_ID/"
chmod -R u+rwX,go+rX "$DATA_ROOT/games/$GAME_ID"

DATA_IMG="$WORK/playos-data.img"
echo "==> Creating playos-data disk (512M, ext4, game installed)"
truncate -s 512M "$DATA_IMG"
# mke2fs -d populates the filesystem from a directory tree, so no loop mount
# (and no root) is needed to install the game.
mke2fs -q -t ext4 -L playos-data -d "$DATA_ROOT" "$DATA_IMG"

SERIAL_LOG="$WORK/serial.log"
OVMF_VARS_TMP="$WORK/OVMF_VARS.fd"
if [[ -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS" "$OVMF_VARS_TMP"
else
    truncate -s 4M "$OVMF_VARS_TMP"
fi

QEMU_EXTRA=()
case "$DISPLAY_MODE" in
    none) QEMU_EXTRA+=(-display none) ;;
    sdl)  QEMU_EXTRA+=(-display sdl,gl=off) ;;
    *)    die "--display must be none or sdl" ;;
esac
[[ -n "$GAMEPAD" ]] && QEMU_EXTRA+=(-object "input-linux,id=gamepad0,evdev=$GAMEPAD")

echo "==> Booting (${TIMEOUT}s, display=$DISPLAY_MODE, autostart=$GAME_ID)"
set +e
timeout -k 5 "$TIMEOUT" qemu-system-x86_64 \
    -m 1024M \
    -machine q35,accel=kvm:tcg \
    -cpu qemu64 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_TMP" \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -vga none \
    -drive if=none,id=data,format=raw,file="$DATA_IMG" \
    -device virtio-blk-pci,drive=data \
    -device virtio-gpu-pci,xres=1280,yres=720 \
    -device virtio-keyboard-pci \
    -append "console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200n8 quiet playos.autostart=$GAME_ID" \
    -serial "file:$SERIAL_LOG" \
    -no-reboot \
    "${QEMU_EXTRA[@]}"
QEMU_EXIT=$?
set -e
echo "    qemu exited ($QEMU_EXIT; 124 = timeout, expected)"

# ── Verify: init launched the game, and the compositor rendered it ────────
fail=0

if grep -q "autostart requested - launching game $GAME_ID" "$SERIAL_LOG" 2>/dev/null; then
    echo "  [ok]   init honoured playos.autostart=$GAME_ID"
else
    echo "  [FAIL] no autostart line in the serial log"
    fail=1
fi

if grep -q "spawning game: $GAME_ID" "$SERIAL_LOG" 2>/dev/null; then
    echo "  [ok]   device artifact passed manifest/exec/sandbox checks"
else
    echo "  [FAIL] the game was not spawned"
    fail=1
fi

# The compositor's stderr lives on /data, not the serial console. QEMU is
# killed rather than shut down, so the ext4 journal still holds the pending
# metadata — replay it on a private copy (never the boot disk) before reading
# with debugfs (no mount, no root).
READ_IMG="$DATA_IMG"
if command -v e2fsck >/dev/null 2>&1; then
    if cp --reflink=auto "$DATA_IMG" "$WORK/read.img" 2>/dev/null || cp "$DATA_IMG" "$WORK/read.img" 2>/dev/null; then
        e2fsck -fy "$WORK/read.img" >/dev/null 2>&1 || true
        READ_IMG="$WORK/read.img"
    fi
fi

COMPOSITOR_LOG="$WORK/compositor-stderr.log"
if debugfs -R "cat /log/compositor-stderr.log" "$READ_IMG" >"$COMPOSITOR_LOG" 2>/dev/null || \
   debugfs -c -R "cat /log/compositor-stderr.log" "$READ_IMG" >"$COMPOSITOR_LOG" 2>/dev/null; then
    # debugfs pads with NULs, which makes grep treat the log as binary.
    tr -d '\0' < "$COMPOSITOR_LOG" > "$COMPOSITOR_LOG.txt"
    if grep -aEq "game=[1-9][0-9]*" "$COMPOSITOR_LOG.txt"; then
        game_fps="$(grep -aoE 'game=[0-9]+' "$COMPOSITOR_LOG.txt" | tail -1)"
        echo "  [ok]   compositor rendered the game (${game_fps#game=} commits/s)"
    elif grep -aq "game surface added to scene" "$COMPOSITOR_LOG.txt"; then
        echo "  [ok]   compositor added the game surface (no commit-rate sample yet)"
    else
        echo "  [FAIL] compositor reported no game surface"
        fail=1
    fi
else
    echo "  [warn] could not read the guest compositor log"
    fail=1
fi

if [[ -n "$GAMEPAD" ]]; then
    echo "  [note] host device $GAMEPAD passed through; gamepad fidelity is a"
    echo "         human check (see sdk-emulator-profile.md)"
fi

if [[ "$fail" == "0" ]]; then
    echo "==> emulator run PASSED"
else
    echo "==> emulator run FAILED — re-run with --keep and inspect $WORK/serial.log" >&2
fi
exit "$fail"
