#!/usr/bin/env bash
# 20_apply_system_ops.sh — M1a stage 2: apply the §2.2 op table (9 ops, exact
# and ordered) to work/images/system-fork.img via debugfs -w.
#
# Preconditions: stage 10 has staged the fork copy and captured donor identity.
# Every op asserts its pre-state (donor-identical), mutates, then verifies the
# post-state by read-back (debugfs always exits 0, so exit codes prove nothing).
#
# Inode identity policy (determinism, §2.0 rule 4):
#   - donor files replaced in place (ops 2,3,6,7,8) keep the DONOR file's
#     {c,a,m}time and crtime=0;
#   - donor-content grafts (op 1) keep the DONOR(T-ROM) file's {c,a,m}time;
#   - Mint-content graft (op 5) keeps Mint's ACCDET.kl {c,a,m}time;
#   - fork-authored content (op 9) uses the build tree's HEAD commit epoch;
#   - all new/rewritten inodes get mode/uid/gid per §3.2-9 (0644 root:root),
#     extra_isize=28 (donor value) and the security.selinux xattr restored;
#   - touched parent dirs (/, /etc, /usr/keylayout, /lib/hw, /vendor/etc) are
#     re-pinned to their donor {c,a,m}times at the end (mkdir/rm/write update
#     parent dir times with wall-clock otherwise — breaks determinism).
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=00_env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/00_env.sh"
require_tools debugfs sha256sum git patch

log "stage 20: applying §2.2 op table"
ensure_dirs
verify_donor_pins
[ -f "${IMG_FORK}" ] || die "stage 20 requires ${IMG_FORK} (run 10_unpack_system.sh first)"
assert_sha "${IMG_FORK}" "$(pin_for ~/q5-flash/rom/system.img)" \
  "${IMG_FORK} pre-op state (must be pristine donor copy — run 10 for a clean start)"

# shellcheck source=/dev/null
source "${WORK_DIR}/stats/donor-identity.env"

getf() { awk -v n="$2" '{print $n}' <<<"$1"; } # Nth field of a df_md tuple

# Build determinism inputs
GITREV="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
GITDIRTY="$(git -C "${REPO_ROOT}" status --porcelain | wc -l)"
GITDATE="$(git -C "${REPO_ROOT}" log -1 --format=%cI)"
BUILD_EPOCH="$(git -C "${REPO_ROOT}" log -1 --format=%ct)"
OPLOG="${WORK_DIR}/stats/ops.log"
: > "${OPLOG}"
mdf() { printf '%s\n' "$1" >> "${OPLOG}"; }

SO_TROM_IMG="${WORK_DIR}/assets/trom/audio.primary.mt6582.so"
POLICY_TROM_IMG="${WORK_DIR}/assets/trom/audio_policy.conf"
EFFECTS_TROM_IMG="${WORK_DIR}/assets/trom/audio_effects.conf"
ACCDET_SRC="${PATCH_DIR}/usr/keylayout/ACCDET.kl"
MTKKPD_SRC="${PATCH_DIR}/usr/keylayout/mtk-kpd.kl"
GENERIC_PATCH="${PATCH_DIR}/usr/keylayout/Generic.kl.patch"

# ---------------------------------------------------------------- op 1 audio HAL
p="/lib/hw/audio.primary.mt6582.so"
df_assert_md "${IMG_FORK}" "${p}" "${DONOR_MD_SO_LITHIUM}" "op1 pre-state ${p}"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}" "write ${SO_TROM_IMG} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "$(getf "${TROM_MD_SO}" 2)" "$(getf "${TROM_MD_SO}" 3)" \
  "$(getf "${TROM_MD_SO}" 7)" "$(getf "${TROM_MD_SO}" 6)" "$(getf "${TROM_MD_SO}" 5)" \
  "$(getf "${TROM_MD_SO}" 8)" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op1.check"
assert_sha "${TMP_DIR}/op1.check" "$(pin_for img:TROM:lib/hw/audio.primary.mt6582.so)" "op1 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" "${TROM_MD_SO}" "op1 result ${p}"
mdf "op1 OK"

# ---------------------------------------------------------------- op 2 audio_policy.conf
p="/etc/audio_policy.conf"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op2.pre"
assert_sha "${TMP_DIR}/op2.pre" "$(pin_for img:LITHIUM:etc/audio_policy.conf)" "op2 pre-state ${p}"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}" "write ${POLICY_TROM_IMG} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "$(getf "${TROM_MD_POLICY}" 2)" "$(getf "${TROM_MD_POLICY}" 3)" \
  "$(getf "${TROM_MD_POLICY}" 7)" "$(getf "${TROM_MD_POLICY}" 6)" "$(getf "${TROM_MD_POLICY}" 5)" \
  "$(getf "${TROM_MD_POLICY}" 8)" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op2.check"
assert_sha "${TMP_DIR}/op2.check" "$(pin_for img:TROM:etc/audio_policy.conf)" "op2 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" "${TROM_MD_POLICY}" "op2 result ${p}"
mdf "op2 OK"

# ---------------------------------------------------------------- op 3 audio_effects.conf
p="/etc/audio_effects.conf"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op3.pre"
assert_sha "${TMP_DIR}/op3.pre" "$(pin_for img:LITHIUM:etc/audio_effects.conf)" "op3 pre-state ${p}"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}" "write ${EFFECTS_TROM_IMG} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "$(getf "${TROM_MD_POLICY}" 2)" "$(getf "${TROM_MD_POLICY}" 3)" \
  "$(getf "${TROM_MD_EFFECTS}" 7)" "$(getf "${TROM_MD_EFFECTS}" 6)" "$(getf "${TROM_MD_EFFECTS}" 5)" \
  "$(getf "${TROM_MD_EFFECTS}" 8)" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op3.check"
assert_sha "${TMP_DIR}/op3.check" "$(pin_for img:TROM:etc/audio_effects.conf)" "op3 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" "${TROM_MD_EFFECTS}" "op3 result ${p}"
mdf "op3 OK"

# ---------------------------------------------------------------- op 4 delete mixer stub
p="/vendor/etc/mixer_paths.xml"
df_exists "${IMG_FORK}" "${p}" || die "op4 pre-state: ${p} unexpectedly absent"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}"
df_exists "${IMG_FORK}" "${p}" && die "op4 post-state: ${p} still present"
mdf "op4 OK"

# ---------------------------------------------------------------- op 5 add ACCDET.kl
p="/usr/keylayout/ACCDET.kl"
df_exists "${IMG_FORK}" "${p}" && die "op5 pre-state: ${p} unexpectedly present"
df_write "${OPLOG}" "${IMG_FORK}" "write ${ACCDET_SRC} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "0" "0" \
  "$(getf "${MINT_MD_ACCDET}" 7)" "$(getf "${MINT_MD_ACCDET}" 6)" "$(getf "${MINT_MD_ACCDET}" 5)" \
  "$(getf "${MINT_MD_ACCDET}" 8)" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op5.check"
assert_sha "${TMP_DIR}/op5.check" "$(pin_for img:MINT:usr/keylayout/ACCDET.kl)" "op5 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" "${MINT_MD_ACCDET}" "op5 result ${p}"
mdf "op5 OK"

# ---------------------------------------------------------------- op 6 replace mtk-kpd.kl
p="/usr/keylayout/mtk-kpd.kl"
df_assert_md "${IMG_FORK}" "${p}" "${DONOR_MD_MTKKPD}" "op6 pre-state ${p}"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op6.pre"
assert_sha "${TMP_DIR}/op6.pre" "$(pin_for img:LITHIUM:usr/keylayout/mtk-kpd.kl)" "op6 pre-state ${p}"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}" "write ${MTKKPD_SRC} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "0" "0" \
  "$(getf "${DONOR_MD_MTKKPD}" 7)" "$(getf "${DONOR_MD_MTKKPD}" 6)" "$(getf "${DONOR_MD_MTKKPD}" 5)" \
  "0" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op6.check"
MTKKPD_SHA="$(sha_of "${MTKKPD_SRC}")"
assert_sha "${TMP_DIR}/op6.check" "${MTKKPD_SHA}" "op6 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" \
  "$(printf '%s' "0644 0 0 $(wc -c < "${MTKKPD_SRC}") $(getf "${DONOR_MD_MTKKPD}" 5) $(getf "${DONOR_MD_MTKKPD}" 6) $(getf "${DONOR_MD_MTKKPD}" 7) 0 28")" \
  "op6 result inode identity ${p}"
# §2.5 acceptance (spec §3.2-5): dual HOME map + wake flags present
grep -Fq 'key 102   HOME              WAKE_DROPPED' "${TMP_DIR}/op6.check" || die "op6: 102/HOME WAKE_DROPPED line missing"
grep -Fq 'key 172   HOME              WAKE_DROPPED' "${TMP_DIR}/op6.check" || die "op6: 172/HOME WAKE_DROPPED line missing"
grep -Fq 'key 745   FCOVER_2           WAKE' "${TMP_DIR}/op6.check" || die "op6: FCOVER_2 line missing"
mdf "op6 OK"

# ---------------------------------------------------------------- op 7 patch Generic.kl
p="/usr/keylayout/Generic.kl"
df_assert_md "${IMG_FORK}" "${p}" "${DONOR_MD_GENERIC}" "op7 pre-state ${p}"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op7.pre"
assert_sha "${TMP_DIR}/op7.pre" "$(pin_for img:LITHIUM:usr/keylayout/Generic.kl)" "op7 pre-state ${p}"
PATCHWORK="${WORK_DIR}/patchwork/usr/keylayout"
mkdir -p "${PATCHWORK}"
cp -- "${TMP_DIR}/op7.pre" "${PATCHWORK}/Generic.kl"
patch --dry-run -d "${WORK_DIR}/patchwork" -p1 -i "${GENERIC_PATCH}" -f \
  || die "op7: Generic.kl.patch dry-run failed against donor base"
patch -d "${WORK_DIR}/patchwork" -p1 -i "${GENERIC_PATCH}" -f \
  || die "op7: Generic.kl.patch apply failed"
GENERIC_PATCHED="${WORK_DIR}/patchwork/usr/keylayout/Generic.kl"
# §2.6 expectations: exactly the 7 targeted lines carry flags now
n_flags="$(grep -cE '^key (116   POWER             WAKE|127   MENU              WAKE_DROPPED|139   MENU              WAKE_DROPPED|142   POWER             WAKE|143   POWER             WAKE|152   POWER             WAKE|158   BACK              WAKE_DROPPED)$' "${GENERIC_PATCHED}")"
[ "${n_flags}" -eq 7 ] || die "op7: expected 7 wake-flagged lines after patch, found ${n_flags}"
n_copy="$(grep -cE '^key (133   COPY|135   PASTE|137   CUT)$' "${GENERIC_PATCHED}")"
[ "${n_copy}" -eq 3 ] || die "op7: COPY/CUT/PASTE lines were disturbed (${n_copy}/3)"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}" "write ${GENERIC_PATCHED} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "0" "0" \
  "$(getf "${DONOR_MD_GENERIC}" 7)" "$(getf "${DONOR_MD_GENERIC}" 6)" "$(getf "${DONOR_MD_GENERIC}" 5)" \
  "0" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op7.check"
assert_sha "${TMP_DIR}/op7.check" "$(sha_of "${GENERIC_PATCHED}")" "op7 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" \
  "$(printf '%s' "0644 0 0 $(wc -c < "${GENERIC_PATCHED}") $(getf "${DONOR_MD_GENERIC}" 5) $(getf "${DONOR_MD_GENERIC}" 6) $(getf "${DONOR_MD_GENERIC}" 7) 0 28")" \
  "op7 result inode identity ${p}"
mdf "op7 OK"

# ---------------------------------------------------------------- op 8 build.prop mainkeys
p="/build.prop"
df_assert_md "${IMG_FORK}" "${p}" "${DONOR_MD_BUILDPROP}" "op8 pre-state ${p}"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op8.pre"
assert_sha "${TMP_DIR}/op8.pre" "$(pin_for img:LITHIUM:build.prop)" "op8 pre-state ${p}"
PROPWORK="${WORK_DIR}/patchwork/build.prop"
if [ "$(grep -c 'qemu.hw.mainkeys=1' "${TMP_DIR}/op8.pre")" -eq 1 ]; then
  sed 's/^qemu\.hw\.mainkeys=1$/qemu.hw.mainkeys=0/' "${TMP_DIR}/op8.pre" > "${PROPWORK}"
elif [ "$(grep -c 'qemu.hw.mainkeys=0' "${TMP_DIR}/op8.pre")" -eq 1 ]; then
  cp -- "${TMP_DIR}/op8.pre" "${PROPWORK}"   # already applied (defensive idempotence)
else
  cp -- "${TMP_DIR}/op8.pre" "${PROPWORK}"   # spec §2.2 op 8: "else append at end if absent"
  printf 'qemu.hw.mainkeys=0\n' >> "${PROPWORK}"
fi
n1="$(grep -c '^qemu\.hw\.mainkeys=1$' "${PROPWORK}" || true)"
n0="$(grep -c '^qemu\.hw\.mainkeys=0$' "${PROPWORK}" || true)"
[ "${n1}" -eq 0 ] && [ "${n0}" -eq 1 ] || die "op8: mainkeys state wrong (n1=${n1} n0=${n0})"
dlines="$(diff -- "${TMP_DIR}/op8.pre" "${PROPWORK}" | grep -cEc '^[<>]' || true)"
[ "${dlines}" -le 2 ] || die "op8: build.prop diff exceeds the single-line edit (${dlines} lines)"
df_write "${OPLOG}" "${IMG_FORK}" "rm ${p}" "write ${PROPWORK} ${p}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${p}" \
  "0100644" "0" "0" \
  "$(getf "${DONOR_MD_BUILDPROP}" 7)" "$(getf "${DONOR_MD_BUILDPROP}" 6)" "$(getf "${DONOR_MD_BUILDPROP}" 5)" \
  "0" "28"
df_dump "${IMG_FORK}" "${p}" "${TMP_DIR}/op8.check"
assert_sha "${TMP_DIR}/op8.check" "$(sha_of "${PROPWORK}")" "op8 result ${p}"
df_assert_md "${IMG_FORK}" "${p}" \
  "$(printf '%s' "0644 0 0 $(wc -c < "${PROPWORK}") $(getf "${DONOR_MD_BUILDPROP}" 5) $(getf "${DONOR_MD_BUILDPROP}" 6) $(getf "${DONOR_MD_BUILDPROP}" 7) 0 28")" \
  "op8 result inode identity ${p}"
mdf "op8 OK"

# ---------------------------------------------------------------- op 9 fork manifest
FORK_ETC_DIR="/etc/fork"
MANIFEST_IMG_NAME="fork-manifest.txt"
MANIFEST_FILE="${WORK_DIR}/assets/${MANIFEST_IMG_NAME}"
if df_exists "${IMG_FORK}" "${FORK_ETC_DIR}"; then
  die "op9 pre-state: ${FORK_ETC_DIR} unexpectedly exists"
fi
df_write "${OPLOG}" "${IMG_FORK}" "mkdir ${FORK_ETC_DIR}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${FORK_ETC_DIR}" \
  "040755" "0" "0" "${BUILD_EPOCH}" "${BUILD_EPOCH}" "${BUILD_EPOCH}" "${BUILD_EPOCH}" "28"
generate_manifest() {
  local debugfs_ver patch_ver zip_line bash_ver sha_ver
  debugfs_ver="$(debugfs -V 2>&1 | head -n1)"
  patch_ver="$(patch --version | head -n1)"
  zip_line="$(zip -v 2>/dev/null | sed -n '2p')"
  [ -n "${zip_line}" ] || zip_line="zip (version unavailable)"
  bash_ver="$(bash --version | head -n1)"
  sha_ver="$(sha256sum --version | head -n1)"
  cat <<EOF
Q5 Lithium 7 fork — M1a system.img build manifest (spec bob-m1-spec §2.2 op 9)
===============================================================================
git_rev:         ${GITREV}$([ "${GITDIRTY}" -gt 0 ] && printf ' (worktree-dirty)')
git_commit_date: ${GITDATE}
build_epoch:     ${BUILD_EPOCH}

host_tools:
  ${bash_ver}
  ${debugfs_ver}
  simg2img: $(command -v simg2img)
  ${patch_ver}
  ${zip_line}
  ${sha_ver}

donors (sha256 / size / path):
  D-LITHIUM-SYS    $(sha_of "${DONOR_LITHIUM_SYS}") $(wc -c < "${DONOR_LITHIUM_SYS}") ~/q5-flash/rom/system.img
  D-TROM-SYS       $(sha_of "${DONOR_TROM_SYS}") $(wc -c < "${DONOR_TROM_SYS}") ~/.hermes/q5-recovery/base/T-ROM_V2.3/system.img
  D-MINT-SYS       $(sha_of "${DONOR_MINT_SYS}") $(wc -c < "${DONOR_MINT_SYS}") ~/.hermes/q5-recovery/base/Mint_V1.0/system.img
  D-LITHIUM-BOOT   $(sha_of "${DONOR_LITHIUM_BOOT}") $(wc -c < "${DONOR_LITHIUM_BOOT}") ~/q5-flash/rom/boot.img (reference only; M1a does not modify boot)
  D-LITHIUM-SCATTER $(sha_of "${DONOR_LITHIUM_SCATTER}") $(wc -c < "${DONOR_LITHIUM_SCATTER}") ~/q5-flash/rom/MT6582_Android_scatter.txt (package input)

ops applied (M1a §2.2 — the exact 9):
  1 replace /system/lib/hw/audio.primary.mt6582.so   <- T-ROM V2.3  sha256=$(sha_of "${SO_TROM_IMG}")
  2 replace /system/etc/audio_policy.conf            <- T-ROM V2.3  sha256=$(sha_of "${POLICY_TROM_IMG}")
  3 replace /system/etc/audio_effects.conf           <- T-ROM V2.3  sha256=$(sha_of "${EFFECTS_TROM_IMG}")
  4 delete  /system/vendor/etc/mixer_paths.xml       (was 122 B, sha256=$(pin_for img:LITHIUM:vendor/etc/mixer_paths.xml))
  5 add     /system/usr/keylayout/ACCDET.kl          <- Mint V1.0 content  sha256=$(sha_of "${ACCDET_SRC}")
  6 replace /system/usr/keylayout/mtk-kpd.kl         <- patches/§2.5  sha256=${MTKKPD_SHA}
  7 patch   /system/usr/keylayout/Generic.kl         <- patches/§2.6  result sha256=$(sha_of "${GENERIC_PATCHED}")
  8 edit    /system/build.prop                       qemu.hw.mainkeys 1 -> 0
  9 add     /system/etc/fork/${MANIFEST_IMG_NAME}    (this file)

notes:
  - base is stock Lithium 7 (Android 7.1.2); audio pair is the verified working
    T-ROM donor combination (ADR-2); kernel and boot.img are untouched in M1a.
  - keylayout merge adds WAKE/WAKE_DROPPED flags, dual-maps 102+172 -> HOME and
    carries Mint's ACCDET.kl headset keys (ADR-4).
  - NVRAM partition untouched; no donor binaries embedded in the repository.
EOF
}
generate_manifest > "${MANIFEST_FILE}"
[ -s "${MANIFEST_FILE}" ] || die "op9: generated manifest is empty"
df_write "${OPLOG}" "${IMG_FORK}" "write ${MANIFEST_FILE} ${FORK_ETC_DIR}/${MANIFEST_IMG_NAME}"
df_write_inode "${OPLOG}" "${IMG_FORK}" "${FORK_ETC_DIR}/${MANIFEST_IMG_NAME}" \
  "0100644" "0" "0" "${BUILD_EPOCH}" "${BUILD_EPOCH}" "${BUILD_EPOCH}" "${BUILD_EPOCH}" "28"
df_dump "${IMG_FORK}" "${FORK_ETC_DIR}/${MANIFEST_IMG_NAME}" "${TMP_DIR}/op9.check"
assert_sha "${TMP_DIR}/op9.check" "$(sha_of "${MANIFEST_FILE}")" "op9 result ${FORK_ETC_DIR}/${MANIFEST_IMG_NAME}"
df_assert_md "${IMG_FORK}" "${FORK_ETC_DIR}" \
  "$(printf '%s' "0755 0 0 4096 ${BUILD_EPOCH} ${BUILD_EPOCH} ${BUILD_EPOCH} ${BUILD_EPOCH} 28")" \
  "op9 dir ${FORK_ETC_DIR}"
df_assert_md "${IMG_FORK}" "${FORK_ETC_DIR}/${MANIFEST_IMG_NAME}" \
  "$(printf '%s' "0644 0 0 $(wc -c < "${MANIFEST_FILE}") ${BUILD_EPOCH} ${BUILD_EPOCH} ${BUILD_EPOCH} ${BUILD_EPOCH} 28")" \
  "op9 file ${FORK_ETC_DIR}/${MANIFEST_IMG_NAME}"
mdf "op9 OK"

# ---------------------------------------------------------------- re-pin parent dirs
# rm/write/mkdir above update parent dir {c,a,m}time with wall-clock; restore
# donor identity (sizes/mode are untouched by these ops).
dirtuple_sif() { # LOG IMG DIRPATH TUPLE
  df_write "$1" "$2" \
    "sif ${3} mtime @$(getf "$4" 5)" \
    "sif ${3} atime @$(getf "$4" 6)" \
    "sif ${3} ctime @$(getf "$4" 7)"
}
dirtuple_sif "${OPLOG}" "${IMG_FORK}" "/"                  "${DONOR_MD_ROOT}"
dirtuple_sif "${OPLOG}" "${IMG_FORK}" "/etc"               "${DONOR_MD_ETC}"
dirtuple_sif "${OPLOG}" "${IMG_FORK}" "/usr/keylayout"     "${DONOR_MD_KEYLAYOUT}"
dirtuple_sif "${OPLOG}" "${IMG_FORK}" "/lib/hw"            "${DONOR_MD_LIBHW}"
dirtuple_sif "${OPLOG}" "${IMG_FORK}" "/vendor/etc"        "${DONOR_MD_VENDORETC}"
df_assert_md "${IMG_FORK}" "/"              "${DONOR_MD_ROOT}"       "parent-dir re-pin /"
df_assert_md "${IMG_FORK}" "/etc"           "${DONOR_MD_ETC}"        "parent-dir re-pin /etc"
df_assert_md "${IMG_FORK}" "/usr/keylayout" "${DONOR_MD_KEYLAYOUT}"  "parent-dir re-pin /usr/keylayout"
df_assert_md "${IMG_FORK}" "/lib/hw"        "${DONOR_MD_LIBHW}"      "parent-dir re-pin /lib/hw"
df_assert_md "${IMG_FORK}" "/vendor/etc"    "${DONOR_MD_VENDORETC}"  "parent-dir re-pin /vendor/etc"

# ---------------------------------------------------------------- superblock wtime fix
# Every debugfs -w session re-stamps superblock s_wtime (=time(NULL)) at close via
# ext2fs_flush, which breaks byte-identical re-runs (§2.0 hard rule 4). The donor's
# s_wtime is zero; all debugfs sessions are finished here, so restore the donor's
# exact 4 bytes directly in the container file. Read-only debugfs sessions never
# touch this field, so the value survives staging (30) and verification (99).
dd if=/dev/zero of="${IMG_FORK}" bs=4 seek=$(( (1024 + 48) / 4 )) count=1 conv=notrunc status=none
fork_sb_wtime="$(od -An -tx4 -j $((1024 + 48)) -N 4 "${IMG_FORK}" | tr -d ' \n')"
[ "${fork_sb_wtime}" = "${DONOR_SB_WTIME_HEX}" ] \
  || die "superblock s_wtime not donor-pinned (got ${fork_sb_wtime}, want ${DONOR_SB_WTIME_HEX})"

log "stage 20 complete: 9 ops applied and verified (see ${OPLOG})"
