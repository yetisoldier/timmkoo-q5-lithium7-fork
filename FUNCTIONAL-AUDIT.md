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
* Audio Recorder 3.5.23 added. An actual 22.56-second Ogg recording decoded
  successfully, using BUILTIN_MIC. This proves audio capture, not intelligibility
  or microphone calibration. Private test recordings are not published.
* Mint FM receiver restored with isolated native libraries and a minimal vendor
  API shim. The stock app/JNI cannot run unchanged on Nougat. See below.
* 36 device-protected app folders retained obsolete UIDs from earlier installs.
  Repaired only files owned by each folder's old UID/GID, without traversing
  symlinks; credential-protected owners matched. This is a live-data repair,
  not something to bake into the system image. Audiobookshelf's blank launch
  screen disappeared afterward. Never ship a blanket recursive chown of /data.

## FM: independent failures and evidence

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
| Audiobookshelf | Normal empty-library / connect-to-server screen after UID repair. Server streaming/offline books require user server/account. |
| Plexamp | Welcome screen renders. Account/server playback untested. |
| Apple Music | Library/trial screen renders. Account playback/DRM untested. |
| Video | H.264 1920x1080 test renders; currently uses software decoder. Sustained performance/hardware decode under investigation. |
| USB | D42-R2 pure MTP+ADB selected from the USB chooser survives configuration. Windows detects WPD Lithium and Android ADB simultaneously. A 4 KiB file copied PC > device > PC through Windows Shell/MTP has matching SHA-256 throughout; fixture removed. |
| Battery/charging | Full battery, approximately 4.2V while USB-powered. Low-SOC charging, discharge lifetime and unplugged deep sleep remain unverified. |
| Other sensors | HAL entries exist but no recent sensor samples. Physical rotation/light/proximity behavior is not proven; no speculative driver additions made. |
| Platform | Android 7.1.2 and WebView 65 are old. These app launch tests do not establish current app/service compatibility or supported security maintenance. |

No camera/browser app, app credentials, private recordings, product-page PDF,
userdata or adopted-storage keys belong in the public checkpoint/repository.
Clean-install/factory-reset validation is still distinct from testing updates
on this development device.
