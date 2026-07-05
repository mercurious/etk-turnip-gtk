# Gears — `TU_DEBUG` barrier flags added by this fork

All gears are implemented at a single site, `tu6_emit_flushes()` in
`src/freedreno/vulkan/tu_cmd_buffer.cc`. They are opt-in via `TU_DEBUG` and have **no effect
unless selected**, so the fork is a strict superset of stock behavior.

On the rig these are not hand-written; they're applied through the **Pitstop DRIVER tab**, which
writes them atomically to `/storage/.config/profile.d/097-etk-turnip-dials` (sourced before RPCS3
launch) and stamps each session's `tune_tag` in the telemetry ledger for A/B attribution. Outside
ETK, set them via the `TU_DEBUG` environment variable.

## Fork gears

The gears are **FPS-recovery levers**, lighter than `syncdraw`. None of them beats `syncdraw` on
stability — they trade serialization back for framerate. For crash-avoidance, use stock `syncdraw`
(see below).

| Flag | Barrier emitted | Notes | Status |
|------|-----------------|-------|--------|
| `sddepth` | `WAIT_MEM_WRITES \| CCU_CLEAN_DEPTH \| WAIT_FOR_ME` | Lighter than `syncdraw` (no full WFI); recovers FPS in GPU-bound scenes | Most stable of the lighter gears, **but more crash-prone than `syncdraw`** |
| `sdmem` | `WAIT_MEM_WRITES \| WAIT_FOR_ME` | Drops the CCU depth clean | **Falsified** — survival collapses (~33%) vs `sddepth` |
| `sdme` | `WAIT_FOR_ME` only | Minimal barrier | **Falsified** — did not hold (0/2) |
| `sdclean` | `CCU_CLEAN_DEPTH` only | Cache clean, no waits | Experimental; lighter still |
| `sdgate` | `sddepth`, gated to depth-writing draws only | ~93% of GT5P draws write depth, so the gate is ~null | No measurable gain over `sddepth` |
| `dmlog` | — | Logs resolve operations; instrumentation only | Decode/analysis helper |

**Recommendation:** for stability, use stock **`syncdraw`** — it is the best-tested dial and the
accepted floor. Reach for `sddepth` only when you want to claw back framerate in GPU-bound sections
and accept a higher crash risk than `syncdraw`. Going lighter than `sddepth` (`sdmem`/`sdme`) is
falsified — the depth-cache clean is what keeps the lighter gear from collapsing.

## Relevant upstream `TU_DEBUG` flags (for reference)

These are stock Mesa flags, not added by the fork:

- `syncdraw` — `CP_WAIT_FOR_IDLE` after every draw. **The preferred, best-tested stability dial**
  on these titles; the fork's `sddepth` is a lighter FPS-recovery variant that does *not* match it
  on stability.
- `nolrz`, `noubwc` — exonerated (hang persists with them set).
- `sysmem`, `gmem` — render-mode selection; the hang is mode-independent.
- `nobin`, `forcebin`, `nocb`, `noconcurrentresolves`, `flushall` — other levers, lower priority,
  not surveyed.
