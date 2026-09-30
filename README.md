# Pixel 5 (redfin) — LineageOS boot with full kallsyms

Rebuilds the LineageOS `redfin` kernel with `CONFIG_KALLSYMS_ALL=y` and posts a
ready-to-flash `boot.img` for each release. LineageOS ships with the kernel's data
symbols stripped out of the symbol table; this puts them back (the `rodata`/data
symbols) — handy for kernel debugging and anything that resolves kernel symbols at
runtime.

👉 **[Latest boot image → Releases](../../releases)**

## What it changes

Just the one option — `CONFIG_KALLSYMS_ALL=y` — on top of LineageOS's own kernel
config. Everything else (CFI, LTO, module versioning, the exact version string) is left
exactly as LineageOS builds it, so the stock vendor modules still load. The build reads
the kernel commit straight out of each official OTA and checks the rebuilt version
string matches byte-for-byte before publishing — if it doesn't, it publishes nothing.

## Flashing (each LineageOS update)

1. Take the LineageOS update and reboot (this restores the stock kernel).
2. Download the `boot-kallsyms-….img` from the matching [release](../../releases).
3. If you're rooted, patch it in your root manager first; then
   `fastboot flash boot <img>` (both slots) and reboot.

Keep your original `boot.img` as a fallback.

## Schedule

Builds every **Wednesday** (LineageOS releases on Mondays), one release per build,
tagged `los-YYYYMMDD`. You can also run it anytime from the **Actions** tab.

<details>
<summary>Owner: setup & maintenance</summary>

- **Enable:** Settings → Actions → General → Workflow permissions → *Read and write*
  (the workflow also declares `permissions: contents: write`). Then run it once from the
  **Actions** tab.
- **Pinned tools** are in [`scripts/build-kallsyms-boot.sh`](scripts/build-kallsyms-boot.sh)
  (`payload-dumper-go`, `magiskboot`, and `clang` from apt.llvm.org) — bump a URL if one
  404s.
- **A run failing on `FATAL version mismatch`** did its job: LineageOS changed the
  version string, so the build refused to publish something that could break a module.
  Check the log; don't bypass the gate.
- **New LineageOS branch** past `lineage-23.2`? Update `KERNEL_BRANCH` in the script.
- **Scheduled builds auto-disable** after 60 days with no commits (GitHub emails you) —
  click *Enable* or push any commit to reset it.

</details>
