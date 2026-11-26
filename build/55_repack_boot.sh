#!/usr/bin/env bash
# 55_repack_boot.sh — zImage + stock Lithium ramdisk → out/boot-m1b-<tag>.img (§4.1.3).
#
# Replicates Lithium's MTK dual-header boot.img format byte-precisely:
#   kernel payload = 512B MTK header (88168858 | LE32 len | "KERNEL" | 0xFF*472) + zImage
#   ramdisk payload = donor's raw in-image blob (ROOTFS header + cpio.gz) reused VERBATIM (E4)
# The boot.img header carries Lithium's exact args (boot.img-args.txt / §4.1.3) and is
# verified field-by-field against the donor after packing.
#
# Usage: 55_repack_boot.sh alpha|beta|beta-touch|beta-touch-lcm|beta-touch-lcm-board|beta-touch-lcm-board2|beta-touch-lcm-board3|beta-touch-lcm-board4|beta-touch-lcm-board5|beta-touch-lcm-board6|beta-touch-lcm-board7|beta-touch-lcm-board8|beta-touch-lcm-board9|beta-touch-lcm-board10|beta-touch-lcm-board11|beta-touch-lcm-board12|lithium-ctl [--debug-cmdline]
#   alpha       → BUILD_ALPHA/arch/arm/boot/zImage        → out/boot-m1b-alpha.img
#   beta        → BUILD_BETA/arch/arm/boot/zImage         → out/boot-m1b-beta.img
#   beta-touch  → build-beta-touch/arch/arm/boot/zImage   → out/boot-m1b-beta-touch.img  (D17)
#   beta-touch-lcm → build-beta-touch-lcm/.../zImage      → out/boot-m1b-beta-touch-lcm.img  (D18)
#   beta-touch-lcm-board → build-beta-touch-lcm-board/.../zImage
#                 → out/boot-m1b-beta-touch-lcm-board.img  (D19+D20, the M4 verdict image)
#   beta-touch-lcm-board2 → build-beta-touch-lcm-board2/.../zImage
#                 → out/boot-m1b-beta-touch-lcm-board2.img  (D21 MBR panic fix, the M5 verdict image)
#   beta-touch-lcm-board3 → build-beta-touch-lcm-board3/.../zImage
#                 → out/boot-m1b-beta-touch-lcm-board3.img  (D22 input repairs, the D22 verdict image)
#   beta-touch-lcm-board6 → build-beta-touch-lcm-board6/.../zImage
#                 → out/boot-m1b-beta-touch-lcm-board6.img  (D25 tpd framework integration, the D25 verdict image)
#   lithium-ctl → the PINNED donor's kernel payload, verbatim (no build needed)
#                 → out/boot-m1b-lithium-ctl.img; must be byte-identical to the
#                 donor boot.img (T0 repack-control, bob-m3-boot-debug §5).
#   --debug-cmdline  optional flag (bob-m3-boot-debug §5.4): appends
#                 "console=ttyMT3,921600n1 initcall_debug printk.time=1" to the
#                 cmdline and writes out/boot-m1b-<tag>-dbg.img (NEVER the
#                 default images). Not allowed with lithium-ctl (T0 must stay
#                 pristine — byte-identity with the donor is the pass gate).
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/40_kernel_env.sh"

require_tools python3 sha256sum stat
# --debug-cmdline (§5.4 UART/ram-console evidence capture aid). OFF by default;
# every default path below is identical to its pre-M3 behaviour.
# Environment override lets a diagnostic run append extra params (e.g.
# log_buf_len=4M so boot-time driver messages survive until adb is up)
# while every default path stays byte-identical.
DEBUG_CMDLINE_SUFFIX="${DEBUG_CMDLINE_SUFFIX_OVERRIDE:-console=ttyMT3,921600n1 initcall_debug printk.time=1}"
DEBUG_CMDLINE_MODE=0
if [ "${2:-}" = "--debug-cmdline" ]; then
  DEBUG_CMDLINE_MODE=1
elif [ "${2:-}" != "" ] || [ $# -gt 2 ]; then
  usage="usage: 55_repack_boot.sh alpha|beta|beta-touch|beta-touch-lcm|beta-touch-lcm-board|beta-touch-lcm-board2|beta-touch-lcm-board3|beta-touch-lcm-board4|beta-touch-lcm-board5|beta-touch-lcm-board6|beta-touch-lcm-board7|beta-touch-lcm-board8|beta-touch-lcm-board9|beta-touch-lcm-board10|beta-touch-lcm-board11|beta-touch-lcm-board12|lithium-ctl [--debug-cmdline]"
  echo "${usage}" >&2
  exit 64
fi
[ $# -le 2 ] || { usage="usage: 55_repack_boot.sh alpha|beta|beta-touch|beta-touch-lcm|beta-touch-lcm-board|beta-touch-lcm-board2|beta-touch-lcm-board3|beta-touch-lcm-board4|beta-touch-lcm-board5|beta-touch-lcm-board6|beta-touch-lcm-board7|beta-touch-lcm-board8|beta-touch-lcm-board9|beta-touch-lcm-board10|beta-touch-lcm-board11|beta-touch-lcm-board12|lithium-ctl [--debug-cmdline]"; echo "${usage}" >&2; exit 64; }
TAG="${1:-}"
case "${TAG}" in
  alpha) ZIMAGE="${BUILD_ALPHA}/arch/arm/boot/zImage" ;;
  beta)  ZIMAGE="${BUILD_BETA}/arch/arm/boot/zImage" ;;
  beta-touch) ZIMAGE="${KDIR}/build-beta-touch/arch/arm/boot/zImage" ;;
  beta-touch-lcm) ZIMAGE="${KDIR}/build-beta-touch-lcm/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board) ZIMAGE="${KDIR}/build-beta-touch-lcm-board/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board2) ZIMAGE="${KDIR}/build-beta-touch-lcm-board2/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board3) ZIMAGE="${KDIR}/build-beta-touch-lcm-board3/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board4) ZIMAGE="${KDIR}/build-beta-touch-lcm-board4/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board5) ZIMAGE="${KDIR}/build-beta-touch-lcm-board5/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board6) ZIMAGE="${KDIR}/build-beta-touch-lcm-board6/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board7) ZIMAGE="${KDIR}/build-beta-touch-lcm-board7/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board8) ZIMAGE="${KDIR}/build-beta-touch-lcm-board8/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board9) ZIMAGE="${KDIR}/build-beta-touch-lcm-board9/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board10) ZIMAGE="${KDIR}/build-beta-touch-lcm-board10/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board11) ZIMAGE="${KDIR}/build-beta-touch-lcm-board11/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board13) ZIMAGE="${KDIR}/build-beta-touch-lcm-board13/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board14) ZIMAGE="${KDIR}/build-beta-touch-lcm-board14/arch/arm/boot/zImage" ;;
  beta-touch-lcm-board12) ZIMAGE="${KDIR}/build-beta-touch-lcm-board12/arch/arm/boot/zImage" ;;
  lithium-ctl) ZIMAGE="" ;;  # donor kernel payload, extracted verbatim below (T0)
  *) die "tag must be 'alpha', 'beta', 'beta-touch', 'beta-touch-lcm', 'beta-touch-lcm-board', 'beta-touch-lcm-board2', 'beta-touch-lcm-board3', 'beta-touch-lcm-board4', 'beta-touch-lcm-board5', 'beta-touch-lcm-board6' or 'lithium-ctl'" ;;
esac
if [ "${TAG}" = "lithium-ctl" ]; then
  if [ "${DEBUG_CMDLINE_MODE}" -ne 0 ]; then
    die "lithium-ctl must stay byte-identical to the donor — --debug-cmdline is not allowed (T0, bob-m3 §5)"
  fi
else
  [ -s "${ZIMAGE}" ] || die "zImage missing: ${ZIMAGE} (run the corresponding build stage first)"
fi
[ -x "${MTK_TOOLS}/mkbootimg" ] || die "mkbootimg missing at ${MTK_TOOLS}"

verify_lithium_donor

# ---------------------------------------------------------------- stock ramdisk (E4)
RAMDISK_BLOB="${SCRATCH}/lithium-ramdisk-blob.bin"
extract_lithium_ramdisk "${RAMDISK_BLOB}"

# ---------------------------------------------------------------- kernel payload
PAYLOAD="${SCRATCH}/kernel-mtk-header-${TAG}.img"
if [ "${TAG}" = "lithium-ctl" ]; then
  # T0 repack-control (bob-m3-boot-debug §5): feed the repack machinery the
  # DONOR's own kernel payload — the #ANDROID!-adorned image region
  # boot.img[pg : pg+ksz] (2048 : 2048+3809720) = 512B MTK KERNEL header +
  # zImage — with no fork build involved. The pipeline must reproduce the
  # donor image exactly (asserted below); any difference IS the repack bug
  # the control exists to catch.
  log "lithium-ctl: extracting donor kernel region [${LITHIUM_PAGESIZE} : +${LITHIUM_KERNEL_SIZE}] verbatim (T0, bob-m3 §5)"
  python3 - "${DONOR_LITHIUM_BOOT}" "${PAYLOAD}" <<'PYEOF'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
full = open(src, 'rb').read()
magic, ksz, kaddr, rsz, raddr, ssz, saddr, taddr, pg, u1, u2 = struct.unpack_from('8s10I', full, 0)
assert magic == b'ANDROID!', magic
region = full[pg:pg + ksz]
assert region[:4] == b'\x88\x16\x88\x58', 'kernel MTK header missing'
assert region[8:14] == b'KERNEL', region[8:14]
assert struct.unpack('<I', region[4:8])[0] == len(region) - 512, 'MTK KERNEL header length wrong'
open(dst, 'wb').write(region)
print(f'donor kernel region: {len(region)} bytes @0x{pg:x}')
PYEOF
  # the region is already pinned in 40_kernel_env.sh as the Lithium kernel blob
  assert_sha "${PAYLOAD}" "${LITHIUM_KERNEL_IMG_SHA}" "lithium kernel region (T0 control)"
else
  log "repacking ${TAG}: kernel $(stat -c%s "${ZIMAGE}") B + ramdisk blob $(stat -c%s "${RAMDISK_BLOB}") B (byte-identical, E4)"
  python3 - "${ZIMAGE}" "${PAYLOAD}" <<'PYEOF'
import struct, sys
zimg, out = sys.argv[1], sys.argv[2]
z = open(zimg, 'rb').read()
assert z[0x24:0x28] == b'\x18\x28\x6f\x01', 'input is not an ARM zImage'
# MTK KERNEL header = a4 magic + L payload len + a32 type + 0xFF*472 (512 total),
# matching repack-MTK.pl gen_header / the donor's own bytes (asserted below).
hdr = b'\x88\x16\x88\x58' + struct.pack('<I', len(z)) \
    + b'KERNEL'.ljust(32, b'\x00') + b'\xff' * 472
assert len(hdr) == 512
open(out, 'wb').write(hdr + z)
PYEOF
fi

# ---------------------------------------------------------------- pack
if [ "${DEBUG_CMDLINE_MODE}" -ne 0 ]; then
  log "debug cmdline flag: appending '${DEBUG_CMDLINE_SUFFIX}' (bob-m3 §5.4; dbg image, default images untouched)"
  PACK_CMDLINE="${LITHIUM_CMDLINE} ${DEBUG_CMDLINE_SUFFIX}"
else
  PACK_CMDLINE="${LITHIUM_CMDLINE}"
fi
ARGS=(
  --kernel "${PAYLOAD}"
  --ramdisk "${RAMDISK_BLOB}"
  --base 0x80000000
  --pagesize "${LITHIUM_PAGESIZE}"
  --kernel_offset 0x00008000
  --ramdisk_offset 0x04000000
  --second_offset 0x00f00000
  --tags_offset 0x0e000000
  --board "${LITHIUM_BOARD}"
  --cmdline "${PACK_CMDLINE}"
)

# The debug-cmdline variant must NEVER overwrite the default (pinned) images —
# write it under its own -dbg name so a debug capture cannot clobber evidence.
if [ "${DEBUG_CMDLINE_MODE}" -ne 0 ]; then
  IMG_NAME="boot-m1b-${TAG}-dbg.img"
  VERIFY_MODE="kernel-debug"
else
  IMG_NAME="boot-m1b-${TAG}.img"
  VERIFY_MODE="kernel"
fi
if [ "${TAG}" = "lithium-ctl" ]; then
  VERIFY_MODE="ctl"
fi
OUT_IMG="${OUT_DIR}/${IMG_NAME}"
rm -f "${OUT_IMG}"
"${MTK_TOOLS}/mkbootimg" "${ARGS[@]}" -o "${OUT_IMG}" \
  || die "mkbootimg failed"
[ -s "${OUT_IMG}" ] || die "mkbootimg produced nothing"

# ---------------------------------------------------------------- verify vs donor
python3 - "${DONOR_LITHIUM_BOOT}" "${OUT_IMG}" "${PAYLOAD}" "${RAMDISK_BLOB}" \
  "${VERIFY_MODE}" "${DEBUG_CMDLINE_SUFFIX}" <<'PYEOF'
import struct, sys, hashlib
def hdr(p):
    full = open(p, 'rb').read()
    return full, struct.unpack_from('8s10I16s512s20s', full, 0)
lf, lk = hdr(sys.argv[1])
nf, nk = hdr(sys.argv[2])
payload, blob, mode, dbg_suffix = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6].encode()

names = ['magic','ksz','kaddr','rsz','raddr','ssz','saddr','taddr','pg','u1','u2']
l = dict(zip(names, lk[:11])); n = dict(zip(names, nk[:11]))
# byte-identical fields: everything except kernel size; sizes stay equal for
# ramdisk because the blob is reused verbatim.
same = ['magic','kaddr','raddr','ssz','saddr','taddr','pg','u1','u2']
diffs = [k for k in same if l[k] != n[k]]
assert not diffs, f'header fields differ from donor: {diffs}'
assert n['rsz'] == l['rsz'], f'ramdisk_size {n["rsz"]} != donor {l["rsz"]}'
# board name must equal the donor's header verbatim; cmdline must equal the
# donor's verbatim — or, with --debug-cmdline, donor cmdline + the exact
# appended debug suffix (bob-m3 §5.4: cmdline change is the ONE added delta).
assert nk[11] == lk[11], 'board name differs from donor'
exp_cmd = lk[12].rstrip(b'\x00')
got_cmd = nk[12].rstrip(b'\x00')
if mode == 'kernel-debug':
    exp_cmd = exp_cmd + b' ' + dbg_suffix
assert got_cmd == exp_cmd, f'cmdline mismatch: got {got_cmd!r}, want {exp_cmd!r}'
# ramdisk region must be byte-identical to the extracted blob
ram1 = (1 + (n['ksz'] + n['pg'] - 1) // n['pg']) * n['pg']
new_ram = nf[ram1:ram1 + n['rsz']]
blob_b = open(blob, 'rb').read()
assert new_ram == blob_b, 'in-image ramdisk differs from donor blob'
# kernel region must equal the MTK-headed payload we supplied
pay_b = open(payload, 'rb').read()
assert nf[n['pg']:n['pg'] + n['ksz']] == pay_b, 'kernel payload mismatch'
assert pay_b[:4] == b'\x88\x16\x88\x58' and pay_b[8:14] == b'KERNEL'
ln = struct.unpack('<I', pay_b[4:8])[0]
assert ln == len(pay_b) - 512, 'MTK KERNEL header length wrong'
if mode == 'ctl':
    # T0 pass gate: the donor's own payload re-packed by our machinery must
    # reproduce the donor image exactly; ksz equal is part of that.
    assert n['ksz'] == l['ksz'], f'ctl ksz {n["ksz"]} != donor {l["ksz"]}'
    assert nf == lf, 'T0 image is NOT byte-identical to the donor boot.img'
    print(f'verify OK (ctl, T0): BYTE-IDENTICAL to donor boot.img; '
          f'ksz equal ({n["ksz"]} B); ramdisk byte-identical '
          f'({n["rsz"]} B, sha {hashlib.sha256(new_ram).hexdigest()[:12]}…)')
else:
    print(f'verify OK: headers byte-identical except ksz '
          f'({l["ksz"]} (donor) vs {n["ksz"]}); ramdisk byte-identical '
          f'({n["rsz"]} B, sha {hashlib.sha256(new_ram).hexdigest()[:12]}…)')
PYEOF

IMG_SHA="$(sha_of "${OUT_IMG}")"
log "out/${IMG_NAME}: $(stat -c%s "${OUT_IMG}") B sha256 ${IMG_SHA}"
printf '%s  %s\n' "${IMG_SHA}" "${IMG_NAME}" > "${OUT_DIR}/${IMG_NAME}.sha256"
log "M1b-${TAG} repack complete"
