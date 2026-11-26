# Bob — M3 boot-debug: fork kernel hangs at the LK logo

**Task:** `.specs/bob-m3-task.md`
**Symptom (verified on device):** `out/boot-m1b-beta-touch-lcm.img` (heyrudra 3.10.54 + q5 board
config + D1–D18 + Lithium ramdisk + Lithium args) shows the LK "Timmkoo" splash and never reaches
Android. Preloader + LK run (logo on screen); the KERNEL is the failure point. Device rolled back
to Mint.
**Method:** full static audit of the fork tree/build/repack, byte-level comparison against the
pinned Lithium donor (`443e40c3…` boot.img; kernel blob `5217dd41…`; decomp `d284ba16…`; Mint
blob for cross-checks), initcall-level trace of every D-delta's boot-time code, and read-through
of the MT6582 DSI/display boot path (the only delta-touchable code that runs before the logo
would disappear). **No flashing performed by Bob.**

---

## 0. TL;DR — verdict

1. **The repack is innocent.** Boot args, MTK dual-header format, ramdisk blob, offsets, board
   number, cmdline — all verified byte-for-byte against the Lithium donor *independently of
   Forge's own assertions* (§2.1). The only byte difference between the fork images and the
   known-good Lithium image is the kernel payload.
2. **The memory map is innocent.** `PHYS_OFFSET=0x80000000`, `zreladdr=0x80008000`, memory comes
   from LK's ATAG_MEM at runtime (`mt_fixup`), identical for both kernels (§2.2).
3. **The a106-cloned "q5" board config has never been validated on Q5 hardware, and the logo-hang
   symptom is consistent with failure *before* the mtkfb probe completes.** Almost none of the
   D1–D18 deltas execute any code before that point (§3.2) — so the prior probability is heavily
   on a **tree/board-config-level failure that α itself would also hit**. This is a hypothesis
   about probabilities, not a finding of fact: no fork image except β+touch+lcm has ever been
   flashed.
4. **The decisive next test is NOT another build — it is two flashes**: (a) a *repack-control*
   image (Lithium's own kernel payload re-packed by our pipeline), then (b) `out/boot-m1b-alpha.img`
   (stock a106 build). That pair isolates {repack machinery} vs {tree/board-config} vs {a delta}
   in two boots (§5).
5. **Do not rebuild from scratch. Do not shotgun code changes before the α/control evidence
   exists.** The pipeline is deterministic and the four existing images already form a bisect
   ladder. The fix is evidence-gated and will be a small config/board patch, same model as
   D17/D18 (§4).

---

## 1. Symptom decomposition — what "hangs at LK logo" does and does not mean

The LK paints the logo. The kernel's display subsystem (`mtkfb_probe`, `module_init` →
`device_initcall`) re-initializes the DSI engine and installs a fresh framebuffer; on success the
logo is gone within the second — replaced by blank/black, then the Android boot animation, while
ccci/mmc/audio/i2c sensors come up. Therefore:

- **Logo persists ⇒ the kernel stalled before `mtkfb_probe` completed**, i.e. in
  decompression / `start_kernel` / initcalls up to the video init, or in a hard busy-loop inside
  the display init itself.
- **`CONFIG_PANIC_TIMEOUT=5`** is set in all four fork configs. A classic kernel panic would
  **auto-reboot after ~5 s** (visible as a logo flicker/reset loop). The reported behaviour
  (persistent hang, rollback needed) is therefore more consistent with an **infinite wait
  (busy-loop/deadlock) than a panic** — and vendor MT6582 code contains exactly such unbounded
  wait loops (§3.4). Hera must confirm hang-vs-reset-loop on the next flash; it is a one-glance
  discriminator.

Boot order facts that matter (verified in-tree):

| Subsystem | initcall level | Runs before logo would clear? |
|---|---|---|
| DSI/LCM select + `DSI_Init` | `mtkfb_init` → `device_initcall` | **yes — this is the logo-clearing step itself** |
| ccci modem init | `device_initcall_sync` (`ccci_init`) | no (after mtkfb in level order) |
| i2c adapters (`mt_i2c`) | platform devices registered by `mt_board_init` ← `late_initcall(board_init)` | no |
| gsl touch probe (D17), aw87559 amp probe (D13/D14) | driver probe at adapter-add ⇒ `late_initcall` | no |
| eMMC/MSDC + PMT scan | platform device registered at `late_initcall` | no |
| camera sensor/lens init (D8–D12) | camera open from userspace | no |
| FGADC/battery_meter (D4) | `device_initcall` (bounded auxadc) | around the same window; constants-only change |

---

## 2. Task questions 1–3 — verified-safe items (with evidence)

### 2.1 Boot args / images format — VERIFIED CORRECT (task Q1)

Independent re-parse of all five images (script in the audit trail below):

| Image | kaddr | raddr | saddr | taddr | pg | board | cmdline |
|---|---|---|---|---|---|---|---|
| Lithium `boot.img` (`443e40c3`) | 0x80008000 | 0x84000000 | 0x80f00000 | 0x8e000000 | 2048 | 1441186574 | `bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug` |
| `boot-m1b-alpha.img` | 0x80008000 | 0x84000000 | 0x80f00000 | 0x8e000000 | 2048 | 1441186574 | identical |
| `boot-m1b-beta.img` | ident | ident | ident | ident | 2048 | ident | ident |
| `boot-m1b-beta-touch.img` | ident | ident | ident | ident | 2048 | ident | ident |
| `boot-m1b-beta-touch-lcm.img` | ident | ident | ident | ident | 2048 | ident | ident |

Every header field except `kernel_size` is byte-identical to the donor; `ramdisk_size` identical;
ramdisk region is the donor blob verbatim (`c0be6c46…`); the MTK 512 B `KERNEL` header
(`88 16 88 58 | LE32 len | "KERNEL" | 0xFF…`) matches the donor's anatomy (len = zImage size,
asserted by `55_repack_boot.sh`). No trailing signature/secure append exists in the donor image
(its size is exactly 2543×2048 — plain mkbootimg output), and the donor boots on this device;
**the Q5 LK therefore does not authenticate the kernel payload of boot.img** (the LK binary
contains `sec_img_verify.c` strings, but they are inert here for this image class). BOOT
partition is 16 MB (`out/scatter-fork.txt` BOOTIMG `partition_size: 0x1000000`); all images
(≤5.67 MB) fit.

**One residual risk the static check cannot close:** the fork kernel payload (4.26 MB MTK-headed)
is ~12 % larger than Lithium's (3.81 MB). No LK size-cap evidence exists *either way*; this is
cleanly falsified by the repack-control test (§5, T0) combined with α (T1).

### 2.2 Memory / DRAM — VERIFIED COMPATIBLE (task Q2)

- heyrudra tree: `arch/arm/mach-mt6582/include/mach/memory.h` → `#define PHYS_OFFSET 0x80000000`;
  `Makefile.boot` → `zreladdr 0x80008000`, `params_phys 0x80000100`. Matches Lithium's header
  addresses exactly.
- **DRAM sizing is runtime, not compile-time.** `mt_fixup()` (mt_devs.c:1108) sums the LK-provided
  ATAG_MEM banks and carves the vendor reserved block from the last bank (`FB_SIZE`, modem share,
  etc.). The same LK hands the same ATAGs to both kernels. There is no in-tree DDR-type/geometry
  table that could mismatch (`dram_overclock_init` only creates sysfs files + copies sram text;
  `CONFIG_MAX_DRAM_SIZE_SUPPORT=0x80000000` is a 2 GB ceiling).
- String inventory for memory machinery, Lithium blob vs fork β-touch-lcm Image: ddr 890/1115,
  emi 163/179, mblock 17/18, md32 12/15, DRAM 22/30 — same SoC memory stack on both
  (differences are the a106 tree's extra debug/format strings).
- Both kernels: XZ-compressed zImage, `VMSPLIT_3G`, `HIGHMEM`, 3.10.54, gcc 4.8, same compiled-in
  console fallback (`console=ttyMT3,921600n1`) + `CONFIG_CMDLINE_FROM_BOOTLOADER=y` (LK's cmdline
  wins). Lithium's banner: `Linux version 3.10.54 (wangliang@innioasis117) (gcc 4.8) #3 SMP
  PREEMPT Fri Jan 26 12:00:29 CST 2024`. Fork: same, anchored identity.

### 2.3 Board-config completeness — the honest status (task Q3)

`mach-mt6582/q5/` is a byte-clone of `a106/` plus D1–D18 (asserted by `50_kernel_delta.sh`;
`diff -rq` confirms only the D-patched files differ). Deliberate audit of the clone classes that
execute **before the logo would clear**:

| Board-config class | Verdict | Evidence |
|---|---|---|
| DCT PMIC boot init (`q5/dct/dct/pmic_drv.c`) | **safe** — a106's `pmu_drv_tool_customization_init()` is an empty function; no rail is re-programmed at boot | read the file |
| `mt_devs.c` static i2c board infos | safe — all commented out; platform devices only | mt_devs.c:846-864, 1640-1642 |
| `q5/core/board.c` | safe — combo-WiFi glue, no board initcalls | grep, no `*_initcall` |
| `q5/partition/cust_part_mbr.c` | standard value `MBR_START_ADDRESS_BYTE = 12 Mi` | read; and PMT scan runs at late_initcall anyway |
| DCT EINT/GPIO-usage | **partially validated for touch only**: D17 proved CTP RST=GPIO14, EINT=GPIO2, `CUST_EINT_TOUCH_PANEL_NUM 2`, VIO28+VGP1 rails against the Lithium blob — exact match, no edits | d17-report §2.4 |
| **Everything else DCT-derived** (`cust_gpio_boot.h` boot-time pin modes/states, `cust_eint.h` channel map, `cust_leds*` backlight/PWM routing, keypad matrix, DSI-LANE/TE pin mode defaults in `codegen.dws`) | **NEVER validated against Q5 ground truth** — these *do* run/matter early (GPIO boot states apply at SoC GPIO init; DSI/T E pin modes gate the video path) | **the open risk; α test + log capture addresses it** |
| LK name contract for LCM | validated: Q5 LK carries exactly the four names and `%s lcm=%1d-%s`; kernel receives one of them via ATAG_CMDLINE (survives `cmdline_filter` — it strips only `console=/root=/lk_t=/pl_t=`) | d18-report §2.1; mt_devs.c:1039-1079 |

**Bottom line for Q3:** no *proven* wrong setting, but the only Q5-evidenced parts of the cloned
board config are the ones D17/D18 decoded from the blobs. The rest is a106 hardware truth, not
Q5 hardware truth. The display-pin/pad class (`cust_gpio_boot.h` defaults for DSI/TE/LCM-RST)
is the highest-risk unverified class because it can break the DSI engine path — see H1b.

---

## 3. Root-cause hypotheses, ranked

### Ranking logic (read this first — it's the spine of the test plan)

For the kernel to hang *with the LK logo still up*, the failure must occur **before
`mtkfb_probe` completes** (§1). Auditing every delta for code that actually executes in that
window (§3.2) shows that **at most one delta (D18) touches that window at all, and even it only
does struct-level work there** (name strings + `get_params`; the DSI engine init and the
optional compare_id reads are *shared* SoC code that α/β run identically). Every other delta
runs at `late_initcall`, at device-open from userspace, or never touches hardware at boot.
Therefore the prior distribution is:

- **P(tree/board-config/boot-level failure, shared by α, β, β-touch, β-touch-lcm) ≈ 0.6**
- **P(repack/format failure, shared by all four) ≈ 0.05** (static evidence already strongly
  against; control image closes it)
- **P(D18-specific) ≈ 0.15 · P(D17) ≈ 0.08 · P(D13/D14) ≈ 0.04 · P(D1–D12) ≈ 0.08**

The α/control flash pair discriminates the first two from everything else at a cost of two
flashes — dramatically cheaper than blind code changes.

---

### H1 — tree/board-config-level failure (α itself hangs). **Prior ≈ 0.6. Test: T1 (α flash) + captured log.**

The fork kernel has never once booted on Q5 hardware. The α image is a *stock a106 build* — the
whole unproven surface (LK-handoff on this device, ATAG parsing, clocks, PMIC, eMMC, display
engine under a106 board/DCT truth) is exercised by α exactly as much as by β+touch+lcm.

Mechanisms, ranked within H1:

#### H1a — DSI engine busy-wait during display init (fits symptom best)

The MT6582 vendor DSI stack contains **timeout-free busy-waits on engine registers**; the
prominent ones are in the DSI *read* path used by `compare_id`/autodetect:

- `drivers/misc/mediatek/video/mt6582/dsi_drv.c` ≈1606 `while(DSI_REG->DSI_INTSTA.BUSY);` —
  **no timeout**; ≈1619/1629 `while(DSI_REG->DSI_INTSTA.CMD_DONE == 0);` — **no timeout**;
  ≈1639 `while((INREG32(&DSI_REG->DSI_STATE_DBG0)&0x1) == 0);` — **no timeout**.
- `_WaitForEngineNotBusy()` (≈530): the non-interrupt path loops
  `while (BUSY || CMD_DONE) wait_event_interruptible_timeout(2 s)` and on timeout dumps registers
  + `DSI_Reset()` but **never breaks** — if the engine never recovers this is an infinite
  2 s-cadence wait inside `mtkfb_probe` (hang with periodic UART prints).

If the DSI engine is non-functional under the a106-clone board/DCT config (display clocks, IO-pad
or TE/reset-pin boot states — the unverified class from §2.3), every variant of this loop hangs
the boot *before* the logo is redrawn, with interrupts alive on other CPUs, the watchdog pat
kept by other threads — **an indefinite silent hang at the logo. Exact symptom match.**

Boot-path detail that shapes the sub-cases (traced in `disp_hal.c` / `disp_drv.c` / `mtkfb.c`):

- **LK passes `lcm=<n>-<name>`** (Q5 LK passes a `gc9503v_wvga_dsi_vdo_hsd|_boe` name, always).
- β-touch-lcm: name **matches** the compiled list → `DISP_SelectDevice` succeeds → no compare_id,
  no DSI reads at select time; engine init proceeds with blob-exact LCM params.
- α/β/β-touch (`hx8369b*` names): name **misses** → `mtkfb_find_lcm_driver` fails →
  `DISP_DetectDevice()` runs **autodetect**: `init_dsi(FALSE)` + `compare_id` per compiled
  driver → those unbounded DSI **read** waits are on the critical path. (So paradoxically
  α/β/β-touch are *more* exposed to an unhealthy DSI engine than β-touch-lcm.)

#### H1b — a106 DCT GPIO/display boot-state mismatch (the unverified class feeding H1a)

`cust_gpio_boot.h` (1200 lines, a106-generated) sets each pin's boot mode/direction/level. If an
a106-mode pin collides with Q5's wiring (e.g., a GPIO the Q5's hardware expects held differently
for the display/PMU/eMMC), the kernel can malfunction during early init. Unverifiable from the
blob alone; needs either the α symptom or the UART/ram-console log, then a blob-forensic
decoding of the vendor's DCT-equivalent (exactly the D17/D18 method — pin numbers are visible
as compiled `mt_set_gpio_*` constants in the Lithium blob).

#### H1c — other pre-logo early init (eMMC PMT, SPM/PM, EMI-MPU, auxadc-cal, kpd/leds/accdet)

All traced SoC-level and shared with any working MT6582; PMT/MSDC actually probe at
`late_initcall` (after the logo step) so they are excluded from the logo-hang class. Listed for
completeness; no evidence pointing here.

### H2 — repack/format failure (even a control wouldn't boot). **Prior ≈ 0.05. Test: T0.**

Statics all line up (§2.1), but only a boot of the **Lithium-kernel-payload repacked by our own
pipeline** proves the mkbootimg invocation + MTK header generation + offsets produce a booting
image on *this* LK (kernel-size headroom included — fork payload is 12 % larger). A 10-minute,
zero-compile test that must run first.

### H3 — D18-specific (α/β/β-touch fine; only β+touch+lcm hangs). **Prior ≈ 0.15. Test: T2/T3/T4 ladder.**

Possible mechanisms, even though D18's boot-time code is structurally inert (§3.2):

- Name-match changes the boot display flow: matched-name selection *skips* the autodetect reads
  but *proceeds* with full `DSI_Init` + timings from the blob-exact `lcm_params`, then the first
  frame update. If the first-update path (`DSI_set_cmdq` waits with 2 s timeouts inside the
  no-break `_WaitForEngineNotBusy` loop, VDO-mode start) deadlocks, the hang is at the same
  visible point.
- The `0xFFE/0xFFF` vendor table encoding differs from this tree's older `0xFE/0x00` convention.
  The port reproduces the vendor literals and uses its own `push_table` — verified round-trip
  byte-exact against the blob (d18-report §2.2 "170 rows… PASS"), so this is low — but the
  *init* table never executes at boot anyway (only at suspend/resume/fbconfig), so a table bug
  cannot produce the reported logo hang.
- `LCM_setting_table` row size is 72 B in both blob and port (tiling proof) — struct-layout
  risk closed.

Confirmation protocol: if T2 (β) and T3 (β-touch) boot and T4 (β+touch+lcm) hangs, D18 is
convicted by elimination; instrument then (§5.4).

### H4 — D17 gsl touch-specific. **Prior ≈ 0.08.**

All gsl hardware traffic runs at `late_initcall` probe time — provably after the logo-clearing
step (i2c-0 adapter is registered by `mt_board_init`, late_initcall). The probe is fully bounded
(3-retry canary stage, ~1.5 s of sleeps on total-failure). It *cannot* produce the logo hang.
It could produce a *post-logo* stall (e.g., EINT polarity storm) — that's why β-touch (T3) is in
the ladder ahead of β+touch+lcm: it validates D17 on-device before D18 enters the test.

### H5 — D13/D14 amp. **Prior ≈ 0.04.**

`Audio_eamp_command` is reached only from `AudDrv_Kernel` ioctl handlers (userspace) and
NULL-guards the client; probe = 6 bounded smbus reads at `late_initcall`; `arch_initcall`
registration moves data only. Cannot hang the logo stage.

### H6 — D1–D12 (chargers/FGADC/cameras/lens). **Prior ≈ 0.08 (mostly D8–D12 compile-surface).**

D1/D2/D3/D7 remove code paths; D4 changes constants fed to bounded FGADC division (Q_MAX=2000 —
no div-by-zero); D8–D12 add drivers whose hardware paths open only from userspace. No logo-stage
execution. A *latent build-composition* bug (e.g., a symbol collision) cannot exist — any such
issue would corrupt identically across all images and would have been caught by link; runtime
effect nil until probe time.

---

### 3.2 (referenced above) — what each delta executes before `mtkfb_probe` completes

| Delta | First hardware-touching execution | Consequence for logo-hang |
|---|---|---|
| D1/D2 (chargers off) | none (compiled out) | none |
| D4 (FGADC Q_MAX) | battery_meter init, bounded auxadc calibration | none observed mechanism |
| D8/D9/D10 (sensor drivers/list) | camera open (userspace) | none |
| D11 (camera power) | camera open | none |
| D12 (lens dw9714/19) | no static board info ⇒ no boot probe | none |
| D13 (amp driver + eamp glue) | probe at `late_initcall` (i2c-2 adapter) | none pre-logo |
| D14 (amp board info) | `arch_initcall` — data registration only | none |
| D17 (gsl touch) | probe at `late_initcall` (i2c-0 adapter), bounded | none pre-logo |
| **D18 (LCM)** | mtkfb probe: `set_util_funcs`/`get_params`/name strcmp; then **shared SoC DSI engine init** — identical code α runs too | struct-work only; the risk is the shared DSI path (→H1a) |

---

## 4. The exact fix

There is no responsible "exact fix" that skips the two controlling flashes. The decision tree
below **is** the fix, with the concrete repair for each outcome; all repairs are small,
evidence-gated patches in the established D-serie s model — **no rebuild-from-scratch anywhere on
this tree** (§6).

**Step 0 (today, no device):** Forge builds the control image (§5, T0) — 10 minutes, no compile.

**Branch A — T0 (Lithium-payload repack) FAILS to boot.**
The bug is in the repack machinery, not in any kernel. Action: byte-diff the control against the
donor (they should differ only in NOTHING — T0 should be nearly byte-identical to
`~/q5-flash/rom/boot.img`; any diff is the bug). If T0 is byte-identical to the donor yet fails
on device, the flash *procedure* (partition/tool), not the image, is broken — stop and audit
Hera's flash path. Do not touch the kernel tree in this branch.

**Branch B — T0 boots, T1 (α) hangs at logo.**
Tree/board-config conviction. The repair is evidence-directed:
1. Capture the hang point: debug α image with `console=ttyMT3,921600n1 initcall_debug
   printk.time=1` (one-line cmdline change in the repack) + UART capture if pads are available;
   else AEE powerkey hang-dump / ram-console readback (§5.4 lists all three precisely).
2. The log names the stalled initcall — expected candidates per §3: the DSI/display path
   (H1a/H1b) or an even earlier SoC init. Fix = port the offending board value from Q5 ground
   truth (decode the vendor constant from the pinned Lithium blob, verbatim the D17/D18
   methodology) into `q5/…` as D19, or disable the offending subsystem at
   `q5_defconfig` level if it's not needed for the fork's goals (display is not optional —
   an LCD/DSI failure must be repaired, not masked).
3. Only after α boots: re-enter the ladder at T2.

**Branch C — T1 (α) boots (dark/garbage screen expected), T2 (β) hangs.**
Convicts D1–D16. Sub-bisect with two builds max: β-minus-(D13+D14) first (amp is the only one
with an arch_initcall), then β-minus-(D8–D12). The FGADC/charger edits (D1–D4) are constants/
removals and cannot hang early; do not waste flashes there.

**Branch D — T2 boots, T3 (β-touch) hangs → convicts D17.** Fix inside the gsl port:
prime suspects are probe-path behaviour on this board (EINT flow vs the blob's RISING evidence;
hwPowerOn rail order) — decode the exact vendor probe sequence from the blob (already
disassembled in d17-report §2.3) and diff against `mtk_gslX680.c` line by line.

**Branch E — T3 boots, T4 (β+touch+lcm) hangs → convicts D18 interaction.** Given D18's
boot-time code is struct-only, the conviction really means "the matched-name display path on
this tree". Repair: instrument the display path (debug cmdline + log capture), compare against
the Lithium kernel's observed `[LCM Auto Detect]/[LCM Specified]` trace; check whether the LK's
passed name exactly equals one of the two compiled names (any suffix/whitespace difference
routes to autodetect and the unbounded DSI reads — §3.1 mechanism). Possible pre-emptive
hardening (below) applies here too.

**Cross-cutting hardening patch (recommended regardless of branch, but only AFTER the first log
exists — do not shotgun):** bound the timeout-free DSI polls in `dsi_drv.c` (≈1606/1619/1629/1639)
with the same 100 ms `get_current_time_us` budget its sibling functions already use, and add a
`break` to the timeout arm of `_WaitForEngineNotBusy`'s while loop. This converts any future
"silent infinite hang at logo" into a bounded failure that either boots dark (diagnosable via
adb) or panics (auto-reboot → visible). This is risk-reduction instrumentation, **not** the root
cause fix; land it as its own D-id only when evidence says which branch we're in.

---

## 5. Minimal test plan (what to flash, in what order, what to observe)

Principles: **BOOT partition only; system stays the known Lithium`system.img` state between
tests; one variable per boot; every failure gets the same three evidence captures attempted
(§5.4); stock Mint restore procedure unchanged if anything goes wrong.**

### T0 — repack-control (no kernel compile; proves the repack machinery)
- Forge: extend `55_repack_boot.sh` with a `lithium-ctl` tag that packs **the donor's own
  kernel payload verbatim** (extract kernel region `boot.img[2048 : 2048+3809720]` from the
  pinned donor, re-pack it through the identical mkbootimg path/asserts). Expected output is
  byte-identical (or header-identical) to the donor image — the script's verify step should
  print `ksz` equal, not differing.
- Hera: flash `out/boot-m1b-lithium-ctl.img`, boot.
- **Pass** (Android boots, with the usual Lithium charging/audio bugs) ⇒ repack pipeline proven;
  proceed to T1. **Fail** ⇒ Branch A; do not flash α yet.

### T1 — α isolation (**the decisive bisect the task asks for, stated explicitly**)
- Flash `out/boot-m1b-alpha.img` (stock a106 build, **no deltas**).
- Expected-if-healthy: logo → screen changes (dark or garbage is *expected and fine* — α has only
  the a106 hx8369b LCM names and the Q5 LK passes `gc9503v_*`; the display path will miss/autodetect
  -fail) → Android comes up: `adb get-state` → `shell uname -r` = `3.10.54`, dmesg contains
  `[LCM Auto Detect]`/`[mtkfb]` lines. Touch absent is expected (GAP-1/D17 not in α).
- **Boots** ⇒ tree + a106-clone board config are sound on Q5 hardware; a **delta** broke
  β+touch+lcm — run the ladder T2→T4. **Hangs** ⇒ Branch B (tree/board-config); capture logs
  (§5.4) before anything else; the log names the fix.

### T2 — β (`out/boot-m1b-beta.img`) — only if T1 booted
Validates D1–D16 on device. Pass = same as T1 plus `bct24157|MAX17050SW6106|fan5405_config_interface`
absent in dmesg/sysfs; then T3.

### T3 — β-touch (`out/boot-m1b-beta-touch.img`) — only if T2 booted
Validates D17 alone on device. Pass = `0-0040` bound to `gsl_tp`, one `mtk-tpd` input, dmesg
`the test 0xb8 = {…}` + `------GSLX680_FW_*------` banner; touch functional enough to prove no
interrupt storm (boot completes, load average sane). Then T4.

### T4 — β+touch+lcm (`out/boot-m1b-beta-touch-lcm.img`) — the failing image
If reached (T1–T3 all boot) it convicts D18 by elimination (Branch E). If it *boots* this time,
the original hang was environmental (flashing/procedure/unit state) — rerun T4 once to confirm
before declaring it.

### 5.4 Evidence protocol — run on EVERY failure (mandatory, in this order)
1. **Hang vs reset-loop:** watch the logo ≥ 30 s. A ~5 s-periodic reset = panic
   (`CONFIG_PANIC_TIMEOUT=5`) — record it, that alone routes the branch; indefinite hang =
   busy-wait/deadlock.
2. **AEE powerkey hang-detect** (both fork and Lithium kernels have `CONFIG_MTK_AEE_POWERKEY_HANG_DETECT=y`
   + `MTK_RAM_CONSOLE` SRAM console + MRDUMP): on the hung screen, hold Power ~10–15 s to force a
   KE dump; then boot the known-good image and harvest `/sdcard/mtklog/aee_exp` + expdb.
3. **ram-console / last_kmsg:** after the hang, a *warm* reset into Lithium/Mint (avoid
   battery-pull between hang and readback; SP-Tool downloads may or may not preserve SRAM) and
   `cat /proc/last_kmsg` — the SRAM console lives at `0xF900DC00` (survives warm resets).
4. **UART (definitive, if test points are reachable):** debug image with
   `console=ttyMT3,921600n1 initcall_debug printk.time=1` appended to the cmdline (55 one-line
   change) — the LK + kernel will name the exact stalled initcall/driver. 921600 8N1, ttyMT3.
5. Deliver all captures with the flash report; without a log we are ranking hypotheses — with a
   log we are reading the answer.

### What NOT to do
- Do not flash intermediate images out of order (T3/T4 before T1/T0 is wasted evidence).
- Do not change kernel code before T0+T1 results exist (the two flashes halve the search space;
  code-first guesses would be unmotivated churn on a deterministic pipeline).
- Do not interpret "dark screen on α/β" as failure — it is the *predicted* healthy state for
  those images (a106 LCM names vs the Q5 panel).

---

## 6. Forge: fix vs rebuild — guidance

**Rebuild from scratch: nothing.** The pipeline (40/45/50/60/61/55) is deterministic,
hash-gated, reproducible across fresh object dirs; the four pinned images and their parity
reports are consistent with their committed patches. The D13 Makefile-hunk repair discovered in
D17 (fresh-dir β drift, 20-byte build-id-only delta) is already fixed and proven — keep it.

**Forge tasks now (build-side, no device):**
1. Add the `lithium-ctl` tag to `55_repack_boot.sh` (T0) — trivial, reuses existing plumbing.
2. Prepare (do not flash) the debug-cmdline variant capability (append
   `console=ttyMT3,921600n1 initcall_debug printk.time=1`) as a script flag — cheap, ready the
   moment any flash fails.
3. Have the DSI-timeout hardening patch drafted per §4 ("cross-cutting hardening") but **do not
   land it before evidence** names a branch — an unneeded patch on an unproven base is how
   bisects get confused.

**Do not "improve" board-config values preemptively.** Every q5 board value that was ever
validated was decoded from a pinned blob (D17/D18 model). Guessing DCT/GPIO values would create
exactly the class of bug we are hunting.

---

## 7. For Karen — validation baseline for the boot-debug loop

- **Acceptance per-branch:**
  - T0: boots to Android; `uname -r` 3.10.54; presence of known Lithium bugs (= control behaved
    exactly like the donor).
  - T1: reaches Android *or* a definitive log capture; dark screen ≠ failure. `adb shell uname -r`
    = 3.10.54 is the pass signal; documented `[mtkfb]`/LCM-autodetect dmesg expected.
  - T2/T3: same plus the per-delta observable sets already defined in forge-m1b/d17 reports
    (charger strings absent; `gsl_tp` bound; `mtk-tpd` present).
  - T4: full boot, `[LCM Specified] [gc9503v_wvga_dsi_vdo_hsd|boe]`, `480 x 800`, no reset-loop.
- **Failure classification gate (every image):** hang-forever vs ~5 s reset-loop must be recorded;
  it is the primary panic-vs-deadloop classifier and feeds §5 branch selection.
- **Edge cases to keep on the radar** (not this bug, documented so they are not rediscovered):
  ST7701S-panel Q5 unit (LK's other two names) would dark-screen a D18 kernel — only if a future
  unit shows `[LCM … st7701…]` in LK UART; α/β's guaranteed LCM-name miss → autodetect path with
  unbounded DSI reads (§3.1) means α/β hang-diagnosis and α/β healthy-boot-with-dark-screen are
  *both* possible outcomes — the discriminator is whether Android/adb comes up, not the screen.

---

## 8. Audit trail (static evidence cited above)

- Independent header parse of `~/q5-flash/rom/boot.img` + all four `out/boot-m1b-*.img`
  (struct unpack of `8s10I`, board @48, cmdline @64): §2.1 table.
- `arch/arm/mach-mt6582/{Makefile.boot,include/mach/memory.h}`; `mt_devs.c:1108 mt_fixup`.
- `.config` dumps from `build-alpha|beta|beta-touch|beta-touch-lcm` (XZ, VMSPLIT_3G, HIGHMEM,
  CMDLINE_FROM_BOOTLOADER, MT6582 SERIAL console, AEE/RAM_CONSOLE/PANIC_TIMEOUT=5).
- Initcall levels: `mtkfb.c:3541 module_init`; `dual_ccci/ccci_init.c` device_initcall_sync;
  `arch/arm/mach-mt6582/board.c:47 late_initcall(board_init)` → `mt_devs.c:1556 mt_board_init`
  → i2c/msdc platform devices; `D14 arch_initcall`; `gslX680 module_init(tpd_driver_init)`;
  `AudDrv_Kernel.c:3334-3439` (EAMP ioctl-only callers).
- DSI unbounded waits: `dsi_drv.c` ≈1606/1619/1629/1639 (read path), `_WaitForEngineNotBusy`
  non-breaking timeout loop ≈530; sibling 100 ms timeout pattern ≈1389-1421.
- LCM name flow: `disp_hal.c:706-788 disphal_get_lcm_driver` (name match skips compare_id;
  NULL-name autodetect runs `init_dsi`+compare_id per driver), `disp_drv.c:680-773`
  (`isLCMFound` pinned on any `lcm=?-` name), `mtkfb.c:2515-2551, 2808-2817`.
- Boot-time LCM init is *not* executed: `lcm_drv->init()` callers = fbconfig debug only
  (`disp_drv.c:3243`).
- DCT audit: `q5/dct/dct/pmic_drv.c` (empty custom init), `codegen.dws` presence,
  `cust_gpio_boot.h` (1200 lines, a106-generated), `partition/cust_part_mbr.c` (12 Mi PMT base).
- Lithium vendor facts: banner `(wangliang@innioasis117) #3 … 2024-01-26`; build tree root
  `/home/sdb/wangliang/mt6582_5/kernel-3.10/`; LK `lk-q5.bin` strings incl. the four LCM names,
  `%s lcm=%1d-%s`, sec_img_verify strings (inert per §2.1 reasoning); memory-string inventory
  ddr/emi/mblock/md32 comparable (§2.2).
- Scatter: `out/scatter-fork.txt` BOOTIMG partition 0x1000000 (16 MB) — all images fit.

**Bob's final word:** the engineering has been careful; what is missing is *one byte of device
evidence* — whether the stock α kernel boots this board. Flash T0, then T1, capture the log, and
bring the result back. Every subsequent step is already on rails.
