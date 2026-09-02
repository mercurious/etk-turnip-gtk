#!/usr/bin/env bash
# ETK Stage IV — Turnip (Mesa) ANDROID build (bionic/kgsl), packaged for AdrenoTools.
# Runs INSIDE the native-arm64 'turnip-android' container. Sibling of build_rocknix.sh:
# same source, same fork, different OS/ABI — see etk/drivers/README.md for why a
# driver built for one can never load on the other.
#
# WHY THIS EXISTS: etk-turnip-26.1.3-android.adpkg.zip is the single most
# downloaded artifact this project has published (1,629 as of 2026-08-07) and
# until now it had NO recipe in any repo — the same failure the 2026-08-05 fleet
# audit found in four other lanes, on the highest-stakes target of the lot. The
# configure line below is reconstructed from that release's own notes.
#
# The ROCKNIX driver takes the fork patches; this one is currently STOCK Mesa,
# matching what shipped as 26.1.3. Patching Android is a separate decision —
# note that fork patch 0006 exists to give ROCKNIX *KGSL parity*, i.e. to make
# the msm driver behave the way this one already does.
#
# MUST be validated by actually loading it on-device (aPS3e driver manager),
# never by the gates alone.
set -euo pipefail

MESA_VER="${MESA_VER:-26.2.2}"   # stable-track default — keep in lockstep with prepare-fork-branch.sh BASE_TAG
JOBS="${JOBS:-4}"
API="${API:-26}"                 # matches the shipped package's minApi
NDK="${NDK:-/ndk}"
WORK=/work
OUT="$WORK/out"
cd "$WORK"

# --- NDK toolchain: detect the host tag, never hardcode it ------------------
# Google ships no aarch64 Linux NDK; the community build names its host tag
# dir 'linux-arm64' (NOT linux-aarch64) and leaves a linux-x86_64 compat
# symlink. Picking the real directory keeps us off the symlink.
NDKBIN=""
for d in "$NDK"/toolchains/llvm/prebuilt/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in linux-x86_64) continue ;; esac   # skip the compat symlink
    NDKBIN="${d}bin"; break
done
[ -n "$NDKBIN" ] && [ -x "$NDKBIN/clang" ] || { echo "ERROR: no usable NDK toolchain under $NDK"; exit 1; }
echo ">> NDK toolchain: $NDKBIN"
"$NDKBIN/clang" --version | head -1

CC_BIN="$NDKBIN/aarch64-linux-android$API-clang"
CXX_BIN="$NDKBIN/aarch64-linux-android$API-clang++"
[ -x "$CC_BIN" ] || { echo "ERROR: $CC_BIN missing — API $API not provided by this NDK"; exit 1; }

# --- Mesa source: TARBALL (stable) or GIT (pre-release) --------------------
# MESA_REF set  -> devel track: clone Mesa main and build a PINNED commit.
# MESA_REF unset-> stable track: the released tarball for MESA_VER.
#
# The devel track exists because the Android Turnip scene ships almost entirely
# from Mesa main, and does it opaquely — a driver named after its author with no
# way to learn what source produced it. A pinned sha, embedded in the binary and
# printed in the package, is the whole differentiator. Anyone can rebuild ours.
MESA_REF="${MESA_REF:-}"
MESA_GIT_URL="${MESA_GIT_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_SHA=""
TRACK="stable"

if [ -n "$MESA_REF" ]; then
  TRACK="devel"
  SRCDIR="$WORK/mesa-git"
  if [ ! -d "$SRCDIR/.git" ]; then
    echo ">> cloning mesa main (once; ~1.5 GB)"
    git clone --filter=blob:none "$MESA_GIT_URL" "$SRCDIR"
  fi
  cd "$SRCDIR"
  echo ">> fetching + pinning $MESA_REF"
  git fetch -q --all --tags
  git checkout -q --detach "$MESA_REF" 2>/dev/null || git checkout -q --detach "origin/$MESA_REF"
  git reset -q --hard
  MESA_SHA=$(git rev-parse --short=9 HEAD)
  # Keep the FULL sha for the attribution gate. Mesa embeds its own abbreviation
  # (10 chars, not ours), so the only safe comparison is "is the embedded value
  # a prefix of the full commit id" — comparing two different abbreviations can
  # never match and fails a correct build.
  MESA_FULLSHA=$(git rev-parse HEAD)
  # Mesa's VERSION file is the authority for what main currently calls itself
  # (e.g. 26.3.0-devel). Never guess it from the branch name.
  MESA_VER=$(tr -d ' \n' < VERSION)
  echo ">> devel track: mesa $MESA_VER @ $MESA_SHA"
else
  if [ ! -d "$WORK/mesa-$MESA_VER" ]; then
    echo ">> downloading mesa $MESA_VER tarball"
    curl -fL --retry 3 -o mesa.tar.xz "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
    tar -xf mesa.tar.xz && rm -f mesa.tar.xz
  fi
  cd "$WORK/mesa-$MESA_VER"
  # Attribution caveat, same as the ROCKNIX lane: a tarball tree has no git sha,
  # so the version string carries the release number and no (git-<sha>). That is
  # correct for a stable build — the release number IS the identity.
  [ -d .git ] || echo ">> note: tarball tree (no .git) — MESA_GIT_SHA1 empty, as with the shipped 26.1.3"
fi

# --- meson cross file ------------------------------------------------------
# pkg_config_libdir points at an EMPTY directory on purpose. Without it, meson
# runs the host pkg-config and happily satisfies TARGET dependencies from the
# aarch64-Linux host: the first attempt defined -DHAVE_ZSTD -DHAVE_ZLIB
# -DUSE_LIBELF -DHAVE_SPIRV_TOOLS from host packages and then died on
# "'zstd.h' file not found", because the header search is the NDK sysroot while
# the *detection* was the host. Host arch matches target arch here, which is
# exactly what makes the leak silent — a mismatched host would have failed
# loudly. Starve pkg-config instead; the NDK sysroot still resolves libz and
# friends through the compiler.
EMPTY_PC="$WORK/.empty-pkgconfig"; mkdir -p "$EMPTY_PC"
CROSS="$WORK/android-aarch64-$API.cross"
cat > "$CROSS" <<CROSSEOF
[binaries]
ar = '$NDKBIN/llvm-ar'
strip = '$NDKBIN/llvm-strip'
c = ['$CC_BIN']
cpp = ['$CXX_BIN']
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = ['/usr/bin/pkg-config']

[properties]
pkg_config_libdir = ['$EMPTY_PC']

[built-in options]
# Link libc++ STATICALLY. Without this the driver carries a DT_NEEDED on
# libc++_shared.so, which is an NDK library and NOT part of Android — it exists
# on a device only if some app happened to bundle it. The driver then fails to
# load with nothing useful in the log. The shipped 26.1.3 has no such NEEDED;
# the first build here did, and that is a shipping defect, not a detail.
cpp_link_args = ['-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
CROSSEOF
echo ">> cross file: $CROSS"

# --- configure: Vulkan-only freedreno, KGSL kmd, android platform ----------
# android-stub synthesizes the Android framework libs (libcutils, libhardware,
# libnativewindow, liblog) so no AOSP tree is needed; the real ones are resolved
# on-device at load time.
BUILDDIR="build-android"
rm -rf "$BUILDDIR"
meson setup "$BUILDDIR" \
  --cross-file "$CROSS" \
  -Dbuildtype=release \
  -Dplatforms=android \
  -Dplatform-sdk-version="$API" \
  -Dandroid-stub=true \
  -Dvulkan-drivers=freedreno \
  -Dgallium-drivers= \
  -Dfreedreno-kmds=kgsl \
  -Dvideo-codecs= \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
  -Dcpp_rtti=false \
  -Db_lto=false -Dstrip=false

ninja -C "$BUILDDIR" -j"$JOBS" src/freedreno/vulkan/libvulkan_freedreno.so

# --- versioned outputs -----------------------------------------------------
# VERLABEL is the ONE identity string: it names the file, the package, and what
# the user sees in the driver picker, so those can never disagree. A devel build
# carries its pinned sha in the label — that is the promise the scene does not
# make ("T28-toasted" identifies nothing you can check).
if [ "$TRACK" = devel ]; then
    VERLABEL="$MESA_VER-$MESA_SHA"
    DISPLAY_NAME="ETK Turnip $MESA_VER ($MESA_SHA)"
    TRACK_BLURB="Pre-release: built from Mesa's development branch at commit $MESA_SHA. Newer fixes, less testing."
else
    VERLABEL="$MESA_VER"
    DISPLAY_NAME="ETK Turnip $MESA_VER"
    TRACK_BLURB="Stable: built from the official Mesa $MESA_VER release."
fi

mkdir -p "$OUT"
RAW="$OUT/libvulkan_freedreno-android-$VERLABEL.so"
cp "$BUILDDIR/src/freedreno/vulkan/libvulkan_freedreno.so" "$RAW"

# The SHIPPED package carries a STRIPPED .so (14,394,560 B for 26.1.3). Strip
# with the NDK's llvm-strip, not the host binutils strip — a host strip on a
# bionic object is the classic way to produce a subtly broken library.
PKGSO="$OUT/libvulkan_freedreno.so"
cp "$RAW" "$PKGSO"
"$NDKBIN/llvm-strip" "$PKGSO"

# --- AdrenoTools package ---------------------------------------------------
# Schema per the adrenotools loader; libraryName MUST match the .so in the zip.
# Our naming stays version-only (law #8) — the scene's convention of nicknaming
# builds after their author is exactly what makes "which turnip should I use"
# unanswerable.
# `name` is the ONLY line most users ever read — it is what the driver picker
# shows. It must say which build this is without jargon, because the alternative
# is a list of nicknames the user cannot rank.
cat > "$OUT/meta.json" <<METAEOF
{
  "schemaVersion": 1,
  "name": "$DISPLAY_NAME",
  "description": "$TRACK_BLURB Tested on Adreno 650 (Snapdragon 865/870). Other Adreno 6xx/7xx should work but are untested. Full details: github.com/mercurious/etk-turnip-gtk",
  "author": "Mesa / mercurious",
  "packageVersion": "$VERLABEL",
  "vendor": "Mesa",
  "driverVersion": "$VERLABEL",
  "minApi": $API,
  "libraryName": "libvulkan_freedreno.so"
}
METAEOF

ADPKG="$OUT/etk-turnip-$VERLABEL-android.adpkg.zip"
rm -f "$ADPKG"
( cd "$OUT" && zip -q -X "$ADPKG" libvulkan_freedreno.so meta.json )

# ==========================================================
# GATES — an Android driver that loads on the wrong ABI, or links a soname the
# device does not have, fails at runtime with no useful message. Check here.
# ==========================================================
echo
echo ">> BUILT ANDROID $VERLABEL ($TRACK track)"
ls -la "$RAW" "$PKGSO" "$ADPKG"
file "$PKGSO"

echo ">> ELF arch (must be AArch64):"
readelf -h "$PKGSO" | awk -F: '/Machine/{print $2}' | xargs
readelf -h "$PKGSO" | grep -q AArch64 || { echo "!!! NOT AArch64"; exit 1; }

# Android does NOT use the Vulkan ICD loader interface — it loads the driver as
# a HAL module and enters through the hw_module_t symbol `HMI`. Checking for
# vk_icdGetInstanceProcAddr here (as the ROCKNIX lane correctly does) fails on a
# perfectly good Android driver. Verified against the shipped 26.1.3, which
# exports HMI and no vk_icd* at all.
echo ">> Android HAL entry point (expect HMI):"
nm -D --defined-only "$RAW" | grep -E ' [DdBb] HMI$' \
    || { echo "!!! HMI MISSING — not a loadable Android Vulkan HAL"; exit 1; }

# The bionic NEEDED set is the tell that this is an Android build and not a
# glibc one that happens to be aarch64. A glibc build lists libc.so.6; bionic
# lists a bare libc.so plus the framework libs.
echo ">> NEEDED libs (bionic set — libc.so bare, NOT libc.so.6):"
readelf -d "$PKGSO" | grep NEEDED
if readelf -d "$PKGSO" | grep -q 'libc\.so\.6'; then
    echo "!!! links glibc (libc.so.6) — this is NOT an Android driver"; exit 1
fi
readelf -d "$PKGSO" | grep -q 'Shared library: \[libc\.so\]' \
    || { echo "!!! no bare libc.so — not a bionic link"; exit 1; }

# libc++_shared.so ships with an APP, not with Android. A driver that NEEDs it
# will not load on a device where nothing has provided it, and the failure is
# silent. Every NEEDED here must be an Android system library.
if readelf -d "$PKGSO" | grep -q 'libc++_shared\.so'; then
    echo "!!! NEEDS libc++_shared.so — not an Android system library; driver will fail to load."
    echo "    Fix: link libc++ statically (cpp_link_args = ['-static-libstdc++'])."
    exit 1
fi

echo ">> embedded version string:"
VSTR=$(strings "$PKGSO" | grep -oE "Mesa $MESA_VER[^\"]*" | head -1)
[ -n "$VSTR" ] || { echo "!!! no 'Mesa $MESA_VER' string — built from the wrong tree?"; exit 1; }
echo "   $VSTR"

# On the devel track the embedded sha must match the commit we pinned. This is
# the ROCKNIX lane's law ("proof the artifact came from the tree you think it
# did") and it is the entire basis of the claim that our pre-releases are
# auditable: a user can read the sha off the driver and diff it themselves.
if [ "$TRACK" = devel ]; then
    EMBED=$(printf '%s' "$VSTR" | sed -n 's/.*git-\([0-9a-f]*\).*/\1/p')
    [ -n "$EMBED" ] || { echo "!!! devel build carries no git- sha in its version string"; exit 1; }
    case "$MESA_FULLSHA" in
        "$EMBED"*) echo "   embedded git-$EMBED is a prefix of pinned $MESA_FULLSHA" ;;
        *) echo "!!! embedded git-$EMBED is NOT a prefix of pinned $MESA_FULLSHA — built from a different tree"; exit 1 ;;
    esac
fi

echo ">> package contents:"
unzip -l "$ADPKG"
echo ">> sha256:"
sha256sum "$PKGSO" "$ADPKG"
echo ">> LANE OK"
