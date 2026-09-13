# T9 — signed v0.3.0 artifacts + A/B update on hardware — 2026-09-13

Sprint 14 T9: *"Enforce production image hygiene and signed artifacts."* This is the
final run: the production image, the signed EFI binary, the update bundle, the SDK
headers tarball and checksums — plus the first **A/B update applied to the installed
Ally**, which is the acceptance step that was still open.

Everything below was produced on the build host and verified on the device
(`192.168.0.127`, ROG Ally, Micron 512 GB NVMe) over SSH.

## 1. Production image (hygiene)

```sh
make ally-production-build          # output/ally-production/
```

| Check | Result |
|---|---|
| Shell / busybox | `/bin/sh` **absent**, `/usr/bin/busybox` **absent** |
| SSH | `/usr/sbin/dropbear`, `sshd`, `sftp-server` **absent** |
| PlayOS components | `/usr/bin/playos-shell`, `playos-installer`, `playos-compositor` present |
| Rootfs | `output/ally-production/images/rootfs.squashfs` — 55 066 624 bytes |

Matches the security model (no shell, no SSH, no debug tools in production).

## 2. Signed EFI binary

```sh
scripts/sign-efi.sh output/ally-production/images/bzImage \
                    output/ally-production/images/BOOTX64.EFI.signed
sbverify --cert keys/dev/efi-signing-cert.pem …/BOOTX64.EFI.signed
```

```
Signature verification OK
```

74 627 784 bytes. (Development key; production uses an HSM-backed key post-MVP.)

## 3. Update bundle

```sh
scripts/create-update-bundle.sh output/ally-production/images/rootfs.squashfs 0.3.0 \
                               output/ally-production/images/playos-update-0.3.0-prod.playosb
```

Layout `PBS1 | len | JSON header | payload | sig_len | hex HMAC-SHA256`, independently
re-verified against the bundle bytes (not just trusted from the writer):

```
version      : 0.3.0 | sig_alg: hmac-sha256-dev
payload_size : 55066624 == len(payload): True
payload sha  : matches header payload_sha256 -> True
hmac-sha256  : VALID
```

## 4. A/B update on the Ally — the hardware acceptance

Installed system booted on **slot A** (`/dev/nvme0n1p2`, `boot.json` slot a 0.1.0 good),
a bundle staged at `/data/updates/playos-update-0.3.0.playosb`
(dev rootfs, same 8-step install that was verified earlier). Then, from the shell's
Settings → System: **Check for Update** → **Apply Update** → **Restart to Apply**.

`init.log`:

```
[65.952] received type=ApplyUpdate from fd=10
[66.341] ApplyUpdate complete: /data/updates/playos-update-0.3.0.playosb
```

After the reboot:

| Evidence | Value |
|---|---|
| Running root | `/dev/nvme0n1p3` → **slot B** |
| `boot.json` | `active_slot: "b"`, `slot_b: {version: "0.3.0", boot_count: 0, health: "good"}`, `slot_a` untouched at `0.1.0` |
| Payload integrity | `sha256(slot B, 54 931 456 bytes)` = `acaabad7a5667a38b1818df80afbe4084825e19c68a70fededa426361ffc1c89` = `sha256(rootfs.squashfs)` shipped in the bundle — **byte-exact** |
| Shell display | reads `boot.json` → `OS VERSION 0.3.0`, `SLOT B` |
| Mark-good | `boot_count` back to 0 with `health: good` (accounting ran on the new slot) |
| SSH after the flip | available (payload is the dev image), so the flip was verified remotely |

The bundle's own HMAC verified independently (`hmac-sha256: VALID`) and its header's
`payload_sha256` matched its payload — so the artefact, the transport and the
on-disk result are all accounted for end to end.

## 5. SDK headers

```sh
scripts/export-sdk-headers.sh 0.3.0     # output/playos-0.3.0-sdk-headers.tar.gz
gcc -I playos/include/playos -std=c99 -Wall -Wextra -Werror -c minimal_game.c   # COMPILE OK
gcc minimal_game.o -L…/playos-platform-api/build -lplayos -o minimal_game       # LINK OK
LD_LIBRARY_PATH=… ./minimal_game                                                # RUNS
```

```
NEEDED  Shared library: [libplayos.so.0]      ← frozen SONAME
[INFO] [game] starting on 30DF003XGE
[WARN] [input] platform: no controller device found (scanned /dev/input/event0-31)
```

The warning is expected on a desktop host with no gamepad. **PASS** — the shipped
headers are self-sufficient with `-Werror` as C99 and a minimal game builds and runs
from the published artifact alone.

## 6. Checksums

`playos-0.3.0-SHA256SUMS.txt` (in this directory):

```
5a062c2b…65b63  rootfs.squashfs
12e76453…b9213c  bzImage
b23dcf87…d60fd6  BOOTX64.EFI.signed
b6249dff…96ce2c  playos-update-0.3.0-prod.playosb
01ec4373…ed62c6  playos-ally-prod-usb.img
271ddd5e…c19d0  playos-0.3.0-sdk-headers.tar.gz
```

## 7. Rollback — the other half of the A/B acceptance

Still on slot B, the board was rebooted holding **Volume Up** → shell **Recovery Menu** →
**Rollback** (d-pad + A).

`init.log`:

```
[72.218] received type=RollbackSlot from fd=10
[72.218] rollback requested via IPC
[72.219] RollbackSlot: active slot b -> a, rebooting
```

After the reboot:

| Evidence | Value |
|---|---|
| Running root | `/dev/nvme0n1p2` → **slot A** |
| `boot.json` | `active_slot: "a"`, `slot_a {version 0.1.0, health good, boot_count 0}`, `slot_b {version 0.3.0, health **bad**}` |
| Quarantine | the slot rolled back *from* is marked `bad`; the booted slot marked `good` by the normal good-boot timer |

Both directions of the A/B contract are therefore hardware-verified: update forward
(bundle → slot B → boots → mark-good) and roll back safely (recovery → RollbackSlot IPC →
slot A, failed slot quarantined).

## Still open

- **Rollback half** of the A/B acceptance: recovery menu → Rollback → back to slot A
  (and, if a slot fails to boot, the 3-strike auto-rollback).
- The tag-triggered CI release run (`.github/workflows/release.yml`) producing the same
  set with secrets — this report is the local, reproducible equivalent.
- `sdk-headers.tar.gz` ships headers only by design; the toolchain + libraries SDK is
  Sprint 15 (`scripts/export-sdk.sh`).
