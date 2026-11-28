# Hera Brief — v1.0.1 Power & Audio Hygiene (Battery Drain + Volume Keys)

> Author: Hera (diagnosis). Target release: v1.0.1 (patch over released v1.0.0).
> Device: Q5 Gen 7 (Timmkoo Q5) running "Lithium 7 v1.0.0" — Android 7.1.2, kernel 3.10.54,
> build increment `q5gen7.1.0.1`. SoC MT6582 (armeabi-v7a, 32-bit). 2000 mAh battery.
> All evidence below was collected live over wireless adb on 2026-11-26/27.

---

## Workstream 1 — Idle battery drain (device never deep-sleeps)

### Symptom (user-reported)
Device left on a nightstand idle (screen off, nothing playing) went **fully dead** from a
healthy charge. User asked "what drained the battery?"

### Live telemetry that proves it (`dumpsys batterystats --charged`)
Time on battery **18h 0m**, screen OFF **17h 28m (96.7%)**, screen ON only 31m (2.9%).
So this is a pure background drain — the screen was not the cause.

- **Uptime vs realtime:** 11h 49m uptime of 18h 0m realtime ⇒ the CPU was **awake ~12 of 18 h**
  and in deep sleep only ~6 h. A healthy idle device should be asleep ~95%+ of that window.

Kernel wakelocks (the drain, ranked):

| Kernel wakelock | Held | Wakeups |
|---|---|---|
| `event0` = **`mtk-kpd`** (keypad driver) | **6h 59m 54s** | 186,154 |
| `WLAN AHB ISR` (MT662x WiFi) | **4h 48m 02s** | 147,331 |
| `event1` = `ACCDET` (accessory/headphone detect) | 14m 55s | 188,732 |
| `event3` = `mtk-tpd` (touch panel) | 12m 43s | 188,910 |
| `event4` = `mtk-tpd-kpd` | 12m 39s | 188,888 |
| `WLAN TX THREAD` | 12m 25s | 399,574 |
| `pmicAuxadc irq wakelock` | 1m 59s | 35,808 |
| `EINT wakelock` | 1m 00s | 125 |

Also: `Wifi on: 18h 0m (100%)`, `Wifi running: 18h 0m (100%)`.

Input device → event mapping (from `/proc/bus/input/devices`):
`mtk-kpd` → event0 (has a `cpufreq` handler attached), `ACCDET` → event1,
`hwmdata` → event2, `mtk-tpd` → mouse0/event3, `mtk-tpd-kpd` → event4.

### Root-cause hypothesis (MARKED HYPOTHESIS — Bob to confirm against source)
The MediaTek input drivers on this 3.10.54 kernel — **kpd (keypad), tpd (touch panel), accdet
(headphone detect)** — are generating spurious interrupts / holding wakelocks that keep the SoC
out of suspend, and the **MT662x WLAN driver** keeps the WiFi subsystem awake (interrupt storm:
`WLAN AHB ISR` + `WLAN TX THREAD` = ~550k wakeups). `event0` alone is ~3 wakeups/second
continuously for 18 h from a keypad nobody was touching. This is a classic MTK 3.10.x
suspend/EINT/irq-config defect, not an app issue.

### What is NOT the cause (already ruled out)
- **RIL/telephony radio** — Codex already set `ro.radio.noril=true`; the RIL daemon is NOT
  running (`init.svc.ril-daemon` empty). This is not the drain.
- **Apple Music / apps** — total app partial-wakelock time was ~2m56s; Apple Music's own
  contribution was ~5 s. Apps are essentially innocent.
- **Screen** — off 96.7% of the time.

### Mitigation already applied by Hera (NOT the fix — record only)
`settings put global wifi_sleep_policy 0` (was `2` = keep-on-always). This makes WiFi sleep with
the screen off and cuts the WLAN storm symptom, but the driver suspend defects remain. The real
fix must make the drivers suspend correctly, not just hide the radio.

### Decisions Bob must make (with options)
1. **Keypad/tpd/accdet interrupt storms** — fix the drivers' EINT/wakeup config vs. disable the
   unused drivers (the Q5 has physical buttons; is the kpd path even used, or is input handled
   elsewhere?). Name exact files/functions in the 3.10.54 tree.
2. **WLAN suspend** — MT662x proper power-save / suspend (WOWLAN vs. full suspend), and whether
   the WLAN driver needs a `wifi_sleep_policy`-independent suspend path.
3. Which of these are kernel-patchable vs. config-only (e.g. GPIO/EINT wake-source registration).

---

## Workstream 2 — Volume keys control ringtone, not media

### Symptom (user-reported)
"No phone capability, so the volume keys should control MEDIA volume, not ringtone." On this
device the hardware volume keys adjust STREAM_RING (ringtone) instead of STREAM_MUSIC.

### Evidence
- `ro.radio.noril=true` (RIL disabled) — but the FRAMEWORK still presents as a phone.
- `persist.radio.multisim.config=dsds`, `keyguard.no_require_sim=false` still set.
- `ro.telephony.sim.count=0`, no SIM, no modem, no voice capability.

### Root-cause hypothesis (MARKED HYPOTHESIS)
The RIL disable (`noril`) removes the radio, but the Android **framework** still has
`config_voice_capable=true` (AOSP default in
`frameworks/base/core/res/res/values/config.xml`), so `PhoneWindowManager` treats the device as a
phone and routes idle volume keys to the ringer stream. The fix is to make the framework
voice-incapable.

### CONTRADICTION to surface (required determination, not a footnote)
`ro.radio.noril=true` was ALREADY set, yet volume keys STILL control ringtone. This proves the
RIL-level disable is insufficient — the framework-level "voice capable" flag (and/or the
telephony packages) is the actual lever. Bob must determine the exact mechanism and the minimal
change that makes volume keys default to STREAM_MUSIC without breaking audio.

### Decisions Bob must make (with options)
1. `config_voice_capable=false` via resource overlay (RRO) vs. build-config change — which is the
   correct, minimal, non-breaking path for this tree?
2. Whether telephony packages (TeleService/Telecom/TelephonyProvider) must ALSO be removed or
   disabled, or whether the flag alone suffices.
3. Confirm the change does not regress media playback, audio routing, or the FM/recorder paths
   already brought up (see `FM-BRINGUP.md`, `MEDIA-BRINGUP.md`, `CURRENT-STATUS.md`).

---

## Corroborating evidence for WS2 (Apple Music "won't play" — same root cause)
User also reported "Apple Music won't play." Logcat during a play attempt showed
`AudioService: Stream muted, skip playback` — the media stream was muted (speaker music volume
`volume_music_speaker=1` of 15), so playback was silently skipped. Confirmed: raising the media
volume made Apple Music play normally. This is the SAME phantom-telephony defect as WS2 — the
hardware volume keys drive STREAM_RING instead of STREAM_MUSIC, so the media stream was left at
minimum/muted and users could not raise it. The WS2 fix (volume keys → media) also permanently
prevents this "muted media / silent playback" failure mode. NOT a DRM/GMS/version/TLS issue —
explicitly ruled out.

## Where the code lives (for Bob's reconnaissance)
- Kernel 3.10.54: `.reference-kernel-3.10.54/` (drivers under `drivers/input/keyboard/`,
  `drivers/input/touchscreen/mediatek/`, `drivers/misc/mediatek/` accdet, WLAN under
  `drivers/misc/mediatek/connectivity/` or `drivers/net/wireless/`).
- Patches applied over the donor firmware: `patches/`.
- Build pipeline: `build/`, `manifests/`.
- Donor firmware: `donors/` (Mint KK base + Lithium 7).
- Current live status and prior bring-up notes: `CURRENT-STATUS.md`, `FUNCTIONAL-AUDIT.md`,
  `HANDOFF.md`, `FM-BRINGUP.md`, `MEDIA-BRINGUP.md`.
