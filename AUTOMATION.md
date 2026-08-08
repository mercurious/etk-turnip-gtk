# The driver release lane — automation design

What exists today is the hard part: a reproducible, gated Android build on a
cloud node, plus the ROCKNIX build beside it from the same source. This is how
that becomes a release *line* rather than a thing we do by hand, and how the
Android line feeds the Linux one honestly.

Nothing here is built yet. It is written down so it can be, and so the shape is
argued before code exists.

---

## 1. What the product actually is

Not the driver. Anyone can build Mesa. The product is **being able to answer
"which one should I use?"** — a question the Android Turnip scene cannot answer
about its own output.

Concretely, four properties, in descending order of how much they matter:

1. **Identity.** Every file says what Mesa version it is, and pre-releases carry
   the exact commit. `T28-toasted` is not an identity.
2. **A changelog.** What is different from the one you're running. Nobody in
   this scene ships this, and it is mechanically derivable.
3. **Honest scope.** What we tested on, and what we didn't.
4. **Reproducibility.** The recipe is public and is the actual script we run.

Cadence is *not* on that list. Shipping more builds than anyone can evaluate
recreates the chaos we're claiming to fix. A slower, legible line beats a fast
opaque one — that is the entire bet.

## 2. The lane, in stages

```
  watch → decide → build → gate → describe → stage → validate → publish
                                                        ↑
                                              the operator, on the rig
```

**watch** — two sources: `archive.mesa3d.org` for new stable releases, and Mesa
git for commits touching `src/freedreno/`. Both are cheap to poll.

**decide** — do not build every commit. Build when:
- a new stable release appears (always), or
- `src/freedreno/` has accumulated N commits since the last devel build, or
- it has been more than X weeks and anything changed.

The threshold is a product decision, not a technical one. Start conservative.

**build + gate** — `scripts/build_android.sh` and `build_rocknix.sh` as they
stand. The gates already refuse: wrong architecture, missing Android HAL entry
point, a dependency on `libc++_shared.so`, a version string that doesn't match
the tree, and — on devel — an embedded commit that isn't the one we pinned.

**describe** — the differentiator, and it is nearly free:

```bash
git log --oneline <last-shipped-sha>..<new-sha> -- src/freedreno/
```

That is the freedreno-only change list between what users are running and what
we're about to ship. Even raw it beats every competitor. Grouped into
"Adreno 6xx", "Adreno 7xx", "shared" and counted, it becomes release notes a
non-developer can skim.

**stage → validate → publish** — the important one. A build that passes gates is
**not validated**; it is a candidate. Only the rig promotes it. This is the same
rule the rest of the kit already runs on (`forge.sh` stages, the operator races,
the ledger judges) and it must not be relaxed just because a driver is easy to
build. Publishing an unraced build as "recommended" is exactly how the scene
lost the ability to answer question one.

Practical shape: automation publishes to a **pre-release** with notes and gate
output. A human promotes it to latest after it has actually run a game.

## 3. Two tracks, one index

| track | source | cadence | who it's for |
|---|---|---|---|
| `stable` | Mesa release tarball | when Mesa releases | everyone |
| `devel` | Mesa main, pinned sha | curated | people chasing a specific fix |

And **one page that always answers the question** — current stable, current
devel, what changed, what we tested. Every release links back to it. If a user
has to compare filenames to make a decision, the product has failed.

## 4. Failure modes to design for now

- **Mesa main breaks.** Regularly. The lane must fail loudly and publish
  nothing. Gates already cover it; the automation must not treat a failed build
  as "skip and carry on quietly."
- **A build passes gates and is bad on-device.** Inevitable. This is why
  publishing is gated on a human, and why the previous package must stay
  downloadable forever. Never delete an old release.
- **Cadence creep.** The most likely way this fails is by succeeding at building
  and forgetting that the value was curation.
- **Support-matrix drift.** Every release repeats what was tested. The moment
  that line goes stale, honesty becomes marketing.

## 5. The Linux funnel — how to do it without lying

The Android line is the wider door: ~1,629 downloads for one Android driver
against 72 across seventeen ETK releases. The Linux work is where the
interesting engineering is. Connecting them is fair *if* the connection is
argued rather than asserted.

**Rules:**

- **Never claim "Linux is faster" flatly.** Name mechanisms that cannot exist in
  an Android app: a GPU-hang net spanning kernel, driver and emulator; per-game
  tuning with recorded results; kernel fixes for this chip. A reader can check
  those claims.
- **Lead with the trade, not the upside.** It is an SD card and an afternoon
  against installing an app. Say that first. It also doesn't touch what's
  already on the device — the strongest and most checkable claim available.
- **Put it last.** The driver page must be genuinely useful to someone who never
  clicks through. The moment the drivers become a lead-magnet whose quality
  slips, the funnel dies with them.
- **Same care both sides.** The Android drivers get the same gates as the
  ROCKNIX ones because they're the same lane. That is the argument.

**Measure it.** The Android-to-Linux ratio is currently ~23:1. If that ratio
moves after driver releases carry the invitation, the funnel works. If downloads
rise and ETK stays at 72, the funnel is decorative and should be rethought
rather than shouted louder.

## 6. Build order

1. **The index page.** Highest value, no automation needed. It is the answer to
   the question.
2. **`describe`** — the freedreno-only changelog between shipped and candidate.
   Small script, immediate differentiation.
3. **`watch` + `decide`** — a scheduled job that opens an issue saying "Mesa
   26.2.1 is out" or "12 freedreno commits since the last devel." Notification
   before automation; a human still pulls the trigger.
4. **Publish automation** — last, and only for pre-releases. Promotion stays
   manual, permanently.

Steps 1 and 2 deliver most of the value and need no scheduler at all. That
ordering is deliberate: the thing that makes this worth doing is editorial, and
editorial does not automate.
