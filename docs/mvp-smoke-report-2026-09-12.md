# MVP smoke test — 2026-09-12 — ROG Ally (dev image)

Run on physical **ASUS ROG Ally** (AMD Ryzen Z1 Extreme, 16 threads, 11 GB), dev
USB image flashed to the internal NVMe, SSH over Wi-Fi.

- Raw collector output: [`evidence/mvp-evidence-2026-09-12.md`](evidence/mvp-evidence-2026-09-12.md)
- Checklist: [`playos-spec/src/testing/mvp-smoke-test.md`](../../playos-spec/src/testing/mvp-smoke-test.md)
- Device RTC is unset (no battery-backed clock, no NTP), so `date` on the device
  is meaningless and `/data/log` timestamps are uptime-relative.

## Image identity

| Component | sha256 (first 16) | bytes |
|---|---|---|
| `playos-init` (installed as `/init`) | `1b8753db19360bf7` | 177128 |
| `playos-shell` | `0a76f93fda056933` | 325544 |
| `playos-compositor` | `0837553f923eb787` | 55352 |
| `playos-overlay` | `f039410814b74a3e` | 34648 |
| `libplayos.so.0.3.0` | `46000d67ca670ce9` | 264048 |

`versions.lock`: init `3c7309d`, compositor `3862e4d`, shell `da26d88`,
spec `280f5e8`, samples `651ed31`, refdistro `f0bd607`.

## Result: 18 / 19 PASS

| # | Criterion | Result | Evidence |
|---:|---|---|---|
| 1 | Boots directly from UEFI into PlayOS | PASS | Device boots straight to the shell, no desktop; exercised repeatedly across flashes today |
| 2 | UEFI-bootable EFI artifact | PASS | `FOUND /EFI/EFI/BOOT/BOOTX64.EFI (74490880 bytes)` on the ESP (`/dev/nvme0n1p1` → `/EFI`). Note the checklist's `/EFI/BOOT/BOOTX64.EFI` is the *live-USB* layout; on the installed system the ESP is mounted at `/EFI` |
| 3 | `playos-init` is PID 1 | PASS | `/proc/1/exe` → `/init`; `strings /init` → `playos-init PID 1 Boot Supervisor`. (`/proc/1/comm` is `init` because the binary is installed as `/init`, and `/sbin/init` is BusyBox — PID 1 itself is playos-init.) The checklist's `awk '{print $4}' /proc/1/comm` was wrong and is fixed |
| 4 | Compositor owns DRM/KMS + Wayland | PASS | `playos-compositor` pids 312/317; `/run/playos/playos-0` socket present |
| 5 | Shell persistent controller-first UI | PASS | shell PID 348 alive through the whole session, 55.5 fps steady (`278 frames, 16.7ms/frame`) |
| 6 | wlroots + AMDGPU DRM/GBM/EGL/Mesa | PASS | `DRIVER=amdgpu`; EGL vendor `Mesa Project`, EGL driver `radeonsi`; GL renderer `AMD Ryzen Z1 Extreme (radeonsi, phoenix, ACO, DRM 3.61, 6.12.103)` |
| 7 | Shell renders via Raylib PlayOS backend | PASS | Shell renders (fps log) and captures its own output; game frames render on the same stack (criterion 12) |
| 8 | Shell + game use public `libplayos` ABI | PASS | `/usr/lib/libplayos.so` → `.so.0` → `.so.0.3.0`, and the shell has it mapped: `7f21d1edf000-… /usr/lib/libplayos.so.0.3.0`. `ldd` does not exist on musl, so the script now uses `/proc/<pid>/maps` |
| 9 | Trusted transport stays internal | PASS | Only `/run/playos/control.sock` and `/run/playos/compositor.sock`, mode `0660 root:playos-trusted`; no game-facing socket |
| 10 | Shell requests launch; init spawns/supervises | PASS | `init.log`: `received type=LaunchGame from fd=10` → `game spawned: com.playos.sample-bunnymark PID 403` |
| 11 | Compositor waits for first valid frame | PASS | `GameSurfaceReady` (14.207) precedes `GAME_FOREGROUND` (15.211); no black frame or flash on quick-launch was observed |
| 12 | Hardware-accelerated render + controller input | PASS | Game rendered on the AMD stack and appears in captures; controller `Microsoft X-Box 360 pad` connected; face buttons, SELECT and d-pad (`ABS_HAT0X/Y`) all decoded — verified by overlay navigation and in-game input |
| 13 | System button backgrounds/pauses game | PASS | `ARMOURY CRATE tap - showing overlay` → compositor `GAME_FOREGROUND → PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND` (3× in one session); game then SIGSTOPed if non-cooperative |
| 14 | Resume returns to same game without restart | PASS | Reverse transitions to `GAME_FOREGROUND` with the **same** game PID 403 still alive after each overlay visit — no respawn, no relaunch |
| 15 | Game audio through ALSA | PASS | `aplay -l`: `card 1: ALC294 Analog` + `card 0: HDMI 0`; shell applies mixer defaults (`set master volume to 0.70 on 'Master'`); audio samples load their assets. (Audible playback is inherently a human check.) |
| 16 | Clean exit + crash return to shell | PASS | Clean exit: `TerminateGame: pid=403` → `CompositorStateChanged state=SHELL_FOREGROUND` in **28 ms**, shell foreground again. Crash path: shell restart after a SIGABRT was exercised earlier today (init respawns the shell and the compositor releases the stale role) |
| 17 | Games/saves on separate ext4 | PASS | `/dev/nvme0n1p5 on /data type ext4 (rw,relatime)`; `/data` holds `games/ saves/ config/ screenshots/ updates/ system/`; per-game save dir `saves/com.playos.sample-bunnymark` |
| 18 | System image immutable | PASS | `/dev/nvme0n1p2 on / type squashfs (ro,relatime,errors=continue)` |
| 19 | Recovery usable without accelerated graphics | **FAIL** | No software render path exists in the image (`modetest`/`weston`/SimpleDRM absent) — recovery renders *through the compositor*, so the compositor-failure entry point cannot show the menu when graphics are what broke. Tracking gap: **F3 / S14-T6** |

## Gap — criterion 19

Recovery entry points work while the GPU stack is healthy (cmdline flag,
Volume-Down hold, missing `/data`, compositor failure), and the menu
(reboot / shutdown / factory reset / rollback / logs) is implemented. What is
missing is a **render path that does not depend on AMDGPU/wlroots**: on this
hardware the recovery UI is the Raylib shell on the compositor, so an
`amdgpu`-initialisation failure leaves no way to display it. Closing this needs
either a SimpleDRM/`efifb`-backed renderer for the recovery screen or a
kernel-framebuffer console fallback. Until then the MVP has 18 of 19 criteria
and Sprint 14's exit gate is not satisfied.

## Notes / minor findings

- Device hostname: `uname -n` reports `(none)` although `/etc/hostname` says
  `playos-ally` — `playos-init` never applies it.
- The image has no PlayOS version marker (`/etc/os-release` is stock Buildroot),
  so build identity has to come from binary hashes.
- `/init` is the init binary path; `/sbin/init` belongs to BusyBox and is not
  what the kernel runs.
