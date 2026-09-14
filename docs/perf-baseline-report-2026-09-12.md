# PlayOS performance baseline — 2026-09-12 — ROG Ally (dev image)

Measured on physical **ASUS ROG Ally** (AMD Ryzen Z1 Extreme, 16 threads,
11 GB RAM), dev image, idle shell background unless stated. Latencies are read
from `init.log`, whose line prefix is **seconds of system uptime**, so no extra
instrumentation was needed; the collector is
[`scripts/perf-baseline.sh`](../scripts/perf-baseline.sh) and its raw output is
[`evidence/perf-baseline-2026-09-12.md`](evidence/perf-baseline-2026-09-12.md).

Image: shell `0a76f93fda056933`, compositor `0837553f923eb787`, overlay
`f039410814b74a3e` (refdistro `f0bd607`).

## Results vs Sprint 14 T7 targets

| Target | Measured | Verdict |
|---|---|---|
| Cold boot → shell **< 5 s** | init logs its first line at **4.565 s** (kernel+firmware before it), `system ready` at 6.187 s, shell up (`ShellReady`) at **7.157 s** | **MISS — 1.43×** (gap P1) |
| Shell → game first frame **< 3 s** | `LaunchGame` 13.206 s → `GameSurfaceReady` **14.207 s (1.00 s)** → `GAME_FOREGROUND` 15.211 s | **PASS** |
| System button → overlay **< 100 ms** | `ShowOverlay` 23.792 s → compositor state change received 23.796 s = **4–5 ms** for the shell→init→compositor chain; the overlay's own first frame adds ≤ 1 frame at 55 fps (~18 ms) | **PASS** |
| Game exit → shell **< 500 ms** | `TerminateGame: pid=403` 37.781 s → `SHELL_FOREGROUND` **37.809 s = 28 ms** | **PASS** |
| `sample-triangle` 60 FPS at native resolution | **not measurable** — the image ships the 11 demo games, not `sample-triangle`, and the demos have no FPS counter. The shell itself runs at **55.5 fps** (278 frames / 5 s, 16.7 ms/frame) at 1920×1080 | **UNVERIFIED** (gap P2) |
| Direct scanout confirmed in the compositor log | **no `scanout` lines** at the default wlroots log level | **UNVERIFIED** (gap P3) |
| Idle shell CPU **< 2 %** | shell **6 %**, compositor **4 %**, overlay **0 %** of one core (≈ 0.4 % / 0.25 % / 0 % of the 16-thread system) | **MISS if per-core**, PASS if system-wide (gap P4) |

Other baseline data from the same run: 260 MB RAM used of 11118 MB; load
average 0.66 / 0.42 / 0.19; thermals `acpitz` 43 °C and 20 °C; battery `BAT0`
full at 100 %, `AC0` present.

## Gaps filed (also recorded in `playos-spec/src/testing.md`)

- **P1 — boot to shell 7.16 s vs 5 s (1.43×).** Within the sprint's "no metric
  more than 2× target" acceptance line, but over target. ~4.6 s elapses before
  `playos-init` logs anything (firmware + kernel + initramfs), so the largest
  single win is earlier/deferred kernel work (module load, udev coldplug,
  `loglevel`), not `playos-init` itself; the remaining 2.6 s is
  init → udev → compositor → shell.
- **P2 — in-game frame rate is not instrumented.** Add a lightweight FPS counter
  to the supervised game path (or ship `sample-triangle`) so "60 FPS at native
  resolution" can be measured on demand.
- **P3 — direct scanout is not observable.** No compositor-side indication at
  the default log level; add a counter/log line when a game surface is scanned
  out directly (or run the compositor with debug logging for the measurement).
- **P4 — the shell renders continuously at 55 fps even with a static UI**
  (6 % of a core). The `< 2 %` target needs both a definition (per-core or
  system-wide) and damage-driven rendering: skip `BeginDrawing`/`EndDrawing`
  when nothing changed and no animation is running.
- **P5 (minor, not perf).** `uname -n` reports `(none)` although
  `/etc/hostname` is `playos-ally` — `playos-init` never applies the hostname.
  The image also carries no PlayOS version marker (`/etc/os-release` is stock
  Buildroot), so build identity has to be established from binary hashes.

---

## Follow-up 2026-09-13 — P2 instrumentation + P4 damage-driven shell rendering

### P2 — in-game FPS instrumentation (done)

The compositor now counts each tracked toplevel's commits per second and logs
them, which measures the client's frame rate without any cooperation from it
(so it covers non-cooperative games):

```
playos-compositor: fps shell=8 game=120 (commits/s)
```

Measured on the Ally with a sample game: **peak 120 commits/s** — the game
saturates the panel's 120 Hz. `scripts/perf-baseline.sh` reports the shell rate
plus the in-game peak.

### P4 — damage-driven shell rendering (done)

The shell used to redraw continuously (~55 fps) even when nothing changed. It now
redraws only when something can have changed — input within 0.6 s, a screen
change, toasts/modals, the installer hold, or the Live Input Test — and otherwise
settles at ~8 fps, sleeping 4 ms per idle iteration (raylib's pacing lives inside
`EndDrawing()`, so a skipped frame must not be left to spin).

| Metric (Ally, idle) | Before | After |
|---|---|---|
| Shell frame rate (`shell-stderr.log`) | 55.5 fps | **8.0-8.2 fps** |
| Shell commits/s (compositor) | 56 | **8-9** |
| Shell CPU | 7.4% of one core | **2.8%** |

Input latency is unchanged in practice: input is polled every iteration (the
4 ms sleep bounds the delay), and any button/d-pad press switches to full rate
for 0.6 s.

**What made this interesting:** the first attempt did not engage at all — the
shell stayed at 55 fps. Decoding the raw evdev traffic showed why: the Ally's
right stick *at rest* oscillates `ABS_RY 511 <-> 767` (~65 events/s), so a
"any event = activity" rule is permanently true. The activity signal now counts
only discrete input (EV_KEY, d-pad hat). Trade-off, by design: analog motion no
longer wakes the UI, so stick-driven list scrolling redraws at the idle rate
(d-pad navigation, the primary path, stays full rate).

### P3 — direct scanout: measured, not assumed (done)

The original report listed direct scanout as **not confirmable**. The compositor
now listens for output *presentation* events and reports, once a second, how the
frames actually reached the panel (`WLR_OUTPUT_PRESENT_ZERO_COPY` = presented
without the renderer copying the buffer, i.e. the direct-scanout path):

```
fps shell=8 game=0 (commits/s) present zero-copy=8 copied=0
```

Measured on the Ally:

| Window | Present events | Result |
|---|---|---|
| 30 s game run (typical second: `fps shell=0 game=56`) | 1684 zero-copy / 0 copied | **100.0% direct** |
| Whole session (UI idle + game) | 2535 zero-copy / 0 copied | **100% direct** |

So every presented frame - in-game and on the shell UI - went to the panel
without a GPU copy. `scripts/perf-baseline.sh` now prints the percentage.

Two things fall out of the same data:

- the shell committed **0 frames/s while the game held the foreground** (max 12,
  at the transitions), which is the P4 suspend gate verified in-game rather than
  only on the idle UI;
- the game itself presented at a steady 56 commits/s in this run (a 60 Hz-locked
  title), against 120 in the earlier run - the panel and the compositor keep up
  either way.

### Still open from the original report

P1 only: cold boot 6.49 s against the 5 s target (see the follow-up above; the
remaining ~1.5 s is the chunk before init runs, the ESP/NVMe wait on the
critical path, and the shell's own startup).

---

## Follow-up 2026-09-13 — P1 boot-time attribution (first cuts)

Target: **cold boot → shell ready < 5 s**. Measured 7.44 s on the Ally. The init
log timestamps attribute it exactly:

| Stage | Time | Delta |
|---|---|---|
| power-on → init's first line (firmware + kernel + initramfs) | 4.51 s | **4.51 s** |
| → ESP mounted (udev start + partition discovery) | 5.29 s | 0.79 s |
| → compositor spawned | 5.37 s | 0.07 s |
| → compositor **ready** | 5.57 s | 0.20 s |
| → shell **spawned** (fixed "500 ms grace period") | 6.07 s | **0.50 s** |
| → shell window ready 1920x1080 (EGL/GL context, first configure) | 7.00 s | **0.93 s** |
| → registered as trusted shell | 7.01 s | 0.01 s |
| → `ShellReady` seen by init (first frame rendered) | 7.44 s | **0.44 s** |

Two of those are pure added latency, and were cut:

- **the 500 ms grace period** before spawning the shell is replaced by a
  connect-probe of the compositor's Wayland socket (`/run/playos/playos-0`,
  polled every 20 ms, 2 s cap). The socket is the actual precondition and is
  ready within a few ms; the fixed sleep was pure delay. The measured value is
  logged on every boot ("compositor Wayland socket ready after N ms").
- **the ESP mount retry** backed off 100/200/300…900 ms, so a boot whose
  `/dev/nvme0n1p1` node appeared a moment late paid ~600 ms in sleeps alone. It
  now polls every 25 ms (40 attempts, same 1 s tolerance), costing only the time
  actually needed.

**Measured on the next boot (confirmation):**

```
  4.570s    +0.001s  udevd started (PID 226)
  5.240s    +0.670s  ESP mounted at /EFI (device /dev/nvme0n1p1)
  5.581s    +0.203s  compositor ready (PID 310)
  5.581s    +0.000s  compositor Wayland socket ready after 0 ms   <- was a 504 ms sleep
  5.581s    +0.000s  spawning shell: /usr/bin/playos-shell
  6.490s    +0.908s  received type=ShellReady
```

**Cold boot → shell ready: 7.66 s → 6.49 s (−1.17 s)**, and `system ready`
(i.e. every component spawned) at 5.58 s.

Two corrections to the plan above, both from the data:

- the ESP stage did **not** shrink (0.67 s): the wait is the *kernel* bringing up
  the NVMe (init starts at 4.57 s, the partitions appear ~0.6 s later), so the
  fast poll only removed the *sleeps* around a wait that is otherwise real. It is
  on the critical path by construction: **the Ally has no bootloader at all** —
  the kernel is booted by the EFI stub as `\EFI\BOOT\BOOTX64.EFI` (see
  `scripts/gen-ally-usb-image.sh`: "EFI stub boot — no GRUB"), and its command
  line is compiled in (`CONFIG_CMDLINE_BOOL=y`,
  `CONFIG_CMDLINE="console=tty1 quiet loglevel=3"`). There is therefore nothing
  that could pre-declare the active slot: init must mount `/EFI`, read
  `boot.json` and pivot before any user-space component starts. **An earlier
  revision of this report suggested "pass the slot from GRUB" — that was wrong**
  (it generalised from the QEMU dev target, which does use GRUB2, to the Ally,
  which does not), and a second revision called the wait "hardware bring-up" —
  **the kernel log contradicts that too**: `nvme0n1: p1 p2 p3 p4 p5` appears at
  **1.76 s** and the kernel hands over at 1.81 s, while init's first ESP mount is
  at **4.61 s**. The NVMe was ready 2.8 s before anyone asked for it.

  So ~2.7 s is spent *inside* the first (initramfs) init doing something that
  leaves no trace: its log cannot persist because `/data` is not mounted yet.
  This is the actual P1 target, and it is unmeasured — the first task is to make
  it visible (`/dev/kmsg` markers), not to guess at it.
- the shell's startup measured 0.91 s this boot (it was 1.37 s), so that stage is
  highly variable — worth re-measuring before optimising it.

**What remains, honestly:** hitting 5 s needs the two big items, not more
trimming. The first is the real prize, and it is also just *correct*
engineering:

0. **The unlogged 2.7 s of the first init (the real target — measure first).**
   Add `/dev/kmsg` markers around the first init's steps (udev trigger/settle, ESP
   find+mount, squashfs mount, pivot, exec) so the phase is visible in `dmesg`.
   Candidates, none yet proven: the ESP FAT mount and its `sync`, the squashfs
   mount of the active slot, the recovery button check (must return instantly
   when nothing is held), boot-stage writes that fsync the FAT, and the udev
   trigger+settle — though that measured **0.10 s** warm on the device, so it is
   not automatically guilty.
1. **An installed system boots a live-USB kernel.** `CONFIG_INITRAMFS_SOURCE`
   embeds `rootfs.cpio` (198 MB uncompressed; the 74 MB `bzImage` installs to the
   target ESP as `/BOOTX64.EFI`). The kernel hand-off at 1.81 s bounds this: the
   unpack costs at most ~1 s, so it is a secondary item, not the headline.
   Shipping a minimal kernel+initramfs as the install payload removes it.

1. **~2.5-3 s of kernel + initramfs before init runs** (firmware POST is the rest
   and is not ours). The controllable part is the embedded initramfs: shrinking
   it (dev tooling out of the packaged cpio) and/or its compression is the next
   real win.
2. **~1.4 s of shell startup** (0.93 s EGL/GL context + first configure, 0.44 s
   first frame). Parallelising GL-context creation with the compositor configure
   wait is the plausible cut.
