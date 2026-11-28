# Karen task — m5 validation (Power & Audio, v1.0.1)

## Read (design intent + implementation)
1. `.specs/bob-m5-power-audio-spec.md` — the FULL design spec (validate implementation against
   design INTENT, not just correctness). §7 is your validation baseline; expand freely.
2. `.specs/forge-m5-pass1-report.md` and `.specs/forge-m5-pass2-report.md` — Forge's reports,
   especially their **deviations** sections.

## What to validate (read-only — do NOT write source)
The uncommitted working tree contains the full implementation. Review against the spec:

**Kernel (Pass 1):**
- `patches/kernel/D43-kpd-phantom-storm.patch` vs §5.1.1 (K1 mtk_kpd.h, K2 pmic_mt6323.c,
  K3 kpd.c + hal_kpd.c scan-log gate).
- `patches/kernel/D44-wlan-ahb-isr-window.patch` vs §5.1.2 (gl_kal.c `(HZ/10)`→`(HZ/50)`).
- `build/kernel-d43.series`, `build/82_kernel_delta_power_audio.sh`,
  `build/75_kernel_delta_coherent_dma.sh` (d43 tag case), `patches/kernel/DELTA-NOTES.md`.
- `build/test_kpd_filter.py` — host test G1–G6; RUN it and report results.

**ARSC (Pass 2):**
- `build/patch_arsc_values.py` vs §5.2 — run its T1/T2 gates; confirm it flips
  `config_voice_capable` to false and is self-verifying + idempotent.
- `build/apply_system_defaults.py` vs §5.4 — confirm `ro.radio.noril=true` + `wifi_sleep_policy=0`
  baked in, and the arsc guard.

## Specific items to adjudicate (from Forge's deviations)
1. **Resid discrepancy**: Bob's spec says `config_voice_capable` resid is `0x011200a9`; Forge's
   name-based resolution found `0x0112006c` (claiming `0xa9` is `config_sms_decode_gsm_8bit_data`).
   VERIFY which is correct at the byte level, and confirm Forge patched the RIGHT entry
   (`config_voice_capable`, value TRUE→FALSE).
2. **Pass-1 D1 drop-counter**: Forge replaced `popcount(changed & ~stable_mask)` with
   `hweight16(S1 ^ S2)`, claiming the spec formula is provably 0. Confirm the correction matches
   Bob's intent (storm-attribution counter) and report behavior is unchanged.
3. **Pass-1 D3 build base**: Forge built `boot-d43.img` against `.reference-kernel-3.10.54` +
   reconstructed base (not the released `/root/q5-kernel-reference`). Flag this as a release-gate
   item — do NOT treat the current `boot-d43.img` as the shippable artifact.

## Constraints
- Read-only: no source writes, no edits, no `git commit`. Your report IS the deliverable.
- You run headless (no real Q5). The §7.2 device gates are UNEXECUTABLE here — mark them WARN
  (code validated, hardware gate deferred to Hera), not PASS.
- Write your report INCREMENTALLY to `.specs/karen-m5-report.md` (verdict + evidence table first,
  then per-item proofs), so a partial run still leaves a usable deliverable.

## Output
`.specs/karen-m5-report.md` — clear PASS/FAIL/WARN verdict per workstream, findings, and the
release-gate conditions that remain. Do NOT git commit.
