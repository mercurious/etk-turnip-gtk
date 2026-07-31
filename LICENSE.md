# Licensing & attribution

This is a **downstream fork of Mesa**. Mesa's own license terms govern this source unchanged.

## What governs

- **Upstream license files are carried verbatim.** When you produce the fork branch from the base
  tag (see [`scripts/prepare-fork-branch.sh`](scripts/prepare-fork-branch.sh)), Mesa's top-level
  license documentation comes with it — `docs/license.rst` and the `licenses/` directory.
  Do not remove or alter them.
- **Per-file headers govern each file.** Mesa is predominantly **MIT**-licensed, with some
  components under other licenses. Every file this fork modifies is MIT upstream (verified against
  `mesa-26.1.6`):

  | File | Copyright | How MIT is declared |
  |------|-----------|---------------------|
  | `src/freedreno/vulkan/tu_cmd_buffer.cc` | © 2016 Red Hat | `SPDX-License-Identifier: MIT` |
  | `src/freedreno/vulkan/tu_device.cc` | © 2016 Red Hat | `SPDX-License-Identifier: MIT` |
  | `src/freedreno/vulkan/tu_query_pool.cc` | © 2015 Intel | `SPDX-License-Identifier: MIT` |
  | `src/freedreno/vulkan/tu_query_pool.h` | © 2016 Red Hat | `SPDX-License-Identifier: MIT` |
  | `src/freedreno/vulkan/tu_util.cc` | © 2015 Intel | `SPDX-License-Identifier: MIT` |
  | `src/freedreno/vulkan/tu_util.h` | 2020 Valve | `SPDX-License-Identifier: MIT` |
  | `src/vulkan/runtime/vk_fence.c` | © 2021 Intel | full MIT text, **no SPDX tag** |
  | `src/vulkan/runtime/vk_fence.h` | © 2021 Intel | full MIT text, **no SPDX tag** |

  This fork preserves those headers unchanged and adds no conflicting blanket claim. Note the last
  two: they are MIT by full boilerplate rather than an SPDX identifier, so a `grep SPDX` sweep alone
  will not find their license — check the header text.

> That list is the complete fork delta (see `git log mesa-26.1.6..` on a branch built by
> `scripts/prepare-fork-branch.sh`). If you extend it to other files, re-check their headers — both
> `grep -n SPDX-License-Identifier <file>` *and* the comment block at the top — and keep them intact.

**Backported upstream commits** under `patches/backports/` are unmodified Mesa commits carrying their
original authorship and `Signed-off-by`/`Part-of` trailers; they are governed by the same upstream
terms and are attributed to their authors in [`patches/README.md`](patches/README.md).

## The one real obligation

The MIT terms require **preserving the copyright and permission notices**. Practically: keep the
upstream license files and every per-file header intact, and keep your changes as visible commits on
top of the tagged base so the provenance is auditable. That is the whole compliance story for an
MIT-licensed base.

## Attribution of the changes

The fork's modifications are confined to the sites listed in [`PATCHES.md`](PATCHES.md). They are
deliberately minimal and intended to be upstreamable as a freedreno merge request; the canonical home
for any upstream-worthy change is freedesktop GitLab, not this repository.
