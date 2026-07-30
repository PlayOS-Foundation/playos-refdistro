# Boot and services

The first-frame rule is the controlling boot policy: GPU and input readiness,
seat access, the compositor, and the Shell are the only services that belong on
the visual critical path. The compositor must never wait for a background
service.

## Current boot paths

### Live ISO

```text
UEFI → Alpine kernel and initramfs → APK overlay
→ playos-visual softlevel → dbus → seatd
→ playos-compositor → playos-shell
→ playos-async-trigger (polls for /run/playos-visual-ready)
→ openrc --no-stop playos-async → NetworkManager + iwd + sshd
```

NetworkManager, iwd, and sshd are assigned to `playos-async`, not `playos-visual`.
The compositor writes `/run/playos-visual-ready` after successful startup.
`playos-async-trigger` polls for this flag (15s timeout) and activates the
async runlevel with `openrc --no-stop`. The `--no-stop` flag is required:
a plain `openrc <runlevel>` switches runlevels and stops every started
service not present in the target runlevel, which would kill seatd and the
compositor (they live in `playos-visual`, not `playos-async`) and drop the
device to a VT login prompt. This keeps networking and SSH off the visual
critical path.

### Installed disk image

```text
UEFI → systemd-boot → kernel and initramfs → ext4 root
→ OpenRC default runlevel → dbus → seatd
→ playos-compositor → playos-shell
→ playos-async-trigger → openrc --no-stop playos-async → NetworkManager + iwd + sshd
→ playos-firstboot (one-shot on the first boot)
```

The installed-image script assigns NetworkManager, iwd, and sshd to
`playos-async`. `playos-firstboot` runs in the `default` runlevel on first boot.

## Target service policy

The desired service split is:

| Scope | Services |
|---|---|
| Visual path | GPU/input readiness, seatd, compositor, Shell |
| Asynchronous path | audio, networking, Bluetooth, library scanning, updates, cloud, marketplace, telemetry, SSH/debug |

`playos-async` is reserved for this asynchronous path, started via
`playos-async-trigger` after compositor readiness. The trigger polls for
`/run/playos-visual-ready` (written by the compositor after successful
startup) with a 15-second timeout, then activates the async runlevel.

## Boot budget

| Metric | Initial acceptance | Reference target |
|---|---:|---:|
| Cold boot to first Shell frame | under 8 s | under 3 s |
| Resume to Shell | under 3 s | under 1 s |

Any service added to the visual path must have a measured first-frame impact
recorded with its image-validation evidence.

## First boot

`playos-firstboot` runs once after a disk image is written. It applies
pre-flight configuration from the ESP when present, regenerates identity and
filesystem identifiers, updates boot configuration, creates an EFI boot entry,
then removes itself from OpenRC runlevels.
