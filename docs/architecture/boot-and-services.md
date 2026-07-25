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
```

`genapkovl-playos.sh` currently also adds NetworkManager, iwd, and
sshd to `playos-visual`. They are not dependencies of `playos-compositor`, but
they are presently started in the same softlevel.

WiFi uses **iwd** as the backend (`wifi.backend=iwd` in NetworkManager config).
iwd is started as an OpenRC service in the playos-visual runlevel. The previous
`wpa_supplicant` package was referenced but its binary and init script were
never installed — iwd is the supported path.

### Installed disk image

```text
UEFI → systemd-boot → kernel and initramfs → ext4 root
→ OpenRC default runlevel → dbus → seatd → iwd
→ playos-compositor → playos-shell
→ playos-firstboot (one-shot on the first boot)
```

The installed-image script currently adds NetworkManager, iwd,
sshd, and `playos-firstboot` to the default runlevel. NetworkManager is
configured with `wifi.backend=iwd` and `wifi.iwd.autoconnect=yes`.

## Target service policy

The desired service split is:

| Scope | Services |
|---|---|
| Visual path | GPU/input readiness, seatd, compositor, Shell |
| Asynchronous path | audio, networking, Bluetooth, library scanning, updates, cloud, marketplace, telemetry, SSH/debug |

`playos-async` is reserved for this asynchronous path, started only after
compositor readiness. The current scripts do not yet implement that complete
transition, so documentation must not represent it as completed behavior.

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
