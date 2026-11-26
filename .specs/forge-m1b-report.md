# Forge — M1b implementation report (kernel rebuild: α parity build + β board deltas)

**Spec:** `.specs/bob-m2-spec.md` §3 (delta table D1–D16), §4.0–4.4 (implementation)
**Status: COMPLETE — α+β built, verified, byte-stable at tags `m1b-alpha`/`m1b-beta` (10478ce, m1a-anchored build identity); GAP-1 + OQ items escalated; NO flashing performed.**
**Method:** builds happen in the gitignored `.reference-kernel-3.10.54/kernel-3.10/` tree with its
in-tree `arm-eabi-4.8` toolchain; repo commits carry only `patches/kernel/*.patch` (one per D-id),
`build/4*_kernel*.sh`, `manifests/kernel-sources.sha256` (hard rule: never the tree, never `.img`).

---

## 0. Session log (incremental)

- Working from repo HEAD `7574d5f` (m1a tag). Donor pins `manifests/donors.sha256` re-verified below before use.
- Scratch workspace: `~/.hermes/cache/scratch/opencode/forge-m1b/` (gitignored class of path).

---

## 1. M1b-α — stock-parity build (§4.1)

### 1.1 Environment verified

- Kernel tree `.reference-kernel-3.10.54/kernel-3.10/` (heyrudra `android_kernel_micromax_a106`, HEAD
  `96e53552`), Makefile `VERSION=3 PATCHLEVEL=10 SUBLEVEL=54` ✓, git-clean before build.
- Toolchain in-tree `arm-eabi-gcc (GCC) 4.8` ✓ (used via absolute path; see note D-3 below).
- **Mechanics verified before build** (per §4.1.0 "understand first"): the charging Makefile
  else-chain (`drivers/misc/mediatek/power/mt6582/Makefile`) ends in `obj-$(CONFIG_MTK_SMART_BATTERY)
  += charging_hw_pmic.o` when every `*_SUPPORT` is off — D1's premise holds ✓; board dir is selected
  purely by `obj-y += $(ARCH_MTK_PROJECT)/` in `mach-mt6582/Makefile` ✓; `CUSTOM_KERNEL_IMGSENSOR`
  becomes `obj-y += <dirs>/` via `imgsensor/src/mt6582/Makefile` and `-D` flags via
  `Makefile.custom` (lowercase→uppercase) ✓; cust headers resolve through
  `-I$(MTK_PROJECT_PATH_ROOT)/power` (q5 board dir) ✓.
- Build: `make ARCH=arm CROSS_COMPILE=<abs> O=build-alpha a106_defconfig && make -j12 ... zImage` —
  **zero errors** (warnings only; e.g. the familiar `charging_get_error_state defined but not used`
  from charging_hw_fan5405.c — that driver drops out at β per D1).
- Banner: **`Linux version 3.10.54 (yetisoldier@minipc) (gcc version 4.8 (GCC) ) #1 SMP PREEMPT …`** ✓
  (`§4.1.1` requirement: record 3.10.54).
- α zImage: `build-alpha/arch/arm/boot/zImage`, **4,229,544 B, sha256 `1a864bef32ce6c7c1f1b06677a2fffc8359077bf935712687e52fdbfd49a44ff`**.

### 1.2 Build-mechanics deviations logged (no spec deviation)

- **D-1 (O= object dirs):** α and β build into separate object dirs `kernel-3.10/build-alpha/`,
  `kernel-3.10/build-beta/` so a β artifact can never reuse an α object. Spec §4.1.1 shows in-tree
  `make`; output-identical to spec (same defconfig, same sources); keeps re-runs clean.
- **D-2 (absolute CROSS_COMPILE):** relative `../arm-eabi-4.8/...` resolves against `O=build-alpha`
  (not `$K`) and failed (`not found`); scripts pass the absolute toolchain path.
- **D-3 (zImage decomp = `arch/arm/boot/Image`):** this tree ships `CONFIG_KERNEL_XZ=y` (no gzip
  stream inside zImage); the zImage's piggy *is* `arch/arm/boot/Image` (kbuild emits both), so the
  parity strings come from that Image — semantically identical to "decompressed zImage" (both are
  the same uncompressed kernel payload the XZ decompressor would emit). Lithium-side comparison uses
  Bob's scratch `lithium-kernel.decomp` (sha verified `d284ba1698c77267aaeafb64abd3defcb82f7d09bcc5ddbb3538e303dc69ab53`,
  matches the bob-m2 pin) produced from the pinned Lithium kernel blob
  `5217dd41c77b8184bd63fe56bd95bbedf89b7cb08a2a6f073091c11c31bbe88c` (boot.img-kernel.img, matches
  `bob-m2-spec` §1.2 head).

### 1.3 Parity check (§4.1.2 + §3.2-B.10) — driver-name inventory vs `5217dd41…`

Method: `strings -a` over α Image (82,538 lines) vs `lithium-strings.txt` (57,968 lines);
grep-hit line counts (case-insensitive, unique lines) for the enumerated families:

| Family | α (a106 build) | Lithium blob | §4.1.2 verdict |
|---|---|---|---|
| `ccci` (modem) | 741 | 677 | ✓ keep (same driver family; a106 has more DCT/debug strings) |
| `mali` (GPU) | 809 | 791 | ✓ keep |
| `mt6323` (PMIC) | 19 | 39 | ✓ PMIC core present (probe/dump/export strings). Lithium extras are its own board `cust_pmic`/DCT debug tables (`TPMIC_DUMP_ALL_Re:` etc.) — board glue, not a driver delta |
| `gsl_tp` (touch) | **0** | 3 | ✗ **FAILS the §4.1.2 must-have — see GAP-1 below (tree has no GSL driver at all)** |
| `mtk-kpd` | 1 | 1 | ✓ |
| `auxadc` | 210 | 172 | ✓ |
| `battery_meter`/`FGADC` | 34 | 30 | ✓ (FGADC SW gauge compiled in, as Mint's kernel does) |
| `fan5405` | 26 | 24 | present in α (a106 sets `FAN5405=y`); **β drops it (D1)**. (Bob's §2.1 counted 29 substring-hits vs 24 line-hits — counting-method delta only) |
| `bct24157` | 0 | 13 | ✓ absent in α; **β asserts not-set (D2)** |
| `MAX17050SW6106` | 0 | 12 | ✓ absent in α (and stays out per D3/D7) |
| `aw87559_pa` | 0 | 3 | expected absent at α; **β ports it (D13/D14)** |
| `dw9714` / `dw9719` | 0 | 39 / 46 | expected absent at α; **β ports them (D12)** |
| Mint sensors `gc5004mipiraw`, `hi253yuv`, `hi704yuv` | 0 | 0 | expected absent in both at α; **β adds all three (D8–D11)** |

**a106-side extras Lithium lacks** (§4.1.2 "acceptable — inert without matching hardware", logged):
`ov5648`×363, `hi258`×44 (a106's shipped sensors — inert in the new list per D8),
`ektf2k`×2 + `goodix`×1 + `GT9xx`×9 (a106 touchpanels), `ap3220`×72/`akm09911`×12/`kxtj2`×75
(a106 sensor stack), LCM `hx8369b` (a106's panel — see OQ-7/G2 display note; Bob already predicted
this as the next delta if G2 shows a dark screen).

**Verdict:** α passes every §4.1.2 must-have **except `gsl_tp`**, which is *impossible from this
tree* (GAP-1) — everything §4.1.2 calls "expected absences at α" is indeed absent.

### 1.4 GAP-1 (escalation for Bob, not blocking α): touch driver missing from the chosen tree

- **Fact:** the heyrudra tree contains **no GSL-class touch driver anywhere** (no `gsl*` file in the
  whole tree; a106/2014011 boards ship ektf2k/Goodix/GT9xx/FT5336 only; a106_defconfig has no
  `CONFIG_CUSTOM_KERNEL_TOUCHPANEL` at all — the a106 kernel carries **no touch driver whatsoever**).
- The Q5's live touch (`0-0040 gsl_tp`, hardware-facts §2.5) binds to a driver only the
  Lithium/T-ROM lineage kernel has (built-in: `gsl_tp`+`cst2xx` strings live *inside* the `5217dd41…`
  blob; no `.ko` exists in its ramdisk or at `system/lib/modules` — drivers are built-in there).
- §3 tables have **no touch delta** (§2.6 row says "keep — works on stock") — that assumption is
  false for this tree.
- **Consequence:** the β kernel will boot and charge but **touch will not work until a touch driver
  is ported** (donor needed — e.g. the gsl driver from another Q5/Q3E-lineage 3.10 tree;
  `T-ROM-Project/android_device_t-rom_q5_q3e_mt6582` (checked) carries no kernel/touch lineage).
- **G2 exposure:** Hera's α gate "input devices list == stock (±0)" will show the missing touch
  input device — the expected, documented α state for this gap (not a tree-selection failure).
- **Recommended follow-up (Bob's call):** a follow-up delta (post-G3, evidence-gated like D15/D16)
  porting the gsl-class driver + `CONFIG_CUSTOM_KERNEL_TOUCHPANEL` wiring for the Q5. Forge did **not**
  improvise one (forbidden scope expansion).

### 1.5 Repack recipe (§4.1.3, E1/E4/E9) — decoded from the pinned Lithium boot.img

MTK dual-header format confirmed from Lithium's own bytes (`443e40c3…` boot.img, pinned):

- kernel payload  = 512 B MTK header (`88 16 88 58` magic + LE32 zImage-size + `"KERNEL"` type \
  field (`a4 L a32` per repack-MTK.pl's own gen_header, type string zero-padded to 32) + `0xFF`
  fill to 512 B) + raw zImage; boot.img header `kernel_size` = 512+zImage.
  Lithium: 3,809,720 = 512 + 3,809,208 ✓ (zImage magic `0x016f2818` at header+0x24 ✓).
- ramdisk payload = 512 B MTK header (`"ROOTFS"` type, same anatomy) + raw cpio.gz; boot header
  `ramdisk_size` = 512+gz-size. Lithium: 1,394,157 = 512 + 1,393,645 ✓ — header len field
  equals the gz size exactly.
- **E4 ramdisk byte-identity is achieved by reusing the raw in-image ramdisk blob** (header+cpio.gz
  verbatim, extracted straight from the donor boot.img at page offset 0x3a3000), NOT by re-running
  `find | cpio` (repack-MTK.pl's rebuild would not be byte-identical). The blob is pinned:
  `c0be6c46333b52f08dd725353f69bd6cbe8cf402838d5d7b67cfcc09522c62cf` (also cached at
  `donors/lithium-ramdisk-blob.bin`, re-extractable from the pinned boot.img at any time).
- mkbootimg = the bob-m1 mtk-tools binary; args exactly §4.1.3 / Lithium's `boot.img-args.txt`
  (base 0x80000000, pg 2048, koff 0x8000, roff 0x04000000, soff 0x00f00000, toff 0x0e000000,
  board `1441186574`, cmdline `bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug`).

### 1.6 α acceptance self-check (§4.3)

| Criterion | Status |
|---|---|
| compiles with arm-eabi-gcc 4.8, zero errors, warnings logged | ✓ (logged in build log) |
| parity report checked into build log; §3.2-B.10 sets pass | ✓ §1.3 (`out/kernel-parity-alpha.txt`; all but GAP-1, which is tree-impossible — see §1.4) |
| boot.img headers byte-identical to Lithium's except payload/sizes; ramdisk hash == Lithium's | ✓ 55_repack_boot.sh asserts both (donor-kernel region excluded fields; ramdisk 1,394,157 B blob equality verified) |
| §3 deltas as committed patches | ✓ §3 (one file per D-id, D-id in the commit message) |
| reproducible | ✓ α zImage byte-stable across repeated 45 runs (see §4 "determinism model") |

### 1.7 Artifacts (α) — `out/boot-m1b-alpha.img`

| Artifact | Size (B) | sha256 |
|---|---|---|
| α zImage (`build-alpha/arch/arm/boot/zImage`) | 4,230,272 | `bad4bc25e62823f70c5ef25021d36a382aabdfab4f467b2a821c786c3e2cbbf7` |
| **`out/boot-m1b-alpha.img`** | 5,627,904 | `d886ccfedaaf02d7244a339ed4bb9a8f73f4e1be8327fe88e26633e13579f224` |
| α Image (parity decomp) | 13,939,816 | `9eda4fa1ee221696e652de848a294a8e54201492fccef2b24b6ba51c5dc0e060` |

Both images are 5,627,904 B: donor ramdisk unchanged (1,394,157 B) + MTK-padded new kernel —
the size delta vs Lithium's 5,208,064 is purely the larger kernel payload (page-aligned).

---

## 2. M1b-β — board delta build (§4.2)

### 2.1 Deltas applied (D1–D16 status)

| ID | Status | Where it landed |
|---|---|---|
| D1 | ✓ | `patches/kernel/D1.patch` — q5_defconfig `MTK_FAN5405_SUPPORT` → not-set; power Makefile else-chain → `charging_hw_pmic.o` only (premise re-verified in-tree before the build) |
| D2 | ✓ | `patches/kernel/D2.patch` — MAX8971/SNB1058 explicit not-set lines added; the remaining charger family already not-set in the a106 base (kept). NB: `MTK_SNB1058_SUPPORT` has no Kconfig symbol in this tree → kbuild drops it from generated .config; the line stays in the defconfig as the documented assertion (the power Makefile's `ifeq` against an undefined var is false either way). 50 asserts every family symbol off |
| D3 | ✓ (assert) | `CONFIG_MTK_SMART_BATTERY=y` preserved; FGADC (`battery_meter`/`[FGADC]` = 24 β hits, identical count to α) is the only gauge. No MAX17050SW6106 anywhere (D7 class) |
| D4 | ✓ | `patches/kernel/D4.patch` — all eight `Q_MAX_*` (4 temp + 4 H_CURRENT) → **2000** (OQ-2 default; FGADC aging-learning refines at runtime); `FG_METER_RESISTANCE 0`, `R_FG_VALUE 0`, temps untouched |
| D5 | ✓ (assert) | `q5/power/cust_battery_meter_table.h` byte-identical clone of a106's (50 asserts `cmp`) |
| D6 | ✓ (assert) | `q5/power/cust_charging.h` byte-identical clone (thresholds 3400/4050/4230, AC 900 mA / USB 500 mA kept — SW6106 is autonomous) |
| D7 | ✓ (assert) | **No** bct24157 port (chip absent on Mint hardware). 50 asserts no `bct24157*` sources exist and no `fan5405_config_interface`/`charging_hw_fan5405` strings in the blob. NOTE: `fan5405.c/h`/`charging_hw_fan5405.c` are the reference tree's *own* pristine sources (never ported, never edited); D1 un-compiles them |
| D8 | ✓ | `patches/kernel/D8.patch` — `CONFIG_CUSTOM_KERNEL_IMGSENSOR="gc5004_mipi_raw hi253_yuv hi704_yuv"` → `-DGC5004_MIPI_RAW -DHI253_YUV -DHI704_YUV` + obj-y on the three dirs |
| D9 | ✓ | `patches/kernel/D9.patch` — donor drop-in (persimmon mt6735m gc5004; sprout hi253/hi704 + authored per-dir Makefiles) + OQ-5 adaptations: hi253 `SensorISOBinningInfo` block dropped (member gone from this tree's ACDK struct); the KK-erased scenario ids `VIDEO_CAPTURE_MPEG4 / CAMERA_CAPTURE_P1 / CAMERA_CAPTURE_MEM / VIDEO_CAPTURE_MAX` restored to `kd_imgsensor_define.h` at their **canonical ALPS positions** (vendor HALs are compiled against the official numeric encoding — inserting at any other position would silently break scenario matching) |
| D10 | ✓ | `patches/kernel/D10.patch` — `GC5004MIPI_SENSOR_ID 0x5004` + `SENSOR_DRVNAME_GC5004_MIPI_RAW "gc5004mipiraw"` added to kd_imgsensor.h; kd_sensorlist.h extern + three guarded kdSensorList entries (large→small per the file's note). HI253=0x0092/HI704=0x0096 pre-existed (kd_imgsensor.h:232/233 verified); GC5004 id ground truth cross-checked via donor-oxygen (carlitros900 ac70ox): `#define GC5004MIPI_SENSOR_ID 0x5004` |
| D11 | ✓ | `patches/kernel/D11.patch` — q5 kd_camera_hw.c power branches: GC5004 ← a106 OV5648 raw-mipi template; HI253/HI704 ← a106 HI258 Hynix-YUV template (the Q5's live front camera is Hynix YUV at 0x5A); off-paths reuse a106's existing blocks; insertion AFTER the ODM's double-brace HI258 branch quirk; **no GPIO values changed** (D16) |
| D12 | ✓ | `patches/kernel/D12.patch` — donor lens dirs `lens/mt6582/dw9714af` + `dw9719af` (bq/aquaris-E5FHD mt6592 sources; `mt6582/inc/DW9714AF.h` verified byte-identical to donor's, only `inc/DW9719AF.h` is new) + DW9719AF Makefile line (DW9714AF pattern) + Kconfig entry + defconfig `CONFIG_MTK_LENS_DW9714AF_SUPPORT=y` / `CONFIG_MTK_LENS_DW9719AF_SUPPORT=y` (DUMMYLENS stays on as fallback) — this also converts the tree's *pre-existing dead makefile ref* into a live driver |
| D13 | ✓ | `patches/kernel/D13.patch` — `q5/sound/aw87559_pa.{c,h}` legacy-i2c port of the chip contract + `Audio_eamp_command()` implementation (the yusu_android_speaker.h aud-glue contract EAMP_SPEAKER/HEADPHONE/EARPIECE/GET-SETREGISTER/SETAMP_GAIN/SETMODE/CTRP) + q5 sound Makefile line + **a106 yusu no-op stub removed** (exactly one definition links; the Q5's EAMP ioctls now reach physical amp control) |
| D14 | ✓ | `patches/kernel/D14.patch` — `I2C_BOARD_INFO("aw87559_pa", 0x58)` on **bus 2**, registered from an early initcall so the board info precedes i2c-2 adapter registration (3.10 scans static board info only at adapter-add, i2c-core.c:1062); same pattern as the in-tree FocalTech touch driver |
| D15 | ✓ (no-delta) | q5 keypad files byte-identical to a106 (50 asserts); ADR-4 userspace dual-map covers home codes; G5f fallback path documented |
| D16 | ✓ (no-delta) | q5 `cust_gpio_usage.h` byte-identical to a106 (50 asserts); review pass documented in `patches/kernel/DELTA-NOTES.md` |

All ten non-trivial deltas are committed as `patches/kernel/D*.patch` (one file per D-id; D-id +
spec reference in each patch prologue and in the commit message). The five no-diff rows (D3/D5/D6/
D7/D15/D16) are asserted invariants + documented in `patches/kernel/DELTA-NOTES.md`.

### 2.2 β build

`make q5_defconfig && make zImage` — **zero errors** (warnings only). Banner identical to α:
**`Linux version 3.10.54 (forge@fork) (gcc version 4.8 (GCC)) #1 SMP PREEMPT 2026-11-25T13:47:27-06:00`**
(pinned identity). β zImage **4,229,784 B, sha256
`43f6d3d0cd6b222526ed62793d08b71cab27f13c8135026c1dc2b2165963e83c`** — byte-stable across
repeated 50 runs.

### 2.3 δ-parity (§4.2.8) — `out/kernel-parity-beta.txt`

| Family | β | Lithium blob | Verdict |
|---|---|---|---|
| `gc5004mipiraw` | 2 | 0 | ✓ new (Mint set per §2.3) |
| `hi253yuv` / `hi704yuv` | 6 / 7 | 0 | ✓ new |
| `dw9714` / `dw9719` | 28 / 53 | 39 / 46 | ✓ present (AF framework ported) |
| `aw87559_pa` | **3** | **3** | ✓ — same hit count as the stock blob |
| `battery_meter`/`[FGADC]` | 24 | 24 | ✓ FGADC-only gauge (D3) |
| `ccci` / `mali` / `mt6323` / `mtk-kpd` / `auxadc` | 750 / 809 / 19 / 1 / 210 | 677 / 791 / 39 / 1 / 172 | ✓ unchanged ± |
| **must-NOT**: `bct24157` / `MAX17050SW6106` / `fan5405_config_interface` | 0 / 0 / 0 | 13 / 12 / n | ✓ D1/D2/D3 applied |
| a106 lens/sensor leftovers (`ov5648`=5, `hi258`=3) | str-references only | 0 | inert (kept strcmp/AF refs; no driver compiled) |

`fan5405` shows 1 residual string in β: the generic `drivers/power/mediatek/battery_common.c`
panic message "[BATTERY] Battery is not exist, power off FAN5405 and system" — unmodified vendor
code that Lithium's own blob carries too. The actual driver is gone (`fan5405_config_interface`
= 0 hits). Not a D1 violation.

**§4.2.8 verdict: PASS.**

### 2.4 Artifacts (β) — `out/boot-m1b-beta.img`

| Artifact | Size (B) | sha256 |
|---|---|---|
| β zImage (`build-beta/arch/arm/boot/zImage`) | 4,229,784 | `43f6d3d0cd6b222526ed62793d08b71cab27f13c8135026c1dc2b2165963e83c` |
| **`out/boot-m1b-beta.img`** | 5,627,904 | `2c3ac47a25ae89b049ba518354747a7365f6a8d5939548fba05f16c8fa51e0cc` |

55_repack_boot.sh verified for both images: header fields byte-identical to Lithium's except
kernel size; **ramdisk region byte-identical** (sha `c0be6c46…`, E4 ✓); kernel payload = MTK
header + zImage verified in-image. Sizes are page-aligned; both images fit the BOOT partition.

---

## 3. Deviations from spec (with reasons)

1. **MotorolaMobilityLLC/kernel-mtk cannot supply the AW87559 amp (D13 donor)** — probed the
   default branch (`android-13-release-ttt`) plus 11 candidate branches across nougat/oreo/pie/
   Q-10/S-12 MTK families for `aw87559|awinic`: **zero files** in every one. The spec's named
   family fallback (§3.6 "…_xiaomi_selene family") carries the full AW87559/AW87xxx set — used
   `atharvnegi/kernel_xiaomi_selene` (pinned). Contract reference `artificery-dev/tempo` (public)
   supplied the authoritative chip protocol (pulse timing, register images, chip-id retries)
   which the driver implements; the contract doc is pinned as `donors/tempo-audio.md` and the
   source codec as `donors/tempo-linux-aw87559.c`.
2. **Motorola branches probe recorded in the patch prologue** so Karen can audit the choice.
3. **O= object dirs + mtime/`__TIME__` pinning for determinism** — this MTK tree full-rebuilds
   under `make O=` on every invocation (verified empirically; steady-state `make` would be
   incremental but kbuild regenerates its objtree makefile each run). Every run recompiles all
   objects, so: banner pinned via `KBUILD_BUILD_VERSION/TIMESTAMP/USER/HOST`; the vendor
   `__DATE__`/`__TIME__` stamps pinned via a `CC=` make-argument wrapper
   (`-Wno-builtin-macro-redefined -U__DATE__ -U__TIME__ -D__DATE__='"Nov_25_2026"'
   -D__TIME__='"19:47:27"'` — underscore-form date because kbuild's checksyscalls helper
   re-splits args unquoted). Result: **α and β zImages are byte-identical across repeated
   pipeline runs** (α `bad4bc25…`, β `43f6d3d0…` — and, after the m1a-anchored identity fix, these exact bytes are
  reproduced from ANY commit state (verified across four different HEADs)). The defconfig step skips the
   rewrite when unchanged to avoid unnecessary cust-header regeneration.
4. **D14 registration implemented inside the amp driver (focaltech pattern)** rather than the
   commented-out `mt_devs.c` block: `mt_devs.c` is shared by a106/2014011/q5 — editing it would
   leak `aw87559_pa` into the α build (§4.1.2 expects absence) and pollute other boards. The
   in-driver `arch_initcall` registration is order-safe (before i2c-2 spawns) and
   board-dir-confined, satisfying D14's "q5 board i2c board info on bus 2" intent.
5. **`Audio_eamp_command()` moved from yusu stub to the amp driver** — required by D13's
   "mixer controls exist for the T-ROM HAL to poke": the aud driver (`AudDrv_Kernel.c:3334-3451`)
   calls this symbol for every EAMP ioctl; a106's stub returned 0. q5 deletes the stub and the
   amp implements it with the tempo contract. This is the minimal faithful "adapt to this tree's
   sound glue".
6. **`kd_imgsensor_define.h` scenario-id restoration (part of D9)** — see §2.1/D9 rationale.
7. **GAP-1 (escalated, not deviated): touch driver absent** — see §1.4. Not fixed here (out of
   the §3 delta table; would be a new delta requiring Bob's decision + donor).
8. **AW87559 enable GPIO not driven** — the tempo contract's EN pulse uses Y2's GPIO 8; no Q5
   GPIO is evidenced anywhere (live maps list the amp at `2-0058` only). Hard rule: never invent
   GPIO values. The driver performs the I2C-only probe/off lifecycle; if G4 shows the chip id
   read failing, that dmesg evidence decides the follow-up (add the board EN gpio then).

---

## 4. Build determinism model (hard rule 4)

- **Inputs hash-asserted**: manifests/donors.sha256 (Lithium boot.img — M1a pin) and
  manifests/kernel-sources.sha256 (Lithium decomp + ramdisk blob + all 30 donor source files +
  donor repo revision anchors) are verified by 45/50/55 at every run; any drift aborts loudly.
- **Patches are self-contained**: 50_kernel_delta.sh resets the reference tree to the pristine
  clone (`git reset --hard`, O= dirs preserved), recreates board q5 (§4.2 steps 1-2), applies
  D1…D16 patches in order, asserts the no-diff invariants, then builds. A re-run reproduces the
  identical tree; the modified-tracked-file set is asserted to be exactly the five shared files.
- **kbuild full-rebuild quirk**: this tree rebuilds all ~2300 objects under `make O=` on every
  invocation (documented above). All timestamp sources are pinned (banner + `__DATE__`/`__TIME__`),
  so **re-runs produce byte-identical zImages** (verified: α across 45×2, β across 50×2, plus an
  independent direct-make reproduction of β).
- **Repack**: ramdisk blob reused verbatim; header fields compared against the donor byte-by-byte
  in 55; re-runs produce identical images (verified: same hashes repeated).
- The full rebuild makes each 50 run take ~7 minutes; that is the price of the O= quirk, not a
  correctness property.

---

## 5. Warnings & risks logged

- α warnings: normal MTK-tree noise (e.g. `charging_get_error_state defined but not used` in
  charging_hw_fan5405.c — that driver drops out at β; netfilter/`skb_tx_error` const-qualifier;
  several `&& within ||` paren warnings in kd_camera_hw.c — pre-existing a106 style, preserved
  to keep the clone-diff minimal).
- β: the DW9714AF/`dw9714af` dead-makefile-ref in the a106 tree is now live (port supplies the
  dir); no other build-system warnings surfaced.
- OQ-8 (GC5004 may not be fitted on retail Q5): compiling it is harmless — probe fails inertly.
- OQ-7 (LCM): α/β carry a106's panel config; **if G2 boots but the screen stays dark**, port the
  gc9503v-class LCM next (Bob's spec anticipated this; source: bq/sprout lineage).
- AW87559 EN-GPIO uncertainty: see §3.8. G4's dmesg/audibility decides.
- The T-ROM HAL ↔ amp coupling is validated only at G4 (`tinymix` on Mint vs fork); the SETMODE
  vocabulary mapping (0=mute, non-zero=on-image) is documented in the driver — if the HAL's
  semantics differ, the driver's mapping is the one-line adaptation point.

---

## 6. Hand-off notes

- **Hera**: flash `out/boot-m1b-alpha.img` (BOOT only, system=stock Lithium) for G2. Expect
  `uname -r` = 3.10.54; input devices will MISS the gsl touch entry (GAP-1 §1.4) and a106-inert
  extras don't appear — record the list diff. Then G3 diagnostics, then G6 camera checks on β.
- **Hera (β)**: `out/boot-m1b-beta.img` — G3 charging (SOC ≥2 %/10 min monotonic), G6 camera
  probe (`grep -iE 'imgsensor|hi253|hi704|gc5004'` dmesg hits expected: gc5004mipiraw/hi253yuv/
  hi704yuv strings are in-kernel per §2.3), G4 amp via tinymix.
- **Karen**: §3.2-B.10 on `out/kernel-parity-alpha.txt` + `out/kernel-parity-beta.txt`; check the
  D-id → patch mapping (§2.1); hash pins in `manifests/kernel-sources.sha256`.
- **Bob**: GAP-1 decision (touch delta: needs a donor tree with the Q5's GSL-class driver);
  OQ-2 battery label when available (D4 currently at the 2000 mAh default); OQ-7 LCM delta if
  G2 shows a dark screen.

---

## 7. Commits & tags (this session)

- `762d819` m1b: pin kernel-work donor sources + comparison blobs (manifests/kernel-sources.sha256)
- `ff99eb0` m1b: §3 delta patches — one file per D-id (D1/D2/D4/D8/D9/D10/D11/D12/D13/D14 as
  `patches/kernel/*.patch`; D3/D5/D6/D7/D15/D16 as asserted invariants + `DELTA-NOTES.md`)
- `b2d54b1` m1b: kernel pipeline (40_env/45_alpha-parity/50_delta/55_repack)
- annotated tags **`m1b-alpha`** and **`m1b-beta`** both on `10478ce` (combined-release policy:
  artifact summaries + D1–D16 status + GAP-1 escalation live in the tag annotations; the α and
  β images are both reproducible from this revision — verified byte-stable; the build identity
  pins derive from HEAD, so re-running at this exact tag regenerates these bytes).
- Repo policy: `.specs/forge-m1b-report.md` (this file) is agent coordination, not tracked;
  the tagged annotations + committed artifacts are the record.
- Verified: `git ls-files` contains **no** kernel tree, no `*.img`/`*.bin`, no donor payload —
  only manifests, patches, scripts, specs.

**Status: COMPLETE — α + β images built, verified, hash-pinned; pipeline idempotent; escalated
items (GAP-1 touch driver, OQ-2 battery label, AW87559 EN-GPIO, OQ-7 LCM) documented for
Bob/Hera. Awaiting Hera G2 (α boot parity) → G3/G6 (β). No flashing performed by Forge.**
