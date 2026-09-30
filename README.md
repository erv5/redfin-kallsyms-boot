# Pixel 5 (redfin): LineageOS boot with full kallsyms

Rebuilds the LineageOS `redfin` kernel with `CONFIG_KALLSYMS_ALL=y` and posts a
ready-to-flash `boot.img` for each of the most recent LineageOS builds. LineageOS
ships with the kernel's data symbols stripped out of the symbol table; this puts them
back (the `rodata`/data symbols), which helps with kernel debugging and anything that
resolves kernel symbols at runtime.

👉 **[Get the latest boot image from Releases](../../releases)**

## What it changes

Just the one option, `CONFIG_KALLSYMS_ALL=y`, on top of LineageOS's own kernel config.
Everything else (CFI, LTO, module versioning, the exact version string) is left exactly
as LineageOS builds it, so the stock vendor modules still load. The build reads the
kernel commit straight out of each official OTA and checks the rebuilt version string
matches byte-for-byte before publishing. If it doesn't, it publishes nothing.

## Flashing (each LineageOS update)

1. Take the LineageOS update and reboot (this restores the stock kernel).
2. Download the `boot-kallsyms-….img` from the matching [release](../../releases).
3. If you're rooted, patch it in your root manager first, then
   `fastboot flash boot <img>` (both slots) and reboot.

Keep your original `boot.img` as a fallback.

## Schedule

Builds every **Wednesday** (LineageOS releases on Mondays) and keeps the last few
builds available, one release per build, tagged `los-YYYYMMDD`. You can also run it
anytime from the **Actions** tab.

<details>
<summary>Owner: setup & maintenance</summary>

- **Enable:** Settings, Actions, General, Workflow permissions, *Read and write*
  (the workflow also declares `permissions: contents: write`). Then run it once from the
  **Actions** tab.
- **How many builds:** the workflow builds the last 3 (`matrix.offset: [0, 1, 2]` in
  [`.github/workflows/kallsyms-boot.yml`](.github/workflows/kallsyms-boot.yml)). Add or
  remove offsets to keep more or fewer.
- **Pinned tools** are in [`scripts/build-kallsyms-boot.sh`](scripts/build-kallsyms-boot.sh):
  `payload-dumper-go` and `clang` from apt.llvm.org (magiskboot comes from the official
  Magisk APK, so it isn't pinned). Bump a URL if one 404s.
- **A run failing on `FATAL version mismatch`** did its job: LineageOS changed the
  version string, so the build refused to publish something that could break a module.
  Check the log; don't bypass the gate.
- **New LineageOS branch** past `lineage-23.2`? Update `KERNEL_BRANCH` in the script.
- **Scheduled builds auto-disable** after 60 days with no commits (GitHub emails you).
  Click *Enable*, or push any commit to reset it.

</details>
