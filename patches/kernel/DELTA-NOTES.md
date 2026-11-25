# §3 Deltas without a file diff — assertions & rationale (Forge M1b)

These §3 rows change no bytes in the kernel tree by design; `build/50_kernel_delta.sh`
asserts each invariant and aborts on violation. Their deltas are *selections* and
*non-actions*, per `bob-m2-spec.md` §3 and the task hard rules.

## D3 (Case A — keep `CONFIG_MTK_SMART_BATTERY=y`)
- Invariant asserted: `q5_defconfig` keeps `CONFIG_MTK_SMART_BATTERY=y`.
- Effect: FGADC (`battery_meter_hal.o`) stays the *only* fuel gauge — exactly Mint's own
  kernel driver set (§2.2). No MAX17050SW6106 option exists anywhere in this tree and none
  is ported (D7 class reasoning: chip is absent on Mint hardware).

## D5 (Case A — `cust_battery_meter_table.h` verbatim clone)
- Invariant asserted: `arch/arm/mach-mt6582/q5/power/cust_battery_meter_table.h` is
  byte-identical to the a106 original (`cmp`).
- Rationale (§2.2): Mint's compiled FGADC profiles are not binary-recoverable; the generic
  MT6582 100-pt ZCV/R-table set + runtime FGADC learning yields a working monotonic SOC.
  OQ-3 carries the calibration fallback if G3 shows implausible percentages.

## D6 (Case B — `cust_charging.h` thresholds kept)
- Invariant asserted: `arch/arm/mach-mt6582/q5/power/cust_charging.h` is byte-identical to
  the a106 original (`cmp`): `V_PRE2CC_THRES 3400`, `V_CC2TOPOFF_THRES 4050`,
  `RECHARGING_VOLTAGE 4230`, AC/USB currents unchanged.
- Rationale: the SW6106 (autonomous, hardware) sets the real input current; these bounds
  govern only the PMIC-notification/UI thread. Raising AC current is explicitly forbidden
  by the D6 row.

## D7 (Case B — non-delta: NO bct24157/fan5405 port)
- Invariant asserted: no `bct24157*` / `charging_hw_fan5405*` / `fan5405*` sources exist in
  the tree after deltas (the D1 defconfig change already un-compiled them).
- Escalation path (§3.2 D7 row): if G3-post-flash still shows dead charging, suspects are the
  q5 charge-related GPIO/`cust_pmic` settings — escalate to Bob; do NOT improvise a driver.

## D15 (Keys — no delta in primary build)
- Invariant asserted: `arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h` and
  `q5/dct/dct/inc/cust_kpd.h` are byte-identical to the a106 originals.
- Rationale: ADR-4's userspace dual-map (102+172→HOME with WAKE_DROPPED, M1a) covers both
  lineages; G5 verifies on-device. G5f fallback (transplant the Q5 matrix) only if G5 fails.

## D16 (GPIO usage — no speculative edits)
- Invariant asserted: `arch/arm/mach-mt6582/q5/dct/dct/inc/cust_gpio_usage.h` is byte-identical
  to the a106 original.
- Forge review pass (spec D16 row): the a106 map's consumers checked for conflicts with Q5
  hardware classes — LCM (`hx8369b` class panel vs Q5's gc9503v: display-side delta is OQ-7,
  evidence-gated at G2), camera pins (D11 uses the same abstract `pinSet`/`IDX_PS_*`
  framework with a106 values untouched), eint/accdet unaffected. Any wrong pin surfaces as a
  G1/G2 boot-log anomaly and gets patched from dmesg evidence — never blind.
