# Touch integration via the MTK tpd framework (replaces the standalone gsl port)

## Decisive evidence (verified on device 2026-11-25)
- **Hardware is good.** Stock Lithium (boot-m1b-lithium-ctl.img) boots and the user confirmed touch
  works on it. It binds the panel as `0-0040 -> mtk-tpd` and exposes input devices
  `mtk-tpd` (event2) and `mtk-tpd-kpd` (event3).
- **Our fork cannot ACK the panel.** The standalone port registers its own i2c driver `gsl_tp`;
  on every bus/address it fails:
  - bus 0/1/2 × addr 0x40/0x15/0x5d all return `[mt-i2c]ERROR 548: I2C_ACKERR`,
  - `gsl_i2c_read_bytes i2c read failed @0xb0` then `D22: init failed (-1)`.
- **Ruled out:** power (`/proc/mt_pmic/dump_ldo_status` shows `VGP1=1, VIO28=1`; MT6323 has no VGP4,
  so the D24 VGP4 call is a no-op), and muxing (source-pinned `cust_gpio_usage.h` is identical to the
  DrvGen-generated header for I2C0 GPIO84/85, CTP reset GPIO14, INT GPIO2).
- **Conclusion:** the panel answers the MTK framework driver, not a parallel i2c driver. The port
  must integrate with `drivers/input/touchscreen/mediatek/mtk_tpd.c` (`tpd_driver_add()`), the way
  stock does, instead of registering `gsl_tp` itself.

## Task
1. Study how the in-tree framework expects a panel driver: `mtk_tpd.c` (`tpd_driver_add`,
   `tpd_driver_list`, `TP_DRV_MAX_COUNT`), `tpd_default.c`, `tpd_setting.c`, and how another
   in-tree panel driver (e.g. an FT5x/elan one) fills `struct tpd_driver_t`.
2. Convert our GSLX680 port into that shape: keep D17/D22 driver internals (i2c read/write contract,
   bounded firmware loader, alive gate), but expose them through `tpd_local_init()` +
   `struct tpd_driver_t` and `tpd_driver_add()`. Let `mtk-tpd` own the i2c client at 0x40 instead of
   registering a standalone `gsl_tp` i2c driver.
3. Keep the Q5 pin/power facts already proven: reset GPIO14, INT GPIO2 pull-up, EINT 2 rising,
   rails VGP1+VIO28 (both verified ON), 100 ms settle before the first i2c access.
4. Remove/disable the standalone registration path so only one driver claims 0x40.
5. Preserve D1–D24 behaviour; D23's keep-registered diagnostic must NOT ship.
6. Keep D20 header precedence and D21 MBR intact.

## Acceptance
- `for d in /sys/bus/i2c/devices/*/driver; do ...` shows `0-0040 -> mtk-tpd` on our fork.
- `/proc/bus/input/devices` lists `mtk-tpd` and `mtk-tpd-kpd`.
- Physical swipe produces coordinates (capture with `adb shell -tt getevent -lt`, **never** without
  `-tt`).
- Buttons still mapped VOLUMEUP/VOLUMEDOWN correctly; boot, display unchanged.

## Constraints
Build + static gates only. No flashing from the agent that writes code; Hera flashes and the user
verifies touch physically.
