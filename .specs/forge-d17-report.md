# Forge — D17 implementation report (GSL touch driver port — GAP-1 close)

**Task:** `.specs/forge-d17-task.md` (hard gate: *no flash without touch*); spec context
`bob-m2-spec.md` §1.4 (GAP-1), `hardware-facts-q5-mint.md` §2.5 (I2C map).
**Status: COMPLETE — β-touch kernel built, parity PASS (gsl strings present + full m1b-β set
intact), `out/boot-m1b-beta-touch.img` packed & hash-pinned; m1b β/α artifacts untouched;
NO flashing performed.** Commit: `b70087b` (`patches/kernel/D17.patch`, D17 in the message).

---

## 0. Session log (incremental)

- Working from m1b HEAD `10478ce`. Scratch: `~/.hermes/cache/scratch/opencode/forge-d17/`.
- Forensic tooling: rebuilt the pinned Lithium decomp into a symbol-aware ELF with
  `vmlinux-to-elf` (48,393 kallsyms symbols @ base `c0008000`; `CONFIG_KALLSYMS_ALL=n` so
  data symbols absent — recovered by disassembly instead), disassembled the gsl driver
  region (`c034b000–c0364000`) with the in-tree arm-eabi-4.8 objdump, and decoded every
  Q5-relevant constant before writing a single line of port code.

## 1. Donor selection (task step 1)

Priority order from the task, checked in the cloned trees:

| Donor (as instructed) | GSL driver? | Finding |
|---|---|---|
| `atharvnegi/kernel_xiaomi_selene` | ✗ | `drivers/input/touchscreen/mediatek/gslX680/` = **Makefile stub only** (dead ref, no sources) |
| `CyanogenMod/android_kernel_mediatek_sprout` | ✗ | tpd framework (`arch/.../touchpanel/`) with GT818B/GT9XX/cy/ft/msg13/synaptics only |
| `PersimmonProject/android_kernel_archos_persimmon_3_10` | ✗ | ft/cy/ektf/GT/generic families only |
| `bq/aquaris-E5FHD` | ✗ | cy/eeti/ektf/ft/GT/gn_melfas only |
| `carlitros900/android_kernel_archos_oxygen` (**already the D10 GC5004 donor**) | ✓ | **complete `gslX68X` tpd driver**: `mtk_gslX680.c` + `gsl_point_id*.c` + `Makefile` + ac70ox/ac101box board configs |

Public-source coverage of the *exact* firmware variant: zero. Sourcegraph global code search
for `GSLX680_FW_DSJ` and `GSLX68X_FW_JX` (both distinct spellings visible in the Lithium
blob) → **0 hits** each; GitHub code search is login-walled and grep.app indexes none. The
T-ROM/Q5 lineage kernel source is unpublished.

**Donor used:** oxygen @ `ed79b470265fc4d997de8c7be020792322c8b4dc` (revision already pinned
in `manifests/kernel-sources.sha256` as the GC5004 anchor). Consumed files, materialized and
hash-pinned as `donors/gslX680/*`:

- `drivers/input/touchscreen/mediatek/gslX68X/mtk_gslX680.c` → driver skeleton
- `drivers/input/touchscreen/mediatek/gslX68X/gsl_point_id_point_active_pen_no_gesture.c`
  → `gsl_point_id.c` (exports exactly the blob's non-gesture set: `gsl_alg_id_main`,
  `gsl_mask_tiaoping`, `gsl_DataInit`, `gsl_version_id`)
- `drivers/input/touchscreen/mediatek/gslX68X/Makefile` → dir makefile structure
- ac70ox `mtk_gslX680{,_public,_factory}.h` + 3 fw headers → **pinned for audit only**
  (the port does NOT use their firmware — see §2)

The task's fallback ("any MT6582 3.10.54 tree with a GSL driver") did not need to be
exercised online: oxygen is an mt8163/3.10-family tree of the same silead lineage whose
register protocol, tpd interface and proc interface match the Lithium blob's compiled
driver symbol-for-symbol (`gsl_load_fw/gsl_start_core/gsl_clear_reg/gsl_reset_core/
gsl_read_interface/gsl_write_interface/gsl_config_read_proc/gsl_config_write_proc/
gsl_test_i2c/gsl_probe/gsl_remove/gsl_resume/…` all present in both).

**NOT a mainline-DT `silead.c` port** (as instructed): the silead mainline driver has no
tpd framework, no multi-config firmware, and a different I2C lifecycle.

## 2. Q5 ground truth — forensics on the pinned Lithium blob

All facts below were decoded from the pinned `donors/lithium-kernel.decomp`
(`d284ba1698c77267…`, kernel blob `5217dd41…`) and cross-checked; **nothing invented**.

### 2.1 Driver identity and I2C binding

- kallsyms symbol `gsl_device_id` (= the classic silead `tpd_i2c_id` table) sits **on the
  string `"gsl_tp"` itself** (VA `0xc0886914`) → the bound i2c driver name is `gsl_tp`,
  matching the live device `0-0040 gsl_tp` (hardware-facts §2.5).
- The blob's board i2c-0 table (VA `0xc0b0af98+`) carries `{"gsl_tp", .addr=0x40}`,
  `{"Hyn_device", 0x5a}`, `{"Hyn_device_cst2xx", 0x5d}` — **byte-for-byte the live Mint
  I2C map** (0-0040 gsl_tp, 0-005a Hyn_device, 0-005d Hyn_device_cst2xx).
- Id aliases `"gsl1680"` + `"gsl915"` exist in the same rodata (classic silead id names)
  → carried into the port's `i2c_device_id` table.
- `TPD_DEVICE` stays `"mtk-tpd"` (shared tpd core string `"mtk-tpd: …" present in blob) —
  same as this tree's `tpd.h`, so the input device keeps the stock name.

### 2.2 Panel firmware — the make-or-break part

The blob links **five** `struct fw_data {offset,val}` firmware arrays plus a check array,
all as an exported `gsl_cfg_table[5]` @VA `0xc0884a64` (16 B entries:
`{fw*, fw_count, cfg_data*, cfg_size}`):

| cfg | banner (printed by `gsl_sw_init`) | fw @VA | entries | tuning words @VA |
|---|---|---|---|---|
| 0 | `------GSLX680_FW_HW------` (default/unknown/fp→2) | `0xc08a3c6c` | 5049 | `0xc0b76dfc` |
| 1 | `------GSLX680_FW_DSJ------` (fp→1 **and** fp→4) | `0xc08ada34` | 4851 | `0xc0b765fc` |
| 2 | `------GSLX680_FW_WL------` (fp→3) | `0xc089a0b4` | 4983 | `0xc0b75dfc` |
| 3 | *(no sw_init path selects it in this build)* | `0xc08904fc` | 4983 | `0xc0b755fc` |
| 4 | `------GSLX680_FW_JX_2------` (fp→6 / no-match) | `0xc0886944` | 4983 | `0xc0b74dfc` |

Plus `GSL_TP_CHECK_FW` (957 entries @`0xc0884ab4`, bounded by the kallsyms-anchored next
symbol `gsl_seq_fops`). **Integrity proof: the five arrays tile the fw data region exactly**
(each array ends where the next begins — verified programmatically by the extractor).

*Why this matters*: these arrays are the per-panel microcode downloads. Using another
device's config (the donor's ac70ox GSL3670 firmware) would probe ack on i2c but tune the
wrong panel → dead or garbage touch. No public source carries them, so they were extracted
byte-exact by `build/extract_gsl_fw_from_blob.py` (hash-asserts the decomp against the
manifest; tiling + bounds + banner self-checks; deterministic output
`gslX680_fw_q5.h` 699,049 B / `gslX680_key_q5.h` 34,253 B).

### 2.3 Config autodetect (the chip chooses its own firmware)

`gsl_sw_init` disassembly (blob `c034d7ac…dc38`):

```
1. GPIO14 reset pulse (mode0/out, low → msleep(20) → high → msleep(20))
2. gsl_test_i2c(); abort on failure
3. if config未selected: up to 3× { clear_reg; reset_core; load_fw(GSL_TP_CHECK_FW, 957);
   start_core; msleep(200); read reg 0xb4; if (buf[2]|buf[3]<<8) > 1 → canary answered }
4. msleep(20); read 4 B reg 0xb8 = fingerprint; print "the test 0xb8 = {0x..%02x×4}"
5. score 6 constants: score = 100·popcount(fpᵢ & ~f) + popcount(fpᵢ ^ f)
   fp table = { 0xffc07807, 0xff81f80f, 0xff807807, 0xff80780f, 0xff80fc01, 0xff807c07 }
   → min score wins, first match in cascade order 1..6; no match → 6 (JX_2)
6. banner cascade {1,4→DSJ, 2/0/unknown→HW, 3→WL, 6→JX_2}; then
   clear_reg → reset_core → io_control → load_fw(cfg[sel].fw) → io_control → start_core
```

gsl_start_core (@`0xc034c7d0`) = 4-byte zero write to 0xe0 + `gsl_DataInit(cfg[sel].cfg_data)`
(no sleeps). `check_mem_data` = read 4 B reg 0xb0, byte0==0x5a ⇒ firmware alive, else full
init. **The port implements this algorithm verbatim** — the chip reports its own fingerprint
at runtime, so the fork needs no compile-time panel choice.

### 2.4 Board wiring (GPIO/EINT/power) — the cross-check the task demanded

| Signal | Blob evidence (disassembly) | Reference tree | Cross-check |
|---|---|---|---|
| Reset pin | `mt_set_gpio_out(0x8000000E, 0/1)` + `mt_set_gpio_mode/dir` | `GPIO_CTP_RST_PIN = (GPIO14 \| 0x80000000)` in `q5/dct/dct/inc/cust_gpio_usage.h` | **exact match (0xE = 14)** — file NOT modified |
| INT pin | `mt_set_gpio_mode/dir(0x80000002)` + pull-enable/pull-up | `GPIO_CTP_EINT_PIN = (GPIO2 \| 0x80000000)` | **exact match (0x2 = 2)** — file NOT modified |
| EINT channel | `mt_eint_registration(2, flag=1, handler, auto=1)` (probe | `CUST_EINT_TOUCH_PANEL_NUM 2` in q5 `cust_eint.h` (unchanged) | **num matches (2)**; flag=1 = `EINTF_TRIGGER_RISING` per `mach/eint.h` — the a106-clone TYPE default (FALLING, the FT panel's) is overridden by the driver's `TPD_EINT_FLOW` |
| Power | `hwPowerOn(25, 1800, "TP")`, `hwPowerOn(31, 2800, "TP")` (+ MT6323-enum spellings = same rails fired twice, defensively) | `MT65XX_POWER_LDO_VIO28`=25, `MT65XX_POWER_LDO_VGP1`=31 (`mt_pm_ldo.h`); in-tree ft5336 uses the identical `hwPowerOn(…, VOL_*, "TP")` convention | **rails = VIO28@1.8 V + VGP1@2.8 V**, port fires each once |

So the task's "`cust_gpio_usage.h` touch GPIO wiring" landed as a **verification, not an
edit**: the a106-lineage DCT already declares exactly the pins the Q5's compiled driver
uses (both `cust_gpio_usage.h` and `cust_eint.h` stay byte-identical — asserted by 60).
No GPIO was invented; every number traces to the blob's compiled constants and matches the
vendor header lineage.

## 3. The port (task step 2) — files & wiring

`patches/kernel/D17.patch` (one file, D17 in the prologue) adds/changes:

1. `arch/arm/mach-mt6582/q5/touchpanel/gsl_tp/tpd_custom_gsl_tp.h` (new) — board glue with
   the full evidence table in its header comment: name/address, power sources, EINT flow.
2. `drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.c` (new, ~1,080 lines) — the
   adapted driver: donor skeleton; blob-locked init (`gsl_sw_init` autodetect, `check_mem_data`,
   `gsl_load_fw(client,fw,count)`), GPIO/EINT/power per §2.4, `i2c_register_board_info(0,
   {"gsl_tp",0x40})` self-registration (the in-tree ft5336/gt9xx convention — same pattern
   as D14's amp; the vendor i2c adapter scans static board info at adapter-probe time, so
   module_init-level registration is the tree's proven mechanism), report path = donor's
   NOID protocol (0x80 counter + 0x84… incremental reads + `gsl_alg_id_main` filter +
   `gsl_mask_tiaoping` writeback), suspend/resume via earlysuspend (`struct early_suspend *`
   signatures per this tree's tpd core), `/proc/gsl_config` debug interface with the blob's
   write semantics on the active config's 512-word buffer.
3. `drivers/input/touchscreen/mediatek/gslX680/gsl_point_id.c` (new) — donor point-id unit.
4. `drivers/input/touchscreen/mediatek/gslX680/gslX680_fw_q5.h` / `gslX680_key_q5.h` (new,
   GENERATED) — the extracted firmware/tuning data (§2.2).
5. `drivers/input/touchscreen/mediatek/gslX680/Makefile` (new) — ccflags for the q5 board
   glue dir; builds `gsl_point_id.o` + `mtk_gslX680.o`.
6. `drivers/input/touchscreen/Kconfig` (+10) — `TOUCHSCREEN_MTK_GSL_TP` entry.
7. `drivers/input/touchscreen/mediatek/Makefile` (+5) — dir selection.
8. `arch/arm/configs/q5_defconfig` (+2) — `CONFIG_TOUCHSCREEN_MTK_GSL_TP=y`.

**Build-system note (task's "CONFIG_CUSTOM_KERNEL_TOUCHPANEL" wording):** that Kconfig
symbol does not exist anywhere in the heyrudra 3.10.54 tree (grep over the whole tree: zero
references) — the m1b report already documented the a106 defconfig never sets it. The tree's
actual driver-selection mechanism is `CONFIG_TOUCHSCREEN_MTK_<driver>` per mediatek
touchscreen dir, used exactly like the in-tree drivers do. Likewise "tpd_custom.c/
tpd_default.c registration": this tree's `tpd_default.c` is a shared dummy stub (kept
untouched); the registration glue of this tree lives in (a) the board config header +
(b) the driver's self-registration — which is what D17 implements, faithful to the tree's
own drivers rather than to a newer-ALPS file layout that this tree doesn't have.

## 4. Build + parity (task steps 4–5)

Pipeline: new `build/60_kernel_delta_touch.sh` = the m1b-β sequence (D1…D16 patches) with
D17 applied after, built into a **separate O dir `build-beta-touch`**, extended δ-parity,
then `55_repack_boot.sh beta-touch`. The pinned m1b-β pipeline (50) is unchanged apart from
additive hygiene (see §6).

- **β-touch zImage**: 4,264,072 B, sha256
  **`362503c006c5d6ada1922cdd74582554cf58d6f643e5fcda1ed55e5237f0ff75`**
- **β-touch Image**: 14,104,872 B, sha256
  `331012d3803ac1ad0d4a53cb7278cea187e29d898f5e5fc469060721a3f137f1`
- Banner (pinned identity): `Linux version 3.10.54 (forge@fork) (gcc version 4.8 (GCC)) #1 SMP PREEMPT 2026-11-25T13:47:27-06:00`
- **Determinism**: 60 run twice — identical zImage sha both times; 50 re-run twice after the
  D13 repair — identical sha both times. Fresh-O-dir rebuild also reproduces (`9906e184…`).
- **δ-parity `out/kernel-parity-beta-touch.txt`** (grep -ic line hits):

| D17 must-have | β-touch | Lithium blob | verdict |
|---|---|---|---|
| `gsl_tp` | 19 | 3 | ✓ (port's own prints/logs added) |
| `gsl1680` / `gsl915` | 1 / 1 | 1 / 1 | ✓ exact id-name parity |
| `gslX680` / `GSLX680_FW` | 4 / 4 | 4 / 4 | ✓ **all four firmware banners present** |
| `gsl_alg_id_main` | 1 | 1 | ✓ |
| `gsl_config` | 3 | 2 | ✓ proc interface |

| β-carry-over (no regression) | β-touch | m1b-β (pinned report §2.3) | verdict |
|---|---|---|---|
| gc5004mipiraw / hi253yuv / hi704yuv | 2 / 6 / 7 | 2 / 6 / 7 | ✓ identical |
| dw9714 / dw9719 | 28 / 53 | 28 / 53 | ✓ identical |
| `aw87559_pa` | 3 | 3 | ✓ identical |
| ccci / mali / mt6323 / mtk-kpd / auxadc | 750 / 809 / 19 / 1 / 210 | 750 / 809 / 19 / 1 / 210 | ✓ identical |
| battery_meter+[FGADC] | 24 | 24 | ✓ identical |
| must-not `bct24157` / `MAX17050SW6106` / `fan5405_config_interface` | 0 / 0 / 0 | 0 / 0 / 0 | ✓ (D1/D2/D3/D7 still hold) |

Parity verdict: **PASS — the touch delta is purely additive; every m1b-β count unchanged.**

### 4.1 Repacked image (task step 5)

`build/55_repack_boot.sh beta-touch` → **`out/boot-m1b-beta-touch.img`**:

- **Size: 5,662,720 B, sha256 `2c6d575307ae8fbd11ef49464b7b43eb73c45670e0f30d411cc1f8226b59d7d0`**
- Header fields byte-identical to Lithium's donor except kernel size (4,264,584 = 512 +
  4,264,072), verified in-script; **ramdisk region byte-identical** to the donor blob
  (`c0be6c46…`, E4 ✓); re-run of 55 reproduces the image byte-for-byte.
- `out/boot-m1b-beta.img` (`2c3ac47a…`) and `out/boot-m1b-alpha.img` (`d886ccfe…`) are
  **untouched** — kept for comparison, as instructed.

## 5. Pipeline corrections made during D17 (logged, not spec deviations)

1. **D13.patch Makefile-hunk defect (m1b latent bug, repaired as part of D17's clean-state
   proof).** The committed D13 hunk emptied `q5/sound/Makefile` (`@@ -1,5 +0,0 @@`) instead
   of adding the amp line.  Masked so far because `build-beta/` still held the original
   session's `sound/built-in.o`; any *fresh* build dir would fail
   (`ld: cannot find …/q5/sound/built-in.o` — reproduced by β-touch's first run).  Repair:
   the hunk now adds `aw87559_pa.o` exactly as the m1b report documented ("q5 sound
   Makefile line"), object order `yusu_android_speaker.o aw87559_pa.o` verified against the
   original session's `.built-in.o.cmd`.  **Effect on m1b-β content: none** — the fresh β
   Image diffs against the pinned session β Image in exactly **20 bytes**, which are the
   `.note.gnu.build-id` description (a vmlinux-metadata hash over symtab bytes, not shipped
   Image content); all other bytes identical.  Consequence: fresh-dir β = zImage
   `9906e184b77bb57da44bdfe1ba2d401a883a09ae17b619925fd1e0f74f09861f` (Image
   `b61c5a783ded78666bf93e73969c35074b1a80cd5c61be2bb1c653ba5b722db7`, deterministic over
   repeated runs).  The committed m1b tag artifacts on disk stay the m1b bytes
   (`out/boot-m1b-beta.img` = `2c3ac47a…` verified).  Also proved: the DCT/PTGEN
   regenerated headers embed only a *comment* timestamp — no compiled content — so
   fresh-vs-incremental differences reduce to the build-id note.
2. **O-dir mkdir guards** in 50/60 (kbuild's `O=` requires the dir to pre-exist; the m1b
   scripts assumed the session's dirs).  Fresh-checkout reproducibility now holds end to end.
3. 50's reset now also clears the D17 paths and whitelists `build-beta-touch` (both additive;
   m1b-β behavior unchanged).

## 6. Risks & open items (for Bob/Hera; no blocker found in evidence)

- **Panel-fingerprint selection is chip-driven**: the Q5's chip reports its firmware class
  at probe (reg 0xb8) and the port loads exactly that config from the Q5's own extracted
  firmware.  G-boot dmesg will show `the test 0xb8 = {…}` + the selected
  `------GSLX680_FW_*------` banner — collect it for the record and for debugging.
- The `0x80000000|gpio` flag encoding and `CUST_EINT` mapping follow the MT6582 vendor
  API; if the panel's INT polarity were inverted on the live device, the one-line
  adaptation point is `TPD_EINT_FLOW` in `tpd_custom_gsl_tp.h` (blob compiles RISING;
  in-tree a106 FT default was FALLING) — a G-boot symptom-level decision, not a guess.
- The touch input device will present as `mtk-tpd` (shared core name, same as the
  blob's).  Hera's G-gate compares the *input devices list* — expect one gsl-bound i2c
  client `0-0040` bound to `gsl_tp` + one `mtk-tpd` input node.
- Not ported: the blob's exported gesture symbols (`gsl_GestureBuffer`, `gsl_GestureExtern`,
  `gsl_obtain_gesture`) — the full-image disassembly shows **zero call sites** for them in
  the driver paths; the donor's non-gesture point-id unit provides everything the report
  path uses.  If the T-ROM HAL pokes gesture modes later, that becomes an evidence-gated
  follow-up (donor variant swap in `gsl_point_id.c`).
- The donor variant's HIGH_SPEED_I2C/DMA i2c specializations are not present in this tree's
  config; the port uses plain vendor-i2c msg transfers (chunk ≤ 128 B; the mt6582 i2c core
  DMA-copies anything > `I2C_FIFO_SIZE` internally — verified in `drivers/misc/mediatek/
  i2c/mt6582/i2c.c:1062`), matching how the in-tree ft5336 works on this platform.

## 7. Artifacts & bookkeeping

- `patches/kernel/D17.patch` (D17 in prologue + commit message `b70087b`); donor pins +
  extracted-firmware provenance bytes appended to `manifests/kernel-sources.sha256`
  (`donors/gslX680/*`); `build/extract_gsl_fw_from_blob.py` kept as the provenance
  generator (deterministic, hash-gated).
- `out/kernel-parity-beta-touch.txt` — the parity report quoted in §4.
- `out/boot-m1b-beta-touch.img` — **5,662,720 B, sha256 `2c6d575307ae8fbd11ef49464b7b43eb73c45670e0f30d411cc1f8226b59d7d0`**
- Untouched: `out/boot-m1b-beta.img` (`2c3ac47a25ae89b049ba518354747a7365f6a8d5939548fba05f16c8fa51e0cc`),
  `out/boot-m1b-alpha.img` (`d886ccfedaaf02d7244a339ed4bb9a8f73f4e1be8327fe88e26633e13579f224`).
- `git ls-files` contains no kernel tree, no `.img`/`.bin`; `.specs/`, `donors/`, `out/` are
  gitignored per repo policy.

**Hera hand-off:** the flash candidate for the combined gate is now
`out/boot-m1b-beta-touch.img` (BOOT only, system = stock Lithium).  Expected on boot:
`uname -r` 3.10.54, `0-0040` bound to `gsl_tp`, one `mtk-tpd` input device, dmesg
`------GSLX680_FW_*------` banner naming the chip-selected firmware config.  No flashing
performed by Forge — Flash is Hera's gate.
