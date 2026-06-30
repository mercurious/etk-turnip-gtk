# Gears — `TU_DEBUG` barrier flags added by this fork

All gears are implemented at a single site, `tu6_emit_flushes()` in
`src/freedreno/vulkan/tu_cmd_buffer.cc`. They are opt-in via `TU_DEBUG` and have **no effect
unless selected**, so the fork is a strict superset of stock behavior.

On the rig these are not hand-written; they're applied through the **Pitstop DRIVER tab**, which
writes them atomically to `/storage/.config/profile.d/097-etk-turnip-dials` (sourced before RPCS3
launch) and stamps each session's `tune_tag` in the telemetry ledger for A/B attribution. Outside
ETK, set them via the `TU_DEBUG` environment variable.

## Fork gears

| Flag | Barrier emitted | Notes | Status |
|------|-----------------|-------|--------|
| `sddepth` | `WAIT_MEM_WRITES \| CCU_CLEAN_DEPTH \| WAIT_FOR_ME` | Serializes after the depth store-resolve; **no full WFI** — lighter than upstream `syncdraw` | **Load-bearing.** ~50–67% hang-frequency reduction; recommended default |
| `sdmem` | `WAIT_MEM_WRITES \| WAIT_FOR_ME` | Skips the CCU depth clean | Holds, FPS-neutral vs `sddepth` |
| `sdme` | `WAIT_FOR_ME` only | Minimal barrier | Holds; lighter |
| `sdclean` | `CCU_CLEAN_DEPTH` only | Cache clean, no waits | Stable but slowest (no `WAIT_MEM`) |
| `sdgate` | `sddepth`, gated to depth-writing draws only | ~93% of GT5P draws write depth, so the gate is ~null | No measurable FPS gain over `sddepth` |
| `dmlog` | — | Logs resolve operations; instrumentation only | Decode/analysis helper |

**Default recommendation:** `sddepth`. It is the lightest gear that carries the measured stability
gain; the lighter gears (`sdmem`/`sdme`/`sdclean`) hold but give up the depth-cache clean that
appears to matter, and `sdgate` adds gating complexity for no benefit on this workload.

## Relevant upstream `TU_DEBUG` flags (for reference)

These are stock Mesa flags, not added by the fork, but they were part of the isolation work:

- `syncdraw` — `CP_WAIT_FOR_IDLE` after every draw. The full sledgehammer; `sddepth` is the
  lighter, targeted refinement of the same idea.
- `nolrz`, `noubwc` — exonerated (hang persists with them set).
- `sysmem`, `gmem` — render-mode selection; the hang is mode-independent.
- `nobin`, `forcebin`, `nocb`, `noconcurrentresolves`, `flushall` — other levers, lower priority,
  not surveyed.
