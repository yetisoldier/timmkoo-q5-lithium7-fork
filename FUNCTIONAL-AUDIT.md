# Q5 Mint-style MT6582 functional audit — 2026-11-26

This complements CURRENT-STATUS.md; it is not a claim that every advertised
function has been physically validated. The user authorized autonomous flashing
and asked to omit the camera absent positive hardware evidence.

## Fixes and additions

* Open Camera removed from system and userdata. Purchase-page evidence says
  “no camera”; Mint has an empty sensor list and Android detects zero cameras.
  The front dot alone does not establish a fitted camera. No further speculative
  sensor probing is required. D42 diagnostics remain default-off.
* Xposed Installer removed after repeated repository/database receiver crashes.
  No active modules were found, and the hardware/Home fixes use native code.
  Inactive framework files remain; this is not a full Xposed framework uninstall.
* Jelly and HTMLViewer remain removed; BROWSABLE HTTPS has zero activity handlers.
  WebView remains for apps. Browser removal does not restrict networking inside
  other apps or prevent later sideloading.
* Settings > Buttons > Show navigation buttons exposes the native visibility
  setting. Default ON; OFF persists through reboot. Physical Home assignments
  remain editable in either state. Settings' existing Navigation screen also
  exposes the ROM's navigation-bar controls.
* Camera, gyro and compass feature declarations pruned individually from XML,
  preserving unrelated features/permissions. The sensor HAL has only accelerometer,
  light and proximity entries; it has no gyro or compass.
* Audio Recorder 3.5.23 added. The user recorded a spoken message and confirmed
  recording and playback work properly. A separate speaker-to-microphone tone
  test captured both expected frequencies while the screen was asleep. These
  checks do not establish microphone calibration. User recordings are preserved;
  private audit audio is not published.
* FM receiver replaced with the Android 7 Lineage app and corrected Lithium JNI.
  The HAL's disabled audio-patch setting was an additional silent-audio cause.
  The user confirmed hearing 93.7 through wired headphones with software
  rendering and the HAL property enabled. Volume-key and pause/resume checks
  pass. See [FM-BRINGUP.md](FM-BRINGUP.md).
* 36 device-protected app folders retained obsolete UIDs from earlier installs.
  Repaired only files owned by each folder's old UID/GID, without traversing
  symlinks; credential-protected owners matched. This is a live-data repair,
  not something to bake into the system image. Audiobookshelf's blank launch
  screen disappeared afterward. Never ship a blanket recursive chown of /data.
* Embedded WebView upgraded from 65 to the pinned Lineage ARM build
  119.0.6045.134. With 65, Audiobookshelf's Connect button had a two-pixel height
  and the navigation drawer collapsed. With 119, both render normally and the
  server-address dialog opens. Server authentication awaits the user's check;
  no credentials were entered or collected by the audit. This update adds no
  browser launcher. Version 119 is a compatibility improvement, not a claim of
  current Chromium security support.

## Audiobookshelf server connection

Open Audiobookshelf, tap Connect, enter the existing server's full base URL
(including http:// or https:// and its port when needed), then Submit. Account
sign-in follows server connection. The placeholder IP address is an example,
not the user's server. Neither a separate browser nor Xposed is needed.

The APK is currently a userdata test install, not bundled in the system image.
The embedded WebView is a system component shared with other apps. Its source
commit, LFS object, size and SHA-256 are pinned in `manifests/webview.json`;
`build/fetch_webview.py` verifies the source pointer and downloaded object.
`apply_system_defaults.py --webview /path/to/webview.apk` verifies and installs
that exact APK. Live Package Manager and WebViewFactory logs identify version
119, and the corrected connection-screen layout was checked after reboot.

## Historical Mint FM attempt: superseded by Lineage receiver

The following records the first-stage control-path work. Its app is superseded:
the user found a volume-key crash and no audio. See FM-BRINGUP.md for the new
default, which also requires persist.af.audio_patch_fm=1.

1. The ramdisk created /dev/fm with static major 193; the actual driver registered
   dynamic major 232. D42-R1 removes that mknod/chmod/chown block and leaves
   ueventd's media:media 0660 rule. The node now matches sysfs 232:0.
2. Mint JNI unconditionally registers receiver and transmitter native classes.
   A declaration-only transmitter companion permits registration; there is no
   transmitter UI or transmitter call in this adaptation.
3. The Mint backend encoded ioctl sizes as four bytes. The new backend changes
   31 reviewed request literals to values compiled with the pinned ARM32 kernel
   header/config. Includes six-byte POWERUP and two-byte GETCHIPID; x86 host
   structure sizes must not be substituted. Manifest pins both donor and result.
4. The privileged app requests ACCESS_FM_RADIO, granting media GID 1013. It opens
   the 0660 node without a world-writable permission workaround.

The exact builder output c856cbd57b62e4b2126b29afe15f4422d6795fcbb134ac82d7738461965da69e
was installed and tested: open true; chip 0x6627; RX power-up at 87.5 MHz true;
RSSI -111 without an antenna; RX power-down true. Headphone-antenna reception,
station scan and actual FM audio remain physical tests. Do not interpret a
successful power-up as a successful station-listening test.

Rebuild with Java/git, the pinned smali tools, and extracted Mint donors:

```sh
python3 build/build_mint_fm.py --donors /path/to/mint-fm-files \
  --tools /path/to/smali-jars --keystore /private/development.jks \
  --out out/fm-nougat
python3 build/patch_fm_boot_node.py /path/to/boot-d42.img out/boot-d42-r1.img
python3 build/patch_usb_boot.py out/boot-d42-r1.img out/boot-d42-r2.img
```

The local signing key stays outside the repo. A rebuilt APK's signature/hash
depends on that key and signing timestamp; donor contents/native edits are pinned.

## USB ramdisk correction (D42-R2)

The inherited MT6582 USB init combined normal MTP with a legacy mass-storage /
CD-ROM function and Lenovo IDs. Selecting Transfer files reverted to ADB.
R2 changes only the mtp and mtp,adb actions to pure functions, using the standard
Android 18d1:4ee1/4ee2 IDs. Other USB actions and kernel contents are preserved.
The full 16 MiB boot readback matched
`4ce26b2fb79de4acfef66bb8f2d02e49b38b39444827c2038bcf74489261f1b5`.
After reboot, selecting Transfer files gives config/state/functions mtp,adb,
configured true and data-unlocked true. Windows WPD and ADB both work. Charging-only
remains available; this does not force USB data access on every connection.

The system-defaults builder also completed on a D39 snapshot copy with the
new apps, feature cleanup and F7 framework. A second read-only e2fsck passed.
This validates the offline transformation, not a factory-reset boot.

## Audit results and boundaries

| Area | Result / remaining validation |
|---|---|
| Touch/Home/speaker/headphones | Previously confirmed by user. Native Home policy regression passes after latest system cleanup; original audio HAL retained. |
| Internal and adopted storage | Independent 4 KiB fixtures wrote/read correctly after reboot; adopted UUID remained stable. Fixtures removed. Adopted-media keys live in userdata; do not erase them casually. |
| Wi-Fi/network | Ping succeeds without the earlier jump-label panic. Java HTTPS with standard certificate validation returned HTTP 200 from example.com and letsencrypt.org. |
| Bluetooth | Real controller enabled to ON, accepted discovery, then restored OFF. Pairing, A2DP audio, reconnect and headset buttons need a physical headset. |
| Audiobookshelf | UID repair restored launch; WebView 119 fixes collapsed controls. Server-address dialog opens normally. Server sign-in/streaming/offline books await user account checks. |
| Plexamp | Welcome and built-in email/password sign-in screens render. The browser is optional for that route. Account/server playback untested. |
| Apple Music | Library/trial screen renders. Account playback/DRM untested. |
| Video | Hardware H.264 720p baseline/High Profile renders. 30-second run and repeated playback pass; private cleanup returns locked memory to zero. 1080p test renders through software fallback. See MEDIA-BRINGUP.md for evidence and limits. |
| USB | D42-R2 pure MTP+ADB selected from the USB chooser survives configuration. Windows detects WPD Lithium and Android ADB simultaneously. A 4 KiB file copied PC > device > PC through Windows Shell/MTP has matching SHA-256 throughout; fixture removed. |
| Battery/charging | Full battery, approximately 4.2V while USB-powered. Low-SOC charging, discharge lifetime and unplugged deep sleep remain unverified. |
| Other sensors | HAL entries exist but no recent sensor samples. Physical rotation/light/proximity behavior is not proven; no speculative driver additions made. |
| Platform | Android 7.1.2; embedded WebView updated to 119. These app launch tests do not establish every current service's compatibility or supported security maintenance. |

No camera/browser app, app credentials, private recordings, product-page PDF,
userdata or adopted-storage keys belong in the public checkpoint/repository.
Clean-install/factory-reset validation is still distinct from testing updates
on this development device.

Audiobookshelf, Plexamp and Apple Music are separate userdata test installs, not
bundled default system apps. No account credentials were entered or extracted.

## Official v1.0.0 clean-install follow-up

The separate clean-install pass is now complete through a recovery write of
boot/system/logo, matching bounded readbacks and full internal-data/cache
formats. Android booted from fresh app state as Q5 Gen 7 Lithium 7 v1.0.0.
All 37 generated system files matched. The prior retained-package/UID warnings
were absent, and the owner heard FM after the reset with the same software
rendering/property combination. See the release manifest for final results.
The remaining Bluetooth, battery, sensor, FM-extra and account-playback limits
still apply.
