#!/usr/bin/env bash
# Build a KernelSU / KernelSU-Next + SUSFS redfin kernel for the latest LineageOS OTA.
#
#   VARIANT=ksu      -> official tiann/KernelSU (pinned pre-EOL tag) + simonpunk susfs 4.19
#   VARIANT=ksunext  -> KernelSU-Next (legacy line)  + ShirkNeko susfs 4.19 (fallback simonpunk)
#
# IMPORTANT: this is an ITERATIVE build. Non-GKI 4.19 needs 5 hand-inserted manual
# syscall hooks that setup.sh does NOT add, and the SUSFS KSU-side patch rejects on some
# trees. So this script COLLECTS every .rej into artifacts/ and ATTEMPTS the build. It
# produces a flashable zip only if the build actually succeeds, which needs the manual
# hook patch (patches/manual-hooks-redbull-4.19.patch) and any reject fixes committed
# under patches/<variant>/. Run 1 exists to surface the rejects + the build log.
set -uo pipefail   # deliberately NOT -e: we want to reach reject collection even on failure

VARIANT="${VARIANT:-ksunext}"
DEVICE="${DEVICE:-redfin}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_google_redbull}"
DEFCONFIG="${DEFCONFIG:-redbull_defconfig}"
CLANG_VER="${CLANG_VER:-20}"
KSU_REF="${KSU_REF:-v1.0.5}"          # official KSU: last pre-EOL, susfs-4.19-era tag
KSUNEXT_REF="${KSUNEXT_REF:-legacy}"  # KSU-Next: non-GKI legacy line
PDG_URL="https://github.com/ssut/payload-dumper-go/releases/download/1.3.0/payload-dumper-go_1.3.0_linux_amd64.tar.gz"
AK3_REPO="https://github.com/osm0sis/AnyKernel3"
WS="${GITHUB_WORKSPACE:-$PWD}"

W="$PWD/work"; OUT="$PWD/artifacts"; REJ="$OUT/rejects-$VARIANT"
rm -rf "$W"; mkdir -p "$W" "$OUT" "$REJ"; cd "$W"
LOG="$OUT/build-$VARIANT.log"; : > "$LOG"
fail(){ echo "[FATAL] $*" | tee -a "$LOG"; exit 1; }
note(){ echo "[note] $*" | tee -a "$LOG"; }

echo "::group::1. Latest LineageOS $DEVICE OTA"
curl -fsSL "https://download.lineageos.org/api/v2/devices/${DEVICE}/builds" > builds.json || fail "LOS API"
OTA_URL=$(jq -r 'sort_by(.datetime)|last|.files[]|select(.filename|endswith(".zip"))|.url' builds.json | tail -1)
OTA_NAME=$(jq -r 'sort_by(.datetime)|last|.files[]|select(.filename|endswith(".zip"))|.filename' builds.json | tail -1)
[ -n "$OTA_URL" ] && [ "$OTA_URL" != null ] || fail "no OTA"
OTA_DATE=$(echo "$OTA_NAME" | grep -oE '[0-9]{8}' | head -1); [ -n "$OTA_DATE" ] || OTA_DATE=unknown
note "OTA $OTA_NAME (LOS $OTA_DATE), variant=$VARIANT"
echo "::endgroup::"

echo "::group::2. Toolchain + tools"
sudo apt-get update -qq
sudo apt-get install -y -qq bc bison flex libssl-dev libelf-dev cpio lz4 zip unzip jq \
  binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi >/dev/null
wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- "$CLANG_VER" >/dev/null 2>&1 || true
for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-readelf llvm-ranlib llvm-as; do
  sudo ln -sf "/usr/bin/${t}-${CLANG_VER}" "/usr/local/bin/${t}" 2>/dev/null || true
done
clang --version | head -1
curl -fL "$PDG_URL" | tar xz && chmod +x payload-dumper-go
gh release download -R topjohnwu/Magisk --pattern 'Magisk-v*.apk' --dir . --clobber
unzip -o Magisk-v*.apk 'lib/x86_64/libmagiskboot.so' -d mgsk >/dev/null
cp mgsk/lib/x86_64/libmagiskboot.so magiskboot && chmod +x magiskboot
echo "::endgroup::"

echo "::group::3. OTA boot.img + kernel version"
curl -fL -o ota.zip "$OTA_URL"
unzip -o ota.zip payload.bin >/dev/null
./payload-dumper-go -p boot -o . payload.bin >/dev/null
[ -f boot.img ] || fail "no boot.img"
mkdir -p bx && cp boot.img bx/ && ( cd bx && ../magiskboot unpack boot.img >/dev/null )
VER=$(strings bx/kernel | grep -m1 -oE '4\.19\.[0-9]+-[a-z0-9]+-[a-z0-9]+-g[0-9a-f]{8,}')
[ -n "$VER" ] || fail "cannot read kernel version from OTA"
SHA=$(echo "$VER" | grep -oE 'g[0-9a-f]+$' | sed 's/^g//')
note "OTA kernel $VER (commit $SHA)"
echo "::endgroup::"

echo "::group::4. Clone kernel @ $SHA"
git clone -q "$KERNEL_REPO" kernel
( cd kernel && git fetch -q --depth 1 origin "$SHA" && git checkout -q "$SHA" ) || fail "checkout $SHA"
KROOT="$W/kernel"
echo "::endgroup::"

echo "::group::5. Integrate KSU ($VARIANT)"
cd "$KROOT"
if [ "$VARIANT" = ksu ]; then
  KSU_DIR=KernelSU
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/${KSU_REF}/kernel/setup.sh" | bash -s "$KSU_REF" || note "KSU setup nonzero"
  SUSFS_REMOTE="https://gitlab.com/simonpunk/susfs4ksu"; SUSFS_BRANCH="kernel-4.19"
else
  KSU_DIR=KernelSU-Next
  curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSUNEXT_REF" || note "KSU-Next setup nonzero"
  SUSFS_REMOTE="https://github.com/ShirkNeko/susfs4ksu"; SUSFS_BRANCH="kernel-4.19"
fi
[ -d "$KROOT/$KSU_DIR" ] || note "WARNING: $KSU_DIR not present (setup failed)"
echo "::endgroup::"

echo "::group::6. Manual-hook patch (if committed)"
HOOKP="$WS/patches/manual-hooks-redbull-4.19.patch"
if [ -f "$HOOKP" ]; then
  ( cd "$KROOT" && patch -p1 < "$HOOKP" ) && note "applied manual-hook patch" || note "manual-hook patch had rejects"
else
  note "NO manual-hook patch committed. Non-GKI KSU will compile but NOT hook, so root is non-functional until you add patches/manual-hooks-redbull-4.19.patch. See the guide section 4C."
fi
echo "::endgroup::"

echo "::group::7. Apply SUSFS ($SUSFS_REMOTE@$SUSFS_BRANCH)"
cd "$W"
git clone -q "$SUSFS_REMOTE" susfs -b "$SUSFS_BRANCH" 2>/dev/null \
  || { note "susfs source $SUSFS_REMOTE@$SUSFS_BRANCH unavailable; falling back to simonpunk"; git clone -q https://gitlab.com/simonpunk/susfs4ksu susfs -b kernel-4.19; }
cp ./susfs/kernel_patches/fs/* "$KROOT/fs/" 2>/dev/null || note "no susfs fs/ files"
cp ./susfs/kernel_patches/include/linux/* "$KROOT/include/linux/" 2>/dev/null || note "no susfs include/ files"
cp ./susfs/kernel_patches/50_add_susfs_in_kernel-4.19.patch "$KROOT/" 2>/dev/null || true
( cd "$KROOT" && patch -p1 < 50_add_susfs_in_kernel-4.19.patch ) || note "50_add_susfs had rejects"
cp ./susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "$KROOT/$KSU_DIR/" 2>/dev/null || true
( cd "$KROOT/$KSU_DIR" && patch -p1 < 10_enable_susfs_for_ksu.patch ) || note "10_enable_susfs_for_ksu had rejects (expected on KSU-Next)"
# optional committed reject-fix patches for this variant
if ls "$WS/patches/$VARIANT/"*.patch >/dev/null 2>&1; then
  for p in "$WS/patches/$VARIANT/"*.patch; do ( cd "$KROOT" && patch -p1 < "$p" ) && note "applied $(basename "$p")" || note "reject-fix $(basename "$p") failed"; done
fi
# collect every .rej, preserving relative path
find "$KROOT" -name '*.rej' | while read -r r; do rel="${r#$KROOT/}"; mkdir -p "$REJ/$(dirname "$rel")"; cp "$r" "$REJ/$rel"; done
REJN=$(find "$KROOT" -name '*.rej' | wc -l | tr -d ' ')
note "collected $REJN reject file(s) into artifacts/rejects-$VARIANT/"
echo "::endgroup::"

echo "::group::8. Defconfig"
cd "$KROOT"
make O=out ARCH=arm64 "$DEFCONFIG" >/dev/null || fail "defconfig"
C=./scripts/config; F="--file out/.config"
$C $F -e CONFIG_KSU -e CONFIG_KSU_MANUAL_HOOK -d CONFIG_KSU_KPROBES_HOOK 2>/dev/null || true
$C $F -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_SUS_PATH -e CONFIG_KSU_SUSFS_SUS_MOUNT \
   -e CONFIG_KSU_SUSFS_SUS_KSTAT -e CONFIG_KSU_SUSFS_TRY_UMOUNT -e CONFIG_KSU_SUSFS_SPOOF_UNAME \
   -e CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
   -e CONFIG_KSU_SUSFS_OPEN_REDIRECT -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT -e CONFIG_KSU_SUSFS_ENABLE_LOG 2>/dev/null || true
$C $F -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL -e CONFIG_THINLTO 2>/dev/null || true
sed -i "s/printf '%s' -dirty/printf '%s' ''/g" scripts/setlocalversion 2>/dev/null || true
make O=out ARCH=arm64 LLVM=1 olddefconfig >/dev/null || note "olddefconfig warnings"
grep -E 'CONFIG_KSU=|CONFIG_KSU_SUSFS' out/.config | tee "$OUT/config-$VARIANT.txt" || note "KSU configs not present (patch rejects left them out)"
echo "::endgroup::"

echo "::group::9. kernelrelease gate"
REL=$(make -s O=out ARCH=arm64 kernelrelease 2>/dev/null | tail -1)
echo "kernelrelease=$REL" | tee    "$OUT/kernelrelease-$VARIANT.txt"
echo "ota_version=$VER"   | tee -a "$OUT/kernelrelease-$VARIANT.txt"
[ "$REL" = "$VER" ] && note "kernelrelease MATCHES OTA" || note "WARNING kernelrelease != OTA ($REL vs $VER): do NOT flash"
echo "::endgroup::"

echo "::group::10. Build Image"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
BUILT=0
if make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$(nproc)" Image 2>&1 | tee -a "$LOG"; then
  BUILT=1
else
  note "BUILD FAILED (expected until manual hooks + rejects are resolved). Rejects + log are in artifacts/."
fi
echo "::endgroup::"

echo "::group::11. Package (only if built)"
if [ "$BUILT" = 1 ] && [ -f out/arch/arm64/boot/Image ] && [ "$REL" = "$VER" ]; then
  cp out/arch/arm64/boot/Image "$W/bx/kernel"
  ( cd "$W/bx" && "$W/magiskboot" repack boot.img "$OUT/boot-${VARIANT}-susfs-${OTA_DATE}.img" >/dev/null ) && note "wrote boot-${VARIANT}-susfs-${OTA_DATE}.img" || note "repack failed"
  git clone -q --depth 1 "$AK3_REPO" "$W/ak3" && rm -rf "$W/ak3/.git"
  cp out/arch/arm64/boot/Image "$W/ak3/Image"
  cat > "$W/ak3/anykernel.sh" <<AK
# AnyKernel3 config (redfin, A/B, boot partition)
properties() { '
kernel.string=redfin ${VARIANT}+susfs ${VER}
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
device.name1=redfin
supported.versions=
block=boot;
is_slot_device=1;
ramdisk_compression=auto;
'; }
. tools/ak3-core.sh;
split_boot;
flash_boot;
AK
  ( cd "$W/ak3" && zip -r9 "$OUT/boot-${VARIANT}-susfs.zip" . -x '.git*' >/dev/null ) && note "wrote boot-${VARIANT}-susfs.zip"
else
  note "no flashable output (build not successful or version mismatch); see rejects + log"
fi
echo "::endgroup::"

{ echo "VARIANT=$VARIANT"; echo "OTA_DATE=$OTA_DATE"; echo "VER=$VER"; echo "REL=$REL"; echo "BUILT=$BUILT"; echo "REJECTS=$REJN"; } >> "${GITHUB_ENV:-/dev/null}"
echo "SUMMARY variant=$VARIANT built=$BUILT rejects=$REJN kernelrelease_match=$([ "$REL" = "$VER" ] && echo yes || echo no)"
# exit nonzero when not yet flashable, so CI status reflects reality (artifacts still upload via if: always())
[ "$BUILT" = 1 ] && [ "$REL" = "$VER" ] && exit 0 || exit 3
