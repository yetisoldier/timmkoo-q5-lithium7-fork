# Forge — implement D25: touch via the MTK tpd framework (board6)

Implement Bob's design exactly. Read first, in this order:
1. `.specs/bob-tpd-framework-spec.md`  (binding design; §5 is your task list)
2. `.specs/touch-tpd-framework-task.md` (evidence + acceptance)

Do not re-investigate the root cause. Do not touch the device, do not flash, do not commit.

## What to build (per Bob §5)
- Rename the i2c driver so the sysfs link reads `mtk-tpd`: `tpd_i2c_driver.driver.name = TPD_DEVICE`
  (`"mtk-tpd"`), keeping `id_table` matching `gsl_tp` / 0x40 as the blob proves (`0xc0b74d64`).
- Drop the legacy `force[]`/`forceload` path if the board info already instantiates 0x40.
- Add the stock probe-order details we were missing: **EINT pre-mask before the i2c gate**, the
  **5-retry reg-0xfc gate**, and the guarded unconditional `gsl_sw_init` that **sets `sw_inited = 1`**
  (our port never sets it — do not silently change its semantics).
- Button glue so the framework creates `mtk-tpd-kpd` with keys `{172, 158}`.
- Remove the D23 keep-registered diagnostic from the production path.
- Preserve: D17 i2c contract, D22 bounded loader + alive gate, D24 five-rail power + 100 ms settle,
  GPIO14 reset, GPIO2 INT pull-up, EINT 2 rising, D20 header precedence, D21 MBR 0x1400000.

## Pipeline
- New stage `build/66_kernel_delta_tpd.sh` (clone 65's shape), O-dir
  `build-beta-touch-lcm-board6`, patch list D1…D24 + `D25-tpd-framework.patch`.
- `build/55_repack_boot.sh`: add tag `beta-touch-lcm-board6` (keep existing tags intact).
- Re-assert every D1–D24 invariant enumerated in Bob §5, plus the new D25 gates
  (driver-name string in the object/Image, EINT pre-mask order, 0xfc gate, `sw_inited` set,
  button keys, D23 absent from the shipped image).
- Zero new warnings vs the board5 baseline; reproducible zImage on re-run.

## Acceptance (static only)
- `out/boot-m1b-beta-touch-lcm-board6.img` + `.sha256`, repack verify OK.
- Gates print PASS; D23 marker absent from the shipped Image.
- Report the exact commands, zImage/Image sha256, image sha256, and any invariant you had to
  re-pin (with justification).

## Output
`.specs/forge-d25-report.md`, ending "Implementation complete" or "blocked on X".

Reminder: a build failure caused by a stale `build-beta-touch-lcm-board6/` directory is a state
gate, not a code failure — report it, don't thrash.
