# Bob task — m5: Power & Audio Hygiene (battery drain + volume keys)

## Read first (evidence brief — do NOT re-diagnose)
`.specs/hermes-brief-v1.0.1-power-audio.md` — contains the complete live-device diagnosis,
kernel wakelock telemetry, and the exact contradictions to resolve. Hera has already root-caused
both defects; your job is DESIGN, not re-investigation. Confirm the hypotheses against source,
then produce the implementation spec.

## Two workstreams (both must be covered in ONE spec — combined release)

### WS1 — Idle battery drain (device never deep-sleeps)
MT6582 kernel 3.10.54 input drivers (`mtk-kpd`, `mtk-tpd`, `ACCDET`) + MT662x WLAN generate
interrupt storms that keep the SoC awake ~12 of 18 h idle. Full wakelock table is in the brief.
Determine the correct fix (driver suspend/EINT/wake-source config vs. disabling unused drivers)
with exact file/function-level changes.

### WS2 — Volume keys control ringtone, not media
Framework still reports voice-capable even though `ro.radio.noril=true`. Determine the minimal
change (resource overlay `config_voice_capable=false` vs. build-config vs. removing telephony
packages) that makes volume keys default to STREAM_MUSIC without regressing media/FM/recorder.

## Artifacts to inspect (kernel + framework + patches)
- Kernel: `.reference-kernel-3.10.54/` — input drivers `drivers/input/keyboard/`,
  `drivers/input/touchscreen/mediatek/`, accdet under `drivers/misc/mediatek/`, WLAN/MT662x
  connectivity drivers.
- Patches over donors: `patches/`.
- Build/config: `build/`, `manifests/`, device tree / overlay locations in the tree.
- Current bring-up state: `CURRENT-STATUS.md`, `FUNCTIONAL-AUDIT.md`, `HANDOFF.md`,
  `FM-BRINGUP.md`, `MEDIA-BRINGUP.md`.

## Deliverables (write INCREMENTALLY to `.specs/bob-m5-power-audio-spec.md`)
1. Root-cause confirmation for each workstream (cite the exact driver files/functions and the
   framework flag/package).
2. 3+ options per workstream with tradeoffs, and a clear recommendation.
3. A code-level implementation spec (per-module change tables, exact signatures/flag names,
   untouched-surface constraints, and the test/regression gates). Forge (a cheap model) will
   implement ONLY from this spec, so it must name exact files, symbols, and invariants.

## Constraints
- Do NOT re-investigate the defects (evidence is settled); verify + design.
- Preserve already-working surface: media playback, FM tuner, recorder, USB transfer, touch,
  speaker routing (see CURRENT-STATUS.md). Both changes must be non-regressive.
- Write the spec file incrementally so a partial run still leaves a usable deliverable.
- Save and stop when the spec is complete.
