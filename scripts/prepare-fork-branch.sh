#!/usr/bin/env bash
#
# prepare-fork-branch.sh
#
# Produce a clean, auditable fork branch: a fresh checkout of upstream Mesa at the
# `mesa-26.1.3` tag with the ETK GTK patch series applied as discrete commits on top.
# The result is a tree where `git log mesa-26.1.3..` shows exactly the fork delta, and
# upstream's license files and per-file SPDX headers are carried verbatim.
#
# Why a script and not a GitHub fork: Mesa's canonical home is freedesktop GitLab, not
# GitHub, so there is no GitHub fork-network relationship to inherit. We rebuild the
# lineage explicitly from the upstream tag instead.
#
# IMPORTANT — the build tree's git history has NO stock-upstream baseline. Its first
# commit ("737f654 baseline: mesa 26.1.3 + ETK LSD gears + dimlog") already contains the
# load-bearing gears squashed into a tarball import. A plain `format-patch baseline..HEAD`
# would therefore MISS sddepth/dimlog and export only the (falsified) Patch #3 commits.
# To capture the complete, real delta we diff against a pristine upstream clone:
#
#   patch 0001  = pristine mesa-26.1.3  ->  fork import commit (FORK_BASE) tracked tree
#                 i.e. the LSD/dimlog/sddepth gears that were squashed into the import
#   patch 000N  = the real discrete commits FORK_BASE..FORK_HEAD (the Patch #3 series)
#
# Commands:
#   build   Author the series (needs the container + network). Clones upstream, overlays
#           the fork's import tree, applies the on-top commits, writes ./patches/, and
#           leaves a built checkout under WORKDIR.
#   apply   Reproduce WORKDIR from ./patches/ alone (needs only network) — what a third
#           party or future-you runs without access to the build container.
#
set -euo pipefail

# ---- Config (override via environment) --------------------------------------
UPSTREAM_URL="${UPSTREAM_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}"
BASE_TAG="${BASE_TAG:-mesa-26.1.3}"
FORK_BRANCH="${FORK_BRANCH:-etk-gtk}"
WORKDIR="${WORKDIR:-$(pwd)/mesa-fork-${BASE_TAG}}"
PATCH_DIR="${PATCH_DIR:-$(cd "$(dirname "$0")/.." && pwd)/patches}"

# `build` mode: where the fork tree lives and the commit range to capture.
FORK_TREE="${FORK_TREE:-}"                  # e.g. /work/mesa-26.1.3
FORK_DOCKER="${FORK_DOCKER:-}"              # if set, FORK_TREE is a path INSIDE this container
FORK_BASE="${FORK_BASE:-737f654}"          # tarball-import baseline (gears squashed in)
FORK_HEAD="${FORK_HEAD:-4b1bcd4}"          # final fork commit (dsany variant)
IMPORT_MSG="${IMPORT_MSG:-ETK GTK gears: LSD/sddepth depth-cache barriers + dimlog (squashed import over mesa-26.1.3; see PATCHES.md)}"

# Dev-only cruft that lives in the fork tree but must NOT ship in the public series:
# manual stock-file backups and compiled python bytecode. Pruned from the overlay before
# committing. Space-separated find-name globs (matched anywhere in the tree).
FORK_EXCLUDES="${FORK_EXCLUDES:-*.etk-stock *.etk-stock-* *.patch1bak *.orig __pycache__}"

# Files the fork edited only for its local build workflow — reverted to upstream so the
# public series carries the gears and nothing else. Space-separated repo-relative paths.
FORK_RESTORE="${FORK_RESTORE:-.gitignore}"

usage() {
  cat <<EOF
Usage: $0 <build|apply>

  build   Author the patch series. Requires the fork tree (container or host) AND network.
          In-container:  FORK_DOCKER=turnip-rocknix FORK_TREE=/work/mesa-26.1.3 $0 build
          On host:       FORK_TREE=/path/to/mesa-26.1.3 $0 build

  apply   Reproduce the fork checkout from committed ./patches/ onto a fresh upstream
          ${BASE_TAG} clone. Needs only network.

Overrides: UPSTREAM_URL BASE_TAG FORK_BRANCH WORKDIR PATCH_DIR
           FORK_TREE FORK_DOCKER FORK_BASE FORK_HEAD IMPORT_MSG
EOF
}

# Run git against the fork tree, transparently via docker exec when containerized.
fork_git() {
  if [[ -n "${FORK_DOCKER}" ]]; then
    docker exec "${FORK_DOCKER}" git -C "${FORK_TREE}" "$@"
  else
    git -C "${FORK_TREE}" "$@"
  fi
}

# Stream a tar of FORK_TREE's tracked files at a given ref to stdout.
fork_archive() {
  local ref="$1"
  if [[ -n "${FORK_DOCKER}" ]]; then
    docker exec "${FORK_DOCKER}" git -C "${FORK_TREE}" archive --format=tar "${ref}"
  else
    git -C "${FORK_TREE}" archive --format=tar "${ref}"
  fi
}

preflight_fork() {
  if [[ -z "${FORK_TREE}" ]]; then
    echo "ERROR: set FORK_TREE (the Mesa build tree path)." >&2; usage; exit 1
  fi
  if [[ -n "${FORK_DOCKER}" ]]; then
    docker info >/dev/null 2>&1 || { echo "ERROR: docker unreachable (start colima)." >&2; exit 1; }
    docker exec "${FORK_DOCKER}" test -d "${FORK_TREE}/.git" 2>/dev/null \
      || { echo "ERROR: ${FORK_TREE}/.git not found in container ${FORK_DOCKER} (is it started?)." >&2; exit 1; }
    # Avoid 'dubious ownership' when the tree is owned by a build user but exec'd as root.
    docker exec "${FORK_DOCKER}" git config --global --add safe.directory "${FORK_TREE}" 2>/dev/null || true
  else
    [[ -d "${FORK_TREE}/.git" ]] || { echo "ERROR: ${FORK_TREE} is not a git tree (use FORK_DOCKER if it's in a container)." >&2; exit 1; }
  fi
  fork_git cat-file -e "${FORK_BASE}^{commit}" 2>/dev/null || { echo "ERROR: FORK_BASE=${FORK_BASE} not a commit in the fork tree." >&2; exit 1; }
  fork_git cat-file -e "${FORK_HEAD}^{commit}" 2>/dev/null || { echo "ERROR: FORK_HEAD=${FORK_HEAD} not a commit in the fork tree." >&2; exit 1; }
}

clone_upstream() {
  [[ -e "${WORKDIR}" ]] && { echo "ERROR: ${WORKDIR} exists; remove it or set WORKDIR." >&2; exit 1; }
  echo ">> Cloning ${UPSTREAM_URL} @ ${BASE_TAG} (shallow) -> ${WORKDIR}"
  git clone --depth 1 --branch "${BASE_TAG}" "${UPSTREAM_URL}" "${WORKDIR}"
  git -C "${WORKDIR}" checkout -b "${FORK_BRANCH}" >/dev/null
}

build_series() {
  preflight_fork
  clone_upstream

  echo ">> Overlaying fork import tree (${FORK_BASE}) onto pristine ${BASE_TAG}"
  # Detect upstream files the fork removed (git archive overlay can't express deletions).
  comm -23 \
    <(git -C "${WORKDIR}" ls-files | sort) \
    <(fork_archive "${FORK_BASE}" | tar -tf - | sed 's#/$##' | sort) \
    > /tmp/etk-gtk-deleted.$$ || true
  if [[ -s /tmp/etk-gtk-deleted.$$ ]]; then
    echo "   WARNING: fork import appears to DELETE these upstream files; overlay won't capture that:" >&2
    sed 's/^/     - /' /tmp/etk-gtk-deleted.$$ >&2
    echo "   Handle manually if any are real (gears are normally additive)." >&2
  fi
  rm -f /tmp/etk-gtk-deleted.$$

  fork_archive "${FORK_BASE}" | tar -x -C "${WORKDIR}"

  # Strip dev-only cruft (backup copies, *.pyc) so it never enters the public series.
  if [[ -n "${FORK_EXCLUDES}" ]]; then
    local pruned=0 g
    for g in ${FORK_EXCLUDES}; do
      while IFS= read -r -d '' p; do rm -rf "$p"; pruned=$((pruned+1)); done \
        < <(find "${WORKDIR}" -depth -name "$g" -not -path '*/.git/*' -print0)
    done
    echo ">> Pruned ${pruned} dev-only cruft path(s) matching: ${FORK_EXCLUDES}"
  fi

  # Revert local-workflow files to upstream so they stay out of the public series.
  if [[ -n "${FORK_RESTORE}" ]]; then
    local f
    for f in ${FORK_RESTORE}; do
      if git -C "${WORKDIR}" cat-file -e "${BASE_TAG}:${f}" 2>/dev/null; then
        git -C "${WORKDIR}" checkout "${BASE_TAG}" -- "${f}"
        echo ">> Restored upstream ${f}"
      fi
    done
  fi

  git -C "${WORKDIR}" add -A
  git -C "${WORKDIR}" commit -q -m "${IMPORT_MSG}"

  echo ">> Applying on-top commits ${FORK_BASE}..${FORK_HEAD} (the Patch #3 series)"
  local tmp; tmp="$(mktemp -d)"
  if [[ -n "${FORK_DOCKER}" ]]; then
    local ctmp="/tmp/etk-gtk-onetop.$$"
    fork_git format-patch --output-directory "${ctmp}" --zero-commit --no-signature "${FORK_BASE}..${FORK_HEAD}"
    docker cp "${FORK_DOCKER}:${ctmp}/." "${tmp}/"
    docker exec "${FORK_DOCKER}" rm -rf "${ctmp}"
  else
    fork_git format-patch --output-directory "${tmp}" --zero-commit --no-signature "${FORK_BASE}..${FORK_HEAD}"
  fi
  if ls "${tmp}"/*.patch >/dev/null 2>&1; then
    git -C "${WORKDIR}" am --keep-non-patch "${tmp}"/*.patch
  else
    echo "   (no on-top commits in range — import tree already == HEAD)"
  fi
  rm -rf "${tmp}"

  echo ">> Writing complete series to ${PATCH_DIR}"
  mkdir -p "${PATCH_DIR}"
  rm -f "${PATCH_DIR}"/*.patch 2>/dev/null || true
  git -C "${WORKDIR}" format-patch --output-directory "${PATCH_DIR}" --zero-commit "${BASE_TAG}..${FORK_BRANCH}"

  echo
  echo ">> Done. Fork delta over ${BASE_TAG}:"
  git -C "${WORKDIR}" --no-pager log --oneline "${BASE_TAG}..${FORK_BRANCH}"
  echo
  echo "   Patches written: $(ls -1 "${PATCH_DIR}"/*.patch | wc -l | tr -d ' ')  (commit ./patches/ to this repo)"
  echo "   Built checkout : ${WORKDIR}  (build per BUILDING.md)"
}

apply_series() {
  ls "${PATCH_DIR}"/*.patch >/dev/null 2>&1 || { echo "ERROR: no patches in ${PATCH_DIR}; run '$0 build' first." >&2; exit 1; }
  clone_upstream
  echo ">> Applying committed series from ${PATCH_DIR}"
  git -C "${WORKDIR}" am --keep-non-patch "${PATCH_DIR}"/*.patch
  echo
  echo ">> Done. Fork delta over ${BASE_TAG}:"
  git -C "${WORKDIR}" --no-pager log --oneline "${BASE_TAG}..${FORK_BRANCH}"
  echo "   Built checkout: ${WORKDIR}  (build per BUILDING.md)"
}

case "${1:-}" in
  build) build_series ;;
  apply) apply_series ;;
  *)     usage; exit 1 ;;
esac
