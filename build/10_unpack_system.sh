#!/usr/bin/env bash
# 10_unpack_system.sh — M1a stage 1: stage a mutable fork copy of D-LITHIUM-SYS
# and extract every donor asset the op table (§2.2) needs, with hash assertions.
#
# Method: §2.0 hard rule 5 — debugfs -w surgery on a work/ copy. D-LITHIUM-SYS is
# copied to work/images/system-fork.img (the ONLY writable image in the pipeline);
# T-ROM/Mint donors are read in place (or sparse-converted to work/ first).
#
# All donor reads are hash-asserted against manifests/donors.sha256 (§2.0 rule 2).
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=00_env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/00_env.sh"
require_tools debugfs sha256sum simg2img dumpe2fs cmp

log "stage 10: staging fork image + extracting donor assets"
verify_donor_pins
ensure_dirs
rm -rf "${WORK_DIR:?}/images" "${WORK_DIR:?}/assets" "${WORK_DIR:?}/stats" "${WORK_DIR:?}/tmp"
ensure_dirs

# ---------------------------------------------------------------- sparse handling
# Android sparse header magic 0xED26FF3A (LE bytes 3a ff 26 ed). Donors verified
# raw this session; the conversion path exists so a future donor refresh cannot
# silently produce garbage.
declare -a ACTIVE_LITHIUM ACTIVE_TROM ACTIVE_MINT

stage_raw() { # DONOR_PATH TAG → echoes usable raw-image path
  local donor="$1" tag="$2" magic raw
  magic="$(head -c 4 "${donor}" | od -An -tx1 | tr -d ' \n')"
  if [ "${magic}" = "3aff26ed" ]; then
    raw="${WORK_DIR}/images/${tag}.raw.img"
    log "${tag}: sparse donor detected -> simg2img -> ${raw}"
    simg2img "${donor}" "${raw}"
    sha_of "${donor}" > "${WORK_DIR}/stats/${tag}.donor.sha256"
    log "${tag}: converted raw image sha256: $(sha_of "${raw}")"
    printf '%s' "${raw}"
  else
    printf '%s' "${donor}"
  fi
}

ACTIVE_LITHIUM="$(stage_raw "${DONOR_LITHIUM_SYS}" lithium-sys)"
ACTIVE_TROM="$(stage_raw "${DONOR_TROM_SYS}" trom-sys)"
ACTIVE_MINT="$(stage_raw "${DONOR_MINT_SYS}" mint-sys)"

# ---------------------------------------------------------------- fork staging
cp -- "${ACTIVE_LITHIUM}" "${IMG_FORK}"
assert_sha "${IMG_FORK}" "$(pin_for ~/q5-flash/rom/system.img)" "work/images/system-fork.img (staged copy of D-LITHIUM-SYS)"
log "fork staging copy ready: ${IMG_FORK}"

# ---------------------------------------------------------------- selinux label file
printf 'u:object_r:system_file:s0\000' > "${SELINUX_LABEL_FILE}"
[ "$(wc -c < "${SELINUX_LABEL_FILE}")" -eq 26 ] || die "selinux label bytes != 26"

# ---------------------------------------------------------------- donor inode-identity capture
# df_md tuples ("mode uid gid size ctime atime mtime crtime extra_isize") recorded
# from the DONORS and replayed by 20_after mutation so directory/file metadata
# outside the 9-op content delta stays donor-identical (determinism + §3.2 checks).
{
  printf 'DONOR_MD_ROOT="%s"\n'        "$(df_md "${ACTIVE_LITHIUM}" /)"
  printf 'DONOR_MD_ETC="%s"\n'         "$(df_md "${ACTIVE_LITHIUM}" /etc)"
  printf 'DONOR_MD_KEYLAYOUT="%s"\n'   "$(df_md "${ACTIVE_LITHIUM}" /usr/keylayout)"
  printf 'DONOR_MD_LIBHW="%s"\n'       "$(df_md "${ACTIVE_LITHIUM}" /lib/hw)"
  printf 'DONOR_MD_VENDORETC="%s"\n'   "$(df_md "${ACTIVE_LITHIUM}" /vendor/etc)"
  printf 'DONOR_MD_BUILDPROP="%s"\n'   "$(df_md "${ACTIVE_LITHIUM}" /build.prop)"
  printf 'DONOR_MD_MTKKPD="%s"\n'      "$(df_md "${ACTIVE_LITHIUM}" /usr/keylayout/mtk-kpd.kl)"
  printf 'DONOR_MD_GENERIC="%s"\n'     "$(df_md "${ACTIVE_LITHIUM}" /usr/keylayout/Generic.kl)"
  printf 'DONOR_MD_SO_LITHIUM="%s"\n'  "$(df_md "${ACTIVE_LITHIUM}" /lib/hw/audio.primary.mt6582.so)"
  printf 'DONOR_SB_WTIME_HEX="%s"\n' \
    "$(od -An -tx4 -j $((1024 + 48)) -N 4 "${ACTIVE_LITHIUM}" | tr -d ' \n')"
  printf 'LITHIUM_ACTIVE_IMG="%s"\n'   "${ACTIVE_LITHIUM}"
  printf 'TROM_ACTIVE_IMG="%s"\n'      "${ACTIVE_TROM}"
  printf 'MINT_ACTIVE_IMG="%s"\n'      "${ACTIVE_MINT}"
} > "${WORK_DIR}/stats/donor-identity.env"

# T-ROM audio pair + effects: extract, pin-hash, assert donor perms (root:root 0644 per §2.2 op 1)
# and record donor times for replay.
mkdir -p "${WORK_DIR}/assets/trom"
trom_extract() { # IMG-PATH DEST LABEL
  df_dump "${ACTIVE_TROM}" "$1" "$2"
  assert_sha "$2" "$(pin_for "img:TROM:$1")" "img:TROM:$1"
}
trom_extract /lib/hw/audio.primary.mt6582.so  "${WORK_DIR}/assets/trom/audio.primary.mt6582.so"
trom_extract /etc/audio_policy.conf           "${WORK_DIR}/assets/trom/audio_policy.conf"
trom_extract /etc/audio_effects.conf          "${WORK_DIR}/assets/trom/audio_effects.conf"
{
  printf 'TROM_MD_SO="%s"\n'      "$(df_md "${ACTIVE_TROM}" /lib/hw/audio.primary.mt6582.so)"
  printf 'TROM_MD_POLICY="%s"\n'  "$(df_md "${ACTIVE_TROM}" /etc/audio_policy.conf)"
  printf 'TROM_MD_EFFECTS="%s"\n' "$(df_md "${ACTIVE_TROM}" /etc/audio_effects.conf)"
} >> "${WORK_DIR}/stats/donor-identity.env"
for f in audio.primary.mt6582.so audio_policy.conf audio_effects.conf; do
  case "${f}" in
    audio.*) dp="/lib/hw/${f}" ;;
    *)       dp="/etc/${f}" ;;
  esac
  md="$(df_md "${ACTIVE_TROM}" "${dp}")"
  [ "$(awk '{print $1, $2, $3}' <<<"${md}")" = "0644 0 0" ] \
    || die "T-ROM donor perms for ${f} are not root:root 0644 (got: ${md}); §2.2 op 1-3 expectations violated — STOP"
done

# Mint ACCDET.kl: extract, pin-hash, assert byte-equality with the committed patch asset
mkdir -p "${WORK_DIR}/assets/mint"
df_dump "${ACTIVE_MINT}" /usr/keylayout/ACCDET.kl "${WORK_DIR}/assets/mint/ACCDET.kl"
assert_sha "${WORK_DIR}/assets/mint/ACCDET.kl" "$(pin_for img:MINT:usr/keylayout/ACCDET.kl)" "img:MINT:usr/keylayout/ACCDET.kl"
cmp -- "${WORK_DIR}/assets/mint/ACCDET.kl" "${PATCH_DIR}/usr/keylayout/ACCDET.kl" \
  || die "patches/usr/keylayout/ACCDET.kl differs from Mint donor file (§2.2 op 5 verify 'diff vs Mint == 0' failed)"
printf 'MINT_MD_ACCDET="%s"\n' "$(df_md "${ACTIVE_MINT}" /usr/keylayout/ACCDET.kl)" >> "${WORK_DIR}/stats/donor-identity.env"

# ---------------------------------------------------------------- Lithium "before" dumps (audit trail)
mkdir -p "${WORK_DIR}/assets/lithium"
lith_before() { # IN-IMG-PATH LABEL
  df_dump "${ACTIVE_LITHIUM}" "$1" "${WORK_DIR}/assets/lithium/$2"
  assert_sha "${WORK_DIR}/assets/lithium/$2" "$(pin_for "img:LITHIUM:$1")" "img:LITHIUM:$1"
}
lith_before /lib/hw/audio.primary.mt6582.so  audio.primary.mt6582.so
lith_before /etc/audio_policy.conf           audio_policy.conf
lith_before /etc/audio_effects.conf          audio_effects.conf
lith_before /vendor/etc/mixer_paths.xml      mixer_paths.xml
lith_before /usr/keylayout/mtk-kpd.kl        mtk-kpd.kl
lith_before /usr/keylayout/Generic.kl        Generic.kl
lith_before /build.prop                      build.prop

# Pre-flight structural asserts (donor must look like Bob's forensics assumed)
if df_exists "${ACTIVE_LITHIUM}" /usr/keylayout/ACCDET.kl; then
  die "donor Lithium unexpectedly has /usr/keylayout/ACCDET.kl (E7 said absent) — re-inventory donors"
fi
mapfile -t vendoretc < <(df_ls_names "${ACTIVE_LITHIUM}" /vendor/etc)
[ "${#vendoretc[@]}" -eq 1 ] && [ "${vendoretc[0]}" = "mixer_paths.xml" ] \
  || die "donor /vendor/etc does not contain exactly mixer_paths.xml (got: ${vendoretc[*]:-none})"

# ---------------------------------------------------------------- donor fs facts
dumpe2fs -h "${ACTIVE_LITHIUM}" 2>/dev/null \
  | egrep 'Block count|Block size|Free blocks|Filesystem state' > "${WORK_DIR}/stats/donor-fs.txt"
log "donor fs facts: $(tr '\n' ';' < "${WORK_DIR}/stats/donor-fs.txt")"

log "stage 10 complete (fork copy + extracted assets + donor identity captured)"
