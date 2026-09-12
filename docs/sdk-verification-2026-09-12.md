# SDK headers verification — 2026-09-12

Sprint 14 T9 requires: *"`sdk-headers.tar.gz` compiles a minimal game on a Linux
host."* This is that check, run on the build host (x86_64 Linux, gcc).

## Artifact

```sh
scripts/export-sdk-headers.sh 0.3.0
tar -tzf output/playos-0.3.0-sdk-headers.tar.gz
```

| | |
|---|---|
| Tarball | `output/playos-0.3.0-sdk-headers.tar.gz` |
| Size / sha256 | 35760 bytes / `5173aadc00dea2842c974af337819d91…` |
| Contents | `playos/include/playos/` → `playos.h`, `playos_audio.h`, `playos_display.h`, `playos_input.h`, `playos_lifecycle.h`, `playos_logging.h`, `playos_power.h`, `playos_storage.h`, `playos_system.h`; `playos/include/raylib/raylib.h`; `playos/README.md` |

## Check — minimal game, SDK headers only

The "Getting Started" game (`playos-platform-api/examples/minimal_game.c`) was
extracted from the tarball and built **with only the shipped headers on the
include path** — no repository include directories — then linked against the
host build of the library:

```sh
tar xzf playos-0.3.0-sdk-headers.tar.gz -C /tmp/sdk-check
gcc -I playos/include/playos -std=c99 -Wall -Wextra -Werror -c minimal_game.c -o minimal_game.o   # COMPILE OK
gcc minimal_game.o -L…/playos-platform-api/build -lplayos -o minimal_game                        # LINK OK
```

```
 0x0000000000000001 (NEEDED)  Shared library: [libplayos.so.0]      ← frozen SONAME
 0x000000000000001d (RUNPATH) Library runpath: […/playos-platform-api/build]
```

Running it exercises the public API end to end (lifecycle poll, input scan,
logging):

```
[ 32689.587] [INFO] [game] starting on 30DF003XGE
[ 32689.587] [WARN] [input] platform: no controller device found (scanned /dev/input/event0-31)
```

The warning is expected on a desktop host with no gamepad. **Result: PASS** —
the headers are self-sufficient (they compile with `-Werror` as C99), the ABI
dependency is the frozen `libplayos.so.0`, and a minimal game builds and runs
from the published artifact alone.

## Still open in T9

- Final **signed v0.3.0** run of the tag-triggered pipeline (production image +
  EFI signing + `update.playosb` + `sdk-headers.tar.gz` + checksums).
- **Physical install** of `playos-v0.3.0-rog-ally-installer.img` on a clean Ally
  and an `update.playosb` apply through the A/B flow.
- `sdk-headers.tar.gz` currently ships headers only (by design); the full
  toolchain + libraries SDK is Sprint 15 (`scripts/export-sdk.sh`).
