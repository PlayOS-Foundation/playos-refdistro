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
