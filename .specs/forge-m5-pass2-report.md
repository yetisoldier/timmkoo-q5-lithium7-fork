# Forge Report — m5 Pass 2 of 2: ARSC patcher + system defaults (WS2)

> Status: **COMPLETE** — §5.2 (`build/patch_arsc_values.py`, new) and §5.4
> (`build/apply_system_defaults.py`, edited) implemented exactly as specified;
> T1 + T2 self-verification gates **pass** with manifests emitted; §5.6 list untouched.
> Scope gate: Pass 2 ONLY. No kernel/patch/series/`82_*`/`test_kpd_filter.py` changes
> (all Pass-1 artifacts, untouched — proven in §5 of this report). Not git-committed.
> Spec: `.specs/bob-m5-power-audio-spec.md` §5.2, §5.3, §5.4 (+ §5.6 do-not-touch).

## 0. Changed-files ledger (final)

| # | File | Action | Item | Status |
|---|------|--------|------|--------|
| 1 | `build/patch_arsc_values.py` | new (ARSC reader + self-verifying patcher + manifest) | §5.2 | **done** |
| 2 | `build/apply_system_defaults.py` | edit (4 hunks, 25 lines added, 0 removed/moved: import, --settingsprovider, arsc guard, noril block) | §5.4 | **done** |
| 3 | `out/`-equivalents under scratch | T1/T2 gate outputs + manifests (scratch only, no repo/flash artifacts) | §5.2 T1/T2 | **done** |

No other repo file was created or modified. Specifically NOT touched (per task scope +
§5.6 + Pass-1 boundary): `build/82_kernel_delta_power_audio.sh`, `build/75_kernel_delta_coherent_dma.sh`,
`build/test_kpd_filter.py`, `patches/kernel/*` (D43/D44 + DELTA-NOTES),
`build/kernel-d43.series`, `drivers/input/touchscreen/**`, `drivers/misc/mediatek/accdet/**`,
`evdev.c`, connectivity tree, telephony APKs, ramdisk scripts, `q5_defconfig`,
`docs/INSTALL.md` (see Deviation D3), and all v1.0.0 release artifacts.

## 1. Per-item status

### 1.1 `build/patch_arsc_values.py` (§5.2) — done (new file, 340 lines)

- **Parser** (no apktool/aapt, `zipfile` + raw chunk walk): ResTable (0x0002) → skips
  the global string pool by size → per-package (0x0200): type/key string pools read via
  `typeStrings`/`keyStrings` package fields → sequential chunk walk inside the package
  over TYPE_SPEC (0x0202), TYPE (0x0201) and inline pools (0x0001, skipped by size;
  unknown chunks skip defensively by size too). Every §5.2 layout fact is honored:
  stringsStart relative to the pool chunk start; TYPE id byte at +8; entry offsets after
  the TYPE header (at `headerSize`), relative to `entriesStart`, `0xFFFFFFFF` = NO_ENTRY
  skipped; entry header = size u16 / flags u16 / key index u32; value at entry+size =
  size u16 / res0 u8 / dtype u8 / data u32.
- **String pools**: UTF-8 pools decode the two escaped length fields (1-byte and 2-byte
  `0x80|hi7` forms — empirically `04 04 attr 00` in the donors) then scan to NUL;
  UTF-16 pools decode the length (1- or 2-word escaped form) as LE-16. Only the package
  key/type pools are decoded (identifiers); the 7.2 MB global value-string pool of
  framework-res is skipped byte-exact by size (it contains non-UTF-8 binary entries —
  decoded contents are irrelevant, and skipping avoids the aapt length-quirk entirely).
- **Matching** is by key NAME **and** type NAME per §5.2: `--set-bool` requires the type
  name to decode to `bool` with dtype `0x12` in every matched entry; `--set-int` requires
  the type name `integer` with dtype `0x10`; `dimen`-named and every other type is
  rejected by name, and a matched entry with a wrong dtype aborts the build
  (refuse-on-dtype-mismatch). Complex (bag) entries abort. Applies to **every** config's
  entry that matches (both donors have a single `default` config for the targets, as §5.2
  notes); **asserts ≥1 hit and prints per-hit before/after**.
- **Values**: `true`/`false` → `0xffffffff`/`0x00000000` (INT_BOOLEAN), ints decimal
  (INT_DEC). Only the 4-byte data field is rewritten; dtype/res0/size are untouched.
- **Zip rebuild** (mirror of `build/build_branding.py`'s helper pattern, verbatim):
  iterate `infolist()` in original order, copy each entry's ZipInfo, replace only
  `resources.arsc`, preserve compression, and apply the exact stored-entry 4-byte
  alignment padding convention (`entry.extra = b''` + `0xffff`-padding chunk when
  `base % 4`); additionally the archive comment is carried over (defensive; donor
  comment is empty). Compression type of `resources.arsc` is re-asserted after rebuild.
- **Self-verification, all three §5.2 checks**, every run, build aborts on any failure:
  1. Output APK re-parses; every matched entry reads back exactly the requested value
     (same resid, same dtype, ≥1 hit).
  2. Byte-diff of old vs new arsc: differing 4-byte-aligned dwords == exactly the patched
     value data fields (verified: T1 diff = single dword at arsc offset 19406564, T2 =
     single dword at 10956; idempotent re-patch yields empty diff).
  3. Every non-`resources.arsc` zip entry byte-identical (per-entry sha256 input==output),
     plus identical namelist and `testzip()` clean.
- **Manifest JSON** (`--manifest`): input/output apk sha256, arsc sha256 before/after,
  resource name, id + per-config ids, patched count, before/after values, and the arsc
  byte-diff offsets; per-hit id/config/before/after/dtype/diff-offset sub-records —
  consumable by `apply_system_defaults.py` and Karen.
- **Reader API for §5.4**: `read_named_values(apk_path, name, type_name=None)` parses an
  APK's arsc and returns every config's hit dict (`resid`, `type_name`, `dtype`, `value`,
  config summary, offsets). `apply_system_defaults.py` imports exactly this.

### 1.2 T1 + T2 gates (§5.2 targets, also G-B3) — done, both PASS

| Gate | Input (pinned) | Output (scratch, never flashed) | Result |
|---|---|---|---|
| T1 | `.reference-lithium/framework/framework-res.apk` (`4ef9ce51…`) | `framework-res.vc.apk` (`24e802b9…`) + `framework-res.arsc-manifest.json` | **PASS** — `config_voice_capable` 4294967295 (true) → 0 (false), id `0x0112006c`, dtype `0x12`, 1 config, single-dword arsc diff @ 19406564, all 3 self-checks green |
| T2 | `.reference-lithium/priv-app/SettingsProvider/SettingsProvider.apk` (`803f2b66…`) | `SettingsProvider.apk` (`c6fc0cc4…`) + `SettingsProvider.arsc-manifest.json` | **PASS** — `def_wifi_sleep_policy` 2 → 0, id `0x7f050003`, dtype `0x10`, 1 config, single-dword arsc diff @ 10956, all 3 self-checks green |

Both donors' arsc blobs are byte-identical to the m5 scratch arsc files
(`opencode/m5/framework-res.arsc` `0e9c86f6…`, `opencode/m5/sp.arsc` `533097eb…` = the
`arsc_sha256.before` values in the manifests) — confirming §5.2's "proven in the m5
scratch run" baseline and the exact donor state.

Refusal/self-check negative paths exercised (all abort correctly): N1 `--set-int
def_wifi_sleep_policy=0` on framework-res → "No integer-typed resource … refusing to
proceed on 0 hits"; N2 `--set-int` with a bool-only name → same refusal; N3 idempotent
re-patch of the T1 output → accepted as a no-op with an EMPTY diff (before==after); N4
imported-reader read-back of both T1/T2 outputs reads the requested values.

### 1.3 `build/apply_system_defaults.py` edits (§5.4) — done (21 lines added)

Minimal, matching the file's existing style (regex blocks, `put()`-based mutation,
assert-driven failure):

1. **`--settingsprovider PATH` (new optional arg)**: verified EARLY (before any image
   mutation, right after the media-manifest asserts): `read_named_values(PATH,
   'def_wifi_sleep_policy')` must return ≥1 hit, each `type_name == 'integer'`,
   `dtype == 0x10`, `value == 0` (i.e. the T2 patch must already have been applied — an
   unpatched donor refuses with a message pointing to §5.2; verified below). When
   present, it is placed with the existing `put()` to
   `/priv-app/SettingsProvider/SettingsProvider.apk` (rm-if-exists, write, SELinux label
   `u:object_r:system_file:s0` + readback, sha readback) — its patched sha lands in the
   manifest `changes` like every other put (§5.4.5 "as today").
2. **`ro.radio.noril` build.prop block**: placed immediately after the
   `persist.af.audio_patch_fm` block, same regex style (`(?m)^key=.*$`, ≤1 existing line
   asserted, replace in place else append at EOF):
   `ro.radio.noril=true`.
   `qemu.hw.mainkeys=0` and `persist.af.audio_patch_fm=1` remain exactly as before
   (unchanged blocks).
3. **framework-res arsc guard**: immediately after the put-loop (so after
   `put(a.branding/'framework-res.apk', …)` succeeded), the written file is dumped back
   OUT of the image via debugfs `dump` and parsed with the imported reader; asserts
   ≥1 hit of `config_voice_capable` with `type 'bool'`, dtype `0x12`, value 0
   (`false`). Catches the §5.3 pipeline-order regression (branding on an unpatched
   donor). Negative control verified: the UNPATCHED donor is refused with exactly this
   assertion; also verified the donor image's `/framework/framework-res.apk` is
   byte-identical to the reference tree's (sha assert inside the negative control).
4. (Constraint item — no code): no telephony package removal, no pruning changes,
   `persist.radio.multisim.config`/`keyguard.no_require_sim` untouched (that code
   section exists untouched).
5. Manifest pins: put() already records every placed file's sha256 into the output
   manifest `changes` (framework-res.apk and — when present — SettingsProvider.apk
   included; verified by the harness: 3 pinned entries after the exercised puts).

### 1.4 Verification runs for §5.4 beyond compile (harness against the real donor image)

Full `apply_system_defaults.py` main() cannot run on this machine (the v1.0.1 inputs —
recorder/fm/media/branding/gestures build outputs — live on Bob's machine), so a
verbatim-fragment harness (`opencode/forge-m5p2/guard_harness.py`) exercised the exact
§5.4 code blocks (copy-verbatim: `extract/exists/label/put` + guard + noril block +
settingsprovider put) against a scratch COPY of the real donor `~/q5-flash/rom/system.img`
(donor untouched; sha still `cd6e9b54…` = its `donors.sha256` pin):

- Positive: patched framework-res put → guard PASS; T2 `put` + readback `def_wifi_sleep_policy=0`
  PASS; `ro.radio.noril=true` appended (asserted exactly once in the re-read file);
  `qemu.hw.mainkeys=0` + `persist.af.audio_patch_fm=1` present; both `e2fsck` passes clean
  (`-f -y` then `-f -n`); post-e2fsck debugfs readback of framework-res parses
  `config_voice_capable=false` and is byte-identical to the patched input.
- Negative: UNPATCHED donor → guard refuses ("must read config_voice_capable=false").

## 2. Gate evidence (G-B3; pipeline-order inputs per §5.3)

```
python3 build/patch_arsc_values.py \
  --apk .reference-lithium/framework/framework-res.apk \
  --out <scratch>/framework-res.vc.apk \
  --set-bool config_voice_capable=false --manifest <scratch>/framework-res.arsc-manifest.json
→ id=0x0112006c 0xffffffff -> 0x00000000; self-verification 1/2/3 PASS; manifest emitted.

python3 build/patch_arsc_values.py \
  --apk .reference-lithium/priv-app/SettingsProvider/SettingsProvider.apk \
  --out <scratch>/SettingsProvider.apk \
  --set-int def_wifi_sleep_policy=0 --manifest <scratch>/SettingsProvider.arsc-manifest.json
→ id=0x7f050003 2 -> 0; self-verification 1/2/3 PASS; manifest emitted.
```

Outputs (scratch, deterministic, re-runnable): `out` shas `24e802b9…` (framework-res.vc.apk),
`c6fc0cc4…` (SettingsProvider.apk). Nothing written into the repo except the two source
files; nothing flashed; donors untouched (sha proofs above).

## 3. Deviations from §5.2 / §5.4 (required section)

**D1 — the donor's `config_voice_capable` id is `0x0112006c`, not the spec's `0x011200a9`.**
Evidence (probe): in the T1 donor's arsc the `bool` type chunk entry list places
`config_voice_capable` at entry index `0x6c` with data `0xffffffff` (true); entry `0xa9`
is a DIFFERENT resource (`config_sms_decode_gsm_8bit_data`, data 0). Computed resid =
pkg 0x01 | type 0x12 | entry 0x6c = `0x0112006c`. The spec's name-based matching rule
(§5.2 item 2) — which is what the tool implements — finds exactly one hit regardless, so
behavior is unaffected; the manifest records the observed ids. Bob's `0x011200a9` likely
came from a different framework build's bool ordering (or a doc reference). Impact: none
on matching/patching; recommend the spec text carry both facts ("resid in the v1.0.0
donor arsc: 0x0112006c; match by name per §5.2").

**D2 — no separate `manifests/audio-hygiene-v1.0.1.json` file is written by
`apply_system_defaults.py`.** §5.4.5's parenthetical "(both recorded in the output
manifest `changes` as today)" is implemented literally: the patched shas land in the
output manifest's `changes` dict via the existing `put()` mechanism (verified). No repo
`manifests/` file is added by this pass; if Bob wants a standalone pinned manifest file
for the release (like audio-hygiene), that belongs to the v1.0.1 packaging step
(`package_checkpoint.py`), which is out of Pass-2 scope.

**D3 — `docs/INSTALL.md` release-recipe addition (§5.3) not done in this pass.** The task
scope limits Pass 2 to §5.2 + §5.4 items; the §5.3 pipeline ORDER (kernel → T1 → branding
→ T2 → apply → package) is implemented in the code paths above but the release-recipe
doc edit is deferred to the v1.0.1 release step. Flag for Hera/Bob: when cutting v1.0.1,
add the §5.3 order block to docs/INSTALL.md.

**D4 — patcher niceties beyond the letter of §5.2 (no behavior change for T1/T2):**
archive-comment preservation + an explicit arsc-compression-preservation assert in the
zip rebuild (branding's pattern drops the comment defensively — donors have none);
idempotent same-value re-patch is accepted (before==after ⇒ empty diff, N3 above). These
are defensive additions inside the "self-verification" mandate, not behavior changes.

**D5 — environment (not design): full `apply_system_defaults.py` run not possible here**
(same class as Pass-1 deviation D3): the v1.0.1 build inputs (pinned recorder APK, FM and
media build outputs, branding/gestures outputs, release images) live on Bob's machine.
Substitute verification: py_compile both tools, refusal-path runs (N1/N2/N5), imported-
reader read-backs (N4), and the donor-image harness of §1.4 (positive + negative +
post-e2fsck readback). The full G-B4 gate belongs to the v1.0.1 release build.

## 4. Karen validation pointers (offline replay)

- Replay T1/T2 gates: the two §2 commands (substitute scratch paths); each run aborts on
  any self-check failure and rewrites the manifest.
- Read-back alone: `cd build && python3 -c "from patch_arsc_values import
  read_named_values; print(read_named_values('<patched apk>', 'config_voice_capable'))"`
  (same for `def_wifi_sleep_policy`).
- Manifest cross-check: `arsc_diff_offsets` must equal exactly one data field per
  patched config; `before/after_values` per gate above.
- Full-image gate (G-B4) runs with the release inputs during the v1.0.1 build:
  `apply_system_defaults.py` … `--settingsprovider <T2 output>` `--release-version 1.0.1`;
  the framework-res guard fires during the run (framework-res must be the T1+branding
  product per §5.3 order).

## 5. Scope-cleanliness proof (final state)

`git status --porcelain` at pass end contains exactly the Pass-1 artifacts (uncommitted,
present since before this pass: `build/75_kernel_delta_coherent_dma.sh` and
`patches/kernel/DELTA-NOTES.md` modifications and the untracked build/patch files) plus
the two Pass-2 items (`build/apply_system_defaults.py` modified with only the 25 §5.4
lines; `build/patch_arsc_values.py` new) and the pre-existing untracked `.specs/`
documents including this report. Donor pins unchanged:
`~/q5-flash/rom/system.img` `cd6e9b54…`, `.reference-lithium/framework-res.apk`
`4ef9ce51…`, `.reference-lithium/SettingsProvider.apk` `803f2b66…` (re-hashed after all
runs). Nothing git-committed (Hera commits after review).
