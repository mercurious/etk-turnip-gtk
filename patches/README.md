# patches/

The complete ETK GTK fork delta, as a `git am`-able series. Apply onto a fresh upstream clone with
[`../scripts/prepare-fork-branch.sh apply`](../scripts/prepare-fork-branch.sh) (no build container
required).

## Layout

| Path | What it is |
|------|-----------|
| `*.patch` | The **fork series** — base-agnostic. Verified to apply with zero fuzz to `mesa-26.1.3`, `mesa-26.1.6` and `mesa-26.2.0-rc3`, so it is deliberately *not* duplicated per base. Split it only when it actually has to diverge. |
| `backports/<line>/` | **Upstream commits** pulled back to an older base. Base-specific by nature. |

`backports/26.1/` carries two turnip commits that ship in 26.2 but were never backported to 26.1.x.
`backports/26.2/` is **empty, and that is correct** — 26.2 contains both natively, and the script
treats an empty backport set as a no-op rather than an error.

## Fork series

| Patch | What it is | Status |
|-------|-----------|--------|
| `0001-ETK-GTK-gears-…` | The LSD FPS-recovery gears: `sddepth`/`sdmem`/`sdme` depth-cache barriers + `dimlog`, in `tu_cmd_buffer.cc` + `tu_util.{cc,h}`. Squashed, because the source tree imported them as one commit with no stock baseline between. | **Kept** (default-off; FPS levers — `syncdraw` owns stability) |
| `0002-Patch-3-B-ccuhalf-ccuquarter-…` | Cap a6xx depth CCU cache size. | Falsified |
| `0003-Patch-3-A-dsbypass-…` | Selective sysmem for depth-storing renderpasses. | Falsified |
| `0004-Refined-A-dsany-…` | Route any depth-attachment renderpass to sysmem. | Falsified |
| `0005-t3devlost-…` | Device-loss detection via per-object staleness (`vk_fence` + `tu_query_pool`). | **Kept** — field-validated |
| `0006-KGSL-parity-query-survive-…` | Forge an available zero instead of device-lost, under the parity kernel. | Built; on-track validation pending |
| `0007-zlatez-…` | Widen upstream's A650 `EARLY_Z_LATE_Z` hang workaround past its D32S8 format gate, plus a `dimlog` reachability probe. | **Built, not yet validated** — the open experiment |
| `0008-Mark-the-fork-in-driverInfo-…` | `driverInfo` reports `Mesa <ver> (git-<sha>) ETK-GTK` so an A/B result is attributable to a build. | **Kept** |

The falsified patches are retained on purpose: they are `TU_DEBUG`-gated and default-off, and the
production `.so` carries all gears so the negative results stay reproducible. The decision log is in
[`../PATCHES.md`](../PATCHES.md).

The series preserves upstream's license files and per-file SPDX (`MIT`) headers unchanged.

## Backports (line 26.1 only)

| Patch | Upstream commit | Why it is here |
|-------|-----------------|----------------|
| `backports/26.1/0001-tu-a6xx-Work-around-D32S8-EARLY_Z_LATE_Z-hang.patch` | `a70d2af590db` | Forces `LATE_Z` for a state combination whose in-tree comment reads *"A630/A650 hangs with this combination of states"*. Same GPU family as this fork, and a fragment-stage wedge. Patch `0007` builds directly on it. |
| `backports/26.1/0002-tu-util-Fix-tile-division-algorithm.patch` | `5000d6644db4` | Intermediate tile-divisor levels were marked initialized without being computed, "leaving their tiling configs full of uninitialized data". The reference fault is a ragged `255×510` depth sub-target, and the divisor only escalates under the GMEM pressure that scene creates. |

> Regenerate the fork series from the build tree with `prepare-fork-branch.sh build` (needs the build
> container). Backports are curated artifacts downloaded from GitLab, not regenerated from that tree —
> `build` mode leaves `backports/` alone.
