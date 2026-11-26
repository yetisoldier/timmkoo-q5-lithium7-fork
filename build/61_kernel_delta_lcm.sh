#!/usr/bin/env bash
# 61_kernel_delta_lcm.sh — D18: β + touch + LCM (display fix) → β-touch-lcm build.
#
# Reproduction of the β-touch sequence (D1…D17 via patches/kernel/*) with the
# D18 LCM patch (patches/kernel/D18.patch) applied on top, built into a
# SEPARATE object dir (build-beta-touch-lcm) so the pinned m1b-β and β-touch
# artifacts stay byte-stable and reproducible from 50/60 alone.  Outputs:
#   build-beta-touch-lcm/arch/arm/boot/zImage       — β+touch+LCM kernel
#   out/kernel-parity-beta-touch-lcm.txt            — extended δ-parity (§4.2.8 + D17 + D18)
# (55_repack_boot.sh beta-touch-lcm → out/boot-m1b-beta-touch-lcm.img)
#
# D18 donor + Q5 ground truth: see patches/kernel/D18.patch prologue and
# .specs/forge-d18-report.md.  Donor pins: manifests/kernel-sources.sha256
# (donors/y2linux/kernel/platform/panel.c, donors/lk-q5.bin + the pinned
# lithium decomp whose compiled gc9503v drivers are the port's data source).
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/40_kernel_env.sh"

require_tools make python3 strings patch cmp git sha256sum grep

BUILD_BETA_TOUCH_LCM="${KDIR}/build-beta-touch-lcm"
# pinned byte-integrity of the extracted Q5 firmware header (D17, cf. 60_kernel_delta_touch.sh)
D17_FW_SHA="bae204cb4dd1f6adce804af5fad91e9b3424847bd7a09e7faadacf3effbae680"

# ---------------------------------------------------------------- provenance pins
if [ -d "${REPO_ROOT}/donors" ]; then
  log "donors/ present — asserting kernel-sources pins (drift detection)"
  while read -r want lbl; do
    case "${lbl}" in
      '#'*|'') continue ;;
    esac
    f="${REPO_ROOT}/${lbl}"
    [ -f "${f}" ] || { warn "pin target missing (donor not cloned): ${lbl} — skipping (patches are self-contained)"; continue; }
    got="$(sha_of "${f}")"
    [ "${got}" = "${want}" ] || die "donor drift: ${lbl} sha ${got} != pinned ${want}"
  done < "${KSRC_MANIFEST}"
  log "kernel-sources pins verified where donors are present"
else
  warn "donors/ absent — patches are self-contained; proving build from repo state only"
fi

# ---------------------------------------------------------------- reset reference tree
# identical policy to 50/60; D18 adds the two gc9503v lcm dirs to the rm list
# (new untracked paths from prior runs).
log "resetting reference tree to pristine clone (HEAD $(git -C "${KERNEL_REPO_ROOT}" rev-parse --short HEAD))"
git -C "${KERNEL_REPO_ROOT}" reset --hard HEAD >/dev/null
rm -rf \
  "${KDIR}/arch/arm/mach-mt6582/q5" \
  "${KDIR}/arch/arm/configs/q5_defconfig" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/gc5004_mipi_raw" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi253_yuv" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi704_yuv" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9714af" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9719af" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/inc/DW9719AF.h" \
  "${KDIR}/drivers/input/touchscreen/mediatek/gslX680" \
  "${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_hsd" \
  "${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_boe"
BAD="$(git -C "${KERNEL_REPO_ROOT}" status --porcelain \
  | grep -v -E '^\?\? kernel-3\.10/build-(alpha|beta|beta-touch|beta-touch-lcm|beta-touch-lcm-board2|beta-touch-lcm-board)/$' || true)"
[ -z "${BAD}" ] || die "unexpected reference-tree state:
${BAD}"
log "reference tree pristine (O= build-alpha/build-beta/build-beta-touch/build-beta-touch-lcm preserved)"

# ---------------------------------------------------------------- §4.2 steps 1-2
BOARD_SRC="${KDIR}/arch/arm/mach-mt6582/a106"
BOARD_DST="${KDIR}/arch/arm/mach-mt6582/q5"
rm -rf "${BOARD_DST}"
cp -r "${BOARD_SRC}" "${BOARD_DST}"
rm -f "${KDIR}/arch/arm/configs/q5_defconfig"
cp "${KDIR}/arch/arm/configs/a106_defconfig" "${KDIR}/arch/arm/configs/q5_defconfig"
sed -i 's/^CONFIG_ARCH_MTK_PROJECT="a106"/CONFIG_ARCH_MTK_PROJECT="q5"/' \
  "${KDIR}/arch/arm/configs/q5_defconfig"
grep -q '^CONFIG_ARCH_MTK_PROJECT="q5"' "${KDIR}/arch/arm/configs/q5_defconfig" \
  || die "project rename failed"

# ---------------------------------------------------------------- apply deltas in D-order
# identical to 60 (D1→…→D4→D17) plus D18 last.
PATCH_ORDER=(D1 D2 D8 D9 D10 D11 D12 D13 D14 D4 D17 D18)
mkdir -p \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/gc5004_mipi_raw" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi253_yuv" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi704_yuv" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9714af" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9719af" \
  "${KDIR}/drivers/input/touchscreen/mediatek/gslX680" \
  "${KDIR}/arch/arm/mach-mt6582/q5/touchpanel/gsl_tp" \
  "${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_hsd" \
  "${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_boe"
for pid in "${PATCH_ORDER[@]}"; do
  log "patch: ${pid}"
  (cd "${KDIR}" && patch -p1 --no-backup-if-mismatch --quiet \
    < "${REPO_ROOT}/patches/kernel/${pid}.patch") \
    || die "patch ${pid} failed to apply"
done

log "all patches applied; asserting the modified-tracked-file set"
CHANGED="$(git -C "${KERNEL_REPO_ROOT}" diff --name-only | sed 's|^kernel-3.10/||' | LC_ALL=C sort | tr '\n' ' ')"
WANT="$(printf '%s\n' \
  drivers/input/touchscreen/Kconfig \
  drivers/input/touchscreen/mediatek/Makefile \
  drivers/misc/mediatek/Kconfig.drivers \
  drivers/misc/mediatek/lcm/mt65xx_lcm_list.c \
  drivers/misc/mediatek/imgsensor/inc/kd_imgsensor.h \
  drivers/misc/mediatek/imgsensor/inc/kd_imgsensor_define.h \
  drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.h \
  drivers/misc/mediatek/lens/Makefile | LC_ALL=C sort | tr '\n' ' ')"
[ "${CHANGED}" = "${WANT}" ] \
  || die "unexpected tracked-file changes: got [${CHANGED}] want [${WANT}]"

# pin every delta-applied file's mtime to the commit epoch (determinism, cf. 50/60)
log "pinning delta-file mtimes to commit epoch ${KBUILD_HEAD_EPOCH}"
find "${KDIR}/arch/arm/mach-mt6582/q5" "${KDIR}/arch/arm/configs/q5_defconfig" \
     "${KDIR}/drivers/input/touchscreen/mediatek/gslX680" \
     "${KDIR}/drivers/input/touchscreen/Kconfig" \
     "${KDIR}/drivers/input/touchscreen/mediatek/Makefile" \
     "${KDIR}/drivers/misc/mediatek/lcm/mt65xx_lcm_list.c" \
     "${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_hsd" \
     "${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_boe" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/inc/kd_imgsensor.h" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/inc/kd_imgsensor_define.h" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.h" \
     "${KDIR}/drivers/misc/mediatek/lens/Makefile" \
     "${KDIR}/drivers/misc/mediatek/Kconfig.drivers" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/gc5004_mipi_raw" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi253_yuv" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi704_yuv" \
     "${KDIR}/drivers/misc/mediatek/Makefile.custom" \
     "${KDIR}/drivers/misc/mediatek/video/mt6582/dsi_drv.c" \
     "${KDIR}/drivers/misc/mediatek/video/mt6582/mtkfb.c" \
     "${KDIR}/drivers/misc/mediatek/mmc-host/mt6582/sd.c" \
     "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9714af" \
     "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9719af" \
     -type f -exec touch -d "@${KBUILD_HEAD_EPOCH}" {} + 2>/dev/null || true

# ---------------------------------------------------------------- no-diff delta assertions
cmp -s "${BOARD_DST}/power/cust_battery_meter_table.h" \
       "${BOARD_SRC}/power/cust_battery_meter_table.h" \
  || die "D5 violated: q5 cust_battery_meter_table.h is not a verbatim a106 clone"
cmp -s "${BOARD_DST}/power/cust_charging.h" "${BOARD_SRC}/power/cust_charging.h" \
  || die "D6 violated: q5 cust_charging.h is not a verbatim a106 clone"
grep -q '^CONFIG_MTK_SMART_BATTERY=y$' "${KDIR}/arch/arm/configs/q5_defconfig" \
  || die "D3 violated: SMART_BATTERY not enabled"
for sym in BQ24250 BQ24261 BQ24196 FAN5405 FAN5402 BQ24158 BQ24296 BQ27541 \
           NCP1851 NCP1854 RT9536 SWCHR BQ24160 MAX8971; do
  grep -q "^# CONFIG_MTK_${sym}_SUPPORT is not set$" "${KDIR}/arch/arm/configs/q5_defconfig" \
    || die "D2 violated: ${sym} not explicitly off in q5_defconfig"
done
if ls "${KDIR}"/drivers/misc/mediatek/power/mt6582/bct24157* >/dev/null 2>&1; then
  die "D7 violated: bct24157 sources present"
fi
for f in keypad/mtk_kpd.h dct/dct/inc/cust_kpd.h dct/dct/inc/cust_gpio_usage.h; do
  cmp -s "${BOARD_DST}/${f}" "${BOARD_SRC}/${f}" \
    || die "D15/D16 violated: ${f} deviates from the a106 lineage default"
done
log "D2/D3/D5/D6/D7/D15/D16 invariants asserted (patches/kernel/DELTA-NOTES.md)"

# ---------------------------------------------------------------- D17 invariants
cmp -s "${BOARD_DST}/touchpanel/gsl_tp/tpd_custom_gsl_tp.h" \
       "${BOARD_SRC}/touchpanel/gsl_tp/tpd_custom_gsl_tp.h" 2>/dev/null \
  && die "D17 violated: the a106 board must NOT already carry gsl_tp glue (clone drifted?)"
cmp -s "${BOARD_DST}/dct/dct/inc/cust_gpio_usage.h" \
       "${BOARD_SRC}/dct/dct/inc/cust_gpio_usage.h" || die "D17 violated: touch GPIOs must come unmodified from the a106 lineage"
grep -q '^CONFIG_TOUCHSCREEN_MTK_GSL_TP=y$' "${KDIR}/arch/arm/configs/q5_defconfig" \
  || die "D17 violated: GSL_TP not enabled in q5_defconfig"
# the D17 generated firmware must still be the pinned extraction
fw_sha="$(sha_of "${KDIR}/drivers/input/touchscreen/mediatek/gslX680/gslX680_fw_q5.h")"
[ "${fw_sha}" = "${D17_FW_SHA}" ] || die "D17 violated: extracted fw sha ${fw_sha} != pin ${D17_FW_SHA}"
log "D17 invariants asserted (GSL_TP on, fw bytes pinned)"

# ---------------------------------------------------------------- D18 invariants
# the a106 board must not carry gc9503v glue and the pristine lcm list must not
# reference the ported drivers
! grep -q "gc9503v" "${BOARD_SRC}/lcm/mt65xx_lcm_list.c" 2>/dev/null \
  || die "D18 violated: the pristine a106 lcm list must not already carry gc9503v entries"
lcm_list="${KDIR}/drivers/misc/mediatek/lcm/mt65xx_lcm_list.c"
grep -q 'extern LCM_DRIVER gc9503v_wvga_dsi_vdo_hsd_drv;' "${lcm_list}" \
  || die "D18 violated: hsd extern missing from mt65xx_lcm_list.c"
grep -q 'extern LCM_DRIVER gc9503v_wvga_dsi_vdo_boe_drv;' "${lcm_list}" \
  || die "D18 violated: boe extern missing from mt65xx_lcm_list.c"
grep -q '#if defined(GC9503V_WVGA_DSI_VDO_HSD)' "${lcm_list}" \
  || die "D18 violated: hsd list entry missing from mt65xx_lcm_list.c"
grep -q '#if defined(GC9503V_WVGA_DSI_VDO_BOE)' "${lcm_list}" \
  || die "D18 violated: boe list entry missing from mt65xx_lcm_list.c"
defconfig="${KDIR}/arch/arm/configs/q5_defconfig"
grep -q '^CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo_hsd gc9503v_wvga_dsi_vdo_boe"$' "${defconfig}" \
  || die "D18 violated: q5_defconfig LCM line is not the blob-locked gc9503v pair"
! grep -q 'hx8369b' "${defconfig}" \
  || die "D18 violated: hx8369b still referenced by q5_defconfig"
grep -q '^CONFIG_LCM_HEIGHT="800"$' "${defconfig}" \
  || die "D18 violated: CONFIG_LCM_HEIGHT must stay 800"
grep -q '^CONFIG_LCM_WIDTH="480"$' "${defconfig}" \
  || die "D18 violated: CONFIG_LCM_WIDTH must stay 480"
for d in hsd boe; do
  dir="${KDIR}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_${d}"
  for f in "gc9503v_wvga_dsi_vdo_${d}.c" Makefile; do
    [ -s "${dir}/${f}" ] || die "D18 violated: missing ${dir}/${f}"
  done
  grep -q "\.name           = \"gc9503v_wvga_dsi_vdo_${d}\"" \
    "${dir}/gc9503v_wvga_dsi_vdo_${d}.c" \
    || die "D18 violated: ${d} driver .name is not the LK-matched blob string"
done
log "D18 invariants asserted (gc9503v pair wired, hx8369b unwired, names = LK contract, 480x800 kept)"

# ---------------------------------------------------------------- β-touch-lcm build
mkdir -p "${BUILD_BETA_TOUCH_LCM}"   # kbuild's O= requires the dir to exist on first use
BTLCM_CFG_CHANGING=1
if [ -s "${BUILD_BETA_TOUCH_LCM}/.config" ]; then
  mkdir -p "${SCRATCH}/defconfig-probe-beta-touch-lcm"
  make -C "${KDIR}" ARCH=arm CROSS_COMPILE="${TC}" O="${SCRATCH}/defconfig-probe-beta-touch-lcm" \
    q5_defconfig >/dev/null 2>&1
  cmp -s "${SCRATCH}/defconfig-probe-beta-touch-lcm/.config" "${BUILD_BETA_TOUCH_LCM}/.config" \
    && BTLCM_CFG_CHANGING=0
  rm -rf "${SCRATCH}/defconfig-probe-beta-touch-lcm"
fi
if [ "${BTLCM_CFG_CHANGING}" -eq 0 ]; then
  log "β-touch-lcm build: q5_defconfig unchanged since last run — keeping existing .config"
else
  log "β-touch-lcm build: make q5_defconfig"
  make -C "${KDIR}" ARCH=arm CROSS_COMPILE="${TC}" O="${BUILD_BETA_TOUCH_LCM}" \
    q5_defconfig > "${SCRATCH}/beta-touch-lcm-defconfig.log" 2>&1 \
    || die "q5_defconfig failed — see ${SCRATCH}/beta-touch-lcm-defconfig.log"
fi
# the final .config must carry the D18 selection (kbuild may drop unknown lines)
grep -q '^CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo_hsd gc9503v_wvga_dsi_vdo_boe"$' \
  "${BUILD_BETA_TOUCH_LCM}/.config" \
  || die "D18 violated: CONFIG_CUSTOM_KERNEL_LCM did not survive into .config"
log "β-touch-lcm build: make zImage"
make -C "${KDIR}" -j"$(nproc)" ARCH=arm CROSS_COMPILE="${TC}" CC="${BUILD_CC}" \
  O="${BUILD_BETA_TOUCH_LCM}" zImage > "${SCRATCH}/beta-touch-lcm-zImage.log" 2>&1 \
  || die "β-touch-lcm zImage build failed — see ${SCRATCH}/beta-touch-lcm-zImage.log"

ZIMAGE="${BUILD_BETA_TOUCH_LCM}/arch/arm/boot/zImage"
IMAGE="${BUILD_BETA_TOUCH_LCM}/arch/arm/boot/Image"
[ -s "${ZIMAGE}" ] && [ -s "${IMAGE}" ] || die "β-touch-lcm kernel artifacts missing"
# both LCM objects must have been built and linked into the kernel
for d in hsd boe; do
  o="${BUILD_BETA_TOUCH_LCM}/drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_${d}/built-in.o"
  [ -s "${o}" ] || die "D18 violated: ${o} was not built"
done
log "β-touch-lcm lcm objects present (built-in.o for both variants)"
LCM_ZIMAGE_SHA="$(sha_of "${ZIMAGE}")"
log "β-touch-lcm zImage sha256: ${LCM_ZIMAGE_SHA}"
strings -a "${IMAGE}" > "${SCRATCH}/beta-touch-lcm-strings.txt"
BANNER="$(grep -m1 -a -E '^Linux version 3\.10\.54' "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
[ -n "${BANNER}" ] || die "β-touch-lcm banner missing 3.10.54"
log "β-touch-lcm banner: ${BANNER}"

# ---------------------------------------------------------------- δ-parity (§4.2.8 + D17 + D18)
# single source of truth: regenerate the Lithium strings from the pinned decomp
assert_ksrc_label "${LITHIUM_DECOMP}" "donors/lithium-kernel.decomp"
strings -a "${LITHIUM_DECOMP}" > "${LITHIUM_STRINGS}"

MUST_LCM=(gc9503v_wvga_dsi_vdo_hsd gc9503v_wvga_dsi_vdo_boe 'gc9503v kernel id' 'gc9503v boe')
MUST_TOUCH=(gsl_tp gsl1680 gsl915 gslX680 gsl_alg_id_main gsl_config GSLX680_FW)
MUST_NOT_ALL=(bct24157 MAX17050SW6106 fan5405_config_interface hx8369b)
L_BETA_TOUCH_LCM="$(grep -icE 'battery_meter|\[FGADC\]' "${SCRATCH}/beta-touch-lcm-strings.txt")"

PARITY="${OUT_DIR}/kernel-parity-beta-touch-lcm.txt"
{
  echo "# M1b-β-touch-lcm parity report — §4.2.8 sets + D17 touch + D18 LCM vs Lithium blob 5217dd41…"
  echo "# β-touch-lcm: $(sha_of "${IMAGE}") ($(stat -c%s "${IMAGE}") B Image) / zImage ${LCM_ZIMAGE_SHA}"
  echo "# banner: ${BANNER}"
  echo "# -- D18 must-have (gc9503v LCM; blob side shows the same strings) --"
  for f in "gc9503v_wvga_dsi_vdo_hsd" "gc9503v_wvga_dsi_vdo_boe" "gc9503v" "gc9503v kernel id" "gc9503v boe" hx8369b; do
    printf '%-30s | beta-touch-lcm=%4d | lithium=%s\n' "${f}" \
      "$(grep -ic "${f}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)" \
      "$(grep -ic "${f}" "${LITHIUM_STRINGS}" || true)"
  done
  echo "# -- D17 must-have (touch) --"
  for f in "${MUST_TOUCH[@]}"; do
    printf '%-24s | beta-touch-lcm=%4d | lithium=%s\n' "${f}" \
      "$(grep -ic "${f}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)" \
      "$(grep -ic "${f}" "${LITHIUM_STRINGS}" || true)"
  done
  echo "# -- β-carry-over set (no regression) --"
  for f in gc5004mipiraw hi253yuv hi704yuv dw9714 dw9719 aw87559_pa ccci mali mt6323 \
           mtk-kpd auxadc fan5405 bct24157 MAX17050SW6106 fan5405_config_interface; do
    printf '%-24s | beta-touch-lcm=%4d | lithium=%s\n' "${f}" \
      "$(grep -ic "${f}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)" \
      "$(grep -ic "${f}" "${LITHIUM_STRINGS}" || true)"
  done
  printf '%-24s | beta-touch-lcm=%4d | lithium=%s\n' "battery_meter+[FGADC]" "${L_BETA_TOUCH_LCM}" \
    "$(grep -icE 'battery_meter|\[FGADC\]' "${LITHIUM_STRINGS}" || true)"
} > "${PARITY}"

FAILED=0
for p in "${MUST_LCM[@]}"; do
  n="$(grep -ic "${p}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
  [ "${n}" -gt 0 ] || { warn "D18 MUST-HAVE failed: ${p}"; FAILED=1; }
done
# hx8369b must be gone entirely
n="$(grep -ic 'hx8369b' "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
[ "${n}" -eq 0 ] || { warn "D18 MUST-NOT violated: hx8369b strings present (${n})"; FAILED=1; }
for p in "${MUST_TOUCH[@]}"; do
  n="$(grep -ic "${p}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
  [ "${n}" -gt 0 ] || { warn "D17 MUST-HAVE failed: ${p}"; FAILED=1; }
done
[ "${L_BETA_TOUCH_LCM}" -gt 0 ] || { warn "MUST-HAVE failed: battery_meter/[FGADC]"; FAILED=1; }
for p in gc5004mipiraw hi253yuv hi704yuv dw9714 dw9719 aw87559_pa ccci mali mt6323 mtk-kpd auxadc; do
  n="$(grep -ic "${p}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
  [ "${n}" -gt 0 ] || { warn "β-carry-over lost: ${p}"; FAILED=1; }
done
for p in "${MUST_NOT_ALL[@]}"; do
  n="$(grep -ic "${p}" "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
  [ "${n}" -eq 0 ] || { warn "MUST-NOT violated: ${p} (${n} hits)"; FAILED=1; }
done
n="$(grep -ic 'fan5405_config_interface\|charging_hw_fan5405' "${SCRATCH}/beta-touch-lcm-strings.txt" || true)"
[ "${n}" -eq 0 ] || { warn "fan5405 driver strings present"; FAILED=1; }

log "δ-parity report (β-touch-lcm): ${PARITY}"
[ "${FAILED}" -eq 0 ] || die "β-touch-lcm parity failed (see ${PARITY})"
log "D18 β-touch-lcm build + δ-parity complete (§4.2.8 + D17 + D18 PASS)"
log "next: build/55_repack_boot.sh beta-touch-lcm"
