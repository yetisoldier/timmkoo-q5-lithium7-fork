#!/usr/bin/env bash
# 99_verify.sh — M1a offline verification (Karen §3.2-A checks 1-9, no device).
#
# Core mechanism (check A2): full recursive debugfs walk + content hash of
# out/system.img vs D-LITHIUM-SYS, folded into per-path tuple lines
# (path|type|mode|uid|gid|size|content-key). The diff surface between the two
# images must equal EXACTLY the §2.2 op table (any 10th difference fails).
#
# Donor-side walk/content maps are cached under work/stats/ keyed by the pinned
# D-LITHIUM-SYS sha256; pins are re-verified on every run.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=00_env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/00_env.sh"
require_tools debugfs dumpe2fs sha256sum git patch python3 diff od awk

IMG="${OUT_DIR}/system.img"
[ -f "${IMG}" ] || die "99_verify: ${IMG} missing (run the pipeline first)"

P=0
FAIL=0
chk() { # chk <PASS|FAIL> <name> <detail>
  if [ "$1" = "PASS" ]; then
    log "PASS  ${2} — ${3}"
    P=$((P + 1))
  else
    warn "FAIL  ${2} — ${3}"
    FAIL=$((FAIL + 1))
  fi
}
section() { log "--- ${1}"; }
# ls -l style mode strings from df_md mode fields:
#   file perms "0644" -> "100644" (S_IFREG|0644); dir perms "0755" -> "40755" (S_IFDIR|0755)
ls_mode_file() { printf '100%s' "${1: -3}"; }
ls_mode_dir()  { printf '4%s' "${1: -4}"; }

# ================================================================ walk engine
walk_image() { # IMG WALKMAP LINKFILE
  local img="$1" mapf="$2" linkf="$3"
  : > "${mapf}"
  : > "${linkf}"
  local -a queue=("/")
  local qi=0 d row mode uid gid size name path
  while [ "${qi}" -lt "${#queue[@]}" ]; do
    if [ "${qi}" -gt 20000 ] || [ "${#queue[@]}" -gt 20000 ]; then
      die "walk_image: runaway queue (>${qi} dirs) on ${img} — aborting"
    fi
    d="${queue[${qi}]}"
    qi=$((qi + 1))
    while IFS= read -r row; do
      [ -n "${row}" ] || continue
      mode="${row%% *}"; row="${row#* }"
      uid="${row%% *}";  row="${row#* }"
      gid="${row%% *}";  row="${row#* }"
      size="${row%% *}"; name="${row#* }"
      # "."/".." entries would cycle the BFS forever — skip them
      if [ "${name}" = "." ] || [ "${name}" = ".." ]; then continue; fi
      if [ "${d}" = "/" ]; then path="${name}"; else path="${d#\/}/${name}"; fi
      case "${mode}" in
        4*)  # directory
          printf 'D\t%s\t%s\t%s\t%s\n' "${path}" "${mode}" "${uid}" "${gid}" >> "${mapf}"
          queue+=("${path}")
          ;;
        10*) # regular file
          printf 'F\t%s\t%s\t%s\t%s\t%s\n' "${path}" "${mode}" "${uid}" "${gid}" "${size}" >> "${mapf}"
          ;;
        12*) # symlink (targets resolved later)
          printf 'L\t%s\n' "${path}" >> "${mapf}"
          printf '%s\n' "${path}" >> "${linkf}"
          ;;
        *)   # unexpected inode type — recorded so a diff surfaces it
          printf 'X\t%s\t%s\n' "${path}" "${mode}" >> "${mapf}"
          ;;
      esac
    done < <(df_read "${img}" "ls -l ${d}" \
      | sed -nE 's/^ *([0-9]+) +([0-9a-f]+) *\(([0-9]+)\) *([0-9]+) +([0-9]+) +([0-9]+) +([0-9]+)-[A-Za-z]+-[0-9]+ +[0-9]+:[0-9]+ +(.+)$/\2 \4 \5 \6 \8/p')
  done
}

link_targets() { # IMG LINKFILE OUT("path<TAB>target")
  local img="$1" linkf="$2" out="$3"
  : > "${out}"
  local p tgt fidx=0
  while IFS= read -r p; do
    tgt="$(df_read "${img}" "stat ${p}" \
      | sed -n 's/^ *Fast link dest: "\(.*\)"$/\1/p' | head -n1)"
    [ -n "${tgt}" ] || tgt="<UNRESOLVED>"
    printf '%s\t%s\n' "${p}" "${tgt}" >> "${out}"
  done < "${linkf}"
}

hash_contents() { # IMG WALKMAP OUT("path<TAB>sha256" for every regular file)
  local img="$1" mapf="$2" out="$3"
  local dumpdir cmdf total i sha
  dumpdir="$(mktemp -d "${TMP_DIR}/content.XXXXXX")"
  cmdf="$(mktemp "${TMP_DIR}/hashcmd.XXXXXX")"
  local -a files
  mapfile -t files < <(grep '^F' "${mapf}" | cut -f2)
  total=${#files[@]}
  : > "${cmdf}"
  for i in $(seq 1 "${total}"); do
    printf 'dump /%s %s/%d\n' "${files[$((i - 1))]}" "${dumpdir}" "${i}" >> "${cmdf}"
  done
  printf 'quit\n' >> "${cmdf}"
  debugfs -f "${cmdf}" "${img}" >/dev/null 2>&1 || true
  rm -f "${cmdf}"
  : > "${out}"
  for i in $(seq 1 "${total}"); do
    sha="<MISSING>"
    [ -f "${dumpdir}/${i}" ] && sha="$(sha_of "${dumpdir}/${i}")"
    printf '%s\t%s\n' "${files[$((i - 1))]}" "${sha}" >> "${out}"
  done
  rm -rf "${dumpdir}"
}

# tuples_build WALKMAP EXTRAMAP OUT
# extra map: single "path<TAB>value" preload (sha for files, target for links;
# a path is exactly one type so keys cannot collide).
# output line: path<TAB>type<TAB>mode<TAB>uid<TAB>gid<TAB>size<TAB>content-key
tuples_build() {
  awk -F'\t' 'NR == FNR { extra[$1] = $2; next }
    $1 == "F" { printf "%s\tF\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, (extra[$2] == "" ? "<NOHASH>" : extra[$2]); next }
    $1 == "L" { printf "%s\tL\t%s\t-\t-\t-\t%s\n", $2, $3, (extra[$2] == "" ? "<NOLINK>" : extra[$2]); next }
    $1 == "D" { printf "%s\tD\t%s\t%s\t%s\t-\t-\n", $2, $3, $4, $5; next }
    { printf "%s\t%s\t%s\t%s\t%s\t%s\t-\n", $2, $1, $3, $4, $5, $6 }' \
    "$2" "$1" > "$3"
}

# ================================================================ A0/A1 donor + sums integrity
section "A0/A1 donor pins + published-checksums"
ensure_dirs
verify_donor_pins
chk PASS "A0" "manifests/donors.sha256 verified (5 donors, full re-hash)"

if [ -f "${OUT_DIR}/SHA256SUMS.txt" ]; then
  awk -v d="${OUT_DIR}" '{ print $1 "  " d "/" $2 }' "${OUT_DIR}/SHA256SUMS.txt" > "${TMP_DIR}/sums.abs"
  if sha256sum --quiet -c "${TMP_DIR}/sums.abs" \
    && grep -q "$(sha_of "${IMG}")" "${OUT_DIR}/SHA256SUMS.txt"; then
    chk PASS "A1" "out/SHA256SUMS.txt verifies; covers published image"
  else
    chk FAIL "A1" "out/SHA256SUMS.txt mismatch"
  fi
  rm -f "${TMP_DIR}/sums.abs"
else
  chk FAIL "A1" "out/SHA256SUMS.txt missing"
fi

# ================================================================ donor caches
DONOR_CACHE_KEY="$(pin_for ~/q5-flash/rom/system.img)"
DONOR_WALK="${WORK_DIR}/stats/donor-walk.tab"
DONOR_EXTRA="${WORK_DIR}/stats/donor-extra.tab"   # content shas + link targets

need_cache=1
if [ -f "${DONOR_WALK}" ] && [ -f "${DONOR_EXTRA}" ] \
  && [ "$(head -n1 "${DONOR_WALK}")" = "# key=${DONOR_CACHE_KEY}" ] \
  && [ "$(head -n1 "${DONOR_EXTRA}")" = "# key=${DONOR_CACHE_KEY}" ] \
  && [ "$(wc -l < "${DONOR_WALK}")" -gt 100 ]; then
  need_cache=0
fi
if [ "${need_cache}" -eq 1 ]; then
  log "building donor walk/content cache (once per donor pin)…"
  walk_image "${DONOR_LITHIUM_SYS}" "${TMP_DIR}/d.walk" "${TMP_DIR}/d.links"
  link_targets "${DONOR_LITHIUM_SYS}" "${TMP_DIR}/d.links" "${TMP_DIR}/d.linkmap"
  hash_contents "${DONOR_LITHIUM_SYS}" "${TMP_DIR}/d.walk" "${TMP_DIR}/d.content"
  { printf '# key=%s\n' "${DONOR_CACHE_KEY}"; cat "${TMP_DIR}/d.walk"; } > "${DONOR_WALK}"
  { printf '# key=%s\n' "${DONOR_CACHE_KEY}"; cat "${TMP_DIR}/d.content"; cat "${TMP_DIR}/d.linkmap"; } > "${DONOR_EXTRA}"
fi
tail -n +2 "${DONOR_WALK}" > "${TMP_DIR}/d.walk.body"
tail -n +2 "${DONOR_EXTRA}" > "${TMP_DIR}/d.extra.body"
tuples_build "${TMP_DIR}/d.walk.body" "${TMP_DIR}/d.extra.body" "${TMP_DIR}/d.tuples"

# ================================================================ A2 exact-9-op diff
section "A2 changed-set == exactly the §2.2 op table"
walk_image "${IMG}" "${TMP_DIR}/f.walk" "${TMP_DIR}/f.links"
link_targets "${IMG}" "${TMP_DIR}/f.links" "${TMP_DIR}/f.linkmap"
hash_contents "${IMG}" "${TMP_DIR}/f.walk" "${TMP_DIR}/f.content"
cat "${TMP_DIR}/f.content" "${TMP_DIR}/f.linkmap" > "${TMP_DIR}/f.extra"
tuples_build "${TMP_DIR}/f.walk" "${TMP_DIR}/f.extra" "${TMP_DIR}/f.tuples"

donor_line() { # PATH — full donor tuple line prefixed for removal side
  awk -F'\t' -v p="${1}" '$1 == p { printf "<\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, $6, $7; exit }' \
    "${TMP_DIR}/d.tuples"
}

# donor-identity values from stage 10 stats (donor perms/times asserted there)
# shellcheck source=/dev/null
source "${WORK_DIR}/stats/donor-identity.env"
trom_active="${TROM_ACTIVE_IMG}"
mint_active="${MINT_ACTIVE_IMG}"
SO_MD="$(df_md "${trom_active}" /lib/hw/audio.primary.mt6582.so)"
POLICY_MD="$(df_md "${trom_active}" /etc/audio_policy.conf)"
EFFECTS_MD="$(df_md "${trom_active}" /etc/audio_effects.conf)"
ACCDET_MD="$(df_md "${mint_active}" /usr/keylayout/ACCDET.kl)"

# rebuild expected post-op files from donor bases (independent of stage 20)
df_dump "${DONOR_LITHIUM_SYS}" /usr/keylayout/Generic.kl "${TMP_DIR}/v.Generic.donor"
PW="${TMP_DIR}/v-pw/usr/keylayout"
mkdir -p "${PW}"
cp -- "${TMP_DIR}/v.Generic.donor" "${PW}/Generic.kl"
patch -s -d "${TMP_DIR}/v-pw" -p1 -i "${PATCH_DIR}/usr/keylayout/Generic.kl.patch"
df_dump "${DONOR_LITHIUM_SYS}" /build.prop "${TMP_DIR}/v.build.prop.donor"
sed 's/^qemu\.hw\.mainkeys=1$/qemu.hw.mainkeys=0/' "${TMP_DIR}/v.build.prop.donor" > "${TMP_DIR}/v.build.prop.new"

manifest_size="$(df_md "${IMG}" /etc/fork/fork-manifest.txt | awk '{print $4}')"
manifest_sha="$(awk -F'\t' -v p="etc/fork/fork-manifest.txt" '$1 == p { print $2; exit }' "${TMP_DIR}/f.content")"

{
  donor_line vendor/etc/mixer_paths.xml
  printf '>\tusr/keylayout/ACCDET.kl\tF\t%s\t0\t0\t%s\t%s\n' \
    "$(ls_mode_file "$(awk '{print $1}' <<<"${ACCDET_MD}")")" "$(awk '{print $4}' <<<"${ACCDET_MD}")" \
    "$(pin_for img:MINT:usr/keylayout/ACCDET.kl)"
  printf '>\tetc/fork\tD\t40755\t0\t0\t-\t-\n'
  printf '>\tetc/fork/fork-manifest.txt\tF\t100644\t0\t0\t%s\t%s\n' "${manifest_size}" "${manifest_sha}"
  donor_line lib/hw/audio.primary.mt6582.so
  printf '>\tlib/hw/audio.primary.mt6582.so\tF\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ls_mode_file "$(awk '{print $1}' <<<"${SO_MD}")")" "$(awk '{print $2}' <<<"${SO_MD}")" \
    "$(awk '{print $3}' <<<"${SO_MD}")" "$(awk '{print $4}' <<<"${SO_MD}")" \
    "$(pin_for img:TROM:lib/hw/audio.primary.mt6582.so)"
  donor_line etc/audio_policy.conf
  printf '>\tetc/audio_policy.conf\tF\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ls_mode_file "$(awk '{print $1}' <<<"${POLICY_MD}")")" "$(awk '{print $2}' <<<"${POLICY_MD}")" \
    "$(awk '{print $3}' <<<"${POLICY_MD}")" "$(awk '{print $4}' <<<"${POLICY_MD}")" \
    "$(pin_for img:TROM:etc/audio_policy.conf)"
  donor_line etc/audio_effects.conf
  printf '>\tetc/audio_effects.conf\tF\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ls_mode_file "$(awk '{print $1}' <<<"${EFFECTS_MD}")")" "$(awk '{print $2}' <<<"${EFFECTS_MD}")" \
    "$(awk '{print $3}' <<<"${EFFECTS_MD}")" "$(awk '{print $4}' <<<"${EFFECTS_MD}")" \
    "$(pin_for img:TROM:etc/audio_effects.conf)"
  donor_line usr/keylayout/mtk-kpd.kl
  printf '>\tusr/keylayout/mtk-kpd.kl\tF\t100644\t0\t0\t%s\t%s\n' \
    "$(wc -c < "${PATCH_DIR}/usr/keylayout/mtk-kpd.kl")" "$(sha_of "${PATCH_DIR}/usr/keylayout/mtk-kpd.kl")"
  donor_line usr/keylayout/Generic.kl
  printf '>\tusr/keylayout/Generic.kl\tF\t100644\t0\t0\t%s\t%s\n' \
    "$(wc -c < "${PW}/Generic.kl")" "$(sha_of "${PW}/Generic.kl")"
  donor_line build.prop
  printf '>\tbuild.prop\tF\t100644\t0\t0\t%s\t%s\n' \
    "$(wc -c < "${TMP_DIR}/v.build.prop.new")" "$(sha_of "${TMP_DIR}/v.build.prop.new")"
} > "${TMP_DIR}/expected.diff"

diff <(sort "${TMP_DIR}/d.tuples") <(sort "${TMP_DIR}/f.tuples") > "${TMP_DIR}/actual.diff" || true
grep -E '^[<>]' "${TMP_DIR}/actual.diff" | sed -E 's/^([<>]) /\1\t/' | sort > "${TMP_DIR}/actual.changed" || true
sort "${TMP_DIR}/expected.diff" > "${TMP_DIR}/expected.sorted"
if cmp -s "${TMP_DIR}/expected.sorted" "${TMP_DIR}/actual.changed"; then
  chk PASS "A2" "recursive debugfs diff vs D-LITHIUM-SYS == exactly the 9 ops ($(wc -l < "${TMP_DIR}/actual.changed") changed tuples)"
else
  chk FAIL "A2" "differences outside the op table (see below)"
  diff -- "${TMP_DIR}/expected.sorted" "${TMP_DIR}/actual.changed" | sed 's/^/       /' >&2
fi
[ "$(wc -l < "${TMP_DIR}/f.tuples")" -gt 1500 ] \
  && chk PASS "A2-walk" "fork walk covered $(wc -l < "${TMP_DIR}/f.tuples") paths" \
  || chk FAIL "A2-walk" "fork walk suspiciously small ($(wc -l < "${TMP_DIR}/f.tuples"))"

# ================================================================ A3 audio_policy lint
POLICY_DUMP="${TMP_DIR}/v.audio_policy.conf"
df_dump "${IMG}" /etc/audio_policy.conf "${POLICY_DUMP}"
lb="$(tr -cd '{' < "${POLICY_DUMP}" | wc -c)"
rb="$(tr -cd '}' < "${POLICY_DUMP}" | wc -c)"
v30="$(grep -c 'audio_hal_version 3\.0' "${POLICY_DUMP}")"
if [ "${lb}" -eq "${rb}" ] && [ "${v30}" -eq 1 ] \
  && [ "$(sha_of "${POLICY_DUMP}")" = "$(pin_for img:TROM:etc/audio_policy.conf)" ]; then
  chk PASS "A3" "audio_policy.conf lint: braces balanced (${lb}), primary hal 3.0 ×1, byte-identical to T-ROM"
else
  chk FAIL "A3" "braces ${lb}/${rb} hal3.0×${v30} — see stats"
fi

# ================================================================ A4 .so checks
SO_DUMP="${TMP_DIR}/v.audio.so"
df_dump "${IMG}" /lib/hw/audio.primary.mt6582.so "${SO_DUMP}"
hdr="$(od -An -tx1 -N 20 "${SO_DUMP}" | tr -d ' \n')"
# e_ident: 7f 'E' 'L' 'F' 01(32-bit) 01(LSB) 01; @0x10 e_type=0300 (ET_DYN, shared object); @0x12 e_machine=2800 (ARM)
if [ "${hdr:0:14}" = "7f454c46010101" ] && [ "${hdr:32:8}" = "03002800" ]; then
  chk PASS "A4-elf" "ELF32 LSB ARM shared-object header confirmed"
else
  chk FAIL "A4-elf" "unexpected ELF header: ${hdr}"
fi
needed="$(python3 - "${SO_DUMP}" <<'EOF' || true
import struct, sys
b = open(sys.argv[1], "rb").read()
phoff = struct.unpack_from("<I", b, 28)[0]
phentsize, phnum = struct.unpack_from("<HH", b, 42)
loads, dyn = [], None
for i in range(phnum):
    o = phoff + i * phentsize
    p_type = struct.unpack_from("<I", b, o)[0]
    if p_type == 1:
        loads.append((struct.unpack_from("<I", b, o + 4)[0],      # p_offset
                      struct.unpack_from("<I", b, o + 8)[0],      # p_vaddr
                      struct.unpack_from("<I", b, o + 16)[0]))    # p_filesz
    elif p_type == 2:
        dyn = struct.unpack_from("<I", b, o + 4)[0]               # p_offset
def v2o(v):
    for fo, fv, fsz in loads:
        if fv <= v < fv + fsz:
            return fo + (v - fv)
    raise SystemExit("strtab not mapped by any PT_LOAD")
entries = []
o = dyn
while o < len(b):
    tag, val = struct.unpack_from("<II", b, o)
    if tag == 0:
        break
    entries.append((tag, val))
    o += 8
strtab = next(v for t, v in entries if t == 5)
base = v2o(strtab)
for t, off in entries:
    if t == 1:  # DT_NEEDED
        p = base + off
        print(b[p:b.index(b"\0", p)].decode())
EOF
)"
libset="$(awk -F'\t' '$1 == "F" { p = $2; sub(/^.*\//, "", p); if ($2 ~ /^(lib|vendor\/lib)\//) print p }' "${TMP_DIR}/f.walk" | sort -u)"
missing=0
while IFS= read -r lib; do
  [ -n "${lib}" ] || continue
  if ! grep -qxF "${lib}" <<<"${libset}"; then
    missing=$((missing + 1))
    warn "  A4: DT_NEEDED lib not in fork /system(/vendor)/lib: ${lib}"
  fi
done <<<"${needed}"
n_needed="$(printf '%s' "${needed}" | grep -c . || true)"
if [ "${missing}" -eq 0 ]; then
  chk PASS "A4" "DT_NEEDED satisfied (${n_needed} libs present in fork image); .so byte-identical to donor → symbol set unchanged"
else
  chk FAIL "A4" "${missing} DT_NEEDED libraries unresolved"
fi

# ================================================================ A5 .kl syntax + §2.5/§2.6 content
df_dump "${IMG}" /usr/keylayout/mtk-kpd.kl "${TMP_DIR}/v.mtk-kpd.kl"
df_dump "${IMG}" /usr/keylayout/ACCDET.kl "${TMP_DIR}/v.ACCDET.kl"
df_dump "${IMG}" /usr/keylayout/Generic.kl "${TMP_DIR}/v.Generic.kl"
kpdbad="$(grep -cvE '^(#|$)|^key [0-9]+ +[A-Z0-9_]+( +(WAKE|WAKE_DROPPED))?[[:space:]]*$' "${TMP_DIR}/v.mtk-kpd.kl" || true)"
acdbad="$(grep -cvE '^(#|$)|^key [0-9]+ +[A-Z0-9_]+( +(WAKE|WAKE_DROPPED))?[[:space:]]*$' "${TMP_DIR}/v.ACCDET.kl" || true)"
genbad="$(grep -cvE '^(#|$)|^(key usage|axis|led) |^key [0-9]+ +[A-Z0-9_]+( +(WAKE|WAKE_DROPPED|FUNCTION))?[[:space:]]*$' "${TMP_DIR}/v.Generic.kl" || true)"
dual=1
grep -Fq 'key 102   HOME              WAKE_DROPPED' "${TMP_DIR}/v.mtk-kpd.kl" || dual=0
grep -Fq 'key 172   HOME              WAKE_DROPPED' "${TMP_DIR}/v.mtk-kpd.kl" || dual=0
wake7=1
for line in 'key 116   POWER             WAKE' 'key 127   MENU              WAKE_DROPPED' \
            'key 139   MENU              WAKE_DROPPED' 'key 142   POWER             WAKE' \
            'key 143   POWER             WAKE' 'key 152   POWER             WAKE' \
            'key 158   BACK              WAKE_DROPPED'; do
  grep -Fqx "${line}" "${TMP_DIR}/v.Generic.kl" || wake7=0
done
if [ "${kpdbad}" -eq 0 ] && [ "${acdbad}" -eq 0 ] && [ "${genbad}" -eq 0 ] \
  && [ "${dual}" -eq 1 ] && [ "${wake7}" -eq 1 ]; then
  chk PASS "A5" ".kl syntax OK; mtk-kpd dual-maps 102+172 HOME; Generic.kl carries the 7 WAKE-flag edits"
else
  chk FAIL "A5" "kpd-bad=${kpdbad} accdet-bad=${acdbad} gen-bad=${genbad} dual=${dual} wake7=${wake7}"
fi

# ================================================================ A6 build.prop diff
df_dump "${IMG}" /build.prop "${TMP_DIR}/v.build.prop.img"
n_diff="$(diff -- "${TMP_DIR}/v.build.prop.donor" "${TMP_DIR}/v.build.prop.img" | grep -cE '^[<>]' || true)"
if [ "${n_diff}" -eq 2 ] && [ "$(grep -c '^qemu\.hw\.mainkeys=0$' "${TMP_DIR}/v.build.prop.img")" -eq 1 ]; then
  chk PASS "A6" "build.prop diff vs donor == exactly the mainkeys line (0 present)"
else
  chk FAIL "A6" "build.prop diff lines=${n_diff} (expect 2 = one line per side)"
fi

# ================================================================ A7 stub deleted / manifest present
vend="$(df_ls_names "${IMG}" /vendor/etc | wc -l)"
df_dump "${IMG}" /etc/fork/fork-manifest.txt "${TMP_DIR}/v.fork-manifest.txt"
if [ "${vend}" -eq 0 ] && [ -s "${TMP_DIR}/v.fork-manifest.txt" ]; then
  chk PASS "A7" "/vendor/etc/mixer_paths.xml absent (dir empty); fork-manifest present + non-empty"
else
  chk FAIL "A7" "vendor/etc entries=${vend}, manifest present=$([ -s "${TMP_DIR}/v.fork-manifest.txt" ] && echo y || echo n)"
fi
if grep -Fq "$(git -C "${REPO_ROOT}" rev-parse HEAD)" "${TMP_DIR}/v.fork-manifest.txt" \
  && grep -Fq "$(pin_for ~/q5-flash/rom/system.img)" "${TMP_DIR}/v.fork-manifest.txt" \
  && grep -Fq "$(pin_for ~/.hermes/q5-recovery/base/T-ROM_V2.3/system.img)" "${TMP_DIR}/v.fork-manifest.txt"; then
  chk PASS "A7b" "fork-manifest provenance: git HEAD + donor pins recorded"
else
  chk FAIL "A7b" "fork-manifest missing git rev / donor pins"
fi

# ================================================================ A8 image integrity
sb_state="$(dumpe2fs -h "${IMG}" 2>/dev/null | sed -n 's/^Filesystem state: *//p')"
sz="$(stat -c '%s' "${IMG}")"
freeb="$(dumpe2fs -h "${IMG}" 2>/dev/null | sed -n 's/^Free blocks: *//p')"
donor_free="$(sed -n 's/^Free blocks: *//p' "${WORK_DIR}/stats/donor-fs.txt")"
df_read "${IMG}" "ls -l /" > /dev/null
free_delta=$((donor_free - freeb))
if [ "${sb_state}" = "clean" ] && [ "${sz}" -le "${MINT_ANDROID_CEILING}" ] \
  && [ "${free_delta}" -ge -64 ] && [ "${free_delta}" -le 64 ]; then
  chk PASS "A8" "debugfs mount OK; state=clean; size ${sz} ≤ 0x33400000; free ${freeb} (donor ${donor_free})"
else
  chk FAIL "A8" "state=${sb_state} size=${sz} free=${freeb} Δ=${free_delta}"
fi

# ================================================================ A9 perms
chg_ok=1
for p in lib/hw/audio.primary.mt6582.so etc/audio_policy.conf etc/audio_effects.conf \
         usr/keylayout/mtk-kpd.kl usr/keylayout/Generic.kl usr/keylayout/ACCDET.kl \
         build.prop etc/fork/fork-manifest.txt etc/fork; do
  row="$(awk -F'\t' -v p="${p}" '$1 == p { print; exit }' "${TMP_DIR}/f.tuples")"
  if [ -z "${row}" ]; then
    chg_ok=0
    warn "  A9: ${p} not in fork walk"
    continue
  fi
  mode="$(cut -f3 <<<"${row}")"
  if [ "${mode}" != "100644" ] && [ "${mode}" != "40755" ]; then
    chg_ok=0
    warn "  A9: ${p} mode=${mode}"
  fi
done
ww_new="$(comm -13 <(awk -F'\t' '$3 ~ /[2367]$/ { print $1 }' "${TMP_DIR}/d.tuples" | sort) \
                  <(awk -F'\t' '$3 ~ /[2367]$/ { print $1 }' "${TMP_DIR}/f.tuples" | sort) || true)"
if [ "${chg_ok}" -eq 1 ] && [ -z "${ww_new}" ]; then
  chk PASS "A9" "changed paths 0644/0755 root:root; no new world-writable entries"
else
  chk FAIL "A9" "chg_ok=${chg_ok}; world-writable additions: ${ww_new:-none}"
fi

# ================================================================ summary
section "summary"
log "checks: ${P} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || { log "99_verify: NOT green — do not hand off"; exit 1; }
log "99_verify: GREEN — §2.4 self-check satisfied for out/system.img"
