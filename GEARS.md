# Gears — `TU_DEBUG` flags added by this fork

The barrier gears are implemented at a single site, `tu6_emit_flushes()` in
`src/freedreno/vulkan/tu_cmd_buffer.cc`. The Patch #7 z-mode gears sit at a second site,
`tu6_build_depth_plane_z_mode()` in the same file. All are opt-in via `TU_DEBUG` and have **no effect
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
| `dimlog` | — | Instrumentation only: GMEM render-target/bin dims + ragged remainder at tiling setup, and the `zlatez` reachability probe below | Decode/analysis helper |

## Z-mode gears (Patch #7) — a different mechanism

`zlatez` is **not** a barrier gear and does not belong to the FPS-vs-stability trade above. It is a
stability experiment on a different axis, and the first fork gear that is not a *resolve* mechanism —
which matters, because every falsified gear in [`PATCHES.md`](PATCHES.md) was one.

Upstream forces `A6XX_LATE_Z` for `A6XX_EARLY_Z_LATE_Z` + `D32_SFLOAT_S8_UINT` + a killing fragment
shader, under the in-tree comment *"A630/A650 hangs with this combination of states"*. That is this
fork's GPU and a fragment-stage wedge — the shape of the reference fault. The ETK workload is Z24S8,
so the format gate is the only thing keeping that workaround off it.

| Flag | Effect | Notes | Status |
|------|--------|-------|--------|
| `zlatez` | Extends the upstream workaround to `D24_UNORM_S8_UINT` | **The confirmed format** — use this one | **First positive result** (see below) |
| `zlatezany` | Drops the format gate entirely — any depth format | Not needed: the probe identified the format | Built; superseded by `zlatez` |

**A/B result (2026-07-30, `gtk_0.6`, GT5P one-lap HSL, N=3 per arm, single sitting):** gear **off**
→ 3/3 wedged (`00E59005`), 5 rescues. Gear **on** → 3/3 completed the race, saved and exited
cleanly, 0 rescues, PERFECT% 2.4 → 7.1. This is the first fork gear to beat its own control on this
fault, and the mechanism was predicted in advance by the `dimlog` probe rather than found by
fishing the ledger.

Caveats that keep it provisional: N=3; **one lap** (the documented boss is HSL-reverse at ~lap 4–5,
so this does not separate *eliminated* from *delayed*); and one title — `BCUS98158` is GT5P **Spec
II**, the title that was separately hit by an RPCS3 ARM64 SPU miscompile.

> **Sessions after 2026-07-31 09:46 do not extend this result.** Two follow-on claims — an "N=6
> extension" and an "exposure gradient" — were withdrawn on 08-01: the first pooled across an RPCS3
> base bump, the second read the Spec II boot-fatal window as driver behaviour. See
> [`PATCHES.md`](PATCHES.md). Only the 07-30 block is single-stack.

> Reading the ledger: a completed session is race + save + graceful exit, a crashed one just stops,
> so **a winning arm can show shorter durations than a losing one**. Compare `status` and `rescues`
> before duration.

**Run the probe before the gear.** With `TU_DEBUG=dimlog` and *no* z-gear set, the driver logs once:

```
[ETK zlatez] hazard state reached: EARLY_Z_LATE_Z + fs_kill_fragments, depth_format=… depth_write=… stencil_write=…
```

If that line never appears, the hazard state is never entered, both gears are inert, and the
hypothesis dies for the price of one session instead of an N≥3 A/B.

**Probe result (2026-07-30, GT5P BCUS98158, `gtk_0.5`):** it appears — with
`depth_format=VK_FORMAT_D24_UNORM_S8_UINT depth_write=1 stencil_write=0`. The workload enters the
hazardous state in exactly the format upstream's `D32S8` gate excludes, so `zlatez` is the gear to
race and `zlatezany` can stay on the shelf.

> The `[ETK …]` lines go to `MESA_LOG_FILE` (rig: `etk_telemetry/t0probe.log` via profile.d
> `099-etk-t0probe-log`), **not** `RPCS3.log` — `mesa_logi` writes to stderr. Grepping the wrong
> file returns zero hits and reads exactly like a falsified hypothesis.

> `dimlog` is **not free**: 26,924 lines / 2.7 MB in a 440 s session, and the run's frametimes
> showed it. Use it to answer a reachability question, then turn it off before measuring anything.

Because both gears are a strict *widening of an existing upstream workaround* rather than a new
mechanism, a positive result is directly reportable as a freedreno merge request.

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
