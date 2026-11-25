#!/usr/bin/env bash
# 00_env.sh — shared environment, tool checks and donor-pin verification.
#
# Sourced (never executed) by every build/*.sh stage of the M1a pipeline.
# Spec: .specs/bob-m1-spec.md §2.0 (hard rules), §2.9 (conventions).
#
# Conventions implemented here:
#   - set -euo pipefail / IFS are set by the CALLING script (its banner), and
#     re-asserted at the bottom of this file defensively.
#   - No `cd` anywhere; all paths absolute.
#   - Every donor read is hash-asserted against manifests/donors.sha256.
#   - debugfs ALWAYS exits 0, even on failed commands (verified empirically on
#     e2fsprogs 1.47.0) — therefore every mutation is verified by read-back,
#     never by exit code.
# shellcheck shell=bash

# ---------------------------------------------------------------- paths
_m1a_script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(git -C "${_m1a_script_dir}/.." rev-parse --show-toplevel)" \
  || { printf '[forgem1a][FATAL] not inside the fork git repo\n' >&2; exit 1; }
unset _m1a_script_dir

WORK_DIR="${REPO_ROOT}/work"
OUT_DIR="${REPO_ROOT}/out"
TMP_DIR="${WORK_DIR}/tmp"
IMG_FORK="${WORK_DIR}/images/system-fork.img"      # writable staging copy (debugfs -w target)

# Donors (read-only external artifacts; NEVER copied into the repo, never modified)
DONOR_LITHIUM_BOOT="${HOME}/q5-flash/rom/boot.img"
DONOR_LITHIUM_SYS="${HOME}/q5-flash/rom/system.img"
DONOR_LITHIUM_SCATTER="${HOME}/q5-flash/rom/MT6582_Android_scatter.txt"
DONOR_TROM_SYS="${HOME}/.hermes/q5-recovery/base/T-ROM_V2.3/system.img"
DONOR_MINT_SYS="${HOME}/.hermes/q5-recovery/base/Mint_V1.0/system.img"

DONOR_MANIFEST="${REPO_ROOT}/manifests/donors.sha256"
PATCH_DIR="${REPO_ROOT}/patches"

# Geometry (spec E9 / §2.3): Lithium system size class; Mint ANDROID ceiling.
LITHIUM_SYS_SIZE_CLASS=761761792
MINT_ANDROID_CEILING=$((0x33400000))

# SELinux context carried by every donor system file (E6/E7 stat evidence);
# written out as a 26-byte value file ("u:object_r:system_file:s0" + NUL) by
# 10_unpack_system.sh and applied to new/rewritten inodes with debugfs ea_set.
SELINUX_LABEL_FILE="${WORK_DIR}/selinux-label.bin"
# Fork-authored inode timestamps use the HEAD commit epoch of the build tree:
# same repo state + same donors => byte-identical output (spec hard rule 4).

# ---------------------------------------------------------------- logging
log() { printf '[forgem1a] %s\n' "$*"; }
warn() { printf '[forgem1a][WARN] %s\n' "$*" >&2; }
die() {
  printf '[forgem1a][FATAL] %s\n' "$*" >&2
  exit 1
}

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: ${t}"
  done
}

# ---------------------------------------------------------------- hashing/pins
sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

# pin_for LABEL — echo the pinned sha256 for a label from manifests/donors.sha256.
# Donor-file labels are the paths after "~/"; in-image labels are "img:<DONOR>:<path>".
# Absolute paths under $HOME are normalized to the manifest's "~/..." label form.
pin_for() {
  local lbl h
  lbl="${1}"
  case "${lbl}" in
    "${HOME}"/*) lbl="~${lbl#"${HOME}"}" ;;
    img:*:/*)    lbl="$(printf '%s' "${lbl}" | sed 's#^\(img:[^:]*\):/\+#\1:#')" ;;
  esac
  h="$(awk -v lbl="${lbl}" '$2 == lbl { print $1; exit }' "${DONOR_MANIFEST}")"
  [ -n "${h}" ] || die "no pin found in ${DONOR_MANIFEST} for '${1}' (aborting per §2.10)"
  printf '%s' "${h}"
}

# verify_donor_pins — full sha256sum -c of the [donor] section (lines whose label
# starts with "~/", expanded to $HOME). The [extract] (img:*) pins are asserted
# by the stages that actually read inside the donor images.
verify_donor_pins() {
  local pinfile n
  # --tmpdir: donor pin temp lives in $TMPDIR//tmp and must not depend on
  # work/ existing yet (stage 10 verifies pins BEFORE creating work/).
  pinfile="$(mktemp --tmpdir donorpins.XXXXXXXX)" \
    || die "cannot create pinfile temp"
  grep -E '^[0-9a-f]{64}  ~/' "${DONOR_MANIFEST}" \
    | sed "s|  ~/|  ${HOME}/|" > "${pinfile}"
  n="$(wc -l < "${pinfile}")"
  [ "${n}" -eq 5 ] || die "manifests/donors.sha256: expected 5 [donor] lines, found ${n}"
  if ! sha256sum --quiet -c "${pinfile}"; then
    rm -f "${pinfile}"
    die "donor pin mismatch (manifests/donors.sha256) — STOP per §2.10: re-inventory donors with Bob"
  fi
  rm -f "${pinfile}"
  log "donor pins verified (5 files)"
}

assert_sha() { # FILE WANT_GITHUBLABEL[optional msg]
  local file="$1" want="$2" label="${3:-${file}}"
  local got
  got="$(sha_of "${file}")"
  [ "${got}" = "${want}" ] \
    || die "sha256 mismatch for ${label}: got ${got}, want ${want}"
}

# ---------------------------------------------------------------- debugfs primitives
# df_read IMG CMD... — run read-only commands in one debugfs session, print output.
df_read() {
  local img="$1" c
  shift
  {
    for c in "$@"; do printf '%s\n' "${c}"; done
    printf 'quit\n'
  } | debugfs -f - "${img}" 2>/dev/null
}

# df_write LOG IMG CMD... — mutating session. Appends session transcript to LOG.
# NOTE: exit status is meaningless (debugfs exits 0); callers must read-back.
df_write() {
  local logf="$1" img="$2" c cmdfile
  shift 2
  cmdfile="$(mktemp "${TMP_DIR}/debugfs.XXXXXX")"
  : > "${logf}"
  {
    for c in "$@"; do printf '%s\n' "${c}"; done
    printf 'quit\n'
  } > "${cmdfile}"
  { printf 'debugfs -w session on %s:\n' "${img}"; cat "${cmdfile}"; printf -- '---- output ----\n'; } >> "${logf}"
  debugfs -w -f "${cmdfile}" "${img}" >> "${logf}" 2>&1 || true
  rm -f "${cmdfile}"
  # Guard: debugfs error phrases — absent-path writes, corrupt fs, bad syntax.
  # (Expected-error paths in the pipeline are pre-checked with df_exists first.)
  if grep -Eq 'while trying|No such file|File not found|Bad magic|Corrupt|Invalid|error occurred|Failed|failed to' "${logf}" \
    && ! grep -q 'IGNORE-GUARD' "${logf}"; then
    grep -E 'while trying|No such file|File not found|Bad magic|Corrupt|Invalid|error occurred|Failed|failed to' "${logf}"
    die "debugfs session reported errors (see ${logf}) — aborting"
  fi
  return 0
}

# df_exists IMG PATH → 0/1
df_exists() {
  df_read "$1" "stat ${2}" 2>/dev/null | grep -q '^ *Inode: '
}

# df_md IMG PATH → "mode uid gid size mtime atime ctime crtime extra_isize"
# (times in decimal seconds; nsec is 0 across the donor image)
df_md() {
  local img="$1" path="$2" st hex mode uid gid size extra dec
  st="$(df_read "${img}" "stat ${path}")"
  [ -n "${st}" ] || die "df_md: no stat output for ${path} on ${img}"
  mode="$(printf '%s\n' "${st}" | sed -n 's/.*Mode:  *\([0-9]*\).*/\1/p' | head -n1)"
  uid="$(printf '%s\n' "${st}" | sed -n 's/^User: *\([0-9]*\).*/\1/p' | head -n1)"
  gid="$(printf '%s\n' "${st}" | sed -n 's/^User: *[0-9]* *Group: *\([0-9]*\).*/\1/p' | head -n1)"
  size="$(printf '%s\n' "${st}" | sed -n 's/^User: *[0-9]* *Group: *[0-9]*.*Size: \([0-9]*\)/\1/p' | head -n1)"
  extra="$(printf '%s\n' "${st}" | sed -n 's/^Size of extra inode fields: \([0-9]*\).*/\1/p' | head -n1)"
  local out="${mode} ${uid:-?} ${gid:-?} ${size:-?}"
  for hex_tag in ctime atime mtime crtime; do
    hex="$(printf '%s\n' "${st}" | sed -n "s/^ *${hex_tag}: 0x\([0-9a-f]*\):.*/\1/p" | head -n1)"
    [ -n "${hex}" ] || die "df_md: ${hex_tag} missing for ${path} on ${img}"
    dec=$((16#${hex}))
    out="${out} ${dec}"
  done
  out="${out} ${extra:-0}"
  printf '%s\n' "${out}"
}

# df_assert_md IMG PATH WANT_MD LABEL — WANT_MD in df_md format ("0644 0 0 ...")
df_assert_md() {
  local img="$1" path="$2" want="$3" label="${4:-$2}" got
  if ! got="$(df_md "${img}" "${path}")"; then
    die "df_assert_md: ${label} missing on ${img}"
  fi
  [ "${got}" = "${want}" ] \
    || die "inode metadata mismatch for ${label}:
  got:  ${got}
  want: ${want}"
}

# df_dump IMG PATH OUTFILE
df_dump() {
  df_read "$1" "dump ${2} ${3}" >/dev/null
  [ -f "$3" ] || die "df_dump: ${2} -> ${3} produced nothing (missing in image?)"
}

# df_ls_names IMG DIR — entry names from `ls -l` (skips . and ..)
# debugfs ls -l row: "<inode> <mode6> (<nlink>) <uid> <gid> <size> <D-Mon-Y> <HH:MM> <name...>"
# NOTE: for an empty directory the grep has no output and would exit 1 under
# pipefail — the brace group forces success so "empty listing" is a valid result.
df_ls_names() {
  df_read "$1" "ls -l ${2}" \
    | sed -nE 's/^ *([0-9]+) +([0-9]+) *\(([0-9]+)\) *([0-9-]+) +([0-9]+) +([0-9]+) +([0-9]+)-[A-Za-z]+-[0-9]+ +[0-9]+:[0-9]+ +(.+)$/\8/p' \
    | { grep -vxF -e '.' -e '..' || true; }
}

# df_write_inode — canonical "restore donor-like inode identity" sequence after
# debugfs `write`: mode/uid/gid/pinned times/pinned crtime/extra_isize/selinux xattr.
# Usage: df_write_inode LOG IMG PATH MODE UID GID MTIME ATIME CTIME CRTIME EXTRA
df_write_inode() {
  local logf="$1" img="$2" path="$3" mode="$4" uid="$5" gid="$6" \
    mtime="$7" atime="$8" ctime="$9" crtime="${10}" extra="${11}"
  df_write "${logf}" "${img}" \
    "sif ${path} mode ${mode}" \
    "sif ${path} uid ${uid}" \
    "sif ${path} gid ${gid}" \
    "sif ${path} mtime @${mtime}" \
    "sif ${path} atime @${atime}" \
    "sif ${path} ctime @${ctime}" \
    "sif ${path} crtime @${crtime}" \
    "sif ${path} extra_isize ${extra}" \
    "ea_set -f ${SELINUX_LABEL_FILE} ${path} security.selinux"
}

# ---------------------------------------------------------------- stage bootstrap
ensure_dirs() {
  mkdir -p "${WORK_DIR}/images" "${WORK_DIR}/assets" "${WORK_DIR}/stats" "${TMP_DIR}" "${OUT_DIR}"
}

set -euo pipefail
IFS=$'\n\t'
