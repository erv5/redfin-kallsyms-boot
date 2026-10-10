# Patches for the KSU-Next + SUSFS build

`ksu-susfs.yml` applies these after cloning the LineageOS kernel and running KernelSU-Next
`setup.sh v1.1.1`. They are crDroid's proven redbull integration, verified to apply to the
LineageOS 23.2 tree with zero rejects.

- `ksunext/0001-ksun-v1.1.1-susfs.patch` — crDroid's KSU-Next-side SUSFS integration,
  applied **inside** the `KernelSU-Next/` directory (`cd KernelSU-Next && patch -p1`).
- `ksunext/0002-crdroid-kernelside-susfs.patch` — crDroid's kernel-side SUSFS + the
  non-GKI manual hooks, applied at the **kernel root** (`patch -p1`).

Source: crdroidandroid/android_kernel_google_redbull, `ksun-patches` branch (0001) and the
`16.0...16.0-susfs2-test` diff (0002). Bump both together if you move KSU-Next versions.
