#!/usr/bin/env bash
# Build a KernelSU-Next + SUSFS redfin kernel for the latest LineageOS OTA, using
# crDroid's proven redbull integration (KSU-Next v1.1.1 + SUSFS v1.5.7).
#
# Why this is clean: crDroid maintains this exact integration for the redbull 4.19
# kernel. Their two patches apply to the LineageOS tree with zero rejects (verified
# locally), so we just reproduce them here. Official KSU was dropped: its SELinux code
# needs the 4.19 global `policydb`, which is static/unexported on this kernel.
#
#   patches/ksunext/0001-ksun-v1.1.1-susfs.patch     -> applied INSIDE KernelSU-Next
#   patches/ksunext/0002-crdroid-kernelside-susfs.patch -> applied at the kernel root
set -uo pipefail

DEVICE="${DEVICE:-redfin}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_google_redbull}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-23.2}"
DEFCONFIG="${DEFCONFIG:-redbull_defconfig}"
CLANG_VER="${CLANG_VER:-20}"
KSUNEXT_REF="${KSUNEXT_REF:-v1.1.1}"   # version crDroid's patches target
PDG_URL="https://github.com/ssut/payload-dumper-go/releases/download/1.3.0/payload-dumper-go_1.3.0_linux_amd64.tar.gz"
AK3_REPO="https://github.com/osm0sis/AnyKernel3"
WS="${GITHUB_WORKSPACE:-$PWD}"

W="$PWD/work"; OUT="$PWD/artifacts"; REJ="$OUT/rejects"
rm -rf "$W"; mkdir -p "$W" "$OUT" "$REJ"; cd "$W"
LOG="$OUT/build.log"; : > "$LOG"
fail(){ echo "[FATAL] $*" | tee -a "$LOG"; exit 1; }
note(){ echo "[note] $*" | tee -a "$LOG"; }

echo "::group::1. Latest LineageOS $DEVICE OTA"
curl -fsSL "https://download.lineageos.org/api/v2/devices/${DEVICE}/builds" > builds.json || fail "LOS API"
OTA_URL=$(jq -r 'sort_by(.datetime)|last|.files[]|select(.filename|endswith(".zip"))|.url' builds.json | tail -1)
OTA_NAME=$(jq -r 'sort_by(.datetime)|last|.files[]|select(.filename|endswith(".zip"))|.filename' builds.json | tail -1)
[ -n "$OTA_URL" ] && [ "$OTA_URL" != null ] || fail "no OTA"
OTA_DATE=$(echo "$OTA_NAME" | grep -oE '[0-9]{8}' | head -1); [ -n "$OTA_DATE" ] || OTA_DATE=unknown
TAG="ksunext-susfs-${OTA_DATE}"
note "OTA $OTA_NAME (LOS $OTA_DATE)"
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
git init -q kernel
( cd kernel
  git remote add origin "$KERNEL_REPO"
  git fetch -q --depth 1 origin "$SHA" || git fetch -q --depth 200 origin "$KERNEL_BRANCH"
  git checkout -q "$SHA"
) || fail "checkout $SHA"
KROOT="$W/kernel"
echo "::endgroup::"

echo "::group::5. KernelSU-Next $KSUNEXT_REF + crDroid SUSFS"
cd "$KROOT"
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSUNEXT_REF" || note "KSU-Next setup returned nonzero"
[ -d "$KROOT/KernelSU-Next" ] || fail "KernelSU-Next not present (setup failed)"
# crDroid KSU-Next-side SUSFS integration (paths relative to KernelSU-Next root)
( cd KernelSU-Next && patch -p1 < "$WS/patches/ksunext/0001-ksun-v1.1.1-susfs.patch" ) || note "0001 ksun susfs patch had rejects"
# crDroid kernel-side SUSFS + manual hooks (paths relative to kernel root)
patch -p1 < "$WS/patches/ksunext/0002-crdroid-kernelside-susfs.patch" || note "0002 kernel-side susfs had rejects"
find "$KROOT" -name '*.rej' | while read -r r; do rel="${r#$KROOT/}"; mkdir -p "$REJ/$(dirname "$rel")"; cp "$r" "$REJ/$rel"; done
REJN=$(find "$KROOT" -name '*.rej' | wc -l | tr -d ' ')
note "rejects after crDroid patches: $REJN"
echo "::endgroup::"

echo "::group::6. Defconfig"
cd "$KROOT"
make O=out ARCH=arm64 "$DEFCONFIG" >/dev/null || fail "defconfig"
C=./scripts/config; F="--file out/.config"
$C $F -e CONFIG_KSU 2>/dev/null || true
# full SUSFS set (crDroid's kernel-side integration handles SUS_MOUNT on this tree)
$C $F -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_SUS_PATH -e CONFIG_KSU_SUSFS_SUS_MOUNT \
   -e CONFIG_KSU_SUSFS_SUS_KSTAT -e CONFIG_KSU_SUSFS_TRY_UMOUNT -e CONFIG_KSU_SUSFS_SPOOF_UNAME \
   -e CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
   -e CONFIG_KSU_SUSFS_OPEN_REDIRECT -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT -e CONFIG_KSU_SUSFS_ENABLE_LOG 2>/dev/null || true
$C $F -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL -e CONFIG_THINLTO 2>/dev/null || true
sed -i "s/printf '%s' -dirty/printf '%s' ''/g" scripts/setlocalversion 2>/dev/null || true
make O=out ARCH=arm64 LLVM=1 olddefconfig >/dev/null || note "olddefconfig warnings"
grep -E 'CONFIG_KSU=|CONFIG_KSU_SUSFS' out/.config | tee "$OUT/config.txt" || note "KSU configs missing"
echo "::endgroup::"

echo "::group::7. kernelrelease gate"
REL=$(make -s O=out ARCH=arm64 kernelrelease 2>/dev/null | tail -1)
{ echo "kernelrelease=$REL"; echo "ota_version=$VER"; } | tee "$OUT/kernelrelease.txt"
[ "$REL" = "$VER" ] && note "kernelrelease MATCHES OTA" || note "WARNING kernelrelease != OTA ($REL vs $VER): do NOT flash"
echo "::endgroup::"

echo "::group::8. Build Image"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
BUILT=0
if make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$(nproc)" Image 2>&1 | tee -a "$LOG"; then BUILT=1; else note "BUILD FAILED; see build.log + rejects"; fi
echo "::endgroup::"

echo "::group::9. Package (only if built and version matches)"
if [ "$BUILT" = 1 ] && [ -f out/arch/arm64/boot/Image ] && [ "$REL" = "$VER" ]; then
  cp out/arch/arm64/boot/Image "$W/bx/kernel"
  ( cd "$W/bx" && "$W/magiskboot" repack boot.img "$OUT/boot-ksunext-susfs-${OTA_DATE}.img" >/dev/null ) && note "wrote boot-ksunext-susfs-${OTA_DATE}.img" || note "repack failed"
  git clone -q --depth 1 "$AK3_REPO" "$W/ak3" && rm -rf "$W/ak3/.git"
  cp out/arch/arm64/boot/Image "$W/ak3/Image"
  cat > "$W/ak3/anykernel.sh" <<AK
properties() { '
kernel.string=redfin KSU-Next+SUSFS ${VER}
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
  ( cd "$W/ak3" && zip -r9 "$OUT/boot-ksunext-susfs-${OTA_DATE}.zip" . -x '.git*' >/dev/null ) && note "wrote boot-ksunext-susfs-${OTA_DATE}.zip"
else
  note "no flashable output (build failed or version mismatch); see rejects + build.log"
fi
echo "::endgroup::"

{ echo "TAG=$TAG"; echo "OTA_DATE=$OTA_DATE"; echo "OTA_NAME=$OTA_NAME"; echo "VER=$VER"; echo "REL=$REL"; echo "BUILT=$BUILT"; echo "REJECTS=$REJN"; } >> "${GITHUB_ENV:-/dev/null}"
echo "SUMMARY built=$BUILT rejects=$REJN kernelrelease_match=$([ "$REL" = "$VER" ] && echo yes || echo no)"
[ "$BUILT" = 1 ] && [ "$REL" = "$VER" ] && exit 0 || exit 3
