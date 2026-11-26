# Bob — M4: board-config port design (fix the α reset-loop panic)

**Task:** `.specs/bob-m4-task.md` · **Supersedes M3's flash ladder** (T0/T1 answered: pipeline healthy
per the earlier static proofs, the fork kernel and α both panic ⇒ tree/board-config convicted — no
further isolation flashes needed before acting).
**Method:** full initcall-window audit of the heyrudra MT6582 tree (source-level, in-tree line refs
throughout) + targeted re-decodes on the pinned Lithium blob (`kernel blob 5217dd41…`, decomp
`d284ba16…` at `~/.hermes/cache/scratch/opencode/bob-m1/lithium/kernel.decomp`; symbol-aware ELF +
48,392 kallsyms at `~/.hermes/cache/scratch/opencode/forge-d17/lithium.{elf,syms,full.asm}`, base
`0xc0008000`) using the D17/D18 toolchain (in-tree `arm-eabi-4.8` objdump on `lithium.elf`).
**All blob numbers below are decoded from the pinned blob in this session; nothing guessed.**

---

## 0. TL;DR — the design in one screen

1. **The panic window is bigger than M3 assumed.** `mtkfb`'s platform *device* is registered in
   `mt_board_init()` (`mt_devs.c:1809`) which runs at **`late_initcall` via `board_init`
   (`board.c:47`)**, while the *driver* registers at `device_initcall` (`mtkfb.c:3541`). The probe
   therefore fires inside `board_init`, and **everything from `setup_arch` through
   `late_initcall(board_init)` precedes "logo clears"**: arch_initcall EINT/PM-pwr/CIRQ, fs_initcall
   PMIC6323-probe + USB-OTG pins, device_initcall driver regs, ccci_sync, and `board_init`'s own
   i2c/msdc/audio/disp/m4u/fb/leds registrations.
2. **Exactly one class in that window is (a) board-config-dependent, (b) proven divergent
   a106↔Q5, and (c) panic-capable: the display/LCM selection path.** The Q5 LK always passes
   `lcm=1-gc9503v_wvga_dsi_vdo_(hsd|boe)`; any build whose compiled `lcm_driver_list` misses those
   names (α/β/β-touch — hx8369b list) walks the miss path: `isLCMFound` pinned at cmdline parse,
   autodetect runs the unbounded DSI-read `compare_id` waits, and the probe then **continues with
   `lcm_drv == NULL`** into `DISP_Init` — a fatal combination in the pid-1 init thread (any oops
   there = panic regardless of `PANIC_ON_OOPS`; `CONFIG_PANIC_TIMEOUT=5` gives the observed ~5 s
   reset loop; logo persists because the framebuffer is never installed). D18 already repaired the
   *list* (both blob names compiled — byte-parity proven). What remains is **robustness + the
   verification/ports around it** (§3, D19/D20).
3. **Every other early-window board class is blob-proven MATCHING (not guessed):** PMIC custom
   init is an empty stub in the *vendor* kernel too; PMIC EINT channel = 25 in both; backlight =
   `CUST_BLS_PWM(5)` in both; LCM reset is an SoC register in both (no board GPIO); TE has no GPIO
   in this panel class (register-level flags only); LCD IO-pad init is a compiled no-op in this
   tree. These become **build-time assertions**, not edits.
4. **The DCT headers are NOT the compiled truth — `codegen.dws` is.** `archprepare` runs
   `tools/dct/DrvGen` (host ELF) on `q5/dct/dct/codegen.dws` and regenerates
   `cust_eint.h/cust_gpio_usage.h/cust_kpd.h/…` into the **O dir**, which shadows the source copies
   (`-I$(objtree)/…/dct/dct/inc`, srctree path listed without `/inc`). **Editing the `.h` files in
   place would be silently overwritten.** The port therefore uses an include-precedence override
   (§3.2-D20) — this is the single most important implementation fact of M4, and it invalidates the
   naive "just edit cust_eint.h" plan.
5. **Deliverables:** D19 = display-path guards (mtkfb cleans-fail on total LCM miss; bound the
   unbounded DSI read polls); D20 = the decoded Q5 board-value port (EINT map / GPIO usage / SD-CD /
   accdet / speaker / OTG / kpd / led-hygiene) + include-precedence mechanism + pipeline invariant
   re-pin; new stage `62_kernel_delta_board.sh` + repack tag `beta-touch-lcm-board`; staged re-test
   ladder with per-stage observables (§4).

---

## 1. Early-init class ranking (task Q1)

### 1.1 The panic window, precisely

Initcall order in this tree (verified by grep of every `*_initcall` in the compiled paths):

| Stage | Runs | Board-config input? |
|---|---|---|
| `setup_arch` | `mt_fixup` (ATAG/mem carve; `DISP_GetVRamSizeBoot` — guarded, returns 0x1400000 default on miss) | no (LK-driven) |
| core_initcall | boot_common, cputopo, rq_stats | no |
| postcore/arch_initcall | `mt_pwrap_init` (PMIC wrapper), `mssv_init`, **`mt_eint_init`** (EINT hw + MD1 map), `dram_overclock_init` (sysfs only), `mt_l2c_init`, `hw_watchpoint_init`, **`mt_power_management_init`** (SPM/slp/clkmgr-bringup/DCM/idle), `mt_mon`, `mt_reg_dump`, `chip_common`, `mt_cirq_init`, `fiq_smp_call`, `tz_client_init`, `init_wk_check_bit` | **`cust_eint_md1.h` (CNT=0 both)**, `cust_eint.h` PMIC ch. |
| subsys_initcall | `ccci_util_init`, `cmdq_init`, `mtkpasr_init` | no |
| fs_initcall | **`pmic_mt6323_init`** (device+driver registered → probe runs here; calls `pmu_drv_tool_customization_init`, sets PMIC EINT), `usb20_init` (OTG pin setup) | **`cust_pmic`/DCT pmic**, PMIC EINT ch., OTG pins |
| device_initcall | driver *registrations*: mtkfb, leds, kpd, rtc, xlog, wlan; probes only where a device already exists | leds/kpd table compile-time only |
| device_initcall_sync | `ccci_init` (modem) | no (Q5 modem-less payload, same as α) |
| late_initcall **`board_init`→`mt_board_init`** | registers uart, nand, gpio, fh, kpd-pdev, i2c×3 (→ instantiates static i2c clients ⇒ D17 gsl probe here), msdc, audio, disp, m4u, **`mt6575_device_fb` ⇒ `mtkfb_probe` runs**, leds-pdev ⇒ leds **probe after fb**, hdmi, spi (+`ptp_init`, `mt_clkmgr_late_init`, `mt_init_dma`, `battery_init`/`battery_meter_init` at same level, link-ordered after) | **everything** |

**⇒ The panic window = [kernel entry … `mtkfb_probe` completes], which structurally includes the
late_initcall `board_init` sequence up to the fb registration.** A panic/oops anywhere in this span
kills pid 1 (`kernel_init`) → `Panic` → 5 s reset-loop with the LK logo frozen. That matches the M4
on-device evidence.

### 1.2 Class ranking (earliest × panic-capability, with the a106-vs-Q5 evidence)

| # | Class | Executes in window | Could its wrong value PANIC (null/invalid access) vs hang? | a106-vs-Q5 evidence (decoded this session unless noted) | Verdict |
|---|---|---|---|---|---|
| **1** | **Display/LCM selection** (lcm list / name parse / autodetect / DISP_Init) | device_initcall(driver) + **probe at late_initcall board_init** | **YES, both modes**: miss ⇒ (a) autodetect `compare_id` runs `dsi_drv.c` unbounded `while(BUSY/CMD_DONE)` reads (hang), then (b) probe continues with `lcm_drv==NULL` into `DISP_Init` (invalid access → panic). Only class with all three: in-window, board-config-driven, **proven divergent** (α's hx8369b list can never match the Q5 LK's gc9503v cmdline name — certain for α/β/β-touch) | Divergent: LK passes `gc9503v_wvga_dsi_vdo_hsd|_boe` (D18, from `lk-q5.bin`); α list: `hx8369b*` only | **THE culprit class.** D18 fixed the list; D19 adds miss-robustness + bounds the waits (§3.1) |
| **2** | **PMIC rails / upmu** (`cust_pmic`, DCT `pmic_drv.c`, PMIC6323 probe) | fs_initcall probe | Theoretically the worst (bad rail programming ⇒ brown-out/crash) — why it got the deep blob check | **MATCH with proof**: vendor `pmu_drv_tool_customization_init` @`0xc004aad8` = prologue+`mcount`+return (**empty**, 5 insns) ≡ a106's empty body; PMIC EINT: vendor `PMIC_EINT_SETTING` @`0xc0510e2c` does `mt_eint_set_hw_debounce(25,1)` + `mt_eint_registration(25, TRIGGER_HIGH(4), …, 0)` + `unmask(25)` ≡ a106's `CUST_EINT_MT6323_PMIC_NUM 25` (both in `cust_eint.h` and hardcoded `pmic_mt6323.c:94`); same MT6323 chip | **Exonerated.** No port. Becomes build assertions (§3.3) |
| **3** | **EINT channel map** (`cust_eint.h`) | PMIC channel consumed at mt_eint_init/pmic probe (in window); the rest at per-driver probes (mostly post-fb) | No panic mechanism (register writes; wrong channel ⇒ lost/storm interrupts ⇒ at worst a stall **post-fb**) | MATCH for PMIC(25)/TOUCH(2, D17); **DIVERGENT**: MSDC1 card-detect — a106 `CUST_EINT_MSDC1_INS_NUM 8`, blob `msdc_enable_cd_irq` configures **GPIO3**; ACCDET — a106 ch.0/pin GPIO0 vs blob `accdet_eint_func` programs **GPIO4** (mode/dir/out) | Port divergent channels (functional + removes post-fb stall risks) |
| **4** | **DSI-LANE / TE pin modes** | inside mtkfb probe | TE misconfig ⇒ hang-class only (and only under mixmode); LANE count from lcm_params (D18, blob-exact) | Vendor TE: `DSI_TE_Enable`/`DSI_TE_EXT_Enable` @`0xc05917e8/0xc059182c` = flag bytes + DSI reg `0xF400C018 bit9` — **no GPIO anywhere in the vendor DSI path** (0 of 197 `mt_set_gpio_*` calls map to dsi/lcd functions); fork's `GPIO113` TE-EINT setup runs **only when `lcm_params->dsi.mixmode_enable`** (a GC9503V VDO panel ⇒ false). `LCD_Init_IO_pad`/`LCD_Set_DrivingCurrent` are compiled **no-ops** in this tree (`lcd_drv.c`) | **Closed.** No port; D19 bounds the waits that would have hung here |
| **5** | **Clocks / PLL** ("defconfig clock/PLL toggles") | arch (clkmgr-bringup) / late | SoC-level only | No board clock table exists in this kernel for MT6582: PLLs belong to LK; the kernel clkmgr does clock-*gating* with SoC tables; DVFS tables are SoC-fused. No `FREQHOPPING`/board PLL toggle in `q5_defconfig` (grepped). String-parity already shows subsystem equivalence (mt6323 19/19, ccci 750/750, auxadc 210/210 — D17/D18 parity) | **Nothing to port.** Documented; no defconfig clock change |
| **6** | **`cust_gpio_boot.h` boot pin modes/states** | **never executed in kernel** | n/a | Only 4 `#include` consumers exist: 3 charger drivers (**not built** by D1/D2/D3/D7) + `misc_via` for the VIA modem (**not built**: `CONFIG_EVDO_DT_VIA_SUPPORT` not set in `q5_defconfig`). Boot-time pin states are an **LK** responsibility on this platform | **Inert.** No port (recorded so nobody re-chases it) |
| **7** | **`cust_leds` backlight/PWM** | device_initcall(reg) + late probe **after** fb (mt_devs.c:1817 vs 1809) | No panic mechanism; wrong ⇒ dark backlight | **MATCH with proof**: blob `get_cust_led_list` @`0xc004e3ec` → 32 B entries @`0xc0b5fb7c`: `lcd-backlight` **mode=5 = `MT65XX_LED_MODE_CUST_BLS_PWM`** with a `disp_bls_set_backlight`-class callback pointer ≡ a106's `cust_leds.c` last entry; `Cust_GetBacklightLevelSupport_byPWM` returns **256** both. Divergent-but-harmless: vendor red/green/blue/jogball/keyboard/button = `MODE_NONE` (Q5 has no such LEDs) vs a106's PMIC ISINK1/0/2 | lcd-backlight: no change. Hygiene port: set the six non-LCD entries to NONE (stop driving unattached PMIC current sinks). Low priority |
| **8** | **Keypad matrix** (`cust_kpd.h`, `mtk_kpd.h`) | late probe (post-fb) | No panic mechanism | a106: 1-row×2-col matrix `[1]=VOLUP [2]=VOLDOWN` + PMIC pwrkey (`MTK_PMIC_PWR_KEY 8`); blob `kpd_pdrv_probe`/`kpd_keymap_handler` present (`0xc04a4820/…4354`); keymap decode = find `{KEY_VOLUMEUP=115, KEY_VOLUMEDOWN=114}` LE word pairs near kpd rodata xrefs (method in §2.4) — Q5 physically has exactly those three keys | Port only if decode diverges (likely match) |

### 1.3 Why the ranking orders the *fix*, not just the risk

Classes 2, 4, 5, 6, 7(lcd) are **closed with blob proof** — they cost zero flashes. Class 8, and the
functional divergences inside class 3 (MSDC-CD, ACCDET) plus speaker/OTG/camera pins, execute
**after** the panic point; they matter for a complete Android boot but cannot be the α panic. Only
class 1 can reset-loop the device before the logo clears — so the first re-flash is built around
class 1 (D19) with everything else riding along as proven-safe-or-post-window ports (D20).

---

## 2. Decode targets + method per class (task Q2)

**Shared tooling (already exists, reuse):** `lithium.elf` + `lithium.syms` (kallsyms-rebuilt;
`CONFIG_KALLSYMS_ALL=n` in the blob ⇒ text symbols only, data recovered via disassembly),
`lithium-full.asm` (whole-image objdump), pinned `kernel.decomp` (file offset = VA − `0xc0008000`),
in-tree `arm-eabi-4.8` objdump. Blob constants appear either as `movw`/`movt` immediate pairs
(`movt #32768 ; 0x8000` = the `0x80000000` GPIO flag) or as PC-relative literal-pool `ldr`s (resolve
by computing pool VA and reading 4 bytes from the decomp — the D17 workflow). Every value lands in
the tree only after the same tiling/bounds/self-check discipline D17/D18 used.

| Class | Decodable? | Method + expected shape | Blob anchors (this session) | Result |
|---|---|---|---|---|
| PMIC boot rails (`cust_pmic`/upmu DCT) | **Yes — done** | Disassemble the DCT hook the PMIC probe calls; empty = `push/mcount/pop` only (5 insns) | `pmu_drv_tool_customization_init` @`0xc004aad8` | **EMPTY ≡ a106** (no rails set at kernel boot; LK owns them) |
| PMIC EINT | **Yes — done** | `mt_eint_set_hw_debounce(num,deb)` + `mt_eint_registration(num,flag,fn,auto)` immediates (r0=num, r1=flag) | `PMIC_EINT_SETTING` @`0xc0510e2c`; handler `mt6323_pmic_eint_irq` @`0xc0510d54` | **ch=25, HIGH(4), deb=1 ≡ a106** |
| EINT map (AP channels) | **Yes (remaining work for Forge)** | Per-driver `mt_eint_registration` immediates + the GPIO the driver programs; cross-check DWS records | PMIC 25 ✓, touch 2 ✓(D17); `msdc_enable_cd_irq` → **GPIO3**; `accdet_eint_func` → **GPIO4** (mode/dir/out triple) | MSDC1-INS **8→3**, ACCDET **0→4(+confirm EINT num & polarity from the registration call)**, GSE/ALS stay a106 (no such kernel driver on Q5 — verify strings confirm no GSE driver in blob) |
| Boot GPIO pin modes (`cust_gpio_boot.h`) | Decodable but **moot** | n/a — no compiled kernel consumer (§1.2 #6) | — | **Skip** |
| GPIO usage map (`cust_gpio_usage.h`) | **Yes** | Whole-image map of `mt_set_gpio_{mode,dir,out,pull_enable,pull_select}` callsites: pin = r0 immediate (`movw/movt`, or `ldr [pc]` literal pool → hand-resolve) | 197 callsites mapped this session by function (gsl 14/2 ✓, camera, speaker, accdet, usb, msdc, rtc-pwrdn, kpd, vibrator, wmt…) | Port the divergent pins (MSDC-CD, ACCDET, OTG, RTC-BBPU if divergent); gsl ✓ |
| LCM reset pin | **Yes — done** | `lcm_set_reset_pin` body | @`0xc05992d0` = `uxtb` + `bl LCD_SetResetSignal` ≡ fork `disp_hal.c:181-185` (SoC **register**, no GPIO) | **Match — nothing to port** |
| DSI-LANE / TE | **Yes — done** | No `mt_set_gpio_*` in any dsi/lcd function (0/197); TE enable = DSI reg bit | `DSI_TE_Enable`/`_EXT_` @`0xc05917e8/0xc059182c` (flag bytes + `0xF400C018[9]`) | **No TE GPIO in this class — closed** |
| LCM drivers / params / lanes | **Done (D18)** | — | D18 report | Ported; asserted by parity |
| Leds/backlight | **Yes — done** | `get_cust_led_list` returns static array; entries = 32 B `{char* name, int mode, int data, PWM_config[5]}` | array @`0xc0b5fb7c`; `Cust_GetBacklightLevelSupport_byPWM` returns 256 | lcd = `CUST_BLS_PWM(5)` ≡; red/green/blue/jogball/keyboard/button = `NONE` (hygiene port) |
| Keypad | **Yes** | Keymap table = adjacent LE32 Linux keycodes (114/115) in rodata near kpd code; row/col + pwrkey-pmic flag as immediates in `kpd_pdrv_probe`; compare with `KPD_INIT_KEYMAP` | `kpd_pdrv_probe` @`0xc04a4820`, `kpd_keymap_handler` @`0xc04a4354` | Forge decode → port only if divergent |
| Speaker EN pin | **Yes (Forge work)** | `Speaker_Init`/`Sound_Speaker_Turnon` — pin via `movw/movt` or literal pool (the vendor passes cust-struct fields; resolve the struct by following the `ldr rX,[pc]` pool word into rodata) | `Speaker_Init` @`0xc004e424`, `Sound_Speaker_Turnon` @`0xc004e500`; a106 side: `GPIO_SPEAKER_EN_PIN = GPIO6` | Port into `cust_gpio_usage.h` if ≠ GPIO6 |
| USB OTG pins | **Yes (Forge work)** | Same pool-resolve on `mt_usb_otg_init` (cust struct in rodata near `0xc0daf358`, dump 32–48 B and match the a106 struct layout) | `mt_usb_otg_init` callsite set mapped | Port `GPIO_OTG_IDDIG_EINT_PIN` (a106: GPIO17) / `GPIO_OTG_DRVVBUS_PIN` (a106: GPIO21) if divergent |
| SD card-detect | **Yes — done (pin)** | `msdc_enable_cd_irq` GPIO triple | **GPIO3** (a106: EINT8/GPIO8-class) | Port `CUST_EINT_MSDC1_INS_NUM` + pin |
| Accdet (audio-jack) | **Yes (Forge work)** | `accdet_eint_func` GPIO4 triple + the EINT channel from its registration; vendor flow prints `[Accdet]accdet_setup_eint` | `mt_accdet_probe`, `accdet_eint_func` | Port accdet pin/channel |
| Camera power/reset | **Done (D8–D11) — cross-check only** | Re-run D11's anchors against `kdCISModulePowerOn` @`0xc004deac` to confirm no DCT-level divergence | callsite map present | Verify-only assertion |
| RTC power-down GPIO | **Yes (Forge work)** | `hal_rtc_bbpu_pwdn` mode/dir/out triple | callsite mapped | Hygiene port if divergent |
| Vibrator | **Yes (trivial)** | `get_cust_vibrator_hw` returns cust struct; decode rodata struct | @`0xc004e2b4` | Hygiene if divergent |
| Clocks/PLL | **Not applicable** | No board clock table exists in this kernel (§1.2 #5) | — | **None** |

---

## 3. The port plan (task Q3 — implementation-ready for Forge)

Two new deltas, following the established D-series discipline (one patch file each, prologue with
evidence, donor/blob anchors, hash-pinned inputs, parity outputs). **No values are invented; every
changed constant cites its blob anchor.**

### 3.1 D19 — display-path guards (panic-class hardening; lands FIRST, alone with D18 it is the flash)

Rationale (ADR): the log is unrecoverable (ram-console cleared by the SP flash; no AEE dump; no UART
adapter — task context). Class 1 is convicted by evidence (§1.2), but its *exact* fault line inside
the miss path cannot be named statically: the unbounded DSI `compare_id` reads M3 documented would
hang (not panic), so the observed 5 s panic implies either the `lcm_drv==NULL` continuation faults,
or a deeper abort. **We cannot fix a line we cannot see — so we make the entire class of failure
survivable and observable instead, while the corrected LCM list (D18, landed) removes the actual
cause.** This is risk-reduction instrumentation deliberately promoted to a fix because the root
cause (wrong list) is already fixed and the guard is what protects every *future* miss
(e.g., an ST7701S-variant Q5 unit hitting a gc9503v-only build).

Patch `patches/kernel/D19.patch`, two files in the shared video driver (touching nothing the D19
prologue won't document):

1. `drivers/misc/mediatek/video/mt6582/mtkfb.c` — in `mtkfb_probe`, after the
   `mtkfb_find_lcm_driver()`/`DISP_DetectDevice()` block (~line 2822): on total miss (`lcm_drv ==
   NULL` after both), **log a loud marker and `goto cleanup` with `r = -ENODEV`** instead of
   proceeding to `DISP_Init` with a NULL lcm driver. Effect: the probe fails cleanly, the kernel
   keeps booting (dark screen), adb/dmesg come up, and the marker names the exact miss. Effect on
   the healthy path (name matched, D18): none — the guard is behind the miss condition only.
2. `drivers/misc/mediatek/video/mt6582/dsi_drv.c` — bound the unbounded polls M3 identified
   (`≈1606 while(BUSY)`, `≈1619/1629 while(CMD_DONE==0)`, `≈1639 while(STATE_DBG0&1)==0`) with the
   same ~100 µs/100 ms budget pattern its sibling functions already use, logging and returning an
   error on expiry; add the missing `break` to the timeout arm of `_WaitForEngineNotBusy`'s loop.
   Effect: any future unhealthy-engine condition becomes a bounded, logged failure (dark or
   recoverable), never a silent freeze — and it converts the α-class hang mechanism into something
   with a signature in the log.

Priority: **P0 — this is what the first M4 re-flash exists to prove.** It is small, entirely within
already-touched subsystem, and bisect-friendly.

### 3.2 D20 — the Q5 board-value port (functional classes; proven-safe to ride along)

**The mechanics come first — this is where an uninformed implementation fails:**

- **DCT regeneration trap.** `arch/arm/Makefile:298` includes `scripts/drvgen/drvgen.mk`;
  `archprepare` regenerates the DCT headers from `tools/dct/DrvGen` (host ELF, not stripped) +
  `q5/dct/dct/codegen.dws` into `$(objtree)/arch/arm/mach-mt6582/q5/dct/dct/inc/` whenever the dws
  or the tool is newer — observed live (`build-beta-touch*/…/cust_eint.h` carries a 2026 timestamp
  vs the a106 2017 header). The compile include order from `.pmic_drv.o.cmd`: `-I <srctree>/q5/dct/dct`
  (no `/inc` — does not resolve `cust_eint.h`) … `-I <objtree>/q5/dct/dct/inc` (drvgen output —
  **this is what actually compiles**). **Editing `q5/dct/dct/inc/*.h` in the source tree alone is a
  no-op.**
- **Mechanism (chosen — include-precedence override):** D20 adds
  `-I$(MTK_PROJECT_PATH_ROOT)/dct/dct/inc` **before** the `-I$(DRVGEN_OUT)/inc` line in
  `drivers/misc/mediatek/Makefile.custom`, and maintains the Q5-pinned values in the *source*
  headers `q5/dct/dct/inc/*.h` (D15/D16's existing byte-compare invariants then guard the pinned
  values — see pipeline change). The `codegen.dws` is *documented* as a106-provenanced and left in
  place (drvgen still generates the untouched files; overridden files resolve from the source dir
  first). Alternatives considered and rejected: (a) binary-editing `codegen.dws` — format is the
  Windows DrvGen project's binary save (visible records, but no writer in-tree; high risk of silent
  field-width corruption; *revisit only if a later build proves precedence didn't take* — the
  parity gate below detects exactly that);
  (b) post-`archprepare` O-dir overwrite + `touch` — works but is pipeline magic invisible to code
  review; reserved as fallback if (chosen) precedence shows any edge case in `ptgen`-touched paths.
- **Header-set discipline:** only headers carrying changed values are overridden; all others stay
  on the drvgen path (so `cust_adc.h`/`cust_power.h`/`pmic_drv.*` remain generated and
  bit-identical to today).

**Values to port** (priority order inside D20 — highest-risk-first = the in-window items and the
post-fb boot-completion risks; each with its blob anchor so Forge re-verifies, never copies blindly):

| Pri | File(s) → value | a106 today | Q5 truth (blob anchor) | Why it matters |
|---|---|---|---|---|
| 1 | `q5/dct/dct/inc/cust_eint.h` + `cust_gpio_usage.h`: **MSDC1 card-detect** | `CUST_EINT_MSDC1_INS_NUM 8`, GPIO8-class pin, LOW debounced | pin **GPIO3** (`msdc_enable_cd_irq` triple: mode/dir/out 0x3); EINT channel + trigger from the registration call site (Forge: complete the decode — `bl mt_eint_registration` args in that function's region) | msdc1 probes during `board_init` **right before fb**; a wrong level-triggered channel on a floating/mis-wired pin storms IRQs in the panic window's tail — and a phantom card-detect breaks Android boot anyway |
| 2 | `cust_eint.h` + `cust_gpio_usage.h` (+ `q5/accdet/accdet_custom*` if the driver takes the pin from there): **ACCDET** | ch 0 / GPIO0, TRIGGER_LOW | **GPIO4** programmed in `accdet_eint_func`; channel + flag from the adjacent registration (Forge decode) | Audio-jack detect; post-fb but required for sound correctness on a music player |
| 3 | `cust_gpio_usage.h`: **GPIO_OTG_IDDIG_EINT_PIN / GPIO_OTG_DRVVBUS_PIN** | GPIO17 / GPIO21 | `mt_usb_otg_init` pool-decode (rodata cust struct near `0xc0daf358`) | usb20 = **fs_initcall, inside the panic window**; harmless (GPIO writes) but pin collisions with Q5 wiring must be eliminated on principle |
| 4 | `q5/leds/mt65xx/cust_leds.c`: set red/green/blue/jogball/keyboard/button to `MT65XX_LED_MODE_NONE, -1` | PMIC ISINK1 / ISINK0 / NONE / NONE / NONE / ISINK2 | vendor **NONE** for all six (`get_cust_led_list` array @`0xc0b5fb7c` decoded this session) | Hygiene: stops sourcing 20 mA-class current sinks into unconnected PMIC outputs; zero risk; keeps `lcd-backlight` BLS entry byte-identical |
| 5 | `cust_kpd.h` / `q5/keypad/mtk_kpd.h`: port keymap **only if** the blob's `{114,115}` keymap/rodata + pwrkey flag diverges from `[1]=VOLUP [2]=VOLDOWN`, PMIC pwrkey | as listed | `kpd_pdrv_probe`/`kpd_keymap_handler` decode | Three-button player; expected match — the decode doubles as the proof |
| 6 | `cust_gpio_usage.h`: RTC `BBPU` pin, vibrator cust struct | a106 values | `hal_rtc_bbpu_pwdn`, `get_cust_vibrator_hw` | Hygiene (poweroff path, vibrator) |
| 7 | Assertion-only (no edit): camera power/reset pins | D11 values | re-run D11 anchors vs `kdCISModulePowerOn` @`0xc004deac` | Continuous proof D11 stays aligned with the blob |

**Nothing else changes in D20:** PMIC cust (proven empty≡), PMIC EINT (25≡), TE/LANE/reset
(proven), `cust_gpio_boot.h` (inert), clocks/PLL (no board table), partition (M3-verified),
touch (D17), LCM (D18).

### 3.3 Pipeline changes (Forge, build-side)

1. **`build/62_kernel_delta_board.sh`** — clone of 61's shape: applies D1…D18 + D19 + D20 into a
   fresh O dir `build-beta-touch-lcm-board`, with **new assertions** replacing the old
   pin-them-equal checks:
   - **re-pin the D15/D16 invariant** in 50/60/61/62: `keypad/mtk_kpd.h`,
     `dct/dct/inc/cust_kpd.h`, `dct/dct/inc/cust_gpio_usage.h` (and D20 files) are no longer
     required to equal the a106 originals — instead compare against the **Q5-pinned contents** (the
     pipeline's source-of-truth copies), so a reverted value fails the build loudly.
   - **new proven-match parity asserts** (grep -ic style, β-touch-lcm-board vs Lithium blob):
     `gc9503v` names = 1/1 each; PMIC: vendor pmic-cust is empty → **assert the fork's is too**
     (source-compare, not strings); EINT 25 present in both; `disp_bls_set_backlight` present both
     sides; plus the unchanged-carry-over set from D18's table (cameras, lens, amp, gsl, ccci,
     mt6323=19, auxadc=210, must-not bct24157/MAX17050/fan5405 = 0).
   - **precedence-took-effect gate**: post-build, verify the compiled binary contains the new
     constants (e.g., strings/objdump spot check on the O-dir `.o`s or whole-Image string parity
     for the affected drivers) — this is the detector that proves the Makefile.custom precedence
     worked and drvgen did not shadow our headers. If this gate fails, fall back to mechanism (b),
     the post-`archprepare` O-dir overwrite.
2. **`build/55_repack_boot.sh`** — add tag `beta-touch-lcm-board` (same header/ramdisk/assurance
   plumbing; byte-parity harness reused unchanged).
3. Additive hygiene only in 50/60/61 (reset lists + O-dir whitelist for the new stage) — pinned
   behavior unchanged, exactly per the D17/D18 pattern.
4. Defconfig: **no clock/PLL toggles** (§1.2 #5); the only defconfig edits M4 makes are none at
   all (D19 touches driver source, D20 touches board files + one Makefile.custom line).

---

## 4. Staged re-test plan (task Q4)

Principles: BOOT partition only; system stays the pinned Lithium `system.img`; stock Mint restore
unchanged; **one kernel variable per flash**; every failure runs the §4.3 capture protocol. The
M3-era α/β/β-touch ladder is **retired** — α is now *explained* (hx8369b list cannot match the Q5
LK's gc9503v names) and no longer a useful probe.

### S0 — build & static gates (no device)
- `62_kernel_delta_board.sh` then `55_repack_boot.sh beta-touch-lcm-board` →
  `out/boot-m1b-beta-touch-lcm-board.img` (+ sha256 sidecar, same as siblings).
- Gates: all §3.3 assertions PASS; image anatomy = the same dual-header/ramdisk-verbatim form as
  the pinned siblings; header fields differ from the donor only in `kernel_size`.

### F1 — flash `beta-touch-lcm-board` (D18 + D19 + D20) — the M4 verdict flash
Watch for **≥ 30 s** and classify:
- **Boots to Android** (`adb wait-for-device` → `adb shell uname -r` = 3.10.54) ⇒ **M4 root cause
  closed.** Expected dmesg (Karen's acceptance set):
  `Linux version 3.10.54` banner, `[LCM Auto Detect], we have 2 lcm drivers built in` (or the hsd/boe
  pair), `[LCM Specified] [gc9503v_wvga_dsi_vdo_hsd|_boe]`, `[mtkfb] LCM resolution: 480 x 800`,
  GSL: `the test 0xb8 = {…}` + `------GSLX680_FW_*------`, `0-0040 gsl_tp`, one `mtk-tpd` input.
- **Logo clears but system misbehaves** ⇒ past the panic class; triage the new symptom (functional
  deltas, not panic).
- **Still reset-loops ~5 s** ⇒ capture per §4.3 immediately. The D19 guards make a repeat of the
  *same* silent loop materially less likely (autodetect is bounded; total-miss probe bails loudly);
  a surviving loop means a **different** fault line, and the capture now finds it.
- **Boots dark-but-alive** (adb answers, screen black) ⇒ D19's miss-guard fired: the dmesg marker
  names the LCM-name mismatch verbatim ⇒ the LK/unit carries the *other* panel family
  (`st7701_wvga_dsi_vdo_ivo|_dingsj`); that is the documented, evidence-gated D21 (port the two
  st7701s drivers from the same blob — the method is identical to D18; their tables/params sit in
  the same region right next to the gc9503v ones).

### F2 — only if F1 loops: instrumentation flash
Rebuild/repack with the existing `--debug-cmdline` flag (adds
`console=ttyMT3,921600n1 initcall_debug printk.time=1`), flash, capture (§4.3). The log names the
stalled initcall/driver; the fix is then a bounded third delta against a named line — no more
broad-port iteration.

### 4.3 Failure-capture protocol (mandatory on every failed flash, in order)
1. Record hang-forever vs ~5 s periodic reset (primary classifier).
2. **ram-console / last_kmsg first (no SP full-flash between failure and readback):** warm-reset
   into the known-good control (boot-only flash of `boot-m1b-lithium-ctl.img`, which leaves system +
   SRAM console intact — do **not** reflash other partitions), then `cat /proc/last_kmsg` and dump
   `/sdcard/mtklog/aee_exp*`. SRAM console at `0xF900DC00` survives warm resets (M3 §5.4).
3. AEE powerkey hang-dump: hold Power ~10–15 s on the hung screen, then read expdb from the control boot.
4. UART if an adapter ever becomes available: ttyMT3 921600 8N1, debug cmdline already prepared.
5. Deliver captures with the flash report; a log beats ranking.

---

## 5. Validation baseline for Karen (expand freely)

- **Per-image gate (any M4 flash):** reset-loop-5s absence is the primary signal; `uname -r`
  3.10.54 + adb = boot acceptance; the dmesg marker set in F1 is the full acceptance.
- **Regression set after F1 passes:** D17 (touch input `mtk-tpd`, `the test 0xb8` banner), D18
  (`[LCM Specified]` name + 480×800), D13/D14 (amp probe `2-0058 aw87559_pa`), D1–D3/D7 (charger
  strings absent), D4 (battery present, sane SOC slope), D8–D12 (camera/lens sysfs presence).
- **New-class acceptance (D20):** `/proc/interrupts` shows sane EINT counts (no runaway line);
  `cat /sys/class/leds/*/brightness` — red/green/button nodes present but inert; audio-jack
  insert/remove generates accdet events; keys VOL+/−/POWER emit
  `EV_KEY KEY_VOLUMEUP/KEY_VOLUMEDOWN/KEY_POWER`; USB host/device mode switch works (OTG pins).
- **Edge cases to keep on the radar:** ST7701S Q5 unit ⇒ dark-D19-boot (diagnosable, not panic —
  then D21); a repeat silent loop *with* D19 in ⇒ different fault class → F2 instrumentation path;
  SP full-format flashes wipe the SRAM console ⇒ always boot-only flash for capture.

---

## 6. Audit trail (evidence index)

- Initcall map: `arch/arm/mach-mt6582/board.c:47`; `mt_devs.c:1556 mt_board_init`, `:1809`
  fb-device, `:1817` leds-device, `:1640-1652` i2c; `mtkfb.c:3541 module_init`; probe miss path
  `mtkfb.c:2808-2830`, `2955-2973 DISP_Init`; `disp_drv.c:680-788` (boot parse, `isLCMFound` pin,
  `disp_drv_init_context`), `disp_hal.c` `disphal_get_lcm_driver`/`disphal_get_if_driver`;
  `eint.c:1524 arch_initcall`; `pmic_mt6323.c:3559/3881 fs_initcall`, `:94-99` hardcoded ch25;
  `dsi_drv.c:256-258` TE GPIO113 + `:769-779, 838-847` mixmode gate; `lcd_drv.c` `LCD_Init_IO_pad`
  no-op; misc_via/charger cust_gpio_boot consumers (4 files, all unbuilt in q5 defconfig).
- DCT regen: `scripts/drvgen/drvgen.mk` (`archprepare: $(DRVGEN_FILE_LIST)`),
  `arch/arm/Makefile:298`; live proof: `build-beta-touch*/arch/arm/mach-mt6582/q5/dct/dct/inc/*.h`
  timestamps 2026-11-25 vs source 2017-08-03; compile-line include order from
  `build-beta-touch-lcm/…/q5/dct/dct/.pmic_drv.o.cmd`; `tools/dct/DrvGen` = host ELF (not stripped).
- Blob decodes this session (pinned decomp `d284ba16…` via `forge-d17/lithium.elf`, base
  `0xc0008000`): `pmu_drv_tool_customization_init @0xc004aad8` = empty;
  `PMIC_EINT_SETTING @0xc0510e2c` = ch25/HIGH/deb1; `get_cust_led_list @0xc004e3ec` → array
  `@0xc0b5fb7c` (32 B entries): lcd-backlight mode=5/callback, six others mode=0; backlight PWM
  support fn returns 256; `lcm_set_reset_pin @0xc05992d0` → `LCD_SetResetSignal` register;
  `DSI_TE_* @0xc05917e8/0xc059182c` = reg-only; 197 `mt_set_gpio_*` callsites mapped by function
  (gsl 14/2 ✓, msdc_cd GPIO3, accdet GPIO4, speaker/otg/usb/rtc/kpd/vibrator anchors listed §2);
  kpd anchors `0xc04a4820/0xc04a4354`; speaker `0xc004e424/0xc004e500`.
- Prior anchors reused: D17 (`forge-d17-report.md` §2), D18 (`forge-d18-report.md` §2), M3
  (`bob-m3-boot-debug.md` §2/§3/§5.4), hardware facts (`hardware-facts-q5-mint.md`).

**Remaining entry points (non-blocking):** exact panic line unknowable without a log — covered by
D19 guards + §4.3 capture instead of chasing it; ST7701S-unit D21 only if F1 shows the dark-boot
marker; `codegen.dws` binary edit only if the precedence gate (§3.3-1) ever fails its proof.

**Design complete.**
