#!/usr/bin/env bash
# 55_repack_boot.sh — zImage + stock Lithium ramdisk → out/boot-m1b-<tag>.img (§4.1.3).
#
# Replicates Lithium's MTK dual-header boot.img format byte-precisely:
#   kernel payload = 512B MTK header (88168858 | LE32 len | "KERNEL" | 0xFF*472) + zImage
#   ramdisk payload = donor's raw in-image blob (ROOTFS header + cpio.gz) reused VERBATIM (E4)
# The boot.img header carries Lithium's exact args (boot.img-args.txt / §4.1.3) and is
# verified field-by-field against the donor after packing.
#
# Usage: 55_repack_boot.sh alpha|beta|beta-touch|beta-touch-lcm
#   alpha       → BUILD_ALPHA/arch/arm/boot/zImage        → out/boot-m1b-alpha.img
#   beta        → BUILD_BETA/arch/arm/boot/zImage         → out/boot-m1b-beta.img
#   beta-touch  → build-beta-touch/arch/arm/boot/zImage   → out/boot-m1b-beta-touch.img  (D17)
#   beta-touch-lcm → build-beta-touch-lcm/.../zImage      → out/boot-m1b-beta-touch-lcm.img  (D18)
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/40_kernel_env.sh"

require_tools python3 sha256sum stat
[ "${2:-}" = "" ] || { usage="usage: 55_repack_boot.sh alpha|beta|beta-touch|beta-touch-lcm"; echo "${usage}" >&2; exit 64; }
TAG="${1:-}"
case "${TAG}" in
  alpha) ZIMAGE="${BUILD_ALPHA}/arch/arm/boot/zImage" ;;
  beta)  ZIMAGE="${BUILD_BETA}/arch/arm/boot/zImage" ;;
  beta-touch) ZIMAGE="${KDIR}/build-beta-touch/arch/arm/boot/zImage" ;;
  beta-touch-lcm) ZIMAGE="${KDIR}/build-beta-touch-lcm/arch/arm/boot/zImage" ;;
  *) die "tag must be 'alpha', 'beta', 'beta-touch' or 'beta-touch-lcm'" ;;
esac
[ -s "${ZIMAGE}" ] || die "zImage missing: ${ZIMAGE} (run the corresponding build stage first)"
[ -x "${MTK_TOOLS}/mkbootimg" ] || die "mkbootimg missing at ${MTK_TOOLS}"

verify_lithium_donor

# ---------------------------------------------------------------- stock ramdisk (E4)
RAMDISK_BLOB="${SCRATCH}/lithium-ramdisk-blob.bin"
extract_lithium_ramdisk "${RAMDISK_BLOB}"

# ---------------------------------------------------------------- pack
log "repacking ${TAG}: kernel $(stat -c%s "${ZIMAGE}") B + ramdisk blob $(stat -c%s "${RAMDISK_BLOB}") B (byte-identical, E4)"
PAYLOAD="${SCRATCH}/kernel-mtk-header-${TAG}.img"
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
  --cmdline "${LITHIUM_CMDLINE}"
)

OUT_IMG="${OUT_DIR}/boot-m1b-${TAG}.img"
rm -f "${OUT_IMG}"
"${MTK_TOOLS}/mkbootimg" "${ARGS[@]}" -o "${OUT_IMG}" \
  || die "mkbootimg failed"
[ -s "${OUT_IMG}" ] || die "mkbootimg produced nothing"

# ---------------------------------------------------------------- verify vs donor
python3 - "${DONOR_LITHIUM_BOOT}" "${OUT_IMG}" "${PAYLOAD}" "${RAMDISK_BLOB}" <<'PYEOF'
import struct, sys, hashlib
def hdr(p):
    full = open(p, 'rb').read()
    return full, struct.unpack_from('8s10I16s512s20s', full, 0)
lf, lk = hdr(sys.argv[1])
nf, nk = hdr(sys.argv[2])
payload, blob = sys.argv[3], sys.argv[4]

names = ['magic','ksz','kaddr','rsz','raddr','ssz','saddr','taddr','pg','u1','u2']
l = dict(zip(names, lk[:11])); n = dict(zip(names, nk[:11]))
# byte-identical fields: everything except kernel size; sizes stay equal for
# ramdisk because the blob is reused verbatim.
same = ['magic','kaddr','raddr','ssz','saddr','taddr','pg','u1','u2']
diffs = [k for k in same if l[k] != n[k]]
assert not diffs, f'header fields differ from donor: {diffs}'
assert n['rsz'] == l['rsz'], f'ramdisk_size {n["rsz"]} != donor {l["rsz"]}'
# board name and cmdline must equal the donor's header verbatim
assert nk[11] == lk[11], 'board name differs from donor'
assert nk[12].rstrip(b'\x00') == lk[12].rstrip(b'\x00'), 'cmdline differs from donor'
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
print(f'verify OK: headers byte-identical except ksz '
      f'({l["ksz"]} (donor) vs {n["ksz"]}); ramdisk byte-identical '
      f'({n["rsz"]} B, sha {hashlib.sha256(new_ram).hexdigest()[:12]}…)')
PYEOF

IMG_SHA="$(sha_of "${OUT_IMG}")"
log "out/boot-m1b-${TAG}.img: $(stat -c%s "${OUT_IMG}") B sha256 ${IMG_SHA}"
printf '%s  boot-m1b-%s.img\n' "${IMG_SHA}" "${TAG}" > "${OUT_DIR}/boot-m1b-${TAG}.img.sha256"
log "M1b-${TAG} repack complete"
