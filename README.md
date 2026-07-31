# ETK Turnip — GTK fork (Mesa 26.1.6, Adreno 650 / SM8250)

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
> Base: tag **`mesa-26.1.6`** (freedesktop GitLab — `gitlab.freedesktop.org/mesa/mesa`),
> rebased from `mesa-26.1.3` on 2026-07-30.
> Upstream is the canonical source; this is a downstream patch series carried on top of that tag.
> Target backend: `freedreno` / `msm` (Linux KMS), glibc ABI — **not** the Android `bionic`/KGSL build.

This is **not** a GitHub fork-network fork. Mesa's canonical home is freedesktop GitLab, not
GitHub, so the GitHub "Fork" relationship is not available. This is a standalone repository that
declares its lineage here and carries its changes as discrete commits over the base tag,
so `git log mesa-26.1.6..` shows exactly the delta. See [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh).

The series is base-agnostic and verified to apply with zero fuzz to `mesa-26.1.3`, `mesa-26.1.6` and
`mesa-26.2.0-rc3`, so the same patches build a **stable** or a **pre-release** driver — which is what
lets the ETK Pitstop DRIVER tab A/B one against the other:

```bash
./scripts/prepare-fork-branch.sh apply                                   # stable  (mesa-26.1.6)
BASE_TAG=mesa-26.2.0-rc3 FORK_BRANCH=etk-gtk-26.2 ./scripts/prepare-fork-branch.sh apply
```

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
