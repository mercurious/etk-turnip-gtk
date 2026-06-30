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

This is why every "fix the resolve" mechanism below ultimately falsifies, and why `sddepth` is
framed as a mitigation rather than a cure.

## Series

### Patch #1 — CCU resolve serialization (FALSIFIED, kept for history)
- **Files:** `src/freedreno/vulkan/tu_cmd_buffer.cc`
- **Change:** forced `WAIT_FOR_IDLE` + `CCU_CLEAN_DEPTH` + `CCU_INVALIDATE` after every GMEM
  store-resolve via `tu6_emit_flushes()`.
- **Verdict:** an early "Gold" result did not survive N=3; the hang persists. Kept as a commit so the
  reasoning is visible.

### Patch #2 — `sddepth` / `sdmem` / `sdme` gears (VALIDATED)
- **Files:** `src/freedreno/vulkan/tu_cmd_buffer.cc` (at `tu6_emit_flushes()`), helper defs in
  `tu_util.{h,cc}`.
- **Change:** three opt-in `TU_DEBUG` barrier levels (see [`GEARS.md`](GEARS.md)).
- **Verdict:** **`sddepth` is load-bearing** — ~50–67% hang-frequency reduction, FPS-neutral. This
  also reframed the root cause: a lighter barrier helping at all points to shader-retirement timing,
  not a missing resolve sync.

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
`nolrz`/`noubwc`, and per-draw discriminators have all been falsified for this fault. `sddepth` is
the surviving mitigation.

## Redumps (forensic evidence)

Hang redumps backing the decode are banked outside this repo (large binaries). Representative
captures: HSL race (`ib2=0x15D8F8AA4`, sysmem 2D-blit resolve), Save-Game (`CP_BLIT`/`BLIT_OP_SCALE`),
plus gmem/`sddepth` variants used for the truncation-recovery and self-repair flow.
