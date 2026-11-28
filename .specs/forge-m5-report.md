# Forge Report — m5: Power & Audio Hygiene (v1.0.1, kernel tag d43)

> Status: IN PROGRESS (incremental — see ledger below).
> Spec: `.specs/bob-m5-power-audio-spec.md` §5. Two ADRs (m5-WS1 W1, m5-WS2 V1) implemented as specified.
> No flash performed. Do NOT git-commit (Hera commits after review).

## 0. Changed-files ledger (updated as work completes)

| # | File | Action | Item | Status |
|---|------|--------|------|--------|
| 1 | `patches/kernel/D43-kpd-phantom-storm.patch` | new (K1+K2+K3+scan-log gate) | §5.1.1 | pending |
| 2 | `patches/kernel/D44-wlan-ahb-isr-window.patch` | new (K4) | §5.1.2 | pending |
| 3 | `build/kernel-d43.series` | new (= d42 series + D43 + D44) | §5.1 | pending |
| 4 | `build/82_kernel_delta_power_audio.sh` | new (78-pattern wrapper, `Q5_KERNEL_TAG=d43`) | §5.3 | pending |
| 5 | `build/75_kernel_delta_coherent_dma.sh` | edit (tag case + gates treat d43 like d42) | §5.3 | pending |
| 6 | `patches/kernel/DELTA-NOTES.md` | append D43/D44 entries verbatim | §5.1 | pending |
| 7 | `build/patch_arsc_values.py` | new (self-verifying arsc patcher, T1+T2) | §5.2 | pending |
| 8 | `build/apply_system_defaults.py` | edit (--settingsprovider, build.prop, arsc guard) | §5.4 | pending |
| 9 | `build/test_kpd_filter.py` | new (host test G1–G6, runs in 82 chain) | §5.5 | pending |
| 10 | `out/boot-d43.img` (+ `.sha256`) | build output — emitted only, never flashed | §5.1.3 | pending |

## 1. Per-item status

(sections filled in below as items complete)
