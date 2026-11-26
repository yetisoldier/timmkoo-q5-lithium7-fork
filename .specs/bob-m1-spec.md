# Bob — M1 Architecture & Implementation Specification
## Q5 Lithium 7 Fork (Lithium 7 → Q5 "Mint" hardware variant)

**Status: DESIGN COMPLETE — M1 (all four parts written; M1a buildable now, M1b gated on open question Q1)**
**Author: Bob (Principal Software Architect) — Milestone 1**
**Inputs:** `.specs/hermes-brief-v0.1.0-q5-lithium7-fork.md`, `.specs/scout-research-report.md`
**Scratch evidence dir (not committed):** `/home/yetisoldier/.hermes/cache/scratch/opencode/bob-m1/`

---

# PART 0 — Verified forensic evidence (this milestone)

## E1. boot.img structure (mtk-tools unpack) [DONE]

| Field | Lithium 7 (`~/q5-flash/rom/boot.img`) | Mint V1.0 (`~/.hermes/q5-recovery/base/Mint_V1.0/boot.img`) |
|---|---|---|
| kernel size | 3,809,720 B | 5,108,560 B |
| kernel sha256 | `5217dd41c77b8184bd63fe56bd95bbedf89b7cb08a2a6f073091c11c31bbe88c` | `a0c5730de36f4fe64c900cc8dce4f973d5cd84ada739bc627923eb9e93721ad3` |
| base / kernel load | 0x80000000 / 0x80008000 | 0x10000000 / 0x10008000 |
| ramdisk size / load | 1,394,157 B / 0x84000000 | 4,282,475 B / 0x11000000 |
| tags offset | 0x8e000000 | 0x10000100 |
| second stage | **0 (none)** | **0 (none)** |
| page size | 2048 | 2048 |
| cmdline | `bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug` | *(empty)* |

Third-party hashes confirmed this session: **T-ROM V2.3 kernel == Lithium kernel == Manufactory_latest kernel == sha256 `5217dd41…`** (all three byte-identical).

## E2. DTB — none anywhere [DONE]

- FDT magic `0xD00DFEED` scan: raw kernel blobs = 0 hits; **decompressed kernels = 0 hits** (both); full boot.img scans = 0 hits; `extract-dtb` on both boot.imgs extracted nothing; both headers report second-stage = 0.
- **Consequence:** hardware config is compiled into the kernel from board files, NOT patchable as a DTB. There is no DTS patch route for charging/camera/keys. Confirmed empirically (Scout caveat holds).

## E3. Kernel provenance — three ROMs ride ONE kernel; Mint is a different tree [DONE]

| Kernel | Version string | Builder | gcc | Date |
|---|---|---|---|---|
| Lithium/T-ROM/Manufactory | `Linux version 3.10.54` `SMP PREEMPT` | `wangliang@innioasis117` | 4.8 | Fri Jan 26 12:00:29 CST 2024 |
| Mint | `Linux version 3.4.67` `SMP PREEMPT` | `build@dsj` | 4.7 | Fri Aug 22 15:16:42 CST 2025 |

- `CONFIG_IKCONFIG` absent in both (extract-ikconfig output empty) → config reconstructed via string inventory (E5/E8).
- Lithium build identity: `ro.build.flavor=dot_Q340-userdebug` (dotOS-1.x Q340 tree, lineage = `MX2 WV3 platform`; T-ROM `ro.product.board=MX2-WV3 R2`). T-ROM V2.3 = **Android 5.0 (SDK 21)** on the same kernel.

## E4. Ramdisk diff — structural style difference only [DONE]

- Lithium = Nougat-style ramdisk (sepolicy/service_contexts/file_contexts.bin, `fstab.mt6582`, `init.usb.configfs.rc`, `init.zygote32.rc`, off-mode charge via `/charger` + `service charger /sbin/healthd -c` in `init.mt6582.rc`, selinux=permissive on cmdline).
- Mint = KitKat-style ramdisk (`meta_init*.rc`, `init.project.rc`, `init.charging.rc`, `fstab.nand`, `q5su` root hooks). Only `init.charging.rc` + KK `healthd` differ in a charging-relevant way, and they are the KK off-mode mechanism — no content transferable to Nougat.
- **No ramdisk change can fix the Mint-hardware charging/camera symptoms** (all config that names hardware is kernel-compiled). Ramdisk kept as-is for M1.

## E5. Charging/gauge kernel inventory — the driver sets differ by hardware revision [DONE]

| Function | Lithium/T-ROM kernel (3.10.54) | Mint kernel (3.4.67) |
|---|---|---|
| External charger IC driver | **`bct24157`** (+ `fan5405` register-compatible glue strings: `fan5405_config_interface`, `bct24157_hw_component_detect`, `charging_enable`) | **none** (only generic `charging_hw_init`, `Charger_Detect_Init/Release`) |
| Fuel-gauge driver | **`MAX17050SW6106`** (`MAX17050SW6106_driver_probe OK/suspend/resume`, compatible string `mediatek,MAX17050SW6106`) + MTK FGADC fallback (`[FGADC]`, `[FG]` debug) | MTK FGADC only (`[FGADC]`, `[fg_batt_crrnt]`) — no MAX17050/SW6106 driver strings |
| PMIC | MT6323 (both) | MT6323 (both) |
| Speaker amp | `aw87559_pa` (present) | `aw87559_pa` (present) |

Interpretation (drives ADR-3):
- The 3.10.54 kernel was built (Jan 2024, by/for Innioasis) for the **newer Q5 board revision** carrying a **BCT24157** switch charger + an **SW6106-based hybrid gauge** (`MAX17050SW6106` = vendor hybrid driver: SW6106 power-bank SoC, MAX17050-style interface).
- The Mint hardware's own (KitKat) kernel has **neither** driver, yet charges correctly → on Mint hardware, charging is **autonomous** (SW6106 charges without host control) and SOC is read via the **MTK FGADC** path with the Mint battery-profile tables — OR the SW6106 answers the gauge driver at an address the 3.10.54 build doesn't probe.
- The "Max charging current 0 / voltage 0" dumpsys fields are sourced from `power_supply` sysfs attributes that MTK vendor stacks usually never export → largely cosmetic. The real symptom is **SOC stuck at 0–1 %**, which points at (a) gauge probe failure/misconfig and/or (b) the kernel's bct24157 charge-enable state machine actively disabling a charger IC that doesn't exist / fighting the autonomous SW6106. Discriminating these is an on-device gate (G3/G4 in Validation Spec), not guessable offline.

## E6. Audio — userspace-only defect, coherent working donor pair found [DONE]

| File | Lithium 7 | T-ROM V2.3 (working) | Mint V1.0 |
|---|---|---|---|
| `/system/lib/hw/audio.primary.mt6582.so` | 846,160 B `a7cc2dbe…` | 850,256 B `2510d408…` | absent (KK stack in `/system/lib`, `libaudio.primary.default.so`) |
| `/system/etc/audio_policy.conf` | 5,182 B `ef82488d…` (`audio_hal_version 2.0` in **all** modules) | 5,467 B `579c9d04…` (`audio_hal_version 3.0` in primary) | 3,421 B (KK format) |
| `/system/etc/audio_effects.conf` | 6,681 B `13a0b6bb…` | 5,433 B `7379e023…` | 5,433 B `7379e023…` (same as T-ROM) |
| `mixer_paths.xml` | **122 B stub at `/system/vendor/etc/mixer_paths.xml`**: `<path name='speaker'><ctl name='MX2 WV3' value='100'/></path>` | absent | absent |
| `audio_device.xml` | absent everywhere | absent everywhere | absent everywhere |

- Both HAL `.so`s: identical `DT_NEEDED` (27 MTK libs, same platform lineage `vendor/mediatek/proprietary/platform/mt6582/.../aud_drv`), identical speaker/PA string inventory (`Audio_Set_Speaker_On/Off/Vol`, VIBSPK, `AnalogOpenForAddSPK`), **no** reference to `mixer_paths.xml` or `audio_device.xml` → **the stub is inert junk; the real routing is compiled into the `.so` + `audio_policy.conf`** (MTK ALSA path, NVRAM for tuning).
- Binary delta (dynamic symbols): Lithium's HAL adds `AudioAnalogControlExt` external-DAC support (`SetExtCodecDataLen/SampleRate`, `mExtDACIsOpen`); T-ROM's has `UniqueAnalogInstance`. Same source tree, one revision apart.
- `audio_policy.conf` deltas (Lithium vs T-ROM): primary `audio_hal_version 2.0` vs `3.0`; Lithium additionally attaches junk phone devices (`AUDIO_DEVICE_OUT_TELEPHONY_TX`, `TELEPHONY_RX`), drops `a2dp` inputs + `usb` input split, changes primary input sampling_rates set. The version token controls Nougat parser behavior (per-module `global_configuration` + `devices{gains}` are only honored at ≥ 3.0).

## E7. Buttons — entirely userspace; root cause identified [DONE]

`mtk-kpd.kl` (kernel-keypad → Android key map):

| scancode | Lithium | Mint | T-ROM |
|---|---|---|---|
| 102 | `HOME` | `HOME` | `MOVE_HOME` |
| 172 | *(absent)* | *(absent)* | **`HOME`** |
| 114/115 | `VOLUME_DOWN/UP` (no wake flag) | + `WAKE_DROPPED` | no flag |
| 116 | `POWER` (no flag) | `POWER WAKE` | no flag |
| 107/62 | `ENDCALL` | `ENDCALL WAKE` | `ENDCALL` |
| 744/745 | *(absent)* | `FCOVER_1/FCOVER_2 WAKE` | *(absent)* |
| `ACCDET.kl` (headset keys) | **file absent** | 6 keys incl. `122 ENDCALL`,`164 HEADSETHOOK` | present, contents == Mint |

- **T-ROM maps HOME at 172, Lithium doesn't map 172 at all.** Same byte-identical kernel ⇒ if the kpd matrix emits 172 for the physical home key, **home is dead on Lithium** (T-ROM evidence says 172 is the live code on this lineage; Mint's own kernel instead emits 102, matching its own .kl — the two kernel builds map the same matrix position differently).
- **`build.prop`: Lithium `qemu.hw.mainkeys=1` (hides the software nav bar!), T-ROM `qemu.hw.mainkeys=0`.** Q5 Mint has 3 side buttons + home (no capacitive back/menu) ⇒ with the nav bar hidden **and** 172 unmapped **and** no WAKE flags (power/volume can't wake a slept device), the user-visible result is "buttons dead / can't navigate."
- `Generic.kl` (fallback for non-kpd input devices): Mint adds `WAKE`/`WAKE_DROPPED` to POWER(116/142/143/152), MENU(127/139), BACK(158); Lithium has none.

## E8. Camera — kernel sensor-list mismatch; HAL already fine [DONE]

Kernel-compiled sensor inventory (string scan):

| | Lithium/T-ROM 3.10.54 | Mint 3.4.67 |
|---|---|---|
| Sensors | `GC2355_MIPI_RAW`, `GC9503`, `OV5670(_MIPI(_RAW))` | `GC0313MIPI_YUV`, `GC0329_YUV`, `GC2035(_MIPI)_YUV`, **`GC5004_MIPI_RAW`**, **`HI253_YUV`**, **`HI704_YUV`**, `S5K5CAGX_YUV`, `IMX111/135/179_MIPI`, `OV1283`, `OV2680/OV5647/OV5648/OV8825_MIPI`, `OV8830`, `S5K3H2Y`, `GC9503` |
| AF/VCM | `DW9714` + `DW9719` (present) | none matched |

- Mint's list carries the ODM debug prefix ` zhaoshaopeng add SENSOR_DRVNAME_…` for the YUV additions — the Mint hardware set = **rear `GC5004_MIPI_RAW` (5MP, AF-capable) + front Hynix (`HI253` 2MP YUV or `HI704` VGA YUV — which one is fitted is decided by the kd_camera_hw probe at runtime; the brief's "Hynix sensors on I2C" matches this)**.
- Lithium's kernel knows none of the Mint sensors ⇒ both cameras unprobed ⇒ "front camera dead" (and rear too).
- System side is **not** the defect: `camera.mt6582.so` Lithium == T-ROM **byte-identical** (`ad6b6d6a…`, 26,068 B); camera libs exist in Lithium (dotOS-lineage N build). No system.img camera change needed.
- Only `DW9714/DW9719` AF drivers already exist in the 3.10.54 kernel (keep).

## E9. Flash geometry — compatible [DONE]

Both scatters: `PRELOADER 0x0/0x140000`, `BOOTIMG 0x3180000/0x1000000`, `ANDROID(system) 0x6500000`. Difference = ANDROID size (Lithium `0x54600000` ≈1.35 GB vs Mint `0x33400000` ≈ 850 MB); Lithium system.img (761 MB raw ext4) **fits** either. Repack parameters per image recorded (`boot.img-args.txt`); the fork repacks with **Lithium's** own header values (base 0x80000000 etc.).
`preloader_j5052.bin` identical name in both bases → same preloader family; preloader/lk/secro stay untouched (they already charge-boot the device under Mint; Lithium's own package already runs on this board lineage).

## E10. Fork-source reality — Lithium repo is system-only [DONE]

`github.com/NoahDomingues/Lithium` (cloned `.reference-lithium/`, single commit `7f89410`): the git tree **is an unpacked `/system` partition** (1945 files: `app/ priv-app/ lib/ etc/ usr/ vendor/ xbin/ build.prop xposed.prop …`) + GitHub metadata. **No kernel source, no device-tree source, no build system, no `boot.img` in-tree.** The kernel ships only as a release binary ("Lithium 7 Kernel v7.1.06.09.25" = the same `5217dd41…` blob already analyzed).

**⇒ A source-level fork-and-rebuild of Lithium is impossible. The fork is necessarily an image-level, script-driven binary modification of Lithium's `boot.img` + `system.img`, plus a kernel rebuild only from separately-sourced kernel trees.**

---

# PART 1 — ARCHITECTURE SPEC

## 1.0 Executive summary

Lithium 7 cannot be rebuilt from source (E10), and three of the four Mint-hardware defects live in
places no system-level edit can reach (kernel board config, E2/E3). The fork therefore has **two
independently shippable products**:

- **Fork M1a — system.img-only patch** (no kernel change): fixes **audio** (donor pair swap) and
  **buttons** (keylayout/build.prop merge). Builds in minutes, flashes as ANDROID partition only, low
  brick risk. Does **not** fix charging or camera.
- **Fork M1b — kernel rebuild + M1a**: rebuild of the MT6582 3.10.54 kernel (Lithium lineage) with
  the Mint board configuration (Hynix sensor list + Mint key/power board tables) inside the same
  boot.img/rampackage. Fixes **camera** definitively, and **charging** if the on-device gates confirm
  the kernel-domain root cause (E5). This milestone needs kernel source acquisition (open question Q1).

This ordering is deliberate: M1a delivers two of four fixes with near-zero risk and validates the
pipeline; M1b carries all kernel risk and is gated on source availability.

## 1.1 Requirements

Functional: F1 charging reports/works (SOC climbs, not stuck 0–1 %); F2 internal speaker audible
(aux/BT must not regress); F3 all five hardware inputs work (VOL+, VOL−, POWER, HOME, reset-hole)
incl. wake-from-sleep and a usable navigation fallback; F4 front camera enumerates + preview/capture.
Non-functional: NF1 stay on Android 7.1.2 Lithium base (modern apps, e.g. Apple Music); NF2 flash only
BOOT+ANDROID (never preloader/lk/secro); NF3 reproducible build pipeline with hash manifests;
NF4 zero regression vs stock Lithium on radio/WiFi/BT/GPS; NF5 no closed-source donor relicensing
issues beyond community norms (T-ROM team credited; GPL-3.0 lineage acknowledged).

## 1.2 ADR-1 — Fork strategy: image-level binary patch pipeline (not source rebuild)

- **Problem.** Lithium must be modified for Mint hardware; what form does the fork take?
- **Decision.** Image-level fork. The deliverables are a modified `boot.img` + `system.img` produced
  by a scripted, hash-verified pipeline. The git repo stores **scripts, patches, manifests, and this
  spec** — never donor `.img`/`.so` binaries (`.gitignore` already excludes them). Donor images are
  read-only external artifacts (`~/q5-flash/rom/`, `~/.hermes/q5-recovery/base/*/`).
- **Alternatives considered.** (a) Source-level AOSP rebuild from a dotOS Q340 tree — impossible:
  NoahDomingues/Lithium carries no build tree (E10); the dotOS Q340 source lineage is not published
  (T-ROM-Project's public device tree targets CM-12.1/LP, not N). (b) Overlay/Magisk-style runtime
  patching — rejected: needs working base boot anyway, complicates flashing for the user, and can't
  touch the kernel fixes M1b requires. (c) Rebase the whole fork onto Mint KitKat and forward-port —
  rejected: defeats NF1 (must stay on Android 7 for app compatibility).
- **Advantages.** Matches the artifacts that exist; deterministic; auditable; every change is a named
  file op with a hash; rollback = reflashing donor images.
- **Disadvantages.** System.img patch is opaque without the manifest; kernel fixes (M1b) still require
  an actual kernel source tree — image-level alone can't fix camera.
- **Tradeoffs.** We accept binary-level system patching (standard for MTK ROM porting — this is
  exactly how Lithium itself was produced by MTK-ROM-Porter) in exchange for zero build-system risk.
- **Revisit criteria.** If the complete dotOS/CM-14.1 MT6582 source + Innioasis kernel tree surface,
  re-evaluate a source-level rebuild (would improve long-term maintainability).
- **Dependencies.** Toolchain: `bgcngm/mtk-tools` (unpack/repack, proven at M1), `mkbootimg` (from
  mtk-tools), `debugfs` (ext4 surgery without root), `simg2img/img2simg`, `sha256sum`.

## 1.3 ADR-2 — Audio fix: graft T-ROM's working audio pair into Lithium's system.img

- **Problem.** Internal speaker silent on Lithium (T-ROM/Manufactory work; kernel identical).
- **Decision.** Replace a coherent donor pair + clean junk:
  1. `/system/lib/hw/audio.primary.mt6582.so` ← T-ROM (850,256 B, `2510d408…`).
  2. `/system/etc/audio_policy.conf` ← T-ROM verbatim (5,467 B, `579c9d04…`; primary hal 3.0, a2dp
     inputs, usb split — all correct for the Nougat parser).
  3. `/system/etc/audio_effects.conf` ← T-ROM (`7379e023…`; keeps effects graph consistent with the
     donor HAL lineage).
  4. **Delete** `/system/vendor/etc/mixer_paths.xml` (122 B `MX2 WV3` stub; no HAL references it — E6;
     MTK ALSA stack doesn't consume mixer_paths-style files).
  5. Do **not** port any `audio_device.xml`: it doesn't exist in any of the three builds and neither
     HAL loads it (E6). Tuning lives in NVRAM (device partition, untouched by the flash).
- **Why this is right.** The defect class is known: Lithium's HAL+conf pair lost the codec/amp routing
  the working build has (`audio-delta-map.md` prior forensic + E6). The kernel (amp/codec driver,
  `aw87559_pa`) is byte-identical; the AW87559 enable contract (GPIO pulse + I2C init, chip ID 0x5A —
  documented in artificery-dev/tempo) lives behind kernel mixer controls that the **HAL** must poke;
  T-ROM's HAL is the proven poker on this exact kernel. Swapping `.so` alone or conf alone leaves a
  mixed, unverified pair; swapping the pair re-creates the verified working combination. Lithium's
  extra `AudioAnalogControlExt` external-DAC code is irrelevant on the Mint board (codec = MT6323
  internal, amp = AW87559 on I2C 0x58 — same as classic Q5).
- **Alternatives considered.** (a) Graft only Mint's KK-era audio config onto a Nougat HAL — wrong
  era (KK format, no matching HAL, would need synthesis). (b) Reuse Mint's KK HAL on Nougat —
  rejected (ABI: audio_hw_device 1.x/2.0-era symbols, libutils LP→N drift; Scout option D). (c) Keep
  Lithium's N-built HAL, only set conf `audio_hal_version 3.0` + strip phony TELEPHONY devices —
  kept as **Fallback B** if the T-ROM .so fails to load under N userspace (E6 risk note: same
  DT_NEEDED lineage makes load failure unlikely, but LP-built .so on N libs is the one real ABI risk;
  the gate G4 detects it).
- **Disadvantages.** T-ROM pair was LP-built; if a subtle N incompatibility surfaces (not load-fail
  but behavioral), Fallback B is the escape hatch. Both are cheap.
- **Revisit criteria.** If M1b rebuilds a source stack later, rebuild the MTK aud_drv HAL from source
  with the routing included.
- **Verification.** G4 (Validation Spec): logcat `loadHwModule` clean, `dumpsys media.audio_flinger`
  module+route present, tinymix PA control state, audible sweep.

## 1.4 ADR-3 — Charging fix: kernel-domain root cause; fix gated and phased

- **Problem.** Stuck at 0–1 % SOC, `current_max`/`voltage_max` = 0 on Lithium; Mint base charges.
- **Decision.**
  1. **Diagnose before patching (gates first).** The evidence (E5) shows both kernels *can* charge the
     Mint hardware paths differently: Lithium's kernel drives an **external BCT24157** + expects the
     **MAX17050SW6106** hybrid gauge; the Mint kernel drives **neither** yet works (autonomous SW6106
     charging + FGADC SOC). Hera runs gates G3 (dmesg/i2c/sysfs under Lithium and under T-ROM and
     under Mint, on Eric's device) to discriminate:
     - **Case A (gauge/reporting only):** Lithium actually charges (voltage climbs at the cell) but
       SOC reporting is broken because `MAX17050SW6106` fails to probe (wrong I2C addr/board table) or
       returns garbage → fix = kernel gauge board config (I2C address, rsense/model data) or forced
       FGADC fallback with Mint battery profile tables.
     - **Case B (real charge kill):** `bct24157` probe/hw_component_detect misfires and the battery
       thread calls `charging_enable(0)` into thin air / misreads CHR_Type → fix = disable the external
       charger selection (board config) so the SW6106 is left alone (charge-enable never toggled).
     - **Case C (cosmetic only):** cell actually charges and only the dumpsys fields are 0 → ship
       cosmetic-only note (no kernel change) — possible per Scout but Eric's "stuck at 0–1 %" and
       off-load behavior suggest this is not the whole story.
  2. **M1a ships nothing for charging.** (No userspace path exists — healthd merely reads
     `/sys/class/power_supply/*` populated by the kernel.)
  3. **M1b carries the charging fix** in the rebuilt kernel's board config, per the gate outcome
     (Case A or B above). Config sources for the rebuild: reference stack = Google's sprout MT6582
     kernel (`android-mediatek-sprout-3.4-kitkat-mr2`, `drivers/misc/mediatek/power/mt6582/`:
     `charging_hw_fan5405.c`, `battery_meter_hal.c`, `pmic_mt6323.c`) + the mint kernel binary as
     ground truth of *which* drivers Mint HW needs (none external) + Mint battery profile tables
     (extracted from the 3.4.67 kernel binary or its DCT defaults).
- **Alternatives considered.** (a) DTS patch — impossible, no DTB (E2). (b) Binary-patch `charging_hw_*`
  tables in the zImage — rejected as primary (symbol-less, fragile; kept only as emergency stopgap
  K2: NOP the `charging_enable(0)` path). (c) Swap in Mint's 3.4.67 whole kernel (K3) — **rejected**:
  N userspace↔KK kernel ABI risk (mali/gralloc UMP-KDS, seccomp-bpf absence, ccci, selinux feature
  gates) makes this brick-likely, not merely "beta".
- **Disadvantages.** Charging cannot ship in M1a; depends on kernel source acquisition (Q1) and one
  on-device diagnostic cycle.
- **Advantages / rationale.** We fix the actual mechanism, not the symptom; the same rebuild also
  delivers the camera sensors (ADR-5), amortizing kernel-build risk across two fixes.
- **Revisit criteria.** If gate G3 proves Case C, charging is closed as cosmetic with zero kernel work.
- **Dependencies.** Q1 (kernel source), G3 gate data.

## 1.5 ADR-4 — Button fix: pure userspace merge (ships in M1a)

- **Problem.** Dead physical buttons under Lithium (home, wake behavior, nav fallback).
- **Root cause (three compounding userspace defects; E7):** (i) `mtk-kpd.kl` lacks `key 172 HOME`
  (T-ROM proves the lineage's kpd emits 172 for the home key; Lithium maps only 102). (ii) No
  `WAKE`/`WAKE_DROPPED` flags anywhere — POWER/VOL/MENU cannot wake the device (Mint's .kl carries
  them; this matters on a player used in docks/pockets). (iii) `qemu.hw.mainkeys=1` hides the
  software nav bar, so a partially-mapped hardware key set = no navigation at all. Plus `ACCDET.kl`
  (headset hook/next/prev/vol) is missing entirely.
- **Decision.**
  1. New `mtk-kpd.kl` = Lithium base + add `key 172 HOME WAKE_DROPPED` (dual-map 102 **and** 172 →
     HOME: covers both kernel mappings harmlessly; worst case two scancodes do the same thing) + add
     `WAKE` to `116 POWER`, `WAKE_DROPPED` to `114/115 VOLUME_*` and `102 HOME` + carry Mint's
     `744 FCOVER_1` / `745 FCOVER_2 WAKE` entries. See Implementation Spec §2.5 for the literal file.
  2. Add `/system/usr/keylayout/ACCDET.kl` (= Mint/T-ROM content, identical in both).
  3. `Generic.kl` = Lithium base + Mint's WAKE-flag edits only (116/142/143/152 POWER·WAKE,
     127/139 MENU·WAKE_DROPPED, 158 BACK·WAKE_DROPPED). Skip KK-era COPY/CUT/PASTE removals & LEDs.
  4. `build.prop`: `qemu.hw.mainkeys=1` → `0` (nav bar on; framework config already renders it on
     this lineage — T-ROM proves with prop=0 the bar appears).
- **Alternatives considered.** (a) Kernel kpd-table patch to emit uniform codes — unnecessary; .kl
  layer is the designed seam for this. (b) Leave nav bar hidden + remap kpd — rejected: with only
  home+vol+power physically present, BACK/RECENTS need the bar.
- **Verification.** G5 gate: `getevent -p` keycode map, staged physical test incl. wake-from-sleep and
  long-press behaviors; nav bar visible; no double-trigger (both 102/172 → HOME union is idempotent).
- **Open runtime fact.** Which scancode the Mint's home key emits under the 3.10.54 kernel (102 vs
  172). The dual-map makes this unknowable-but-irrelevant; the gate records it for posterity.

## 1.6 ADR-5 — Camera fix: kernel sensor-list port (ships in M1b)

- **Problem.** Front camera absent on Lithium (E8: Lithium kernel sensors = GC2355/OV5670/GC9503; Mint
  hardware = GC5004_RAW rear + Hynix HI253/HI704 YUV front; camera HAL already byte-identical to
  T-ROM's working one).
- **Decision.** In the M1b kernel rebuild, set the kdCamera sensor list to the Mint set:
  `{GC5004_MIPI_RAW (main), HI253_YUV, HI704_YUV (sub)}`, keep the already-present `DW9714`/`DW9719`
  VCM drivers, and port the Mint kernel's per-sensor board hooks (power-rail GPIO order, I2C bus
  IDs/addresses, clock/MCLK assignments) from the 3.4.67 build's ground truth (binary string tables
  + Mint device runtime probe data from gate G6). Userspace needs **nothing**: HAL ==
  T-ROM working, media profiles generic, KK-era `libcameracustom` NVRAM params live in NVRAM
  (untouched partition).
- **Alternatives.** (a) Userspace-only fix — impossible (sensor drivers are compiled-in, not
  modules; HAL can't drive an unprobed sensor). (b) Binary-inject sensor drivers — infeasible.
  (c) Keep GC2355-only and accept dead camera — rejected (requirement F4).
- **Risks.** HI253 vs HI704 identity (resolved at G6 by probe log: `kd_camera_hw` prints the matched
  SENSOR ID); both listed ⇒ probe order binds whichever answers. YUV sensors on the 3.10.54
  mtkcam runtime: the dotOS/CM camera stack for this family expects raw+YUV mix — matches T-ROM's
  working behavior on classic Q5, acceptable risk, gated on hardware test.
- **Dependencies.** Q1 kernel source; G6 probe data.

## 1.7 ADR-6 — Kernel sourcing for M1b (the one external dependency)

- **Problem.** No Lithium kernel source exists (E10). M1b needs a 3.10.54 MT6582 kernel source with
  working build flow.
- **Decision (priority order).**
  1. **Q1a — Ask the lineage authors** (palutenfan123/T-ROM, NoahDomingues; Discord "Timmkoo
     Modders") for the 3.10.54 MT6582 kernel tree used for the innioasis117 build (built on
     2024-01-26). This is the ideal source: exact config, correct GPU/modem glue.
  2. **Q1b — Public ALPS.L0.MP2 MT6582 3.10.54 trees** (Lollipop-era OEM leaks for MT6582 devices:
     Infocus/THL/Doogee/Jiayu lineages on GitHub) + port Q5 board config (`ProjectConfig.mk`,
     `cust_gpio_usage.h`, `cust_kpd.h`, `cust_battery*.h`, sensor list) reconstructed from the
     3.10.54 binary's string tables + Mint's runtime data. GCC 4.8/4.9 arm-eabi toolchain era.
  3. **Q1c (last resort).** Skip kernel rebuild: charging = accept Case-B binary stopgap (K2) only if
     G3 shows real charge kill **and** camera stays broken — rejected outcome; only if Q1a/Q1b dry up.
- **Why not build 3.4.67 instead?** We must keep the 3.10.54 runtime (userspace graphics/modem ABI
  matched; proven by Lithium itself on this board lineage).
- **Note.** This is the only item in the milestone not fully closed by offline forensics; it is a
  resourcing question, not a design unknown. The rest of M1b's design is source-agnostic (board
  config deltas are enumerated in Implementation Spec §2.7).

## 1.8 ADR-7 — Flash/rollback safety contract

- Flash **BOOT+ANDROID only** via SP Flash Tool *Download Only*; never preloader/lk/secro/EBR/MBR.
- Precondition: Eric's verified Mint_V1.0 backup (exists at `~/.hermes/q5-recovery/base/Mint_V1.0/`)
  + SPFT readback of BOOT+ANDROID before first flash (gate G0).
- Rollback = flash donor images back. M1a additionally keeps an **original-system.img backup** so
  audio/buttons revert in one flash.
- Package the fork artifact with a scatter subset (BOOTIMG@0x3180000/0x1000000,
  ANDROID@0x6500000 — both donors agree; E9).

## 1.9 Failure mode analysis (top risks)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| T-ROM LP-built audio .so misbehaves under N userspace | Low–Med | audio still broken | Fallback B (Lithium .so + fixed conf); gate G4 catches at flash-1 |
| Kernel source never obtained (Q1) | Medium | camera never fixed; charging per Case | escalate to palutenfan123/NoahDomingues; Q1b public-tree port path |
| Kernel rebuild boots but modem/GPU ABI drift | Low (same lineage) | brick-ish | gate order: boot test kernel-only first (BOOT flash alone, system stock) |
| Wrong Hynix guess | Med | front cam dark | both HI253+HI704 compiled; probe binds the fitted one |
| bct24157 actively disables Mint charging | Med | charging broken until M1b | M1a explicitly *not* advertised as charging fix |
| Dual-mapping 102/172 has surprise collision | Very low | a key mis-acts | G5 getevent table; remove 102 line if proven 172-only in runtime |
| NVRAM drift from prior flashes | Low | audio/camera tuning odd | NVRAM partition untouched; only factory reset changes it |

## 1.10 Observability / diagnostics baked into the deliverable

- `androidboot.selinux=permissive` retained (debug-friendly; matches Lithium stock).
- M1a/M1b ship a `fork-manifest.txt` in `/system/etc/fork/` (hashes + donor provenance + date) so any
  future dump can be attributed without re-forensics.
- Karen/Hera instrumentation list (exact adb commands per gate) is in Part 3; all are stock tools.

---

# PART 2 — IMPLEMENTATION SPEC (for Forge)

## 2.0 Repository layout (what the fork repo contains)

```
timmkoo-q5-lithium7-fork/
├── build/                     # pipeline scripts (bash, set -euo pipefail)
│   ├── 00_env.sh              # paths, tool checks, donor hash assertions
│   ├── 10_unpack_system.sh    # debugfs-based: ext4 system.img → work/system tree
│   ├── 20_apply_system_ops.sh # the file op table (§2.3) applied idempotently
│   ├── 30_repack_system.sh    # make_ext4fs/img2simg → out/system-fork.img
│   ├── 40_unpack_boot.sh      # mtk-tools unpack of donor boot.img (M1b only)
│   ├── 50_repack_boot.sh      # mkbootimg with Lithium args file (M1b only)
│   ├── 90_package.sh          # fork scatter subset + sha256 manifest + zip
│   └── 99_verify.sh           # offline checks (mirrors Part 3 §3.2)
├── patches/                   # text assets Forge maintains
│   ├── usr/keylayout/mtk-kpd.kl        # literal merged file (§2.5)
│   ├── usr/keylayout/ACCDET.kl         # literal (= Mint/T-ROM content)
│   ├── usr/keylayout/Generic.kl.patch  # WAKE-flag edits only
│   └── build.prop.patch                # qemu.hw.mainkeys 1→0
├── manifests/donors.sha256    # pinned donor hashes (E1/E6/E9 values)
├── .specs/                    # this spec + upstream docs
└── .reference-*/              # gitignored upstream clones
```

**Hard rules for Forge**
1. No donor binary is committed (`.gitignore`: `*.img *.bin *.zip *.so donors/ out/ work/`).
2. Every donor read is hash-asserted before use (`manifests/donors.sha256`); abort on mismatch —
   silent donor drift is the biggest correctness hazard.
3. All writes go to `work/` (unpacked tree) then `out/`, never in-place on donor images.
4. Pipeline is idempotent: re-running from clean reproduces byte-identical outputs for byte-identical
   donors (record all tool versions in the manifest).
5. ext4 surgery via `debugfs -w` on a `work/system.img` copy OR full unpack/repack; pick one method
   and stick to it (repack preferred — preserves no stale inode state; permissions from a stat map).

## 2.1 Donor inventory (hash-pinned)

| Logical name | Path | sha256 (first 16) | Role |
|---|---|---|---|
| D-LITHIUM-BOOT | `~/q5-flash/rom/boot.img` | (record from device files) | boot donor + repack params |
| D-LITHIUM-SYS | `~/q5-flash/rom/system.img` (raw ext4, 761,761,792 B) | pin at build time | system base |
| D-TROM-SYS | `~/.hermes/q5-recovery/base/T-ROM_V2.3/system.img` | pin | audio donor pair |
| D-MINT-BOOT | `~/.hermes/q5-recovery/base/Mint_V1.0/boot.img` (kernel `a0c5730d…`) | pin | board-config ground truth (M1b binary reference) |
| D-MINT-SYS | `~/.hermes/q5-recovery/base/Mint_V1.0/system.img` | pin | ACCDET.kl semantics, kpd WAKE flags |
| KERNEL-BLOB-3.10 | Lithium kernel blob sha256 `5217dd41…` | pin | M1b build target parity check |

## 2.2 M1a build — system.img op table (exact, ordered)

| # | Op | Path in system tree | Source / content | Verify |
|---|---|---|---|---|
| 1 | replace | `/system/lib/hw/audio.primary.mt6582.so` | from D-TROM-SYS same path (850,256 B, sha256 `2510d408…`, 0644 root:shell… keep donor perms `root:root 0644`) | hash == donor |
| 2 | replace | `/system/etc/audio_policy.conf` | from D-TROM-SYS verbatim (5,467 B, `579c9d04…`) | hash == donor; lint §3.2-A3 |
| 3 | replace | `/system/etc/audio_effects.conf` | from D-TROM-SYS verbatim (5,433 B, `7379e023…`) | hash == donor |
| 4 | delete | `/system/vendor/etc/mixer_paths.xml` | — (122 B stub; inert, E6) | file absent |
| 5 | add | `/system/usr/keylayout/ACCDET.kl` | literal from `patches/usr/keylayout/ACCDET.kl` (= Mint content, 6 keys) | diff vs Mint donor file == 0 |
| 6 | replace | `/system/usr/keylayout/mtk-kpd.kl` | literal from `patches/usr/keylayout/mtk-kpd.kl` (§2.5) | diff vs patch == 0 |
| 7 | patch | `/system/usr/keylayout/Generic.kl` | apply `patches/usr/keylayout/Generic.kl.patch` (WAKE flags only, §2.6) | dry-run + apply + context match |
| 8 | edit | `/system/build.prop` | single line: `qemu.hw.mainkeys=1` → `qemu.hw.mainkeys=0` (else append at end if absent) | grep verifies; only this line differs |
| 9 | add | `/system/etc/fork/fork-manifest.txt` | generated: tool versions, donor hashes, date, git rev | exists, non-empty |

**Explicitly NOT touched in M1a:** boot.img (kernel/ramdisk), recovery, lk, preloader, secro, MBR/EBR,
`/system/framework`, `/system/priv-app`, `/system/app`, `camera.mt6582.so` (already correct, E8), all
`lib/*` audio support libs (the donor .so's 27 DT_NEEDED libs already exist in Lithium — E6),
`media_profiles.xml`, `media_codecs*.xml`.

## 2.3 M1a scatter/package

- `90_package.sh` emits: `out/boot.img` — **NOT in M1a** (stock Lithium boot stays); `out/system.img`
  (raw ext4, matching Lithium's block size/count so it fits ANDROID@0x6500000 — 761,761,792 B target
  size class); `out/scatter-fork.txt` = Lithium scatter with only BOOTIMG+ANDROID rows having
  `file_name`, everything else `file_name: NONE`; `out/SHA256SUMS.txt`.

## 2.4 M1a acceptance criteria (Forge self-check before handing to Karen)

- `99_verify.sh` green (see §3.2 for the offline check list).
- Rebuilt system.img mounts read-only (debugfs `ls` of each changed path).
- File ops 1–8 verifiable via `debugfs` stats/hashes without flashing.
- Git tag `m1a` with manifest.

## 2.5 Literal merged `mtk-kpd.kl` (patch content; Forge commits verbatim)

Changes vs Lithium base, line-precise:
- `key 102   HOME` → `key 102   HOME              WAKE_DROPPED`
- new line after it: `key 172   HOME              WAKE_DROPPED`
- `key 115   VOLUME_UP` → `key 115   VOLUME_UP          WAKE_DROPPED`
- `key 114   VOLUME_DOWN` → `key 114   VOLUME_DOWN        WAKE_DROPPED`
- `key 113   MUTE` → `key 113   MUTE              WAKE_DROPPED`
- `key 116   POWER` → `key 116   POWER             WAKE`
- append at end: `key 744   FCOVER_1` and `key 745   FCOVER_2           WAKE`
- All other lines (158 BACK, 232 DPAD_CENTER, 212 CAMERA, 211 FOCUS, 164/128/163/165/168/159 media,
  alphabetical matrix, etc.) stay byte-identical to the Lithium file. Do NOT adopt the KK-era
  removals from Mint's Generic.kl, and do not add WAKE to media keys (defer to G5 runtime data).

## 2.6 Literal `Generic.kl` patch (context 3 lines)

- `key 116   POWER` → add `WAKE`; `key 127/139 MENU` → add `WAKE_DROPPED`; `key 142 SLEEP` →
  `key 142   POWER             WAKE`; `key 143 WAKEUP` → `key 143   POWER             WAKE`;
  `key 152   POWER` → add `WAKE`; `key 158   BACK` → add `WAKE_DROPPED`.
- Leave COPY/CUT/PASTE (133/135/137) mapped as in Lithium; leave the LED section out (Lithium's
  stock N file doesn't have it — keep N semantics; do not import Mint's KK file wholesale).

## 2.7 M1b build — kernel rebuild delta (source-agnostic; executed once Q1 lands)

Board-config deltas to apply inside the sourced 3.10.54 MT6582 tree (ALPS.L0 family, gcc 4.8-era
arm-eabi/abiv7a):

1. **Camera (ADR-5):** in `mediatek/custom/<proj>/kernel/imgsensor/` (or `kd_sensorlist.h` for the
   selected project): set list = `GC5004_MIPI_RAW` (main), `HI253_YUV`, `HI704_YUV` (sub); retain
   `DW9714` + `DW9719` VCM (`lenslist`). Sensor power-up sequences/I2C addrs copy from the Mint
   3.4.67 binary ground truth matched at gate G6.
2. **Charging (ADR-3, per G3 outcome):**
   - Case A: fix `MAX17050SW6106` I2C board registration (bus/addr) OR force FGADC with Mint battery
     profile (`cust_battery_meter.h` / `cust_battery.h` / `cust_fuel_gauge.h` tables) extracted from
     the Mint kernel binary (`battery profile tables` around `[FGADC]` data).
   - Case B: set `CUSTOM_KERNEL_BATTERY_CHARGER` to **none/pmic-only** (drop bct24157 selection) so
     no charge-enable GPIO/I2C traffic touches the autonomous SW6106; keep gauge per Case A.
   - Case C: no change.
3. **Keys:** adopt Mint kpd matrix mapping ONLY if G5 shows 172/102 dual-map produced a conflict;
   otherwise leave the 3.10.54 kpd table alone (userspace .kl handles it — ADR-4).
4. **Defconfig parity target:** resulting zImage must reproduce the Lithium blob's exported driver
   surface (compare string inventory of new blob vs `5217dd41…` blob: fan5405/bct24157, AW87559,
   MAX17050SW6106, GPU/ccci/mali modules — per §3.2-B check table).
5. Repack boot.img with **Lithium's** parameters (E1/E9: base `0x80000000`, pg 2048, koff
   `0x8000`, roff `0x04000000`, soff `0x00f00000`, toff `0x0e000000`, board `1441186574`, cmdline
   `bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug`). Keep Lithium
   ramdisk byte-identical (E4 proved no ramdisk change needed).

## 2.8 Milestones

| MS | Contents | Ships | Testable |
|---|---|---|---|
| **M1a** | op table §2.2 (audio+buttons), manifest, scatter subset | `out/system.img` + flash doc | Karen §3.2 offline + Hera gates G1,G4,G5 on device |
| **M1b-α** | kernel source acquired+builds stock-parity blob (feature parity vs `5217dd41…`, no Mint deltas yet) | `out/boot.img` (BOOT-only flash test) | Hera G2 boot parity test |
| **M1b-β** | camera sensor list + charging board config (per G3 case) | `out/boot.img` | Hera G3/G6 full |
| **M1b-GA** | M1a+M1b-β packaged together with manifest + rollback doc | `fork-m1.zip` | Karen full validation matrix |

## 2.9 Coding conventions

- bash: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, shellcheck-clean, functions with
  `local`, no `cd` (absolute paths), every external artifact hashed.
- File perms in system tree: files 0644 root:root, dirs 0755 (match donor stat map); SELinux
  file_contexts not required for the changed paths under permissive mode, but Karen verifies no
  denials appear in logcat anyway.
- Commit style: one op per commit where practical (`m1a: op-4 delete mixer_paths stub`); the repo
  history doubles as the audit trail.
- Don't "improve" donor content (no reformatting audio_policy.conf, no re-ordering .kl lines beyond
  the specified edits): byte-compares vs donor/patch are the verification mechanism.

## 2.10 Open build questions Forge must NOT resolve by guessing

- If D-TROM-SYS audio pair hashes ≠ manifest → STOP, re-inventory donors with Bob.
- If repacked system.img size ≠ Lithium's size class → do not flash until scatter/partition fit is
  re-verified (ANDROID partition on Eric's device reflects whichever flash created it: both fit at
  < 850 MB, E9).
- Kernel tree selection (Q1) is Bob's, not Forge's, call.

---

# PART 3 — VALIDATION SPEC

Karen expands this into a full QA plan; Hera runs the on-hardware gates. Order matters: offline
checks §3.2 must pass before any flash; gates G0→G6 are staged so a failure stops the pipeline early.

## 3.1 Functional requirements traceability

| Req | What "done" looks like | Verified by |
|---|---|---|
| F1 charging | SOC climbs ≥ 2 %/10 min on USB; `voltage_now` plausible (3.7–4.35 V); not stuck at 0–1 % | G3 |
| F2 speaker | audible sine sweep on internal speaker; aux + BT unaffected | G4 |
| F3 buttons | every physical key produces the right Android key + wake works + nav bar usable | G5 |
| F4 camera | front camera enumerated; preview + capture succeed | G6 |
| NF1 | `ro.build.version.release=7.1.2` intact | G1 (getprop) |
| NF4 regression | WiFi scan/connect, BT SCO, GPS, MTP/adb work as on stock Lithium | G1 |
| NF2/NF3 | only BOOT+ANDROID flashed; manifest hashes match | G0 + §3.2 |

## 3.2 Karen's offline verification (no device)

**A. Artifact integrity & policy (M1a):**
1. `SHA256SUMS` present; donors match `manifests/donors.sha256` before build starts.
2. Changed-file set == exactly the 9 ops of §2.2 (debugfs-recursive hash diff of fork system.img vs
   D-LITHIUM-SYS; any 10th difference = fail).
3. `audio_policy.conf` lint: braces balanced; primary module declares `audio_hal_version 3.0`
   exactly once; no unresolved tokens; file == T-ROM donor byte-for-byte.
4. `.so` checks: ELF32 LSB arm v7, `DT_NEEDED` ⊆ set of libs present in fork `/system/lib`
   (script greps each), exported symbol set unchanged vs donor.
5. `.kl` syntax: every line `key <num> <NAME> [WAKE|WAKE_DROPPED]`, names in Android
   `KEYCODE_*` vocabulary; mtk-kpd.kl contains both `key 102 HOME` and `key 172 HOME`.
6. `build.prop` diff == exactly one line (qemu.hw.mainkeys 0).
7. `/system/vendor/etc/mixer_paths.xml` absent; `/system/etc/fork/fork-manifest.txt` present.
8. Repacked image: mounts via debugfs; size ≤ min(0x33400000, donor size class) → fits Mint
   ANDROID partition; free blocks reported sane.
9. Permissions: changed files 0644 root:root; no world-writable additions.

**B. Kernel checks (M1b):**
10. New zImage: `Linux version 3.10.54`, builder/config delta report vs `5217dd41…` blob
    (strings inventory script provided in `build/99_verify.sh` — compares driver-name sets:
    fan5405/bct24157, MAX17050SW6106, aw87559_pa, mt6323, ccci, mali, kpd, gc5004/hi253/hi704
    present; no unexpected removals).
11. boot.img repack params == Lithium args file (base/offsets/pagesize/board/cmdline byte-identical
    header fields; only kernel payload + sizes differ).
12. Ramdisk in repacked boot.img hash == Lithium ramdisk hash (unchanged).

## 3.3 Hera's on-hardware gates (Eric's Q5 Mint, SP Flash Tool, Download Only)

**G0 — Recovery net (once).** SPFT readback of BOOT+ANDROID saved to `~/.hermes/q5-recovery/baseline/`;
confirm `Mint_V1.0` backup flashable & booting. Abort all later gates if rollback untested.

**G1 — Smoke (flash fork M1a system, stock Lithium boot).** Boots to UI in ≤ 2 min; `getprop
ro.build.version.release` = 7.1.2; adb over USB; WiFi scans; no crash loops in `logcat -b crash`;
`svc power stayon true`.

**G2 — Kernel parity (M1b-α only).** Flash boot.img alone (stock system back): boots; `uname -r`;
`cat /proc/asound/cards` (expected empty — stock behavior, NOT a failure signal);
`cat /sys/class/input/*/device/name` lists match stock Lithium's list (±0); boot to UI OK.

**G3 — Charging diagnosis + verification.**
Pre-M1b diagnostic sub-gates (run on stock Lithium, on T-ROM, on Mint bases, each flashed in turn):
- `dumpsys battery`; `ls /sys/class/power_supply/`; `cat /sys/class/power_supply/*/{type,online,status,current_max,voltage_max,current_now,capacity,voltage_now} 2>/dev/null`
- `dmesg | grep -iE 'bct24157|fan5405|17050|sw6106|charg|BAT_thread'` (probe success/failure lines)
- `su -c 'i2cdetect -y 0'; su -c 'i2cdetect -y 1'` (responder maps; AW87559 expected at 1-0x58;
  gauge family addresses 0x36/0x6A-region)
- Offline-analysis deliverable: which of Case A/B/C (ADR-3) is live → picks the M1b-β board config.
Post-M1b-β acceptance: SOC climbs visibly ≥ 2 %/10 min on USB; `dumpsys battery` health/voltage sane;
unplug→replug keeps SOC monotonic; off-mode charging animation appears (charger binary path intact).

**G4 — Audio.**
- `dumpsys media.audio_flinger` → primary module loaded (name `primary`, HAL handle non-null);
  `dumpsys media.audio_policy` → attached devices include SPEAKER; active route to speaker when no
  headphones.
- `logcat -d | grep -iE 'loadHwModule|wrong audio|audio_policy|AudioFlinger'` → no parse/version
  errors (a version-mismatch error flips to Implementation Fallback B automatically).
- Play 440 Hz / 1 kHz sweep WAV via `tinyplay` (or any known-good app); speaker audible; stop →
  amp off (no hiss/hum persistence).
- Regression: plug wired headset → routes to headset (ACCDET); BT headset → SCO/A2DP path; volume
  steps monotonic.
- `tinymix` capture of speaker-enable control state (for the record; names vary, e.g. PA/amp
  switch) vs Mint stock capture — documents which control the fix toggles (provenance for M1b+).

**G5 — Buttons.**
- `dumpsys input` → mtk-kpd + accdet devices listed with correct .kl attribution.
- `getevent -lt /dev/input/eventX` while pressing each physical key; expected table:
  home → KEY_HOMEPAGE(172) **or** KEY_HOME(102) → both must resolve to Android HOME (dumpsys
  `input` shows mapped state); VOL±, POWER produce their keycodes.
- Physical: power-wake from sleep; vol-wake-with-dropped-keypress (screen wakes, volume unchanged
  on first press); home from any screen incl. lockscreen; **nav bar visible**; Back/Recents via
  nav bar work.
- Reset pinhole still hard-resets (untouched path).
- Headset hook/next/prev (ACCDET) work with a wired headset.

**G6 — Camera (M1b-β).**
- `dmesg | grep -iE 'kd_camera|SENSOR_DRVNAME|imgsensor|HI253|HI704|GC5004'` at boot → sensor probe
  success line for the fitted front sensor (records HI253-vs-HI704 identity).
- Camera app (any AOSP Camera2 app): front preview renders; still capture saves valid JPEG; rear
  (if fitted/reachable on Mint) still works as before the kernel swap or is documented unchanged.
- Regression: no new camera-server crashes; `logcat -b crash` clean across 3 open/close cycles.

**Gate fail-stop rule:** any gate failure = halt, restore rollback image, file findings back to Bob
with captured logs (logcat/dmesg/getevent dumps). Forge never blind-retries.

## 3.4 Performance & security expectations (M1a scope)

- No measurable boot-time regression (±5 %, stopwatch from flash to UI).
- No new world-readable/writable files (Karen `find` check); selinux permissive retained (stock
  behavior — documented, accepted risk of the base ROM, not introduced by the fork).
- Audio HAL swap must not raise idle audio-thread CPU% beyond noise floor (top sampling during
  30 s idle with screen off; device lacks fine power telemetry — coarse check only).

---

# PART 4 — Closing

## 4.1 Design-review checklist

✓ Requirements satisfied (F1–F4 mapped to routes; NF1–NF5 explicit)
✓ Research consumed (brief + scout + 3 donor dump forensics + Lithium repo inspection)
✓ Alternatives evaluated per decision (ADRs 1–6, incl. rejected DTB/KK-HAL/binary-patch/kernel-swap)
✓ Tradeoffs documented (image-level vs source; LP-built HAL on N; dual key-map)
✓ Security reviewed (flash-surface contract; permissive status quo documented; no new perms files)
✓ Performance reviewed (no-op for M1a; kernel parity checked at G2)
✓ Scalability reviewed (pipeline is donor-driven; new hardware revision = new donor row + gates)
✓ Observability designed (fork-manifest, per-gate dumps, tinymix/getevent provenance capture)
✓ Testability reviewed (offline suite §3.2 runs without a device; staged fail-stop gates)
✓ Extensibility reviewed (op-table pattern; patch dir pattern; M1b hooks enumerated)
✓ Technical debt minimized (no forked junk carried: mixer_paths stub deleted; TELEPHONY devices out)
✓ Risks documented (§1.9)
✓ Acceptance criteria defined (§2.4, §3.2, G0–G6 pass conditions)
✓ Forge guidance complete (op table, literal patch contents, don't-guess list §2.10)
✓ Karen validation plan complete (baseline §3.2–3.4, explicitly expandable)

## 4.2 Verdict

**Design complete for Milestone 1.** M1a is fully specified and buildable now with zero unknowns.
M1b is fully specified except for one *resourcing* unknown (kernel source, Q1), which gates only the
build start, not the design. Eric can flash M1a as soon as Forge+Karen finish; charging/camera land
in M1b.

## 4.3 Open questions for Eric

1. **Q1 (blocking M1b only):** Can you obtain the 3.10.54 MT6582 kernel source used for the
   Lithium/T-ROM "innioasis117" build from palutenfan123 or NoahDomingues (Discord "Timmkoo
   Modders")? If not, sanction path Q1b (public ALPS.L0.MP2 MT6582 OEM tree + board-config port).
2. Which apps matter most as speaker/Camera smoke tests (Apple Music + stock Camera OK for audio
   sweep & front-cam preview)?
3. Confirm current flash state of the device (which scatter/partition layout is live today) so the
   M1a package targets the right ANDROID size — both known layouts fit (E9), this is bookkeeping.
4. Do you want the nav bar always-on (recommended, matches T-ROM) or hidden-with-full-hw-keys once
   buttons G5 data lands? Default = T-ROM behavior.

## 4.4 Remaining entry points (for the next stage's task file)

1. **Eric:** Q1 kernel-source contact + answers §4.3.
2. **Forge:** implement M1a pipeline per §2.0–2.6; tag `m1a` when §2.4 self-check green.
3. **Karen:** execute §3.2 offline suite on Forge's artifacts; expand §3.3 into full runbook.
4. **Hera:** G0 recovery net → then M1a device round (G1, G4, G5).
5. **Hera:** charging diagnostics (G3 sub-gates across Lithium/T-ROM/Mint bases) → feed Case A/B/C
   result back to Bob.
6. **Bob (M2 design):** finalize M1b board-config deltas using G3 case result + Q1 source reality;
   if Q1 comes back empty, design the Q1b port step-by-step.
7. **Forge:** M1b-α parity build → G2; M1b-β delta build → G3/G6; package GA.
8. **(Provenance/nice-to-have):** capture G4 `tinymix` PA-control delta + G5 real scancode table +
   G6 sensor identity into `.specs/hardware-facts-q5-mint.md` for the long-term record.

---
*Bob — Principal Software Architect. End of M1 spec.*
