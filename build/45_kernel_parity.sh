#!/usr/bin/env bash
# 45_kernel_parity.sh — M1b-α: stock a106_defconfig build + parity check (§4.1).
#
# Builds the untouched reference tree with the in-tree arm-eabi-4.8 toolchain
# into an isolated object dir, then compares the driver-name string inventory
# of the resulting blob against Bob's Lithium-blob strings (§3.2-B.10 surface).
#
# Parity gate (§4.1.2): ccci/mali/mt6323/mtk-kpd/auxadc/battery meter MUST be
# present; aw87559_pa/DW9714AF/DW9719AF/Mint sensors MUST be absent at α.
# GAP-1: gsl_tp is asserted as WARN (the chosen tree carries no GSL touch
# driver at all — see .specs/forge-m1b-report.md §1.4; not fixable inside α).
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/40_kernel_env.sh"

require_tools make python3 strings sha256sum grep awk tail stat

# ---------------------------------------------------------------- sanity
grep -q 'SUBLEVEL = 54' "${KDIR}/Makefile" \
  || die "kernel Makefile is not 3.10.54 — wrong reference tree"
[ -x "${TC}gcc" ] || die "toolchain missing at ${TC}"
("${TC}gcc" --version 2>/dev/null | head -1) | grep -q '4\.8' \
  || die "arm-eabi-gcc is not 4.8"
mkdir -p "${BUILD_ALPHA}" "${OUT_DIR}" "${SCRATCH}"

# ---------------------------------------------------------------- α build
# Spec §4.1.1 flow: `make a106_defconfig && make zImage`. Rerunning the
# defconfig regenerates MTK cust headers and relinks drivers embedding
# __DATE__/__TIME__ stamps (wlan/ccci/mali) — churning the blob bytes while
# the banner stays pinned. So: skip the defconfig step when .config is
# unchanged (probe-build into a scratch dir), keeping re-runs byte-identical.
# A fresh O-dir build embeds fresh stamp values once — noted in the report.
CONFIG_UNCHANGED=0
if [ -s "${BUILD_ALPHA}/.config" ]; then
  mkdir -p "${SCRATCH}/defconfig-probe"
  make -C "${KDIR}" ARCH=arm CROSS_COMPILE="${TC}" \
    O="${SCRATCH}/defconfig-probe" a106_defconfig >/dev/null 2>&1
  if cmp -s "${SCRATCH}/defconfig-probe/.config" "${BUILD_ALPHA}/.config"; then
    CONFIG_UNCHANGED=1
  fi
  rm -rf "${SCRATCH}/defconfig-probe"
fi
if [ "${CONFIG_UNCHANGED}" -eq 1 ]; then
  log "α build: a106_defconfig unchanged since last run — keeping existing .config"
else
  log "α build: make a106_defconfig (O=build-alpha)"
  make -C "${KDIR}" ARCH=arm CROSS_COMPILE="${TC}" O="${BUILD_ALPHA}" \
    a106_defconfig > "${SCRATCH}/alpha-defconfig.log" 2>&1 \
    || die "a106_defconfig failed — see ${SCRATCH}/alpha-defconfig.log"
fi

log "α build: make zImage"
make -C "${KDIR}" -j"$(nproc)" ARCH=arm CROSS_COMPILE="${TC}" CC="${BUILD_CC}" \
  O="${BUILD_ALPHA}" zImage > "${SCRATCH}/alpha-zImage.log" 2>&1 \
  || die "zImage build failed — see ${SCRATCH}/alpha-zImage.log"

ZIMAGE="${BUILD_ALPHA}/arch/arm/boot/zImage"
IMAGE="${BUILD_ALPHA}/arch/arm/boot/Image"
[ -s "${ZIMAGE}" ] || die "zImage not produced"
[ -s "${IMAGE}" ] || die "Image (piggy) not produced — required for parity strings"

ALPHA_ZIMAGE_SHA="$(sha_of "${ZIMAGE}")"
ALPHA_IMAGE_SHA="$(sha_of "${IMAGE}")"
log "α zImage sha256: ${ALPHA_ZIMAGE_SHA}"

# Build banner: Linux version 3.10.54 straight from the strings file (grep the
# file, never a pipe through grep -m1: pipefail turns grep's SIGPIPE upstream
# into a spurious failure, and byte counts stay huge — 13.9 MB Image).
strings -a "${IMAGE}" > "${SCRATCH}/alpha-strings.txt"
BANNER="$(grep -m1 -E '^Linux version 3\.10\.54' "${SCRATCH}/alpha-strings.txt" || true)"
[ -n "${BANNER}" ] || die "kernel banner does not say 'Linux version 3.10.54'"
log "α banner: ${BANNER}"

# ---------------------------------------------------------------- parity
# Bob's Lithium comparison blob must still be the pinned one; derive the
# comparison strings from it so the counts never depend on scratch edits.
assert_ksrc_label "${LITHIUM_DECOMP}" "donors/lithium-kernel.decomp"
strings -a "${LITHIUM_DECOMP}" > "${LITHIUM_STRINGS}"

A_STR="${SCRATCH}/alpha-strings.txt"

# grep-line-hit counting against the pinned Lithium strings inventory.
hits() { grep -ic "$2" "$1" || true; }
A_STR="${SCRATCH}/alpha-strings.txt"

MUST_PRESENT="ccci mali mt6323 mtk-kpd auxadc"
# battery_meter + FGADC share one check (SW fuel-gauge family must exist)
BM_A="$(grep -icE 'battery_meter|\[FGADC\]' "${A_STR}")"
BM_L="$(grep -icE 'battery_meter|\[FGADC\]' "${LITHIUM_STRINGS}")"

# NOTE: IFS is '\n\t' (set -u era conventions) — space-separated for-loops must use
# literal lists or arrays, never unquoted $VAR strings.
PARITY="${OUT_DIR}/kernel-parity-alpha.txt"
{
  echo "# M1b-α parity report — strings inventory vs Lithium blob 5217dd41…"
  echo "# α: $(sha_of "${IMAGE}") ($(stat -c%s "${IMAGE}") B Image) / zImage $(sha_of "${ZIMAGE}")"
  echo "# banner: ${BANNER}"
  echo "# NOTE: fresh rebuilds differ from this run only inside vendor driver"
  echo "# __DATE__/__TIME__ build stamps (wlan/ccci/mali) and their XZ-compressed"
  echo "# descendants; the driver-name inventory below is rebuild-invariant."
  echo "# table: family | alpha-hits | lithium-hits | verdict"
  for f in "ccci" "mali" "mt6323" "gsl_tp" "mtk-kpd" "auxadc" "fan5405" "bct24157" \
           "MAX17050SW6106" "aw87559_pa" "dw9714" "dw9719" "gc5004mipiraw" \
           "hi253yuv" "hi704yuv" "hi258" "ov5648"; do
    printf '%-16s | %5d | %5d | %s\n' "${f}" \
      "$(hits "${A_STR}" "${f}")" "$(hits "${LITHIUM_STRINGS}" "${f}")" "info"
  done
  printf '%-16s | %5d | %5d | %s\n' "batt_meter+FGADC" "${BM_A}" "${BM_L}" "info"
} > "${PARITY}"

FAILED=0
for f in "ccci" "mali" "mt6323" "mtk-kpd" "auxadc"; do
  n="$(hits "${A_STR}" "${f}")"
  [ "${n}" -gt 0 ] || { warn "§4.1.2 MUST-PRESENT failed in α: ${f}"; FAILED=1; }
done
[ "${BM_A}" -gt 0 ] || { warn "§4.1.2 MUST-PRESENT failed: battery_meter/FGADC"; FAILED=1; }
# GAP-1: gsl_tp cannot be satisfied by this tree (no GSL driver exists — §1.4).
n="$(hits "${A_STR}" "gsl_tp")"
if [ "${n}" -eq 0 ]; then
  warn "§4.1.2 gsl_tp=0 in α — KNOWN GAP-1 (tree has no GSL touch driver; escalated to Bob)"
else
  warn "unexpected: gsl_tp present in α? investigate"
fi
for f in "aw87559_pa" "dw9714" "dw9719" "gc5004mipiraw" "hi253yuv" "hi704yuv" \
         "bct24157" "MAX17050SW6106"; do
  n="$(grep -ic "${f}" "${A_STR}" || true)"
  [ "${n}" -eq 0 ] || { warn "§4.1.2 EXPECTED-ABSENT violated at α: ${f} (${n} hits)"; FAILED=1; }
done

log "parity report: ${PARITY}"
if [ "${FAILED}" -ne 0 ]; then
  die "α parity failed (see ${PARITY})"
else
  log "α parity: §4.1.2 must-present PASS (gsl_tp excluded per GAP-1), expected-absence PASS"
fi
log "M1b-α build + parity complete"
