#!/usr/bin/env bash
# run.sh — D22 actual-source host tests (hera-d22-input-diagnosis contract
# item: "Add reproducible actual-source host tests with transport mocks").
#
# The tests run the REAL driver functions — extracted verbatim from
#   OLD = the pre-D22 mtk_gslX680.c (the D17 state — snapshot of the tree
#         right before patches/kernel/D22.patch applies)
#   NEW = the post-D22 mtk_gslX680.c (snapshot right after it applies)
# — not reformulations. The firmware/tuning headers come from the real
# applied tree directory (fw sha-checked against the D17 generation pin).
#
# Proven (ASAN-built, gcc):
#   old write helper  -> stack-buffer-overflow READ  (aborts; must FAIL)
#   old fw loader     -> stack-buffer-overflow WRITE (aborts; must FAIL)
#   new write helper  -> exact stream + payload immutability + validation
#   new fw loader     -> every record of every real Q5 array emitted exactly
#                        as page/data transfers; partial batch, discontinuity,
#                        full-batch cap, injected short/negative transports
#   new init path     -> failure never reports success; bounded alive gate;
#                        full vendor sequence on the success path
#
# Usage: run.sh OLD_SRC NEW_SRC TREE_GSL_DIR
#   OLD_SRC      path to the pre-D22 mtk_gslX680.c
#   NEW_SRC      path to the post-D22 mtk_gslX680.c
#   TREE_GSL_DIR directory holding gslX680_fw_q5.h / gslX680_key_q5.h
# Exit 0 = all gates pass.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLD_SRC="${1:?usage: run.sh OLD_SRC NEW_SRC TREE_GSL_DIR}"
NEW_SRC="${2:?usage: run.sh OLD_SRC NEW_SRC TREE_GSL_DIR}"
TREE_GSL_DIR="${3:?usage: run.sh OLD_SRC NEW_SRC TREE_GSL_DIR}"
WORK="$(mktemp -d /tmp/d22-host-tests.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log()  { printf '[d22-host-tests] %s\n' "$*"; }
die()  { printf '[d22-host-tests][FATAL] %s\n' "$*" >&2; exit 1; }

command -v gcc >/dev/null 2>&1 || die "gcc not available"

[ -f "${OLD_SRC}" ] || die "OLD_SRC missing: ${OLD_SRC}"
[ -f "${NEW_SRC}" ] || die "NEW_SRC missing: ${NEW_SRC}"
[ -f "${TREE_GSL_DIR}/gslX680_fw_q5.h" ] || die "fw header missing in ${TREE_GSL_DIR}"

# ---------------------------------------------------------------- pins
# the extracted Q5 firmware header must be the pinned generation (the same
# byte pin build/60_kernel_delta_touch.sh asserts for the D17 extraction)
D22_FW_SHA="bae204cb4dd1f6adce804af5fad91e9b3424847bd7a09e7faadacf3effbae680"
got_fw="$(sha256sum -- "${TREE_GSL_DIR}/gslX680_fw_q5.h" | awk '{print $1}')"
[ "${got_fw}" = "${D22_FW_SHA}" ] || die "fw header sha ${got_fw} != pin ${D22_FW_SHA}"

# ---------------------------------------------------------------- extraction
# extract EXACT text by literal prefix matching (index()-based, no regex
# escapes). Two shapes:
#   ext     FROM STOP — lines after FROM until EXCLUSIVE of the STOP line
#                       (used for a region that must not swallow the next
#                       function's opening line);
#   ext_inc FROM STOP — lines from FROM through AND INCLUDING the STOP line
#                       (used for whole functions: the closing brace is kept).
ext() { # ext FROM STOP SRC OUT
	local from="${1}" stop="${2}" src="${3}" out="${4}"
	awk -v a="${from}" -v b="${stop}" \
		'f && index($0, b) == 1 {exit} !f && index($0, a) == 1 {f=1} f {print}' \
		"${src}" > "${out}"
	[ -s "${out}" ] || die "extraction empty (from: ${from}) from ${src}"
}
ext_inc() { # ext_inc FROM STOP SRC OUT (stop line INCLUDED)
	local from="${1}" stop="${2}" src="${3}" out="${4}"
	awk -v a="${from}" -v b="${stop}" \
		'f && index($0, b) == 1 {print; exit} !f && index($0, a) == 1 {f=1} f {print}' \
		"${src}" > "${out}"
	[ -s "${out}" ] || die "extraction empty (from: ${from}) from ${src}"
}

# --- OLD (pre-D22) fragments; drift-proofed against the known defect shapes ---
ext_inc 'static u32 gsl_write_interface' '}' "${OLD_SRC}" "${WORK}/x-old-write.c"
ext_inc 'static void gsl_load_fw' '}' "${OLD_SRC}" "${WORK}/x-old-load.c"
grep -q 'buf\[0\] = reg;' "${WORK}/x-old-write.c" \
	|| die "OLD extraction drift: the old [reg|payload] write helper not found"
grep -q 'send_flag == 1 % burst' "${WORK}/x-old-load.c" \
	|| die "OLD extraction drift: the old constant-flush loader not found"

# --- NEW (post-D22) fragments ---
# span A = constants + struct/config tables + i2c + chip helpers + load_fw
# + check_mem_data + gsl_check_alive — i.e. everything from the panel-identity
# block down to (excluding) the gsl_sw_init definition. Both the forward
# DECLARATIONS of gsl_sw_init/check_alive ("...;") and the DEFINITION share a
# prefix, so the from/stop logic must skip declaration lines (trailing ';').
awk -v a='/* ---- panel identity' -v b='static int gsl_sw_init(struct i2c_client' \
	'f && index($0, b) == 1 && substr($0, length($0), 1) != ";" {exit}
	 !f && index($0, a) == 1 {f=1}
	 f {print}' "${NEW_SRC}" > "${WORK}/x-new-spana.c"
awk -v a='static int gsl_sw_init(struct i2c_client' -v b='}' \
	'f && index($0, b) == 1 {print; exit}
	 !f && index($0, a) == 1 && substr($0, length($0), 1) != ";" {f=1}
	 f {print}' "${NEW_SRC}" > "${WORK}/x-new-swinit.c"
ext_inc 'static int gsl_write_interface(struct i2c_client' '}' "${NEW_SRC}" "${WORK}/x-new-wif.c"
ext_inc 'static s32 gsl_i2c_write_bytes' '}' "${NEW_SRC}" "${WORK}/x-new-wbytes.c"
cat "${WORK}/x-new-wif.c" "${WORK}/x-new-wbytes.c" > "${WORK}/x-new-write.c"
# the write-only harness does not pull the whole constants block: take the
# exact #define lines it needs straight from the source (drift-proofed)
grep -E '^#define GSL_I2C_MAX_PAYLOAD[[:space:]]' "${NEW_SRC}" > "${WORK}/x-new-const.c"
[ -s "${WORK}/x-new-const.c" ] || die "NEW extraction drift: GSL_I2C_MAX_PAYLOAD define missing"
cat "${WORK}/x-new-const.c" "${WORK}/x-new-write.c" > "${WORK}/x-new-write.tmp"
mv "${WORK}/x-new-write.tmp" "${WORK}/x-new-write.c"
grep -q 'staged\[0\] = reg;' "${WORK}/x-new-wif.c" \
	|| die "NEW extraction drift: the staged-buffer write helper not found"
grep -q 'static int gsl_load_fw' "${NEW_SRC}" \
	|| die "NEW drift: repaired loader signature missing in source"

# the real extracted firmware header for the old-loader ASAN proof
cp "${TREE_GSL_DIR}/gslX680_fw_q5.h" "${WORK}/x-real-fw-check.h"
ln -sf "${TREE_GSL_DIR}/gslX680_fw_q5.h" "${WORK}/gslX680_fw_q5.h"
ln -sf "${TREE_GSL_DIR}/gslX680_key_q5.h" "${WORK}/gslX680_key_q5.h"
# the new fragments #include "gslX680_fw_q5.h"/"gslX680_key_q5.h" themselves

ASAN_FLAGS=(-fsanitize=address -fno-omit-frame-pointer -g -O0 -I"${HERE}" -I"${WORK}")

build() { gcc "${ASAN_FLAGS[@]}" -o "${WORK}/$1" "${HERE}/$2" || die "build failed: $2"; }

# ---------------------------------------------------------------- 1. must FAIL
log "1. OLD write helper — expect ASAN stack-buffer-overflow READ (abort)"
build old_write old_write_asan.c
set +e
"${WORK}/old_write" > "${WORK}/old-write.out" 2> "${WORK}/old-write.err"
rc=$?
set -e
[ "${rc}" -ne 0 ] || die "OLD write helper did NOT abort under ASAN (repair regression?)"
grep -q 'stack-buffer-overflow' "${WORK}/old-write.err" \
	|| { log "--- stderr ---"; cat "${WORK}/old-write.err"; die "OLD write abort is not a stack-buffer-overflow"; }
log "   OK: aborted with ASAN stack-buffer-overflow"

log "2. OLD firmware loader — expect ASAN stack-buffer-overflow WRITE (abort)"
build old_fw old_fw_asan.c
set +e
"${WORK}/old_fw" > "${WORK}/old-fw.out" 2> "${WORK}/old-fw.err"
rc=$?
set -e
[ "${rc}" -ne 0 ] || die "OLD firmware loader did NOT abort under ASAN (repair regression?)"
grep -q 'stack-buffer-overflow' "${WORK}/old-fw.err" \
	|| { log "--- stderr ---"; cat "${WORK}/old-fw.err"; die "OLD loader abort is not a stack-buffer-overflow"; }
log "   OK: aborted with ASAN stack-buffer-overflow"

# ---------------------------------------------------------------- 2. must PASS
log "3. NEW write helper — payload immutability + exact byte stream + validation"
build new_write new_gsl_write.c
"${WORK}/new_write"

log "4. NEW firmware loader — all real Q5 arrays + synthetic edges + injected failures"
build new_fw new_gsl_fw.c
"${WORK}/new_fw"

log "5. NEW init path — failure never reports success; bounded alive gate"
build new_init new_gsl_init.c
"${WORK}/new_init"

log "ALL D22 HOST TESTS PASS (old defects still reproduce; repairs verified on actual source)"
