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

## D19 (display-path guards — the M4 verdict-flash hardening)
- `patches/kernel/D19.patch` (supersedes the M3-era `D19-dsi-timeout.patch` draft,
  which is removed; its scope is contained here *and extended* to the mtkfb probe
  guard + error-returns that bob-m3 SS6.3 deferred).
- Two files:
  1. `drivers/misc/mediatek/video/mt6582/mtkfb.c` — `mtkfb_probe()` bails with
     `-ENODEV` via `cleanup` when the global `lcm_drv` is still NULL after the
     cmdline parse + `DISP_DetectDevice()` autodetect; the marker
     `[mtkfb] D19: no LCM driver found after cmdline parse + autodetect` names the
     miss verbatim (plain printk, not debug-gated). `mtkfb_free_resources(NULL, 0)`
     is a no-op, so the early exit is safe.
  2. `drivers/misc/mediatek/video/mt6582/dsi_drv.c` — `_WaitForEngineNotBusy()`'s
     2 s-timeout arm now `break`s after one Dump+Reset (was: infinite re-arm), and
     the four timeout-free engine polls in `DSI_Detect_CLK_Glitch_Default()` get
     the sibling 100 ms `get_current_time_us()` budget: the pre-BackUpCmdQ BUSY
     poll arm does Reset+status-clear+`return 1`, the post-BackUpCmdQ polls jump
     to a shared `fail_exit` tail that replays the success tail's restore
     statements (status clear, INTEN re-enable, RestoreCmdQ, SetMode) before
     `return 1`. Return 1 = the function's fail/glitch signal — callers (446,
     1565) unlock and either fire DISP_DSI_CMD_DONE_INT (frame retry) or fall
     through with force_transfer on the reset engine.
- Known residuals deliberately NOT bounded (listed in the patch prologue with VA/
  line refs): dsi_drv.c:1649 (bit18), :1819/:1901 (Parallel variant), :4043
  (`DSI_dcs_read_lcm_reg_v2` RACK do-while — on the live autodetect read path),
  :4120, :3899, :323 (dead). Extend only on Bob's sign-off.
- Invariants asserted (62_kernel_delta_board.sh): miss-marker + `-ENODEV` + extern
  greps on mtkfb.c; exactly 4 `(D19: 100ms budget)` strings + `fail_exit:` on
  dsi_drv.c; the shipped Image carries the marker (1) and the budget strings (3 —
  the two identical CMD_DONE strings merge). Zero new compiler warnings vs the
  β-touch-lcm build log (937 == 937, identical warning-file sets).

## D20 (Q5 board-value port + DCT include-precedence — "the include-order is the fix")
- **Mechanism:** DCT headers are regenerated by DrvGen (`codegen.dws` → O dir) at
  every build and the O-dir `inc` was the ONLY resolvable `/inc` dir — editing the
  source headers alone is a silent no-op. D20 adds
  `-I$(MTK_PROJECT_PATH_ROOT)/dct/dct/inc` BEFORE `-I$(DRVGEN_OUT)/inc` in
  `drivers/misc/mediatek/Makefile.custom` (consumed by both the mediatek driver
  tree and `arch/arm/mach-mt6582`, whose Makefile includes Makefile.custom) and
  pins the Q5 values in the SOURCE headers. Only 3 headers are overridden
  (`cust_eint.h`, `cust_gpio_usage.h`, `cust_kpd.h`); all others stay on the
  DrvGen path byte-identical to a106 (asserted by 62 with `cmp`).
- **Ported values** (each re-decoded from the pinned blob this session; full VA
  trail in `.specs/forge-m4-report.md`):
  - `cust_eint.h`: `CUST_EINT_MSDC1_INS_NUM` 8→3, `_DEBOUNCE_CN` 1→0
    (blob ch3 @c04f0258/d8/fc; the fork's msdc1_hw IS the SD+CD variant — no
    `CONFIG_MTK_WCN_CMB_SDIO_SLOT` in q5_defconfig — so the fork registered CD on
    EINT8 = GPIO8 = the Q5's speaker pad before D20); `CUST_EINT_ACCDET_NUM` 0→4
    (blob ch4 @c04a1f00/f94/f8c).
  - `cust_gpio_usage.h`: `GPIO_ACCDET_EINT_PIN` GPIO0→GPIO4 (probe triple
    @c04a355c-78 = accdet.c's own calls); `GPIO_CAMERA_CMRST1_PIN` GPIO3→GPIO16 +
    `GPIO_CAMERA_CMPDN1_PIN` GPIO4→GPIO18 (blob pinSet rows @0xc083c170+0x20/30 —
    the sub-camera collides with the Q5's card-detect/headset pads otherwise);
    `GPIO_SPEAKER_EN_PIN` GPIO6→GPIO8 (blob Speaker_Init
    gated on `is_aw87559_exit()` — no compiled consumer here, hygiene); NEW
    `GPIO_MSDC1_EINT_PIN` = GPIO3 + the vendor's mode0/dir-in/out-low pad-repin
    ported into `msdc_enable_cd_irq` (sd.c), so the registered channel watches
    the real card line like the vendor build.
  - `cust_kpd.h`: keymap `[1]=VOLUP,[2]=VOLDOWN` → `[0]=VOLDOWN,[1]=VOLUMEUP`
    (blob compiled kpd_keymap @0xc08d0e34; the matrix wiring differs by one —
    "expected match" did NOT hold). `KPD_DL_KEY*`/recovery macros (LK-side, no
    kernel consumer) and the LPRST flag block (blob compiles it out) left
    untouched.
  - `cust_leds.c`: red/green/button PMIC ISINK → `NONE, -1` (blob array
    @0xc0b5fb7c = NONE for all six); `lcd-backlight` BLS entry byte-identical.
- **Re-pinned D15/D16 invariants** (62): `keypad/mtk_kpd.h` stays an a106 clone;
  the overridden headers are asserted against the Q5-pinned constants; the
  non-overridden DCT files (`cust_gpio_boot.h`, `cust_adc.h`, `cust_power.h`,
  `cust_eint_md1.h`, `pmic_drv.h`) must stay byte-identical a106 clones.
- **Precedence gate (62, post-build):** `hal_kpd.o` data carries {114,115} (not
  {0,115,114}); `kd_camera_hw.o` pinSet[1] row = {GPIO16|F,0,1,0,GPIO18|F,0,1,0}
  (not the a106 3/4 row) matched word-aligned so misaligned byte runs can't
  false-pass; `sd.o` sites clean of r0=8 with the Q5 r0=3 + debounce r1=0 form
  (compiled msdc_enable_cd_irq = GPIO3 triple → debounce(3,0) → reg(3,...)); 
  `accdet.o` registration r0=4 + `mov r0,#0x80000004`, a106 `0x80000000` gone.
- **No-port, proven-match (asserted, not edited):** PMIC cust empty stub
  (`pmu_drv_tool_customization_init` body == `{}` — blob @0xc004aad8 = 5-insn
  empty); PMIC EINT 25/HIGH/deb1 (blob @c0510e2c ≡ a106 header); ACCDET debounce
  256 + TRIGGER_LOW; touch EINT ch2; main-camera GPIO9/GPIO10; kpd debounce 1024
  (@c04a4990); RTC `GPIO_SRCLKEN_PIN GPIO37` (mtk_rtc_hal.c:61 ≡ blob @c0493880);
  vibrator cust {50, 9, 0x5} (@0xc0b5fb70 ≡ a106); OTG IDDIG GPIO17 both (blob
  mt_usb_otg_init @c0545b34-68; VBUS is charger-IC OTG boost in the vendor — no
  GPIO — so the fork's GPIO93 entry stays, documented).
- Pipeline: `62_kernel_delta_board.sh` (new), `55_repack_boot.sh` tag
  `beta-touch-lcm-board`, additive whitelist/mtime-pin hygiene in 50/60/61. No
  defconfig changes. Image: `out/boot-m1b-beta-touch-lcm-board.img`
  sha256 `2ecb317e9ba0dc903c28219c970f42197fd59a11300c13909949fa76b7bf608f`
  (idempotent across re-runs; header fields byte-equal the donor except `ksz`).

## D21 (Q5 MBR constant port + dumchar_probe init_pmt() guard — the F1 boot-panic fix)
- `patches/kernel/D21.patch` — three touchpoints:
  - `arch/arm/mach-mt6582/q5/partition/cust_part_mbr.c`: the LIVE
    `MBR_START_ADDRESS_BYTE` global `12288*1024` (0xC00000, the a106/Unite-2
    value, carried in by the board clone) → **`(0x1400000)`** = the Q5's real
    MBR linear address. Blob trail: Lithium `init_pmt` @c050faa8 picks
    PartInfo["mbr"], `ldrd r8,[r9,#16]` @c050fe94-9c, then `ldrd r2,[ip]` with
    `ip = c0b5fc80` @c050fdfc-08 and `cmp r9,r3 / cmpeq r8,r2 / bne c050ff4c`
    @c050fe0c-14 — the preset is the u64 global at **c0b5fc80 =
    0x0000000001400000** (read from the pinned decomp d284ba16… base 0xc0008000;
    cross-proved via lithium.elf .kernel c0008000@0x124). Scatter cross-check
    (`.hermes/q5-recovery/spft/live-geometry/MT6582_live_scatter.txt`, project
    j5052): MBR `linear_start_addr: 0x1400000` in EMMC_USER, PRELOADER
    0x0–0x1400000 in EMMC_BOOT_1. The mismatch on the fork meant pmt.c:610
    failed on EVERY boot → `mbr_invalid:` (pmt.c:628) freed every
    `PartInfo[i].name` to NULL **without resetting `PART_NUM`** → dumchar_probe
    walked `PART_NUM>0` NULL names → the F1 last_kmsg NULL-deref in
    `dumchar_probe` (c04dd1e4).
  - `drivers/misc/mediatek/dum-char/mt6582/dumchar.c` (`dumchar_probe`, at the
    old `init_pmt();` — dumchar.c:908): capture the return:
    `result = init_pmt(); if (result) { printk(KERN_ERR "[Dumchar]D21: …");
    return -ENODEV; }` — loud marker + clean fail BEFORE the PART_NUM loop can
    deref the NULL names. A plain early return (not the goto ladder) because
    nothing has been acquired in the probe yet (kzalloc/alloc_chrdev_region
    all come after). Any future PMT failure is diagnosable, not fatal.
  - `drivers/misc/mediatek/mmc-host/mt6582/sd.c` (the FPGA_PLATFORM dead
    sample block): **re-decode correction to the task row** — the
    `#define MBR_START_ADDRESS_BYTE (0x660000)` at sd.c:231 is inside a
    comment block (`/* … */`, sd.c:230/231) and never compiles; the vendor's
    own sd.c consumes the cust_part_mbr.c global too (msdc_get_offset
    @c04fa754: `rsb r0, r0, r3` with `r3 = ldr [c0b5fc80]` — no local define
    exists in the vendor build). D21 keeps the sample table inert, adds the
    DEAD-text note and updates the sample value 0x660000 → 0x1400000 so a
    future de-comment cannot resurrect the stale constant.
- **Asserts (62, extended to O dir `build-beta-touch-lcm-board2`):**
  - source: q5 global = `(0x1400000)`; a106 origin pristine
    (`12288 * 1024` there = no cross-board leak); sd.c carries the note +
    `#define … (0x1400000)` and NO `0x660000`; dumchar.c has
    `result = init_pmt();` + the D21 marker + `return -ENODEV;` and NO bare
    `    init_pmt();` call.
  - compiled: `cust_part_mbr.o` .data carries the `0x1400000` u64
    (word-aligned search; a106 `0xC00000` form absent anywhere);
    `dumchar.o` .rodata carries `D21: init_pmt() failed`; `pmt.o` keeps the
    vendor `MBR offset invald` preset-check string. Shipped Image carries the
    marker + the `[Dumchar]MBR address` format string (boot log will print
    `1400000`).
- Pipeline: 62 builds the NEW O dir `build-beta-touch-lcm-board2` (the pinned
  M4 `beta-touch-lcm-board` artifacts stay reproducible from the pre-D21
  history); `55_repack_boot.sh` tag `beta-touch-lcm-board2`; additive
  O-dir whitelist hygiene in 50/60/61. No defconfig changes.
