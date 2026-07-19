#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [path-to.iso]" >&2
    exit 1
fi

if [[ $# -eq 1 ]]; then
    ISO="$(readlink -f "$1")"
else
    ISO="$(find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n'         | sort -nr         | head -n 1         | cut -d' ' -f2-)"
fi

if [[ -z "${ISO:-}" || ! -f "$ISO" ]]; then
    echo "error: no ISO found; pass one explicitly or build it first" >&2
    exit 1
fi

CODE=""
VARS=""
for candidate in     /usr/share/OVMF/OVMF_CODE_4M.fd     /usr/share/OVMF/OVMF_CODE.fd     /usr/share/ovmf/OVMF.fd; do
    if [[ -f "$candidate" ]]; then
        CODE="$candidate"
        break
    fi
done
for candidate in     /usr/share/OVMF/OVMF_VARS_4M.fd     /usr/share/OVMF/OVMF_VARS.fd; do
    if [[ -f "$candidate" ]]; then
        VARS="$candidate"
        break
    fi
done

if [[ -z "$CODE" ]]; then
    echo "error: OVMF firmware not found; install the Ubuntu ovmf package" >&2
    exit 1
fi

QEMU_DIR="$ROOT/.build/qemu"
mkdir -p "$QEMU_DIR"

ACCEL=(-machine q35,accel=tcg -cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=(-machine q35,accel=kvm -cpu host)
fi

FIRMWARE=(-bios "$CODE")
if [[ -n "$VARS" ]]; then
    cp "$VARS" "$QEMU_DIR/OVMF_VARS.fd"
    FIRMWARE=(
        -drive "if=pflash,format=raw,readonly=on,file=$CODE"
        -drive "if=pflash,format=raw,file=$QEMU_DIR/OVMF_VARS.fd"
    )
fi

echo "Booting: $ISO"
echo "QEMU console: Ctrl-A X exits"

exec qemu-system-x86_64     "${ACCEL[@]}"     "${FIRMWARE[@]}"     -m 2048     -smp 4     -device virtio-vga     -display none     -serial mon:stdio     -nic user,model=virtio-net-pci     -cdrom "$ISO"     -boot order=d     -no-reboot
