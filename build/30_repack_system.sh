#!/usr/bin/env bash
# 30_repack_system.sh — M1a stage 3: validate the mutated image's filesystem
# identity and publish it to out/system.img.
#
# With the debugfs -w method (§2.0 rule 5) there is no repack: out/system.img IS
# the donor ext4 filesystem with the 9-op content delta. Size/block-count are
# therefore donor-identical by construction; this stage proves it and copies.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=00_env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/00_env.sh"
require_tools debugfs dumpe2fs sha256sum

log "stage 30: validating + publishing out/system.img"
ensure_dirs
verify_donor_pins
[ -f "${IMG_FORK}" ] || die "stage 30 requires ${IMG_FORK} (run 10 + 20 first)"

image_size() { stat -c '%s' "$1"; }

# --- superblock identity ---------------------------------------------------
read_sb() { dumpe2fs -h "$2" 2>/dev/null | egrep "^$1"; }
donor_count="$(read_sb 'Block count' "${DONOR_LITHIUM_SYS}")"
fork_count="$(read_sb 'Block count' "${IMG_FORK}")"
[ "${fork_count}" = "${donor_count}" ] \
  || die "block count drift: donor ${donor_count} vs fork ${fork_count}"
donor_state="$(read_sb 'Filesystem state' "${DONOR_LITHIUM_SYS}")"
fork_state="$(read_sb 'Filesystem state' "${IMG_FORK}")"
[ "${fork_state}" = "${donor_state}" ] \
  || die "filesystem state drift: donor '${donor_state}' vs fork '${fork_state}'"

donor_sz="$(image_size "${DONOR_LITHIUM_SYS}")"
fork_sz="$(image_size "${IMG_FORK}")"
[ "${fork_sz}" -eq "${donor_sz}" ] || die "image size drift: ${fork_sz} != ${donor_sz}"
[ "${fork_sz}" -le "${MINT_ANDROID_CEILING}" ] \
  || die "fork image exceeds Mint ANDROID ceiling (§2.10)"
[ "${fork_sz}" -eq "${LITHIUM_SYS_SIZE_CLASS}" ] \
  || warn "image size ${fork_sz} != documented Lithium class ${LITHIUM_SYS_SIZE_CLASS}"

donor_free="$(read_sb 'Free blocks' "${DONOR_LITHIUM_SYS}" | awk '{print $3}')"
fork_free="$(read_sb 'Free blocks' "${IMG_FORK}" | awk '{print $3}')"
printf 'donor_free=%s fork_free=%s\n' "${donor_free}" "${fork_free}" \
  > "${WORK_DIR}/stats/free-blocks.env"
if [ "$((donor_free - fork_free))" -gt 64 ] || [ "$((fork_free - donor_free))" -gt 64 ]; then
  die "free-block drift beyond 64 blocks: donor ${donor_free} vs fork ${fork_free}"
fi

# --- changed-path sanity on the work image ---------------------------------
for p in lib/hw/audio.primary.mt6582.so etc/audio_policy.conf etc/audio_effects.conf \
         usr/keylayout/mtk-kpd.kl usr/keylayout/Generic.kl usr/keylayout/ACCDET.kl \
         build.prop etc/fork/fork-manifest.txt; do
  df_exists "${IMG_FORK}" "/${p}" || die "stage 30: missing changed path /${p}"
done
df_exists "${IMG_FORK}" /vendor/etc/mixer_paths.xml \
  && die "stage 30: deleted path /vendor/etc/mixer_paths.xml is still present"

# --- publish ---------------------------------------------------------------
mkdir -p "${OUT_DIR}"
cp -- "${IMG_FORK}" "${OUT_DIR}/system.img"
assert_sha "${OUT_DIR}/system.img" "$(sha_of "${IMG_FORK}")" "out/system.img (copy integrity)"
{
  printf 'path=%s\n' "$(readlink -f "${OUT_DIR}/system.img")"
  printf 'size=%s\n' "${fork_sz}"
  printf 'sha256=%s\n' "$(sha_of "${OUT_DIR}/system.img")"
  printf 'donor_blocks=%s fork_blocks=%s donor_free=%s fork_free=%s\n' \
    "$(awk '{print $3}' <<<"${donor_count}")" "$(awk '{print $3}' <<<"${fork_count}")" \
    "${donor_free}" "${fork_free}"
} > "${WORK_DIR}/stats/out-system.info"
log "published out/system.img: ${fork_sz} B, sha256 $(sha_of "${OUT_DIR}/system.img")"
log "stage 30 complete"
