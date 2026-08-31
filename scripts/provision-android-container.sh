#!/usr/bin/env bash
#
# provision-android-container.sh
#
# Create the `turnip-android` build container — the bionic/kgsl sibling of
# provision-build-container.sh's `turnip-rocknix`.
#
# WHY A SECOND CONTAINER: the ROCKNIX lane builds against glibc + wayland/x11
# and links libdrm; this one cross-compiles against bionic with the Android NDK
# and links the Android framework libs. Same Mesa source, incompatible
# toolchains. Keeping them separate means neither lane's dep set can silently
# satisfy the other's build and produce a driver for the wrong OS.
#
# THE NDK IS THE HARD PART. Google ships host toolchains for linux-x86_64,
# darwin-x86_64 and windows-x86_64 only — there is no official aarch64 Linux
# NDK, so an ARM build box cannot cross-compile for Android out of the box.
# This installs the community aarch64-native build, sha256-pinned. It is a
# CUSTOM LLVM build, so its codegen is not Google's: do not split an A/B's arms
# between a driver built here and one built with an official NDK elsewhere.
#
# SELF-CONTAINED ON PURPOSE. It installs its own NDK rather than borrowing the
# aPS3e lane's copy — that lane is marked for retirement, and the most
# downloaded artifact this project ships must not depend on a directory that is
# scheduled to disappear.
#
# Usage:
#   scripts/provision-android-container.sh
#   ETK_BUILD_HOST=ubuntu@1.2.3.4 scripts/provision-android-container.sh
#
# Overrides: ETK_BUILD_HOST  CONTAINER  IMAGE  SSH_KEY  LANE_ROOT
#
# Idempotent: re-running against an existing container only re-checks packages.
set -euo pipefail

ETK_BUILD_HOST="${ETK_BUILD_HOST:-}"          # empty = local docker
CONTAINER="${CONTAINER:-turnip-android}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/etk_rig}"
LANE_ROOT="${LANE_ROOT:-\$HOME/turnip-android-lane}"   # expanded on the BUILD HOST

# Pinned by digest, not by tag. On 2026-08-05 the Air and etk-cloud held
# different images behind an identical ubuntu:24.04 tag (786a8b55 vs 561618e2).
IMAGE="${IMAGE:-ubuntu@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea}"

# NDK r27d, aarch64-linux-gnu host. Host tag dir inside is 'linux-arm64'
# (NOT linux-aarch64) with a linux-x86_64 compat symlink — build_android.sh
# detects it rather than assuming.
NDK_URL="${NDK_URL:-https://github.com/HomuHomu833/android-ndk-custom/releases/download/r27/android-ndk-r27d-aarch64-linux-gnu.tar.xz}"
NDK_SHA256="${NDK_SHA256:-568e69a57a0dcec3d885df3a1d184fffbdbd8edfef4d598d1911f98cf3baecef}"

# Mesa 26.x needs a newer meson than Ubuntu 24.04 ships; same pin as the
# ROCKNIX container so the two lanes cannot drift apart on build-system version.
MESON_VERSION="${MESON_VERSION:-1.11.1}"

# Dep set is the ROCKNIX container's, minus the glibc/wayland/x11 dev packages
# that an android-stub cross build never touches, plus zip for the adpkg.
# glslang-tools is NOT optional and is easy to mistake for a graphics-stack dep
# you can drop on a cross build: glslangValidator runs on the BUILD machine to
# compile Mesa's own internal shaders, so it is needed whatever the target.
# Dropping it fails at meson setup with "Program 'glslangValidator' not found".
PKGS="build-essential bison flex git curl zip unzip xz-utils file ca-certificates
      pkg-config ninja-build patchelf glslang-tools
      python3 python3-pip python3-mako python3-packaging python3-yaml
      libelf-dev libexpat1-dev libxml2-dev zlib1g-dev"
PKGS="$(printf '%s' "${PKGS}" | tr -s '[:space:]' ' ')"

host_sh() {
  if [[ -n "${ETK_BUILD_HOST}" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -i "${SSH_KEY}" \
        "${ETK_BUILD_HOST}" "bash -s"
  else
    bash -s
  fi
}

# Ship the recipe from the repo, never assume it is already in the container —
# the lesson that cost the ROCKNIX lane its only copy of build_rocknix.sh.
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE_DIR/build_android.sh" ] || { echo "ERROR: missing $HERE_DIR/build_android.sh" >&2; exit 1; }
BUILD_WRAPPER_B64="$(base64 < "$HERE_DIR/build_android.sh" | tr -d '\n')"

echo ">> Target: ${ETK_BUILD_HOST:-local docker}   container=${CONTAINER}"

host_sh <<REMOTE
set -euo pipefail
command -v docker >/dev/null || { echo "ERROR: docker not found on this host." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unreachable." >&2; exit 1; }

arch=\$(uname -m)
[ "\$arch" = "aarch64" ] || [ "\$arch" = "arm64" ] || {
  echo "ERROR: host arch is \$arch. This lane needs an aarch64 host — the NDK it installs is an aarch64-native build." >&2
  exit 1; }

LANE="${LANE_ROOT}"
mkdir -p "\$LANE"/{work,ndk,dl}

# --- NDK, sha256-pinned ---------------------------------------------------
if [ ! -f "\$LANE/ndk/source.properties" ]; then
  if [ ! -f "\$LANE/dl/ndk.tar.xz" ]; then
    echo ">> fetching NDK"
    curl -fsSL -o "\$LANE/dl/ndk.tar.xz.part" "${NDK_URL}"
    mv "\$LANE/dl/ndk.tar.xz.part" "\$LANE/dl/ndk.tar.xz"
  fi
  got=\$(sha256sum "\$LANE/dl/ndk.tar.xz" | cut -d' ' -f1)
  [ "\$got" = "${NDK_SHA256}" ] || { echo "ERROR: NDK sha256 mismatch: \$got != ${NDK_SHA256}" >&2; exit 1; }
  echo ">> extracting NDK (sha ok)"
  rm -rf "\$LANE/ndk.tmp" && mkdir -p "\$LANE/ndk.tmp"
  tar -xf "\$LANE/dl/ndk.tar.xz" -C "\$LANE/ndk.tmp"
  src=\$(dirname "\$(find "\$LANE/ndk.tmp" -maxdepth 2 -name source.properties | head -1)")
  [ -n "\$src" ] || { echo "ERROR: no source.properties in the NDK tarball" >&2; exit 1; }
  rm -rf "\$LANE/ndk" && mv "\$src" "\$LANE/ndk" && rm -rf "\$LANE/ndk.tmp"
fi
echo ">> NDK: \$(grep '^Pkg.Revision' "\$LANE/ndk/source.properties" | tr -d ' ')"

# --- container ------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo ">> Container ${CONTAINER} exists; starting it"
  docker start "${CONTAINER}" >/dev/null
else
  echo ">> Creating ${CONTAINER} from ${IMAGE}"
  # Bind-mount the lane: /work and the NDK live on the HOST, so \`docker rm\`
  # costs a re-provision and not the toolchain.
  docker run -d --name "${CONTAINER}" \
    -v "\$LANE/work:/work" \
    -v "\$LANE/ndk:/ndk:ro" \
    -w /work "${IMAGE}" sleep infinity >/dev/null
  docker exec "${CONTAINER}" mkdir -p /work/out
fi

echo ">> Installing build dependencies (idempotent)"
docker exec "${CONTAINER}" bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null
  pip3 install -q --break-system-packages "meson==${MESON_VERSION}" >/dev/null
'

echo ">> Installing the build wrapper at /work/build_android.sh"
docker exec "${CONTAINER}" bash -lc '
  printf %s "${BUILD_WRAPPER_B64}" | base64 -d > /work/build_android.sh
  chmod +x /work/build_android.sh
'

echo ">> Toolchain in ${CONTAINER}:"
docker exec "${CONTAINER}" bash -lc '
  ndkbin=\$(ls -d /ndk/toolchains/llvm/prebuilt/*/ | grep -v linux-x86_64 | head -1)bin
  printf "     %-18s %s\n" "ndk"     "\$(grep ^Pkg.Revision /ndk/source.properties | tr -d " ")"
  printf "     %-18s %s\n" "clang"   "\$(\$ndkbin/clang --version | head -1)"
  printf "     %-18s %s\n" "clang arch" "\$(file -bL \$ndkbin/clang | cut -c1-40)"
  printf "     %-18s %s\n" "meson"   "\$(meson --version)"
  printf "     %-18s %s\n" "ninja"   "\$(ninja --version)"
  printf "     %-18s %s\n" "python3" "\$(python3 --version)"
'
echo ">> Done. Build with:  docker exec ${CONTAINER} bash -lc 'MESA_VER=26.2.1 /work/build_android.sh'"
REMOTE
