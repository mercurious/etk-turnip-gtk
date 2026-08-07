# patches/

The complete ETK GTK fork delta, as a `git am`-able series. Apply onto a fresh upstream clone with
[`../scripts/prepare-fork-branch.sh apply`](../scripts/prepare-fork-branch.sh) (no build container
required).

## Layout

| Path | What it is |
|------|-----------|
| `*.patch` | The **fork series** — base-agnostic. Measured 2026-08-07: applies **8/8 zero fuzz** to `mesa-26.2.0` and `mesa-26.1.6`, and **7/8** to main @ `e40d93a` with `SKIP_PATCHES='0002-*'` (0002's context was refactored away upstream; its gears stay registered-but-inert). Deliberately *not* duplicated per base — split it only when it actually has to diverge. |
| `backports/<line>/` | **Upstream commits** pulled back to an older base. Base-specific by nature. |

`backports/26.1/` carries two turnip commits that ship in 26.2 but were never backported to 26.1.x.
26.2 and newer contain both natively — no backport dir is needed there, and the script
treats an absent/empty backport set as a no-op rather than an error.

## Fork series

> **Registration is decoupled.** Every fork gear is declared once in
> `src/freedreno/vulkan/tu_etk_gears.h` (added by patch 0001) and reaches the upstream files through
> three macros, each a single-line insertion anchored at the *opening* of its construct. **No patch
> after 0001 touches `tu_util.{h,cc}`**, so a gear can be dropped on a base where it doesn't apply
> without breaking the rest of the series. ETK bits allocate from 63 downward (`ETK_GEAR_BIT`) while
> upstream counts up from 0 — see [`../PATCHES.md`](../PATCHES.md) for the collision that motivated
> this.

| Patch | What it is | Status |
|-------|-----------|--------|
| `0001-ETK-GTK-gears-…` | The gear registry (`tu_etk_gears.h`) plus the LSD FPS-recovery gears: `sddepth`/`sdmem`/`sdme` depth-cache barriers + `dimlog`, in `tu_cmd_buffer.cc` + `tu_util.{cc,h}`. Squashed, because the source tree imported them as one commit with no stock baseline between. | **Kept** (default-off; FPS levers — `syncdraw` owns stability) |
| `0002-Patch-3-B-ccuhalf-ccuquarter-…` | Cap a6xx depth CCU cache size. | Falsified; dropped via `SKIP_PATCHES='0002-*'` on bases where upstream's `depth_cache_fraction` rework removed its context (main/devel) — registered but inert there |
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
>
> **Hand-curated context, survives only until a `build` regeneration:** 0006's include hunk was
> re-anchored on 2026-08-07 (insert `util/u_debug.h` *before* `util/os_time.h`, one trailing context
> line) so the one series applies to 26.1.6, 26.2.0 **and** current main — main had added
> `util/ralloc.h` after `os_time.h`, breaking the original trailing context. A future `build` run
> regenerates 26.1.3-era context and must re-apply this re-anchor (or the devel apply breaks again).
