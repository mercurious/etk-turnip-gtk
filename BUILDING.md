# Building the ETK Turnip GTK fork (ROCKNIX / glibc / `msm`)

This produces `libvulkan_freedreno.so` for **glibc ARM64** (ROCKNIX) targeting the
SM8250 / Adreno 650. It is **not** the Android build — the Android Turnip is `bionic`/KGSL and the
two `.so` files are not interchangeable. (A separate Android build path exists for aPS3e; it is out
of scope here.)

## Prerequisites

- An ARM64 Linux build environment (native arm64 avoids Rosetta/emulation issues). The reference
  setup is a Docker container, `turnip-rocknix`, on Ubuntu 24.04 arm64. On macOS this runs under
  [colima](https://github.com/abiosoft/colima)/Docker; a native arm64 Linux box or VM is preferred.
- Toolchain matching the ROCKNIX target: **glibc 2.41**, meson + ninja, the standard Mesa build
  deps (see Mesa's own `docs/install.rst`).
- A Mesa checkout at tag `mesa-26.1.6` with the fork patches applied
  (see [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh)).
- **`git` on `PATH` at build time.** Mesa generates `git_sha1.h` from the checkout; without it
  `MESA_GIT_SHA1` is empty and the build loses its per-build identity (see *Identifying a build*).

## Getting the source

```bash
./scripts/prepare-fork-branch.sh apply
```

That clones upstream at the base tag, applies the line's backports, then the fork series. To build a
**pre-release** driver instead — the point of the second track, so Pitstop can A/B stable against
experimental:

```bash
BASE_TAG=mesa-26.2.0-rc3 FORK_BRANCH=etk-gtk-26.2 ./scripts/prepare-fork-branch.sh apply
```

`BASE_TAG` accepts anything `git clone --branch` accepts: a release tag, an rc tag, a stable branch
(`26.2`), or `main`. For a moving branch, add `REUSE=1` to re-pull an existing checkout in place.
The backport set is chosen automatically from the base — `patches/backports/26.1/` for the 26.1 line,
nothing for 26.2 (which carries those commits natively). Verified clean on `mesa-26.1.6` and
`mesa-26.2.0-rc3`.

## Configure

```bash
meson setup build-rocknix \
  -Dbuildtype=release \
  -Dplatforms=wayland,x11 \
  -Dvulkan-drivers=freedreno \
  -Dgallium-drivers= \
  -Dfreedreno-kmds=msm \
  -Dvideo-codecs= \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
  -Db_lto=false -Dstrip=false
```

- `-Dfreedreno-kmds=msm` selects the upstream `msm` KMS path (ROCKNIX), **not** the Android KGSL path.
- `-Dplatforms=wayland,x11` matches the ROCKNIX display server (sway/Wayland with X11 fallback).
- **`-Dgallium-drivers=` is load-bearing, not optional.** Meson defaults it to `auto`, which pulls in
  the GL/compute stack and fails configure with `ERROR: Dependency "libclc" not found`. We ship only
  `libvulkan_freedreno.so`, so there is nothing to gain from building gallium anyway. `-Dvideo-codecs=`
  and the `glx/egl/gbm/llvm=disabled` set exist for the same reason: drop dependencies the Vulkan
  driver never links.
- This matches `/work/build_rocknix.sh` in the reference container, which is the authoritative
  configure line. Verified against `mesa-26.1.6` and `mesa-26.2.0-rc3` on 2026-07-30.

## Build

Full build (reference container wrapper):

```bash
docker exec turnip-rocknix bash -lc 'MESA_VER=26.1.6 /work/build_rocknix.sh'
```

Incremental rebuild — **use this in the iterate loop**, a full `rm -rf build-rocknix` is far slower:

```bash
ninja -C build-rocknix -j4 src/freedreno/vulkan/libvulkan_freedreno.so
```

Artifact:

```
build-rocknix/src/freedreno/vulkan/libvulkan_freedreno.so
```

## Build traps (learned the hard way)

- **Gate on ninja's real exit code.** Piping through `tail`/`head` masks the exit status —
  `if ninja > build.log 2>&1; then cp ...; fi`, never `ninja | tail`.
- **Don't `rm -rf build-rocknix` to iterate.** Incremental ninja rebuilds only the changed object
  (~1–2 min vs. a full build).
- **Turnip 26.1.x source is C++ (`.cc`), not C.** Files are `tu_cmd_buffer.cc`, `tu_util.cc`, etc.
- **Struct copy-init gotcha:** `tu_cache_state x = {}` fails on `BitmaskEnum` members. Copy-init
  from the live state first, then override: `tu_cache_state x = cmd->state.cache; x.flush_bits |= ...`.
- **Build the version bump into the container invocation.** `MESA_VER` in the wrapper above must
  match the base you actually checked out, or the wrapper will build the wrong tree.

## Identifying a build

Patch #8 makes the driver self-identifying, so a build is attributable at runtime:

```bash
vulkaninfo | grep driverInfo
#   driverInfo = Mesa 26.1.6 (git-1a2b3c4d5e) ETK-GTK
```

The `git-…` component is the fork branch's HEAD, so it differs per series build; the `ETK-GTK`
suffix answers "is this the fork at all?" at a glance. The numeric version is deliberately left
alone — RPCS3 parses it for driver-keyed workarounds, so a non-numeric suffix there could change
emulator behaviour and confound the comparison.

**This must pass before any A/B run.** Pitstop can hold several drivers at once, and a result you
cannot attribute to a build is not a result. `sha256sum` of the bound `.so` remains the
belt-and-braces check.

If `driverInfo` shows `ETK-GTK` but **no** `(git-…)`, the tree was not a git checkout at build time
and `git_sha1.h` came out empty. The usual cause is the tarball path in `build_rocknix.sh`, which
fetches `mesa-<ver>.tar.xz` from `archive.mesa3d.org` — a tarball has no `.git`, so every build from
it reports the same string and is indistinguishable from the next.
**Use `prepare-fork-branch.sh apply`**, which always produces a git checkout, and keep `git` on
`PATH` in the build environment.

Stage artifacts with the base and sha in the filename so the DRIVER tab can tell them apart:

```
libvulkan_freedreno-rocknix-26.1.6-etk-g<sha>.so
libvulkan_freedreno-rocknix-26.2.0-rc3-etk-g<sha>.so
```

## Selecting the driver on the rig

On ROCKNIX the built `.so` is staged under `/storage/turnip/drivers/` and selected through the
**Pitstop DRIVER tab**, which records the choice in `/storage/turnip/selected`; a boot service
bind-mounts the selected `.so` over `/usr/lib/libvulkan_freedreno.so`. The selection is
**cold-boot gated** — it must survive a full reboot to count as validated. (This selection
mechanism lives in the ETK repo, not here; this repo is source + build only.)
