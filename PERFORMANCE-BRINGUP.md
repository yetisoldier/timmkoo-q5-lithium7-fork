# Post-release performance and Wi-Fi-only configuration

These changes follow v1.0.0. Its published images/checksums remain immutable.
The live device was updated without formatting data, adopted storage, or app
accounts. The kernel, audio HAL, shared M4U library and codec hooks are unchanged.

## Android runtime

The inherited build.prop had original ART defaults followed by obsolete
"Dalvik" overrides. Effective values were 5m/48m/64m for heap start/growth/max
and `interpret-only` for dex2oat. `q5_runtime_defaults.py` removes those four
duplicates, retaining the original 8m/192m/256m and `speed` values. It rejects
unexpected donor values and is idempotent. These are per-process limits, not
preallocated RAM or extra physical memory.

Applied live and verified after reboot. Apple Music, Plexamp, Audiobookshelf
and Saga were explicitly compiled with `cmd package compile -m speed -f` and
their package dexopt state confirmed `speed`. No app data was cleared.

All three Android animation scales are 0 on the test device at the owner's
request. Apple Music 4.7.2 animated artwork is off and reduced player motion is
on. Plexamp 4.12.4 uses Flat background instead of Ultrablur; high-quality
visualizers were already off. App preferences are userdata, not bundled APK
modifications or defaults for other users.

Two Plexamp first-draw measurements before/after AOT were approximately
1.10/1.10 seconds versus 1.29/1.32 seconds. This small sample does **not** show
a cold-start speedup. Do not advertise a quantified performance gain. Java heap
pressure was not established as the cause of the user's lag.

## Cellular components

There was no resident Phone or Telecom app process to remove. The native
`ril-daemon` nevertheless repeatedly restarted. Its system init definition now
has `disabled`. The boot ramdisk's `ccci_fsd` and `ccci_mdinit` modem helpers also
have `disabled` (D42-R4); their combined pre-change RSS was about 4.8 MiB.
That is not a measured PSS/free-memory gain and no CPU saving is quantified.

`ro.radio.noril=true` makes Android 7 ConnectivityService omit cellular network
types. CarrierText then clears its text on this non-mobile device. The pinned
framework resource table also sets `config_voice_capable` and
`config_sms_capable` false. Only those two boolean values change; IDs, resource
table size, wallpaper and other APK entry contents are retained. The APK is
not rebuilt or re-signed. `build_wifi_only.py` rejects another resource donor.

This does not remove telephony framework JARs or vendor connectivity drivers.
FM, Wi-Fi and Bluetooth share platform components, so deleting all libraries
whose names mention radio would be inappropriate. No modem/NVRAM/calibration
partitions were written. The 16 MiB boot range was read back and matched its
candidate; the kernel and every other ramdisk file are byte-for-byte unchanged.

The live lock screen was visually checked: the No SIM/emergency-only carrier
message is absent. On the final D42-R4 boot, Wi-Fi reconnected automatically
and two external pings passed with no cellular helper processes present.
An earlier boot had AP authentication timeouts; the owner confirmed needing
manual Wi-Fi reconnects before these changes. The later D43 candidate adds
persistent addressing and bounded startup recovery; see [WIFI-BRINGUP.md](WIFI-BRINGUP.md)
for the actual reconnect tests and remaining protocol limitations.
Bluetooth turned ON after the final R4 boot with the helpers absent and was
restored to OFF. The local WAV preview showed playback and an active AudioTrack;
the original audio HAL hash still matched. This was not an audible listening test.
The owner deferred the headphone/FM
regression after this change; audible FM remains unverified for this candidate.

## Apple Music hang

The captured ANR waited in ExoPlayer video-surface setup while multiple MTK AVC
animated-artwork decoders were being created/removed. Restarting media.codec
cleared the stuck vendor component; disabling animated artwork avoided the
trigger. The owner confirmed music was playing and later said Apple Music was
fine. This is an app-specific workaround, not a fix for concurrent vendor OMX
decoding. Sequential hardware AVC checks from v1.0.0 still have their original
scope. Keep the original audio HAL and MEMLOCK hook.

## Optional audiobook clients

- Saga: publisher `gaut3/saga` stable v1.2.0 universal APK, publisher SHA-256
  sidecar verified, package `com.gaut3.saga`, minSdk 24, ARMv7 included. Installed
  as userdata alongside Audiobookshelf and opens to Plex sign-in. Authenticated
  playback has not been verified.
- Requested [Chronicle Epilogue](https://github.com/fabiogermann/chronicle/blob/3503420a77b225df3b8ec7bb737b93df67eccc72/app/build.gradle.kts): inspected Gradle config
  declares minSdk 30 (Android 11); the Q5 runs API 25. Not installed. The older
  `mattttvaughn/chronicle` is a different project and was not substituted.
- Bookcamp: publisher links Google Play (`app.bookcamp.android`). No verified
  compatible APK was obtained or installed. Do not claim support from a listing
  alone or add Google services merely to obtain it.

## Other known issue

An unrelated Settings Notification Drawer screen threw ClassCastException in
`NotificationDrawerQsSettings.onCreate` (PreferenceScreen cast to ListPreference).
It is not an Apple Music crash and remains open. Private diagnostic logs, app
preferences, authentication data and account screenshots are not repository
artifacts.
