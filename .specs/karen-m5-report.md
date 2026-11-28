# Karen Report — m5 validation (Power & Audio, v1.0.1)

> Validator: Karen. Spec: `.specs/bob-m5-power-audio-spec.md` (§7 baseline, expanded).
> Inputs under review: uncommitted working tree (Pass 1 kernel + Pass 2 ARSC).
> Mode: read-only, headless (no Q5 hardware). §7.2 device gates V0–V14 are **deferred
> to Hera** — code-validated only, marked WARN, never PASS.
> Method: every claim below was re-executed or re-derived independently on this machine
> (fresh `prepare_kernel` trees, host-test run, T1/T2 patch runs, an independent ARSC
> probe written from the AOSP format spec, a full 82-chain build replay, and a
> code-equivalence sweep of all 2532 build objects). The working tree was left
> byte-identical to its pre-review state (out/ artifacts restored; `git status`
> unchanged; nothing committed).

---

## Executive summary

**Overall Status: WARN** — implementation PASS at the code level for every workstream;
release readiness is gated on process conditions (release-base rebuild, full-pipeline
G-B4, device gates) that cannot be executed in this headless environment.

**Overall Risk: Medium** — no Critical or High severity code defects found in 40+
executed checks. The open items are release-process conditions, not implementation
defects.

**Confidence: High** (for everything executable headless; device behavior remains
unproven by definition here).

| # | Workstream | Verdict | Evidence |
|---|---|---|---|
| 1 | Pass 1 — D43 patch (K1/K2/K3/scan-log gate) vs §5.1.1 | **PASS** (code) | E1 |
| 2 | Pass 1 — D44 patch (K4) vs §5.1.2 | **PASS** (code) | E2 |
| 3 | Pass 1 — series / 82 wrapper / 75 d43 case / DELTA-NOTES | **PASS** | E3 |
| 4 | Pass 1 — host test G1–G6 (§5.5, G-B2) — EXECUTED | **PASS** | E4 |
| 5 | Pass 1 — full 82-chain build replay (§5.1.3, G-B1) — EXECUTED | **PASS** (with reproducibility caveat, E5) | E5 |
| 6 | Pass 2 — patch_arsc_values.py T1/T2 (§5.2, G-B3) — EXECUTED | **PASS** | E6 |
| 7 | Pass 2 — apply_system_defaults.py (§5.4) | **PASS** (code paths executed; full G-B4 deferred to release build) | E7 |
| 8 | Adjudication 1 — resid discrepancy | **Forge CORRECT** — right entry patched; spec resid wrong, spec byte-anchor right | A1 |
| 9 | Adjudication 2 — D1 drop-counter formula | **Forge's correction ACCEPTED** — matches Bob's intent; report behavior unchanged | A2 |
| 10 | Adjudication 3 — D3 build base | **RELEASE-GATE** — current boot-d43.img is NOT the shippable artifact | A3 |
| 11 | §7.2 device gates V0–V14 | **WARN — deferred to Hera** (headless; code validated) | — |
| 12 | G-B4 full-pipeline / G-B5 tuple diff | **DEFERRED to the v1.0.1 release build** (inputs live on Bob's machine) | E7 |

---

## Test plan

### Executed (spec baseline §7.1)
- **G-B1** — full 82-chain replay: prepare → q5_defconfig → JUMP_LABEL/RODATA asserts →
  d39 protocol gate → D43 greps (1)–(6) → D44 invariants → defconfig-drift hunk guard →
  CONSYS_6582 → `test_kpd_filter.py` → zImage build → repack. **PASS** (chain exit 0).
- **G-B2** — `build/test_kpd_filter.py` G1–G6 against a freshly prepared post-D43 tree.
  **PASS** (6/6, exit 0).
- **G-B3** — T1 and T2 runs of `build/patch_arsc_values.py` with all three
  self-verification checks + manifests. **PASS** (both; byte-identical to Forge's
  reported outputs).
- **G-B4 (partial)** — §5.4 code paths (settingsprovider early check, framework-res arsc
  guard, noril build.prop block, put()/extract()/label()) executed against a scratch
  COPY of the real donor system image, positive AND negative paths. **PASS** for the
  code; the full-pipeline run (with branding/gestures/fm/recorder/media/webview inputs)
  is deferred to the release build — those inputs live on Bob's machine.
- **Defconfig-drift gate** — independent d42-series vs d43-series `.config` generation
  and diff. **EMPTY** (byte-identical).

### Added by Karen (beyond the §7 baseline)
- **K1** Pristine-anchor verification: every D43/D44 hunk anchor compared against the
  pinned reference tree (`.reference-kernel-3.10.54` @ `96e5355…`, verified via
  `git rev-parse`). PASS.
- **K2** Full-series apply test: `prepare_kernel.py --series build/kernel-d43.series`
  into a fresh workdir (d42 series + D43 + D44 applies cleanly). PASS.
- **K3** Independent ARSC walker (written from AOSP ResourceTypes.h, sharing no code
  with Forge's parser) + raw-hexdump manual decode of the donor arsc. Settles A1.
- **K4** Idempotence: re-patch of the T1 output → accepted no-op, empty diff. PASS.
- **K5** Refusals N1/N2 (wrong-type / wrong-name `--set-int`) → exit 1, no output
  written; T1 output zip structure verified (arsc STORED, 4-byte aligned, namelist
  preserved, `testzip` clean). PASS.
- **K6** ARSC guard executed against a real ext4 image copy: real `put()` of the
  T1-patched APK → real guard reads it back via debugfs and parses
  `config_voice_capable=false` (positive), and refuses the UNPATCHED donor with the
  exact §5.4.3 message (negative). PASS.
- **K7** Noril block executed against the donor's real build.prop: appends
  `ro.radio.noril=true` exactly once; `qemu.hw.mainkeys` / `persist.af.audio_patch_fm`
  blocks untouched; donor confirmed to contain NO noril line (independently confirming
  spec §1.2's "not in any shipped artifact"). PASS.
- **K8** SettingsProvider early check: accepts the T2 output; refuses the unpatched
  donor pointing at §5.2. PASS.
- **K9** Full independent kernel build replay + artifact comparison (see E5).
- **K10** Code-equivalence sweep: `.text` sections of all 2532 objects compared between
  Forge's build and Karen's replay build. PASS (see E5).
- **K11** Warning-profile comparison (normalized for build path). PASS — zero new
  target-code warnings; only 2 host-tool warnings differ (see E5).
- **K12** DELTA-NOTES.md D43/D44 entries byte-compared against the spec's verbatim
  blocks. PASS.
- **K13** §5.6 do-not-touch verification: patch file scope (4 files for D43, 1 for D44),
  `git status` ledger, no touchscreen/accdet/evdev/connectivity-outside-gl_kal.c/telephony
  content anywhere in the delta. PASS.
- **K14** Inspection of Bob's `m5-verify` re-verification probes (side finding, A1).

### Skipped / deferred (with reason)
- **§7.2 V0–V14** — device gates: UNEXECUTABLE headless. **WARN, deferred to Hera.**
  Code paths feeding each gate (filter behavior, module params, observability prints,
  arsc values, build.prop lines) are validated offline instead.
- **G-B4 full run / G-B5** — requires the v1.0.1 build inputs (branding/gestures/FM/
  recorder/media/WebView outputs) that live on Bob's machine, and a v1.0.1 image that
  does not exist yet. Deferred to the release build; the §5.4 code is validated (K6–K8).

---

## E1 — D43 patch vs §5.1.1 — PASS (code)

**Method**: extracted the pristine anchors from the pinned reference tree, compared
against the patch hunks, then ran the full deterministic
`prepare_kernel.py --series build/kernel-d43.series` into a fresh scratch workdir and
inspected the resulting files.

**K1 (mtk_kpd.h)** — PASS
- Pristine line 84 `#define KPD_PMIC_RSTKEY_MAP KEY_VOLUMEDOWN` confirmed; patch deletes
  it and substitutes the D20/D22-style banner comment exactly as §5.1.1 requires.
- Untouched-define contract verified in the patched tree: `KPD_PWRKEY_USE_PMIC/EINT`,
  `TWOKEY_REBOOT_*`, `KPD_PMIC_LPRST_TD`, keymap/debounce defines intact.
- All consumers of the deleted define are `#ifdef`-guarded and compile out cleanly
  (verified by grep in the patched tree): kpd.c:386 (AEE hook), kpd.c:868 (probe
  keybit), hal_kpd.c:401/512 (hal body incl. its `input_report_key`).
  `kpd_pmic_rstkey_hal` becomes an empty function → the phantom path is input-dead even
  if the PMIC IRQ ever fired. Double-kill as designed (K1+K2).

**K2 (pmic_mt6323.c)** — PASS
- `cust_pmic_interrupt_en_setting()` (~line 561): pristine `upmu_set_rg_int_en_fchrkey(1);`
  flipped to `(0)` with one-line D43 comment. ✓
- `PMIC_INIT_SETTING_V1()`: pristine tree has EXACTLY TWO `pmic_config_interface(0x166,0x1,0x1,1)`
  pokes (lines 3406 and 3495 — matching the spec's "~3406 and ~3495"); BOTH flipped to
  `0x166,0x0` with a D43 comment each. ✓
- No other poke or `upmu_set_rg_int_en_*` call touched (3 hunks total in this file);
  `upmu_set_rg_int_en_pwrkey(1)` remains (gate greps it; verified present). ✓

**K3 (kpd.c)** — PASS
- State block after `kpd_keymap_state`: `kpd_glitch_ms=150`, `kpd_pending_state[]`,
  `kpd_reported_state[]`, `kpd_glitch_work`, `kpd_glitch_drops` — exactly the §5.1.1 set.
- `kpd_glitch_work_func` implements the spec algorithm: `stable_mask = ~(S1^S2)`,
  `changed = S2 ^ reported`, `report_mask = changed & stable_mask`, per-bit
  `hw_keycode=(i<<4)+j`, `pressed = !(S2 & bit)`, `linux_keycode==0 → continue`,
  `kpd_aee_handler` → `kpd_backlight_handler` → `input_report_key` → `input_sync`.
  Reported-state update `(S2 & stable) | (reported & ~stable)` is correct (unstable
  bits keep the old reported value — they were not reported).
- `kpd_keymap_handler` rewritten to sample-only + `schedule_delayed_work`, with the
  `#ifdef CONFIG_OF / enable_irq(kp_irqnr) / #else / enable_irq(MT_KP_IRQ_ID) / #endif`
  structure preserved verbatim. No `msleep`/`schedule_timeout`; system workqueue only.
- Probe: `kpd_init_keymap_state` for both baselines + `INIT_DELAYED_WORK` after the
  hrtimer block. Suspend: `cancel_delayed_work_sync` FIRST statement. Resume: fresh
  sample + both `memcpy` re-syncs, no reporting. ✓
- `kpd_aee_handler`, hrtimer setup, AEE 5s/15s logic untouched (G6 exercises the real
  extracted AEE code).
- `module_param(kpd_glitch_ms, int, 0644)` in the existing module_param block — Forge
  deviation D5 (definition moved up to the state block out of C necessity) verified
  harmless: semantics identical, `/sys/module/kpd/parameters/` registration unchanged
  (`__param_kpd_glitch_ms` present in vmlinux).

**Scan-log gate (hal_kpd.c)** — PASS
- `static int kpd_show_scan = 0;` next to top statics; `module_param(kpd_show_scan, int,
  0644);` at file scope right after `kpd_get_keymap_state`; the
  `register = %x %x %x %x %x` printk gated on `if (kpd_show_scan)`.
- The press/release printk (~line 350, `kpd_show_hw_keycode`-gated) retained — §6
  field-attribution print preserved. ✓

**Patch hygiene** — D43 touches exactly 4 files (mtk_kpd.h, pmic_mt6323.c, kpd.c,
hal_kpd.c); no `arch/arm/configs/` hunks; no connectivity/accdet/touchscreen/evdev
content. §5.6 respected (K13).

## E2 — D44 patch vs §5.1.2 — PASS (code)

- Pristine `gl_kal.c:773–780` `kalHifAhbKalWakeLockTimeout` confirmed carrying
  `KAL_WAKE_LOCK_TIMEOUT(..., (HZ/10)); /* 100ms */`.
- Patch: single hunk, `(HZ/10)` → `(HZ/50)` with D44 comment. The patch file contains
  exactly one `--- a/` header (gl_kal.c) — nothing else in the connectivity tree.
- D44 invariants verified in the patched tree AND asserted by the 75-chain gates:
  `wake_up_interruptible(&GlueInfo->waitq);` present in ahb.c; `"WLAN AHB ISR"` /
  `"WLAN TX THREAD"` names present; `HifAhbPltmSuspend`/`HifAhbPltmResume` present (still
  the untouched stubs); `CONFIG_MTK_COMBO_CHIP="CONSYS_6582"` in q5_defconfig.

## E3 — series / 82 wrapper / 75 d43 case / DELTA-NOTES — PASS

- `build/kernel-d43.series` = `kernel-d42.series` + exactly two appended lines
  (`D43-kpd-phantom-storm.patch`, `D44-wlan-ahb-isr-window.patch`, in that order);
  `diff` shows nothing else. ✓ §5.1.
- `build/82_kernel_delta_power_audio.sh` is the exact 78-pattern thin wrapper:
  `set -euo pipefail`, `export Q5_KERNEL_TAG=d43`, `exec` 75. ✓
- `build/75_kernel_delta_coherent_dma.sh`: tag case extended to `...|d42|d43`; d43
  inherits the d42-shaped branches (JUMP_LABEL-off + DEBUG_RODATA-on asserts;
  `test_touch_key_protocol.py` non-legacy). The new `d43` gate block runs AFTER
  prepare + config asserts and BEFORE the zImage build, asserting D43 greps (1)–(6)
  as worded in DELTA-NOTES, the D44 invariants, the defconfig-drift hunk guard, and
  `test_kpd_filter.py` (G-B2 wiring). All greps abort the build on failure.
  Forge deviation D4 (gates live in 75 under the d43 case, not in the 82 wrapper) is
  **accepted**: the greps must run against the patched tree, which only exists after
  `prepare_kernel.py` inside 75; the DELTA-NOTES phrase "asserted by build/82 gates"
  is satisfied by the 82→75 chain.
- `patches/kernel/DELTA-NOTES.md`: D43/D44 entries appended byte-identical to the
  spec's verbatim blocks (K12). ✓

## E4 — `build/test_kpd_filter.py` G1–G6 EXECUTED — PASS

Karen ran the test against a freshly prepared post-D43 tree:

```
PASS G1: one 250ms press -> exactly one VOLUMEUP down/up, no duplicates
PASS G2: 80ms pulse -> zero events, drop counter +1
PASS G3: 60s of 2.9Hz slot-01 toggling -> zero events, drops==174
PASS G4: press across suspend -> no stuck key, no phantom release
PASS G5: two quick distinct presses -> both delivered, correct order
PASS G6: aee follows the filtered stream; both-key 5-15s path intact
PASS: D43 kpd glitch filter G1-G6        (exit 0)
```

Harness quality assessment (beyond pass/fail):
- Extracts the REAL patched functions (`kpd_glitch_work_func`, `kpd_keymap_handler`,
  `kpd_pdrv_suspend`, `kpd_pdrv_resume`, `kpd_aee_handler`, `kpd_update_aee_state`,
  the D43 state block, `KPD_INIT_KEYMAP` macro, keymap-state initializer,
  `KPD_NUM_*` sizes) from the tree — it tests the shipped code, not a re-implementation.
- Mocks are faithful where it matters: `schedule_delayed_work` implements 3.10's
  no-restart pending-timer semantics; `input_report_key` implements the input-core
  change-suppression view (userspace stream) alongside the raw driver-call stream.
- Asserts the D43 shapes before running (sample-only tasklet, resume re-sync, suspend
  cancel-first) and fails loudly on an unpatched tree — it cannot silently pass on
  stale code.
- The `kpd: dropped N glitch bits` ratelimited print is exercised (visible in G2/G3).

## E5 — Full 82-chain build replay (G-B1) — PASS, with an important reproducibility finding

Karen re-ran the entire chain independently (same pinned checkout, same series, same
toolchain, same reconstructed base boot image Forge used):

```
Q5_BUILD_WORK=<karen-scratch>/build-d43-replay \
  bash build/82_kernel_delta_power_audio.sh .reference-kernel-3.10.54 \
  <forge-m5p1>/base/boot-d42-r3-16MiB.img
→ all gates green (D43 greps 1–6, D44 invariants, defconfig guard, protocol gate,
  G1–G6), zImage built, repack OK, CHAIN_EXIT=0
```

- **Defconfig drift**: d42-series `.config` vs d43-series `.config` generated
  independently → **byte-identical** (spec gate "diff vs d42 build = EMPTY" ✓;
  Forge's empty `defconfig-diff.txt` corroborated).
- **Warning profile** (normalized for build path): zero new target-code warnings; the
  only 2 extra lines in Karen's replay are host-tool warnings
  (`scripts/sortextable.c`, `usr/gen_init_cpio.c`) — exactly the two host tools Forge's
  report called out as environment-dependent. Consistent with Forge's claim.
- **D43/D44 symbols in the built vmlinux**: `kpd_glitch_work_func`,
  `kpd_glitch_drops`, `__param_kpd_glitch_ms`, `kpd_show_scan`/`__param_kpd_show_scan`,
  and the `kpd: dropped %lu glitch bits` format string all present (both builds).

### E5.1 — NEW FINDING (Medium, process): the kernel build is NOT byte-reproducible across build-directory paths

Karen's replay produced `boot-d43.img` sha `6e1c1a0b…` vs Forge's `c3229c5b…`
(Forge's artifact verified on disk before the replay; restored afterwards). Root cause
was fully diagnosed — **the compiled CODE is identical; the differences are embedded
build metadata**:

1. **MTK's debug macros embed absolute `__FILE__` paths in `.rodata`** (~810 strings).
   Karen's workdir path is 4 chars/entry longer than Forge's → `.rodata` grows by
   3408 bytes → every subsequent section/symbol address shifts (80,650 address-like
   dwords differ; `__modver` size delta is page-alignment fill, both sections end
   exactly on the next page boundary).
2. **Three `__TIME__` strings** from pre-existing MTK code (`mali_kernel_linux.c`,
   `umplock_driver.c`, `ump_kernel_linux.c`, `ccci_platform.c`, `swcr.c` — all
   pre-existing, none D43/D44).
3. **Proof of code identity (K10)**: `.text` sections of **all 2380 objects with code
   are byte-identical** between Forge's build and Karen's replay (148 objects have no
   `.text` — empty subsystems; 0 asymmetric). The only 4 intermediate links with
   differing `.text` (`drivers/built-in.o`, `drivers/misc/built-in.o`,
   `drivers/misc/mediatek/built-in.o`, `vmlinux.o`) differ ONLY in 14 literal-pool
   words (`.word` addends referencing the shifted `.rodata` symbols — disassembly
   verified: identical instructions, e.g. `masp_hal_secure_algo`'s pool
   `0x0007a2bc` vs `0x0007a550`).
4. **Ramdisk: byte-identical** between the two boot images (same base, same repack).

**Consequence for the release process** (folds into A3): a rebuild on a different
machine/path can NOT be verified by comparing `boot-d43.img` shas — the kernel bytes
will legitimately differ. Release verification must instead compare (a) ramdisk bytes
(must be identical), and (b) code equivalence (leaf-object `.text` comparison, as done
here), or rebuild in a canonical pinned workdir path. Severity: Medium (process);
zero code impact — both builds are correct builds of the same source.

## E6 — `build/patch_arsc_values.py` T1/T2 EXECUTED — PASS

Karen re-ran both gates independently (scratch outputs; donors untouched — re-hashed
after all runs):

**T1** (`--set-bool config_voice_capable=false` on donor framework-res.apk):
```
bool/config_voice_capable id=0x0112006c config=default: 0xffffffff -> 0x00000000
input  sha256 4ef9ce5166cbaa1fe7f3a0682bb9ba2a668c0b73dd7ca8877da65053af96e6d2
output sha256 24e802b975dd3a4be300ef68b6f5a27a2be99564367c55f48442d597521558f5
arsc before 0e9c86f600ea479f05466436027f4cf0ffa794e55edb9ffd4f81085cf32479c7
single-dword diff @ 19406564 (= 0x1281ee4); self-verification 1/2/3 PASS; exit 0
```
Byte-identical to Forge's reported outputs (both shas match Forge's pass-2 report) —
the tool is deterministic and reproducible.

**T2** (`--set-int def_wifi_sleep_policy=0` on donor SettingsProvider.apk):
```
integer/def_wifi_sleep_policy id=0x7f050003 config=default: 0x00000002 -> 0x00000000
input  sha256 803f2b6641b7ed8ffddca5f5a49eb6bf5b3f258f412dd21e94ae5bee5dbf764b
output sha256 c6fc0cc472bba80ce06752fb22bab060d487a3ff1d4f0adf15a76d0c3ece6bab
single-dword diff @ 10956; self-verification 1/2/3 PASS; exit 0
```
Before-value 2 matches the spec's "current default 2 — matches Hera's live finding". ✓

**Idempotence (K4)**: re-patch of the T1 output → accepted as a no-op
(`0x00000000 -> 0x00000000`, `arsc_diff_offsets: []`, exit 0). Self-verifying and
idempotent as required. ✓

**Negative paths (K5)**: `--set-int def_wifi_sleep_policy` on framework-res and
`--set-int config_voice_capable=0` both refuse (exit 1, no output APK written) with
"refusing to proceed on 0 hits". Dtype-mismatch refusal and complex/bag-entry abort
are coded and reachable. ✓

**Zip rebuild (verified on the T1 output)**: `resources.arsc` STORED, data offset
4-byte aligned, namelist identical to donor, `testzip()` clean. ✓

**§5.2 conformance verified in source**: no apktool/aapt; UTF-8 (1- and 2-byte length
forms) + UTF-16 pools; TYPE_SPEC/TYPE walk with inline pools skipped by size; NO_ENTRY
skipped; matching by key name AND type name with dtype enforcement; ≥1 hit asserted
with per-hit before/after printed; rebuild mirrors build_branding.py's alignment
convention; three self-verification checks; manifest JSON with all required fields.

## E7 — `build/apply_system_defaults.py` vs §5.4 — PASS (code; full G-B4 deferred)

Source review + executed code paths (K6–K8) against a scratch COPY of the real donor
image (`~/q5-flash/rom/system.img`, pin `cd6e9b54…` verified before and after):

1. **`--settingsprovider PATH`** — optional arg; EARLY verification (before any image
   mutation) via the imported reader: ≥1 hit, `type_name == 'integer'`, `dtype == 0x10`,
   `value == 0`; refusal message points to §5.2/T2. When present, placed with the
   existing `put()` (rm-if-exists, write, SELinux label `u:object_r:system_file:s0` +
   label readback, sha readback) to `/priv-app/SettingsProvider/SettingsProvider.apk`;
   sha lands in the `changes` manifest. **Executed**: T2 output accepted; unpatched
   donor refused (exit 1, §5.2-pointing message). ✓
2. **`ro.radio.noril=true` build.prop block** — placed immediately after the
   `persist.af.audio_patch_fm` block, same regex style (`(?m)^key=.*$`, ≤1 existing
   line asserted, replace-in-place else append). **Executed** against the donor's real
   build.prop: appended exactly once; `qemu.hw.mainkeys` / `persist.af.audio_patch_fm`
   blocks untouched; donor confirmed to contain NO noril line pre-patch
   (independently confirming spec §1.2). ✓
3. **framework-res arsc guard** — immediately after the put-loop (i.e., after
   `put(branding/framework-res.apk, /framework/framework-res.apk)`), the written file
   is dumped back OUT of the image via debugfs and parsed with the imported reader;
   asserts `config_voice_capable` bool/0x12/value 0. **Executed**: real `put()` of the
   T1-patched APK → guard PASS; UNPATCHED donor → refused with the exact §5.4.3
   message. Catches the §5.3 pipeline-order regression (branding on an unpatched
   donor) as designed. ✓
4. **Do-not-touch constraints** — no telephony package removal (removal loop still
   only Jelly/HTMLViewer/OpenCamera/XposedInstaller); `prune_features` untouched by
   this delta; `persist.radio.multisim.config` / `keyguard.no_require_sim` unreferenced. ✓
5. **Manifest pins** — both patched APK shas recorded in the output manifest `changes`
   via `put()`. Forge pass-2 deviation D2 (no standalone
   `manifests/audio-hygiene-v1.0.1.json` file) is **accepted with a recommendation**:
   the spec sentence is ambiguous ("…-style pins … (both recorded in the output
   manifest `changes` as today)"); the shas ARE pinned. If Bob wants the standalone
   file, it belongs to the `package_checkpoint.py` release step — flag for Hera.

**Not executable here**: the full `main()` run (needs the v1.0.1 build inputs that live
on Bob's machine). This is the same class as Forge's pass-2 deviation D5 and is
inherent to the environment, not a gap in the implementation.

---

## A1 — Adjudication: resid discrepancy — **Forge is CORRECT; the right entry was patched**

**Question**: Bob's spec says `config_voice_capable` is resid `0x011200a9` (entry 169);
Forge's name-based resolution found `0x0112006c` (entry 0x6c = 108) and says `0xa9` is
`config_sms_decode_gsm_8bit_data`. Which is right at the byte level, and did Forge
patch the right entry?

**Method**: Karen wrote an INDEPENDENT ARSC walker (from the AOSP ResourceTypes.h
layout, sharing no code with Forge's parser) plus a raw-hexdump manual decode of the
donor `.reference-lithium/framework/framework-res.apk` arsc. Bob's scratch arsc
(`opencode/m5/framework-res.arsc`, sha `0e9c86f6…`) was confirmed byte-identical to the
donor's embedded arsc — Bob's evidence was gathered from the same bytes.

**Findings (raw bytes, no parser trust)**:
1. The value field at Bob's claimed arsc offset `0x1281ee4` contains
   `08 00 00 12 ff ff ff ff` = value size 8, res0 0, dtype 0x12 (INT_BOOLEAN),
   data `0xffffffff` (TRUE). **Bob's byte anchor is real.**
2. The entry header immediately before it (`0x1281ed8`) is size=8, flags=0,
   **key index 9186** — exactly the key index Bob's spec cites ("key index 9186 of
   9567"; pool count 9567 also confirmed).
3. Key-pool entry 9186 raw bytes:
   `14 14 63 6f 6e 66 69 67 5f 76 6f 69 63 65 5f 63 61 70 61 62 6c 65 00`
   → UTF-8 length fields (20, 20) + ASCII **"config_voice_capable"** + NUL —
   human-readable in the hex dump.
4. That entry sits at **entry index 0x6c (108)** of the bool TYPE chunk (type id 0x12,
   package 0x01) → **resid 0x0112006c. Forge's number is correct.**
5. Entry 0xa9 (169) of the same chunk is key index 9247 =
   `config_sms_decode_gsm_8bit_data`, data `0x00000000` (false). **Bob's `0x011200a9`
   is a different resource** — exactly as Forge reported.
6. `config_voice_capable` exists in exactly ONE config (the default) across all 62
   bool TYPE chunks (other configs' entry 0x6c is NO_ENTRY) — matching the spec's
   "single default config" note and the tool's `patched_count: 1`.
7. **Three-way offset agreement**: Bob's claimed value-field offset `0x1281ee4` ==
   decimal 19406564 == Forge's manifest `arsc_diff_offsets[0]` == Karen's independent
   probe's value-field offset for entry 0x6c. **The single dword Forge patched IS the
   value field Bob's evidence chain identified.**

**Verdict**: Forge patched the RIGHT entry (`config_voice_capable`, TRUE→FALSE,
dtype 0x12, single-dword diff). The spec's byte-level evidence (key index 9186,
offset 0x1281ee4, value 0xffffffff) was correct all along; only the DERIVED
resid/entry number (`0x011200a9`/169) is wrong for this donor — it likely came from a
different framework build's bool entry ordering or a doc reference. The §5.2
name-based matching rule is the binding implementation rule and is immune to the
discrepancy. **Recommendation**: correct the spec text to "resid in the v1.0.0 donor
arsc: 0x0112006c; match by name per §5.2" (Forge's own recommendation, endorsed).
Severity: **Informational** (spec documentation defect; zero behavioral impact).

**Side finding (Informational)**: Bob's post-hoc re-verification probes
(`opencode/m5-verify/arsc2.py`, `arsc_bool.py`) are broken — they add `headerSize +
stringsStart` to the pool base when decoding strings (stringsStart is relative to the
chunk START, per the very layout facts in §5.2), so they decode garbage and report
`key index: None`. They cannot have produced the spec's correct byte anchor; the m5
scratch run's decoder must have been a different (correct) one. No action needed for
v1.0.1; noted so nobody trusts those two scripts later.

## A2 — Adjudication: D1 drop-counter formula — **Forge's correction is sound and matches Bob's intent**

**Question**: Forge replaced the spec pseudocode
`kpd_glitch_drops += popcount(changed & ~stable_mask)` with
`dropped += hweight16(S1 ^ S2)`, claiming the spec formula is provably 0 for the
pulses the filter kills. Confirm the correction matches Bob's intent
(storm-attribution counter) and that report behavior is unchanged.

**Analysis (symbolic, both glitch presentations)**:
- The literal expression is `popcount((S2 ^ reported) & (S1 ^ S2))`: a bit contributes
  only if it differs from the reported state at S2 AND is unstable across the window.
- A self-contained glitch pulse — the exact thing the filter exists to kill — returns
  the matrix to baseline by work time, so `S2 == reported` for its bits:
  - press-edge-only presentation (release settles without a further IRQ): S1 keeps the
    pressed bit, S2 = baseline → `(S2^reported)=0` → literal counts **0**;
  - both-edges presentation (release edge IRQs and resamples S1): S1 = S2 = baseline →
    literal counts **0**.
  In both cases the implemented `hweight16(S1^S2)` counts 1 / 0 respectively — i.e. the
  literal form counts exactly 0 for every pulse the filter is designed to kill, making
  G2 ("drop counter increments"), G3 ("drops == observed glitches") and the §6
  storm-death-certificate metric ("kpd: dropped N glitch bits" showing the storm
  dying) unsatisfiable as written. **Karen independently confirms Forge's proof.**
- The implemented form never counts a reported bit (reported bits are stable by
  construction ⇒ absent from S1^S2), never double-counts (each work run counts its own
  window's unstable bits), and is a strict superset of the literal form's (empty)
  count on real storms.
- **Report behavior is unchanged**: the reporting path (`report_mask = changed &
  stable_mask` + per-bit report) is byte-for-byte the spec's pseudocode; only the
  counter accumulation differs. G1–G6 (executed, E4) prove the reporting behavior.
- Residual imprecision (accepted, informational): in the both-edges presentation the
  implemented counter also reads 0 (S1 was resampled to baseline), so the counter
  attributes only press-edge-only pulses; and a state change landing between S1 and S2
  without an IRQ (rare race) is counted although it may be reported in the next window.
  This affects attribution precision only — the counter is a diagnostic, not a
  correctness gate. Bob's §6 intent ("after d43, an idle dmesg should show ~0 of all
  three") is served: the metric counts what the window killed.

**Verdict**: Forge's D1 deviation is **accepted** — it repairs an unsatisfiable spec
formula while preserving the reporting semantics and the counter's diagnostic intent.
Recommend Bob annotate the spec pseudocode (counter = unstable bits across the
window, `hweight16(S1^S2)`). Severity: **Informational**.

## A3 — Adjudication: D3 build base — **RELEASE-GATE item (agreed with Forge), now with a sharper verification recipe**

Forge built `out/boot-d43.img` against `.reference-kernel-3.10.54` (pinned revision
verified: `96e535524cb10b9e3d9ea2d0e69599726605ae8e`) plus a base boot image
RECONSTRUCTED on this machine from `boot-m1b-beta-touch-lcm-board14.img` via the
documented deterministic chain (`patch_fm_boot_node.py` → R1, `patch_usb_boot.py` →
R2, `patch_codec_boot.py` → R3, zero-padded to 16 MiB) — NOT against the released
`/root/q5-kernel-reference` + the device's actual D42-R3 boot image (which live on
Bob's machine).

**Karen's position**: the current `out/boot-d43.img` (sha
`c3229c5b83089e8b02b7bddba3db684783b397ea389768cd7a2f4fc15a1e2ec8`, 16,777,216 bytes —
verified on disk) must **NOT be treated as the shippable artifact**. The kernel code is
proven (E5/K10), but the ramdisk/header bytes derive from a reconstructed base whose
equivalence to the released D42-R3 boot image is asserted by pipeline logic, not by
byte comparison against the released artifact.

**Release-gate condition (blocking for the v1.0.1 flash)**: when the released D42-R3
boot image is at hand, re-run the 82 chain against it and verify:
1. **ramdisk bytes identical** to this build's (Karen's replay already proves the
   repack is deterministic given the same base);
2. **kernel code equivalence** — NOT sha equality: per E5.1 the kernel legitimately
   differs across build paths (MTK `__FILE__` embedding + `__TIME__`). Either rebuild
   in the same canonical workdir path used for the release, or verify via leaf-object
   `.text` comparison (the K10 method) / disassembly.
Until then: **WARN** on the artifact, PASS on the code. Severity: **Medium (process)**,
zero code impact.

---

## Defect summary

| # | Finding | Severity | Impact | Disposition |
|---|---|---|---|---|
| 1 | Spec resid `0x011200a9` wrong for this donor (correct: `0x0112006c`); byte anchor (offset 0x1281ee4, key 9186, value 0xffffffff) correct; Forge patched the right entry | Informational | none (name-based matching) | Bob: fix spec text |
| 2 | Spec drop-counter formula provably counts 0 for killed pulses (G2/G3/§6 unsatisfiable as written); Forge's `hweight16(S1^S2)` matches intent | Informational | none (reporting unchanged; G1–G6 pass) | Bob: annotate spec pseudocode |
| 3 | `boot-d43.img` built against a reconstructed base, not the released D42-R3 boot image | Medium (process) | release artifact not shippable as-is | RELEASE-GATE: rebuild against released base (A3) |
| 4 | Kernel build not byte-reproducible across build paths (MTK `__FILE__` in .rodata + `__TIME__`); code proven identical via 2380/2380 leaf-object `.text` comparison | Medium (process) | release verification methodology must compare ramdisk + code-equivalence, not kernel sha | Folded into A3's verification recipe |
| 5 | Bob's `m5-verify` probes (arsc2.py/arsc_bool.py) decode string pools with a headerSize+stringsStart double-count → always report `key index: None` | Informational | broken diagnostic scripts (not part of the deliverable) | Do not trust those scripts; no v1.0.1 action |
| 6 | §7.2 device gates V0–V14 unexecuted (headless) | — (environmental) | device behavior unproven | WARN — deferred to Hera per task |
| 7 | G-B4 full-pipeline run + G-B5 + docs/INSTALL.md §5.3 recipe (Forge pass-2 D3) outstanding | Low (process) | release-build steps | Hera at v1.0.1 packaging |

No Critical or High severity defects. No functional defects found in any executed test.

---

## Release recommendation

**Not Ready for Release (yet) — zero code defects; blocked on release-gate conditions.**

The m5 implementation itself is validated: every §5.1/§5.2/§5.4 item matches the spec
(all four D43 bolts, the D44 hunk, the build plumbing, the host test, the ARSC patcher,
the system-defaults wiring), the full 82-chain replay is green end-to-end, and both
adjudicated deviations (resid, drop-counter) resolve in Forge's favor with byte-level
and symbolic proofs. What blocks the v1.0.1 flash release is process, not code:

1. **Rebuild the release boot image against the released D42-R3 base boot image**
   (A3 + E5.1): ramdisk bytes must match; kernel verified by code-equivalence (or a
   canonical build path), never by cross-path sha comparison. The current
   `out/boot-d43.img` is a bring-up artifact, not the shippable one.
2. **Run the full G-B4 pipeline** with the real v1.0.1 inputs (T1→branding→T2→apply)
   on the release machine, plus G-B5 and the §5.3 docs/INSTALL.md recipe addition;
   emit `manifests/release-v1.0.1.json` with the pinned shas (including the standalone
   arsc manifests if Bob wants them).
3. **Execute §7.2 device gates V0–V14 on hardware (Hera)** — V1 (soak thresholds),
   V3/V4 (volume keys → STREAM_MUSIC), V12 (wifi_sleep_policy=0), V13 (noril) are the
   acceptance spine; V2 is the user's overnight check. Until these run, the device-side
   behavior of both workstreams is unproven by definition of this headless review.
4. (Informational, non-blocking) Bob's spec text fixes: resid `0x0112006c`, drop-counter
   pseudocode annotation.

**Per-workstream final verdicts**: Pass 1 (kernel) **PASS** (code; artifact WARN per
A3). Pass 2 (ARSC + system defaults) **PASS** (code; full-pipeline run deferred).
Adjudications: A1 Forge correct / A2 Forge accepted / A3 release-gate. Device gates:
**WARN, deferred to Hera.**

*(End of report — Karen, m5 validation. Nothing was committed; the working tree was
restored to its pre-review state.)*
