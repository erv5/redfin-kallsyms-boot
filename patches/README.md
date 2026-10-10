# Patches for the KSU-Next + SUSFS build

`ksu-susfs.yml` applies these after cloning the LineageOS kernel and running KernelSU-Next
`setup.sh v1.1.1`. SUSFS version is pinned to **v1.5.5** across both sides so they match.

- `ksunext/0001-ksun-v1.1.1-susfs.patch` — crDroid's KSU-Next-side SUSFS integration
  (KSUN v1.1.1 / SUSFS v1.5.x), applied **inside** `KernelSU-Next/`.
- Kernel-side SUSFS is simonpunk `susfs4ksu` branch `kernel-4.19` (SUSFS **v1.5.5**),
  cloned at build time: its `fs/` + `include/linux/` files are copied in and
  `50_add_susfs_in_kernel-4.19.patch` applied at the kernel root.
- `ksunext/0002-mount-vfsmount-field.patch` — adds the `susfs_mnt_id_backup` field to
  `struct vfsmount`; the stock SUSFS mount.h hunk rejects on this tree because redbull's
  vfsmount has no trailing `void *data;`.

SUS_MOUNT / TRY_UMOUNT / HAS_MAGIC_MOUNT are left off (their `fs/namespace.c` hunks reject
on this tree); SUS_PATH / KSTAT / uname / cmdline / open-redirect / symbol-hiding are on.
