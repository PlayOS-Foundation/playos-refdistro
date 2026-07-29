# PlayOS aports patches

## Purpose

The `aports-mkimage.patch` file captures four modifications that PlayOS needs
against Alpine's aports scripts (branch `3.24-stable`).  Previously these
were applied with fragile `sed` commands in `build-alpine-iso.sh`.  Using a
proper `.patch` file means a mismatch between the patch and the upstream
source is caught at build time by `git apply`, instead of silently producing
a broken ISO.

## What the patch does

| # | File | Change | Why |
|---|---|---|---|
| 1 | `scripts/mkimage.sh` | Remove `--no-chown` | apk-tools 3.0.6+ usermode conflicts with root in nspawn |
| 2 | `scripts/mkimage.sh` | Replace `cp -Lrs` with `cp -rL` | nspawn bind mounts don't support hardlinks across filesystem boundaries |
| 3 | `scripts/mkimg.base.sh` | Insert DESTDIR backup before `xorrisofs` | nspawn xorriso systematically corrupts the apkovl; we rebuild the ISO from the backup |
| 4 | `scripts/mkimg.base.sh` | Remove `sd-mod,usb-storage quiet` from initfs_cmdline | sd-mod/usb-storage may hang during netboot; quiet suppresses debug messages |

## Regeneration procedure

When Alpine updates the aports scripts (or you move to a new stable branch),
the patch must be regenerated against the new source.  Follow these steps:

### 1. Clone aports at the correct tag/branch

```bash
cd /var/tmp
git clone https://gitlab.alpinelinux.org/alpine/aports.git
cd aports
git checkout 3.24-stable
```

### 2. Apply the four changes

```bash
# Patch 1: remove --no-chown
sed -i 's/--no-chown//g' scripts/mkimage.sh

# Patch 2: replace cp -Lrs with cp -rL
sed -i 's/cp -Lrs/cp -rL/' scripts/mkimage.sh

# Patch 3: insert DESTDIR backup before xorrisofs
sed -i '/^[[:space:]]*xorrisofs \\/i\cp -a "${DESTDIR}" /var/tmp/playos-destdir-backup' scripts/mkimg.base.sh

# Patch 4: remove sd-mod,usb-storage and quiet from initfs_cmdline
sed -i 's/initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage quiet"/initfs_cmdline="modules=loop,squashfs"/' scripts/mkimg.base.sh
```

### 3. Verify the changes applied correctly

```bash
grep -r --no-chown scripts/mkimage.sh && echo "ERROR: --no-chown still present" || echo "OK: --no-chown removed"
grep 'cp -Lrs' scripts/mkimage.sh && echo "ERROR: cp -Lrs still present" || echo "OK: cp -Lrs replaced"
grep 'playos-destdir-backup' scripts/mkimg.base.sh || echo "ERROR: backup line not found"
grep 'sd-mod\|usb-storage' scripts/mkimg.base.sh && echo "ERROR: sd-mod/usb-storage still in initfs_cmdline" || echo "OK: cmdline cleaned"
```

### 4. Generate the patch

```bash
git diff > /path/to/playos-refdistro/patches/aports-mkimage.patch
```

### 5. Update the base commit reference

Record the base commit so future maintainers know which upstream revision
the patch targets:

```bash
git rev-parse HEAD
```

Add that commit hash to this README and to the header of the patch file.

## Application

The patch is applied by `scripts/apply-aports-patches.sh`, which is called
from `scripts/build-alpine-iso.sh`.  The script uses `git apply` which will
fail loudly if the patch does not apply cleanly.
