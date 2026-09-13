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

### Still open from the original report

P1 (boot 7.16 s vs 5 s target) and P3 (direct-scanout observability) are
unchanged.
