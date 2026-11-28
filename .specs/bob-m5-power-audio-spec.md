# Bob Spec — m5: Power & Audio Hygiene (battery drain + volume keys)

> Author: Bob (architecture). Release target: **v1.0.1** patch over released v1.0.0.
> Input: `.specs/hermes-brief-v1.0.1-power-audio.md` (Hera). Evidence is settled; this
> document CONFIRMS hypotheses against source and defines the fix design.
> Implementer: Forge (cheap model — exact files/symbols are spelled out below).
> Validator: Karen (§7 is your starting baseline).
> Kernel profile baseline: **D42-R3**; new kernel tag: **d43**.

---

## Executive summary

**WS1 (battery):** Live telemetry (18 h idle, 12 h awake) is produced by two input-event
generators feeding Android's per-client evdev suspend-block wakelock (`event0`), plus an
MT662x WLAN ISR storm holding `"WLAN AHB ISR"` 100 ms per interrupt with no driver suspend
path at all. Source review surfaced a **new primary suspect**: the PMIC fchrkey pin — unwired
on the Q5 — is mapped to KEY_VOLUMEDOWN with its PMIC interrupt enabled at boot
(`KPD_PMIC_RSTKEY_MAP`, `upmu_set_rg_int_en_fchrkey(1)`), generating phantom volume events.
The chosen fix (W1) kills both generators (D43: unmap + mask FCHRKEY + 150 ms matrix glitch
filter), tightens the WLAN ISR window 100→20 ms (D44), and bakes `wifi_sleep_policy=0`.
No driver removal; touch/accdet/audio surfaces untouched.

**WS2 (volume keys):** The phone personality is not `ro.radio.noril` (which was set live
only and appears in no shipped artifact) but `config_voice_capable=true` — byte-level
verified in the shipped `framework-res.apk` (`resources.arsc`, resid `0x0112006c`,
value `0xffffffff`). The fix (V1) flips that one resource to false at build time via a new
self-verifying arsc patcher and bakes `ro.radio.noril=true` into build.prop. No smali
changes, no telephony-package removal.

Release shape: kernel boot image tag **d43** (D42-R3 + D43 + D44), system image v1.0.1 via
the existing pipeline, one combined TWRP clean-install package. All work gated by host
tests, offline image asserts, and 14 on-device validation gates with quantitative thresholds.

---

## 0. Scope and invariants

Two workstreams in ONE combined release:

- **WS1** — idle battery drain: the device must reach and hold deep sleep when idle with
  the screen off, with WiFi associated, and resume correctly.
- **WS2** — hardware volume keys must default to STREAM_MUSIC (media), not STREAM_RING.

Non-regression invariants (I-numbers are cited throughout):

| # | Surface to preserve | Prior evidence |
|---|---------------------|----------------|
| I1 | Touch (mtk-tpd/GSL, event3) + bezel Home (mtk-tpd-kpd, event4) + Home shortcuts (tap/double-tap/hold) | user-confirmed D37/D39 |
| I2 | Speaker playback, headphone/speaker switching, unplug-pause/resume | user-confirmed D36 |
| I3 | FM tuner via Lineage FMRadio (software rendering, `persist.af.audio_patch_fm=1`) | user-confirmed |
| I4 | Voice recorder capture/playback | user-confirmed |
| I5 | USB MTP+ADB (D42-R2 ramdisk functions) | verified |
| I6 | WiFi networking (ping, HTTPS) | verified |
| I7 | Media playback (H.264 hw decode path) | verified |
| I8 | Hardware volume keys generate correct KEY_VOLUMEUP/KEY_VOLUMEDOWN from mtk-kpd | verified (D22 PTY capture) |
| I9 | Volume keys usable while screen is OFF during audio playback (pocket/radio use; the SoC is already awake then under the audio stream wakelock) | implied by music-player product role — explicitly added as a gate |
| I10 | Power key sleep/wake cycles (PMIC pwrkey path) | daily use |
| I11 | Bluetooth controller ON/OFF toggle | verified |

Build/test tooling conventions to reuse: `build/prepare_kernel.py --series`,
`build/75_kernel_delta_coherent_dma.sh` shared pipeline, `build/55_repack_boot.sh`,
`build/test_touch_key_protocol.py` gate, `build/apply_system_defaults.py` system-image
transform, `build/package_checkpoint.py`, hash-pinned manifests under `manifests/`.

---

## 1. Verification result (what I confirmed against source — no re-diagnosis)

### 1.1 WS1 evidence chain — CONFIRMED and sharpened

Hera's hypothesis (input-driver/EINT/WLAN storms keep the SoC awake) is confirmed by
source reading, with one sharpening: **the batterystats "event0..event4" kernel wakelocks
are not driver-internal locks — they are Android evdev per-client suspend-block
wakelocks, named after the event node and the reader PID.**

Confirmed mechanism, all symbols:

1. **`drivers/input/evdev.c`** (this 3.10.54 tree) implements per-client suspend blocking:
   - `struct evdev_client { ...; struct wake_lock wake_lock; bool use_wake_lock; char name[28]; ... }` (lines 45–59).
   - Client name: `snprintf(client->name, sizeof(client->name), "%s-%d", dev_name(&evdev->dev), task_tgid_vnr(current));` (lines 372–373) → the wakelock batterystats calls `event0` is the event0 client's lock (suffix `-<tgid>` is visible in `/sys/kernel/debug/wakeup_sources`).
   - `__pass_event()` (lines 61–90): **on every `EV_SYN/SYN_REPORT` packet it does `wake_lock(&client->wake_lock)`** (lines 84–87); the lock is released only when the reader drains the queue (`evdev_fetch_next_event`, lines 429–448: `if (client->use_wake_lock && client->packet_head == client->tail) wake_unlock(...)`) or the buffer overflows.
   - Enabled via `EVIOCSSUSPENDBLOCK` ioctl (lines 842–848; `evdev_enable_suspend_block`, 731–744). Android's EventHub enables this for input devices; the kernel-side behavior is unconditional once enabled.
   - **Consequence:** any driver emitting SYN_REPORTs while the system is idle holds a suspend wakelock from emission until InputReader consumes. A ~2.9 Hz event stream chains to ~40 % hold duty (measured: event0 held 6h59m of 12h awake).

2. **mtk-kpd (event0) has TWO live event generators on this tree** — the tree alone cannot
   prove which dominates on hardware, so the fix covers both (§4.1):
   - **(a) PMIC FCHRKEY phantom path — root-cause suspect #1 (new finding, not in the brief):**
     `arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h:84` defines
     `#define KPD_PMIC_RSTKEY_MAP KEY_VOLUMEDOWN`. The a106 lineages wire the PMIC
     "home/reset" key pin to a button; **the Q5 does not** (Q5 Home is the touch bezel —
     see CURRENT-STATUS D37/D39). The pin is floating and its interrupt is enabled at boot:
     `cust_pmic_interrupt_en_setting()` calls `upmu_set_rg_int_en_fchrkey(1)`
     (`drivers/misc/mediatek/power/mt6582/pmic_mt6323.c:578`), and
     `PMIC_INIT_SETTING_V1()` (pmic_mt6323.c:3359) pokes `RG_INT_EN_FCHRKEY` = 1 twice more
     (0x166 writes at ~lines 3406 and ~3495). Every edge runs `fchr_key_int_handler()`
     (pmic_mt6323.c:765–785), which flips its own polarity (`upmu_set_rg_fchrkey_int_sel`)
     and calls `kpd_pmic_rstkey_handler(pressed)` (kpd.c:369–380) → `kpd_pmic_rstkey_hal`
     (hal_kpd.c:504–515, body guarded by `#ifdef KPD_PMIC_RSTKEY_MAP`) →
     `input_report_key(kpd_input_dev, KEY_VOLUMEDOWN, ...)` — **a phantom KEY_VOLUMEDOWN
     press/release pair per line wiggle, straight into event0**, bypassing the matrix
     scanner entirely. This is the classic MTK floating-PMIC-key storm.
   - **(b) KPD matrix scan path:** `kpd_irq_handler` (kpd.c:434–444) → tasklet
     `kpd_keymap_handler` (kpd.c:385–432): reads `kpd_get_keymap_state()` (hal_kpd.c:310–319),
     and reports EVERY observed 16-bit register toggle with no stability qualification.
     HW debounce is only `KPD_KEY_DEBOUNCE 1024` = 32 ms (cust_kpd.h:72; matches the pinned
     Lithium blob per the D20 note). Only two slots are live ({[0]=KEY_VOLUMEUP,
     [1]=KEY_VOLUMEDOWN}, cust_kpd.h:90–94, D22-reversed); a noisy column line toggles those
     slots and every toggle becomes input events. No wake-source registration exists
     (`kpd_wakeup_src_setting` only gates KP_EN, hal_kpd.c:463–477; suspend path
     kpd.c:899–928 runs only at full system suspend), so during screen-off-awake periods
     the scanner churns unbounded.
   - Attribution between (a) and (b) is **readable on the current device in 10 minutes**
     (both paths printk): `dmesg` counting `[fchr_key_int_handler]` vs `kpd: register =`
     lines (§7 gate V0). The design fixes both regardless; the gates measure the outcome.

3. **MT662x (CONSYS_6582) WLAN — CONFIRMED:**
   - `HifAhbISR` (`drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/hif/ahb/ahb.c:1841–1895`) masks the host interrupt (`MCR_WHLPCR/WHLPCR_INT_EN_CLR`, line 1869) then **unconditionally takes a 100 ms suspend wakelock on every interrupt** via `kalHifAhbKalWakeLockTimeout(GlueInfo)` (line 1884) → `gl_kal.c:773–780`: `KAL_WAKE_LOCK_TIMEOUT(..., (HZ/10))`. Wakelock object `"WLAN AHB ISR"` created at `gl_init.c:2933`.
   - `"WLAN TX THREAD"` wakelock (wlan_lib.c:1293) is wrapped around the tx-thread loop body (gl_kal.c:2957–2965): one lock/unlock per wakeup — 399k wakeups × ~1.9 ms matches the telemetry shape.
   - **No Linux suspend handling at all**: `HifAhbPltmSuspend()` is a stub `{ return 0; }` (ahb.c:2354–2359); `.resume` likewise. No WOWLAN, no IRQ masking, no PS negotiation at suspend. At idle the host keeps getting interrupt traffic (beacon/broadcast class) at ~2.3 Hz → 100 ms × 2.3 Hz ≈ 23 % hold duty (measured 4h48m/18h).
   - Wakelocks are active: `gl_kal.h:689–709` compiles them only `#if CONFIG_ANDROID`; `q5_defconfig:2550 CONFIG_ANDROID=y`, `511 CONFIG_WAKELOCK=y`, `543 CONFIG_PM_WAKELOCKS=y`, `540 CONFIG_PM_SLEEP=y`. Chip config: `1299 CONFIG_MTK_COMBO_CHIP_CONSYS_6582=y`, `1304 CONFIG_MTK_WLAN_CHIP="CONSYS_MT6582"`.

4. **ACCDET (event1) — ruled MINOR, keep behavior:** 4 internal wakelocks exist
   (`accdet.c:63–66`, init 1369–1372); the suspend/resume handlers are compiled to no-ops
   (`#if 0` blocks, accdet.c:1435–1510) so detection stays live in suspend — **required**
   for I2 (unplug detection). Held only 14m55s/18h. EINT ch 4 is level-LOW with debounce
   256 (`cust_eint.h:43–46`); churn exists while awake but is cheap (avg 4.7 ms holds).
   **Decision: do not touch accdet in v1.0.1.**

5. **mtk-tpd (event3) / mtk-tpd-kpd (event4) — ruled MINOR, do not touch:** the GSL driver
   masks its EINT at earlysuspend (`tpd_suspend` → `mt_eint_mask(CUST_EINT_TOUCH_PANEL_NUM)`,
   `drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.c:1412–1422`; unmask in
   `tpd_resume` at 1451; wired by `mtk_tpd.c:376–378`). Held 12–13 min/18h. Touch is the
   highest-regression-risk surface on this device; **no changes.**

6. **Answer to Hera Q1 ("is the kpd path even used?"):** YES — volume keys arrive through
   the KPD matrix on this board (D22 PTY evidence) AND through the phantom PMIC fchrkey
   map (this brief's suspect). mtk-tpd-kpd carries only the bezel Home. No input driver on
   the storm list is unused — the correct fix is targeted quiescing/source-kill, not
   driver removal. The genuinely unused thing on this board is the *fchrkey mapping*, and
   that is exactly what we remove.

7. **Already-ruled-out re-verified:** RIL — `ril-daemon` not running and, see §1.2, the
   noril property is not even in the shipped pipeline; apps — ~3 min partial wakelock;
   screen — off 96.7 %.

### 1.2 WS2 evidence chain — CONFIRMED, and the contradiction is now fully resolved

**The contradiction dissolves into two separate facts:**

1. **`ro.radio.noril=true` is NOT part of any shipped artifact.** It exists nowhere in the
   build pipeline (`patches/`, `build/*.py`, `build/*.sh`), not in `.reference-lithium/build.prop`
   (only `persist.radio.multisim.config=dsds` etc. are present), not in the ramdisk patchers.
   It was set **live** on the running device. So at v1.0.0 the phone-level radio disable is
   not even reproducible from source. v1.0.1 must bake it (§5.4) — orthogonal to volume keys.
2. **The shipped framework reports voice-capable = true, byte-level proven:** in the shipped
   `.reference-lithium/framework/framework-res.apk`, `resources.arsc` package `android` (0x01),
   key string `config_voice_capable` exists (key index 9186 of 9567) as **bool, type id 0x12,
   entry 0x6c (= resource id `0x0112006c`), default config, value `0xffffffff` (TRUE)**, value
   field at arsc offset `0x1281ee4`. This is the AOSP phone default; Lithium did not override it.

Mechanism (symbol-level, cross-checked against the shipped binaries; all names verified
present): volume keys with no active media session route
`PhoneWindowManager`/`MediaSessionLegacyHelper` → `AudioManager.adjustSuggestedStreamVolume(dir, USE_DEFAULT_STREAM_TYPE, flags)` →
`AudioService.getActiveStreamType(...)` (present in shipped `services.jar`'s classes.dex,
alongside `mPlatformType` and `isInCommunication`) → which consults `mPlatformType`, set in
the AudioService constructor from `AudioSystem.getPlatformType(context)`; that helper
(present in shipped `framework.jar` alongside the `PLATFORM_VOICE`/`PLATFORM_TELEVISION`
constants and the `config_voice_capable` name) returns **PLATFORM_VOICE iff
`config_voice_capable` is true**. With PLATFORM_VOICE, the no-active-stream fallback is the
ringtone stream → **volume keys adjust STREAM_RING**. With the flag false (PLATFORM_DEFAULT)
the fallback is **STREAM_MUSIC** — this is exactly how AOSP/Lineage tablets behave.
Telephony priv-apps (Dialer, TeleService, Telecom, TelephonyProvider, MmsService,
CellBroadcastReceiver, …) are present in the image, but **no package removal flips this
resource flag** — package removal is not the lever.

---

## 2. WS1 options and decision

### Option W1 — Targeted source-kill + bounded glitch filter + ISR wake-window tightening (RECOMMENDED)

Components (all built into kernel tag **d43**, patches D43/D44):
- **K1** Remove the phantom PMIC→keypad mapping entirely: delete
  `KPD_PMIC_RSTKEY_MAP` from `arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h`.
  All consumers are `#ifdef`-guarded (hal_kpd.c:504 function body, kpd.c:377 AEE hook),
  so `kpd_pmic_rstkey_handler`/`fchr_key_int_handler` become harmless no-ops for input.
- **K2** Stop the FCHRKEY interrupt from being enabled at all:
  `cust_pmic_interrupt_en_setting()`: `upmu_set_rg_int_en_fchrkey(1) → (0)`;
  in `PMIC_INIT_SETTING_V1()` change BOTH `pmic_config_interface(0x166,0x1,0x1,1)` pokes
  to mask `0x0`. PWRKEY stays enabled (`upmu_set_rg_int_en_pwrkey(1)` unchanged;
  the 0x166 bit-0 pwrkey pokes untouched) — explicit build-time assert.
- **K3** Matrix-path glitch filter in kpd.c: replace immediate report in
  `kpd_keymap_handler` with a *sample → delayed-verify → report only stable bits* scheme
  using one restartable `delayed_work` (`kpd_glitch_ms`, module_param, default **150 ms**).
  Rationale for 150 ms: real physical volume presses hold ≥ ~180–250 ms; the measured phantom
  cadence is ~2.9 Hz. Bits unstable across the window are dropped and counted
  (rate-limited printk + counter for field diagnosis).
- **K4** WLAN ISR wakelock window: `kalHifAhbKalWakeLockTimeout` `HZ/10` (100 ms) →
  `HZ/50` (20 ms) in gl_kal.c:779. The lock exists only to cover IST dispatch racing
  suspend; the main thread is already woken immediately (ahb.c:1890). 5× cut of the WLAN
  hold accumulation at the observed ~2.3 Hz idle IRQ rate (4h48m/18h → ~1h/18h worst case,
  expected far less; gates below).
  Also gate the unconditional per-scan register printk in hal_kpd.c:317 behind a new
  `kpd_show_scan` module_param default 0 (spam/CPU hygiene; keep D42-era diagnosability via param).
- **S1** Bake `wifi_sleep_policy=0` as the shipped default (Hera's live mitigation made
  reproducible): patch `def_wifi_sleep_policy` → 0 inside shipped
  `/priv-app/SettingsProvider/SettingsProvider.apk` (resource exists in its arsc — verified).

Tradeoffs: K1/K2 permanently surrender the (unwired) PMIC secondary key pin — zero cost on
Q5 hardware; rollback = flash D43-superseded boot image. K3 adds ≤150 ms report latency to
volume keys (imperceptible; Android long-press handled framework-side by hold time).
K4 is a latency/PM window change only. S1 only seeds defaults on clean installs (the v1.0.1
delivery path is clean-install, matching v1.0.0 practice).

Addresses: event0 storm (both generators), WLAN ISR window, TX-thread downstream churn,
and bakes the WiFi sleep policy — the complete WS1 envelope with minimal touch surface.

### Option W2 — Bound the evdev suspend-block wakelock (kernel-generic)

Replace `wake_lock()` at evdev.c:87 with `wake_lock_timeout(&client->wake_lock, ...)` so a
storming device cannot hold suspend indefinitely regardless of driver fixes.
Tradeoffs: changes Android input-core semantics for **every** input device (touch, accdet,
tpd-kpd included); risks missing genuine wake-key delivery on a slow InputReader; masks
rather than fixes driver defects; harder to validate exhaustively for I1/I9/I10.
**Rejected for v1.0.1.** Revisit only if W1's on-device metrics still show event0-class
holds above gate thresholds.

### Option W3 — Config-only mitigation (no kernel change)

Ship only S1 (+ optionally an init.d-style `settings put` at boot) and accept the kpd/WLAN
storms during screen-off-awake. Tradeoffs: leaves the dominant 7h-held wakelock generator
in place; the device still cannot reliably reach deep sleep while idle-awake churn exists.
**Rejected as insufficient**; S1 is folded into W1 instead.

### Option W4 — Full WLAN power-save rework (WOWLAN/host-suspend integration in `HifAhbPltmSuspend`, firmware PS/offload negotiation at suspend)

Most "correct" long-term; requires conn_soc firmware-mailbox PS negotiation, ARP/multicast
offload config, resume re-association behavior, and extensive on-device WiFi validation.
Tradeoffs: high regression risk to I6 (network) for a patch release; days of validation.
**Deferred** — revisit criteria in §8.

### Decision record (ADR-m5-WS1)

- Problem: 12h/18h idle wake, dominated by `event0` (6h59m held) + `WLAN AHB ISR` (4h48m) + TX churn.
- Decision: **W1** (K1+K2+K3+K4 kernel; S1 system default).
- Alternatives considered: W2 (input-core bound), W3 (config-only), W4 (WOWLAN rework) — above.
- Rationale: W1 removes both confirmed event generators at their source, bounds the third
  amplifier, and is fully covered by host tests + on-device metric gates; smallest blast radius.
- Consequences: volume-key reporting gains ≤150 ms software latency; fchrkey pin becomes
  permanently report-less on this product (it is unwired; nothing to lose).
- Revisit: if post-fix 60-min soak still shows event0 > 60 s held or `WLAN AHB ISR` >
  4 min·held/h, escalate to W2/W4 respectively (§8).

---

## 3. WS2 options and decision

### Option V1 — Flip `config_voice_capable` to false in framework-res.apk at build time (RECOMMENDED)

A new deterministic build tool edits the shipped binary resource: bool key
`config_voice_capable` (res id `0x0112006c`) in `resources.arsc` of the donor
`framework-res.apk`: TRUE → FALSE. Everything downstream (branding drawable replacement,
apply_system_defaults install) treats it as data; branding preserves arsc entry bytes
(the branding builder only replaces drawable entries and re-zips with preserved alignment).

- **Baked-in `ro.radio.noril=true`** as a build.prop line in apply_system_defaults.py,
  making the previously live-only setting reproducible (also keeps ril-daemon reliably off).
- **No telephony package removal.** Not required for the behavior change; removal risks
  background service ANRs/crashes for zero functional gain in a music-player release.

Tradeoffs: `TelephonyManager.isVoiceCapable()` becomes false framework-wide; Settings/keyguard
hide voice-only affordances (desirable here); emergency-dial affordances on the lockscreen
reduce — acceptable for this product (no modem at all). Package presence unchanged → lowest
regression risk vs Option V2/V3.

### Option V2 — Smali-patch `com.android.server.audio.AudioService` in services.jar

Force `mPlatformType` to `AudioSystem.PLATFORM_DEFAULT` or rewrite the
`getActiveStreamType` fallback branch. We already smali-patch services.jar for F1 (Home).
Tradeoffs: patches hot audio-service code paths (a regression there breaks ALL volume
behavior, incl. in-call/communication fallbacks — precisely the code Karen must not need to
re-certify); duplicates what a resource already expresses; needs re-derivation per donor.
**Rejected.**

### Option V3 — Remove telephony packages (TeleService/Telecom/TelephonyProvider/Dialer/…)

Does not change the resource flag → **proven insufficient for the defect** (§1.2). As pure
hygiene it saves some RAM/flash but introduces init/uid ordering risk with `com.android.phone`
process dependents. **Rejected** (documented here so it is not re-proposed as the lever).

### Decision record (ADR-m5-WS2)

- Problem: volume keys adjust STREAM_RING on a voice-incapable device.
- Decision: **V1** (arsc bool flip + bake noril prop), no package removal, no smali change.
- Alternatives: V2 (smali force), V3 (package removal) — above.
- Rationale: V1 is the exact AOSP tablet configuration; one byte-class change in a value
  field; zero Java/native code change; fully verifiable offline (parser self-check +
  byte-diff-equals-intended-set gate) and on-device (stream-selection dump).
- Consequences: framework-wide voice-incapable presentation; noril now source-controlled.
- Revisit: never expected; the flag is the canonical mechanism.

---

## 4. Root-cause code map (verified; cite these in patches)

### 4.1 WS1 — idle drain chain

```
[WS1-A: PMIC fchrkey phantom path]
drivers/misc/mediatek/power/mt6582/pmic_mt6323.c
  cust_pmic_interrupt_en_setting():578      upmu_set_rg_int_en_fchrkey(1)          <- enables IRQ
  PMIC_INIT_SETTING_V1():3359 (0x166 pokes ~3406 & ~3495)  RG_INT_EN_FCHRKEY=1     <- enables IRQ
  pmic dispatch:907                          INT_STATUS1 bit1 -> fchr_key_int_handler()
  fchr_key_int_handler():765-785             flips polarity, calls kpd_pmic_rstkey_handler()
arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h:84  #define KPD_PMIC_RSTKEY_MAP KEY_VOLUMEDOWN
drivers/misc/mediatek/keypad/kpd.c:369-380   kpd_pmic_rstkey_handler -> kpd_pmic_rstkey_hal
drivers/misc/mediatek/keypad/mt6582/hal_kpd.c:504-515  input_report_key(KEY_VOLUMEDOWN)
drivers/input/evdev.c:84-87                  wake_lock() on SYN_REPORT -> "event0*" held

[WS1-B: KPD matrix scan path]
drivers/misc/mediatek/keypad/kpd.c:434-444   kpd_irq_handler: disable_irq_nosync + tasklet
drivers/misc/mediatek/keypad/kpd.c:385-432   kpd_keymap_handler: reports EVERY toggle, enable_irq at end
drivers/misc/mediatek/keypad/mt6582/hal_kpd.c:310-319  kpd_get_keymap_state (also prints scan regs)
arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h:72      KPD_KEY_DEBOUNCE 1024 (=32 ms, HW only)
arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h:90-94   active map {[0]=VOLUP,[1]=VOLDOWN} (D22)
kpd.c:899-928                                suspend hooks only KP_EN gate at full suspend

[WS1-C: WLAN ISR churn]
.../conn_soc/drv_wlan/mt_wifi/wlan/os/linux/hif/ahb/ahb.c
  HifAhbISR():1841-1895                      INT_EN_CLR (1869) + 100ms wakelock (1884) + wake (1890)
  HifAhbPltmSuspend():2354-2359              STUB { return 0; }  <- no suspend handling
.../wlan/os/linux/gl_kal.c:773-780           kalHifAhbKalWakeLockTimeout: KAL_WAKE_LOCK_TIMEOUT(HZ/10)
.../wlan/os/linux/gl_init.c:2933             "WLAN AHB ISR" wakelock init
.../wlan/common/wlan_lib.c:1293              "WLAN TX THREAD" wakelock init
.../wlan/os/linux/gl_kal.c:2957-2965         tx thread: wake_unlock / wait_event / wake_lock per pass
```

### 4.2 WS2 — stream-selection chain

```
KEY_VOLUMEUP/DOWN on mtk-kpd (matrix path, D22-corrected map)
 -> PhoneWindowManager / MediaSessionLegacyHelper
 -> AudioManager.adjustSuggestedStreamVolume(dir, USE_DEFAULT_STREAM_TYPE, flags)
 -> AudioService.getActiveStreamType()          [services.jar: symbol verified present]
 -> mPlatformType == PLATFORM_VOICE ?           [services.jar: symbol verified present]
    <- AudioSystem.getPlatformType(ctx)         [framework.jar: verified present]
    <- Resources.getBoolean(R.bool.config_voice_capable) = TRUE  [framework-res.apk arsc:
        package android(0x01), bool type 0x12 entry 0x6c -> resid 0x0112006c, value 0xffffffff,
        value-field arsc offset 0x1281ee4]
 -> fallback stream = STREAM_RING   (BUG for this product)
```

Ships-side corroboration: `.reference-lithium/priv-app/` contains the full telephony set
(Dialer, TeleService, Telecom, TelephonyProvider, MmsService, CellBroadcastReceiver,
CarrierConfig, EmergencyInfo) — consistent with a phone-configured ROM that never had SIM/modem.

---

## 5. Implementation specification (Forge: implement EXACTLY this; do not improvise)

### 5.1 Kernel changes — new tag **d43**, two patches

Create:
- `patches/kernel/D43-kpd-phantom-storm.patch` (K1+K2+K3+scan-log gate)
- `patches/kernel/D44-wlan-ahb-isr-window.patch` (K4)
- `build/kernel-d43.series` = exact contents of `build/kernel-d42.series` **plus** the two
  new patches appended in this order: D43, D44.
- `build/82_kernel_delta_power_audio.sh` — thin wrapper following the 78 pattern:
  sets `export Q5_KERNEL_TAG=d43` and execs `75_kernel_delta_coherent_dma.sh`.
  ALSO extend `75_kernel_delta_coherent_dma.sh`'s tag case list from
  `d36|d37|d38|d39|d40|d41|d42` to include `d43`, and extend its JUMP_LABEL/RODATA config
  assertions + `test_touch_key_protocol.py` gate so d43 runs them (i.e., treat d43 like d42).
- `patches/kernel/DELTA-NOTES.md`: append the D43/D44 invariant entries below.

#### 5.1.1 D43 details

**File `arch/arm/mach-mt6582/q5/keypad/mtk_kpd.h` (K1)**
- Delete the line `#define KPD_PMIC_RSTKEY_MAP KEY_VOLUMEDOWN` (currently line 84).
- In its place, add a banner comment (following the D20/D22 comment style) stating:
  the Q5 fchrkey pin is unwired; D22 PTY evidence places VOLDOWN on matrix slot [1];
  fchrkey IRQ left storming produced phantom KEY_VOLUMEDOWN pairs on event0 (m5 evidence).
- Do NOT touch: `KPD_PWRKEY_USE_PMIC KPD_YES`, `KPD_PWRKEY_USE_EINT KPD_NO`,
  `TWOKEY_REBOOT_*`, `KPD_PMIC_LPRST_TD`, keymap/debounce defines.

**File `drivers/misc/mediatek/power/mt6582/pmic_mt6323.c` (K2)**
- In `cust_pmic_interrupt_en_setting()` (starts ~line 562): change
  `upmu_set_rg_int_en_fchrkey(1);` → `upmu_set_rg_int_en_fchrkey(0);` with a one-line D43 comment.
- In `PMIC_INIT_SETTING_V1()` (starts line 3359): change BOTH occurrences of
  `ret = pmic_config_interface(0x166,0x1,0x1,1); // [1:1]: RG_INT_EN_FCHRKEY;`
  to mask `0x0` (i.e. `pmic_config_interface(0x166,0x0,0x1,1);`), with a D43 comment each.
- **DO NOT CHANGE** any other `pmic_config_interface` poke or `upmu_set_rg_int_en_*` call;
  pwrkey enable (`upmu_set_rg_int_en_pwrkey(1)`) must remain exactly 1. Patch asserts below.

**File `drivers/misc/mediatek/keypad/kpd.c` (K3)** — matrix glitch filter:
- Add module param at the existing module_param block (next to `kpd_show_hw_keycode`, ~line 1011):
  `static int kpd_glitch_ms = 150;` + `module_param(kpd_glitch_ms, int, 0644);`
- Add state (place near the keymap state globals, ~line 45):
  - `static u16 kpd_pending_state[KPD_NUM_MEMS];`
  - `static u16 kpd_reported_state[KPD_NUM_MEMS];` (initialised in probe from `kpd_init_keymap_state` values)
  - `static struct delayed_work kpd_glitch_work;`
  - `static unsigned long kpd_glitch_drops;` (counter)
- Add work function `static void kpd_glitch_work_func(struct work_struct *work)`:
  ```
  1. read current state S2 via kpd_get_keymap_state(S2_buf)
  2. for each mem slot i: stable_mask = ~(S1[i] ^ S2[i])   // bits equal across the two samples
     changed      = S2[i] ^ kpd_reported_state[i]
     report_mask  = changed & stable_mask
     for each set bit j in report_mask:
         hw_keycode = (i<<4)+j; pressed = !(S2[i] & (1U<<j));
         linux_keycode = kpd_keymap[hw_keycode];
         if (linux_keycode == 0) continue;
         kpd_aee_handler(linux_keycode, pressed);
         kpd_backlight_handler(pressed, linux_keycode);
         input_report_key(kpd_input_dev, linux_keycode, pressed);
         input_sync(kpd_input_dev);
     kpd_glitch_drops += hweight16(S1[i] ^ S2[i]);   // CORRECTION: popcount(changed & ~stable_mask) is provably 0 for self-contained glitch pulses (Karen-verified); hweight16(S1^S2) = the bits the window killed — matches storm-attribution intent, report behavior unchanged.
     kpd_reported_state[i] = (S2[i] & stable_mask) | (kpd_reported_state[i] & ~stable_mask);
  3. if drops were nonzero, printk_ratelimited (KPD_SAY "dropped %lu glitch bits\n", ...)
  ```
- Rewrite `kpd_keymap_handler` (tasklet, kpd.c:385–432) to ONLY:
  ```
  kpd_get_keymap_state(kpd_pending_state);       // S1 sample
  schedule_delayed_work(&kpd_glitch_work, msecs_to_jiffies(kpd_glitch_ms));
  enable_irq(...)                                // keep the existing CONFIG_OF/else form verbatim
  ```
  It must no longer report keys itself. Preserve the existing `#ifdef CONFIG_OF ... #else
  enable_irq(MT_KP_IRQ_ID) #endif` structure exactly (both branches keep their symbol).
- In `kpd_pdrv_probe` (after the `hrtimer_init` blocks, ~line 881): add
  `INIT_DELAYED_WORK(&kpd_glitch_work, kpd_glitch_work_func);` and initialise
  `kpd_reported_state`/`kpd_pending_state` via `kpd_init_keymap_state(...)` (same initial map).
- In `kpd_pdrv_suspend` (kpd.c:899–913): FIRST statement `cancel_delayed_work_sync(&kpd_glitch_work);`
  (before the existing KP_EN wake-source logic; keep everything else).
- In `kpd_pdrv_resume` (kpd.c:915–928): after existing logic, re-sync baselines WITHOUT reporting:
  `kpd_get_keymap_state(buf); memcpy(kpd_reported_state, buf); memcpy(kpd_pending_state, buf);`
  (guards a press spanning a suspend from becoming a stuck key).
- Keep `kpd_aee_handler`, hrtimer setup, AEE 5s/15s logic EXACTLY as-is (the AEE flow operates
  on reported events only; both volume keys still deliver press+release for genuine holds).
- Constraint: NO `msleep`/`schedule_timeout` in the tasklet; work item runs on the system
  workqueue (`schedule_delayed_work`) — do not create a custom wq.

**File `drivers/misc/mediatek/keypad/mt6582/hal_kpd.c` (scan-log gate, part of K3)**
- Add near the top statics (~line 21): `static int kpd_show_scan = 0;` and at file scope
  after `kpd_get_keymap_state` add `module_param(kpd_show_scan, int, 0644);`.
- Gate the `printk(KPD_SAY "register = %x %x %x %x %x\n", ...)` inside `kpd_get_keymap_state`
  (line 317) on `if (kpd_show_scan)`. (The press/release printk at 350 remains on the
  existing `kpd_show_hw_keycode` flag.)

**D43 DELTA-NOTES.md entry (copy verbatim headings):**
```
## D43 (m5 power: phantom-input storm kill)
- Invariants asserted by build/82 gates:
  (1) mtk_kpd.h no longer defines KPD_PMIC_RSTKEY_MAP (grep must FAIL);
  (2) cust_pmic_interrupt_en_setting enables fchrkey with argument 0;
  (3) PMIC_INIT_SETTING_V1 has zero '0x166,0x1,0x1,1' occurrences;
  (4) upmu_set_rg_int_en_pwrkey(1) unchanged (grep must find it);
  (5) cust_kpd.h keymap still {[0]=KEY_VOLUMEUP,[1]=KEY_VOLUMEDOWN}, KPD_KEY_DEBOUNCE 1024;
  (6) kpd.c reports keys only from kpd_glitch_work_func (grep: input_report_key count in
      kpd_keymap_handler body == 0);
  (7) D39 contract intact: build/test_touch_key_protocol.py passes (runs in 75-chain for d43).
- Rationale: .specs/bob-m5-power-audio-spec.md §1.1/§2 (W1).
```

#### 5.1.2 D44 details

**File `drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/gl_kal.c`**
- In `kalHifAhbKalWakeLockTimeout` (lines 773–780): change `(HZ/10)` to `(HZ/50)` with a
  D44 comment (100 ms → 20 ms; reason + spec ref).
- Nothing else in the connectivity tree changes. **DO NOT** touch `HifAhbISR`,
  `HifAhbPltmSuspend`, the tx thread, wakelock names, or any config.h value.

**D44 DELTA-NOTES.md entry:**
```
## D44 (m5 power: bound WLAN AHB ISR suspend window 100ms -> 20ms)
- Invariants: HifAhbISR wake_up call unchanged; "WLAN AHB ISR"/"WLAN TX THREAD" names unchanged;
  HifAhbPltmSuspend/Resume untouched; q5_defconfig CONSYS_6582 selection unchanged.
- Rationale: .specs/bob-m5-power-audio-spec.md §1.1 item 3, §2 (W1/K4); revert criterion §8 R3.
```

#### 5.1.3 Kernel build & gates (Forge runs, in order)

```
Q5_BUILD_WORK=/root/q5-build-d43 bash build/82_kernel_delta_power_audio.sh \
    /root/q5-kernel-reference /path/to/boot-before.img
# emits out/boot-d43.img (+ .sha256) — never flashes
```
Assert (build aborts on any failure): D43 gate greps (1)–(6) above; d39 protocol gate
passes; `CONFIG_JUMP_LABEL` off + `DEBUG_RODATA` on preserved; q5_defconfig diff vs d42
build = EMPTY (no config drift allowed for m5).

### 5.2 New build tool — `build/patch_arsc_values.py` (WS2 + S1)

Purpose: deterministic, self-verifying binary patch of ONE named value resource inside an
APK's `resources.arsc`, for aapt-compiled APKs (UTF-8 string pools, multiple configs).

CLI:
```
python3 build/patch_arsc_values.py \
    --apk in.apk --out out.apk \
    [--set-bool config_voice_capable=false | --set-int def_wifi_sleep_policy=0] \
    --manifest out.arsc-manifest.json
```
Required behavior (implement with `zipfile` + raw arsc walking; NO apktool/aapt dependency):
1. Parse `resources.arsc`: ResTable header → global string pool → per-package:
   key string pool, type string pool, then TYPE_SPEC (0x0202) / TYPE (0x0201) chunk walk.
   String decode must handle UTF-8 pools (1- and 2-byte length forms) and UTF-16 pools.
   (Reference decoder logic is proven in the m5 scratch run: stringsStart is relative to the
   pool chunk start; TYPE chunk id byte at +8; entry offsets after the TYPE header; entry
   header = size u16 / flags u16 / key index u32; value at entry+size = size u16 / res0 u8 /
   dtype u8 / data u32.)
2. Match by KEY NAME and TYPE NAME: for `--set-bool`, type must decode to `bool`
   (dtype must be 0x12 in matched entries); for `--set-int`, accept type `integer`
   (dtype 0x10) or `dimen`-named types rejected. Apply to **every** config's entry whose key
   matches (framework-res has a single default config; SettingsProvider too — assert ≥1 hit,
   print per-hit before/after values, refuse to proceed on 0 hits or dtype mismatch).
3. Rewrite the APK: copy ALL zip entries byte-identical except `resources.arsc` (which is
   replaced with the patched blob). Preserve each entry's compression, ordering, and for
   STORED entries the existing 4-byte alignment padding convention (mirror the exact zip
   rebuild technique of `build/build_branding.py` — reuse its helper pattern).
4. Self-verification (fail the build if ANY check fails):
   - Re-parse the output APK; the target value must read back as requested.
   - Byte-diff original vs patched arsc blobs: the set of differing 4-byte-aligned regions must
     equal exactly the set of patched value fields (no other bytes changed anywhere).
   - All other zip entries byte-identical (`sha256` per entry, compare to input).
5. Manifest JSON: input/output apk sha256, patched resource name/id/count, before/after
   values, arsc byte-diff offsets. `apply_system_defaults.py` and Karen consume this.

Targets for v1.0.1:
- **T1** donor `framework-res.apk`: `--set-bool config_voice_capable=false`.
- **T2** donor `priv-app/SettingsProvider/SettingsProvider.apk`: `--set-int def_wifi_sleep_policy=0`
  (resource verified present in shipped arsc; current default 2 — matches Hera's live finding).

### 5.3 Pipeline integration

Order (all driven from repo scripts; add to `docs/INSTALL.md` release recipe):
```
KERNEL:  build/82_kernel_delta_power_audio.sh  -> out/boot-d43.img
FRAMEWORK: donor framework-res.apk -[T1]-> work/v101/framework-res.vc.apk
BRANDING:  build/build_branding.py --framework work/v101/framework-res.vc.apk -> out/branding/
           (branding preserves arsc bytes; assert below proves it)
SETTINGSP: donor SettingsProvider.apk -[T2]-> work/v101/SettingsProvider.apk
SYSTEM:    build/apply_system_defaults.py (extended, §5.4) ... --settingsprovider work/v101/SettingsProvider.apk \
             --release-version 1.0.1
PACKAGE:   build/package_checkpoint.py (existing) -> out/Q5-Gen7-Lithium7-v1.0.1.zip + manifests/release-v1.0.1.json
```

### 5.4 `build/apply_system_defaults.py` edits (minimal, match existing style)

1. New optional arg: `--settingsprovider PATH`. When present: verify PATH parses via
   `patch_arsc_values.py`-imported reader with `def_wifi_sleep_policy == 0`; then `put()` it to
   `/priv-app/SettingsProvider/SettingsProvider.apk` (SELinux label + readback sha check, as
   existing `put()` does). Add to `changes` manifest.
2. build.prop block (place immediately after the existing `persist.af.audio_patch_fm` block),
   SAME regex style (match ≤1 existing line else append):
   ```
   ro.radio.noril=true
   ```
3. framework-res arsc guard: after `put(a.branding/'framework-res.apk', ...)` succeeds, read
   the written file back OUT of the image via debugfs `dump`, parse with the imported reader,
   assert `config_voice_capable == false`. (Catches pipeline-order regressions where branding
   accidentally runs on an unpatched donor.)
4. Do NOT remove or alter any telephony package; do NOT prune telephony feature XMLs;
   do NOT touch `persist.radio.multisim.config` or `keyguard.no_require_sim` this release.
5. Manifests: write `manifests/audio-hygiene-v1.0.1.json`-style pins: patched
   framework-res.apk sha, patched SettingsProvider.apk sha (both recorded in the output
   manifest `changes` as today).

### 5.5 New host test — `build/test_kpd_filter.py` (runs BEFORE flash, in 82 chain)

Pattern: same extraction technique as `build/d22_host_tests` / `build/test_touch_key_protocol.py`
(awk-extract the REAL patched functions from the tree into a harness; mock input_report_key,
kpd_get_keymap_state, schedule_delayed_work with a host-controlled fake clock):
- G1: one 250 ms press of hw slot 0 → exactly one `KEY_VOLUMEUP` down then up; no duplicates.
- G2: an 80 ms pulse on slot 0 → ZERO events; drop counter increments.
- G3: 60 s of 2.9 Hz slot-01 toggling → ZERO events; drops == observed glitches.
- G4: press held across one suspend (work cancelled) + resume re-sync → no stuck key, single
  release/pair delivered after resume per state change rules.
- G5: two quick distinct presses (>150 ms apart each) → both delivered, correct order.
- G6: kpd_aee_handler invoked with the filtered event stream (both-key hold 5–15 s path intact).

### 5.6 Files Forge must NOT touch in this milestone

- Anything under `drivers/input/touchscreen/` and `drivers/misc/mediatek/accdet/` (I1, I2).
- Audio HAL binaries/props beyond the single build.prop additive line (`persist.af.audio_patch_fm=1` stays).
- `evdev.c` (input core) — W2 is the rejected option.
- Connectivity tree outside the single gl_kal.c hunk — no WOWLAN this release.
- `.reference-lithium/priv-app/*` telephony APKs — no removals.
- Ramdisk scripts (`patch_usb_boot.py` outputs) — D42-R2 USB behavior stands.
- q5_defconfig — zero drift for m5 (asserted).

---

## 6. Observability & deployment

- **Field attribution prints retained**: `[fchr_key_int_handler]` xlog line (pmic_mt6323.c),
  kpd press/release printk, and the new rate-limited glitch-drop counter
  (`kpd: dropped N glitch bits`). After d43, an idle dmesg should show ~0 of all three.
- **Module params** for field tuning without rebuild: `kpd_glitch_ms` (default 150),
  `kpd_show_scan` (default 0), plus pre-existing `kpd_show_hw_keycode`/`kpd_show_register`.
- **Metrics gates** (Karen): `/sys/kernel/debug/wakeup_sources` + batterystats deltas, 60-min
  screen-off soak; thresholds in §7.
- **Deployment**: same TWRP clean-install path as v1.0.0 (boot/system/logo only; no
  userdata/calibration/NVRAM writes; bounded readbacks on all three), scatter asserts
  unchanged. Settings-seed changes (S1) apply at first boot of the clean install, matching
  v1.0.0's delivery model. Rollback = reflash v1.0.0 (D42-R3 boot + v1.0.0 system).

---

## 7. Validation specification (Karen baseline — expand freely)

### 7.1 Pre-flash gates (offline, Forge runs; Karen may replay)
- G-B1: `build/82_kernel_delta_power_audio.sh` completes; all D43/D44 DELTA asserts pass;
  d39 touch-key protocol gate passes; defconfig diff vs d42 build empty.
- G-B2: `build/test_kpd_filter.py` G1–G6 pass.
- G-B3: `patch_arsc_values.py` self-verification passes for T1 and T2; manifests emitted.
- G-B4: `apply_system_defaults.py` output: build.prop contains `ro.radio.noril=true` and
  unchanged `persist.af.audio_patch_fm=1`/`qemu.hw.mainkeys=0`; framework-res.apk read back
  from the image parses `config_voice_capable=false`; SettingsProvider.apk read back parses
  `def_wifi_sleep_policy=0`; two read-only e2fsck passes clean; file-count/content diff vs
  v1.0.0 manifest equals exactly the intended change set (no collateral edits).
- G-B5: `99_verify.sh`-style tuple diff (if replayed for v1.0.1 image) shows only intended paths.

### 7.2 Functional gates (device, post clean-install)
| Gate | Procedure (adb unless noted) | Pass |
|---|---|---|
| V0 (attribution, optional on D42-R3 pre-flash) | `dmesg \| grep -c fchr_key_int_handler` vs `grep -c "kpd: register"`, 10 min screen-off | documents which WS1 generator dominated; informational |
| V1 power soak | charge ≥90 %, WiFi associated, screen off, 60 min idle; then `dumpsys batterystats --charged` | uptime/realtime ≤ 0.35 (baseline was 0.66); `event0*` kernel wakelocks absent or ≤ 60 s held; `WLAN AHB ISR` ≤ 4 min held/hour; `WLAN TX THREAD` ≤ 1.5 min/h |
| V2 overnight (user) | nightstand idle 8 h+ from known charge | battery ≥ ~90 % remaining (acceptance; replaces the “fully dead” defect) |
| V3 volume keys (WS2 happy path) | no media playing, screen ON: `input keyevent KEY_VOLUME_UP/DOWN` (or physical), then `dumpsys audio`/media-volume readout for streams 3 and 2 | STREAM_MUSIC index changes; STREAM_RING index unchanged — for injected AND physical keys |
| V4 volume keys while playing music (screen ON and screen OFF) | start playback (Music or test WAV), screen off, physical VOL± | media stream index changes; playback uninterrupted; I9 holds |
| V5 FM regression | Lineage FMRadio, wired headset | audible station as before; VOL± adjust; pause/resume OK (I3) |
| V6 recorder regression | record ~10 s, play back | capture nonzero, playback audible (I4) |
| V7 speaker/headphones regression | speaker playback; plug headset; unplug during playback | correct routing; unplug pauses, Play resumes on speaker (I2) |
| V8 touch/Home/bezel regression | tap swipe; bezel single-tap Home; double-tap Back; hold Recents; navbar on/off persistence | all pass as v1.0.0 (I1) |
| V9 WiFi regression | toggle WiFi; associate; ping 3×; HTTPS GET example.com 200 | pass (I6) |
| V10 power key / suspend cycles | 10× screen off/on with 15 s off intervals | no wedged wakelock, no input loss; touch alive after wake (I10, I1) |
| V11 USB regression | MTP+ADB connect; 4 KiB round-trip sha match (Windows WPD + adb) | pass (I5) |
| V12 settings default | fresh boot WITHOUT any user action: `settings get global wifi_sleep_policy` | `0` |
| V13 ril stays off | `getprop ro.radio.noril` → `true`; `getprop init.svc.ril-daemon` → empty/stopped; no modem log churn | pass |
| V14 key hold UX | phys VOL± long-hold 2 s on Home screen | media volume steps repeatedly via framework long-press handling (framework-side behavior; no driver key repeat added) |

### 7.3 Failure/abuse cases to include
- Rapid VOL± taps (10 taps in 3 s): media volume follows with ≤150 ms lag per tap; a lost
  press below 150 ms is acceptable per design (documented), but zero *phantom* presses allowed.
- 60-min soak WITH music playing screen-off: device must NOT deep-sleep (audio holds it),
  volume keys must work throughout, no kernel warnings.
- Suspend during a held volume press: release after wake must not leave a stuck pressed key
  (d43 resume re-sync; covered by host G4 + device spot check).
- Storage/adopted-card untouched; no userdata writes by the deliverable.

---

## 8. Risks, open items, revisit criteria

- **R1 (medium, mitigated)**: If some Q5 unit variant DID wire fchrkey to a real key (contrary to
  all evidence in CURRENT-STATUS/D22), K1/K2 would kill that key input. Mitigation: V3/V4/V8
  device gates; rollback = v1.0.0 images; revisit = restore map + keep PMIC IRQ mask off only.
- **R2 (low)**: 150 ms filter eats a sub-150 ms intentional tap. Chosen per minimum observed
  real-press durations (132–153 ms bezel taps on D39 belonged to the touch path, not kpd; human
  volume presses are longer). Field knob `kpd_glitch_ms` exists; only lower if V14-style gate fails.
- **R3 (low)**: 20 ms WLAN ISR window could drop a pending IST across a tight suspend race;
  consequence is delayed/lost idle packet at worst (retry semantics). Detect via V9 + streaming
  test; revisit = 50 ms, escalate to W4 (WOWLAN) if WLAN hold still > 4 min/h.
- **R4 (info)**: `config_voice_capable=false` hides ringer UI affordances in Settings and any
  voice-only system flows; desired here. Apps querying `isVoiceCapable` (e.g., telephony utils)
  will see false — correct for a modemless music player.
- **R5 (info)**: S1 seeds only clean installs; dev units keep Hera's live `settings put` value
  (already 0) — consistent either way.
- **R6 (accepted)**: kpd IRQ/tasklet churn at ~3 Hz may persist if the storm is matrix-electric
  (filter kills events, not IRQs) — expected cost ≪1 % CPU, non-waking; accepted.
- **Open (future)**: W4 WOWLAN + firmware PS; `pmicAuxadc` and `EINT` wakelocks (~2 min
  combined/18 h) judged noise-floor, no action; optional telephony-package diet for a later
  hygiene release (V3 as hygiene only — never as the WS2 lever).

## 9. Acceptance criteria (release gate v1.0.1)

1. All pre-flash gates G-B1..G-B5 pass; manifests sha-pinned.
2. Device gates V1 (soak thresholds), V3, V4, V5, V7, V8, V9, V12, V13 pass in ONE session on
   the clean-installed v1.0.1; V2 reported by user within 48 h.
3. No regression vs FUNCTIONAL-AUDIT table (its "Result / remaining validation" column items
   previously verified remain verified).
4. Release manifest `manifests/release-v1.0.1.json` records: boot d43 sha, system image sha,
   both arsc manifests, build.prop diff = exactly the added lines relative to v1.0.0
   (`ro.radio.noril=true` plus the release-version properties, per the existing versioning rule).

## 10. ADR index

- **ADR-m5-WS1**: §2 — targeted source-kill (K1/K2) + bounded glitch filter (K3) + WLAN ISR
  window (K4) + baked wifi_sleep_policy=0 (S1); rejected W2 input-core bound, W3 config-only,
  W4 WOWLAN (deferred).
- **ADR-m5-WS2**: §3 — framework-res `config_voice_capable=false` via arsc build patch +
  bake `ro.radio.noril=true`; rejected services.jar smali force and telephony package removal.

(End of spec — Final Review Checklist: requirements satisfied ✓; existing functionality
preserved I1–I11 ✓; evidence re-verified from source ✓; alternatives evaluated W1–W4/V1–V3 ✓;
tradeoffs documented ✓; security (no new attack surface; binary-patch self-verification) ✓;
performance (soak thresholds) ✓; observability §6 ✓; testability host+device ✓;
extensibility (patch series + tool reuse) ✓; risks §8 ✓; Forge guidance §5 ✓; Karen plan §7 ✓.)
