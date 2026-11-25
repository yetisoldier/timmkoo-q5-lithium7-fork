#!/usr/bin/env bash
# 90_package.sh — M1a stage 4: package artifacts.
#
# Emits (spec §2.3):
#   out/scatter-fork.txt — the Lithium scatter with only BOOTIMG+ANDROID rows
#                          keeping file_name; every other row set to file_name: NONE
#   out/SHA256SUMS.txt   — covers out/system.img + out/scatter-fork.txt
#   out/fork-m1a-system.zip — flash bundle (system.img + scatter + SHA256SUMS)
#   out/fork-m1a-system.zip.sha256
#
# The zip is deterministic: entry mtimes pinned to the build tree's HEAD commit
# epoch, and `zip -X` strips uid/gid/extra fields.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=00_env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/00_env.sh"
require_tools sha256sum zip awk touch diff

log "stage 90: packaging"
ensure_dirs
verify_donor_pins
[ -f "${OUT_DIR}/system.img" ] || die "stage 90 requires ${OUT_DIR}/system.img (run 30 first)"
[ -f "${DONOR_LITHIUM_SCATTER}" ] || die "donor scatter missing"

BUILD_EPOCH="$(git -C "${REPO_ROOT}" log -1 --format=%ct)"

# ---------------------------------------------------------------- scatter subset
awk '
  $1 == "partition_name:" { name = $2 }
  $1 == "file_name:" {
    if (name != "BOOTIMG" && name != "ANDROID") { print "  file_name: NONE"; next }
    print; next
  }
  { print }
' "${DONOR_LITHIUM_SCATTER}" > "${OUT_DIR}/scatter-fork.txt"

# verify: diff touches file_name rows only; BOOTIMG/ANDROID survive verbatim
mapfile -t changed < <(diff -- "${DONOR_LITHIUM_SCATTER}" "${OUT_DIR}/scatter-fork.txt" | grep -E '^[<>]' || true)
non_fn=0
for ln in "${changed[@]}"; do
  case "${ln}" in *file_name:*) ;; *) non_fn=$((non_fn + 1)) ;; esac
done
[ "${non_fn}" -eq 0 ] || die "scatter transform touched non-file_name lines"
[ "$(grep -c '  file_name: boot.img' "${OUT_DIR}/scatter-fork.txt")" -eq 1 ] || die "BOOTIMG row lost"
[ "$(grep -c '  file_name: system.img' "${OUT_DIR}/scatter-fork.txt")" -eq 1 ] || die "ANDROID row lost"
n_none="$(grep -c '  file_name: NONE' "${OUT_DIR}/scatter-fork.txt")"
log "scatter-fork.txt: ${n_none} rows set to NONE, BOOTIMG+ANDROID kept"

# ---------------------------------------------------------------- checksums
# shellcheck disable=SC2016
sha256sum "${OUT_DIR}/system.img" "${OUT_DIR}/scatter-fork.txt" \
  | awk '{ n = split($2, a, "/"); $2 = a[n]; print }' > "${OUT_DIR}/SHA256SUMS.txt"
grep -q "^$(sha_of "${OUT_DIR}/system.img")" "${OUT_DIR}/SHA256SUMS.txt" \
  || die "SHA256SUMS.txt does not cover out/system.img"

# ---------------------------------------------------------------- zip bundle
touch -d "@${BUILD_EPOCH}" "${OUT_DIR}/system.img" "${OUT_DIR}/scatter-fork.txt" "${OUT_DIR}/SHA256SUMS.txt"
rm -f "${OUT_DIR}/fork-m1a-system.zip" "${OUT_DIR}/fork-m1a-system.zip.sha256"
zip -X -q -j "${OUT_DIR}/fork-m1a-system.zip" \
  "${OUT_DIR}/system.img" "${OUT_DIR}/scatter-fork.txt" "${OUT_DIR}/SHA256SUMS.txt"
printf '%s  fork-m1a-system.zip\n' "$(sha_of "${OUT_DIR}/fork-m1a-system.zip")" \
  > "${OUT_DIR}/fork-m1a-system.zip.sha256"

log "stage 90 complete:"
log "  out/system.img              $(sha_of "${OUT_DIR}/system.img" | head -c 16)…"
log "  out/scatter-fork.txt        $(sha_of "${OUT_DIR}/scatter-fork.txt" | head -c 16)…"
log "  out/SHA256SUMS.txt          $(sha_of "${OUT_DIR}/SHA256SUMS.txt" | head -c 16)…"
log "  out/fork-m1a-system.zip     $(sha_of "${OUT_DIR}/fork-m1a-system.zip" | head -c 16)…"
