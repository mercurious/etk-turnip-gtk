# CLAUDE.md — etk-turnip-gtk (sister repo of the ETK ecosystem)

**Mother repo: `~/etk`.** Bootstrap every session there first — read `~/etk/CLAUDE.md`, then
`~/etk/TRACK_MANUAL.md` (§8 deployment, §8.5 the build fleet) before working here. This repo is
one spoke of that system: the **Mesa Turnip driver fork** (glibc/`msm`/ROCKNIX, Adreno 650) for
the SM8250 rig. It publishes source and reproduces builds; it is not a distribution channel.

## Reading order (this repo)
`README.md` (lineage + the three tracks) → `BUILDING.md` (container, configure line, traps) →
`PATCHES.md` (decision log; falsified ideas stay falsified) → `VALIDATION.md` (A/B ground rules)
→ `GEARS.md` (TU_DEBUG gear semantics) → `patches/README.md` (series vs backports layout).

## How artifacts flow (never deviate)
1. **Prepare trees**: `scripts/prepare-fork-branch.sh apply` (stable default; sha-pin for devel —
   "main is a POSITION, not a version"; `SKIP_PATCHES` for gears upstream refactored away).
2. **Mint**: `~/etk/forge.sh turnip` conducts `~/etk/tools/forge/lane_turnip.sh` on **etk-cloud**
   (knobs `FORGE_TURNIP_VERS` / `FORGE_TURNIP_GTKVER` in gitignored `~/etk/etk.conf`). The lane
   needs `/work/mesa-<ver>` trees WITH `tu_etk_gears.h` (a tree without it is the pre-0.7
   bit-collision build — refuse), and stages `etk_turnip_rocknix_<ver>_gtk_<gen>.so` + sha256
   into `~/etk/drivers/` — that directory IS the driver catalog.
3. **Deploy**: only the operator, only via `~/etk/install.sh` (STEP 6.5 stages the catalog to
   the rig; Pitstop DRIVER tab selects; cold-boot gated). Claude NEVER contacts the rig from
   anywhere but the Air, and never reboots it.

## Non-negotiables inherited from the mother repo
- Always-reboot gate; verify the LIVE artifact (`driverInfo` must show `Mesa <ver> (git-<sha>)
  ETK-GTK` — a build you cannot attribute is not a result).
- Trunk-based: work on `main`, push same session; never force-push.
- Public artifacts under the **mercurious** pseudonym; docs stay development/tuning-focused.
- VALIDATION rule 7: re-baseline stock `syncdraw` after any base bump before ranking gears.
