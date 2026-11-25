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

## D7 (Case B — non-delta: NO bct24157 port)
- Invariant asserted: no `bct24157*` sources exist in the tree after deltas. The `fan5405*.c`
  files are the reference tree's *own* sources (present in the pristine clone, never ported from
  outside); D1 un-compiles them — proven by the δ-parity strings (`fan5405_config_interface` and
  `charging_hw_fan5405` = 0 hits in the β blob).
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

# D17 additions (touch port — Forge D17; see .specs/forge-d17-report.md)

## D17 (GAP-1 close — gsl_tp / GSL1680-family touch driver port)
- Files added by `patches/kernel/D17.patch`:
  - `drivers/input/touchscreen/mediatek/gslX680/{mtk_gslX680.c,gsl_point_id.c,Makefile,
    gslX680_fw_q5.h,gslX680_key_q5.h}` — donor skeleton (oxygen @ed79b470 gslX68X) + the
    Q5's own firmware extracted from the pinned Lithium blob
    (`build/extract_gsl_fw_from_blob.py`, tiling-verified, sha-pinned in
    `manifests/kernel-sources.sha256` as `donors/gslX680/gen-gslX680_fw_q5.h`).
  - `arch/arm/mach-mt6582/q5/touchpanel/gsl_tp/tpd_custom_gsl_tp.h` — board glue
    (name "gsl_tp", i2c-0 0x40, power VIO28@1.8 V + VGP1@2.8 V "TP", EINT RISING).
- Wiring cross-checks (blob forensics, ALL evidence-locked):
  - reset GPIO14 / INT GPIO2 = the blob's `mt_set_gpio_out(0x8000000E/0x80000002, …)` —
    *already declared* as `GPIO_CTP_RST_PIN`/`GPIO_CTP_EINT_PIN` in the a106/q5 lineage
    `cust_gpio_usage.h` (byte-identical file, so D16's untouched-file invariant HOLDS).
  - EINT channel 2 RISING: the blob compiles `mt_eint_registration(2, flag=1)`; the q5
    `cust_eint.h` (a106 clone) already carries `CUST_EINT_TOUCH_PANEL_NUM 2` (unchanged);
    the a106-clone TYPE default (FALLING) belongs to that board's FT panel and is
    overridden by the driver's `TPD_EINT_FLOW`.
  - No I2C board edit needed: the driver self-registers `I2C_BOARD_INFO("gsl_tp", 0x40)`
    on bus 0 (the in-tree ft5336/gt9xx convention; same as D14's amp pattern).
- Invariants asserted by `build/60_kernel_delta_touch.sh`:
  - `CONFIG_TOUCHSCREEN_MTK_GSL_TP=y` present in q5_defconfig;
  - `cust_gpio_usage.h` still the a106 clone with GPIO2/GPIO14 CTP pins (above);
  - extracted fw hash == pinned extraction (`D17_FW_SHA`);
  - δ-parity: `gsl_tp/gsl1680/gsl915/gslX680/gsl_alg_id_main/gsl_config/GSLX680_FW`
    present in the blob AND the whole β-carry-over set intact (no regression).
- Not ported (documented absence): the blob's exported gesture symbols
  (`gsl_GestureBuffer/gsl_GestureExtern/gsl_obtain_gesture`) — no call sites exist for
  them in the blob's driver paths (checked over the full disassembly); the donor's
  non-gesture point-id unit provides everything the report path uses.

## M1b pipeline corrections made during D17 (recorded here as pipeline debt payoff)
1. **D13 patch defect repair (q5/sound/Makefile hunk)**: the committed D13 hunk replaced
   the *whole* Makefile with an empty file (`@@ -1,5 +0,0 @@`) instead of adding
   `aw87559_pa.o`.  It went unnoticed because `build-beta/` still carried the original
   session's `sound/built-in.o` (incremental reuse masks a missing object dir).  A fresh
   build dir hit `ld: cannot find arch/arm/mach-mt6582/q5/sound/built-in.o`.  Repair:
   the hunk now adds exactly the documented D13 line:
   `obj-y := yusu_android_speaker.o aw87559_pa.o` (order verified against the original
   session's `.built-in.o.cmd`).  Effect on m1b-β: **kernel Image bytes unchanged**
   (proven: pinned-β vs fresh-β Images differ only in the 20-byte GNU build-id note —
   the ld build-id hashes vmlinux metadata (symtab), not the shipped Image; string sets
   and layout byte-identical).  Consequence: a fresh-dir β build now yields
   zImage `9906e184b77bb57da44bdfe1ba2d401a883a09ae17b619925fd1e0f74f09861f`
   (Image `b61c5a783ded78666bf93e73969c35074b1a80cd5c61be2bb1c653ba5b722db7`,
   13,848,424 B), deterministic across repeated 50 runs; the m1b tag artifacts on disk
   (`out/boot-m1b-alpha.img` `d886ccfe…`, `out/boot-m1b-beta.img` `2c3ac47a…`) are
   untouched and remain the m1b reference bytes.
2. `build/50_kernel_delta.sh`: reset now also clears the D17 paths and whitelists the
   `build-beta-touch` O-dir; fresh-O-dir `mkdir -p` guards added (50 + 60) — the original
   scripts assumed pre-existing O dirs.

## D18 (display must-preserve — gc9503v WVGA LCM port)
- Invariants asserted (61_kernel_delta_lcm.sh):
  - `q5_defconfig` LCM line == `CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo_hsd gc9503v_wvga_dsi_vdo_boe"`,
    zero `hx8369b` references left, `CONFIG_LCM_HEIGHT="800"`/`CONFIG_LCM_WIDTH="480"` kept;
  - `mt65xx_lcm_list.c` carries both `gc9503v` externs + guarded list entries
    (guards = the `-DGC9503V_WVGA_DSI_VDO_{HSD,BOE}` defines that `Makefile.custom`
    derives from `CONFIG_CUSTOM_KERNEL_LCM`);
  - both `drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_{hsd,boe}/` dirs carry the
    driver + Makefile, driver `.name` == the LK-matched blob string;
  - both LCM `built-in.o` objects exist in the O dir after build;
  - δ-parity: the four gc9503v strings (both names + both compare_id printk formats)
    present in the blob; `hx8369b` = 0 hits; D17 and β-carry-over sets intact.
- Data provenance: 170 command-table rows round-trip-verified byte-exact against the
  pinned Lithium decomp (`donors/lithium-kernel.decomp`); the wiring deviation from the
  task's literal `CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo"` string is documented
  in the D18.patch prologue (blob/LK name contract — an unsuffixed name cannot match
  what the Q5's LK passes and would re-create the dark screen it fixes).
