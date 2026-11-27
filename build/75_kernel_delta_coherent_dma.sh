#!/usr/bin/env bash
# Linux/WSL build of the Q5 bring-up chain. Never flashes a device.
# Usage: Q5_BUILD_WORK=/fast/linux/path bash build/75_kernel_delta_coherent_dma.sh KERNEL_CHECKOUT BASE_BOOT
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
checkout=$(realpath "${1:?kernel checkout required}")
base_boot=$(realpath "${2:?backed-up Android-v0 MTK boot image required}")
tag=${Q5_KERNEL_TAG:-d39}
case "$tag" in d36|d37|d38|d39|d40|d41|d42) ;; *) echo "Unsupported kernel tag" >&2; exit 1;; esac
work=${Q5_BUILD_WORK:-"$repo/work/$tag"}
mkdir -p "$repo/out"
python3 "$repo/build/prepare_kernel.py" "$checkout" "$work" --series "$repo/build/kernel-$tag.series" > "$repo/out/$tag-prepare.log"
kernel="$work/source/kernel-3.10"
toolchain="$checkout/arm-eabi-4.8/bin/arm-eabi-"
"${toolchain}gcc" --version | head -1
mkdir -p "$work/build"
make -C "$kernel" ARCH=arm CROSS_COMPILE="$toolchain" O="$work/build" q5_defconfig > "$repo/out/$tag-config.log" 2>&1
if [ "$tag" != d36 ] && [ "$tag" != d37 ]; then
    grep -q '^# CONFIG_JUMP_LABEL is not set$' "$work/build/.config"
    grep -q '^CONFIG_DEBUG_RODATA=y$' "$work/build/.config"
fi
if [ "$tag" != d36 ] && [ "$tag" != d37 ] && [ "$tag" != d38 ]; then
    python3 "$repo/build/test_touch_key_protocol.py" "$kernel"
else
    python3 "$repo/build/test_touch_key_protocol.py" "$kernel" --legacy-reporting
fi
export KBUILD_BUILD_USER=codex KBUILD_BUILD_HOST="q5-$tag" KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-26 17:00:00 UTC'
make -C "$kernel" -j"${Q5_JOBS:-12}" ARCH=arm CROSS_COMPILE="$toolchain" O="$work/build" zImage > "$repo/out/$tag-build.log" 2>&1
python3 "$repo/build/repack_live_boot.py" "$base_boot" "$work/build/arch/arm/boot/zImage" "$repo/out/boot-$tag.img"
sha256sum "$repo/out/boot-$tag.img" > "$repo/out/boot-$tag.img.sha256"
echo "Built out/boot-$tag.img; not flashed. D26/D33/D35 diagnostics remain in this bring-up image."
