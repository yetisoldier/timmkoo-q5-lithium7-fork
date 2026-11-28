# Forge task — m5 Pass 2 of 2: ARSC + system defaults (WS2)

## Read: `.specs/bob-m5-power-audio-spec.md` §5.2, §5.3, §5.4 (and ONLY those)
The spec names every exact file, function, and value. **Apply it directly — do NOT re-derive or
re-read unrelated source.** Pass 1 (kernel) is DONE; you are completing the WS2 half only.

## Scope (this pass ONLY)
1. **`build/patch_arsc_values.py`** (§5.2) — self-verifying ARSC patcher that flips
   `config_voice_capable` (resid `0x011200a9`) to `false` in `framework-res.apk` at build time.
   Implement the T1 + T2 gates exactly as specified.
2. **`build/apply_system_defaults.py` edit** (§5.4) — bake `ro.radio.noril=true` and
   `wifi_sleep_policy=0` into the defaults (matching the file's existing style), plus the arsc
   guard per §5.4.

**NOT in this pass**: any kernel/patch/series/`82_*`/`test_kpd_filter.py` changes (Pass 1, done).
Do NOT touch them.

## Hard constraints
- Obey §5.6 do-not-touch list exactly.
- **Deviations section required** — list any departure from §5.2/§5.4 with a reason.
- Write `.specs/forge-m5-pass2-report.md` INCREMENTALLY (changed-files ledger first, then per-item).
- Do NOT `git commit`.

## Output
`.specs/forge-m5-pass2-report.md` — save and stop when §5.2 + §5.4 are implemented and the T1/T2
gates pass.
