# patches/

The complete ETK GTK fork delta over upstream **`mesa-26.1.3`**, as a git-am-able series.
Apply onto a fresh upstream clone with [`../scripts/prepare-fork-branch.sh apply`](../scripts/prepare-fork-branch.sh)
(no build container required).

| Patch | What it is | Status |
|-------|-----------|--------|
| `0001-ETK-GTK-gears-…` | The LSD FPS-recovery gears: `sddepth`/`sdmem`/`sdme` depth-cache barriers + `dimlog`, in `tu_cmd_buffer.cc` + `tu_util.{cc,h}`. Squashed, because the source tree imported them as one commit with no stock baseline between. | **Kept** (default-off; FPS levers — `syncdraw` owns stability) |
| `0002-Patch-3-B-ccuhalf-ccuquarter-…` | Cap a6xx depth CCU cache size. | Falsified (see [`../PATCHES.md`](../PATCHES.md)) |

| `0003-Patch-3-A-dsbypass-…` | Selective sysmem for depth-storing renderpasses. | Falsified |
| `0004-Refined-A-dsany-…` | Route any depth-attachment renderpass to sysmem. | Falsified |

The falsified patches are retained on purpose: they are `TU_DEBUG`-gated and default-off, and the
production `.so` carries all gears so the negative results stay reproducible. The decision log is in
[`../PATCHES.md`](../PATCHES.md).

Total delta: 3 source files, ~120 insertions. The series preserves upstream's license files and
per-file SPDX (`MIT`) headers unchanged.

> Regenerate from the build tree with `prepare-fork-branch.sh build` (needs the build container).
> The `build` and `apply` paths are verified to produce byte-identical trees.
