# Licensing & attribution

This is a **downstream fork of Mesa**. Mesa's own license terms govern this source unchanged.

## What governs

- **Upstream license files are carried verbatim.** When you produce the fork branch from the
  `mesa-26.1.3` tag (see [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh)), Mesa's
  top-level license documentation comes with it — `docs/license.rst` and the `licenses/` directory.
  Do not remove or alter them.
- **Per-file SPDX headers govern each file.** Mesa is predominantly **MIT**-licensed, with some
  components under other licenses. The files this fork modifies are all
  `SPDX-License-Identifier: MIT` upstream:
  - `src/freedreno/vulkan/tu_cmd_buffer.cc` — `© 2016 Red Hat / Bas Nieuwenhuizen`, MIT (confirmed)
  - `src/freedreno/vulkan/tu_util.cc`, `tu_util.h` — MIT (confirmed)

  This fork preserves those headers unchanged and adds no conflicting blanket claim.

> The fork delta touches only those three files (see `git log mesa-26.1.3..` on a branch built by
> `scripts/prepare-fork-branch.sh`). If you extend it to other files, re-check their headers —
> `grep -n SPDX-License-Identifier <file>` — and keep them intact.

## The one real obligation

The MIT terms require **preserving the copyright and permission notices**. Practically: keep the
upstream license files and every per-file header intact, and keep your changes as visible commits on
top of the tagged base so the provenance is auditable. That is the whole compliance story for an
MIT-licensed base.

## Attribution of the changes

The fork's modifications are confined to the sites listed in [`PATCHES.md`](PATCHES.md). They are
deliberately minimal and intended to be upstreamable as a freedreno merge request; the canonical home
for any upstream-worthy change is freedesktop GitLab, not this repository.
