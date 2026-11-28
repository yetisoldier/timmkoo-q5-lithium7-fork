# Forge task — m5 Pass 1 of 2: KERNEL changes only (D43 + D44)

## Read: `.specs/bob-m5-power-audio-spec.md` §5.1 (and ONLY §5.1)
The spec ALREADY names every exact file, line number, function name, and code snippet you need.
**Do NOT re-read the kernel source to re-derive anything — apply the spec's edits directly.**
No probing, no reconnaissance. The design and every symbol are settled; your only job is faithful
mechanical application of §5.1.

## Scope (kernel / build integration — this pass ONLY)
1. `patches/kernel/D43-kpd-phantom-storm.patch` — §5.1.1 (K1 mtk_kpd.h, K2 pmic_mt6323.c,
   K3 kpd.c + hal_kpd.c scan-log gate).
2. `patches/kernel/D44-wlan-ahb-isr-window.patch` — §5.1.2 (gl_kal.c `(HZ/10)`→`(HZ/50)`).
3. `build/kernel-d43.series` — = d42 series + D43 + D44 appended.
4. `build/82_kernel_delta_power_audio.sh` — thin 78-pattern wrapper, `Q5_KERNEL_TAG=d43`.
5. Edit `build/75_kernel_delta_coherent_dma.sh` — add `d43` to the tag case list + config
   assertions + `test_touch_key_protocol.py` gate (treat d43 like d42).
6. Append D43 + D44 entries to `patches/kernel/DELTA-NOTES.md` (verbatim from §5.1).
7. `build/test_kpd_filter.py` — host test G1–G6 per §5.5, wired to run in the 82 chain.

**NOT in this pass** (deferred to Pass 2): `build/patch_arsc_values.py` and
`build/apply_system_defaults.py` (the ARSC/WS2 work). Do NOT touch them.

## Hard constraints
- Obey §5.6 do-not-touch list exactly (accdet/tpd are OUT of scope).
- Do NOT flash; emit `out/boot-d43.img` (+ `.sha256`) only.
- **Deviations section required** — list any place you depart from §5.1, with a reason.
- Write the report file `.specs/forge-m5-pass1-report.md` INCREMENTALLY (changed-files ledger
  first, then per-item status). Do NOT `git commit`.

## Output
`.specs/forge-m5-pass1-report.md` — save and stop when §5.1 is applied and the host test passes.
