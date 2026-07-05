# Validation protocol

This driver's claims are about **stability under a noisy workload**, so the test design matters more
than any single run. The reference title (GT5P) has an enormous run-to-run variance (time-to-crash
spanning roughly 77–2886 s), so single runs prove nothing — verdicts come from the operator's screen
across repeated runs, with the mechanism confirmed from the logs.

## Ground rules

1. **Cold-boot gate.** Every change must survive a full reboot. ROCKNIX reverts non-persistent
   changes; a runtime bind-mount that vanishes on reboot is not validated. Confirm the intended `.so`
   is bound *after* a cold boot before recording anything.
2. **Warm cache only.** Exclude cold-launch recompile sessions (high shader-harvest rows, ≳1000
   shaders): those are recompiles, not race runs. Only warm runs (harvest ≈ 0) count toward the
   duration signal.
3. **Saturated-vault A/B.** Run candidate vs. control against the **same** (saturated) shader vault
   so shader-compile noise isn't the variable under test.
4. **N ≥ 3 per candidate.** No crowning a gear from one run. The early Patch #1 "Gold" died exactly
   this way.
5. **Rule out our own code first.** Before blaming hardware (cable/card/thermals), confirm the fault
   reproduces independent of the gear and the bind.

## Signal, not crash-rate

Measure **duration and time-to-crash ceiling**, not a binary "clean/crashed" rate — the latter is
biased by the variance above. The headline stability result on the ledger — a median
session-duration lift (≈171 s → ≈286 s, ≈+67% on a saturated vault) — belongs to the **`syncdraw`**
tuning campaign, **not** to any fork gear. `tune_tag` is stamped per session so each run attributes
to the dial it actually ran under; keep that attribution honest when comparing.

## What the fork gears are measured *for*

Because the fork gears (`sddepth` et al.) are FPS levers, not a stability win, the axis that
adjudicates them is **framerate / frametime**, not crash-rate — the ledger has no FPS column, so
stability numbers alone cannot rank `sddepth` against `syncdraw`. Frametime consistency
(`ft_jitter_ms`, extracted post-session) plus measured FPS is the real comparison. On stability,
expect a fork gear to do **no better than `syncdraw`** (and `sddepth` to do somewhat worse) — the
question a gear has to answer is whether the FPS it buys is worth that stability cost.

## Reproducing a comparison

1. Build both `.so` files (stock `mesa-26.1.3` and the fork) — see [`BUILDING.md`](BUILDING.md).
2. Stage both under the driver catalog and select via the DRIVER tab; **cold boot** between swaps.
3. Warm the vault (one launch to menu), then run the fixed race scenario N≥3 per build.
4. Compare duration / time-to-crash and `ft_jitter_ms`, not pass/fail counts.
