# Forge — M4 report: D19 display guards + D20 board-value port (the α reset-loop fix)

**Task:** `.specs/forge-m4-task.md` · **Design:** `.specs/bob-m4-board-port.md`
**Method:** every §3.2/§2 blob anchor re-decoded this session from the pinned Lithium
kernel (`kernel.img` 5217dd41…, decomp d284ba16… at `~/.hermes/cache/scratch/opencode/bob-m2/`,
symbol ELF + kallsyms at `forge-d17/lithium.{elf,syms}`, in-tree `arm-eabi-4.8` objdump, base
`0xc0008000`). Nothing copied blindly; three spec-row values were **corrected** by the re-decode
(MSDC1 EINT channel, ACCDET's eint-func GPIO, sub-camera pins) — flagged inline and in §4.
**Status: all deliverables landed and verified.**

---

## 1. D19 — display-path guards (`patches/kernel/D19.patch`)

Verified by apply + real build + shipped-Image string checks. The M3 draft
(`D19-dsi-timeout.patch`) is superseded and removed; D19.patch additionally carries what M3
deferred (probe guard + error-returns per the M4 wording).

**1a. `mtkfb.c` `mtkfb_probe()` (the panic-class fix).** After the
`mtkfb_find_lcm_driver()`/`DISP_DetectDevice()` block (mtkfb.c:2808-2822), on total miss
(`lcm_drv == NULL` — the global of `disp_drv.c:54`, exactly the miss path M4 §1.2 class 1
convicted): plain `printk(KERN_ERR "[mtkfb] D19: no LCM driver found after cmdline parse +
autodetect …")` naming the cmdline lcm name verbatim, `r = -ENODEV`, `init_state = 0`,
`goto cleanup`. `mtkfb_free_resources(fbdev=NULL, 0)` is a no-op (its `case 0`), so the early
exit is safe; on the healthy (D18 name-matched) path the branch is not taken. The
`extern LCM_DRIVER *lcm_drv;` is declared in the guard's scope (same idiom as
`disp_drv_dsi.c:24`). Shipped-Image evidence: the marker string survives (1 hit).

**1b. `dsi_drv.c` — five bounded waits.**
- `_WaitForEngineNotBusy()` (process-context arm, ~576): the `0 == ret` arm now **`break`s**
  after one `DSI_DumpRegisters(); DSI_Reset();` instead of re-arming
  `wait_event_interruptible_timeout(WAIT_TIMEOUT)` forever (bob-m3 SS1/SS4's live-path infinite
  wait inside `mtkfb_probe`).
- `DSI_Detect_CLK_Glitch_Default()`: the enumerated polls — `while(BUSY)` (~1606), the two
  `while(CMD_DONE == 0)` (~1619/1629), and `while(STATE_DBG0 & 0x1) == 0` (~1639 bit0) — bounded
  with the sibling 100 ms `get_current_time_us()` budget (same idiom as DSI_WaitForTE/DSI_WaitBtaTE
  at 1387/1419), logging `(D19: 100ms budget)` and **returning an error on expiry**:
  - the BUSY poll sits *before* `DSI_BackUpCmdQ()`, so its arm does `DSI_Reset(); OUTREG32(INTSTA,0);
    return 1;` (nothing acquired yet — running the restore tail over an unbacked-up queue would be
    worse);
  - the other three sit *after* `BackUpCmdQ + INTEN{RD_RDY,CMD_DONE}=0`, so their arm jumps to a
    shared `fail_exit` tail that replays the success tail's restore statements (status clear,
    interrupt enables back on, `DSI_RestoreCmdQ()`, `DSI_SetMode(lcm_params->dsi.mode)`) and returns 1 —
    the engine/queue/mode stays consistent for the next transfer;
  - `return 1` = the function's fail/glitch signal: both callers (`dsi_drv.c:446`, `:1565`)
    release the lock and either fire `DISP_DSI_CMD_DONE_INT` (frame retry) or fall through with
    `force_transfer` onto the reset engine. `glitch_detect_fail_cnt` is untouched (that counter
    belongs to the `try_times` arm).
- **Not bounded** (residual list carried in the D19 prologue with refs, per "do not shotgun"):
  `:1649` (bit18, same loop), `:1819/:1901` (Parallel variant), `:4043` (`DSI_dcs_read_lcm_reg_v2`
  RACK do-while — on the live name-miss autodetect read path), `:4120`, `:3899`, `:323` (`#if 0`,
  dead). Extension needs Bob's sign-off.
- Build evidence: exactly 4 `(D19: 100ms budget)` strings in dsi_drv.c, 3 in the shipped Image
  (gcc merges the two identical CMD_DONE texts); **zero new compiler warnings** vs the
  β-touch-lcm build (937 == 937, identical warning-file sets).

## 2. D20 — Q5 board-value port (`patches/kernel/D20.patch`)

**2a. The mechanism (§3.2's "single most important fact"), verified live.** `scripts/drvgen/drvgen.mk`
generates `cust_kpd.h/cust_eint.h/cust_gpio_boot.h/cust_gpio_usage.h/cust_adc.h/cust_power.h/
pmic_drv.h/pmic_drv.c/cust_eint_md1.h` into `$(DRVGEN_OUT)/inc` at every build (`archprepare`),
and pre-D20 that O-dir was the ONLY resolvable `/inc` dir (verified on the pinned build's
`.pmic_drv.o.cmd/.sd.o.cmd/.accdet.o.cmd/.hal_kpd.o.cmd`; the srctree `-I …/q5/dct/dct` line does
not resolve these headers). D20 adds `-I$(MTK_PROJECT_PATH_ROOT)/dct/dct/inc` **before**
`-I$(DRVGEN_OUT)/inc` in `drivers/misc/mediatek/Makefile.custom` (consumed by both the mediatek
driver tree and `arch/arm/mach-mt6582`, whose Makefile includes Makefile.custom) and pins the Q5
values in the source headers. `mach/mt_gpio_base.h` provides the `GPIO16/18` enumerations used by
the re-based pins.

**2b. Decoded values — every anchor re-verified this session** (`mt_eint_registration` =
`mt_eint_registration(num, flag, handler, auto_umask)`; flags: RISING=1, FALLING=2, HIGH=4, LOW=8;
`0x8000000N` = `GPIO N | 0x80000000`; MT6582 EINT channel == GPIO pad index, proven by the blob's
own set_polarity/debounce channels matching its programmed pads):

| # | Item | a106/fork before | Blob truth (VA) | Port |
|---|---|---|---|---|
| 1 | MSDC1 card-detect | EINT ch **8** = GPIO8 pad, deb 1, LOW; fork msdc1_hw IS the SD+CD variant (no `CONFIG_MTK_WCN_CMB_SDIO_SLOT` in q5_defconfig → board.c `#else` branch: `CD_PIN_EN\|REMOVABLE`, `MSDC_SD`, cd_level `MSDC_CD_LOW`) ⇒ the fork registered EINT8 **today** — watching GPIO8, the Q5's **speaker** pad (false CD events) | `mt_eint_mask(3)` @c04f0258; `mt_eint_set_hw_debounce(3,0)` @c04f02d8; `mt_eint_registration(3, LOW(8)↔HIGH(4) by sd_cd_polarity, msdc1_eint_handler @c04f0344, auto=1)` @c04f02fc; pad triple GPIO3 `0x80000003` mode0/dir0/out0 @c04f0268-84 | `cust_eint.h`: ch **3**, deb **0**; NEW `GPIO_MSDC1_EINT_PIN` GPIO3 + the pad triple ported into `sd.c msdc_enable_cd_irq` (gated on the same CD-wired condition; fork's polarity logic byte-matches the vendor's) |
| 2 | ACCDET | ch 0 = GPIO0 pad, deb 256, LOW | probe triple @c04a355c-78 mode0/dir-in/pull-disable on `0x80000004` — **the identical calls** as fork accdet.c:487-489; `debounce(4,256)` @c04a357c ≡ a106's CN; `registration(4, LOW(8)=TYPE, accdet_eint_func @c04a1eb4, auto=0)` @c04a358c | `cust_eint.h`: ch **4**; `cust_gpio_usage.h`: `GPIO_ACCDET_EINT_PIN` GPIO**4**. Debounce/TYPE unchanged (proven match) |
| 3 | OTG | IDDIG GPIO17; DRVVBUS GPIO93 | `mt_usb_otg_init` @c0545b34-68: mode0/dir-in/pull-disable+pull-select(1) on GPIO17 `0x80000011`, `eint_set_sens(17,1)`, `debounce(17,64)`, `registration(17, LOW, …, 0)` — chip/USB values, **IDDIG ≡ a106**. VBUS: `mt_usb_set_vbus` @c0544524 = charger-IC OTG boost (`bct24157_set_otg_en` @c052cf40 / `fan5405_set_otg_en` @c052b7bc) — **no GPIO in the vendor path**; the spec's `0xc0daf358` anchor is .bss state vars (e.g. the aw87559 flag @c0daf460 read by `is_aw87559_exit` @c056f2bc), not a pin pool | **No port** (§4 note) |
| 4 | Leds | red/green/button = PMIC ISINK1/0/2 | `get_cust_led_list` array @0xc0b5fb7c (32 B entries): red/green/blue/jogball/keyboard/button all `MODE_NONE, -1`, PWM zeros; `lcd-backlight` mode5(CUST_BLS_PWM)+`disp_bls_set_backlight` @c03a743c ✓; `Cust_GetBacklightLevelSupport_byPWM` returns **256** @c004e2e8 ≡ fork | `cust_leds.c`: red/green/button → `MT65XX_LED_MODE_NONE, -1`; `lcd-backlight` entry byte-identical |
| 5 | Keypad | `[1]=VOLUP, [2]=VOLDOWN`, deb 1024, `MTK_PMIC_PWR_KEY 8` | blob compiled `kpd_keymap` @0xc08d0e34 (72 u16, copied byte-exact by `kpd_init_keymap` @c04a4fa8): **{[0]=114 VOLUMEDOWN, [1]=115 VOLUMEUP, 0…}** — matrix wiring differs by one; `kpd_set_debounce(1024)` @c04a4990 ≡; PMIC pwrkey is chip-level (`kpd_pwrkey_pmic_handler` @c04a4af4 present) | **Ported** ("expected match" did not hold): `cust_kpd.h` `KPD_INIT_KEYMAP()` → `[0]=VOLUMEDOWN, [1]=VOLUMEUP`. `KPD_DL_KEY*`/recovery macros (LK-side, no kernel consumer) and the LPRST block (blob compiles `upmu_set_rg_*` OUT — verified: blob's `long_press_reboot_function_setting` @c04a4ecc has zero PMIC-register calls) left untouched |
| 6 | RTC BBPU / vibrator | `GPIO_SRCLKEN_PIN GPIO37` (mtk_rtc_hal.c:61); vibrator cust {50, 9, 0x5} | `hal_rtc_bbpu_pwdn` pwrdn triple @c0493880-88 on `0x80000025` = **GPIO37 ≡ fork**; vibrator struct @0xc0b5fb70 = `{0x32, 0x9, 0x5}` **byte-≡ fork** | **No port**; both become assertions |
| 6b | Speaker (re-decode correction) | `GPIO_SPEAKER_EN_PIN GPIO6`, no compiled consumer (AMP blocks empty) | `Speaker_Init` @c004e454-70: GPIO8 `0x80000008` mode0/dir-out/out(0) **gated on `is_aw87559_exit()`** — on amp-fitted units (the fork's D13/D14 i2c path) the vendor keeps GPIO8 inert | `cust_gpio_usage.h`: GPIO6→**GPIO8** (hygiene; no compiled consumer change) |
| 7 | Camera (assertion re-check → **1 divergence found**) | main CMRST/CMPDN GPIO9/GPIO10 ✓; sub CMRST1/CMPDN1 **GPIO3/GPIO4** (a106 lineage, D11 kept GPIO values per D16) | `kdCISModulePowerOn` @c004deac copies its pin table from 0xc083c170: pinSet[0]={**GPIO9**,0,1,0,**GPIO10**,0,1,0} ✓ ≡ fork; pinSet[1]={**GPIO16**,0,1,0,**GPIO18**,0,1,0} — the blob's sub-camera sits on GPIO16/18, NOT the a106 GPIO3/4, which are exactly the Q5's card-detect/ACCRET pads (two drivers fighting over one line once #1/#2 land) | **Ported** (scope extension vs the design's "verify-only" wording — flagged in §4): `cust_gpio_usage.h` CMRST1 GPIO3→GPIO16, CMPDN1 GPIO4→GPIO18. Mux labels stay in a106 DWS vocabulary; only `_M_GPIO` (mode 0) is consumed, exactly as the blob's driver does |

**2c. What D20 does NOT touch** (per design): `cust_gpio_boot.h` (inert — only charger/misc_via
consumers, all unbuilt), PMIC cust (`pmu_drv_tool_customization_init` body `== {}` in
pmic_drv.c ≡ blob's 5-insn empty @0xc004aad8 — asserted by source-compare), PMIC EINT
(25/HIGH/deb1 ≡ blob @c0510e2c), TE/LANE/LCM-reset (D18 + register-only evidence), clocks/PLL
(no board table), partitions/touch/LCM (D18/D17). No defconfig changes exist to make.

## 3. Pipeline changes

- **`build/62_kernel_delta_board.sh`** (new): clone of 61's shape applying D1…D18 + **D19 + D20**
  into fresh O dir `build-beta-touch-lcm-board`; reset-list + O-dir whitelist extended; tracked-file
  WANTED-set extended (mtkfb.c, dsi_drv.c, Makefile.custom, sd.c); mtime pinning extended with the
  D19/D20 files.
  - **Re-pinned D15/D16 invariants**: `keypad/mtk_kpd.h` stays an a106 `cmp` clone; the three
    overridden DCT headers are asserted against their **Q5-pinned contents** (every changed constant
    present, every a106 form absent); the non-overridden DCT files (`cust_gpio_boot.h`,
    `cust_adc.h`, `cust_power.h`, `cust_eint_md1.h`, `pmic_drv.h`) must remain byte-identical a106
    clones (DrvGen keeps owning them); D17's touch-pin checks re-expressed as greps (byte-parity on
    cust_gpio_usage.h no longer holds post-D20).
  - **Proven-match parity asserts**: pmic-cust empty stub; PMIC 25/HIGH; ACCDET 256/LOW; touch ch2;
    main-camera GPIO9/10; kpd debounce 1024 + `MTK_PMIC_PWR_KEY 8`; `GPIO_SRCLKEN_PIN GPIO37`;
    vibrator cust `cmp`-clone; `disp_bls_set_backlight` string present in Image; D18-table-pinned
    fork-side string counts stay put (`mt6323=19`, `auxadc=210`); the β-carry-over MUST/MUST-NOT
    sets from 61 (gsl/ccci/cameras/lens/amp strings; `bct24157`/`MAX17050SW6106`/
    `fan5405_config_interface`/`hx8369b` = 0).
  - **Precedence-took-effect gate** (post-build, the §3.3-1 detector): byte/immediate checks on the
    compiled objects — `hal_kpd.o` data `{114,115}` and NOT `{0,115,114}`;
    `kd_camera_hw.o` pinSet[1] row `{0x80000010,0,1,0,0x80000012,0,1,0}` word-aligned (and not the
    a106 3/4 form) — matching rows word-aligned so this toolchain's coincidental misaligned
    `03 00 00 80` byte-run elsewhere in the object cannot false-pass; `sd.o` msdc_enable_cd_irq site
    checks (no site carries the a106 r0=8; Q5 r0=3 present; debounce arg r1=0) — the compiled
    function is a near-exact replica of the vendor's flow (GPIO3 triple → `debounce(3,0)` →
    `registration(3, LOW|HIGH, handler, auto=1)`); `accdet.o` `registration` r0=4 +
    `mov r0,#0x80000004` with a106's encodable `r0=#0x80000000` gone.
- **`build/55_repack_boot.sh`**: tag `beta-touch-lcm-board` added (usage strings + zImage path +
  die message; repack/verify machinery byte-for-byte the pre-M4 behavior).
- **Additive hygiene in 50/60/61**: O-dir whitelist adds `beta-touch-lcm-board`; the D19/D20-touched
  tracked files join the mtime-pin lists (keeps the older stages' persistent O-dir re-runs
  byte-flat). Nothing else changed — the D15/D16 `cmp` asserts in 50/60/61 remain valid there
  because D20 only applies in 62 (documented decision: the re-pin is semantic only where the
  patch lands).
- No defconfig changes (nothing to toggle — §1.2-5 of the design).

## 4. Deviations / escalations for Bob (implementation-level, no architecture change)

1. **MSDC1 EINT channel = 3, not "8→3 with trigger decode pending"**: the blob's registration is
   `ch=3, LOW(8)↔HIGH(4) by sd_cd_polarity, auto=1` — the LOW/HIGH pair matches the fork's existing
   msdc1_eint_handler polarity-swap logic byte-for-byte, so only channel + debounce ported. The fork
   ALSO needed the vendor's GPIO3 pad-repin (ported into `sd.c`) to make the channel watch the real
   card line — the vendor programs it in the same function under a CD-wired flag (fork gate:
   `MSDC_CD_PIN_EN`, which the fork's compiled msdc1_hw carries).
2. **ACCRET eint-func GPIO**: the blob's `accdet_eint_func` additionally toggles **GPIO7**
   (`0x80000007`, the auxadc/headset-switch pad) — the fork's accdet.c has that code compiled out
   (`GPIO_FSA8049_PIN` undefined; init hook `#ifdef`'d; the fork's eint-func re-arms
   polarity/debounce but has no GPIO toggle). NOT ported (a one-shot init toggle without the
   runtime toggle pair would be a half-feature); on-device acceptance item §5 of the design
   (audio-jack events) will tell whether a follow-up D-id should wire the vendor's toggle pair.
3. **Sub-camera pins ported** (GPIO3/4 → GPIO16/18): the design's row 7 was "verify-only", but the
   re-check proved the fork's front camera drives exactly the pads D20 re-assigns to
   card-detect/headset — a genuine collision that items 1–2 would hard-wire. Blob-evidenced, same
   D20 files; Bob may veto with a 2-line revert.
4. **Speaker/leds "a106" expectations corrected by decode**: speaker = GPIO8 (not GPIO6-class),
   gated on `is_aw87559_exit()`; leds = all six NONE (red/green/button ported).
5. **KPD keymap ported** (the design's "expected match" bet lost): matrix wiring shifts the
   VOLUME pair by one. Recovery/DL key macros untouched (LK-side contracts, no kernel consumer);
   LPRST divergence documented-not-ported (`KPD_PMIC_LPRST_TD` compiled in the fork, absent in the
   blob — affects PMIC-level long-press-reset semantics; deferred to Bob).
6. **D19's `fail_exit` restore tail and the per-poll split** (BUSY arm vs post-Backup polls) are
   my implementation of "log + return error on expiry" — chosen so expiry can never leave the
   command queue backed up with interrupts disabled.

## 5. S0 gates — results

- `bash build/62_kernel_delta_board.sh` **PASS** (full log `/tmp/forge-m4-62.log` +
  `/tmp/forge-m4-62-rerun.log`): donors-pins ✓, reset-audit ✓, D1…D20 patches applied ✓, tracked-file
  WANTED-set ✓, all D2/D3/D5/D6/D7/D15/D16/D17/D18/D19/D20 invariants ✓, defconfig→`.config` LCM line ✓,
  both gc9503v `built-in.o`s ✓, banner `Linux version 3.10.54 (forge@fork) …` ✓, δ-parity PASS
  (`out/kernel-parity-beta-touch-lcm-board.txt`), **DCT-precedence gate PASS** ("precedence gate: OK
  (hal_kpd keymap bytes, kd_camera_hw pin words, sd.o ch3/deb0, accdet.o ch4/GPIO4)") — DrvGen did
  **not** shadow the D20 headers; the O-dir-overwrite fallback was never needed.
- **Idempotency**: second 62 run → identical zImage `85ea587e15e6ea832e6a16aabeeb5a35dbc0e2a310c1d1c690a9f43db2a10c2a`
  and identical final image sha; zImage 4,264,312 B.
- `bash build/55_repack_boot.sh beta-touch-lcm-board` **PASS**: `verify OK: headers byte-identical
  except ksz (3809720 (donor) vs 4264824); ramdisk byte-identical (1394157 B, sha c0be6c46333b…)` —
  independent re-check in python: header fields ≠ donor only in `ksz`; board name + cmdline
  byte-equal; ramdisk region byte-verbatim; kernel region = 512 B MTK `KERNEL` header + zImage with
  matching length field (the dual-header/ramdisk-verbatim anatomy, E4).
- Zero new compiler warnings vs β-touch-lcm (937 == 937, identical warning-file sets).

**Final artifact: `out/boot-m1b-beta-touch-lcm-board.img` — 5,662,720 B —
sha256 `2ecb317e9ba0dc903c28219c970f42197fd59a11300c13909949fa76b7bf608f`**
(sidecar `out/boot-m1b-beta-touch-lcm-board.img.sha256` identical). Flashable per the design's
F1 (≥ 30 s observation; expected dmesg set includes the D18 LCM markers and — on a dark-but-alive
outcome — the D19 marker naming the miss).

## 6. Bookkeeping

- Committed: `patches/kernel/D19.patch` (new; the M3-era `D19-dsi-timeout.patch` draft removed —
  superseded), `patches/kernel/D20.patch` (new), `patches/kernel/DELTA-NOTES.md` (D19/D20 sections),
  `build/62_kernel_delta_board.sh` (new), `build/55_repack_boot.sh` (tag), additive hygiene in
  `50/60/61`. `out/` artifacts remain gitignored per convention.

**Implementation complete.**
