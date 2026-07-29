# AGENTS.md — playos-refdistro

> **⚠️ FIRST:** Read [`gen-context.md`](gen-context.md) before anything else to understand the full PlayOS platform context.

## Purpose

This repository builds the Alpine-based PlayOS reference operating system for full Runtime Devices.

## Source of truth

Platform behaviour is specified in `playos-spec`. ADR-0004 selects Alpine Linux, musl, apk, OpenRC, and Alpine mkimage tooling for the reference OS. Distribution details must not leak into the public PlayOS API.

## Golden rules

1. **First frame first.** Only GPU/input readiness, seatd, compositor, and shell belong on the visual path.
2. **Use Alpine-native mechanisms.** New work uses apk, OpenRC, aports, mkimage, initramfs, modloop, and supported Alpine persistence patterns.
3. **Pin releases.** Released images use a pinned Alpine stable branch. Do not consume unpinned edge repositories.
4. **Support multiple distro backends.** Alpine is the reference. Arch + CachyOS
   is an alternative backend for optimized handheld and desktop builds. Both
   produce identical output formats: compressed GPT disk images + bootable ISOs.
   Distro-specific code lives in `alpine/` or `arch/`; shared logic in `shared/`.
5. **Keep runtime code distribution-independent.** Package/init/image code belongs here. Runtime and shell sources must build on musl without depending on apk or OpenRC APIs.
6. **VMs and hardware boot.** Image builds do not validate DRM/KMS, input,
   suspend, or firmware.
7. **No secrets or host-specific paths.**

## Primary workflow

```text
# Alpine (reference)
bash scripts/build-iso-ubuntu.sh

# Arch + CachyOS (general optimized)
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=cachyos bash scripts/build-iso-ubuntu.sh

# Arch + CachyOS (handheld optimized — ROG Ally, Steam Deck)
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=deckify bash scripts/build-iso-ubuntu.sh
```

Each pipeline: Ubuntu wrapper → pinned build root → distro-specific image
tooling → compressed GPT disk image + bootable ISO → QEMU/OVMF smoke test.

## Layout policy

- `alpine/`: authoritative profile, package lists, overlays, and image configuration.
- `arch/`: Arch Linux profile — packages, pacman.conf (pinned + CachyOS repos), mkinitcpio.conf, systemd units.
- `shared/`: distro-agnostic code (partition layout, bootloader install, fstab, device profiles, firstboot).
- `scripts/build-alpine-iso.sh`: shared image entrypoint.
- `docs/README.md`: canonical documentation index.
- `docs/build/ubuntu.md`: Ubuntu host workflow.
- `docs/architecture/`: image-pipeline and boot/service architecture.
- `docs/validation.md`: required validation evidence.

A future distro backend must be proposed separately and own its package recipes, image tooling, init/service definitions, tests, and release lifecycle. It must not share mutable implementation state with the Alpine profile.

## Service policy

OpenRC is the reference init system.

- `playos-visual` contains only the first-frame path.
- `playos-async` is reserved for audio, networking, Bluetooth, library,
  updates, cloud, marketplace, telemetry, and debug services after compositor
  readiness.
- A background service may wait for compositor readiness.
- The compositor must never wait for a background service.
- Long-running daemons should use OpenRC supervision and bounded readiness checks.

## Compatibility policy

Reference components build against musl. glibc-only games run through declared compatibility runtimes. Do not add host-wide glibc as an implicit base dependency.

## Validation

Every image change should record:

- pinned Alpine tag and repositories;
- image digest;
- VM boot result;
- first-frame timestamp;
- renderer;
- kernel, Mesa, firmware, and wlroots versions;
- hardware result when device-facing code changed.

See [`docs/validation.md`](docs/validation.md) for the validation matrix.

## Logging infrastructure

All build scripts write structured logs to `logs/YYYY-MM-DD_HH-MM-SS--<distro>-<version>--<arch>/` per run.

### Architecture

- **`shared/logging.sh`** — Full logging library for host-side scripts.
  - `init_logging <script-name>` — Creates run directory, `latest` symlink, `metadata.json`.
  - `log_step` / `log_info` / `log_warn` / `log_error` / `log_success` / `log_debug` — Level-aware logging.
  - `log_cmd <desc> -- <command args...>` — Runs a command, logs stdout+stderr, captures exit code.
  - `log_duration <start_time> <desc>` — Logs elapsed time for a phase.
  - `close_logging` / `resume_logging <script-name>` — Lifecycle management.
  - Log level controlled by `PLAYOS_LOG_LEVEL` env var: `debug` | `info` (default) | `warn` | `error`.

- **`shared/logging-helpers.sh`** — Lightweight wrapper for nspawn-inner and standalone scripts.
  - Sources `logging.sh` when `PLAYOS_LOG_DIR` is available from the orchestrator.
  - Falls back to plain `echo` when running standalone (no log directory).
  - Use `_log_step` / `_log_info` / `_log_warn` / `_log_error` / `_log_success` in inner scripts.

### Log directory layout

```
logs/
├── latest -> 2025-06-15_14-32-01--alpine-3.21--x86_64/
├── 2025-06-15_14-32-01--alpine-3.21--x86_64/
│   ├── summary.log          # High-level phase markers (orchestrator)
│   ├── build-disk-image-alpine.log
│   ├── build-playos-components.log
│   ├── build-alpine-iso.log
│   ├── setup-ubuntu-build-host.log
│   └── metadata.json         # distro, version, arch, host, phases, duration, outcome
```

### nspawn log passing

The orchestrator passes `PLAYOS_LOG_DIR` and `PLAYOS_LOG_LEVEL` via `--setenv` to nspawn containers.
Inner scripts use `logging-helpers.sh` to either resume the full logging session or fall back to echo.

### Script integration checklist

When adding a new script or modifying an existing one:

1. Add `source "$ROOT/shared/logging-helpers.sh"` near the top (after `set -euo pipefail`).
2. Use `_log_step` for major phase markers (replaces `echo "==>"`).
3. Use `_log_info` for details (replaces `echo "    "`).
4. Use `_log_warn` for warnings (replaces `echo "    WARNING:"`).
5. Use `_log_error` for errors (replaces `echo "error:" >&2`).
6. Use `_log_success` for completion confirmations.

### bash EXIT trap warning

bash supports only a single EXIT trap — the last `trap ... EXIT` wins. When combining
multiple cleanup functions, merge them into a single combined trap function:
```bash
_combined_trap() {
    cleanup_disk_layout || true
    close_logging
}
trap _combined_trap EXIT
```
