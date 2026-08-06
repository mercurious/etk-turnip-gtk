#!/usr/bin/env bash
#
# provision-build-container.sh
#
# Create the `turnip-rocknix` build container on any arm64 Linux Docker host —
# the laptop's colima VM, or a remote box like the Oracle Cloud etk-cloud VM.
#
# WHY A CONTAINER AND NOT THE HOST: the artifact has to run on ROCKNIX (glibc
# 2.41, aarch64). Building in an ubuntu:24.04 container makes the glibc and
# toolchain versions a property of the recipe rather than of whatever machine
# happened to run it — the same reason the driver self-identifies.
#
# IT DOES NOT GIVE BYTE-REPRODUCIBLE BUILDS. `ubuntu:24.04` is a rolling tag and
# apt takes whatever is current, so a container built in July differs from one
# built in August. Measured 2026-08-05: laptop vs etk-cloud produced 17,614,520
# vs 17,548,592 bytes from the same series, with libc6-dev 2.39-0ubuntu8.7 vs
# 8.8 (every other build-relevant package matched). Don't split an A/B's arms
# across hosts. Set IMAGE to a digest (ubuntu@sha256:...) to pin harder.
#
# WHY REMOTE AT ALL: a Mesa build is ~700 objects. The laptop's colima VM has a
# fixed 60 GB disk that hit 96% mid-campaign (2026-07-30) and forced a cleanup
# before the build could finish. A cloud box with real cores and real disk turns
# that into a non-event.
#
# Usage:
#   scripts/provision-build-container.sh                      # local docker
#   ETK_BUILD_HOST=ubuntu@1.2.3.4 scripts/provision-build-container.sh
#
# Overrides: ETK_BUILD_HOST  CONTAINER  IMAGE  SSH_KEY
#
# Idempotent: re-running against an existing container only re-checks packages.
set -euo pipefail

ETK_BUILD_HOST="${ETK_BUILD_HOST:-}"          # empty = local docker
CONTAINER="${CONTAINER:-turnip-rocknix}"
IMAGE="${IMAGE:-ubuntu:24.04}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/etk_rig}"

# The container runs `git am` (prepare-fork-branch.sh), which refuses to commit
# without an identity. Inherit the operator's, so authorship on a cloud-built
# series matches a laptop-built one; fall back to a project identity.
GIT_NAME="${GIT_NAME:-$(git config --global user.name  2>/dev/null || echo 'ETK build')}"
GIT_EMAIL="${GIT_EMAIL:-$(git config --global user.email 2>/dev/null || echo 'etk@localhost')}"

# Run a command on whichever Docker host we were pointed at.
host_sh() {
  if [[ -n "${ETK_BUILD_HOST}" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -i "${SSH_KEY}" \
        "${ETK_BUILD_HOST}" "bash -s"
  else
    bash -s
  fi
}

# The dep set is not guessed — it is `apt-mark showmanual` from the container
# that has been producing shipped drivers since 26.1.3, minus the ubuntu:24.04
# base packages. Keep it in sync with that container, not with Mesa's docs.
PKGS="build-essential bison flex git curl zip file ca-certificates pkg-config
      ninja-build patchelf gdb-multiarch glslang-tools
      python3 python3-pip python3-mako python3-packaging python3-yaml
      libdrm-dev libelf-dev libexpat1-dev libvulkan-dev libxml2-dev
      libzstd-dev zlib1g-dev
      libwayland-dev libwayland-egl-backend-dev wayland-protocols
      libx11-dev libx11-xcb-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev
      libxcb-glx0-dev libxcb-keysyms1-dev libxcb-present-dev libxcb-randr0-dev
      libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev
      libxext-dev libxfixes-dev libxrandr-dev libxshmfence-dev libxxf86vm-dev"
# Flatten to one line: PKGS is interpolated into a single-quoted `bash -lc`
# string, so embedded newlines would split it into separate commands and only
# the first line's packages would install (silently — apt succeeds, the rest
# become "command not found").
PKGS="$(printf '%s' "${PKGS}" | tr -s '[:space:]' ' ')"

# Ubuntu 24.04's apt meson is too old for Mesa 26.x — the working container runs
# 1.11.1 from pip at /usr/local/bin/meson. Pin it so a rebuild cannot drift.
MESON_VERSION="${MESON_VERSION:-1.11.1}"

# The build wrapper is installed INTO the container, not assumed to be there.
# Until 2026-08-05 /work/build_rocknix.sh existed only inside the laptop's
# container — the authoritative configure line for every shipped driver, in no
# repo, one `docker rm` from gone. A freshly provisioned box (etk-cloud) had no
# way to build at all. Ship it from the repo instead.
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE_DIR/build_rocknix.sh" ] || { echo "ERROR: missing $HERE_DIR/build_rocknix.sh" >&2; exit 1; }
BUILD_WRAPPER_B64="$(base64 < "$HERE_DIR/build_rocknix.sh" | tr -d '\n')"

echo ">> Target: ${ETK_BUILD_HOST:-local docker}   container=${CONTAINER}  image=${IMAGE}"

host_sh <<REMOTE
set -euo pipefail
command -v docker >/dev/null || { echo "ERROR: docker not found on this host." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unreachable (start colima / add user to docker group)." >&2; exit 1; }

arch=\$(uname -m)
[ "\$arch" = "aarch64" ] || [ "\$arch" = "arm64" ] || \
  echo "WARNING: host arch is \$arch, not aarch64 — the driver must be built natively for ROCKNIX." >&2

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo ">> Container ${CONTAINER} exists; starting it"
  docker start "${CONTAINER}" >/dev/null
else
  echo ">> Creating ${CONTAINER} from ${IMAGE}"
  docker pull -q "${IMAGE}" >/dev/null
  # sleep infinity: a long-lived shell box we docker-exec into, matching how the
  # laptop container has always been driven.
  docker run -d --name "${CONTAINER}" -w /work "${IMAGE}" sleep infinity >/dev/null
  docker exec "${CONTAINER}" mkdir -p /work/out
fi

echo ">> Installing build dependencies (idempotent)"
docker exec "${CONTAINER}" bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null
  # pip on 24.04 is PEP-668 managed; this container is disposable, so the
  # break-system-packages escape is correct rather than a venv indirection.
  pip3 install -q --break-system-packages "meson==${MESON_VERSION}" >/dev/null
'

echo ">> Installing the build wrapper at /work/build_rocknix.sh"
docker exec "${CONTAINER}" bash -lc '
  printf %s "${BUILD_WRAPPER_B64}" | base64 -d > /work/build_rocknix.sh
  chmod +x /work/build_rocknix.sh
'

echo ">> Configuring git in the container (git am needs an identity)"
docker exec "${CONTAINER}" bash -lc '
  git config --global user.name  "${GIT_NAME}"
  git config --global user.email "${GIT_EMAIL}"
  # Build trees are created by root inside the container but may be bind-mounted
  # or docker-cp'"'"'d from another uid; without this git refuses with "dubious
  # ownership" and every prepare-fork-branch run fails at the first git call.
  git config --global --add safe.directory "*"
'

echo ">> Toolchain in ${CONTAINER}:"
docker exec "${CONTAINER}" bash -lc '
  for t in gcc g++ meson ninja python3 glslangValidator pkg-config; do
    printf "     %-16s %s\n" "\$t" "\$(\$t --version 2>/dev/null | head -1 | cut -c1-44)"
  done
  printf "     %-16s %s\n" "glibc" "\$(ldd --version | head -1 | awk "{print \\\$NF}")"
'
REMOTE

echo ">> Done. Build with:  FORK_DOCKER=${CONTAINER} (see BUILDING.md)"
