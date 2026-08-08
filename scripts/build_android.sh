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

MESA_VER="${MESA_VER:-26.2.0}"
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

# --- Mesa source ---
if [ ! -d "$WORK/mesa-$MESA_VER" ]; then
  echo ">> downloading mesa $MESA_VER tarball"
  curl -fL --retry 3 -o mesa.tar.xz "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
  tar -xf mesa.tar.xz && rm -f mesa.tar.xz
fi
cd "$WORK/mesa-$MESA_VER"

# Same attribution caveat as the ROCKNIX lane: a tarball tree has no git sha, so
# driverInfo loses its (git-<sha>). Stock Android builds ship from the tarball
# deliberately — the version string still carries the Mesa release number.
[ -d .git ] || echo ">> note: tarball tree (no .git) — MESA_GIT_SHA1 empty, as with the shipped 26.1.3"

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
rm -rf build-android
meson setup build-android \
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

ninja -C build-android -j"$JOBS" src/freedreno/vulkan/libvulkan_freedreno.so

# --- versioned outputs -----------------------------------------------------
mkdir -p "$OUT"
RAW="$OUT/libvulkan_freedreno-android-$MESA_VER.so"
cp build-android/src/freedreno/vulkan/libvulkan_freedreno.so "$RAW"

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
cat > "$OUT/meta.json" <<METAEOF
{
  "schemaVersion": 1,
  "name": "ETK Turnip $MESA_VER (Stage IV base)",
  "description": "Mesa Turnip a6xx Vulkan driver for Adreno 650 / SM8250 — ETK Stage IV fork base.",
  "author": "Mesa / ETK",
  "packageVersion": "$MESA_VER",
  "vendor": "Mesa",
  "driverVersion": "$MESA_VER",
  "minApi": $API,
  "libraryName": "libvulkan_freedreno.so"
}
METAEOF

ADPKG="$OUT/etk-turnip-$MESA_VER-android.adpkg.zip"
rm -f "$ADPKG"
( cd "$OUT" && zip -q -X "$ADPKG" libvulkan_freedreno.so meta.json )

# ==========================================================
# GATES — an Android driver that loads on the wrong ABI, or links a soname the
# device does not have, fails at runtime with no useful message. Check here.
# ==========================================================
echo
echo ">> BUILT ANDROID $MESA_VER"
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
strings "$PKGSO" | grep -oE "Mesa $MESA_VER[^\"]*" | head -1 \
    || { echo "!!! no 'Mesa $MESA_VER' string — built from the wrong tree?"; exit 1; }

echo ">> package contents:"
unzip -l "$ADPKG"
echo ">> sha256:"
sha256sum "$PKGSO" "$ADPKG"
echo ">> LANE OK"
