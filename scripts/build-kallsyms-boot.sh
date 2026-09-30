#!/usr/bin/env bash
# Build a KALLSYMS_ALL Pixel 5 (redfin) kernel that matches a LineageOS OTA
# (BUILD_OFFSET picks which one: 0 = newest, 1 = previous, ...), swap it into that
# OTA's boot.img, and publish a ready-to-flash boot.img.
#
# Why this works (module-safe): we build from the EXACT kernel commit the OTA used,
# with LineageOS's own redbull_defconfig, changing ONLY CONFIG_KALLSYMS_ALL=y
# (keeps CFI+LTO+MODVERSIONS and the exact version string), so the OTA's 329 vendor
# modules still load. See README.
set -euo pipefail

DEVICE="${DEVICE:-redfin}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_google_redbull}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-23.2}"
DEFCONFIG="${DEFCONFIG:-redbull_defconfig}"
CLANG_VER="${CLANG_VER:-20}"
# pinned third-party tool (review/bump if it 404s). magiskboot is pulled from the
# official Magisk APK at build time (see below), so it isn't pinned here.
PDG_URL="https://github.com/ssut/payload-dumper-go/releases/download/1.3.0/payload-dumper-go_1.3.0_linux_amd64.tar.gz"

W="$PWD/work"; OUT="$PWD/artifacts"; rm -rf "$W" "$OUT"; mkdir -p "$W" "$OUT"; cd "$W"

OFFSET="${BUILD_OFFSET:-0}"
echo "::group::1. Find LineageOS $DEVICE OTA (offset $OFFSET, where 0 = newest)"
curl -fsSL "https://download.lineageos.org/api/v2/devices/${DEVICE}/builds" > builds.json
# builds sorted oldest-first; pick the OFFSET-th from the newest end
BUILD=$(jq -c --argjson off "$OFFSET" 'sort_by(.datetime) | .[-1 - $off] // empty' builds.json)
[ -n "$BUILD" ] || { echo "no build at offset $OFFSET (fewer builds available); nothing to do"; echo "SKIP=1" >> "${GITHUB_ENV:-/dev/null}"; exit 0; }
OTA_URL=$(echo "$BUILD" | jq -r '.files[]|select(.filename|endswith(".zip"))|.url' | tail -1)
OTA_NAME=$(echo "$BUILD" | jq -r '.files[]|select(.filename|endswith(".zip"))|.filename' | tail -1)
[ -n "$OTA_URL" ] && [ "$OTA_URL" != "null" ] || { echo "no OTA zip in build at offset $OFFSET"; exit 1; }
OTA_DATE=$(echo "$OTA_NAME" | grep -oE '[0-9]{8}' | head -1); [ -n "$OTA_DATE" ] || OTA_DATE=$(date +%Y%m%d)
TAG="los-${OTA_DATE}"
echo "OTA: $OTA_NAME  (LineageOS release ${OTA_DATE}, tag ${TAG})"
# One release per LineageOS build: skip early if this OTA is already done (before the big download/build).
if gh release view "$TAG" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Already built for LOS ${OTA_DATE} (${TAG}); nothing to do."
  echo "SKIP=1" >> "${GITHUB_ENV:-/dev/null}"; exit 0
fi
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
[ -x ./payload-dumper-go ] || { echo "failed to obtain payload-dumper-go"; exit 1; }
# magiskboot: static x86_64 binary from the OFFICIAL Magisk APK. Magisk's native tools
# are static ELFs, so they run on the Linux runner (Android shares the Linux syscall
# ABI). Always available + self-updating, unlike a pinned third-party prebuilt.
gh release download -R topjohnwu/Magisk --pattern 'Magisk-v*.apk' --dir . --clobber
unzip -o Magisk-v*.apk 'lib/x86_64/libmagiskboot.so' -d mgsk >/dev/null
cp mgsk/lib/x86_64/libmagiskboot.so magiskboot && chmod +x magiskboot
[ -x ./magiskboot ] || { echo "failed to obtain magiskboot from Magisk APK"; exit 1; }
echo "::endgroup::"

echo "::group::3. Download OTA + extract stock boot.img"
curl -fL -o ota.zip "$OTA_URL"
unzip -o ota.zip payload.bin >/dev/null
./payload-dumper-go -p boot -o . payload.bin >/dev/null
[ -f boot.img ] || { echo "boot.img not extracted"; exit 1; }
echo "::endgroup::"

echo "::group::4. Read OTA kernel version + commit"
mkdir -p bx && cp boot.img bx/ && ( cd bx && ../magiskboot unpack boot.img >/dev/null )
VER=$(strings bx/kernel 2>/dev/null | grep -m1 -oE '4\.19\.[0-9]+-[a-z0-9]+-[a-z0-9]+-g[0-9a-f]{8,}')
[ -n "$VER" ] || { echo "could not read kernel version from OTA"; exit 1; }
SHA=$(echo "$VER" | grep -oE 'g[0-9a-f]+$' | sed 's/^g//')
echo "OTA kernel: $VER  (commit ${SHA}, LOS release ${OTA_DATE}, tag ${TAG})"
echo "::endgroup::"

echo "::group::5. Clone kernel @ $SHA and build KALLSYMS_ALL"
git init -q kernel && ( cd kernel
  git remote add origin "$KERNEL_REPO"
  git fetch -q --depth 1 origin "$SHA" || git fetch -q --depth 200 origin "$KERNEL_BRANCH"
  git checkout -q "$SHA"
  export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 \
         CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  make O=out ARCH=arm64 "$DEFCONFIG" >/dev/null
  ./scripts/config --file out/.config -e CONFIG_KALLSYMS_ALL -e CONFIG_THINLTO
  make O=out ARCH=arm64 LLVM=1 olddefconfig >/dev/null
  REL=$(make -s O=out ARCH=arm64 kernelrelease | tail -1)
  echo "built kernelrelease: $REL"
  # SAFETY GATE: must match the OTA exactly, or vendor modules won't load, so do NOT publish.
  [ "$REL" = "$VER" ] || { echo "FATAL version mismatch: '$REL' != '$VER'"; exit 2; }
  grep -q '^CONFIG_KALLSYMS_ALL=y' out/.config || { echo "KALLSYMS_ALL missing"; exit 2; }
  make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$(nproc)" Image
  N=$(llvm-nm out/vmlinux | awk '{print $2}' | grep -ciE '^[dbr]'); echo "data symbols: $N"
  [ "$N" -gt 1000 ] || { echo "KALLSYMS_ALL not effective"; exit 2; }
)
echo "::endgroup::"

echo "::group::6. Swap kernel into OTA boot.img"
cp kernel/out/arch/arm64/boot/Image bx/kernel
( cd bx && ../magiskboot repack boot.img "$OUT/boot-kallsyms-${VER}.img" >/dev/null )
ls -la "$OUT"
{
  echo "TAG=$TAG"
  echo "VER=$VER"
  echo "OTA_NAME=$OTA_NAME"
  echo "OTA_DATE=$OTA_DATE"
  echo "BOOT_IMG=boot-kallsyms-${VER}.img"
} >> "${GITHUB_ENV:-/dev/null}"
echo "::endgroup::"
