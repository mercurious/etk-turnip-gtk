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
- A Mesa checkout at tag `mesa-26.1.3` with the fork patches applied
  (see [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh)).

## Configure

```bash
meson setup build-rocknix \
  -Dbuildtype=release \
  -Dplatforms=wayland,x11 \
  -Dvulkan-drivers=freedreno \
  -Dfreedreno-kmds=msm \
  -Dallow-broken-lto=true \
  -Dstrip=true
```

- `-Dfreedreno-kmds=msm` selects the upstream `msm` KMS path (ROCKNIX), **not** the Android KGSL path.
- `-Dplatforms=wayland,x11` matches the ROCKNIX display server (sway/Wayland with X11 fallback).
- Adjust remaining flags to the ROCKNIX buildroot's expectations as needed.

## Build

Full build (reference container wrapper):

```bash
docker exec turnip-rocknix bash -lc 'MESA_VER=26.1.3 /work/build_rocknix.sh'
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
- **Verify the binary by size/hash, not version string.** Both stock and fork report
  `Mesa 26.1.3` from `vulkaninfo`; confirm the right `.so` is bound via `stat -c %s` / `sha256sum`,
  not the reported driver version. (Consider setting `MESA_GIT_SHA1` or a unique symbol so the fork
  is self-identifying — currently it is not.)

## Selecting the driver on the rig

On ROCKNIX the built `.so` is staged under `/storage/turnip/drivers/` and selected through the
**Pitstop DRIVER tab**, which records the choice in `/storage/turnip/selected`; a boot service
bind-mounts the selected `.so` over `/usr/lib/libvulkan_freedreno.so`. The selection is
**cold-boot gated** — it must survive a full reboot to count as validated. (This selection
mechanism lives in the ETK repo, not here; this repo is source + build only.)
