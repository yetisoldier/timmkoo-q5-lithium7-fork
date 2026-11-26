# Bob — M2 Specification: M1b Kernel Rebuild (Camera + Charging)
## Q5 Lithium 7 Fork — 3.10.54 MT6582 kernel with Q5 Mint board config

**Status: DESIGN COMPLETE — 2026-11-25**
**Author:** Bob (Principal Software Architect) — M2 design
**Inputs:** `.specs/bob-m1-spec.md` (§1.4 ADR-3, §1.6 ADR-5, §1.7 ADR-6, §2.7),
`.specs/q1b-kernel-source-decision.md`, `.specs/hardware-facts-q5-mint.md`,
`.specs/hermes-release-plan-v0.1.0-combined.md` (combined release — no M1a alone)
**Scratch evidence dir (not committed):** `/home/yetisoldier/.hermes/cache/scratch/opencode/bob-m2/`
- `mint-kernel.decomp` — sha256 `7738bd77…` (Mint 3.4.67 decompressed zImage, from bob-m1/mint)
- `lithium-kernel.decomp` — sha256 `d284ba16…` (Lithium 3.10.54 decompressed zImage, from bob-m1/lithium)
- `mint-strings.txt` (62,215 lines), `lithium-strings.txt` (57,968 lines)

---

# 1. CHOSEN KERNEL TREE

## 1.1 Selection

**Chosen: `heyrudra/android_kernel_micromax_a106`** (Micromax A106 "Unite 2" CM-style tree)
Cloned `--depth 1` to `.reference-kernel-3.10.54/` (already covered by `.gitignore` pattern
`.reference-*/`).

## 1.2 Version proof

`kernel-3.10/Makefile`:
```
VERSION = 3
PATCHLEVEL = 10
SUBLEVEL = 54
EXTRAVERSION =
NAME = TOSSUG Baby Fish
```
→ kernel version **3.10.54**, exactly matching the Lithium blob `5217dd41…` (`Linux version 3.10.54`).

## 1.3 Completeness proof

| Requirement (per task) | Status | Location |
|---|---|---|
| MT6582 arch/platform | ✔ | `arch/arm/mach-mt6582/` (two boards: `a106/`, `2014011/`) |
| Power: `drivers/misc/mediatek/power/mt6582/` | ✔ | `charging_hw_fan5405.c`, `charging_hw_pmic.c`, `fan5405.c`, `bq24158/bq24196/…`, `pmic_mt6323.c`, `battery_meter_hal.c`, `upmu_common.c` |
| Board config layer | ✔ | `arch/arm/mach-mt6582/<board>/` — `power/cust_battery_meter.h` + `cust_battery_meter_table.h` + `cust_charging.h` + `cust_pmic.h`, `keypad/mtk_kpd.h`, `camera/camera/kd_camera_hw.c`, `dct/dct/inc/cust_gpio_usage.h` + `cust_kpd.h` + `cust_power.h` + `cust_adc.h` + `cust_eint.h` |
| Defconfig | ✔ | `arch/arm/configs/a106_defconfig` (+ `2014011_defconfig`) |
| Sensor list | ✔ | `drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.[ch]`; `kd_imgsensor.h` already defines `HI253_SENSOR_ID 0x0092`, `HI704_SENSOR_ID 0x0096`, `SENSOR_DRVNAME_HI253_YUV "hi253yuv"`, `SENSOR_DRVNAME_HI704_YUV "hi704yuv"` |
| Lens/AF framework | ✔ headers / ⚠ sources | `drivers/misc/mediatek/lens/mt6582/inc/DW9714AF.h`, `DW9718AF.h`, etc.; Makefile references `mt6582/dw9714af/` but **subdir is absent from the tree** (dead Makefile ref) — donor port needed |
| Sensor driver sources (Mint set) | ✗ by design | Tree ships ov5648/hi258/s5k3h2yx/ov9760 only. `gc5004_mipi_raw`, `hi253_yuv`, `hi704_yuv`, `dw9714af`, `dw9719af` = port inputs (donors enumerated in §3.6) |
| Toolchain | ✔ **in-tree** | `.reference-kernel-3.10.54/arm-eabi-4.8/` (gcc 4.8, the same major version as the innioasis117 build) |
| Build flow | ✔ | standard kbuild: `make a106_defconfig && make zImage` (ALPS wrapper `build.sh` present but not required) |

**Rejected candidate:** `MTK-Kernels/android_kernel_mediatek_mt6582` — cloned first, `kernel/Makefile`
is VERSION=3 PATCHLEVEL=4 SUBLEVEL=67 (KitKat-era, not 3.10.54); single branch. Directory removed.
Remaining Q1b candidates (s0rd3s Lenovo, Ultimate-1 Senseit, assusdan Huawei) not needed.

## 1.4 Board-config model translation (M1 §2.7 → this tree)

M1 §2.7 described the ALPS layout (`mediatek/custom/<proj>/`, `ProjectConfig.mk`). This tree is the
CM-reorganized equivalent — the port maps 1:1:

| ALPS (M1 §2.7 terminology) | This tree (actual edit points) |
|---|---|
| `mediatek/config/mt6582/ProjectConfig.mk` | `arch/arm/configs/q5_defconfig` (`CONFIG_CUSTOM_KERNEL_IMGSENSOR`, `CONFIG_MTK_FAN5405_SUPPORT`, `CONFIG_MTK_SMART_BATTERY`, `CONFIG_ARCH_MTK_PROJECT`, …) |
| `mediatek/custom/<proj>/kernel/…` | `arch/arm/mach-mt6582/q5/` (new board dir, cloned from `a106/`) |
| `cust_battery.h` / `cust_battery_meter.h` / `cust_fuel_gauge.h` | `arch/arm/mach-mt6582/q5/power/cust_charging.h` · `cust_battery_meter.h` · `cust_battery_meter_table.h` |
| `cust_kpd.h` | `arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h` + `arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h` |
| `cust_gpio_usage.h` | `arch/arm/mach-mt6582/q5/dct/dct/inc/cust_gpio_usage.h` |
| `kd_sensorlist.h` + imgsensor dirs | `drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.h` + new driver dirs |
| `lenslist` | `drivers/misc/mediatek/lens/mt6582/` (+ defconfig `CONFIG_MTK_LENS_*`) |

---

# 2. MINT BOARD-CONFIG EXTRACTION (3.4.67 binary ground truth)

Method: `strings -a` over the decompressed Mint zImage + targeted binary scans. Decompressed Mint
blob = 10,908,740 B, sha256 `7738bd77…` (scratch).

## 2.1 Charger selection — Mint has NO external charger IC [RECOVERED]

| String family | Mint blob | Lithium blob |
|---|---|---|
| `fan5405` / `bct24157` / `bq2415x` / `bq242xx` / `ncp185x` / `rt9536` | **0 hits** | 29 × `fan5405`, 13 × `bct24157` (+ `fan5405_config_interface`, `bct24157_hw_component_detect`, `charging_enable` glue) |
| `max17050` / `sw6106` gauge driver | **0 hits** | 12 × `MAX17050SW6106` (probe/resume/suspend strings + `mediatek,MAX17050SW6106` compatible) |
| PMIC `mt6323` | ✔ 25 hits | ✔ 25 hits |
| Generic charger thread | ✔ `charging_hw_init`, `Charger_Detect_Init/Release`, `[BAT_thread]Cable in/out`, `upmu_is_chr_det` | ✔ (same family) |

**Conclusion (ADR-3 ground truth):** the Mint kernel drives charging via the MT6323 PMIC +
**autonomous SW6106** (power-bank SoC charges without host control). The correct M1b config is
**pmic-only** (`charging_hw_pmic.c`): no charge-enable I2C/GPIO traffic may touch the charger path.

## 2.2 Fuel gauge — MTK FGADC (SW fuel gauge) [RECOVERED]

Mint blob (lines from `mint-strings.txt`):
- `battery_meter` driver set: `[battery_meter_probe] probe`, `[battery_meter_driver] Initialization : DONE`,
  `[battery_meter_initial] SOC_BY_SW_FG done` → the KK `battery_meter.c` SW fuel gauge.
- FGADC: `[FGADC] fgauge get ZCV profile : fail !`, `[FGADC] fgauge get R-Table profile : fail !`,
  `[FGADC] gFG_capacity_by_v=%d`, `[FGADC] gFG_15_vlot = %dmV (over range, reset to 3700)`,
  `[FG] g_fg_dbg_bat_volt : %d`, `[fg_batt_crrnt]:%d [batt_vol]:%d [batt_temp]:%d`.
- No `.ko` / no NVRAM-path strings for the profile ⇒ profile tables are **compiled in**
  (`cust_battery_meter_table.h` equivalent) and refined at runtime (standard MTK FGADC learning).

**Numeric tables NOT recoverable:** exhaustive pattern scans of the stripped blob for the compiled
FGADC profile (100-pt monotonic voltage ramps as u16 runs, u32 runs, and {percent,voltage} pair
tables, offsets over the full 10.9 MB) returned **zero candidates**. The 3.4.67 DCT-compiled tables
are not recognizable without symbol info, and deep reverse-engineering (xref analysis from the FGADC
code strings) has poor ROI vs. the fallback below.

**Fallback design (standard MTK practice, adequate for this device):**
1. Start from the tree's generic MT6582 FGADC profile shape (`cust_battery_meter_table.h` already
   ships 4 × 100-pt temperature ZCV profiles + R-table + NTC `Batt_Temperature_Table`). SOC-by-voltage
   depends on cell chemistry (generic 3.7 V Li-ion curve), **not** on board specifics.
2. `Q_MAX` (capacity) values: set from the **physical battery label** (open question OQ-2 — Eric reads
   the cell's printed mAh) or start at the Q5-class default (~2000 mAh); MTK `fg_qmax_update_for_aging`
   self-learns Qmax over charge cycles, so initial error only affects the *slope*, not monotonicity.
3. NTC table: keep the MTK default NTC curve (10 kΩ-class, universal across MT6582 trees — including
   Mint's own: no custom NTC strings found). Gate G3 verifies `bat_temp` reads plausibly (~ambient).
4. FG meter params (`R_FG_VALUE`, `fg_meter_resistance`, sense resistor): Q5 uses the standard MT6323
   sense network (20 mΩ, matching `drivers/misc/mediatek/power/mt6582/battery_meter_hal.c` defaults);
   verify at G3 by watching SOC slope sanity while charging.

## 2.3 Camera sensor set [RECOVERED]

From `zhaoshaopeng add SENSOR_DRVNAME_*` power strings in the Mint blob (the ODM's camera debug
prefix — matches M1 E8):

| Role | Sensor (DRVNAME) | Evidence |
|---|---|---|
| Main (rear, if fitted) | `GC5004_MIPI_RAW` ("gc5004mipiraw") | `SENSOR_DRVNAME_GC5004_MIPI_RAW power on/off` strings |
| Sub (front — the defect fix) | `HI253_YUV` ("hi253yuv") **or** `HI704_YUV` ("hi704yuv") | `zhaoshaopeng add SENSOR_DRVNAME_HI253_YUV power on`; `…HI704_YUV power on/off` — **both compiled, probe binds the fitted one** |
| VCM/AF | `DW9714` + `DW9719` | In the Lithium blob (54×/46× hits — already present in the innioasis117 tree lineage, keep); Mint blob: no AF strings (KD port of the Mint set relied on the sensor's own AF or none — irrelevant, we keep the 3.10.54 lens framework) |

Also present as ODM debug leftovers (NOT in the active list): GC2035, S5K5CAGX, OV8825/8830, IMX111,
S5K4E1GA, OV2680, GC2235… These appear in other Mint-board family configs; the three above are the
Q5 Mint set per M1 E8 + the live I2C map.

**Runtime I2C ground truth (`hardware-facts-q5-mint.md`, live device):**
- Front Hynix sensor: **I2C bus 0, 7-bit addr 0x5A** (`0-005a Hyn_device`).
- Camera cal EEPROM: bus 1, addr 0x36 (`1-0036 CAM_CAL_DRV`, `1-0050 dummy_eeprom`).
- No rear sensor enumerated at rest ⇒ rear presence is probe-time-only (camera open); GC5004 stays
  in the list as main per E8; not an F4 requirement (the F4 defect is the **front**).

Sensor power sequencing: Mint's `kdCISModulePowerOn` strings show the VCAMA/VCAMD LDO + GPIO
pattern (`[VCAMA_LDO_EN_fuc]`, `[CAMERA SENSOR] set gpio …`, `[CAMERA LENS] set gpio …`) —
the power-pin set is the standard Q5-class 2-lane CSI arrangement. The exact GPIO numbers are not
string-recoverable; the port copies the Q5/Q3E power order from the a106 template adapted to the
Q5 VCAM rails, then **G6 validates** (sensor probe success line in dmesg).

## 2.4 Keypad matrix / GPIO usage [PARTIALLY RECOVERED — decided: no kernel delta in primary plan]

- Mint blob: MTK kpd driver (`kpd: kpd_early_suspend wake up source …`, `kpd_auto_test_for_factorymode`,
  `[kpd]` register dump strings). The numeric matrix (`cust_kpd.h` row/col/keycode tables) is
  compiled as small ints — **not string-recoverable**, and the decompressed blob carries no table
  symbols.
- Behavioral ground truth already established in M1 E7: Mint's own kernel emits scancode **102** for
  home (its `mtk-kpd.kl` maps 102→HOME); the T-ROM/Q3E lineage under its 3.10.54-class kernel emits
  **172**. ADR-4's userspace dual-map (102+172→HOME with WAKE_DROPPED) covers both → **kernel kpd
  table is left at the chosen tree's/Q5-lineage default; no M1b kernel key delta** unless gate G5
  shows a conflict (D15 fallback).
- `FCOVER_1/FCOVER_2` (744/745) exist in Mint's .kl — userspace-only entries, already handled by the
  M1a op table; no kernel work.

## 2.5 I2C bus assignments [RECOVERED — live device facts]

| Device | Bus : addr (7-bit) | Mint driver | M1b consequence |
|---|---|---|---|
| Touch (gsl) | 0 : 0x40 | `gsl_tp` (`0-0040`) | none — Lithium ships gsl_tp already; works on stock |
| Hynix front camera | 0 : 0x5A | `Hyn_device` | camera probe addr for hi253yuv/hi704yuv = 0x5A (driver i2c_board_info) |
| Hynix cst2xx secondary | 0 : 0x5D | `Hyn_device_cst2xx` | none (variant detection device; Lithium blob also carries `cst2xx_local_init`) |
| CAM_CAL EEPROM | 1 : 0x36 | `CAM_CAL_DRV` | none (calibration; generic driver present) |
| dummy EEPROM | 1 : 0x50 | `dummy_eeprom` | none |
| (dummy) | 2 : 0x18 | `DUMMY` | none |
| **Speaker amp AW87559** | **2 : 0x58** | `aw87559_pa` | **bus correction: 0x58 on bus 2** (supersedes the earlier bus-1 note). The heyrudra tree lacks the AW87559 driver entirely → port (§3.6), register on bus 2 |

## 2.6 Lithium blob parity inventory (the `5217dd41…` target surface)

For the M1b-α defconfig-parity gate (Karen §3.2-B.10), the exported driver surface of the Lithium
blob, from `lithium-strings.txt`:

| Component | Lithium blob strings | Mint blob | M1b target |
|---|---|---|---|
| `ccci` (modem) | 744 hits | 787 | **keep** (defconfig parity) |
| `mali` GPU | 604 | 612 | **keep** |
| `mt6323` PMIC | 25 | 25 | keep |
| `aw87559_pa` | 3 | 3 | keep (port driver—absent in chosen tree) |
| `fan5405`+`bct24157` | 29+13 | 0 | **drop** (Case B delta) |
| `MAX17050SW6106` gauge | 12 | 0 | **drop** (Case A delta) |
| Sensors: `gc2355mipiraw`, `gc9503v*`, `ov5670mipiraw` | ✔ | 0 | **replace** with GC5004/HI253/HI704 |
| VCM `DW9714`/`DW9719` | 46/54 | 0 | **keep** (port `dw9714af/` + `dw9719af/` — absent in chosen tree) |
| Touch `gsl_tp` / `cst2xx` | ✔ | ✔ | keep |
| kpd / auxadc / batt thread | ✔ | ✔ | keep |

*Everything "drop" refers to driver selection only; the generic `charging_hw_pmic.c` +
`battery_meter_hal.c` (FGADC) remain compiled — exactly the Mint kernel's own driver set.*



---

# 3. BOARD-CONFIG DELTA TABLE (exact before/after)

**Conventions.** "Base" = heyrudra tree state (`a106_defconfig` board `a106`). All edits happen in a
new board `q5` + a new defconfig `q5_defconfig` — the a106 files are left untouched as reference.
Case tag: **A** = gauge mis-probe branch (ADR-3 Case A), **B** = charge-disable branch (Case B),
**BOTH** = applied unconditionally (the branches coincide — see §3.1), **CAM** = camera, **I2C** =
bus registration, **G5f** = G5-fallback only (not in primary build).

## 3.1 Charging case note (from the task: design BOTH, mark the branch)

Hera's Mint baseline: charges autonomously, SOC 0→18 % (hardware-facts §1). The Lithium/T-ROM
baseline flash (Case A vs B discrimination, G3 sub-gates) is **still pending** — so this spec designs
both branches. However, the Mint binary ground truth (§2.1–2.2) makes the branches **coincide**:
Mint's kernel has *neither* the external charger IC driver *nor* the hybrid gauge driver, and our
chosen 3.10.54 tree has *neither* the bct24157 nor the MAX17050SW6106 sources (not ported, not
missed — those exact chips don't exist on Mint hardware). Therefore **the M1b-β build applies the
Case-A and Case-B deltas together, unconditionally**. G3 (run pre- and post-flash) tells us which
mechanism was the live fault on Lithium; the fix code does not change with the answer.

- If G3 shows **Case A** (Lithium charges but SOC garbage): the fix that matters = D3 (FGADC-only gauge).
- If G3 shows **Case B** (bct24157 actively disables the autonomous SW6106): the fix = D1+D2 (pmic-only charger).
- If **Case C** (cosmetic only — excluded by hardware-facts §1: SOC is *really* stuck on Lithium): still
  correct to ship D1–D3 (matches the hardware's actual charger topology; the hybrid-gauge driver
  cannot be supported on this board without a source we do not have for a chip we do not probe).

## 3.2 Charger + gauge deltas (charging fix)

| ID | Case | File (in `.reference-kernel-3.10.54/kernel-3.10/`) | Before (a106 base) | After (q5) |
|---|---|---|---|---|
| D1 | B | `arch/arm/configs/q5_defconfig` | `CONFIG_MTK_FAN5405_SUPPORT=y` | `# CONFIG_MTK_FAN5405_SUPPORT is not set` → **no external charger compiled**; `drivers/misc/mediatek/power/mt6582/Makefile` else-chain falls through to `charging_hw_pmic.o` (verified: the Makefile's final `else` builds `charging_hw_pmic.o` when all `*_SUPPORT` are off) |
| D2 | B | `arch/arm/configs/q5_defconfig` | *(not present)* | assert explicit: `# CONFIG_MTK_BQ24158_SUPPORT is not set`, `# CONFIG_MTK_BQ24196_SUPPORT is not set`, `# CONFIG_MTK_NCP185*_SUPPORT`, `# CONFIG_MTK_SWCHR_SUPPORT`, `# CONFIG_MTK_MAX8971_SUPPORT`, `# CONFIG_MTK_RT9536_SUPPORT` all off (a106 base already has them off — keep off; do not enable any external charger) |
| D3 | A | `arch/arm/configs/q5_defconfig` | `CONFIG_MTK_SMART_BATTERY=y` | keep `=y` → FGADC path (`battery_meter_hal.o`) is the only gauge; **do not** port any `MAX17050SW6106` option (chip absent on Mint hardware per §2.1) |
| D4 | A | `arch/arm/mach-mt6582/q5/power/cust_battery_meter.h` (new; clone a106's) | a106: `Q_MAX_POS_50 1865` (+25/0/−10 variants 1841/1624/1541, H_CURRENT 1797/1826/1178/1117); `FG_METER_RESISTANCE 0`; temps T0..T3 = 110/0/25/50 | Q5 battery: set `Q_MAX_*` to the Q5 cell capacity (mAh units; **OQ-2** — read from physical battery label; default 2000 if unreadable; FGADC aging learning refines it at runtime); keep `FG_METER_RESISTANCE 0` (MT6323 internal sense) and T0..T3 as-is (generic Li-ion) |
| D5 | A | `arch/arm/mach-mt6582/q5/power/cust_battery_meter_table.h` (new; clone a106's) | a106's generic 100-pt voltage/R profiles | **verbatim clone** of the generic MT6582 profile set (§2.2 fallback: Mint's compiled tables are not recoverable from the stripped binary; the generic Li-ion ZCV curve + runtime FGADC learning yields a working, monotonic SOC — Mint's own stock reports SOC through the same FGADC code path). No numeric Mint values exist to transplant. |
| D6 | A | `arch/arm/mach-mt6582/q5/power/cust_charging.h` (new; clone a106's) | `V_PRE2CC_THRES 3400`, `V_CC2TOPOFF_THRES 4050`, `RECHARGING_VOLTAGE 4230`, `AC_CHARGER_CURRENT CHARGE_CURRENT_900_00_MA`, `USB_CHARGER_CURRENT …_500_00_MA` | keep values (SW6106 is autonomous; these thresholds govern the PMIC notification/UI thread only). Recharge voltage 4230 is fine for the Q5 cell. Do **not** raise AC current — the SW6106, not the kernel, sets real input current. |
| D7 | B | *(no file)* | — | **non-delta (explicit):** do NOT port `bct24157.c`/`fan5405_user_space` glue. Its only evidence of need was the Lithium blob; Mint proves absence. If G3 post-flash shows charging *still* dead, the suspect list is the Q5 charge-related GPIO/`cust_pmic.h` settings — escalate to Bob, do not improvise a charger driver. |

## 3.3 Camera deltas (front camera fix; ADR-5)

| ID | File | Before (a106 base) | After (q5) |
|---|---|---|---|
| D8 | `arch/arm/configs/q5_defconfig` | `CONFIG_CUSTOM_KERNEL_IMGSENSOR="ov5648_mipi_raw_darling ov5648_mipi_raw_truly ov5648_mipi_raw_sunwin ov5648_mipi_raw_darling_zl hi258_mipi_yuv_cmk hi258_mipi_yuv_sw"` | `CONFIG_CUSTOM_KERNEL_IMGSENSOR="gc5004_mipi_raw hi253_yuv hi704_yuv"` (→ `-DGC5004_MIPI_RAW -DHI253_YUV -DHI704_YUV` + obj-y on the three dirs, per `drivers/misc/mediatek/Makefile.custom` + `imgsensor/src/mt6582/Makefile`, both verified) |
| D9 | `drivers/misc/mediatek/imgsensor/src/mt6582/` | dirs: `hi258_mipi_yuv_{cmk,sw}`, `ov5648_mipi_raw_*`, `ov9760_mipi_raw`, `s5k3h2yx_mipi_raw` | **add** dirs (old dirs kept — harmless, only referenced by -D flags): `gc5004_mipi_raw/` ← donor `PersimmonProject/android_kernel_archos_persimmon_3_10` (or `carlitros900/android_kernel_archos_oxygen`) `…/gc5004_mipi_raw/`; `hi253_yuv/` + `hi704_yuv/` ← donor `CyanogenMod/android_kernel_mediatek_sprout` `…/hi253_yuv/`, `…/hi704_yuv/`. 3.4↔3.10 KD API adaptation if the donor symbols don't match (`SensorOpen/SensorClose/GetSensorID/…` signature check — both donors are MTK KD-imgsensor family, small delta expected) |
| D10 | `drivers/misc/mediatek/imgsensor/src/mt6582/kd_sensorlist.h` | entries for ov5648×4 + hi258×2 | add to the extern block + `kdSensorList[]` (insert by resolution large→small per the file's own note): `{GC5004MIPI_SENSOR_ID, SENSOR_DRVNAME_GC5004_MIPI_RAW, GC5004MIPISensorInit}`, `{HI253_SENSOR_ID, SENSOR_DRVNAME_HI253_YUV, HI253_YUV_SensorInit}`, `{HI704_SENSOR_ID, SENSOR_DRVNAME_HI704_YUV, HI704_YUV_SensorInit}` — each inside `#if defined(…)` guards matching the -D flags. `HI253_SENSOR_ID 0x0092` / `HI704_SENSOR_ID 0x0096` already defined in `kd_imgsensor.h` (verified line 232/233); **add `GC5004MIPI_SENSOR_ID` + `SENSOR_DRVNAME_GC5004_MIPI_RAW "gc5004mipiraw"`** to `kd_imgsensor.h` if the donor headers don't carry them (actual ID value from the gc5004 donor source's GetSensorID table — typically the sensor chip ID register read) |
| D11 | `arch/arm/mach-mt6582/q5/camera/camera/kd_camera_hw.c` (new; clone a106's) | a106 strcmp chains for ov5648/hi258 power-up | add strcmp branches for `SENSOR_DRVNAME_GC5004_MIPI_RAW` / `…_HI253_YUV` / `…_HI704_YUV` in `kdCISModulePowerOn` — power sequence = standard Q5-class 2-lane CSI (VCAMA/VCAMD LDO, PDN/RST order per the donor drivers' expectations; Mint blob §2.3 shows VCAMA_LDO_EN + SENSOR GPIO hooks; G6 validates probe). Copy the power-on/off pattern from the gc5004 donor's own board example if present in the donor tree |
| D12 | lens | `mt6582/` has only `dummy_lens`, `ov5648af_*`; Makefile references absent `mt6582/dw9714af/` | **port** (per M1 ADR-5 "keep DW9714/DW9719"): `mt6582/dw9714af/` ← `bq/aquaris-E5FHD` or sprout `…/dw9714af/`; `mt6582/dw9719af/` ← `bq/aquaris-E5FHD` (`DW9719AF` confirmed there); defconfig: `CONFIG_MTK_LENS_DUMMYLENS_SUPPORT=y` (fallback), `CONFIG_MTK_LENS_DW9714AF_SUPPORT=y`, add `CONFIG_MTK_LENS_DW9719AF_SUPPORT=y` (+ Makefile line pattern identical to the dw9714af one). AF binds GC5004 at probe; harmless if AW VCM absent. |

## 3.4 AW87559 speaker amp (I2C correction — needed for the userspace audio pair to work on-device)

The heyrudra tree has **no AW87559 driver** (only `yusu_android_speaker.c`); but both blobs carry
`aw87559_pa`, and the M1a audio fix (T-ROM HAL) relies on the kernel amp controls M1 §1.3 describes.

| ID | File | Before | After |
|---|---|---|---|
| D13 | `arch/arm/mach-mt6582/q5/sound/` (new; clone a106's) | `yusu_android_speaker.c` (generic) | add `aw87559_pa.c` (+ `aw87559_pa.h`) — donor: `MotorolaMobilityLLC/kernel-mtk` or `atharvnegi/kernel_xiaomi_selene` `drivers/misc/awinic/aw87559*` family (self-contained I2C amp driver; register via legacy 3.10 i2c API (i2c_board_info, not regmap); enable contract = chip ID 0x5A at I2C addr 0x58, RST/PWR gpio pulse + I2C init table — contract documented in `artificery-dev/tempo` (M1 §1.3)) — adapt to this tree's sound glue so the `aw87559_pa` mixer controls exist for the T-ROM HAL to poke (G4 `tinymix` is the check) |
| D14 | bus registration (q5 board `core.c`/`i2c` board info) | a106 registers amp touch etc. on its buses | **i2c_board_info{ I2C_BOARD_INFO("aw87559_pa", 0x58) } on bus 2** (live ground truth §2.5: `2-0058 aw87559_pa`; explicitly **not** bus 1) |

## 3.5 Keys / GPIO deltas (minimal)

| ID | Case | File | Before | After |
|---|---|---|---|---|
| D15 | — | `arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h` + `dct/dct/inc/cust_kpd.h` | a106 matrix | **no delta in primary build** (ADR-4 dual-map handles home codes; G5 verifies). **G5f fallback only:** if G5 proves the kpd emits neither 102 nor 172 for a physical key, transplant the Q5 lineage matrix from `T-ROM-Project/android_device_t-rom_q5_q3e_mt6582/kernel` prebuilt lineage evidence + `configs/mtk-kpd.kl` (172=HOME on 3.10.54 kpd) and re-run G5 |
| D16 | — | `arch/arm/mach-mt6582/q5/dct/dct/inc/cust_gpio_usage.h` | a106 GPIO map | no speculative edits. Review pass with Forge: assert no a106-specific GPIO consumers conflict with Q5 hardware (LCM/eint/camera pins). Any GPIO that turns out wrong surfaces as a G1/G2 boot-log anomaly → then patch from dmesg evidence, never blind |

## 3.6 Port-input inventory (donor sources Forge needs)

| Donor | Repo (public) | Provides |
|---|---|---|
| GC5004 main sensor | `PersimmonProject/android_kernel_archos_persimmon_3_10` (3.10 family; alt: `carlitros900/android_kernel_archos_oxygen`, `darklord4822/android_kernel_smart_surf`) | `gc5004_mipi_raw/` driver + SENSOR_ID define |
| HI253 / HI704 sub sensors | `CyanogenMod/android_kernel_mediatek_sprout` | `hi253_yuv/`, `hi704_yuv/` drivers |
| DW9714AF / DW9719AF lens | `bq/aquaris-E5FHD` (3.10; also sprout for dw9714) | `dw9714af/`, `dw9719af/` lens drivers |
| AW87559 amp | `MotorolaMobilityLLC/kernel-mtk` / `…_xiaomi_selene` family `aw87559*` (API-adapted) | amp driver; contract ref: `artificery-dev/tempo` |
| Q5 keymap lineage (fallback) | `T-ROM-Project/android_device_t-rom_q5_q3e_mt6582` | `configs/mtk-kpd.kl` lineage facts |

All donors are GPL-2.0 kernel trees; no relicensing issue (NF5).



---

# 4. IMPLEMENTATION SPEC — FORGE M1b

## 4.0 Layout

Kernel work stays **outside** the fork repo (only manifests/scripts/specs are committed):

```
.reference-kernel-3.10.54/          # gitignored clone (heyrudra/android_kernel_micromax_a106)
├── arm-eabi-4.8/                   # in-tree toolchain (arm-eabi-gcc 4.8 — verified runs)
└── kernel-3.10/                    # the actual tree ("$K" below)
    ├── arch/arm/configs/q5_defconfig            [NEW]
    ├── arch/arm/mach-mt6582/q5/                 [NEW, cloned from a106/]
    └── drivers/misc/mediatek/… (sensor/lens/power/sound edits per §3)
build/                              # fork repo — add:
├── 40_kernel_env.sh                # toolchain/env, donor hash asserts
├── 45_kernel_parity.sh             # M1b-α build+parity check
├── 50_kernel_delta.sh              # M1b-β: applies §3 edits idempotently (patch files kept in patches/kernel/…)
└── 55_repack_boot.sh               # zImage+stock ramdisk → out/boot.img (Lithium header args)
patches/kernel/                     # committed: the exact diffs for every §3 row (one file per D-id)
manifests/kernel-sources.sha256     # donor sensor/lens/amp source hashes
```

Hard rules from M1 §2.0 still bind (hash-assert every donor, idempotent re-runs, no donor binaries in
git). Kernel **source edits are committed as patch files** under `patches/kernel/` (the tree itself
is gitignored); `50_kernel_delta.sh` applies them with `patch -p1` / heredoc writes.

## 4.1 M1b-α — stock-parity build (before any Mint delta)

Purpose: prove the tree+toolchain+repack path boots on the Q5 (gate G2), isolating "tree doesn't
boot on this platform" from "board delta broke it".

1. `make ARCH=arm CROSS_COMPILE=../arm-eabi-4.8/bin/arm-eabi- a106_defconfig && make -j$(nproc) zImage`
   (in `$K`; the top-level `build.sh` wrapper is optional). Record `Linux version 3.10.54` from the
   build banner.
2. **Defconfig parity check vs the `5217dd41…` blob** (offline, no device — Karen §3.2-B.10):
   decompress both zImages, `strings -a`, compare the driver-name inventory sets:
   - Must be present in the new blob: `ccci`, `mali`, `mt6323`, `gsl_tp`, `mtk-kpd`, auxadc/batt thread.
   - Expected absences at α stage (to be added in β): `aw87559_pa`, `dw9714/dw9719` AF, Mint sensors.
   - a106-side extras that Lithium lacks (its own lcm/sensors) are acceptable: they are inert without
     matching hardware; logged in the parity report.
3. Repack: `mtk-tools`/`mkbootimg` with **Lithium's** boot.img-args (base 0x80000000, pg 2048, koff
   0x8000, roff 0x04000000, soff 0x00f00000, toff 0x0e000000, board 1441186574, cmdline
   `bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug`) + **Lithium's
   stock ramdisk byte-identical** (E4). → `out/boot-m1b-alpha.img`.
4. Hera G2: flash BOOT only (system = stock Lithium); must boot; `uname -r` = 3.10.54; input
   devices list == stock (±0). If G2 fails: halt, return to Bob (tree-selection revisit).

## 4.2 M1b-β — board delta build

Apply §3 deltas (patches committed per D-id), in this order:

1. **Board dir**: `cp -r arch/arm/mach-mt6582/a106 arch/arm/mach-mt6582/q5`; replace `a106` strings
   with `q5` in the copied Makefiles/Kconfig hooks if referenced.
2. **Defconfig**: `cp arch/arm/configs/a106_defconfig arch/arm/configs/q5_defconfig`;
   `CONFIG_ARCH_MTK_PROJECT="a106"` → `"q5"`; apply D1/D2/D3 (charger/gauge), D8 (sensor list),
   D12 (lens support).
3. **Camera** (D9–D11): fetch donors (hashes → `manifests/kernel-sources.sha256`), drop the three
   sensor dirs into `drivers/misc/mediatek/imgsensor/src/mt6582/`, edit `kd_sensorlist.h` externs +
   `kdSensorList[]` (guarded), add GC5004 ID/DRVNAME to `kd_imgsensor.h` if missing, add the three
   power-on strcmp branches to `arch/arm/mach-mt6582/q5/camera/camera/kd_camera_hw.c`.
4. **Lens** (D12): drop `dw9714af/` + `dw9719af/` into `drivers/misc/mediatek/lens/mt6582/`, add the
   DW9719 Makefile line (copy the DW9714AF pattern).
5. **Amp** (D13/D14): port `aw87559_pa` into `arch/arm/mach-mt6582/q5/sound/`, register
   `I2C_BOARD_INFO("aw87559_pa", 0x58)` on **bus 2** in the q5 board i2c table; verify the mixer
   control names it exposes are those the T-ROM HAL expects (compare G4 tinymix from Mint).
6. **Battery/keys** (D4–D6, D15, D16): clone power headers into q5/power; leave key/ GPIO tables
   at lineage defaults.
7. Build `make q5_defconfig && make -j zImage`; repack as §4.1.3 → `out/boot-m1b-beta.img`.
8. Parity check (§3.2-B.10): new blob **must** contain `gc5004mipiraw`, `hi253yuv`, `hi704yuv`,
   `dw9714`, `dw9719`, `aw87559_pa`, FGADC (`battery_meter`/`[FGADC]`) strings; **must NOT** contain
   `bct24157`, `MAX17050SW6106`, `fan5405_config_interface`. ccci/mali/mt6323/gsl_tp unchanged ±.
9. Hera G3 post-flash (charging: SOC climbs ≥2%/10 min, monotonic, off-mode animation) + G6 (camera:
   `dmesg | grep -iE 'imgsensor|HI253|HI704|GC5004'` probe success; front preview/capture).

## 4.3 Acceptance criteria (Forge self-check before Karen)

- Both builds compile with `arm-eabi-gcc 4.8` zero-error (warnings logged, not fatal).
- Parity report checked into build log; §3.2-B.10 string sets pass.
- boot.img headers byte-identical to Lithium's args except payload/sizes; ramdisk hash == Lithium's.
- Every §3 delta present as a committed patch in `patches/kernel/` with its D-id in the commit msg.
- Git tag `m1b-beta` (with M1a tag for the combined release per the release plan).

## 4.4 What Forge must NOT do

- No 3.4.67 sources grafted in (ABI mismatch; Mint's own tree is KK).
- No bct24157/MAX17050SW6106 port attempts "for completeness" (D7).
- No ramdisk edits (E4). No touch on preloader/lk/secro/scatter beyond the M1 contract (BOOT+ANDROID).
- Don't invent GPIO/keypad values (D15/D16 are evidence-gated).

# 5. OPEN QUESTIONS / RISKS

| ID | Question / risk | Blocked on | Mitigation |
|---|---|---|---|
| OQ-1 | **Lithium/T-ROM baseline flash still pending** — Case A vs B discrimination unknown. Not blocking: §3.1 shows both branches coincide in the same deltas (D1–D6 applied unconditionally). | Hera G3 sub-gates on Lithium + T-ROM bases | design already covers both; G3 tells us which mechanism was live, for the record |
| OQ-2 | Q5 physical battery capacity (for `Q_MAX` in D4) — cell label unreadable from binaries. | Eric reads the battery label (or `cat /proc/…` after a full charge cycle on Mint) | default 2000 mAh; FGADC aging-learning refines Qmax at runtime; SOC stays monotonic regardless |
| OQ-3 | Mint FGADC numeric tables were **not recoverable** from the stripped 3.4.67 blob (u16/u32/pair scans = 0 candidates). If the generic MT6582 profile produces visibly-wrong SOC %s (G3), the curve needs measured data. | G3 post-flash SOC plausibility | capture `dmesg`/`[FGADC]` dumps at 0/25/50/75/100 % on-device under Mint for one cycle → transplant the ZCV points into `cust_battery_meter_table.h`; this is a calibration pass, not a redesign |
| OQ-4 | HI253 vs HI704 identity of the fitted front sensor. | G6 probe log (`kd_camera_hw`/imgsensor matched SENSOR-ID print) | both drivers compiled (D8); probe binds the answering one by chip ID (0x0092 / 0x0096) |
| OQ-5 | 3.4↔3.10 KD-imgsensor API drift in donor drivers (sprout is 3.4.67 KD; our tree 3.10.54 mtkcam-next). | Forge compile pass | function-pointer signature comparison at port time; the KD API families are adjacent — expected fix class = struct-field renames, not logic changes |
| OQ-6 | aw87559 sound-glue integration depth: the T-ROM HAL may expect the amp behind MTK's `yusu_android_speaker` controls rather than a standalone codec node. | G4 (`tinymix` control list on Mint stock vs fork) | port registers the same kernel mixer controls Mint/Lithium blobs both name (`aw87559_pa` strings present in both blobs); if the HAL can't see them, adapt the registration to the MTK sound path (escalate to Bob with tinymix dumps) |
| OQ-7 | Board `q5` LCM/display config is at a106 defaults — LCM panel differs (a106's vs Q5's gc9503v class panel). Lithium blob carries `gc9503v_wvga_dsi_vdo_*` LCM strings. **If the new kernel boots G2 but the screen stays dark**, LCM is the delta to port next (source: bq/sprout `gc9503v` lcm dir; low risk: same mtk6582 DSI panel class). | G2 display check | G2 explicitly records display state; LCM port = one additional driver dir + `CONFIG_CUSTOM_KERNEL_LCM` string |
| OQ-8 | Rear camera (GC5004) is "present in list" but not confirmed fitted on the retail Q5 Mint (live I2C map shows only the Hynix front). Compiling it is harmless (probe fails inertly); if it probes but yields garbage, remove from list after G6. | G6 | inert probe-failure is the designed behavior |

**Risks carried over from M1 §1.9 that M1b now retires:** kernel-source availability (closed by §1);
bct24157 mis-drive (closed by D1–D2); wrong-Hynix guess (closed by D8 both-drivers).

## Verdict

**Design complete (not blocked).** All five outputs are delivered: (1) tree chosen and proven
(3.10.54, complete mediatek layer, in-tree gcc 4.8 — §1); (2) Mint board-config extracted where
the binary permits, with unrecoverable items identified and runtime-recovery fallbacks given (§2);
(3) exact per-file before/after deltas for charging (Case A **and** B — shown to coincide), camera,
keys, GPIO, I2C (§3, D1–D16); (4) Forge implementation spec with sub-milestones M1b-α/β, parity
checks, and forbidden moves (§4); (5) open questions all carry fallbacks or gates, none block the
build (§5).

The only pending inputs are **on-device facts** (OQ-1/OQ-2/OQ-4), each absorbed by a gate or a
runtime-learning path — none requires more offline design before Forge starts M1b-α.

## Remaining entry points

1. **Forge:** M1b-α parity build (§4.1) → tag `m1b-alpha`; then §4.2 deltas → `m1b-beta`.
2. **Hera:** G2 (α boot parity) → G3 pre-flash Lithium/T-ROM diagnostics (fills OQ-1 for the record)
   → G3/G6 post-flash acceptance (β).
3. **Karen:** parity + offline checks per M1 §3.2-B (10–12) on Forge's artifacts; expand G3 charging
   pass criteria using §3.1 (SOC monotonic + ≥2 %/10 min + plausible mV).
4. **Eric:** battery label read (OQ-2) before the first β flash, if possible.
5. **Bob:** on any OQ-3 SOC-plausibility failure, run the one-cycle calibration capture and land the
   measured ZCV table (calibration, not redesign).

---
*Bob — Principal Software Architect. End of M2 spec.*
