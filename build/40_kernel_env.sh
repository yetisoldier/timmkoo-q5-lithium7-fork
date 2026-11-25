#!/usr/bin/env bash
# 40_kernel_env.sh — shared environment for the M1b kernel stages (45/50/55).
#
# Spec: .specs/bob-m2-spec.md §4.0 (layout), §4.1 (α), §4.2 (β), §4.4 (forbidden).
# Conventions follow build/00_env.sh (M1a): set -euo pipefail by CALLER banner,
# absolute paths, hash-asserted reads, [forgem1b] log prefix.
#
# Manifests:
#   manifests/donors.sha256          — M1a donor pins (Lithium boot.img lives here)
#   manifests/kernel-sources.sha256  — M1b pins: Lithium kernel blob + ramdisk blob,
#                                      every donor-sourced file copied into the tree,
#                                      donor repo HEAD revisions (re-clone anchors).
# Kernel tree / donors are GITIGNORED references; nothing in them is ever committed.
# shellcheck shell=bash

_m1b_script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(git -C "${_m1b_script_dir}/.." rev-parse --show-toplevel)" \
  || { printf '[forgem1b][FATAL] not inside the fork git repo\n' >&2; exit 1; }
unset _m1b_script_dir

# ---------------------------------------------------------------- paths
OUT_DIR="${REPO_ROOT}/out"
SCRATCH="${HOME}/.hermes/cache/scratch/opencode/forge-m1b"
KDIR="${REPO_ROOT}/.reference-kernel-3.10.54/kernel-3.10"
KERNEL_REPO_ROOT="${REPO_ROOT}/.reference-kernel-3.10.54"
TC="${REPO_ROOT}/.reference-kernel-3.10.54/arm-eabi-4.8/bin/arm-eabi-"
BUILD_ALPHA="${KDIR}/build-alpha"
BUILD_BETA="${KDIR}/build-beta"
MTK_TOOLS="${HOME}/.hermes/cache/scratch/opencode/bob-m1/mtk-tools"

# Pinned Lithium donor (boot.img carries the stock ramdisk + reference header)
DONOR_LITHIUM_BOOT="${HOME}/q5-flash/rom/boot.img"
DONOR_MANIFEST="${REPO_ROOT}/manifests/donors.sha256"
KSRC_MANIFEST="${REPO_ROOT}/manifests/kernel-sources.sha256"

# Bob's scratch comparison blobs (hash-asserted against kernel-sources manifest)
LITHIUM_DECOMP="${HOME}/.hermes/cache/scratch/opencode/bob-m2/lithium-kernel.decomp"
# Derived comparison surface: always regenerated from the PINNED decomp so the
# parity counts are invariant to bob-m2 scratch edits (single source of truth).
LITHIUM_STRINGS="${SCRATCH}/lithium-strings-derived.txt"

# Donor source caches (blobless-sparse clones; files hash-asserted below)
DONOR_GS="${REPO_ROOT}/donors/persimmon"
DONOR_SPR="${REPO_ROOT}/donors/sprout"
DONOR_E5="${REPO_ROOT}/donors/e5fhd"
DONOR_SEL="${REPO_ROOT}/donors/selene"

# ---------------------------------------------------------------- deterministic build identity
# Kernel banners embed build context; pin it so identical sources produce
# byte-identical zImages across re-runs (M1a principle: same repo state +
# same inputs ⇒ same bytes). Timestamp = fork HEAD commit time, ISO-strict.
KBUILD_HEAD_EPOCH="$(git -C "${REPO_ROOT}" log -1 --format=%ct)"
KBUILD_HEAD_TS="$(git -C "${REPO_ROOT}" log -1 --format=%cd --date=iso-strict-local)"
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="${KBUILD_HEAD_TS}"
export KBUILD_BUILD_USER=forge
export KBUILD_BUILD_HOST=fork
# MTK vendor drivers (wlan/ccci/mali/…) embed __DATE__/__TIME__ debug stamps and
# kbuild here full-rebuilds (an O= tree quirk), so the stamps MUST be pinned or
# every rebuild churns the blob bytes. Pinned via CC. IMPORTANT details:
#   * CC must be passed as a make COMMAND-LINE argument (env loses to `CC =` in
#     the Makefile) — 45/50 pass CC="${BUILD_CC}".
#   * The macro values MUST be whitespace-free: kbuild helpers like
#     scripts/checksyscalls.sh re-split their args unquoted ($*), which would
#     break on "Nov 25 2026". So the date stamp uses underscores ("Nov_25_2026").
KBUILD_HEAD_EPOCH="$(git -C "${REPO_ROOT}" log -1 --format=%ct)"
KBUILD_HEAD_TS="$(git -C "${REPO_ROOT}" log -1 --format=%cd --date=iso-strict-local)"
KBUILD_DATE="$(date -u -d "@${KBUILD_HEAD_EPOCH}" '+%b_%d_%Y')"   # e.g. Nov_25_2026
KBUILD_TIME="$(date -u -d "@${KBUILD_HEAD_EPOCH}" '+%H:%M:%S')"
BUILD_CC="${TC}gcc -Wno-builtin-macro-redefined -U__DATE__ -U__TIME__ -D__DATE__='\"${KBUILD_DATE}\"' -D__TIME__='\"${KBUILD_TIME}\"'"
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="${KBUILD_HEAD_TS}"
export KBUILD_BUILD_USER=forge
export KBUILD_BUILD_HOST=fork
export KBUILD_HEAD_EPOCH KBUILD_HEAD_TS KBUILD_DATE KBUILD_TIME

# ---------------------------------------------------------------- logging
log()  { printf '[forgem1b] %s\n' "$*"; }
warn() { printf '[forgem1b][WARN] %s\n' "$*" >&2; }
die()  { printf '[forgem1b][FATAL] %s\n' "$*" >&2; exit 1; }

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: ${t}"
  done
}

# ---------------------------------------------------------------- hashing/pins
sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

# pin_from MANIFEST LABEL — echo the pinned sha256 for a label.
pin_from() {
  local manifest="$1" lbl h
  h="$(awk -v l="${2}" '$2 == l { print $1; exit }' "${manifest}")"
  [ -n "${h}" ] || die "no pin '${2}' in ${manifest}"
  printf '%s' "${h}"
}

# assert_sha FILE WANT [label]
assert_sha() {
  local got want
  got="$(sha_of "$1")"
  want="$2"
  [ "${got}" = "${want}" ] \
    || die "sha256 mismatch for ${3:-$1}: got ${got}, want ${want}"
}

# verify_lithium_donor — the boot.img we repack against must still be the pinned one.
verify_lithium_donor() {
  local pin
  pin="$(pin_from "${DONOR_MANIFEST}" "~/q5-flash/rom/boot.img")"
  assert_sha "${DONOR_LITHIUM_BOOT}" "${pin}" "D-LITHIUM-BOOT"
  log "lithium boot.img pin verified (${pin:0:12}…)"
}

# assert_ksrc_label FILE LABEL — file must match its pinned sha in kernel-sources.
assert_ksrc_label() {
  local pin
  pin="$(pin_from "${KSRC_MANIFEST}" "${2}")"
  assert_sha "$1" "${pin}" "${2}"
  log "pin ok: ${2} (${pin:0:12}…)"
}

# ---------------------------------------------------------------- lithium blob pins
LITHIUM_KERNEL_IMG_SHA="5217dd41c77b8184bd63fe56bd95bbedf89b7cb08a2a6f073091c11c31bbe88c"
LITHIUM_DECOMP_SHA="d284ba1698c77267aaeafb64abd3defcb82f7d09bcc5ddbb3538e303dc69ab53"
# Raw in-image ramdisk blob (512B MTK ROOTFS header + cpio.gz), extracted in 55.
LITHIUM_RAMDISK_BLOB_SHA="c0be6c46333b52f08dd725353f69bd6cbe8cf402838d5d7b67cfcc09522c62cf"
# Lithium boot.img header facts (asserted by 55 before every repack).
LITHIUM_PAGESIZE=2048
LITHIUM_KERNEL_SIZE=3809720
LITHIUM_RAMDISK_SIZE=1394157
LITHIUM_BOARD="1441186574"
LITHIUM_CMDLINE="bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug"

# extract_lithium_ramdisk OUTFILE — dump the raw in-image ramdisk payload
# (MTK ROOTFS header + cpio.gz) from the pinned donor boot.img and hash-assert.
extract_lithium_ramdisk() {
  local out="$1"
  python3 - "${DONOR_LITHIUM_BOOT}" "${out}" <<'PYEOF'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
full = open(src, 'rb').read()
magic, ksz, kaddr, rsz, raddr, ssz, saddr, taddr, pg, u1, u2 = struct.unpack_from('8s10I', full, 0)
assert magic == b'ANDROID!', magic
ram1 = (1 + (ksz + pg - 1) // pg) * pg
blob = full[ram1:ram1 + rsz]
assert blob[:4] == b'\x88\x16\x88\x58', 'ramdisk MTK header missing'
assert blob[8:14] == b'ROOTFS', blob[8:14]
assert blob[14:16] == b'\x00\x00', 'ROOTFS type field not NUL-padded'
open(dst, 'wb').write(blob)
print(f'lithium ramdisk blob: {len(blob)} bytes @0x{ram1:x}')
PYEOF
  assert_sha "${out}" "${LITHIUM_RAMDISK_BLOB_SHA}" "lithium ramdisk blob"
}

set -euo pipefail
IFS=$'\n\t'
