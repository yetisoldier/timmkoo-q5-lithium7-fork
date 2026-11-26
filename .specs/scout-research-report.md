# Scout Research Report — MT6582 Firmware Porting for the Lithium 7 → Q5 "Mint" Fork

**Research Question.** What tools, techniques, and existing community resources does the architect need to port correct hardware config (charging, speaker, buttons) from the Q5 Mint Android 4.4.2 base into the MediaTek MT6582 Android 7.1.2 ("Lithium 7") ROM?

## Summary

The single most important finding is an architectural caveat: **MT6582 kernels of this era (ALPS, Linux 3.4.67) are board-file-based, not device-tree-based**, so the Q5 stock/Lithium boot.img most likely contains *no* DTB at all. The DTB workflow must therefore start with a detection step; if no DTB is found, charging/fuel-gauge config lives in compiled-in kernel board headers (`mediatek/custom/<project>/kernel/battery/...`), which changes where the charging fix must be made. For audio, MTK's stack does not use Qualcomm-style `mixer_paths.xml` — routing/volumes live in `audio_policy.conf` plus MTK-specific `audio_device.xml` and the `audio.primary.mt6582.so` HAL, and the `audio_hal_version` 2.0-vs-3.0 mismatch in the broken build is a known failure class for policy parsing. A rich ecosystem of existing resources exists: the Sendew Mint ROM repo, NoahDomingues/Lithium (+ its MTK-ROM-Porter tool), and especially **T-ROM-Project's `android_vendor_t-rom_q5_q3e_mt6582` vendor-blobs repo** (the likely source of a known-good Nougat-era audio HAL) and the **artificery-dev/tempo** project, which documents the AW87559 amp on a sibling Innioasis MT6582 device (Y2) down to the register images and enable-GPIO sequence. Google's own Android One (sprout) MT6582 kernel source on android.googlesource.com contains the full fan5405 / MT6323 charging driver stack as reference.

## Findings

### 1. DTB extraction, patching, and repacking from an MT6582 boot.img

**Critical first step — detect whether a DTB exists at all.** MT6582 ALPS kernels are Linux 3.4.67; on these, hardware config (GPIOs, battery, charger selection, I2C tables) is compiled into the kernel from board headers under `mediatek/custom/<project>/kernel/...` (e.g. `cust_battery.h`, `cust_fuel_gauge.h`, `cust_gpio_usage.h`) selected via `ProjectConfig.mk` — *not* from a device tree. Only 3.10/3.18-era MTK platforms (MT6735/53 etc.) moved this into DTS (a `mediatek,battery` node). The Lithium 7 kernel release ships "kernel & ramdisk", consistent with a classic MTK boot.img layout.

Concrete workflow:

1. **Unpack boot.img.** Any of:
   - `bgcngm/mtk-tools`: `unpack-MTK.pl boot.img` — explicitly supports MT65x2 (MT6572/82/92); prints full header info (base, offsets, page size, cmdline) and writes a repack-args file used later by repack.
   - `osm0sis/AndroidImageKitchen`: `unpackimg.sh boot.img` → splits kernel/ramdisk/etc. into `split_img/`.
   - `xiaolu/mkbootimg_tools`: `mkboot name.img outfolder` (also handles a `dt.img` "second"/dtb section when present).
2. **Probe the kernel blob for an FDT.** The DTB magic is `0xD00DFEED`:
   - `grep -abo $'\xd0\x0d\xfe\xed' boot.img-kernel` (find candidate offsets), or
   - `extract-dtb` (PabloCastellano, PyPI `pip install extract-dtb`): runs directly on a boot.img or zImage, splits appended DTBs: `extract-dtb -o out_dir boot.img`, or `-n` for info-only. Equivalent: `split-appended-dtb` from rockchip-tools.
   - Check whether the boot.img header reports a non-zero `Second stage` size (MTK sometimes puts extra blobs there) and whether the image has a `dtb_size` (mkboot prints this).
3. **Decompile:** `dtc -I dtb -O dts -o board.dts board.dtb` (install `device-tree-compiler`). If `dtc` fails with "Blob has incorrect magic number", the blob has a leading offset — locate with `binwalk`, then `dd if=dtb.img skip=$((0xNN)) iflag=skip_bytes | dtc -I dtb -O dts`.
4. **Patch & recompile:** edit the `.dts`, then `dtc -I dts -O dtb -o board.dtb board.dts`.
5. **Reinsert:** for appended-DTB layouts, `cat zImage board.dtb > zImage-padded`; for boot-header DTB fields use `mkbootimg ... --dtb board.dtb`; then repack with the original parameters:
   - mtk-tools: `repack-MTK.pl -boot` (consumes the args file written at unpack time), or
   - AndroidImageKitchen: `repackimg.sh`, or
   - raw `mkbootimg --kernel ... --ramdisk new_ramdisk.gz --base 0x10000000 --kernel_offset ... --ramdisk_offset ... --tags_offset ... --pagesize 2048 --cmdline "..." -o new_boot.img`. MT6582 values are typically base `0x10000000`, kernel offset `0x00008000`, ramdisk `0x01000000`, second `0x00f00000`, tags `0x10000100`, page 2048 — but always use the values printed by your unpacker.
6. **Flash:** SP Flash Tool, scatter = `MT6582_Android_scatter.txt`, flash BOOT only, "Download Only" (community thread stresses: only with a verified stock backup for that exact hardware revision).

**If no DTB is found (the expected case):** the charging config is in the kernel build, so the fix options become (a) rebuild the kernel from an MT6582 source tree with the Mint board headers (see §2), (b) binary-patch the config tables in the zImage, or (c) determine whether the working/charging difference is actually in the ramdisk (e.g. `init` charging-offline hooks) or in `lk`/preloader — diff all boot.img components between KitsKat-Mint and Lithium builds.

### 2. Charger + fuel gauge configuration (fan5405, MAX17050, MT6323)

MTK's MT6582 power stack (reference: Google's Android One "sprout" MT6582 KitKat-MR2 kernel, `drivers/misc/mediatek/power/mt6582/`) contains:

- `charging_hw_fan5405.c` + `fan5405.c/.h` — the charger-IC driver. Behavior is hardwired via I2C register writes: init writes reg 0x06 (`VSAFE`/`ISAFE`, e.g. `0x70` or `0x77` when `high_battery_volt_enable` = 4.34 V/1250 mA), 0x01 (`TE/CE/HZ_MODE/OPA_MODE`), sets `IINLIM` (input-limit table 100/500/800 mA/max) and `IOCHARGE` (charge-current table 550–1250 mA). Charge enable/disable toggles the `GPIO_SWCHARGER_EN_PIN` and the fan5405 `CE` bit together. **That GPIO definition lives in `cust_gpio_usage.h` (DCT-generated), not a DT** — a wrong port = charger chip never enabled.
- `battery_common.h` / `battery_custom_data` — charge currents per source (AC/USB/host), CV/precharge thresholds, JEITA temperature table, `stop_charging_in_talking`, etc. On the 3.4 ALPS stack these come from `cust_battery.h` (per-project `mediatek/custom/<proj>/kernel/battery/battery/`, with `CUSTOM_KERNEL_BATTERY=battery` in ProjectConfig.mk); on 3.18 platforms the same struct moved into a `mediatek,battery` DTS node.
- `pmic_mt6323.c` / `pmic_chr_type_det.c` — MT6323 PMIC charger-detect and BMT (battery management) glue; MT6323 is a multifunction PMIC (regulators, RTC, ADC/auxadc, **audio codec**, GPIO, keys) hanging off the PMIC wrapper (pwrap/SPI).
- Fuel gauge: MTK's default is its own ADC-based gauge (`battery_meter_hal.c`), but this hardware has a discrete Maxim MAX17050 (I2C). The reported I2C name `MAX17050SW6106` is non-standard — SW6106 is an iSmartWare power-bank management SoC, suggesting a vendor-modified/hybrid gauge driver; there is no upstream driver matching that name (upstream `max17042_battery` covers max17042/17047/17050). Treat it as a custom vendor driver whose init must be discovered from the Mint firmware.

**Why "Max charging current: 0 / Max charging voltage: 0" appears:** in Nougat (and since Lollipop), these `dumpsys battery` fields are populated by healthd's `BatteryMonitor` from `/sys/class/power_supply/*/current_max` and `voltage_max` sysfs attributes. If the kernel power_supply driver never exports those attributes (very common on MTK vendor stacks), Android prints 0 — frequently a cosmetic artifact rather than the charging fault itself. The real fault ("battery stuck at 0–1%") points at the fuel gauge: the MAX17050 requires a host-driven init sequence (POR check, CONFIG/FilterCFG/RelaxCFG writes, unlock/write/verify/lock of the 48-word custom battery model at 0x80–0xAF) every power-up; if the ported ROM's gauge driver never runs that (wrong I2C address, wrong bus, missing driver), SOC reports 0–1% forever and the charge state machine can stay in odd states. 

**Recommended architect diagnostics before writing any patch:**
- `adb shell dumpsys battery` (both builds), `ls /sys/class/power_supply/`, `cat /sys/class/power_supply/*/{type,online,current_max,voltage_max,current_now,capacity,voltage_now}` — compare which attributes exist and their values, charging and not.
- `ls /sys/bus/i2c/devices/`, `i2cdetect -y 0/1` (root) — confirm the fan5405 (typically 8-bit addr 0xD4/0x6A) and the MAX17050SW6106 device probe on the Nougat build at all.
- `dmesg | grep -iE "bat|charg|fg|17050|fan5405|mt6323"` on both builds.
- Full byte-diff of boot.img components (kernel, ramdisk) between Mint-KitKat and Lithium-7 — given the speaker bug already showed userspace-only differences, check whether charging differs in kernel or ramdisk too.

### 3. Porting the MTK audio HAL + audio_policy.conf across 4.4 → 7.1

- **File layout:** Android 4.4 ships only legacy `audio_policy.conf`. Android 7.0 deprecated CONF in favor of `audio_policy_configuration.xml` but **kept CONF support** (gated by the `USE_XML_AUDIO_POLICY_CONF` build flag), so an MTK Nougat ROM still runs `audio_policy.conf` from `/system/etc` — keep that format, no XML conversion needed.
- **CONF format change that matters:** pre-HAL-3.0 files use one *global* `global_configuration` section; HAL ≥3.0 files move `global_configuration` into each hardware-module block and add `audio_hal_version <major.minor>`, optional named `devices { ... }` with `gains`, and profile `devices` references by name. The parser (frameworks/av `ConfigParsingUtils`) interprets sections differently depending on the declared `audio_hal_version`, and AudioFlinger rejects modules reporting below `AUDIO_DEVICE_API_VERSION_MIN` (2.0 on Nougat) with "wrong audio hw device version". **The broken build shipping `audio_hal_version 2.0` where the working one ships 3.0 is a classic port artifact:** the file was copied from (or generated for) a HAL whose `audio_hw_device.common.version` is `AUDIO_DEVICE_API_VERSION_2_0`, or vice versa. The declared version in audio_policy.conf must match what `audio.primary.mt6582.so` actually reports in its `HAL_MODULE_INFO_SYM`. Check the .so directly (the version word is in the module struct; `objdump`/`readelf` the data section, or read AudioFlinger logcat lines during `loadHwModule`).
- **ABI pitfall — don't reuse the KitKat .so:** 4.4-era MTK audio HALs are compiled against libhardware/libaudioutils structs of that era (`audio_hw_device` 1.x/2.0 without `create_audio_patch`, older `audio_stream_out`, different libutils symbol versions). Dropping the KK `audio.primary.mt6582.so` into Nougat will fail to load or misbehave. The correct pattern porting guides use: **take a Nougat-built MT658x audio HAL** (from an existing 7.1 build for this platform — T-ROM/Lithium lineage or the T-ROM vendor-blobs repo, see §4) **and graft the Mint-specific *config*** (audio_policy.conf primary-module contents, attached devices, sample-rate/channel lists that match the hardware).
- **mixer_paths.xml caveat:** classic MTK ALSA audio does not consume `mixer_paths.xml` (that is Qualcomm-style / newer MTK audio-v4 config). MTK routing/volume tables live in `/system/etc/audio_device.xml` (e.g. `device/mediatek/mt6580/audio_device.xml`) plus custom volume-parameter mechanisms read by the MTK `AudioALSAHardware` layer behind the legacy wrapper in `audio.primary.<plat>.so`. If Lithium 7 ships a `mixer_paths.xml`, verify whether the HAL binary actually strings-references it (`strings audio.primary.mt6582.so | grep -i mixer`); if not, the file is inert and the real knobs are `audio_device.xml` + `audio_policy.conf`.
- **Speaker-specific checks:** `primary` module must list `AUDIO_DEVICE_OUT_SPEAKER` in `attached_output_devices` and set it as `default_output_device`, with an output profile whose `devices` includes speaker. Verify at runtime: `adb shell dumpsys media.audio_flinger` and `dumpsys media.audio_policy` (shows parsed modules/profiles/routes and active device), and `logcat | grep -iE "AudioFlinger|APM::|audio_policy|loadHwModule"` at boot for parse errors. At the ALSA layer, `cat /proc/asound/cards`, and `tinymix`/`alsa_amixer` to diff mixer control states between a working (KitKat Mint) playback and the broken Nougat one — since the kernel is identical, the diff will show exactly which control the working HAL sets that the broken one doesn't (e.g. the speaker-enable control feeding the AW87559).

### 4. Existing Q5 / Lithium / Mint modding resources

- **Sendew/TIMMKOO-Q5-Mint-Custom-ROM** (GitHub, created Aug 2026, active): the Mint ROM itself. README documents that the Mint unit is a cheaper, discontinued AliExpress variant of the Q5 on the same base, rooted KitKat, SP-flashable. **This is the authoritative source of Mint-side stock config; check its releases/files for the underlying Mint backup dump.**
- **NoahDomingues/Lithium** (GPL-3.0): Lithium 7 source. Releases include "Lithium 7 Kernel v7.1.06.09.25" (kernel & ramdisk, Xposed-ready) and the scatter file. README explicitly lists "**No audio from speakers**" as a top known issue; the v7.1.06.13.25 release notes say "Attempted speaker audio fix, but speaker still does not work" (thanks to "Meowing Kibble" for working on it) — prior art on this exact bug to coordinate with.
- **NoahDomingues/MTK-ROM-Porter** (GPL-3.0, Python/Batch/Shell): one-step MTK ROM porter for **MT6572/82/92 on 3.4.67** (and tentatively MT6735(m)/37(m) 3.18). This is almost certainly the toolchain that produced Lithium 5/7 — studying its port steps tells the architect exactly what was and wasn't carried over (typical porters swap boot/kernel bits and copy system, which explains the audio HAL/config mismatch).
- **T-ROM-Project** org (github.com/T-ROM-Project, by palutenfan123 — the person Lithium credits with the original discovery): 17 repos including **`android_vendor_t-rom_q5_q3e_mt6582` (vendor blobs for Q5/Q3E MT6582 — prime source for a known-good Nougat audio HAL and stock /system/etc audio configs)**, **`android_device_t-rom_q5_q3e_mt6582` (device tree for building CM-12.1)**, and `dev-mtk-porting-tool`. T-ROM covers Q5/Q3E bought 2020–Mar 2025 (stable) vs Mar–Sep 2025 (beta) — directly relevant to hardware-revision mapping for the Mint.
- **Community:** XDA thread 4754055 "[ROM][7.1] Lithium 7 - Timmkoo Q5/Q3E" (flashing procedure via SP Flash Tool, modified-scatter fixes, reset-button timing; Q5_Update_v2_Munk3.rar 624.9 MB attachment = full stock-style factory package), r/innioasis, Discord "Timmkoo Modders", timmkoo.de, innioasis.app release-note pages (with hardware "Type A / Type B" revision warnings for sibling models). Multiple Q5 hardware revisions exist (rocker vs 3-button "7th gen"; crease between volume buttons identifies the MT6582 units) — the Mint is yet another revision, so revision-specific blobs matter.
- **Reference kernel source:** `android.googlesource.com/kernel/mediatek` branch `android-mediatek-sprout-3.4-kitkat-mr2` — complete MT6582 3.4.67 tree including the full power stack (fan5405, mt6323, battery meter). Also `MTK-Kernels/MT6592-KK-KERNEL` (ALPS.KK1, shared MT6582/6592 tree) and various OEM MT6582 trees (gionee_m3, alcatel_mt6582m with full `mediatek/config/mt6582/ProjectConfig.mk`) as worked examples of project config selection.

### 5. AW87559 amp + MT6323 codec notes

- **Best available documentation: `artificery-dev/tempo`** (`docs/porting/audio.md`) — a Linux port for the **Innioasis Y2, a sibling MT6582 music player**. It gives a working ASoC implementation: machine driver `mt6582-cs43131.c` (Headphone/Speaker pins, mono speaker mode), codec driver **`sound/soc/codecs/aw87559.c` containing the vendor register images for AW87559 and OCA72559**, DTS (`mt6582-innioasis-y2.dts`) with:
  ```dts
  aw87559: amplifier@58 {
      compatible = "awinic,aw87559";
      reg = <0x58>;
      enable-gpios = <&pio 8 GPIO_ACTIVE_HIGH>;
      sound-name-prefix = "PA";
  };
  ```
  and the exact enable behavior: on Speaker-pin up the DRV widget **pulses the enable line low 10 ms then high 100 ms, then reads the chip ID (0x5A = AW87559, 0x09 = OCA72559)**. Note tempo's Y2 uses an external CS43131 DAC on the AFE's "2nd I2S" and does *not* use the MT6582's on-chip ADDA/class-D — the Q5 differs (codec = MT6323 internal), but the **AW87559 enable/init contract (enable GPIO + I2C reg sequence) transfers directly**.
- **Vendor sources:** Awinic's AW87559FCR product page ships the official datasheet (DS_AW87559_EN_V1.4) and an official Android/Linux driver package ("AW87559FCR_Driver" / "AW87XXX_Driver": sample code, porting guide, debugging guide) plus the AW87559_GUI tuning tool (requires AwinicSCPV4). Chip facts: 5th-gen "Smart K" class-D, 9 V adaptive boost, 4.75 W @ 8 Ω, I2C-programmed boost voltage/peak current/gain/TLTR-AGC, speaker+receiver 2-in-1, 1.8 V-logic I2C. If the Mint KitKat firmware contains a vendor DSP/firmware (`.bin`/reg init) file for the amp, it must ride along in the port.
- **MT6323 codec side:** MT6323 embeds the audio codec (upstream binding `mediatek,mt6323` under pwrap lists "Audio codec" among submodules). On MTK Android stacks the SoC machine driver is `mt_soc_pcm_*` + MT6323 codec driver, with mixer control names surfaced to the HAL via ALSA. Since the kernel zImage is byte-identical between working and broken builds, the kernel side (AFE→MT6323→AW87559 hooks) is fine; the defect is that the Nougat HAL never pokes the speaker-enable mixer control/GPIO the KitKat HAL did — confirming the `tinymix`-diff approach in §3 as the fastest fix path.

## Options Compared

| Approach | Effort | Risk | Notes |
|---|---|---|---|
| **A. Assume DTB in boot.img, patch .dts** (extract-dtb → dtc → patch → repack) | Low if it works | Brick if misidentified | Only valid if kernel actually uses DT — detection step (FDT magic scan) decides in minutes. Most MT6582 3.4.67 builds have **no** DTB. |
| **B. Kernel board-config path (no DTB):** rebuild kernel with Mint board headers, or binary-patch zImage tables | Medium–High | Medium (boot loops) | Matches ALPS architecture for charging (cust_battery.h, cust_gpio_usage.h, GPIO_SWCHARGER_EN_PIN, I2C tables, fan5405 selection flags). Requires MT6582 kernel source (sprout/OEM trees as base) and a working 4.8-era arm-eabi toolchain; `./mk <project> n k` build flow per existing MT6582 kernel repos. |
| **C. Audio: graft Mint config onto a Nougat-built MTK HAL** (from T-ROM vendor blobs / Lithium lineage), fix `audio_hal_version` to match the .so, merge `audio_device.xml` | Low–Medium | Low | Highest-confidence fix path; kernel proven identical so defect is purely which ALSA controls the HAL drives. Validate with dumpsys media.audio_flinger + tinymix diff against KitKat Mint. |
| **D. Audio: reuse KitKat HAL .so on Nougat** | Low | High | ABI mismatch (audio_hw_device 2.0 vs 3.0, libutils symbols) — fails load or drops functionality. Not recommended. |
| **E. Charging: treat "Max charging current 0" as cosmetic** and fix only gauge init | Low | May miss real bug | The 0s alone are often cosmetic on MTK; the stuck SOC is the real symptom → focus on MAX17050SW6106 probe/init. Verify with sysfs diff before kernel work. |

## Recommendation

1. Run the **boot.img component diff and FDT detection first** (Option A detection step, one afternoon): unpack both Mint-KitKat and Lithium-7 boot.imgs with `mtk-tools` or AndroidImageKitchen, hash kernel/ramdisk separately, scan for `0xD00DFEED`. This decides §1 vs §2 architecture and, combined with the already-known identical zImage for audio, scopes exactly which config lives where.
2. For **audio**, take Option C: source the Nougat-era `audio.primary.mt6582.so` + stock Q5/Q3E `/system/etc/audio*` set from **T-ROM-Project's vendor blobs repo**, set `audio_hal_version` in audio_policy.conf to the version the .so reports (3.0 per the working build), port the Mint's primary-module attached/default devices, and confirm with a `tinymix` control diff vs. the KitKat Mint build that the AW87559 enable/GPIO control is being set. Do not rely on `mixer_paths.xml` unless the HAL strings-reference it.
3. For **charging**, instrument first (dumpsys battery + `/sys/class/power_supply` + `i2cdetect` on both builds). If the fan5405/gauge devices don't probe on Nougat, go Option B: rebuild the kernel with Mint-side `cust_gpio_usage.h`/battery/I2C config (sprout MT6582 tree + MT6582 OEM trees as reference), since there's very likely no DTB to patch. Ignore the "Max charging current 0" fields per se — fix the gauge SOC.
4. Engage existing maintainers (NoahDomingues, palutenfan123/T-ROM, Sendew, Meowing Kibble) — the speaker fix is an open known-issue on their tracker, and the Mint repo author is actively working now.

## Risks & Unknowns

- **No direct inspection yet:** whether Lithium's boot.img truly lacks a DTB is a strong inference (3.4.67 ALPS + release notes mention only "kernel & ramdisk"), not a verified fact — the 10-minute magic scan settles it.
- `MAX17050SW6106` has no public driver match; the naming hints at a custom/hybrid gauge (possibly involving an SW6106 power-management chip). Its init contract must be reverse-engineered from the Mint firmware (strings/symbols in the stock kernel or hal, I2C traffic on the working build).
- Whether AW87559 init on Q5 is pure GPIO+I2C-regs (as on the Y2 in tempo) or requires a firmware blob download is unknown until the stock files/HAL are inspected.
- Button fixes weren't directly addressable from public sources; likely keylayout/GPIO differences — MT6323 "Keys" submodule + `/system/usr/keylayout` and DCT GPIO config are the places to diff (same process as audio: compare working vs broken builds).
- Multiple Q5 hardware revisions mean blobs from the wrong revision can regress other things — the Mint dump (via Sendew's repo) must be the authoritative donor.
- Flashing risk: community guidance is emphatic about having verified stock firmware for the exact revision before flashing (SP Flash Tool, Download Only, correct scatter).

## Sources

1. github.com/bgcngm/mtk-tools — MTK unpack/repack scripts (explicit MT6582 support; prints header/base/offsets; auto repack-args).
2. github.com/xiaolu/mkbootimg_tools — `mkboot` unpacker/repacker incl. dt.img handling; dtbTool usage.
3. github.com/PabloCastellano/extract-dtb — split appended DTBs from kernel/boot.img (PyPI).
4. cnx-software.com "How to Extract a Device Tree File from Android Firmware Files" — split_bootimg.pl + dtc decompile workflow.
5. wiki.nura.eco "Device Tree (dtb)" / PostMarketOS-style guide — extract-dtb + unpackbootimg + dtc, bad-magic offset handling with binwalk/dd.
6. android.googlesource.com/kernel/mediatek (android-mediatek-sprout-3.4-kitkat-mr2), `drivers/misc/mediatek/power/mt6582/` — charging_hw_fan5405.c, fan5405.c, pmic_mt6323.c, pmic_chr_type_det.c, battery_meter_hal.c (register-level fan5405 behavior).
7. android.googlesource.com/kernel/mediatek (android-mtk-3.18) `battery_common.h` — battery_custom_data struct (charge current tables, JEITA, thresholds) that corresponds to cust_battery.h / DTS battery node.
8. cnblogs.com/cyqx/p/4870785.html — MTK battery config file locations: `mediatek/custom/<proj>/kernel/battery/battery/cust_battery.h`, `custom_fuel_gauge.h`; charge-current/R_sense/NTC defines.
9. github.com/diparthshah/android_kernel_gionee_m3-mt6582 (+ alcatel_mt6582m ProjectConfig.mk) — MT6582 3.4.67 build flow (`mk <project> n k`, ProjectConfig.mk feature selection).
10. source.android.com/docs/core/audio/implement-policy — Android 7.0 audio policy: CONF deprecated but supported via USE_XML_AUDIO_POLICY_CONF; XML format.
11. android.googlesource.com/platform/frameworks/av `services/audiopolicy/audio_policy.conf` template — CONF syntax, global_configuration scope change at HAL 3.0, `audio_hal_version` tag, devices/gains sections.
12. android.googlesource.com frameworks/av `audio_policy_conf.h` — parser tags; CONF path /system/etc/audio_policy.conf.
13. e-com-net.com "mtk audio" — MTK Nougat audio stack walkthrough: legacy_audio_module, loadHwModule, "wrong audio hw device version" version check, MT6580 audio_policy.conf example, `device/mediatek/mt6580/audio_device.xml`.
14. github.com/Sendew/TIMMKOO-Q5-Mint-Custom-ROM — Mint ROM; device-variant background.
15. github.com/NoahDomingues/Lithium + releases — Lithium 7 known issues (no speaker audio), kernel+ramdisk release, scatter file.
16. github.com/NoahDomingues/MTK-ROM-Porter — one-step porter for MT6572/82/92 3.4.67.
17. github.com/T-ROM-Project (android_vendor_t-rom_q5_q3e_mt6582, android_device_t-rom_q5_q3e_mt6582, dev-mtk-porting-tool) — vendor blobs + device tree; palutenfan123/timmkoo.de.
18. xdaforums.com thread 4754055 (Lithium 7) — flashing workflow, hardware-revision identification (MT6582 units 2022–2024, volume-rocker crease vs 3-button 7th gen), Q5_Update_v2_Munk3 factory package.
19. innioasis.app release notes v7.1.06.13.25 — "Attempted speaker audio fix, but speaker still does not work"; Type A/B revision warnings.
20. github.com/artificery-dev/tempo `docs/porting/audio.md` — AW87559 on sibling MT6582 device (Innioasis Y2): aw87559.c codec driver with vendor register images, DTS binding (reg 0x58, enable-gpios), enable pulse + chip-ID 0x5A sequence, AFE/I2S path.
21. awinic.com AW87559FCR product pages — datasheet, official Android driver package (AW87559FCR_Driver/AW87XXX_Driver), GUI tuning tool.
22. analog.com MAX17050 page + MAX17047/MAX17050 datasheet + EngineerZone "How do I load an INI file onto the MAX17050" — mandatory host init sequence (POR, config writes, 48-word model unlock/write/lock); kernel.org Kconfig max17042 family coverage.
23. bytescope.dev / developer.android.com dumpsys battery field semantics — Max charging current/voltage sourced from power_supply sysfs (microamps/microvolts); OEM-dependent presence.
24. kernel.org mediatek,mt6397.yaml binding (covers MT6323) — PMIC submodules incl. audio codec; mt6323.dtsi examples.

## Confidence

**High** for: the DTB toolchain and detection workflow (§1); the fact that MT6582 3.4.67 ALPS config is board-file-based and where charging config lives (§2 reference stack verified in Google's own tree); the audio_policy.conf `audio_hal_version` mechanics and 7.0 CONF support (§3, from AOSP docs/source); the existence and content of the community resources (§4, inspected directly); tempo's AW87559 implementation details (§5, read from the doc itself).

**Medium** for: the inference that Lithium's boot.img contains no DTB (strong but unverified — needs the magic scan); the claim that the Q5's "Max charging current 0" is cosmetic (common MTK behavior, needs sysfs verification on-device); the transferability of Y2's AW87559 enable sequence to the Q5 (same chip family but different board/codec topology).

**Low** for: the meaning of the `MAX17050SW6106` hybrid name and any SW6106 involvement (speculative until stock firmware is inspected).

**Status: partial** — decision-quality on all five questions with the critical architectural caveats identified; two on-device checks (FDT magic scan; sysfs/I2C diff between builds) remain and are cheap. Deeper research on the MAX17050SW6106 driver and the button/keylayout diff is queued behind obtaining the Mint backup dump from Sendew's repo.

**Confidence (overall): Medium-High — grounded primarily in AOSP/kernel primary sources and the actual project repos; residual uncertainty is confined to device-specific facts that require the two on-device checks and the Mint stock dump, not further web research.**
