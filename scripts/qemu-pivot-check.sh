#!/usr/bin/env bash
# qemu-pivot-check.sh — Exercise the A/B slot pivot and forced rollback in QEMU
#
# Builds a synthetic installed disk (GPT with ESP, playos-a, playos-b,
# playos-data) from the Ally rootfs.squashfs, boots it via the QEMU initramfs
# playos-init, and verifies:
#
#   Scenario A — normal pivot into the raw squashfs active slot.
#   Scenario B — forced rollback when boot_count >= 3 && health != "good",
#                verified by reading boot.json back out of the ESP.
#
# This is the QEMU stand-in for the ROG Ally installed-disk path while no
# Ally hardware is available.
#
# Usage:
#   bash scripts/qemu-pivot-check.sh [--timeout SECONDS]
#
# Environment:
#   QEMU_OUTPUT      — Buildroot QEMU output dir (default: output/qemu)
#   ALLY_OUTPUT      — Buildroot Ally output dir (default: output/ally)
#   INSTALLED_IMG    — path for the synthetic disk (default: output/qemu/images/installed.img)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$SCRIPT_DIR/lib/playos_log.sh"

# ── Argument parsing ───────────────────────────────────────────────
TIMEOUT=30
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT="${2:-30}"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--timeout SECONDS]"
            echo "Build a synthetic installed disk and verify A/B pivot + rollback in QEMU."
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--timeout SECONDS]" >&2
            exit 2
            ;;
        *)
            TIMEOUT="$1"
            shift
            ;;
    esac
done

# ── Configuration ──────────────────────────────────────────────────
QEMU_OUTPUT="${QEMU_OUTPUT:-$ROOT_DIR/output/qemu}"
ALLY_OUTPUT="${ALLY_OUTPUT:-$ROOT_DIR/output/ally}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
INSTALLED_IMG="${INSTALLED_IMG:-$QEMU_OUTPUT/images/installed.img}"
WORK_DIR="$(mktemp -d)"

playos_log_step "PlayOS QEMU A/B Pivot Check"

# ── Resolve artifacts ──────────────────────────────────────────────
BZIMAGE=""
INITRAMFS=""

for candidate in "$QEMU_OUTPUT/images/bzImage" "$QEMU_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then
        BZIMAGE="$candidate"
        playos_log_ok "find" "Kernel: $BZIMAGE"
        break
    fi
done

for candidate in "$QEMU_OUTPUT/images/rootfs.cpio" "$QEMU_OUTPUT/images/rootfs.initramfs"; do
    if [[ -f "$candidate" ]]; then
        INITRAMFS="$candidate"
        playos_log_ok "find" "initramfs: $INITRAMFS"
        break
    fi
done

if [[ -z "$BZIMAGE" ]]; then
    playos_log_fatal "find" "Kernel image not found. Run 'make qemu-build' first."
fi
if [[ -z "$INITRAMFS" ]]; then
    playos_log_fatal "find" "initramfs not found. Run 'make qemu-build' first."
fi

ROOTFS_SQUASHFS="$ALLY_OUTPUT/images/rootfs.squashfs"
if [[ ! -f "$ROOTFS_SQUASHFS" ]]; then
    playos_log_fatal "find" "Ally rootfs.squashfs not found at $ROOTFS_SQUASHFS. Run 'make ally-build' first."
fi

# ── OVMF discovery ─────────────────────────────────────────────────
if [[ ! -f "$OVMF_CODE" ]]; then
    for candidate in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd \
        /usr/share/qemu/OVMF.fd; do
        if [[ -f "$candidate" ]]; then
            OVMF_CODE="$candidate"
            break
        fi
    done
fi
if [[ ! -f "$OVMF_CODE" ]]; then
    playos_log_fatal "boot" "OVMF firmware not found. Install the 'ovmf' package."
fi
playos_log_info "boot" "Using OVMF: $OVMF_CODE"

# ── Partition geometry (sectors; 512 bytes/sector) ────────────────
# 512 MiB disk, GPT. Sector layout:
#   ESP        2048   .. 133119  (64 MiB,  ef00, name ESP)
#   playos-a   133120 .. 395263  (128 MiB, 8300, name playos-a)
#   playos-b   395264 .. 657407  (128 MiB, 8300, name playos-b)
#   misc       657408 .. 690175  (16 MiB,  8300, name misc)
#   playos-data 690176 .. 1048575 (175 MiB, 8300, name playos-data)
TOTAL_SECTORS=1048576
ESP_START=2048
ESP_SECTORS=131072
SLOT_A_START=133120
SLOT_B_START=395264
MISC_START=657408
MISC_SECTORS=32768
DATA_START=690176
SLOT_SECTORS=262144
# Reserve 34 sectors at the end for the secondary GPT header + entry array.
DATA_SECTORS=$((TOTAL_SECTORS - DATA_START - 34))

# ── Helpers ────────────────────────────────────────────────────────
require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        playos_log_fatal "tool" "Required tool not found: $tool"
    fi
}

build_disk() {
    playos_log_step "Build Synthetic Installed Disk"
    require_tool sgdisk
    require_tool truncate
    require_tool mkfs.ext4
    require_tool dd

    mkdir -p "$(dirname "$INSTALLED_IMG")"

    playos_log_info "disk" "Creating $INSTALLED_IMG (512 MiB, GPT)..."
    truncate -s $((TOTAL_SECTORS * 512)) "$INSTALLED_IMG"
    sgdisk --zap-all "$INSTALLED_IMG" >/dev/null 2>&1

    sgdisk \
        -n 1:${ESP_START}:$((ESP_START + ESP_SECTORS - 1))  -t 1:ef00 -c 1:ESP \
        -n 2:${SLOT_A_START}:$((SLOT_A_START + SLOT_SECTORS - 1)) -t 2:8300 -c 2:playos-a \
        -n 3:${SLOT_B_START}:$((SLOT_B_START + SLOT_SECTORS - 1)) -t 3:8300 -c 3:playos-b \
        -n 4:${MISC_START}:$((MISC_START + MISC_SECTORS - 1)) -t 4:8300 -c 4:misc \
        -n 5:${DATA_START}:$((DATA_START + DATA_SECTORS - 1)) -t 5:8300 -c 5:playos-data \
        "$INSTALLED_IMG" >/dev/null

    playos_log_info "disk" "Writing rootfs.squashfs into playos-a and playos-b..."
    dd if="$ROOTFS_SQUASHFS" of="$INSTALLED_IMG" bs=512 seek="$SLOT_A_START" conv=notrunc status=none
    dd if="$ROOTFS_SQUASHFS" of="$INSTALLED_IMG" bs=512 seek="$SLOT_B_START" conv=notrunc status=none

    playos_log_info "disk" "Building ext4 playos-data and writing it into partition 5..."
    local data_img="$WORK_DIR/data.img"
    truncate -s $((DATA_SECTORS * 512)) "$data_img"
    mkfs.ext4 -q -F -L "playos-data" "$data_img" >/dev/null 2>&1
    dd if="$data_img" of="$INSTALLED_IMG" bs=512 seek="$DATA_START" conv=notrunc status=none

    playos_log_ok "disk" "Synthetic installed disk ready."
}

write_esp() {
    local boot_json="$1"

    local esp_img="$WORK_DIR/esp.img"
    require_tool mkfs.vfat
    require_tool mmd
    require_tool mcopy

    truncate -s $((ESP_SECTORS * 512)) "$esp_img"
    mkfs.vfat -F 32 -n ESP "$esp_img" >/dev/null 2>&1
    mmd -i "$esp_img" ::/playos >/dev/null 2>&1

    local boot_json_tmp="$WORK_DIR/boot.json"
    printf '%s' "$boot_json" > "$boot_json_tmp"
    mcopy -i "$esp_img" "$boot_json_tmp" ::/playos/boot.json >/dev/null 2>&1

    dd if="$esp_img" of="$INSTALLED_IMG" bs=512 seek="$ESP_START" conv=notrunc status=none
}

read_esp_boot_json() {
    local out_file="$1"
    local esp_img="$WORK_DIR/esp_after.img"
    dd if="$INSTALLED_IMG" of="$esp_img" bs=512 skip="$ESP_START" count="$ESP_SECTORS" status=none
    mtype -i "$esp_img" ::/playos/boot.json > "$out_file" 2>/dev/null || true
}

run_qemu() {
    local log="$1"

    local ovmf_vars_tmp="$WORK_DIR/ovmf_vars.fd"
    if [[ -f "$OVMF_VARS" ]]; then
        cp "$OVMF_VARS" "$ovmf_vars_tmp"
    else
        dd if=/dev/zero of="$ovmf_vars_tmp" bs=1M count=4 status=none
    fi

    timeout "$TIMEOUT" qemu-system-x86_64 \
        -m 512M \
        -machine q35,accel=kvm:tcg \
        -cpu qemu64 \
        -smp 2 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$ovmf_vars_tmp" \
        -kernel "$BZIMAGE" \
        -initrd "$INITRAMFS" \
        -drive if=none,id=installed,format=raw,file="$INSTALLED_IMG",cache=writethrough \
        -device virtio-blk-pci,drive=installed \
        -append "console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200n8 quiet" \
        -serial stdio \
        -display none \
        -no-reboot \
        > "$log" 2>&1 &
    local qemu_pid=$!

    set +e
    wait "$qemu_pid" 2>/dev/null
    local qemu_exit=$?
    set -e

    # QEMU is expected to be killed by timeout (scenario A) or exit via
    # -no-reboot after the rollback reboot (scenario B). Neither is a failure
    # on its own; we judge by log markers.
    return 0
}

count_matches() {
    local pattern="$1"
    local log="$2"
    grep -c "$pattern" "$log" 2>/dev/null || true
}

dump_log_tail() {
    local log="$1"
    playos_log_warn "boot" "Last 40 lines of $log:"
    tail -40 "$log" 2>/dev/null | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
}

# ── Scenario A: normal pivot ───────────────────────────────────────
scenario_a() {
    playos_log_step "Scenario A — Normal pivot into active slot a"

    local boot_json
    boot_json='{
  "v":1,
  "active_slot":"a",
  "slot_a":{"version":"0.1.0","boot_count":0,"health":"good"},
  "slot_b":{"version":"0.1.0","boot_count":0,"health":"empty"}
}'

    write_esp "$boot_json"

    local log="$WORK_DIR/scenario-a.log"
    playos_log_info "pivot" "Booting installed disk (${TIMEOUT}s)..."
    run_qemu "$log"

    local pivot_count start_count switch_fail exec_fail
    pivot_count="$(count_matches 'pivoting to active slot a' "$log")"
    start_count="$(count_matches 'playos-init starting as PID 1' "$log")"
    switch_fail="$(count_matches 'pivot switch_root failed' "$log")"
    exec_fail="$(count_matches 'exec /init failed' "$log")"

    if [[ "$pivot_count" -ge 1 && "$start_count" -ge 2 && "$switch_fail" -eq 0 && "$exec_fail" -eq 0 ]]; then
        playos_log_ok "pivot" "Pivot into squashfs slot a succeeded (pivot=$pivot_count, init starts=$start_count)."
    else
        playos_log_error "pivot" "Scenario A failed: pivot=$pivot_count init_starts=$start_count switch_fail=$switch_fail exec_fail=$exec_fail."
        dump_log_tail "$log"
        playos_log_fatal "pivot" "Scenario A verification failed. Full log kept at: $log"
    fi
}

# ── Scenario B: forced rollback ────────────────────────────────────
scenario_b() {
    playos_log_step "Scenario B — Forced rollback after repeated failures"

    # boot_count 2 + health "pending" → increment makes 3 → rollback.
    local boot_json
    boot_json='{
  "v":1,
  "active_slot":"a",
  "slot_a":{"version":"0.1.0","boot_count":2,"health":"pending"},
  "slot_b":{"version":"0.1.0","boot_count":0,"health":"empty"}
}'

    write_esp "$boot_json"

    local log="$WORK_DIR/scenario-b.log"
    playos_log_info "rollback" "Booting with failing slot a (${TIMEOUT}s)..."
    run_qemu "$log"

    local rollback_count
    rollback_count="$(count_matches 'failed too many times' "$log")"

    if [[ "$rollback_count" -lt 1 ]]; then
        playos_log_error "rollback" "Scenario B failed: no 'failed too many times' marker."
        dump_log_tail "$log"
        playos_log_fatal "rollback" "Scenario B verification failed. Full log kept at: $log"
    fi

    local esp_json="$WORK_DIR/boot-after.json"
    read_esp_boot_json "$esp_json"

    if ! grep -q '"active_slot":"b"' "$esp_json" 2>/dev/null; then
        playos_log_fatal "rollback" "boot.json was not flipped to slot b after rollback. Content: $(cat "$esp_json" 2>/dev/null)"
    fi
    if ! grep -q '"health":"bad"' "$esp_json" 2>/dev/null; then
        playos_log_fatal "rollback" "old slot a was not marked 'bad' after rollback. Content: $(cat "$esp_json" 2>/dev/null)"
    fi

    playos_log_ok "rollback" "Rollback flipped boot.json to slot b and marked slot a bad."
    playos_log_debug "rollback" "Post-rollback boot.json: $(tr -d '\n' < "$esp_json")"
}

# ── Run ────────────────────────────────────────────────────────────
build_disk
scenario_a
scenario_b

playos_log_step "Result"
playos_log_ok "done" "Both pivot scenarios passed. Synthetic disk: $INSTALLED_IMG"
rm -rf "$WORK_DIR"
