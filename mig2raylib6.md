# Migration: Raylib 5.0 → 6.0 on Alpine (Custom APKBUILD)

## Overview

PlayOS targets Raylib 6.0 via FetchContent (`GIT_TAG 6.0`) in both
`playos-shell` and `playos-samples`. Zero source code changes are needed — all
PlayOS Raylib API usage goes through stable core functions untouched by 6.0
breaking changes.

The problem: Alpine 3.24 ships `raylib 5.0-r0` (soname `libraylib.so.450`).
The refdistro build scripts pass `-DPLAYOS_USE_SYSTEM_RAYLIB=ON` to use the
system package, silently downgrading to 5.0 on Alpine while FetchContent gives
6.0 everywhere else.

**This plan:** Create a custom APKBUILD that builds Raylib 6.0 from source,
produces a proper `.apk`, and lets the refdistro consume it like any other
Alpine package — no building from source in every image build.

## What stays the same

- **playos-shell/CMakeLists.txt** — already `GIT_TAG 6.0` (line 50)
- **playos-samples/CMakeLists.txt** — already `GIT_TAG 6.0` (line 39)
- **playos-platform-api** — no changes (conditionally uses Raylib backend when available)
- **All C++ source code** — no API changes needed anywhere

## Files to create

### 1. `alpine/apkbuilds/raylib/APKBUILD`

New file. Based on Alpine's existing raylib 5.0 APKBUILD from `aports/community/raylib`,
updated for 6.0:

```sh
# Contributor: David Demelier <markand@malikania.fr>
# Maintainer: PlayOS <playos@example.com>
pkgname=raylib
pkgver=6.0
pkgrel=0
pkgdesc="A simple and easy to use game development library"
url="https://www.raylib.com"
arch="all"
license="Zlib"
makedepends="cmake glfw-dev samurai"
subpackages="$pkgname-dev"
source="$pkgname-$pkgver.tar.gz::https://github.com/raysan5/raylib/archive/refs/tags/$pkgver.tar.gz"
options="!check" # No tests.

build() {
	if [ "$CBUILD" != "$CHOST" ]; then
		CMAKE_CROSSOPTS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_HOST_SYSTEM_NAME=Linux"
	fi
	cmake -B build -G Ninja \
		-DBUILD_EXAMPLES=Off \
		-DBUILD_SHARED_LIBS=True \
		-DCMAKE_BUILD_TYPE=None \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_INSTALL_PREFIX=/usr \
		-DUSE_EXTERNAL_GLFW=ON \
		$CMAKE_CROSSOPTS .
	cmake --build build
}

package() {
	DESTDIR="$pkgdir" cmake --install build
}

sha512sums="
<TODO: run 'abuild checksum' after placing source tarball>
"
```

**Key differences from Alpine's 5.0 APKBUILD:**
- `pkgver=6.0` instead of `5.0`
- `cmake` instead of `cmake3.5` (Alpine 3.24 has cmake 4.x, we can just use `cmake`)
- sha512sums placeholder — filled in by `abuild checksum`

**Soname:** Raylib 6.0 sets `API_VERSION 600`, producing `libraylib.so.600`.
This is the critical change that cascades into the soname references below.

### 2. `alpine/apkbuilds/raylib/raylib.pre-install` (optional)

If we want to handle upgrades from the Alpine 5.0 package cleanly. Not strictly
needed for the image build (fresh install), but good practice:

```sh
#!/bin/sh
# Clean up old soname symlinks from raylib 5.0 if present
rm -f /usr/lib/libraylib.so.450
```

## Files to modify

### 3. `scripts/build-playos-components.sh`

**Line 17:** Add the custom APKBUILD repo to apk before installing deps:

```diff
 echo "==> Installing PlayOS build dependencies"
+
+# Add custom APKBUILD repo (raylib 6.0)
+mkdir -p /etc/apk/keys
+cp "$ROOT/alpine/apkbuilds/raylib/playos-signing.rsa.pub" /etc/apk/keys/ 2>/dev/null || true
+echo "/home/build/packages/playos" >> /etc/apk/repositories
+
 apk add --no-cache \
```

**Lines 49-52:** Update the stale comment and keep `PLAYOS_USE_SYSTEM_RAYLIB=ON`:

```diff
-# Use Alpine system raylib (5.0) instead of FetchContent raylib 6.0.
+# Use system raylib (custom APKBUILD provides 6.0, matching FetchContent GIT_TAG).
```

**Line 51 and 72:** The `-DPLAYOS_USE_SYSTEM_RAYLIB=ON` flags stay — they'll
now pick up the custom 6.0 package instead of the Alpine 5.0 package.

### 4. `scripts/build-disk-image.sh`

**Lines 161-163:** Update soname from 450 → 600:

```diff
-if [ -f /usr/lib/libraylib.so.450 ]; then
-    cp -a /usr/lib/libraylib.so.450 $MNT/usr/lib/
-    ln -sf libraylib.so.450 $MNT/usr/lib/libraylib.so
+if [ -f /usr/lib/libraylib.so.600 ]; then
+    cp -a /usr/lib/libraylib.so.600 $MNT/usr/lib/
+    ln -sf libraylib.so.600 $MNT/usr/lib/libraylib.so
```

### 5. `alpine/genapkovl-playos.sh`

**Lines 175-177:** Same soname update:

```diff
-    if [ -f /usr/lib/libraylib.so.450 ]; then
-        cp /usr/lib/libraylib.so.450 "$tmp/usr/lib/"
-        ln -sf libraylib.so.450 "$tmp/usr/lib/libraylib.so"
+    if [ -f /usr/lib/libraylib.so.600 ]; then
+        cp /usr/lib/libraylib.so.600 "$tmp/usr/lib/"
+        ln -sf libraylib.so.600 "$tmp/usr/lib/libraylib.so"
```

### 6. `alpine/init.d/playos-installer`

**Line 143:** Update soname reference:

```diff
-for lib in /usr/lib/libraylib.so.450 /usr/lib/libraylib.so /usr/lib/libglfw.so.3; do
+for lib in /usr/lib/libraylib.so.600 /usr/lib/libraylib.so /usr/lib/libglfw.so.3; do
```

### 7. `alpine/mkimg.playos.sh`

**Line 76-77:** No change needed to the `apks` list — `raylib` and `glfw` stay
listed. The custom repo providing raylib 6.0 gets configured earlier in the
build pipeline. If we want to pin to our custom package, we could add a version
constraint but it's unnecessary since the custom repo shadows the Alpine one.

### 8. `playos-spec/book/src/07-engine-integration/03-raylib-reference-kit.md`

**Line 57:** Update reference version shown in docs:

```diff
-FetchContent_Declare(raylib GIT_REPOSITORY https://github.com/raysan5/raylib.git GIT_TAG 5.5)
+FetchContent_Declare(raylib GIT_REPOSITORY https://github.com/raysan5/raylib.git GIT_TAG 6.0)
```

### 9. `gen-context.md` (playos-shell root)

**Line:** Update technology stack version reference from "Raylib 5.x" to
"Raylib 6.0":

```diff
-| **Rendering (reference)** | Raylib 5.x (fetched via FetchContent) |
+| **Rendering (reference)** | Raylib 6.0 (fetched via FetchContent) |
```

## Build pipeline integration

The custom APKBUILD needs to be built and added to a local apk repository
before `build-playos-components.sh` runs. Two approaches:

### Option A: Build in the nspawn container (recommended)

Add a step before the existing `build-playos-components.sh` call in the build
pipeline that:

1. Copies the APKBUILD into the nspawn container
2. Runs `abuild -r` to build the package into a local repo
3. Adds the local repo to `/etc/apk/repositories`
4. Then `apk add raylib-dev` picks up the 6.0 package

### Option B: Pre-build on the Ubuntu host

Build the package once on the host using the Alpine chroot, cache the `.apk`,
and inject it into the nspawn container. Faster for repeated builds.

**Recommendation: Option A** — simpler, no cache invalidation concerns, adds
maybe 30 seconds to the build.

## Verification checklist

- [ ] APKBUILD builds successfully: `abuild -r` produces `raylib-6.0-r0.apk` and `raylib-dev-6.0-r0.apk`
- [ ] `libraylib.so.600` exists in the built package: `tar tzf raylib-6.0-r0.apk | grep libraylib`
- [ ] `build-playos-components.sh` succeeds with the custom raylib 6.0
- [ ] `build-disk-image.sh` copies `libraylib.so.600` (not `.450`)
- [ ] `genapkovl-playos.sh` bundles `libraylib.so.600` (not `.450`)
- [ ] ISO boots in QEMU: `bash scripts/test-iso-qemu.sh`
- [ ] Disk image boots in QEMU: `bash scripts/test-disk-image-qemu.sh`
- [ ] Shell renders correctly, gamepad navigation works
- [ ] Sample apps (hello-playos, space-invaders) launch and render correctly
- [ ] Alpine spec chapter updated, gen-context.md updated

## Rollback plan

If something breaks:
1. Revert the soname changes in the 3 shell scripts (`.450` back to `.600`)
2. Remove the custom APKBUILD repo from the build pipeline
3. Alpine's system raylib 5.0-r0 is still available — the build falls back to it

## Summary

| What | Count | Effort |
|---|---|---|
| New files | 1 (APKBUILD) + optional pre-install | ~35 lines |
| Files modified | 6 | Soname find-and-replace + 1 comment + 1 spec line + 1 gen-context line |
| Source code changes | 0 | None needed |
| Build pipeline | 1 new step | ~5 lines to build + register custom APKBUILD |
| Risk | Low | API is compatible, soname is the only real change |
