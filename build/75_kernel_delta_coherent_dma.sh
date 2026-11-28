#!/usr/bin/env bash
# Linux/WSL build of the Q5 bring-up chain. Never flashes a device.
# Usage: Q5_BUILD_WORK=/fast/linux/path bash build/75_kernel_delta_coherent_dma.sh KERNEL_CHECKOUT BASE_BOOT
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
checkout=$(realpath "${1:?kernel checkout required}")
base_boot=$(realpath "${2:?backed-up Android-v0 MTK boot image required}")
tag=${Q5_KERNEL_TAG:-d39}
case "$tag" in d36|d37|d38|d39|d40|d41|d42|d43|d46) ;; *) echo "Unsupported kernel tag" >&2; exit 1;; esac
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
if [ "$tag" = d43 ]; then
    python3 "$repo/build/test_wifi_mac.py" "$kernel"
fi
if [ "$tag" = d46 ]; then
    # D45/D46 invariant gates (patches/kernel/DELTA-NOTES.md entries — build
    # aborts on any failure; spec .specs/bob-m5-power-audio-spec.md §5.1.1–§5.1.3).
    # (1) the PMIC rstkey→VOLDOWN map is gone from the Q5 board header.
    if grep -q 'define KPD_PMIC_RSTKEY_MAP' "$kernel/arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h"; then
        echo "D45 gate (1): KPD_PMIC_RSTKEY_MAP must be deleted from mtk_kpd.h" >&2; exit 1
    fi
    # (2) fchrkey IRQ enabled with argument 0 only.
    grep -q 'upmu_set_rg_int_en_fchrkey(0);' \
        "$kernel/drivers/misc/mediatek/power/mt6582/pmic_mt6323.c"
    ! grep -q 'upmu_set_rg_int_en_fchrkey(1);' \
        "$kernel/drivers/misc/mediatek/power/mt6582/pmic_mt6323.c"
    # (3) zero '0x166,0x1,0x1,1' register pokes left (PMIC_INIT_SETTING_V1).
    ! grep -q '0x166,0x1,0x1,1' \
        "$kernel/drivers/misc/mediatek/power/mt6582/pmic_mt6323.c"
    # (4) pwrkey enable must remain exactly 1.
    grep -q 'upmu_set_rg_int_en_pwrkey(1);' \
        "$kernel/drivers/misc/mediatek/power/mt6582/pmic_mt6323.c"
    # (5) D39/D22 contract: matrix-slot VOLDOWN keymap + debounce untouched.
    grep -q '\[0\] = KEY_VOLUMEUP' \
        "$kernel/arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h"
    grep -q '\[1\] = KEY_VOLUMEDOWN' \
        "$kernel/arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h"
    grep -q 'define KPD_KEY_DEBOUNCE.*1024' \
        "$kernel/arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h"
    # (6) kpd.c reports keys only from kpd_glitch_work_func: zero
    # input_report_key inside kpd_keymap_handler's body.
    if [ "$(awk '/^static void kpd_keymap_handler\(/{f=1} f&&/^\}/{exit} f{print}' \
              "$kernel/drivers/misc/mediatek/keypad/kpd.c" | grep -c input_report_key || true)" != 0 ]; then
        echo "D45 gate (6): kpd_keymap_handler must not report keys" >&2; exit 1
    fi
    if ! awk '/^static void kpd_glitch_work_func\(/{f=1} f{print} f&&/^\}$/{exit}' \
             "$kernel/drivers/misc/mediatek/keypad/kpd.c" | grep -q input_report_key; then
        echo "D45 gate (6): kpd_glitch_work_func must be the key reporter" >&2; exit 1
    fi
    # D46 invariants: the single hunk and the untouched neighbours.
    grep -q '(HZ/50)' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/gl_kal.c"
    ! grep -q 'HZ/10' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/gl_kal.c"
    grep -q 'wake_up_interruptible(&GlueInfo->waitq);' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/hif/ahb/ahb.c"
    grep -q '"WLAN AHB ISR"' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/gl_init.c"
    grep -q '"WLAN TX THREAD"' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/common/wlan_lib.c"
    grep -q '^HifAhbPltmSuspend($' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/hif/ahb/ahb.c"
    grep -q '^HifAhbPltmResume($' \
        "$kernel/drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/hif/ahb/ahb.c"
    # No config drift for m5: the D45/D46 delta patches must not touch the
    # defconfig layer at hunk level (the built .config JUMP_LABEL/RODATA
    # asserts above cover the outcome side).
    for p in D45-kpd-phantom-storm D46-wlan-ahb-isr-window; do
        if grep -q -- '^--- a/arch/arm/configs/' "$repo/patches/kernel/$p.patch"; then
            echo "D45 gate: $p.patch must not touch arch/arm/configs/" >&2; exit 1
        fi
    done
    grep -q '^CONFIG_MTK_COMBO_CHIP="CONSYS_6582"$' \
        "$kernel/arch/arm/configs/q5_defconfig"
    # G-B2: the kpd glitch-filter host test (runs before the zImage build).
    python3 "$repo/build/test_kpd_filter.py" "$kernel"
fi
export KBUILD_BUILD_USER=codex KBUILD_BUILD_HOST="q5-$tag" KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-26 17:00:00 UTC'
make -C "$kernel" -j"${Q5_JOBS:-12}" ARCH=arm CROSS_COMPILE="$toolchain" O="$work/build" zImage > "$repo/out/$tag-build.log" 2>&1
python3 "$repo/build/repack_live_boot.py" "$base_boot" "$work/build/arch/arm/boot/zImage" "$repo/out/boot-$tag.img"
sha256sum "$repo/out/boot-$tag.img" > "$repo/out/boot-$tag.img.sha256"
echo "Built out/boot-$tag.img; not flashed. D26/D33/D35 diagnostics remain in this bring-up image."
