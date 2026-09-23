# Building the ETK Turnip GTK fork (ROCKNIX / glibc / `msm`)

This produces `libvulkan_freedreno.so` for **glibc ARM64** (ROCKNIX) targeting the
SM8250 / Adreno 650. It is **not** the Android build — the Android Turnip is `bionic`/KGSL and the
two `.so` files are not interchangeable. (A separate Android build path exists for aPS3e; it is out
of scope here.)

## Prerequisites

- An ARM64 Linux build environment (native arm64 avoids Rosetta/emulation issues). The reference
  setup is a Docker container, `turnip-rocknix`, on Ubuntu 24.04 arm64. On macOS this runs under
  [colima](https://github.com/abiosoft/colima)/Docker; a native arm64 Linux box or VM is preferred.

  **Provision it with one command, locally or remotely:**

  ```bash
  scripts/provision-build-container.sh                          # local docker
  ETK_BUILD_HOST=etk-cloud scripts/provision-build-container.sh  # remote arm64 box
  ```

  It is idempotent, pins `meson` (Ubuntu 24.04's apt meson is too old for Mesa 26.x), and sets the
  container's git identity — `prepare-fork-branch.sh` runs `git am`, which refuses to commit
  without one. The dependency list is not guessed: it is `apt-mark showmanual` from the container
  that has produced every shipped driver since 26.1.3.

  Building in an `ubuntu:24.04` container makes glibc and the toolchain a property of the *recipe*
  rather than of whichever machine ran it — the same reasoning as the self-identifying driver.

  > **It does not give you byte-reproducible builds, and measured evidence says so.** The same
  > series built on the laptop container and on `etk-cloud` produced different binaries
  > (17,614,520 vs 17,548,592 bytes). `ubuntu:24.04` is a *rolling* tag and `apt-get install` takes
  > whatever is current, so a container provisioned in July and one provisioned in August differ —
  > confirmed here as `libc6-dev` `2.39-0ubuntu8.7` vs `8.8`, with the remaining size delta not
  > fully isolated. Every other build-relevant package matched.
  >
  > Practical consequences:
  > - **Don't mix hosts inside one campaign.** Build an A/B's arms on the same container.
  > - The driver's `(git-<sha>)` makes the two distinguishable in `vulkaninfo` and in every ledger
  >   row, so they can't be silently conflated — the attribution net catches this class of drift.
  > - For true reproducibility, pin the base image by digest
  >   (`IMAGE=ubuntu@sha256:… scripts/provision-build-container.sh`) and snapshot the apt state.
  >   Not done yet; the honest status is "same recipe, near-identical toolchain, different bytes".
- Toolchain matching the ROCKNIX target: **glibc 2.41**, meson + ninja, the standard Mesa build
  deps (see Mesa's own `docs/install.rst`).
- A Mesa checkout at tag `mesa-26.2.3` with the fork patches applied
  (see [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh)).
- **`git` on `PATH` at build time.** Mesa generates `git_sha1.h` from the checkout; without it
  `MESA_GIT_SHA1` is empty and the build loses its per-build identity (see *Identifying a build*).

## Getting the source

```bash
./scripts/prepare-fork-branch.sh apply
```

That clones upstream at the base tag (default `mesa-26.2.3`), applies the line's backports, then
the fork series. The **fallback stable** (the 26.1 series is EOL upstream; this track is frozen)
is the same command on the previous line's last tag:

```bash
BASE_TAG=mesa-26.1.6 ./scripts/prepare-fork-branch.sh apply
```

`BASE_TAG` accepts a release tag, an rc tag, a stable branch (`26.2`), or a **commit sha**.
For a moving branch, add `REUSE=1` to re-pull an existing checkout in place. The backport set is
chosen automatically from the base — `patches/backports/26.1/` for the 26.1 line, nothing for 26.2
or newer (they carry those commits natively). Verified clean on `mesa-26.2.3` (8/8) on 2026-09-23;
`mesa-26.2.2` (8/8) and main @ `c0682c54` (5/8, `SKIP_PATCHES='0002-* 0003-* 0004-*'`) on 2026-09-02; previously `mesa-26.2.1`
(8/8) and main @ `d2e56df` (7/8) on 2026-08-21, and `mesa-26.2.0`/`mesa-26.1.6` (both 8/8) and
main @ `e40d93a` on 2026-08-07.

### Devel-branch builds must be pinned by sha, not tracked by name

This is the **pre-release track** while no upstream rc exists (`mesa-26.3.0-rc1` is scheduled
2026-10-14 and will slot into the same mechanism as a plain rc-tag apply):

```bash
MAIN_SHA=$(git ls-remote https://gitlab.freedesktop.org/mesa/mesa.git refs/heads/main | cut -f1)
BASE_TAG=$MAIN_SHA SKIP_PATCHES='0002-* 0003-* 0004-*' \
  WORKDIR=$PWD/mesa-fork-26.3.0-devel-$(date +%Y%m%d)-${MAIN_SHA:0:7} ./scripts/prepare-fork-branch.sh apply
```

`main` is a **position, not a version**. Two builds a week apart both report `26.3.0-devel` and are
different drivers — so a branch-tracked build puts a name in the ledger that cannot identify what
ran, defeating stack attribution. Pin the sha and carry it in the artifact name
(`…26.3.0-devel-20260902-c0682c5_gtk_0.x.so` — date first so the DRIVER tab's lexical sort is
chronological; `-e40d93a` is the one grandfathered sha-only name). `SKIP_PATCHES='0002-* 0003-* 0004-*'`
is required on main: upstream's `depth_cache_fraction` rework removed patch 0002's context, and
main @ `df96a4da` (2026-08-28) renamed `rp.gmem_disable_reason` to `force_render_mode_reason`,
the field patches 0003/0004 write. All three gears (`ccuhalf`/`ccuquarter`, `dsbypass`, `dsany`)
stay registered (patch 0001's `tu_etk_gears.h` registry) and are simply inert — dead gears anyway.

> **Naming, because the community convention is misleading.** Android adrenotools packages (e.g.
> `Turnip_v26.3.0-Rn`) are named after `main`'s in-progress VERSION string, so "v26.3.0" means
> *main as of that date* — there is no Mesa 26.3 branchpoint or rc. Their `v26.2.0-R8` (2026-07-09,
> pre-branchpoint `main`) is **older, less stabilised code** than `mesa-26.2.0-rc3` (2026-07-29, the
> stabilisation branch). A higher number is not a newer release.

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
  configure line. Verified against `mesa-26.2.0` and `26.3.0-devel` @ `e40d93a` on 2026-08-07
  (previously `mesa-26.1.6` and `mesa-26.2.0-rc3` on 2026-07-30).

## Build

Full build (reference container wrapper):

```bash
docker exec turnip-rocknix bash -lc 'MESA_VER=26.2.3 /work/build_rocknix.sh'
```

For fleet builds, this wrapper is conducted by **`~/etk/forge.sh turnip`** (the ETK mother repo):
one build per version in `FORGE_TURNIP_VERS`, run detached on `etk-cloud`, gated on the `ETK-GTK`
version string + embedded-git == tree HEAD + unstripped size, and staged into `~/etk/drivers/` as
`etk_turnip_rocknix_<ver>_gtk_<gen>.so` with a sha256 sidecar. Its lane refuses a tree without
`tu_etk_gears.h` (a pre-decoupling tree is the shipped bit-collision build). Prepare the node trees
at `/work/mesa-<ver>` with `prepare-fork-branch.sh apply` first.

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
#   driverInfo = Mesa 26.2.0 (git-1a2b3c4d5e) ETK-GTK
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

Stage artifacts with the base and sha in the filename so the DRIVER tab can tell them apart.
The raw build output is named `libvulkan_freedreno-rocknix-<ver>.so`; the shipped catalog name
(what `~/etk/drivers/` and the DRIVER tab carry) is `etk_turnip_rocknix_<ver>_gtk_<gen>.so`:

```
libvulkan_freedreno-rocknix-26.2.0-etk-g<sha>.so              # manual staging
etk_turnip_rocknix_26.2.0_gtk_0.7.so                          # forge/catalog name
etk_turnip_rocknix_26.3.0-devel-e40d93a_gtk_0.7.so            # devel carries the base pin
```

The ICD json's `api_version` is derived at build time from the tree's own `VK_HEADER_VERSION`
(it was a hardcoded constant once, and shipped stale).

## Selecting the driver on the rig

On ROCKNIX the built `.so` is staged under `/storage/turnip/drivers/` and selected through the
**Pitstop DRIVER tab**, which records the choice in `/storage/turnip/selected`; a boot service
bind-mounts the selected `.so` over `/usr/lib/libvulkan_freedreno.so`. The selection is
**cold-boot gated** — it must survive a full reboot to count as validated. (This selection
mechanism lives in the ETK repo, not here; this repo is source + build only.)
