#!/usr/bin/env bash
# 50_kernel_delta.sh — M1b-β: apply the §3 deltas and build (§4.2).
#
# Reproduction model (idempotent + hash-asserted, hard rule 4):
#   1. reset the reference tree to its pristine clone (git reset --hard + clean,
#      keeping the O= dirs so compiles are incremental and byte-stable);
#   2. recreate board q5 + q5_defconfig per §4.2 steps 1-2 (script-owned steps);
#   3. apply patches/kernel/D*.patch strictly in D-order (one file per D-id);
#   4. assert every no-diff delta invariant (patches/kernel/DELTA-NOTES.md);
#   5. build q5_defconfig+zImage; 6. δ-parity vs the Lithium blob (§4.2.8).
# Donor provenance: manifests/kernel-sources.sha256 pins are asserted when donors/
# is present (drift detection); the patches themselves are self-contained.
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/40_kernel_env.sh"

require_tools make python3 strings patch cmp git sha256sum grep

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
# NOTE: the git repo root is .reference-kernel-3.10.54/ itself (kernel-3.10/ is a
# subdir of it) and arm-eabi-4.8/ is a tracked in-tree toolchain copy. Rather than
# `git clean -e` (whose exclude matching proved unreliable against the O= dirs), do
# reset --hard + explicitly rm the known delta paths, then audit that the ONLY
# remaining untracked entries are the two persistent O= dirs.
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
  | grep -v -E '^\?\? kernel-3\.10/build-(alpha|beta|beta-touch|beta-touch-lcm)/$' || true)"
[ -z "${BAD}" ] || die "unexpected reference-tree state:
${BAD}"
log "reference tree pristine (O= build-alpha/build-beta/build-beta-touch preserved for determinism)"

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
# Defconfig patches first (D1→D2→D8 sequential states; D12 carries the lens
# defconfig hunk after D8), then the source ports. One patch file per D-id.
PATCH_ORDER=(D1 D2 D8 D9 D10 D11 D12 D13 D14 D4)
# The ported driver directories are new (the tree was just reset), so create the
# parent dirs before patch inserts files into them.
mkdir -p \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/gc5004_mipi_raw" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi253_yuv" \
  "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi704_yuv" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9714af" \
  "${KDIR}/drivers/misc/mediatek/lens/mt6582/dw9719af"
for pid in "${PATCH_ORDER[@]}"; do
  log "patch: ${pid}"
  (cd "${KDIR}" && patch -p1 --no-backup-if-mismatch --quiet \
    < "${REPO_ROOT}/patches/kernel/${pid}.patch") \
    || die "patch ${pid} failed to apply"
done

log "all patches applied; asserting the modified-tracked-file set"
CHANGED="$(git -C "${KERNEL_REPO_ROOT}" diff --name-only | sed 's|^kernel-3.10/||' | LC_ALL=C sort | tr '\n' ' ')"
WANT="$(printf '%s\n' \
  drivers/misc/mediatek/Kconfig.drivers \
  drivers/misc/mediatek/imgsensor/inc/kd_imgsensor.h \
  drivers/misc/mediatek/imgsensor/inc/kd_imgsensor_define.h \
  drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.h \
  drivers/misc/mediatek/lens/Makefile | LC_ALL=C sort | tr '\n' ' ')"
[ "${CHANGED}" = "${WANT}" ] \
  || die "unexpected tracked-file changes: got [${CHANGED}] want [${WANT}]"

# Pin every delta-applied file's mtime to the commit epoch: with the persistent
# O= dirs this guarantees make sees no source newer than its objects on re-runs,
# so freshly written files are compiled EXACTLY ONCE and re-runs stay byte-flat.
# (Fresh O-dir builds embed fresh __TIME__ stamps once — documented in the report.)
log "pinning delta-file mtimes to commit epoch ${KBUILD_HEAD_EPOCH}"
find "${KDIR}/arch/arm/mach-mt6582/q5" "${KDIR}/arch/arm/configs/q5_defconfig" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/inc/kd_imgsensor.h" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/inc/kd_imgsensor_define.h" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.h" \
     "${KDIR}/drivers/misc/mediatek/lens/Makefile" \
     "${KDIR}/drivers/misc/mediatek/Kconfig.drivers" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/gc5004_mipi_raw" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi253_yuv" \
     "${KDIR}/drivers/misc/mediatek/imgsensor/src/mt6582/hi704_yuv" \
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
# D7 = NO bct24157 port (chip absent on Mint hardware; §2.1/§3.2). The fan5405*.c
# files are the reference tree's own sources (present in the pristine clone, never
# ported from outside) — D1 un-compiles them, proven by the δ-parity strings.
if ls "${KDIR}"/drivers/misc/mediatek/power/mt6582/bct24157* >/dev/null 2>&1; then
  die "D7 violated: bct24157 sources present"
fi
for f in keypad/mtk_kpd.h dct/dct/inc/cust_kpd.h dct/dct/inc/cust_gpio_usage.h; do
  cmp -s "${BOARD_DST}/${f}" "${BOARD_SRC}/${f}" \
    || die "D15/D16 violated: ${f} deviates from the a106 lineage default"
done
log "D2/D3/D5/D6/D7/D15/D16 invariants asserted (patches/kernel/DELTA-NOTES.md)"
log "D1/D8 applied (defconfig), D9-D14 applied (sources)"

# ---------------------------------------------------------------- β build
# same determinism model as 45: skip the defconfig rewrite when unchanged (the
# rewrite re-runs the MTK cust-header generators and churns __TIME__/__DATE__
# stamps in vendor drivers even though the banner is pinned).
mkdir -p "${BUILD_BETA}"   # kbuild's O= requires the dir to exist on first use
BETA_CFG_CHANGING=1
if [ -s "${BUILD_BETA}/.config" ]; then
  mkdir -p "${SCRATCH}/defconfig-probe-beta"
  make -C "${KDIR}" ARCH=arm CROSS_COMPILE="${TC}" O="${SCRATCH}/defconfig-probe-beta" \
    q5_defconfig >/dev/null 2>&1
  cmp -s "${SCRATCH}/defconfig-probe-beta/.config" "${BUILD_BETA}/.config" \
    && BETA_CFG_CHANGING=0
  rm -rf "${SCRATCH}/defconfig-probe-beta"
fi
if [ "${BETA_CFG_CHANGING}" -eq 0 ]; then
  log "β build: q5_defconfig unchanged since last run — keeping existing .config"
else
  log "β build: make q5_defconfig"
  make -C "${KDIR}" ARCH=arm CROSS_COMPILE="${TC}" O="${BUILD_BETA}" \
    q5_defconfig > "${SCRATCH}/beta-defconfig.log" 2>&1 \
    || die "q5_defconfig failed — see ${SCRATCH}/beta-defconfig.log"
fi
log "β build: make zImage"
make -C "${KDIR}" -j"$(nproc)" ARCH=arm CROSS_COMPILE="${TC}" CC="${BUILD_CC}" \
  O="${BUILD_BETA}" zImage > "${SCRATCH}/beta-zImage.log" 2>&1 \
  || die "β zImage build failed — see ${SCRATCH}/beta-zImage.log"

ZIMAGE="${BUILD_BETA}/arch/arm/boot/zImage"
IMAGE="${BUILD_BETA}/arch/arm/boot/Image"
[ -s "${ZIMAGE}" ] && [ -s "${IMAGE}" ] || die "β kernel artifacts missing"
BETA_ZIMAGE_SHA="$(sha_of "${ZIMAGE}")"
log "β zImage sha256: ${BETA_ZIMAGE_SHA}"
strings -a "${IMAGE}" > "${SCRATCH}/beta-strings.txt"
BANNER="$(grep -m1 -a -E '^Linux version 3\.10\.54' "${SCRATCH}/beta-strings.txt" || true)"
[ -n "${BANNER}" ] || die "β banner missing 3.10.54"
log "β banner: ${BANNER}"

# ---------------------------------------------------------------- δ-parity (§4.2.8)
# single source of truth: regenerate the Lithium strings from the pinned decomp
assert_ksrc_label "${LITHIUM_DECOMP}" "donors/lithium-kernel.decomp"
strings -a "${LITHIUM_DECOMP}" > "${LITHIUM_STRINGS}"

MUST_BETA=(gc5004mipiraw hi253yuv hi704yuv dw9714 dw9719 aw87559_pa)
MUST_NOT_BETA=(bct24157 MAX17050SW6106 fan5405_config_interface)
BM_BETA="$(grep -icE 'battery_meter|\[FGADC\]' "${SCRATCH}/beta-strings.txt")"

PARITY="${OUT_DIR}/kernel-parity-beta.txt"
{
  echo "# M1b-β parity report — §4.2.8 string sets vs Lithium blob 5217dd41…"
  echo "# β: $(sha_of "${IMAGE}") ($(stat -c%s "${IMAGE}") B Image) / zImage ${BETA_ZIMAGE_SHA}"
  echo "# banner: ${BANNER}"
  for f in gc5004mipiraw hi253yuv hi704yuv dw9714 dw9719 aw87559_pa ccci mali mt6323 \
           mtk-kpd auxadc fan5405 bct24157 MAX17050SW6106 fan5405_config_interface; do
    printf '%-24s | beta=%4d | lithium=%s\n' "${f}" \
      "$(grep -ic "${f}" "${SCRATCH}/beta-strings.txt" || true)" \
      "$(grep -ic "${f}" "${LITHIUM_STRINGS}" || true)"
  done
  printf '%-24s | beta=%4d | lithium=%s\n' "battery_meter+[FGADC]" "${BM_BETA}" \
    "$(grep -icE 'battery_meter|\[FGADC\]' "${LITHIUM_STRINGS}" || true)"
} > "${PARITY}"

FAILED=0
for p in "${MUST_BETA[@]}"; do
  n="$(grep -ic "${p}" "${SCRATCH}/beta-strings.txt" || true)"
  [ "${n}" -gt 0 ] || { warn "§4.2.8 MUST-HAVE failed: ${p}"; FAILED=1; }
done
[ "${BM_BETA}" -gt 0 ] || { warn "§4.2.8 MUST-HAVE failed: battery_meter/[FGADC]"; FAILED=1; }
for p in "${MUST_NOT_BETA[@]}"; do
  n="$(grep -ic "${p}" "${SCRATCH}/beta-strings.txt" || true)"
  [ "${n}" -eq 0 ] || { warn "§4.2.8 MUST-NOT violated: ${p} (${n} hits)"; FAILED=1; }
done
# the fan5405 panic string in drivers/power/mediatek/battery_common.c is generic
# vendor code (Lithium's own blob carries it too) — only the DRIVER must be gone:
n="$(grep -ic 'fan5405_config_interface\|charging_hw_fan5405' "${SCRATCH}/beta-strings.txt" || true)"
[ "${n}" -eq 0 ] || { warn "§4.2.8 fan5405 driver strings present"; FAILED=1; }

log "δ-parity report: ${PARITY}"
[ "${FAILED}" -eq 0 ] || die "β parity failed (see ${PARITY})"
log "M1b-β build + δ-parity complete (§4.2.8 PASS)"
