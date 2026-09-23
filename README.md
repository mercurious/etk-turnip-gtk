# ETK Turnip — GTK fork (Mesa 26.2.1, Adreno 650 / SM8250)

A small, validated downstream patch set on top of [Mesa](https://gitlab.freedesktop.org/mesa/mesa)
Turnip (the open-source Vulkan driver for Qualcomm Adreno GPUs), built for **glibc/ROCKNIX**
on the Snapdragon 8 Gen 2 / Adreno 650 class (Retroid Pocket Flip 2) and tuned against
PS3 emulation workloads (RPCS3).

This repository exists to **publish the source and reproduce the build** — it is a development
and tuning record, not a driver-distribution channel. Build from source against your own Mesa
checkout using the steps in [`BUILDING.md`](BUILDING.md).

---

## Lineage (downstream fork)

> **Downstream fork of Mesa.**
> Base: tag **`mesa-26.2.3`** (freedesktop GitLab — `gitlab.freedesktop.org/mesa/mesa`),
> rebased `mesa-26.1.3` → `mesa-26.1.6` (2026-07-30) → `mesa-26.2.0` (2026-08-07) →
> `mesa-26.2.1` (2026-08-21) → `mesa-26.2.2` (2026-09-02) → `mesa-26.2.3` (2026-09-23).
> Upstream is the canonical source; this is a downstream patch series carried on top of that tag.
> Target backend: `freedreno` / `msm` (Linux KMS), glibc ABI — **not** the Android `bionic`/KGSL build.

This is **not** a GitHub fork-network fork. Mesa's canonical home is freedesktop GitLab, not
GitHub, so the GitHub "Fork" relationship is not available. This is a standalone repository that
declares its lineage here and carries its changes as discrete commits over the base tag,
so `git log mesa-26.2.3..` shows exactly the delta. See [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh).

The series is base-agnostic, so the same patches build every track the ETK Pitstop DRIVER tab
holds side by side. Three tracks are offered (measured apply state on 2026-09-23):

```bash
# STABLE — mesa-26.2.3 (released 2026-09-16; ~10 of its 85 commits touch turnip, three of
# them query availability — atomic read of slot->available, CP-write flush after
# CmdCopyQueryPoolResults, WAIT_MEM_WRITES before an XFB query posts — the sync family
# patch 0006 lives in): 8/8, zero fuzz
./scripts/prepare-fork-branch.sh apply

# FALLBACK STABLE — mesa-26.1.6: 8/8, zero fuzz. The 26.1 series is EOL upstream,
# so this track is frozen as-is.
BASE_TAG=mesa-26.1.6 ./scripts/prepare-fork-branch.sh apply

# PRE-RELEASE — 26.3.0-devel pinned by sha off upstream main: 5/8. 0002 skipped since
# upstream's depth_cache_fraction rework removed its context; 0003/0004 skipped since
# main @ df96a4da (2026-08-28) renamed rp.gmem_disable_reason -> force_render_mode_reason,
# the field dsbypass/dsany write. All three are dead gears (PATCHES.md): they stay
# registered in tu_etk_gears.h and are inert. Pin by SHA, never by branch name — "main"
# is a position, not a version — and carry the pin DATE in the tree name (the DRIVER
# tab sorts lexically, so dated names list chronologically).
MAIN_SHA=$(git ls-remote https://gitlab.freedesktop.org/mesa/mesa.git refs/heads/main | cut -f1)
BASE_TAG=$MAIN_SHA SKIP_PATCHES='0002-* 0003-* 0004-*' \
  WORKDIR=$PWD/mesa-fork-26.3.0-devel-$(date +%Y%m%d)-${MAIN_SHA:0:7} ./scripts/prepare-fork-branch.sh apply
```

When upstream cuts `mesa-26.3.0-rc1` (scheduled 2026-10-14) the rc track slots into the same
mechanism: `BASE_TAG=mesa-26.3.0-rc1 ./scripts/prepare-fork-branch.sh apply`.

---

## What this adds

**Stability is owned by the stock `syncdraw` dial, not by this fork.** On these GT titles the
best-tested, preferred stability setting is upstream Turnip's `syncdraw` (a `CP_WAIT_FOR_IDLE` after
every draw) — the accepted stability floor. This fork does not improve on it for crash-avoidance.

What the fork adds is a set of opt-in, lighter **TU_DEBUG gears** at a single emit site
(`tu6_emit_flushes()` in `src/freedreno/vulkan/tu_cmd_buffer.cc`) whose purpose is **FPS recovery**:
they trade some of `syncdraw`'s full per-draw serialization back for framerate in GPU-bound scenes.
They are `TU_DEBUG`-gated and **default-off** — selecting one is a deliberate FPS-vs-stability trade.

- The lighter gears are `sddepth` / `sdmem` / `sdme` (composed from
  `WAIT_MEM_WRITES | CCU_CLEAN_DEPTH | WAIT_FOR_ME`). Going lighter than `sddepth` collapses
  stability (the depth-cache clean is what holds it together); `sddepth` is the most stable of the
  lighter gears **but is more crash-prone than `syncdraw`**.
- Several alternative-mechanism gears (cache-sizing, sysmem routing) were tried and **falsified** —
  the decision log is preserved in [`PATCHES.md`](PATCHES.md) and [`GEARS.md`](GEARS.md) precisely so
  the negative results aren't re-walked.

Since the 26.1.6 rebase the fork also carries a **`zlatez`** gear on a different axis. Every gear
above is a *resolve* mechanism, and every alternative one falsified; `zlatez` is the first that
isn't. Mesa 26.2 added an a6xx workaround whose in-tree comment reads *"A630/A650 hangs with this
combination of states"* — `EARLY_Z_LATE_Z` + a depth/stencil format + a killing fragment shader.
That names this GPU and is a **fragment-stage** wedge, matching the decoded root cause. It is gated
to D32S8 upstream and the ETK target is Z24S8, so `zlatez` widens that gate. It is **built and
unvalidated** — the open experiment, with a `dimlog` probe to falsify it cheaply first.

See [`GEARS.md`](GEARS.md) for the full flag semantics and [`VALIDATION.md`](VALIDATION.md) for the
A/B protocol.

## What it does *not* do

It does **not** cure the underlying hang. The fault's root cause remains unresolved — an upstream 3D
draw whose fragment shader fails to retire on this GPU, after which the command processor wedges at
the next wait and hangcheck reaps it. The hang is **managed** (via `syncdraw`), not fixed, and none
of the fork's lighter gears beat `syncdraw` on stability. The full fault decode is in
[`PATCHES.md`](PATCHES.md).

---

## Repository map

| File | What it is |
|------|-----------|
| [`BUILDING.md`](BUILDING.md) | Reproducible ROCKNIX (glibc/`msm`) build — meson/ninja, cross-compile container, incremental iterate loop |
| [`GEARS.md`](GEARS.md) | `TU_DEBUG` gear semantics, what each barrier emits, default recommendation |
| [`PATCHES.md`](PATCHES.md) | The patch iterations with A/B verdicts (what was kept, what was falsified, and why) |
| [`VALIDATION.md`](VALIDATION.md) | Reproducible test protocol (saturated-vault A/B, cold-boot gate, jitter metric) |
| [`LICENSE.md`](LICENSE.md) | Licensing & attribution — upstream license files and per-file headers govern |
| [`patches/README.md`](patches/README.md) | Patch-series layout: base-agnostic fork series vs. per-line upstream backports |
| [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh) | Produce a clean branch on any upstream ref (release tag, rc, branch, `main`) with the backports + fork patches on top |

---

## Relationship to upstream

The gears are deliberately minimal and confined to one emit site so they remain **upstreamable**
as a freedreno merge request once a culprit is confirmed. This repo is the interim public source;
the end-state for any genuinely upstream-worthy change is a merge request on freedesktop GitLab.
