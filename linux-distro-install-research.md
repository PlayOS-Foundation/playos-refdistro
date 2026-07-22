# Linux Distribution Installation: Best Practices & Approaches

> **Research for PlayOS Reference Distribution**  
> **Date:** 2026-07-22  
> **Scope:** How major Linux distributions handle OS installation to disk, focusing on patterns relevant to PlayOS (console/gaming/appliance use cases).

---

## Table of Contents

1. [Installation Paradigms](#1-installation-paradigms)
2. [Per-Distribution Analysis](#2-per-distribution-analysis)
3. [Comparison Matrix](#3-comparison-matrix)
4. [Key Best Practices](#4-key-best-practices)
5. [PlayOS-Specific Recommendations](#5-playos-specific-recommendations)
6. [References](#6-references)

---

## 1. Installation Paradigms

Linux distributions fall into three broad installation paradigms:

### 1.1 Pre-Built Disk Image (`dd`-based)

A complete, pre-partitioned, pre-installed root filesystem image is shipped as a single file. The user (or installer tool) writes it directly to a block device with `dd` or equivalent.

| Characteristic | Detail |
|---|---|
| **Runtime work** | Minimal — decompress + write blocks to disk |
| **Network required?** | No (self-contained image) |
| **Partitioning logic** | Done at build time; runtime only resizes to fill disk |
| **User-facing complexity** | Low — "select disk, confirm, wait" |
| **Image size** | Larger (~1-4 GiB compressed) |
| **Per-device variants** | One image per CPU architecture (sometimes per-device for GPU drivers) |
| **First-boot setup** | Regenerate machine-id, partition UUIDs, expand filesystem, create EFI entry |

**Adopters:** SteamOS, Bazzite, ChimeraOS, Raspberry Pi OS, Ubuntu Core, Fedora IoT, Batocera, Lakka, Recalbox

**Typical flow:**
```
Build time:       packages → chroot → GPT image (ESP + root) → compress → sign
Install time:     select disk → dd image → resize partition/fs → first-boot service → ready
```

### 1.2 Package-Level Install (Live Environment + Installer)

A minimal live OS boots (from ISO/USB/PXE), runs an installer program that partitions the disk, downloads/installs packages, configures the bootloader, and sets up the new system.

| Characteristic | Detail |
|---|---|
| **Runtime work** | High — partition, format, download packages, install, configure |
| **Network required?** | Usually yes (package download), some have offline mode |
| **Partitioning logic** | Complex — manual, guided, or automatic; LVM, LUKS, btrfs subvolumes |
| **User-facing complexity** | Medium to high — language, keyboard, timezone, partitioning, user accounts |
| **Image size** | Smaller (~200-800 MiB live ISO) |
| **Flexibility** | Highest — any package selection, filesystem, partition layout |

**Adopters:** Ubuntu (Ubiquity/Subiquity), Fedora/RHEL (Anaconda), Debian (debian-installer), openSUSE (YaST), EndeavourOS (Calamares)

**Typical flow (Anaconda example):**
```
Live boot → GUI: language → keyboard → disk selection → partitioning → package selection → install → reboot
```

### 1.3 Script-Based Bootstrap (Manual or Semi-Automated)

A live environment provides tools; the user (or a script) manually partitions, mounts, bootstraps a base system, chroots, and configures. Some distributions wrap this in guided scripts.

| Characteristic | Detail |
|---|---|
| **Runtime work** | High (user-driven or script-driven) |
| **Network required?** | Yes (package download) |
| **Partitioning logic** | User's choice; scripts provide sensible defaults |
| **User-facing complexity** | High (manual) to Medium (scripted) |
| **Image size** | Small ISO |
| **Flexibility** | Highest (full control) |

**Adopters:** Arch Linux (`pacstrap`), Alpine Linux (`setup-alpine` → `setup-disk`), Gentoo (stage3), Void Linux

**Typical flow (Alpine):**
```
Live boot → setup-alpine (keyboard, hostname, network, mirror, ssh, disk) → setup-disk → reboot
```

---

## 2. Per-Distribution Analysis

### 2.1 SteamOS (Valve)

**Paradigm:** Pre-built disk image

SteamOS ships a **recovery image** (~2.5 GiB) that is written directly to disk via `dd` or a dedicated USB creation tool.

| Aspect | Detail |
|---|---|
| **Image format** | Raw `.img` (compressed via `.bz2`) |
| **Partition scheme** | GPT: EFI (64 MiB), A (5 GiB), B (5 GiB), /home (remaining) |
| **A/B updates** | Yes — two root partitions, rauc-based atomic updates |
| **First boot** | Expands /home to fill disk, generates machine-id |
| **Bootloader** | systemd-boot |
| **Installer UX** | No on-device GUI; user creates USB on another PC, boots from USB |
| **Validation** | Checksum verification of image before write |
| **Key insight** | The "installer" is just `dd` — zero runtime complexity on target device |

**Relevance to PlayOS:** This is the closest analog. PlayOS targets the same hardware class (handheld gaming PCs). SteamOS proves that `dd`-based install works at scale for console-style devices. The A/B partition scheme is worth studying for future PlayOS atomic updates.

---

### 2.2 Bazzite (Universal Blue)

**Paradigm:** Pre-built disk image (Fedora Atomic / OSTree-based)

Bazzite builds on Fedora Atomic Desktops (OSTree), shipping pre-built images for Steam Deck, ROG Ally, and generic PCs.

| Aspect | Detail |
|---|---|
| **Image format** | Raw `.iso` (bootable live + installer) or raw disk image |
| **Partition scheme** | GPT: EFI (1 GiB), boot (1 GiB), root (remaining, btrfs) |
| **A/B updates** | OSTree-based atomic updates (rpm-ostree) |
| **First boot** | `bootc`-based provisioning |
| **Bootloader** | systemd-boot (handheld images), GRUB (desktop images) |
| **Installer UX** | Fedora Media Writer, `dd`, or bootable ISO with guided install |
| **Image variants** | Per-device: `bazzite-deck`, `bazzite-ally`, `bazzite-gnome`, `bazzite-kde` |
| **Key insight** | Per-device image variants solve driver/firmware/tuning differences without runtime detection complexity |

**Relevance to PlayOS:** Per-device image variants (ROG Ally, Steam Deck, Legion Go) are a proven pattern. OSTree-based updates are worth evaluating for long-term atomic update capability.

---

### 2.3 ChimeraOS

**Paradigm:** Pre-built disk image

ChimeraOS is the simplest approach — a single pre-built disk image for AMD-based handhelds.

| Aspect | Detail |
|---|---|
| **Image format** | Raw disk image |
| **Partition scheme** | GPT: EFI, root (ext4/btrfs) |
| **A/B updates** | No (single partition, frzr-based update tool planned) |
| **First boot** | Auto-expands partition, generates configs |
| **Bootloader** | systemd-boot |
| **Installer UX** | `dd` from another PC; no on-device installer |
| **Key insight** | Minimalism works — single image, single partition, no runtime package install. Focus on gaming UX, not installer UX. |

**Relevance to PlayOS:** Proves that a single x86_64 image works for all AMD handhelds without per-device variants. The "no on-device installer" approach is acceptable for enthusiast early adopters but may not scale to PlayOS's broader audience.

---

### 2.4 Alpine Linux

**Paradigm:** Script-based bootstrap

Alpine's `setup-alpine` is a guided shell script that configures the live environment, then `setup-disk` partitions and installs the base system.

| Aspect | Detail |
|---|---|
| **Image format** | Bootable ISO (~200 MiB) |
| **Partition scheme** | `setup-disk -m sys`: ESP (100 MiB), root (remaining, ext4) or `-m data` for diskless |
| **Installer UX** | Text-based guided script, no GUI |
| **Key tools** | `setup-alpine`, `setup-disk`, `apk --root <mountpoint>` |
| **Network** | Required (downloads packages via `apk`) |
| **Post-install** | Manual service config, bootloader setup via script |
| **Key insight** | `apk --root` is powerful — install packages into a mounted root without needing the target to be booted. This is what PlayOS's current installer uses. |

**Relevance to PlayOS:** PlayOS's current approach (`setup-disk -m sys`) is directly derived from Alpine. The `apk --root` mechanism is what `longterm-install.md` proposes using at build time (pre-fill the image) instead of at install time (runtime package downloads).

---

### 2.5 Arch Linux

**Paradigm:** Manual bootstrap

Arch is the canonical manual install — no installer, no guided script. The user boots a live ISO and runs `pacstrap`, `genfstab`, `arch-chroot`, etc.

| Aspect | Detail |
|---|---|
| **Image format** | Bootable ISO (~800 MiB) |
| **Partitioning** | Entirely manual (`fdisk`, `parted`, `gdisk`) |
| **Bootstrap** | `pacstrap /mnt base linux linux-firmware` |
| **Installer UX** | None — wiki guide, manual commands |
| **Key tools** | `pacstrap`, `genfstab`, `arch-chroot`, `grub-install` / `bootctl install` |
| **Key insight** | The `pacstrap` pattern (install base packages into a mounted root from a live environment) is universal and clean. Every distro that does package-level install follows this pattern. |

**Relevance to PlayOS:** Arch's `arch-chroot` pattern is what PlayOS's `setup-disk` already does under the hood. The lesson is that package-level install fundamentally requires a working live environment + package manager + network — all runtime dependencies PlayOS wants to eliminate from the install path.

---

### 2.6 Fedora/RHEL (Anaconda)

**Paradigm:** Package-level install with full GUI

Anaconda is the production-grade installer for Fedora, RHEL, CentOS, and derivatives. It is the most feature-complete Linux installer.

| Aspect | Detail |
|---|---|
| **Image format** | Bootable ISO (~2 GiB for Workstation) |
| **Installer UX** | Full GUI (GTK), spoke-based workflow |
| **Automation** | Kickstart files — fully unattended installs |
| **Partitioning** | Automatic (LVM/btrfs) or manual (custom partitioning with blivet-gui) |
| **Storage tech** | LVM, LUKS, btrfs, mdraid, iSCSI, multipath |
| **Network** | Required for package install, but has "Everything" ISO for offline |
| **Key insight** | Anaconda separates storage configuration from package installation cleanly. Kickstart files enable fully automated, reproducible installs — useful inspiration for PlayOS's auto-install path. |

**Relevance to PlayOS:** Anaconda's complexity (LUKS, LVM, iSCSI, etc.) is overkill for a fixed-hardware console. But the Kickstart concept (declarative install config) could inspire PlayOS device profiles: a TOML file specifying which image to write, which partitions to create, and what first-boot steps to run.

---

### 2.7 Calamares (Distribution-Independent Installer)

**Paradigm:** Package-level install, modular framework

Calamares is used by EndeavourOS, Manjaro, Lubuntu, KaOS, and many others. It is explicitly designed to be distribution-agnostic.

| Aspect | Detail |
|---|---|
| **Architecture** | Modular: partition module, packages module, bootloader module, etc. |
| **Customization** | Branding + module selection via config files, no code patches needed |
| **Installer UX** | Qt-based GUI, slideshow-style workflow |
| **Partitioning** | Auto (erase disk, replace partition, alongside) or manual |
| **Key insight** | The module system decouples packaging (pacman vs apt vs apk) from the UI and partitioning logic. This is elegant but adds runtime complexity (Calamares + Qt + modules must be in the live environment). |

**Relevance to PlayOS:** Not directly applicable (PlayOS uses pre-built images, not package install). But the modular, config-driven design philosophy aligns with PlayOS's specification-first approach — a device profile (RFC-0006) could declaratively describe the install configuration.

---

### 2.8 Raspberry Pi OS

**Paradigm:** Pre-built disk image + dedicated imager tool

Raspberry Pi OS is the canonical example of appliance-style OS deployment.

| Aspect | Detail |
|---|---|
| **Image format** | Raw `.img.xz` (~1.2 GiB) |
| **Imager tool** | Raspberry Pi Imager (desktop app: select device → select OS → select SD card → write) |
| **Partition scheme** | MBR: boot (vfat, 256 MiB), root (ext4, remaining) |
| **First boot** | Auto-expands root to fill SD card, generates SSH keys, prompts for user setup |
| **Advanced** | Imager can pre-configure WiFi, SSH, hostname, user before writing (embeds config in boot partition) |
| **Key insight** | **Pre-flight configuration** — the imager tool pre-configures the image before writing it. This eliminates first-boot interactive setup entirely. PlayOS could embed device-profile settings into the ESP before writing. |

**Relevance to PlayOS:** The pre-flight configuration pattern is powerful: the Shell installer GUI (on PlayOS booted from PXE/USB) could write the target device's hostname, WiFi credentials, and user preferences into the disk image's ESP before `dd`. Then the first boot is fully non-interactive.

---

### 2.9 Ubuntu (Ubiquity / Subiquity)

**Paradigm:** Package-level install with GUI (desktop) or TUI (server)

Ubuntu has two installers:
- **Ubiquity** (legacy desktop): Full GUI, slideshow, guided partitioning
- **Subiquity** (server): Terminal-based, API-driven, used by Ubuntu Server

| Aspect | Detail |
|---|---|
| **Installer UX** | Desktop: full GUI with slideshow. Server: TUI with REST API backend |
| **Key insight** | Subiquity's API-driven architecture allows headless/automated installs. The installer exposes a REST API; a separate client (TUI, web UI, or automated script) drives it. |

**Relevance to PlayOS:** The API-driven approach (installer as a service, UI as a client) is architecturally clean and matches PlayOS's design patterns (Runtime provides services, Shell consumes them). A PlayOS install service could expose a simple IPC protocol for the Shell GUI to drive.

---

### 2.10 Batocera / Lakka / Recalbox (Retro Gaming)

**Paradigm:** Pre-built disk image, single-purpose appliance

These retro-gaming distributions are the simplest model: a single compressed image, written to SD card/USB/disk, boots directly into the gaming UI.

| Aspect | Detail |
|---|---|
| **Image format** | `.img.gz` (~2-8 GiB depending on included ROMs) |
| **Partition scheme** | GPT: boot (vfat), share (exFAT/vfat for user ROMs on separate partition), root (ext4) |
| **First boot** | Auto-expands share partition, generates configs |
| **Installer UX** | None on device — Balena Etcher or `dd` from PC |
| **Key insight** | The "share" partition (separate from root) survives OS reflashes. Users can re-image the OS without losing ROMs/saves. |

**Relevance to PlayOS:** The "share partition" concept is directly applicable: a `/home` or `/data` partition separate from the root partition survives OS updates/reinstalls. PlayOS should keep game installs and save data on a separate partition from the OS.

---

## 3. Comparison Matrix

| Distro | Paradigm | Runtime Work | Network? | GUI Installer? | Partition Scheme | Updates |
|---|---|---|---|---|---|---|
| **SteamOS** | Pre-built image | `dd` | No | No (USB creation tool) | GPT: ESP + A + B + /home | A/B atomic |
| **Bazzite** | Pre-built image | `dd` or ISO install | Optional | Yes (ISO path) | GPT: ESP + boot + root (btrfs) | OSTree atomic |
| **ChimeraOS** | Pre-built image | `dd` | No | No | GPT: ESP + root | Single, frzr planned |
| **Alpine** | Script-based | `setup-disk` (packages) | Yes | No (text script) | GPT/MBR: ESP + root | `apk upgrade` |
| **Arch** | Manual bootstrap | `pacstrap` + config | Yes | No (wiki guide) | User's choice | `pacman -Syu` |
| **Fedora** | Package install (Anaconda) | Package download + config | Yes (or offline ISO) | Yes (GTK) | GPT: ESP + boot + root (btrfs/LVM) | `dnf upgrade` |
| **Ubuntu** | Package install (Ubiquity/Subiquity) | Package download + config | Yes | Yes (GTK/TUI) | GPT: ESP + root (ext4) | `apt upgrade` |
| **Calamares** | Package install (modular) | Package download + config | Yes | Yes (Qt) | Configurable | Distro-specific |
| **Raspberry Pi OS** | Pre-built image | `dd` + Imager tool | No | No (Imager desktop app) | MBR: boot + root | `apt upgrade` |
| **Batocera** | Pre-built image | `dd` | No | No | GPT: boot + share + root | Re-image |

---

### Pattern Clustering

```
Console / Gaming / Appliance            Traditional Desktop / Server
─────────────────────────────────       ─────────────────────────────
SteamOS    ████████████                 Ubuntu    ░░░░░░░░░░░░
Bazzite    ████████████                 Fedora    ░░░░░░░░░░░░
ChimeraOS  ████████████                 Arch      ░░░░░░░░░░░░
Batocera   ████████████                 openSUSE  ░░░░░░░░░░░░
RPi OS     ████████████                 Debian    ░░░░░░░░░░░░
PlayOS     ████████████ ← we belong here

Key: ████ = pre-built image, dd-based    ░░░░ = package-level install, runtime work
```

**Every console and appliance distribution uses pre-built images.** PlayOS is correctly aligned with this pattern.

---

## 4. Key Best Practices

### 4.1 Image Construction

| Practice | Why | Adopters |
|---|---|---|
| **Pre-built GPT image** (not copied files) | Deterministic, verifiable, no runtime partitioning errors | SteamOS, RPi OS, Batocera |
| **Compressed with zstd or xz** | Best compression ratio; zstd is fast to decompress | Arch (zstd packages), Fedora (xz images) |
| **SHA-256 checksum + GPG signature** | Integrity + authenticity verification before writing | Arch, Fedora, RPi OS |
| **Sparse image at build time** | Build image with minimal size, expand at install time | All pre-built image distros |
| **Separate OS and data partitions** | OS updates/reinstalls don't touch user data | SteamOS (A+B + /home), Batocera (boot + share + root) |
| **ESP sized for future kernels** | 512 MiB minimum (multiple kernel versions, initramfs) | Fedora (1 GiB ESP), Bazzite (1 GiB) |

### 4.2 Install-Time Flow

| Practice | Why | Adopters |
|---|---|---|
| **Progress reporting via stderr parsing** | `dd status=progress` is universal, no custom IPC needed | All `dd`-based installers |
| **`sgdisk -e` after dd** | Relocate backup GPT to end of disk (disk may be larger than image) | RPi OS, Batocera |
| **`parted resizepart` + `resize2fs` after dd** | Expand root to fill the actual disk | All pre-built image distros |
| **Verify image before writing** | Prevent corrupted installs | Fedora Media Writer, RPi Imager |
| **Clean EFI boot entries post-install** | Remove stale entries from previous OS installs | PlayOS already does this |

### 4.3 First-Boot Setup

| Practice | Why | Adopters |
|---|---|---|
| **Regenerate machine-id** | Prevents UUID collisions across cloned installs | systemd-firstboot, all image-based distros |
| **Regenerate partition/filesystem UUIDs** | Prevents UUID collisions | RPi OS, Batocera |
| **One-shot first-boot service** | Runs once, deletes itself from runlevels | All image-based distros |
| **Pre-flight config embedding** | Write hostname, WiFi, user into ESP before dd | RPi Imager (pre-configure), Ubuntu autoinstall |
| **Fast first frame** | Boot to UI before background services | SteamOS, PlayOS (boot-budget.md target: 2s) |

### 4.4 Update Strategy

| Practice | Why | Adopters |
|---|---|---|
| **A/B partition scheme** | Atomic updates, automatic rollback | SteamOS (rauc), Android, ChromeOS |
| **OSTree-based** | File-level atomic, space-efficient | Fedora Silverblue, Bazzite |
| **Separate data partition** | Survives OS updates | SteamOS, Batocera |
| **Delta updates** | Smaller downloads | SteamOS, ChromeOS |

### 4.5 UX Patterns

| Practice | Why | Adopters |
|---|---|---|
| **No keyboard/mouse required** | Console/controller-first UX | SteamOS, Bazzite, ChimeraOS, Batocera |
| **Single confirmation step** | "Erase and Install" — one button, no partitioning choices | SteamOS recovery, Bazzite |
| **Post-install reboot is automatic** | No manual steps between install and first boot | All console distros |
| **Offline-capable** | No network dependency at install time | SteamOS, RPi OS, Batocera |

---

## 5. PlayOS-Specific Recommendations

Based on the research above, the following recommendations align with both industry best practices and PlayOS's specific constraints (console-first, spec-driven, Alpine-based, ROG Ally primary target).

### 5.1 Primary Path: Pre-Built Disk Image (`dd`-based)

**Aligns with:** SteamOS, Bazzite, ChimeraOS, Batocera, Raspberry Pi OS  
**Mapped in:** `docs/longterm-install.md`

**Why this is correct for PlayOS:**

1. **Console UX demand** — Users expect "press one button, wait, done." Package-level install requires network, package selection, and partitioning choices — all inappropriate for a controller-driven console.
2. **Deterministic** — The image is built once and verified. Every install is identical. No `apk update` failures, no mirror downtime, no partial installs.
3. **Offline** — ROG Ally on an airplane or without WiFi? Install still works from USB.
4. **Speed** — `dd` at ~300 MB/s writes a 4 GiB image in ~15 seconds. Package installs take minutes.
5. **Testable** — The exact image is CI-built, hash-verified, and boot-tested before shipping.

**Recommended architecture** (already described in `longterm-install.md`):

```
Build time:
  Build all PlayOS components
  → Create Alpine root in chroot (apk --root)
  → Copy PlayOS binaries + services
  → Create GPT image (ESP 512 MiB + root ~3 GiB)
  → Install systemd-boot to ESP
  → Compress (zstd)
  → Checksum + sign

Install time (Shell GUI):
  1. User selects disk, confirms "Erase and Install"
  2. Verify image signature (stretch goal)
  3. zstd -d image.zst | dd of=/dev/nvme0n1 bs=4M status=progress
  4. sgdisk -e /dev/nvme0n1              (relocate backup GPT)
  5. parted resizepart 2 100%            (grow root partition)
  6. resize2fs /dev/nvme0n1p2            (grow filesystem)
  7. Reboot

First boot (playos-firstboot service, one-shot):
  1. Regenerate /etc/machine-id
  2. Regenerate partition UUIDs (tune2fs -U random)
  3. Create clean EFI boot entry (efibootmgr)
  4. Delete self from runlevels
```

### 5.2 Retain ISO + PXE for Development

The ISO does not go away. It remains the primary development workflow:

- **PXE/netboot**: Zero-touch iteration (no disk writes during development)
- **QEMU testing**: Boot ISO for CI smoke tests
- **Recovery**: Boot ISO to re-image a broken system

The disk image and ISO are **peer build artifacts** from the same pipeline.

### 5.3 Per-Architecture Images (Not Per-Device, Initially)

| Image | Architecture | Devices |
|---|---|---|
| `playos-gpt-3.24-x86_64.img.zst` | x86_64 | ROG Ally, Steam Deck, Legion Go, generic AMD handhelds, Intel Ultrabooks |
| `playos-gpt-3.24-aarch64.img.zst` | aarch64 | Orange Pi, future ARM devices (future) |

Per-device image variants (like Bazzite's `bazzite-deck` vs `bazzite-ally`) can be added later if device-specific firmware/driver bundles diverge significantly. Currently, all AMD handhelds share the same GPU driver stack (`amdgpu` + Mesa).

### 5.4 Separate Data Partition

Add a `/data` partition (mounted at `/var/lib/playos` or `/home/playos`) that survives OS updates:

```
GPT layout:
  p1: ESP (vfat, 512 MiB)          — bootloader + kernels
  p2: root (ext4, ~4 GiB min)      — OS, read-only or updated atomically
  p3: data (ext4/btrfs, remaining) — games, saves, user configs
```

This enables:
- OS updates that don't touch user data (SteamOS pattern)
- "Factory reset" by re-imaging p1 + p2 only
- Simpler backup (just p3)

### 5.5 Pre-Flight Configuration

The Shell installer GUI (running from PXE/USB) can pre-configure the disk image before writing:

```
Before dd:
  1. Read device profile (TOML, RFC-0006) — input mappings, display config
  2. Read user preferences — WiFi SSID/password, hostname, timezone
  3. Mount ESP from image (loopback)
  4. Write playos-install-config.toml into ESP
  5. dd the image (with embedded config)
  6. First-boot service reads config from ESP → applies settings → deletes config file
```

This eliminates interactive first-boot setup entirely — the console boots directly into the Shell on first start.

### 5.6 Image Distribution

| Method | Use Case |
|---|---|
| **USB drive** | Offline install, factory provisioning, recovery |
| **HTTP download** | Online install from PXE environment |
| **Embedded in PXE initramfs** | Self-contained netboot install (large initramfs, fast local net) |
| **Recovery partition** | On-disk recovery (future, SteamOS pattern) |

### 5.7 What to Avoid

| Anti-Pattern | Why |
|---|---|
| **Full Calamares/Anaconda-style GUI** | Overkill for fixed-hardware console; adds Qt/GTK dependency to live env |
| **Manual partitioning UX** | Console users should never see partition tables |
| **Network-dependent install** | Breaks offline use; single point of failure (mirror downtime) |
| **Interactive first-boot wizard** | Breaks "press button → console ready" expectation |
| **Installer as OpenRC service** | Already replaced with inline Shell GUI (v0.2) |
| **glibc dependency in base image** | ADR-0004: musl is the reference libc |

---

## 6. References

### Industry Examples

- [SteamOS Recovery Image](https://help.steampowered.com/en/faqs/view/1B71-EDF2-EB6D-2BB3) — Pre-built recovery image, `dd` to disk, A/B atomic updates
- [Bazzite Installation Guide](https://docs.bazzite.gg/General/Installation_Guide/) — Per-device pre-built images, Fedora Atomic/OSTree
- [ChimeraOS](https://github.com/ChimeraOS/chimeraos) — Single image for AMD handhelds, `dd` install
- [Batocera](https://github.com/batocera-linux/batocera.linux) — Pre-built images, share partition survives reflash
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) — Pre-flight config embedding, dedicated imager tool
- [Anaconda Installer](https://github.com/rhinstaller/anaconda) — Full GUI, Kickstart automation
- [Calamares](https://github.com/calamares/calamares) — Distribution-independent modular installer
- [Alpine `alpine-conf`](https://github.com/alpinelinux/alpine-conf) — `setup-alpine` + `setup-disk` scripts
- [Arch Installation Guide](https://wiki.archlinux.org/title/Installation_guide) — Manual bootstrap pattern

### PlayOS Internal Documents

- `docs/longterm-install.md` — Proposed pre-built disk image architecture
- `docs/boot-budget.md` — Cold boot to first frame in under 2 seconds
- `docs/fast-boot.md` — Visual path before background services
- `docs/PlayOS-Installation.md` — Current v0.2 install issues and fixes
- `docs/alpine-migration.md` — Alpine bring-up and parity gates
- `alpine/install-script/playos-installer` — Current install script (to be replaced)
- RFC-0004: Platform API surface
- RFC-0006: Device profile format (TOML)
- ADR-0004: Alpine Linux as reference OS base
- ADR-0002: wlroots/TinyWL compositor foundation
