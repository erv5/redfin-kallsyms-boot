# Patches for the KSU + SUSFS build

The `ksu-susfs.yml` workflow applies patches from here, in this order, after it clones
the kernel and runs KernelSU `setup.sh` but before `make`.

## `manual-hooks-redbull-4.19.patch` (required for a bootable kernel)

Non-GKI 4.19 kernels do not get working KSU hooks from `setup.sh`. You must insert five
hook calls by hand, each guarded by `#ifdef CONFIG_KSU`:

| function           | file                | call                         |
|--------------------|---------------------|------------------------------|
| `do_execveat_common` | `fs/exec.c`       | `ksu_handle_execveat(...)`   |
| `do_faccessat`     | `fs/open.c`         | `ksu_handle_faccessat(...)`  |
| `vfs_read`         | `fs/read_write.c`   | `ksu_handle_vfs_read(...)`   |
| `vfs_statx`/newfstatat | `fs/stat.c`     | `ksu_handle_stat(...)`       |
| `SYSCALL_DEFINE4(reboot)` | `kernel/reboot.c` | KSU reboot hook         |

Exact diffs: https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
Make the edits once on a clean checkout of the OTA commit, then
`git diff > manual-hooks-redbull-4.19.patch` and drop it here. The workflow applies it to
the kernel root with `patch -p1`.

## `ksu/*.patch` and `ksunext/*.patch` (reject fixes)

The workflow first tries the upstream SUSFS enable patch, which rejects some hunks
(especially on KSU-Next). Download the `*-rejects-and-logs` artifact from a run, resolve
each `.rej` against the matching source file, capture the result as a patch, and drop it
in the matching variant folder. The workflow applies every `*.patch` here with `patch -p1`
from the kernel root.
