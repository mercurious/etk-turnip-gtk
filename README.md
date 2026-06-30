# ETK Turnip — GTK fork (Mesa 26.1.3, Adreno 650 / SM8250)

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
> Base: tag **`mesa-26.1.3`** (freedesktop GitLab — `gitlab.freedesktop.org/mesa/mesa`).
> Upstream is the canonical source; this is a downstream patch series carried on top of that tag.
> Target backend: `freedreno` / `msm` (Linux KMS), glibc ABI — **not** the Android `bionic`/KGSL build.

This is **not** a GitHub fork-network fork. Mesa's canonical home is freedesktop GitLab, not
GitHub, so the GitHub "Fork" relationship is not available. This is a standalone repository that
declares its lineage here and carries its changes as discrete commits over the `mesa-26.1.3` tag,
so `git log mesa-26.1.3..` shows exactly the delta. See [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh).

---

## What this adds

The fork grafts a set of opt-in **TU_DEBUG gears** at a single emit site
(`tu6_emit_flushes()` in `src/freedreno/vulkan/tu_cmd_buffer.cc`) — lightweight depth-cache
serialization barriers that reduce GPU-hang frequency on GPU-bound scenes without the cost of a
full wait-for-idle.

- The optimal load-bearing gear is **`syncdraw`** (`WAIT_MEM_WRITES | CCU_CLEAN_DEPTH | WAIT_FOR_ME`).
- Several heavier/lighter and alternative-mechanism gears were tried and **falsified** — the
  decision log is preserved in [`PATCHES.md`](PATCHES.md) and [`GEARS.md`](GEARS.md) precisely so
  the negative results aren't re-walked.

See [`GEARS.md`](GEARS.md) for the full flag semantics and [`VALIDATION.md`](VALIDATION.md) for the
reproducible A/B protocol behind the numbers.

## What it does *not* do

The mitigated fault has a **root cause that remains unresolved** — an upstream 3D draw whose
fragment shader fails to retire on this GPU, after which the command processor wedges at the next
wait and hangcheck reaps it. `sddepth` is a **mitigation, not a cure**: it lowers hang frequency
(~50–67% in the measured workload) but residual hangs remain in low-RAM / high-resolution contexts.
The full fault decode is in [`PATCHES.md`](PATCHES.md).

---

## Repository map

| File | What it is |
|------|-----------|
| [`BUILDING.md`](BUILDING.md) | Reproducible ROCKNIX (glibc/`msm`) build — meson/ninja, cross-compile container, incremental iterate loop |
| [`GEARS.md`](GEARS.md) | `TU_DEBUG` gear semantics, what each barrier emits, default recommendation |
| [`PATCHES.md`](PATCHES.md) | The patch iterations with A/B verdicts (what was kept, what was falsified, and why) |
| [`VALIDATION.md`](VALIDATION.md) | Reproducible test protocol (saturated-vault A/B, cold-boot gate, jitter metric) |
| [`LICENSE.md`](LICENSE.md) | Licensing & attribution — upstream license files and per-file headers govern |
| [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh) | Produce a clean `mesa-26.1.3`-based branch with the fork patches on top |

---

## Relationship to upstream

The gears are deliberately minimal and confined to one emit site so they remain **upstreamable**
as a freedreno merge request once a culprit is confirmed. This repo is the interim public source;
the end-state for any genuinely upstream-worthy change is a merge request on freedesktop GitLab.
