# Validation

Image changes require artifact, QEMU, and—when device-facing behavior
changes—hardware validation. A successful build alone does not validate
DRM/KMS, input, firmware, suspend, or device boot behavior.

## Required commands

```bash
bash scripts/verify-build.sh
bash scripts/test-disk-image-qemu.sh out/playos-gpt-v3.24-x86_64.img.zst
bash scripts/test-iso-qemu.sh out/alpine-playos-*.iso
```

`verify-build.sh` checks artifact existence, checksums, GPT and filesystem
integrity, and PXE publication. The disk-image QEMU test monitors serial boot
markers. The ISO QEMU test provides an interactive serial console; use
`Ctrl-A X` to exit.

## Validation matrix

| Change | Minimum evidence |
|---|---|
| Documentation-only | Internal links and documentation consistency |
| Image, package, bootloader, or overlay | `verify-build.sh` and both QEMU tests |
| Service order or first-frame path | QEMU evidence plus measured first-frame time |
| GPU, input, firmware, or device profile | QEMU evidence and ROG Ally hardware result |

## Record with an image change

- Alpine branch and minirootfs version;
- aports revision and configured repositories;
- artifact digest;
- QEMU result;
- first-frame timestamp and renderer;
- kernel, Mesa, firmware, and wlroots versions;
- ROG Ally result when applicable.

See [ROG Ally](hardware/rog-ally.md) for device-specific checks.
