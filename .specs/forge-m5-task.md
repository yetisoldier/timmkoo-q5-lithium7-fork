# Forge task — m5: implement Bob's Power & Audio spec

## Read first
`.specs/bob-m5-power-audio-spec.md` — implement **§5 (Implementation specification) EXACTLY**.
Do NOT re-design, do NOT re-investigate. The design is settled (two ADRs). Your job is faithful,
code-level implementation of §5.

## Deliverables (all in §5 — implement each precisely)
1. **D43 kernel patch** (§5.1) — phantom-input storm kill: unmap `fchrkey` + mask its PMIC IRQ +
   the restartable `delayed_work` matrix glitch filter (`kpd_glitch_ms`, default 150 ms), per the
   exact functions/lines/symbols Bob named.
2. **D44 kernel patch** (§5.1) — bound the WLAN AHB ISR suspend window 100 ms → 20 ms.
3. **`build/patch_arsc_values.py`** (§5.2) — self-verifying tool that flips
   `config_voice_capable` (resid `0x011200a9`) to false in `framework-res.apk` at build time.
4. **Pipeline integration** (§5.3) — the new `82_kernel_delta_power_audio.sh` stage.
5. **`build/apply_system_defaults.py` edits** (§5.4) — bake `ro.radio.noril=true` and
   `wifi_sleep_policy=0` into defaults, matching existing file style.
6. **`build/test_kpd_filter.py`** (§5.5) — the host test with all 6 gates, wired to run BEFORE
   flash in the 82 chain.

## Hard constraints
- **§5.6 Files NOT to touch** — read and obey that list exactly. accdet/tpd are ruled OUT of scope
  (do not modify them).
- Do not flash the device; emit `out/boot-d43.img` (+ `.sha256`) only, never run the flash step.
- **Declare deviations**: your report must carry an explicit "deviations from spec" section with a
  reason for every place you depart from §5 (even a correction). No silent improvisation.
- Write the report file **INCREMENTALLY** (changed-files ledger first, then per-item status) so a
  partial run still leaves a usable deliverable.

## Output
Write your report to `.specs/forge-m5-report.md` (incremental). Save and stop when §5 is fully
implemented and the host test passes. Do NOT `git commit` — Hera commits after review.
