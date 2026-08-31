# Turnip drivers for Android — which one should I use?

Short answer: **download the newest `stable`.** If it works, you're done.

These are Vulkan graphics drivers for Snapdragon phones and handhelds. They
replace the driver your device shipped with, inside emulators that support
custom drivers (aPS3e, Vita3K, Winlator, and others). A better driver can mean
more frames, fewer glitches, or a game booting that didn't before.

---

## Pick a file

| File name looks like | What it is | Use it if |
|---|---|---|
| `etk-turnip-26.2.1-android.adpkg.zip` | **Stable.** Built from an official Mesa release. | You want it to just work. **Start here.** |
| `etk-turnip-26.3.0-devel-a1b2c3d4e-android.adpkg.zip` | **Pre-release.** Built from Mesa's in-progress code, frozen at one exact point. | Stable has a bug you're hoping is fixed, or you like being early. |

The number (`26.2.1`) is the Mesa version — bigger is newer. The letters and
digits on a pre-release (`a1b2c3d4e`) identify the exact snapshot of Mesa's code
it was built from. That's there so anyone can check what they're running and
rebuild it themselves. It isn't a nickname.

**We don't name drivers after ourselves.** If you've been through a few of
these, you've seen files like `turnip-somebody-R8-toasted`. That tells you
nothing you can act on: not how new it is, not what's in it, not how to compare
two of them. Every file here tells you the Mesa version and, on pre-releases,
the exact commit.

## Install it (aPS3e)

1. Download the `.zip`. **Don't unzip it.**
2. In aPS3e: **Configuration → Video → Vulkan → Custom Driver**
3. Point it at the `.zip`, then select the driver and restart the emulator.

Other emulators have a similar "driver manager" or "custom driver" screen.
The `.zip` is the standard AdrenoTools package format, so it works anywhere that
format is supported.

**Your first launch after switching drivers will be slow.** Games build a
shader cache for whichever driver is installed, and changing drivers throws it
away. That's normal and it's one time per driver — not a sign anything's wrong.

## If it's worse, go back

Nothing is permanent. Switch back to your system driver (or the previous
package) in the same screen and restart. Swapping drivers can't brick anything —
worst case a game won't start, and you undo it in about fifteen seconds.

Please tell us when that happens, and which device you're on. A bug report with
a device name is worth more to us than a hundred silent downloads.

## What we actually tested

Honest scope, because "supports all Adreno" is a claim nobody can back:

- **Tested:** Adreno 650 (Snapdragon 865 / 870) — specifically a Retroid Pocket
  Flip 2, running Gran Turismo 5 Prologue on aPS3e for hours at a time.
- **Should work, untested by us:** other Adreno 6xx and 7xx parts.
- **Won't work:** anything that isn't a Qualcomm Adreno. This is not a Mali
  driver.

If you're on other silicon, it may be great — we just haven't looked, and we'd
rather say so than imply coverage we don't have.

## Verify what you're running

Every package contains a `meta.json` naming the exact build, and the version is
compiled into the driver itself. On a pre-release you can take the commit id
from the file name and read that exact code on Mesa's public repository. Nothing
here is a mystery binary — that's the whole point.

---

## One more thing, if you're getting serious about PS3 emulation

This is worth saying plainly rather than burying.

aPS3e is a port of RPCS3 — the desktop PS3 emulator — to Android. It's a
genuinely impressive piece of work. But the same handheld you're running it on
can also boot **Linux**, and there RPCS3 runs as the full desktop emulator
rather than a port. On our test rig that difference is not subtle.

We build drivers for both. The Linux side additionally gets things that can't
exist in an Android app:

- **A crash net.** GPU hangs that would otherwise freeze the device get absorbed
  and the game keeps running. We built this across the kernel, the driver, and
  the emulator — three layers an app can't touch.
- **Per-game tuning that records its own results,** so a change can be shown to
  have helped rather than assumed to have.
- **Kernel fixes** for this specific chip.

The honest trade: it's an SD card and an afternoon, versus installing an app. It
does not touch what's already on your phone — you boot from the card, and remove
it to go back. If your Android experience is "good but I keep hitting a wall,"
that wall is often the platform, not the driver.

That's an invitation, not a bait-and-switch. The Android drivers here are built
with the same care whether or not you ever try the Linux side, and they always
will be.

→ **[ROCKNIX-GTK / Emulation Tuning Kit](https://github.com/mercurious/etk)**

---

## For the curious

Built on a public, reproducible lane — an aarch64 Linux cloud box, in a
container pinned by digest, with a sha256-pinned NDK. The recipe is
`scripts/build_android.sh` in this repository; the provisioning that creates the
build environment is next to it. Both are the actual scripts that produce these
files, not a description of them.

Every build is gated before release: correct CPU architecture, correct Android
entry point, no dependency on libraries your device won't have, and — on
pre-releases — proof that the commit compiled into the binary matches the commit
we claimed to build.
