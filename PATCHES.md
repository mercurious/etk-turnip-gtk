# Patch history & decision log

The fork is a short series carried over `mesa-26.1.6` (rebased from `mesa-26.1.3` on 2026-07-30).
This file records **what was tried, what was kept, and what was falsified** — the negative results
are part of the deliverable, so the dead ends aren't re-walked by anyone reading the source.

## The fault being mitigated (decoded)

- **GPU:** Adreno 650 (SM8250). Hang status family `00E5xxxx` — several variants observed, same root
  cause.
- **Site in the cmdstream:** `tu6_emit_gmem_stores()` → `tu_store_gmem_attachment()`, the internal
  GMEM depth store-resolve.
- **Trigger:** a ragged depth sub-target (`WINDOW_SCISSOR 255×510`, Z24S8) during a GPU-bound scene
  (reference workload: GT5P HSL-reverse, ~lap 4–5).
- **Root cause:** an **upstream 3D draw whose fragment shader fails to retire** on this GPU. Redump
  decode shows a structurally-normal but divergent FS (≈2021 instructions, ≈97 branches) that the
  GPU wedges on during execution. The command processor then blocks at the next `WAIT`, and
  hangcheck reaps it *there* — which is why the fault first looked like a resolve-sync problem.
  It is not: serialization only **reduces the probability** of hitting the wedge.

This is why every "fix the resolve" mechanism below ultimately falsifies, and why stability is
*managed* with stock `syncdraw` rather than cured. The fork's own gears do not beat `syncdraw` on
stability — their purpose is FPS recovery (see [`GEARS.md`](GEARS.md)).

## Series

### Patch #1 — CCU resolve serialization (FALSIFIED, kept for history)
- **Files:** `src/freedreno/vulkan/tu_cmd_buffer.cc`
- **Change:** forced `WAIT_FOR_IDLE` + `CCU_CLEAN_DEPTH` + `CCU_INVALIDATE` after every GMEM
  store-resolve via `tu6_emit_flushes()`.
- **Verdict:** an early "Gold" result did not survive N=3; the hang persists. Kept as a commit so the
  reasoning is visible.

### Patch #2 — `sddepth` / `sdmem` / `sdme` gears (KEPT — as FPS levers, not a stability win)
- **Files:** `src/freedreno/vulkan/tu_cmd_buffer.cc` (at `tu6_emit_flushes()`), helper defs in
  `tu_util.{h,cc}`.
- **Change:** three opt-in `TU_DEBUG` barrier levels, lighter than `syncdraw` (see [`GEARS.md`](GEARS.md)).
- **Verdict:** these are **FPS-recovery gears, not a stability improvement.** Stock `syncdraw`
  remains the best-tested stability dial; **`sddepth` is more crash-prone than `syncdraw`** in
  extended testing. The solid finding here is *negative*: going lighter than `sddepth`
  (`sdmem`/`sdme`) collapses survival, so the depth-cache clean (`CCU_CLEAN_DEPTH`) is the component
  that keeps a lighter gear from falling apart — but even with it, `sddepth` doesn't reach the
  `syncdraw` floor. Kept because the production `.so` exposes the gears as a deliberate
  FPS-vs-stability trade.

  > A prior write-up credited `sddepth` with a "~50–67% hang reduction" and called it the
  > recommended default. That was a mis-attribution: the +67% duration figure belongs to the
  > **`syncdraw`** tuning campaign, not `sddepth`. Corrected here.

### Patch #3-B — `ccuhalf` / `ccuquarter` (FALSIFIED)
- **Files:** a6xx `DEPTH_CACHE_SIZE` register (`src/freedreno/registers/` / generated regs).
- **Change:** cap the depth CCU cache to HALF or QUARTER.
- **Verdict:** smaller made it **worse** (lap-1 failure vs the lap-4/5 baseline). Do not retry.

### Patch #3-A — `dsbypass` / `dsany` (INCONCLUSIVE → unreachable)
- **Files:** `src/freedreno/vulkan/tu_cmd_buffer.cc` (renderpass resolve routing).
- **Change:** route depth-attachment passes to sysmem instead of GMEM.
- **Verdict:** unreachable for this fault — the boss resolve is an **internal GMEM store**, not a
  renderpass attachment resolve, so the routing change never reaches the faulting path.

## Dead gears — do not re-propose

From the productize verdict: cache-sizing, render-path routing, WFI-at-resolve, `rtalign`,
`nolrz`/`noubwc`, and per-draw discriminators have all been falsified for this fault. No fork gear
cures it; stock `syncdraw` remains the stability floor and the fork's gears are FPS levers on top.

## Redumps (forensic evidence)

Hang redumps backing the decode are banked outside this repo (large binaries). Representative
captures: HSL race (`ib2=0x15D8F8AA4`, sysmem 2D-blit resolve), Save-Game (`CP_BLIT`/`BLIT_OP_SCALE`),
plus gmem/`sddepth` variants used for the truncation-recovery and self-repair flow.

### Patch #5 — `t3devlost` device-loss detection: per-object staleness (VALIDATED 2026-07-05)
- **Files:** `src/vulkan/runtime/vk_fence.{c,h}`, `src/freedreno/vulkan/tu_query_pool.{cc,h}`
  (`patches/0005-...`).
- **The problem it solves:** kernel 7.0.11 recovers an a6xx hang via hangcheck but does NOT
  advance `MSM_PARAM_FAULTS`, and never signals the killed submission's fence — so userspace
  pollers spin forever on an orphan while the recovered GPU keeps servicing everyone else.
  Result historically: a silent multi-minute freeze requiring a manual kill.
- **The design (survived three field falsifications):**
  1. *check_status consults* on the poll paths — necessary but blind to hangcheck-class loss
     (counter never moves): kept, insufficient alone.
  2. *Global dry-spell* (no fence signaling anywhere for >10 s) — **falsified live**: the
     recovered GPU retires healthy neighbor fences (observed: retired-fence advanced 15 past
     the orphan), resetting any global clock forever.
  3. **Per-object staleness (the fix that holds):** each `vk_fence` carries a stamp set on its
     first NOT_READY poll, cleared on every observed signal AND reset — an individual fence
     continuously NOT_READY for >10 s cannot exist on a healthy device → `vk_device_set_lost`.
     Each `tu_query_pool` carries the same stamp for unavailable-without-WAIT polls
     (>30 s, cleared when any query in the pool reads available), applied to **any** poll
     flags — a live register read proved real callers poll with
     `PARTIAL|WITH_AVAILABILITY`, which routes around both the NOT_READY return and any
     flag-gated check.
- **Verdict:** field-validated on live wedges — the driver now answers `VK_ERROR_DEVICE_LOST`
  to every post-hangcheck poll within 10–30 s worst-case (typically instantly via the submit
  path). Pairs with the emulator-side net in
  [etk-rpcs3-gtk](https://github.com/mercurious/etk-rpcs3-gtk) (tguard v1–v6), which turns
  the answer into a ~1 s stop + immediate process exit. NOT a cure for the hang itself —
  see the doctrine at the top: this is tolerance, not avoidance.
- **Note:** ETK builds also carry two diagnostic-only `mesa_logi` lines in
  `tu_knl_drm_msm.cc` (`[ETK T0-checkstatus]` lineage markers); omitted from the series as
  non-functional.

### Patch #6 — `kgsl-parity` query-survive: forge zero instead of device-lost (BUILT; on-track validation pending)
- **Files:** `src/freedreno/vulkan/tu_query_pool.cc` (`patches/0006-...`). Builds on Patch #5.
- **The shift:** Patch #5's philosophy is *tolerance* — answer `VK_ERROR_DEVICE_LOST` so the app
  tears down cleanly (a ~1 s stop). Patch #6 is *parity* — when the paired ROCKNIX-GTK kernel keeps
  the hung context alive (`msm.context_keepalive=1`, which does NOT ban the VM nor bump the fault
  counter), the dropped query can instead be forged: report it AVAILABLE with value 0 (one wrong,
  fully-occluded frame) so the app's poll unparks and the race CONTINUES — matching how Android/KGSL
  absorbs the same hang.
- **The design:** gated by `TU_ETK_QUERY_SURVIVE`, **default ON**, with `TU_ETK_QUERY_SURVIVE=0` as
  the kill-switch back to Patch #5's device-lost.

  > **Default corrected 2026-07-30 — and why it matters beyond this patch.** The default was
  > originally *off* (opt-in for a new mechanism). But the certified `gtk_0.4` driver was built with
  > it flipped **on**, and that flip existed only as an *uncommitted edit in the build tree* — so
  > this published series did not reproduce the shipped driver. A rebuild from these patches
  > silently dropped the survive net, which is exactly what happened to `gtk_0.5`: it went to the
  > track with the net disabled and nobody could have told from the source. The lesson is not about
  > this flag: **anything that only exists as a working-tree edit is not part of the fork.** If the
  > series doesn't rebuild the shipped `.so`, the series is wrong. Both dropped-query verdicts in `get_query_pool_results`
  — the `wait_for_available` WAIT_BIT strike path and the PARTIAL/ZCULL-poke staleness path — get a
  survive branch that forges an available zero result (WITH_AVAILABILITY still reports 1/done).
  Threshold `ETK_SURVIVE_UNAVAIL_NS = 1.5 s` doubles as the "submit was dropped" signal and bounds
  the stutter. Never marks the device lost, so submits keep flowing.
- **Requires the parity kernel** — without `msm.context_keepalive` the forged query is followed by an
  `-EPIPE` on the next submit. This is one half of a kernel+driver pair, not standalone.
- **Verdict (honest):** BUILT, compiles, loads, mechanism-correct; **NOT yet on-track validated.** The
  query-poll wedge (a6xx `00C5xxxx`, GT5P 787B) did not reproduce across a full 2026-07-05 session —
  every boss hit (GT5P HSL, GT HD Concept, London/GT HD EU) was the `00E5xxxx` **fence**-path wedge,
  which this patch does NOT cover: RPCS3 spins `vkGetFenceStatus(timeout=0)` and never reaches the
  query path. Cross-title, the fence poll is the dominant real-play wedge; a fence-path survive (the
  `vk_fence.c` twin of this, plus an emulator-side force-signal) is the next patch.

### Patch #7 — `zlatez` / `zlatezany` z-mode gears (BUILT 2026-07-30; the open experiment)
- **Files:** `src/freedreno/vulkan/tu_cmd_buffer.cc` (`tu6_build_depth_plane_z_mode()`),
  `tu_util.{cc,h}` (`patches/0007-…`). Builds on backport `a70d2af590db`.
- **Why this one is different.** Every mechanism above is a *resolve* mechanism, and every one of
  them falsified. This is the first candidate that is not — it targets the **fragment stage**, which
  is where the decode at the top of this file says the fault actually lives.
- **The upstream evidence.** Mesa 26.2 carries `a70d2af590db`, which forces `A6XX_LATE_Z` for
  `A6XX_EARLY_Z_LATE_Z` + `D32_SFLOAT_S8_UINT` + `fs_kill_fragments`. Its in-tree comment reads
  verbatim: `/* A630/A650 hangs with this combination of states. */`. That names **this fork's GPU**,
  and `fs_kill_fragments` (discard / `gl_SampleMask` write / alpha-to-coverage) means a killing
  fragment shader — matching "an upstream 3D draw whose fragment shader fails to retire". Upstream
  already carries a *second* `EARLY_Z_LATE_Z` wedge workaround immediately above it, so this Z-mode
  is independently known to be hazardous on a6xx.
- **The gap, stated plainly.** The upstream workaround gates on **D32S8**; the ETK reference target
  is **Z24S8**. So it does **not** fire on GT5P as written. The format gate is the only thing
  standing between the two. That is the whole hypothesis.
- **The design:** two default-off `TU_DEBUG` gears that widen the gate — `zlatez` adds
  `D24_UNORM_S8_UINT`, `zlatezany` drops the format condition entirely — plus a `dimlog`-gated
  one-shot probe that fires **with no gear set**, reporting the first time the hazard state is
  reached and in which format. Run the probe first: if the line never appears, the hypothesis is
  falsified for the cost of one session instead of an N≥3 A/B.
- **Verdict:** **FIRST POSITIVE RESULT ON THIS FAULT (2026-07-30).** Matched A/B on `gtk_0.6`,
  GT5P BCUS98158, Class B one-lap High Speed Loop (Integra), res 100, race power, warm, N=3 per arm:

  | | `zlatez` OFF | `zlatez` ON |
  |---|---|---|
  | Outcome | **3/3 `SURVIVED:Adreno`** (`00E59005`) | **3/3 `CLEAN` — race completed, saved, graceful exit** |
  | Rescues | 2, 1, 2 (**5**) | **0, 0, 0** |
  | PERFECT% | 2.4 | **7.1** |
  | LOCK% | 35.5 | 37.9 |
  | Duration | 236, 227, 216 s | 221, 207, 227 s |

  Read the durations carefully: the ON runs are *shorter* and that is the win, not a regression. A
  completed session is race + save + graceful exit; a crashed one just stops. The ON arm did
  strictly more work than the OFF arm managed, so the result is not censored by a fixed stop.

  The **rescue count is the strongest column**: crash/no-crash is one endpoint per run, but rescues
  are events *inside* a run, and they went 5 → 0. That is independent of when a session ended.

  The OFF crashes cluster at 216/227/236 s — a 20 s spread for a fault documented at 77–2886 s.
  That tightness says the wedge is triggered at a specific point in the scene rather than randomly,
  which is why N=3 carries more weight here than the raw noise floor implies.

  **What this does not yet establish:**
  - N=3 per arm (Fisher exact on 3/3 vs 0/3 ≈ p 0.05 — the edge, not the far side of it).
  - **One lap.** The documented reference boss is HSL-*reverse* at ~lap 4–5, a longer workload than
    this. Passing one lap does not show the wedge is eliminated rather than delayed.
  - **One title, and a fragile one.** `BCUS98158` is GT5P **Spec II**, which is exactly the title
    hit by the RPCS3 `CellSpursKernel0` boot fatal described below.

  Next: multi-lap on `gtk_0.6` with the gear on, N≥3, **on a single frozen stack**. If it holds past
  the lap-4/5 boss, the result is conclusive and directly reportable upstream as a widening of
  `a70d2af590db`.

  ### Retracted: the "N=6" extension and the "exposure gradient" (2026-08-01)

  Two follow-on claims were made from sessions after 2026-07-31 09:46. **Both are withdrawn** — they
  were reading a stack that moved underneath the experiment, not the driver.

  - **"N=6, 2/6 vs 6/6, p≈0.03."** Withdrawn. The second half of that pooling ran after the ETK
    RPCS3 fork base-bumped from `v0.0.41-19544` to `v0.0.41-19638-a1deb2921` (commits 07-31
    09:46–09:49), roughly an hour before those sessions. The ON arm's apparent decay from 0/3 to 2/3
    coincides with that bump, not with anything about the gear. Arms that span a base bump are not
    one arm.
  - **"Protection degrades with exposure (0/8 short, 2/6 medium, 2/2 long)."** Withdrawn. Those
    short runs and the cluster of ~3 s `ABORTED` rows fall inside the window where GT5P **Spec II**
    (`BCUS98158`, ISO) hit a deterministic `CellSpursKernel0` boot fatal — upstream RPCS3
    `1d657c4e6` stops registering the SPU reduced-loop pattern, which reroutes an older-SPURS loop
    through SPU LLVM and miscompiles it on ARM64. Bisected over 8 hardware rounds and fixed by a
    temporary revert (`etk-rpcs3-gtk` `c40dcf0`, 08-01 11:44). That was the emulator failing to
    boot, not the driver protecting less well at length.

  **What survives is the 07-30 evening block alone** — six sessions, one sitting, one stack,
  N=3 per arm. That is the table above, and it is still the only clean comparison in the ledger.

  The lesson is the same one Patch #8 encodes for the driver, one layer up: **an A/B is only a
  measurement if every layer under it is pinned.** Stack attribution (`stack=rk…/k…/r…` in the
  ledger's `tune_tag`) exists so this class of error is visible in the data rather than
  reconstructed afterwards from commit timestamps.

- **Separate finding — a 26.1.6 jitter regression, provisional.** Frametime jitter is elevated on
  every 26.1.6 row (`6.5–9.9 ms`) versus every 26.1.3-era row (`3.4–6.0 ms`), and it persists with
  `zlatez` **off**, so it is not the gear. It is *probably* the base bump — but the 26.1.3-era
  comparison rows also predate the RPCS3 base bump, so Turnip and RPCS3 are not separated here
  either. Re-measure on one frozen stack before treating it as a Turnip regression.

- **Probe (2026-07-30, the run that justified the A/B) — the hypothesis survived its
  falsification test.** `gtk_0.5` on the rig, `TU_DEBUG=dimlog`, no z-gear, GT5P (BCUS98158,
  US disc), 440 s to a wedge. The probe fired exactly once, as designed:

  ```
  [ETK zlatez] hazard state reached: EARLY_Z_LATE_Z + fs_kill_fragments,
  depth_format=VK_FORMAT_D24_UNORM_S8_UINT depth_write=1 stencil_write=0
  ```

  The workload **does** enter the state upstream names as wedging A630/A650, and it does so in
  **`D24_UNORM_S8_UINT`** — precisely the format upstream's `D32S8` gate excludes. So:
  - the format gate really is the only thing keeping the upstream workaround off this workload;
  - **`zlatez` is the correct gear; `zlatezany` is not needed** (the format is known now);
  - the gear itself is still **UNVALIDATED** — it was not enabled on this run, by design. The run
    tested reachability, which is the cheap question, before spending an N≥3 A/B on the expensive one.

  The same run also confirmed the hang is unchanged by the 26.1.6 rebase + both backports alone:
  `status 00E59005`, ring 0, offending task `RSX Offloader`, `hangcheck recover!` →
  `context_keepalive: surviving hang`. Ledger `SURVIVED:Adreno / KEEPALIVE_SURVIVE,GPU_FENCE_TIMEOUT`.
  That is the known fence-path wedge, and the exit to ES is the tolerance net behaving correctly,
  not a new failure mode.

  **Do not read that run's FPS** (`fps_med 19.8`, `ft_p99 250 ms`, `jitter 8.2` vs a 26.6/75/2.9
  baseline). Three confounds: `dimlog` wrote **26,924 lines / 2.7 MB in 440 s** (~61 flash writes/s
  — the diagnostic is *not* free), the baseline rows are NPEA00050 while this was BCUS98158, and
  those rows ran `default` dials. Turn `dimlog` off for any perf or stability comparison.

- **Where the driver's log actually goes:** `mesa_logi` writes to **stderr**, which `RPCS3.log` does
  not capture. On the rig, profile.d entry `099-etk-t0probe-log` sets
  `MESA_LOG_FILE=$TELEMETRY_DIR/t0probe.log` — that is the only place `[ETK …]` lines appear.
  Grepping `RPCS3.log` returns zero hits and looks exactly like a negative result. It isn't one.
- **Upstreamability:** because it is a strict widening of an existing upstream workaround rather than
  a new mechanism, a positive result is directly reportable as a freedreno MR.

### Patch #8 — `driverInfo` fork marker (KEPT)
- **Files:** `src/freedreno/vulkan/tu_device.cc` (`patches/0008-…`).
- **The problem:** stock and fork both reported bare `Mesa <version>`, so with several drivers
  selectable through the Pitstop DRIVER tab, an A/B result could not be attributed to a build except
  by `sha256sum` of the bound file. For a project whose entire output is A/B verdicts, that is a
  correctness hazard, not a nicety.
- **The change:** `driverInfo` becomes `Mesa <version> (git-<sha>) ETK-GTK`. The numeric version is
  deliberately left untouched — RPCS3 applies driver-version-keyed workarounds and parses this
  string, so a non-numeric version suffix could change emulator behaviour and confound the very
  comparison this enables.
- **Note:** this existed only as an *uncommitted local edit* in the build tree and was absent from
  the published series — it would have been lost on the first rebase. Carrying it as a patch fixes
  that.

## Rebase 26.1.3 → 26.1.6 (2026-07-30)

**Cost: near zero.** Of the files the series touches, only `tu_cmd_buffer.cc` changed upstream
(+12/−12); `tu_util.{cc,h}`, `tu_query_pool.{cc,h}`, `vk_fence.{c,h}` and `tu_knl_drm_msm.cc` were
byte-identical. The full series applies to both `mesa-26.1.6` and `mesa-26.2.0-rc3` with zero fuzz.

**What 26.1.4/5/6 actually contain for us** (349 commits; most of the turnip delta is inapplicable):

- **On-path:** `tu_pass.cc` "Fix uninitialized `gmem_offset` when a GMEM layout is impossible"
  (26.1.5) — a `continue` that continued the *inner* loop, so offsets were still assigned from a
  partially-computed layout. Same bug family as the tile-division backport. `tu_cs.cc`
  `read_write.start` was not repointed at the BO map on command-stream reset (stale pointer; RPCS3
  resets command buffers every frame). `maxFragmentInputComponents` 124 → 128.
- **Not applicable:** the FDM subsampled-metadata / apron / separate-stencil fixes (need
  `VK_EXT_fragment_density_map`), the `TRANSFORM_FEEDBACK_COUNTER` access-mask fix (no XFB),
  `turnip/kgsl: close the dma-buf fd` (Android/KGSL — this build is `-Dfreedreno-kmds=msm`), A702 and
  a7xx-only fixes, and the `msm_bo.c` metadata fix (gallium winsys, not in `libvulkan_freedreno.so`).
- **Verified neutral:** the `fd6_view.cc` A=1 substitution change. It *is* reached from turnip via
  `fdl6_format_swiz()`, but the old comment was right that the HW already returns 1 for R/RG; the
  change only matters for `QCOM_image_processing`, which turnip does not expose.
- **Baseline shift — carry this into any A/B.** `blit_cache_cleaned` was never being set to `true`,
  because `tu6_emit_flushes()` zeroes `cache->flush_bits` on entry and the test ran *after* the call.
  Its only consumer is `tu_flush_dynamic_input_attachments()`, gated on
  `fs.dynamic_input_attachments_used` — so 26.1.6 removes a **per-draw `WAIT_FOR_IDLE`** if and only
  if the app uses dynamic rendering with input attachments. If RPCS3 does, the `syncdraw` floor was
  silently benefiting from that WFI and pre-26.1.6 verdicts are not comparable. Re-baseline before
  ranking any gear.

## Backports carried on the 26.1 line

Two turnip commits ship in 26.2 but were never backported to 26.1.x. Both are in
`patches/backports/26.1/`; `patches/backports/26.2/` is empty because 26.2 has them natively.

- **`a70d2af590db`** — the A650 `EARLY_Z_LATE_Z` hang workaround. Patch #7 builds on it directly.
- **`5000d6644db4`** — "Fix tile division algorithm". Intermediate divisor levels were marked
  initialized without being computed, "leaving their tiling configs full of uninitialized data if one
  of those levels was ever queried directly". The reference fault is a ragged **`255×510`** depth
  sub-target (= 256−1, 512−2 — the signature of a tile config derived from a wrong base), and the
  divisor only escalates above 1 under GMEM pressure via `autotune->get_tile_size_divisor()`, which
  is exactly the lap-4/5 boss regime. **This is testable with instrumentation the fork already
  owns:** `dimlog` prints `tile0=`, `bins=` and `rem=` per framebuffer/gmem-layout, so diffing those
  lines with and without the backport reads directly on whether the ragged bin changes shape.
