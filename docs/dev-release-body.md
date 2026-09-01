# PlayOS Dev Images — {tag}

Development USB images built from `main`.

> **Pre-release** — for testing only, not a production release.

## Images

| Image | Target | SSH | Install payload |
|---|---|---|---|
| `playos-ally-dev-usb.img.xz` | ROG Ally | ✅ DropBear + dev key | ✅ Settings → Install PlayOS |
| `playos-intel-dev-usb.img.xz` | Intel PC (ZenBook UX530 etc.) | ✅ DropBear + dev key | ✅ Settings → Install PlayOS |
| `playos-ally-prod-usb.img.xz` | ROG Ally | ❌ none | ✅ Settings → Install PlayOS |

## What's new in this build

- **Sprint 13.7 installer flow** — live USB boots without pivoting into an installed
  internal slot (ESP live-USB marker), Settings → **Install PlayOS** launches the
  runtime installer, installs to the internal disk, and reboots into the installed OS.
- **Dev SSH key auto-seeded** — after install, the dev image's SSH key is copied to
  the installed system's `/data/ssh/authorized_keys` automatically.
- **SDL_GameControllerDB** gamepad mappings in both game and shell input paths
  (ROG Ally X/Y face-button quirk handled correctly).
- **Intel kernel** — i915, HDA/Realtek, P-State/RAPL, USB-C Ethernet dongles
  (r8152 / ax88179 / CDC-NCM) built in.
- CI now runs on Ubuntu 24.04 with Buildroot `dl/` + host-toolchain caching.

## Flash

```bash
# 1. Verify + decompress
sha256sum -c <image>.img.xz.sha256
xz -dk <image>.img.xz

# 2. Write to USB (replace sdX!)
sudo dd if=<image>.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## SSH into a dev image

- Wired: USB-C Ethernet dongle → DHCP → DropBear on port 22.
- User: `root`, key auth using the same key used to build the image.

## Notes

- These images are not signed; they are for development and testing.
- On a device with an existing PlayOS install, boot the USB explicitly
  (e.g., Volume Down + Power on ROG Ally) — the live marker keeps the session live.
