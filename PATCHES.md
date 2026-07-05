# Patch history & decision log

The fork is a short series carried over `mesa-26.1.3`. This file records **what was tried, what was
kept, and what was falsified** — the negative results are part of the deliverable, so the dead ends
aren't re-walked by anyone reading the source.

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
