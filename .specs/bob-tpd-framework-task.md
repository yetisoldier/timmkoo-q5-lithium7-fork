# Bob — design: move touch onto the MTK tpd framework

Read `.specs/touch-tpd-framework-task.md` first (decisive evidence + acceptance). This is a DESIGN
task only; do not implement, do not build, do not touch the device.

## Problem in one line
The panel answers the in-tree MTK framework driver (`0-0040 -> mtk-tpd`, stock Lithium works), but not
our standalone i2c driver (`gsl_tp`), which fails `I2C_ACKERR` on every bus/address even with the
vendor's exact power rails (verified ON), GPIOs and 100 ms settle.

## What to produce
1. **Framework contract.** Read `drivers/input/touchscreen/mediatek/mtk_tpd.c` (`tpd_driver_add`,
   `tpd_driver_list`, `TP_DRV_MAX_COUNT`, `tpd_probe`), plus `tpd_default.c`, `tpd_setting.c`,
   `tpd.h`. Document exactly what a panel driver must provide (struct `tpd_driver_t` fields,
   `tpd_local_init`/suspend/resume semantics, who allocates the `i2c_client`, who sets bus speed,
   who owns EINT), and how `tpd_device_name` interacts with the i2c device name "gsl_tp"/0x40.
2. **Mapping of our existing code.** For each piece we already have (i2c read/write contract,
   bounded fw loader, alive gate, reset GPIO14, INT GPIO2, EINT 2 rising, power sequence, event
   thread, /proc debug), state where it belongs in the framework shape: `tpd_local_init`,
   `tpd_i2c_probe` equivalent, or the framework's own probe.
3. **Why the standalone path fails.** Give the most defensible technical explanation of why the
   panel ACKs the framework but not our driver (e.g. client/bus configuration, timing at
   `device_initcall` vs `module_init`, bus speed, pull-up/pin state at that moment, or the
   framework's power sequence order). Mark clearly what is proven vs hypothesised — do NOT assert
   an unverified cause.
4. **Implementation plan.** Exact files to add/modify, the order of operations, how to disable the
   standalone registration cleanly without breaking D17–D24 invariants, and which build stage /
   O-dir / repack tag to use. Note every existing invariant that must be re-asserted.
5. **Risks + fallback.** What breaks if the framework claims 0x40 before our code; how to keep the
   D23 diagnostic out of production; rollback path (stock Lithium boot image is known-good).

## Output
`.specs/bob-tpd-framework-spec.md`, implementation-ready for Forge, ending with
"Design complete" or "partial (blocked on X)".
