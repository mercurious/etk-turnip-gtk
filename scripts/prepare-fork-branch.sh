#!/usr/bin/env bash
#
# prepare-fork-branch.sh
#
# Produce a clean, auditable fork branch: a fresh checkout of upstream Mesa at some
# base ref with the ETK GTK patch series applied as discrete commits on top. The
# result is a tree where `git log <base>..` shows exactly the fork delta, and
# upstream's license files and per-file SPDX headers are carried verbatim.
#
# The base ref is anything git can clone --branch: a release tag (mesa-26.1.6), a
# release-candidate tag (mesa-26.2.0-rc3), a stable branch (26.2), or main. That is
# what lets ETK Pitstop hold stable and pre-release drivers side by side.
#
# Two kinds of patch live under ./patches/:
#
#   patches/*.patch              the fork series — base-agnostic. Measured 2026-08-21:
#                                8/8 zero fuzz on mesa-26.2.1 (also 26.2.0/26.1.6 on
#                                2026-08-07); 7/8 on main @ d2e56df (SKIP_PATCHES='0002-*'
#                                — upstream refactored 0002's context away; still true at
#                                this pin). Deliberately NOT duplicated per base; split it
#                                only when it actually has to diverge.
#   patches/backports/<line>/    upstream commits pulled back to an older base.
#                                Base-specific by nature: 26.1/ carries two turnip
#                                commits that 26.2 already contains natively, so
#                                26.2/ is empty and that is the correct state.
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
BASE_TAG="${BASE_TAG:-mesa-26.2.1}"
WORKDIR_EXPLICIT="${WORKDIR:+1}"
WORKDIR="${WORKDIR:-$(pwd)/mesa-fork-${BASE_TAG}}"
PATCH_DIR="${PATCH_DIR:-$(cd "$(dirname "$0")/.." && pwd)/patches}"

# Release line derived from the base ref, used to pick the backport set:
#   mesa-26.1.6 -> 26.1   mesa-26.2.0-rc3 -> 26.2   26.2 -> 26.2   main -> main
# A raw commit sha has no line to derive, so it falls to "main" — which is
# correct: a devel-branch pin needs no backports, it already carries everything.
if [[ -z "${BASE_LINE:-}" && "${BASE_TAG}" =~ ^[0-9a-f]{7,40}$ ]]; then
  BASE_LINE="main"
fi
BASE_LINE="${BASE_LINE:-$(printf '%s' "${BASE_TAG}" | sed -E 's/^mesa-//; s/^([0-9]+\.[0-9]+).*/\1/')}"
BACKPORT_DIR="${BACKPORT_DIR:-${PATCH_DIR}/backports/${BASE_LINE}}"

# Fork branch defaults to the line it sits on (etk-gtk-26.2; a sha pin — line
# "main" — becomes etk-gtk-devel). The old static default `etk-gtk` matched no
# checkout ever actually produced; every invocation overrode it.
FORK_BRANCH="${FORK_BRANCH:-etk-gtk-$([[ "${BASE_LINE}" == main ]] && echo devel || echo "${BASE_LINE}")}"

# Patches to withhold from `apply`: space-separated basename globs, e.g.
# SKIP_PATCHES='0002-*'. For a base where upstream refactored the code out from
# under a falsified patch (0002 vs the depth_cache_fraction rework), skipping is
# the supported path: the gears stay REGISTERED via patch 0001's tu_etk_gears.h
# registry and are simply inert with no implementation behind them — the
# decoupling (d6970b9) exists for exactly this.
SKIP_PATCHES="${SKIP_PATCHES:-}"

# Moving refs (branches like 26.2 or main) are meant to be re-pulled. Set REUSE=1 to
# fetch+reset an existing WORKDIR in place instead of refusing to touch it.
REUSE="${REUSE:-0}"

# `build` mode overlays a FULL source tree captured from the build container. That
# tree is a snapshot of one specific upstream base, so overlaying it onto any other
# base would silently revert every upstream change in between. Pinned separately.
BUILD_BASE_TAG="${BUILD_BASE_TAG:-mesa-26.1.3}"

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
          Pinned to BUILD_BASE_TAG=${BUILD_BASE_TAG} (see note in the header).
          In-container:  FORK_DOCKER=turnip-rocknix FORK_TREE=/work/mesa-26.1.3 $0 build
          On host:       FORK_TREE=/path/to/mesa-26.1.3 $0 build

  apply   Reproduce the fork checkout from committed ./patches/ onto a fresh upstream
          ${BASE_TAG} clone. Needs only network.

          Stable:      $0 apply
          Fallback:    BASE_TAG=mesa-26.1.6 $0 apply
          Branch tip:  BASE_TAG=26.2 REUSE=1 $0 apply
          Devel pin:   BASE_TAG=<40-hex-sha> SKIP_PATCHES='0002-*' $0 apply
                       (pin main by SHA, never by branch name — "main" is a
                        position, not a version, so a branch-tracked build
                        cannot be identified after the fact; 0002 no longer
                        applies past upstream's depth_cache_fraction rework)
          RC track:    BASE_TAG=mesa-26.3.0-rc1 $0 apply
                       (when upstream cuts it — scheduled 2026-10-14)

Current base : ${BASE_TAG}  (line ${BASE_LINE})
Backports    : ${BACKPORT_DIR}
Fork series  : ${PATCH_DIR}

Overrides: UPSTREAM_URL BASE_TAG BASE_LINE BACKPORT_DIR FORK_BRANCH WORKDIR PATCH_DIR
           SKIP_PATCHES REUSE BUILD_BASE_TAG FORK_TREE FORK_DOCKER FORK_BASE FORK_HEAD IMPORT_MSG
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
  if [[ -e "${WORKDIR}" ]]; then
    if [[ "${REUSE}" != "1" ]]; then
      echo "ERROR: ${WORKDIR} exists; remove it, set WORKDIR, or pass REUSE=1 to re-pull." >&2
      exit 1
    fi
    echo ">> Re-pulling ${BASE_TAG} into existing ${WORKDIR} (REUSE=1)"
    git -C "${WORKDIR}" fetch --depth 1 origin "${BASE_TAG}"
    # Drop any previous run's fork branch so the series never applies twice.
    # -f because a re-pull must not be blocked by local edits: this WORKDIR is a
    # disposable build checkout reproduced from ./patches/, so anything dirty in
    # it is scratch by definition. Without -f, `checkout --detach` aborts on a
    # modified tracked file and the whole re-apply fails.
    git -C "${WORKDIR}" checkout -q -f --detach FETCH_HEAD
    git -C "${WORKDIR}" branch -D "${FORK_BRANCH}" 2>/dev/null || true
    git -C "${WORKDIR}" reset -q --hard FETCH_HEAD
    # Preserve meson/ninja build trees: they are untracked, so a bare
    # `clean -fdx` deletes them and turns every re-pull into a full rebuild
    # (~700 objects). Everything else untracked still goes.
    git -C "${WORKDIR}" clean -qfdx -e 'build*'
  elif [[ "${BASE_TAG}" =~ ^[0-9a-f]{7,40}$ ]]; then
    # Commit-sha base. `git clone --branch` takes a tag or a branch name and
    # will reject a raw sha, so pin by fetching the object directly.
    #
    # This exists because `main` is a POSITION, not a version: two builds a week
    # apart both call themselves 26.3.0-devel and are different drivers. Tracking
    # the branch would put a name in the ledger that cannot identify what ran,
    # defeating the whole point of stack attribution. Devel-branch builds must
    # be pinned.
    echo ">> Pinning ${UPSTREAM_URL} @ commit ${BASE_TAG} -> ${WORKDIR}"
    git init -q "${WORKDIR}"
    git -C "${WORKDIR}" remote add origin "${UPSTREAM_URL}"
    # Needs the server to allow fetching a non-tip object (GitLab does).
    git -C "${WORKDIR}" fetch -q --depth 1 origin "${BASE_TAG}" \
      || { echo "ERROR: could not fetch commit ${BASE_TAG} (server may not allow sha fetch)." >&2; exit 1; }
    git -C "${WORKDIR}" checkout -q --detach FETCH_HEAD
  else
    echo ">> Cloning ${UPSTREAM_URL} @ ${BASE_TAG} (shallow) -> ${WORKDIR}"
    git clone --depth 1 --branch "${BASE_TAG}" "${UPSTREAM_URL}" "${WORKDIR}"
  fi
  # Record the base commit by sha: a branch base (26.2, main) has no local ref to
  # diff against after we branch off it, so `${BASE_TAG}..` would not resolve.
  BASE_SHA="$(git -C "${WORKDIR}" rev-parse HEAD)"
  git -C "${WORKDIR}" checkout -b "${FORK_BRANCH}" >/dev/null
}

# Apply the base-specific upstream backports, if this line has any. Newer bases that
# already contain the commits natively have an empty dir -- that is expected, not an
# error, so an absent/empty backport set is silently a no-op.
apply_backports() {
  if ! ls "${BACKPORT_DIR}"/*.patch >/dev/null 2>&1; then
    echo ">> No backports for line ${BASE_LINE} (${BACKPORT_DIR}) — base carries them natively"
    return 0
  fi
  echo ">> Applying upstream backports for line ${BASE_LINE}"
  git -C "${WORKDIR}" am --keep-non-patch "${BACKPORT_DIR}"/*.patch
  ls -1 "${BACKPORT_DIR}"/*.patch | sed 's#.*/#     - #'
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

  # Only the fork series is authored here. Upstream backports are curated artifacts
  # downloaded from GitLab into patches/backports/<line>/, not regenerated from this
  # tree -- and the `rm` glob is non-recursive on purpose so it leaves them alone.
  echo ">> Writing complete series to ${PATCH_DIR}"
  mkdir -p "${PATCH_DIR}"
  rm -f "${PATCH_DIR}"/*.patch 2>/dev/null || true
  git -C "${WORKDIR}" format-patch --output-directory "${PATCH_DIR}" --zero-commit "${BASE_SHA}..${FORK_BRANCH}"

  echo
  echo ">> Done. Fork delta over ${BASE_TAG}:"
  git -C "${WORKDIR}" --no-pager log --oneline "${BASE_SHA}..${FORK_BRANCH}"
  echo
  echo "   Patches written: $(ls -1 "${PATCH_DIR}"/*.patch | wc -l | tr -d ' ')  (commit ./patches/ to this repo)"
  echo "   Built checkout : ${WORKDIR}  (build per BUILDING.md)"
}

apply_series() {
  ls "${PATCH_DIR}"/*.patch >/dev/null 2>&1 || { echo "ERROR: no patches in ${PATCH_DIR}; run '$0 build' first." >&2; exit 1; }
  clone_upstream
  apply_backports
  echo ">> Applying committed fork series from ${PATCH_DIR}"
  local series=() p b g skip
  for p in "${PATCH_DIR}"/*.patch; do
    b="$(basename "$p")" skip=0
    for g in ${SKIP_PATCHES}; do
      # shellcheck disable=SC2254  # unquoted on purpose: $g is a glob
      case "$b" in $g) skip=1 ;; esac
    done
    if [[ "${skip}" == 1 ]]; then
      echo "   >> SKIPPING ${b} (SKIP_PATCHES) — its gears stay registered but inert"
    else
      series+=("$p")
    fi
  done
  [[ ${#series[@]} -gt 0 ]] || { echo "ERROR: SKIP_PATCHES filtered out the entire series." >&2; exit 1; }
  git -C "${WORKDIR}" am --keep-non-patch "${series[@]}"
  echo
  echo ">> Done. Delta over ${BASE_TAG} (${BASE_SHA:0:10}):"
  git -C "${WORKDIR}" --no-pager log --oneline "${BASE_SHA}..${FORK_BRANCH}"
  echo
  echo "   Built checkout: ${WORKDIR}  (build per BUILDING.md)"
}

case "${1:-}" in
  build)
    # The overlay is a FULL source tree snapshotted at BUILD_BASE_TAG. Overlaying it
    # onto any newer base would revert every upstream change in between, silently and
    # invisibly (git archive can express additions, not the deletions that implies).
    # So build mode is pinned to the tree's own base regardless of BASE_TAG.
    if [[ "${BASE_TAG}" != "${BUILD_BASE_TAG}" ]]; then
      echo ">> build mode: pinning BASE_TAG ${BASE_TAG} -> ${BUILD_BASE_TAG} (overlay tree's own base)"
      BASE_TAG="${BUILD_BASE_TAG}"
      [[ -n "${WORKDIR_EXPLICIT}" ]] || WORKDIR="$(pwd)/mesa-fork-${BASE_TAG}"
    fi
    build_series ;;
  apply) apply_series ;;
  *)     usage; exit 1 ;;
esac
