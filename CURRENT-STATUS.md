# Q5 Lithium 7 bring-up — 2026-11-26

The user-confirmed working kernel is **D39**, on top of the published D33 chain.
Touch, physical Home, speaker and headphone playback work. Native Home
shortcuts and browser removal are installed. **Camera omitted per product evidence; no fitted sensor is confirmed.**
This is a development build, not a fully functional release.

The current installed boot is **D42-R3** (D42 kernel, corrected FM, USB and codec startup ramdisk): D39 plus default-off camera
diagnostics (D40–D42). D42 boots, passes the native Home policy regression,
and retains mainkeys=0 and zero browser handlers. The Settings visibility switch
uses secure navigation_bar_visible independently of this property. Keep D39 as the user-confirmed
physical touch/Home/audio baseline; later physical confirmation is still useful.

## Verified on the connected 2026 Q5

| Function | Evidence / limit |
|---|---|
| Touch | User confirmed physical touch. InputReader records physical down/move/up events. GSL register `0xb0` reads `0x5a5a5a5a`. A screen-off/wake cycle retained that signature. |
| Physical Home | D37 restored the bezel report using Mint MS1_0110 firmware. D39 excludes bezel contacts from touchscreen reports; the user confirmed repeated quick taps go Home without opening Recents. |
| Home shortcuts | Native framework policy: single tap Home, double-tap Back (new action 13), hold Recents (action 2). Tested with injected Home key events after reboot: Sound Settings → Settings, long press → Recents, separate single tap → launcher. Physical gesture confirmation is still useful. |
| Speaker | User heard clear playback of the original 25-second test track with D36 and the **original Lithium HAL**, at volume 5/15. |
| Headphone/speaker switching | Headphones were tested; user reports unplugging pauses the player, and pressing Play resumes through the speaker. The app's pause must not be mistaken for routing failure. |
| On-screen navigation | Visible by default. Settings > Buttons > Show navigation buttons works, including persistence of OFF across reboot. F7 exposes the native switch without an unsupported hardware-key-disabler capability. Home assignments remain available. |
| Gnome branding | User-supplied artwork encoded at 480×800; boot layers 0/38 replaced and other 37 logo layers verified byte-identical. Static Android boot display and all seven framework default wallpaper drawables use the same image. Home-screen screenshot verified. |
| Browsers | Jelly and HTMLViewer APKs/directories removed from `/system`, including after reboot. No BROWSABLE https VIEW activities remain. WebView is retained for apps. This is browser removal, not comprehensive parental filtering. |
| Network | D38 disables unsafe ARM jump labels while retaining read-only kernel text. Ping no longer crashes the kernel; repeated three-packet pings pass on D39. |
| Storage | Internal emulated storage mounts. The external card is now adopted, UUID c9c65e1c-f5f0-48f2-a93d-395cbdc5f49e, and remained mounted across reboot. Preserve its key in userdata; do not format or forget it. |
| Boot / ADB | D34–D39 booted through Android. USB ADB and root adbd work. Windows ADB server sometimes needs restarting after reboot/root. |
| Battery | Reports 100%, approximately 4.2V, USB powered. This session does not prove charging across a low-SOC interval. |

The original synthesized 25-second test track is now in internal
`/sdcard/Music/Q5_Blue_Gnome_Speaker_Test.wav` and scanned into the media
provider. The older public-volume path is obsolete. Generate the song with
`build/make_test_song.py`.

See [MEDIA-BRINGUP.md](MEDIA-BRINGUP.md) for restored hardware H.264 playback.
See [FM-BRINGUP.md](FM-BRINGUP.md) for the current Android 7 FM app, corrected
JNI, required audio-patch property and listening-test boundary.
See [FUNCTIONAL-AUDIT.md](FUNCTIONAL-AUDIT.md) for FM/recorder additions,
app-data repair, navigation controls and remaining physical validation.

## Why touch was dead (D34)

The handoff confused two adapter implementations. In the pinned kernel,
`include/linux/i2c.h` defines `USE_I2C_MTK_EXT`, and `COMPATIBLE_WITH_AOSP` is
commented out in `drivers/misc/mediatek/i2c/mt6582/i2c.c`. Therefore
`mt_i2c_algorithm.master_xfer` is **`mtk_i2c_transfer`**, not
`standard_i2c_transfer`. The automatic virtual-to-coherent staging code is in
the inactive standard path.

D30 supplied `virt_to_phys(kmalloc(...))` without DMA mapping or cache
maintenance. On this noncoherent ARM target, a completed transfer did not
establish that the controller received the bytes staged by the CPU. D34 uses
`dma_alloc_coherent`/`dma_free_coherent` for both long writes and reads, using
the same NULL-device allocation convention as the adapter. Short FIFO
transfers are unchanged. No firmware selection change was required to restore
screen touch.

## Why the speaker was silent (D36)

Mint's actual `aw87559_i2c_probe` at `0xc055804c` explicitly puts **GPIO8** in
mode 0/output/high, then waits **50ms** before reading ID. The D13 port omitted
that enable. On D35, enabling that pin and rebinding **2-0058** immediately
produced a verified chip ID **0x5a**. The earlier design's statement that no
enable-pin evidence existed is superseded by this disassembly and live test.

There was another independent missing connection: `SET_SPEAKER_ON/OFF` in
`AudDrv_Kernel.c` invokes `Sound_Speaker_Turnon/off`. Those board functions
were empty a106 stubs; implementing `Audio_eamp_command` alone did not connect
the normal speaker ioctl path. Mint connects these hooks to its AW87559
on/off routines. D36 connects the hooks, initializes the amplifier muted at
probe, and uses Mint's register values (not the sibling Tempo tuning values):
registers 0x02=0x1a, 0x07=0x0f, 0x09=0x08.

D36 also corrects the AMP_Control register-write argument offsets and removes
the invented interpretation of Android NORMAL mode (0) as an amp-mute command.
Mint's mode hook is a no-op; explicit speaker open/close commands control power.

**No audio HAL, policy, or effects files were changed in this session.** The
installed HAL hashes to `a7cc2dbe2cc2b8fd9c06d86f6f9479670a16e66bacc8941660ac81d6a370463e`.
The published M1a report documents a built system image, but its T-ROM HAL was
not installed on the connected device at handoff. Preserve the now-tested
original-HAL baseline before applying older M1a audio substitutions.

## Home and network follow-up (D37–D39)

Mint additionally contains MS1_0110 and MS1_2038 touch firmware/config arrays
absent from D17. D37 adds both and Mint's selector logic, including the 0xfc
byte-2 == 0x83 route and initialization-guard cleanup. This unit selects table
index 5 (MS1_0110), fingerprint `0xff807e01`, chip register `0xb4820101`.

D39 prevents a bezel contact from also appearing as an out-of-range screen
touch, eliminating duplicate Android Home synthesis. Real captured Home
down/up pairs were approximately 132–153ms. The extracted-source protocol test
with ASan/UBSan fails on D38's duplicate reporting and passes on D39.

D38 fixes a separate panic in `patch_text` → `static_key_slow_inc` →
`net_enable_timestamp`, recovered from encrypted expdb diagnostics after ping.
Disable CONFIG_JUMP_LABEL; keep CONFIG_DEBUG_RODATA. Do not solve this by
making the entire kernel text writable.

## Camera investigation and remaining work

- The user reports a front lens/opening above the screen, no rear lens, and
  supplied an online product image matching the Mint-style case. Taking a
  photo on OEM/Mint has never been demonstrated on this unit.
- Purchase listing supplied by the user:
  https://www.aliexpress.us/item/3256810146190263.html . On November 26 the
  user checked it and reported no reference to a camera. Automated access to
  the seller page failed, so that observation has not been independently
  verified against the complete specifications. Combined with the empty Mint
  sensor list and unsuccessful probes, camera hardware is **unconfirmed**.
  Do not label an advertised/previously working camera as regressed, and do
  not identify the opening as a microphone, LED or dummy lens without evidence.
- The user then supplied a 19-page PDF print of that exact purchase page
  (`q5add.pdf`, printed November 26, 2026). Visual review of page 2 confirms
  an October 19 mint-green review, marked "Review for this item", explicitly
  says "no camera". The page also warns that reviews can be aggregated across
  sellers/similar items, so this is corroboration rather than proof of this
  individual unit's internals. Page 3's specifications list a Photo Viewer,
  Voice Recorder and video playback, with no camera feature. Product images
  on pages 4–15 do not advertise camera capture. A camera is therefore **likely
  not fitted**, and it should no longer be treated as a confirmed firmware
  regression or assumed release blocker. Reopen capture bring-up only with
  positive camera hardware/operation evidence. The PDF remains local because
  the print includes account/header information; it is not committed.
- Mint is the user's only known-good overall firmware. Its local reference is
  Sendew/TIMMKOO-Q5-Mint-Custom-ROM v1.0, not verified OEM firmware.
- **Hyn_device is Hynitron CST touch**, registered by `cst2xx_ts_init` at
  I2C0:0x5a. It is not evidence for a Hynix camera. HI253/HI704 use 7-bit
  addresses 0x20/0x30, not 0x5a. No confirmed sensor model exists yet.
- Mint libcameracustom.so has a zero-initialized 56-byte SensorList terminator;
  its kernel exposes no camera SensorInit functions. The ES WV5.02, TM WV3.27,
  and offline Q5D WV3.28 references also have empty sensor lists. **The Q5D
  archive targets MT6580, so it has not been flashed to this MT6582 unit.**
- The installed Lithium userspace lists six unrelated a106 sensors; kernel
  slots do not match. A complete camera-service restart captured via `/dev/kmsg`
  nevertheless shows actual HI253/HI704 probes on both logical slots, all ID 0
  with I2C1 ACK errors. This is failure under the current power/bus setup,
  not proof that the hardware is absent or defective.
- Open Camera 1.56.2 is installed as a system app, independently of Gallery2;
  Mint Gallery2 would replace a newer Nougat Gallery package. Open Camera
  launches, but reports zero cameras. See `manifests/optional-apps.json`.
- Still unverified: Bluetooth playback, low-SOC charging trend, prolonged
  suspend/resume, full camera capture. Prior calibration/NVRAM were retained.

## Artifacts and reproduction

Workspace diagnostics: `../diagnostics/2026-11-26/` (not tracked).

| Artifact | SHA-256 |
|---|---|
| Handoff boot partition backup, 16MiB | `856ea5282b32e0f66a88cc46c1f29fb58f0475b392407dc340e36d5a285eb999` |
| Recovery partition backup, 16MiB | `265401b7a7a2373746e8aad5a8a5288aea56df8b0fc65636dfed28496186bcb2` |
| D34 boot, first working touch | `293cbcefcb6047f77ed432981bb5c0842e2b33bd57ab53246a15054a5a20635f` |
| D35 boot, key-release repair | `09f3d4656a819e50f29b3fd850dbe7617737adad1513df24b12f50f8e18ed89c` |
| D36 boot, working touch + speaker | `0eedb2d50181cd5317f33bf595e855b1c435fd89f2329b330d7de06341a2994a` |
| D37 boot, Mint touch selector/Home | `1e60436f0b5b511434c8729e7778294241e13b052765ad055844a4134d1910c1` |
| D38 boot, network panic fix | `9e29ba5fc47a93e29b3e59c956082d41f3fbc675138eeb8daa6d80300adbc769` |
| D39 boot, paired bezel-only key events | `215f4ea7f4bef9237377adc00f5b2142f0908f9f9cee3f5244830881849f26fe` |
| D40 boot, front-slot camera diagnostic | `a37c7f7c4b3b4e6deec8d6aba0c896d115b642f11dce551ce23b24219e6a8fbd` |
| D41 boot, both logical camera slots | `366de56f7890f83393b0b78b57b87ba051f3af32018e8ac56b836910e0dd25eb` |
| D42 boot, all three I2C adapters | `5b9b297bce3cef9f21830a178f2a19f30f50a49a17822016a526aa6d0ccd0104` |
| Live system snapshot after Home/browser/Lawnfeed changes | `4ae666c5ea2ee6f445fc95258048f2d900bebb501b54b73f3d50b57d69cb0450` |

Every boot write was limited to `/dev/bootimg`, followed by a complete 16MiB
readback and SHA-256 match. D40's initial streaming hash did not complete;
its bounded full readback was verified immediately after reboot. D41/D42
readbacks matched before reboot. LOGO was backed up and separately
read back after installation. No preloader, partition table, NVRAM, calibration,
or recovery partition was written.

Pinned source: `heyrudra/android_kernel_micromax_a106` at
`96e535524cb10b9e3d9ea2d0e69599726605ae8e`, bundled arm-eabi GCC 4.8.
The active Linux source checkout is `/root/q5-kernel-reference` in local WSL
Ubuntu; build output is `/root/q5-build-d34` (reused for incremental builds).

`build/kernel-d39.series` records the exact patch order. An isolated clean build
can be prepared without resetting an existing checkout:

```bash
Q5_BUILD_WORK=/root/q5-repro-d39 bash build/78_kernel_delta_bezel_keys.sh \
    /root/q5-kernel-reference /path/to/boot-before.img
```

The helper archives the pinned source and applies every patch in order, then
builds and repacks a boot image preserving the supplied header/ramdisk. It
never flashes. Its fixed build stamp differs from the initial exploratory
device-tested image, so compare contents/protocol gates rather than expecting
the initial binary hash from a new build.

Branding is deterministic and derives from `assets/branding/blue-gnome-dj.png`:

```bash
python3 build/build_branding.py --source assets/branding/blue-gnome-dj.png \
  --reference-logo /path/to/logo-before.bin \
  --framework /path/to/framework-res-before.apk --out out/branding
```

Only the default wallpaper entries in framework-res.apk change. Manifest,
resource table and other entry contents are verified unchanged; the system
APK's original certificate metadata is retained, not re-signed. The device
booted with the changed framework resource package and displayed the gnome.

## Native Home shortcuts and system defaults

`patches/framework/F1` adds Back as action **13**, preserving the existing IDs
(CMParts reserves 12 for screenshot). It enables Home assignments even while
the navbar is visible, and supplies factory defaults hold=2/double-tap=13.
F2/F3 add Back to the settings enum/list and correct its old upper-bound check.
F4/F5 extend only the Home-action validators. **CMSettingsProvider contains its
own copy of CMSettings**, so patching the platform JAR alone is insufficient.
The on-device selections are also persisted as 2/13. A single tap waits for
Android's normal double-tap timeout before going Home.

Build from the original Lithium framework files with Java, git and Python 3:

```bash
python3 build/build_home_gestures.py --inputs /path/to/original-framework-files \
  --out out/home-gestures --tools /path/to/smali-jars
```

Required donors: `services.jar`, `org.cyanogenmod.platform.jar`, `CMParts.apk`,
`CMSettingsProvider.apk`, and `Lawnchair.apk`; hashes are asserted in the script. Maven tooling
is downloaded with SHA-256 pins in `manifests/smali-tools.json`. Smali 2.5.2,
API 25, single-worker assembly. Only classes.dex changes in each ZIP; other
entry data and original system-package certificate metadata are preserved.
These modified system packages are not re-signed standalone APK updates.
The final generated files were installed and reboot-tested; all four hashes
matched the build manifest during the shortcut test.

Build default system files on an unmounted raw ext4 COPY under Linux/WSL:

```bash
python3 build/apply_system_defaults.py --input /path/to/lithium-system.raw.img \
  --out out/system-defaults.img --branding out/branding \
    --gestures out/home-gestures --fm out/fm-lineage/FMRadio.apk \
  --recorder /path/to/AudioRecorder-3.5.23.apk --media out/media-compat \
  --webview /path/to/Lineage-WebView-119.apk
```

This removes Jelly/HTMLViewer/OpenCamera/Xposed Installer, installs branding,
native shortcuts, Lineage FM, WebView 119 and Audio Recorder, prunes unsupported camera/gyro/compass
feature declarations, forces `qemu.hw.mainkeys=0`, preserves the hash-pinned original audio
HAL, applies system-file labels, and checks ext4 with e2fsck. Tested against
the D36 system snapshot; the resulting image passes a second read-only fsck.
The script does not flash or change userdata. Its generated image is distinct
from the live system snapshot and has not yet received a clean-install test.
Do not run the old M1a T-ROM audio-HAL substitution on this working baseline.

The default browser removal does not block embedded WebViews or installation
of additional apps; do not present it as a complete web-access restriction.

## Launcher cleanup and Xposed

The stock Lawnchair fork conflates two missing-component bits (Google app=1,
Lawnfeed=2) with its outdated-Lawnfeed state (3). Neither feed component is
installed, yet startup calls `showOutdatedLawnfeedPopup` and displays the nag.
F6 checks whether the feed is enabled and whether an actual installed Lawnfeed
is outdated, rather than comparing that ambiguous state. It also defaults the
optional swipe-to-install feed prompts off. Google feed itself already defaults
off. No feed updater or Google app needs to be added for a music-player build.

Xposed Installer has been removed from system and userdata after repository
receiver crashes. No enabled modules were found; normal app_process and libart
have no Xposed dependencies in the checked runtime. None of the hardware/Home
fixes relies on Xposed. Inactive bridge/alternative app_process files remain;
this is not a complete framework uninstall.

## Bounded camera diagnostics (D40–D42)

These add no camera-model assumption. D40 provides root-only
`/sys/module/kd_sensorlist/parameters/camera_probe_budget`, default **0**.
D41 covers both logical slots because a physically front-facing single sensor
could be wired to the logical main slot. D42 additionally checks I2C adapter 2;
the speaker amplifier's 0x58 address is never probed. Known touch address
I2C0:0x40 is explicitly excluded.

While the normal HAL has powered the selected slot, the diagnostic does a
one-byte read at a bounded set of camera candidate addresses. Only if a device
ACKs does it select/read six possible ID registers (no sensor configuration
values are written). A budget is capped at ten invocations, then exhausted.
It does not force GPIO levels, change voltages, or alter normal driver routing.
All power/clock assumptions still belong to the current HAL/board templates.

D41 captured 170 candidate reads on buses 0/1 across both slot power templates,
with **no ACKs**. D42 captured 260 candidate reads across buses 0/1/2 and both
logical slots, also with **no ACKs**. The budget was reset to zero afterward.
CameraService still reports zero devices. The MTK adapter maps ACK errors to -22;
the accompanying I2C_ACKERR/controller dump distinguishes this from an invalid
request rejected without a bus transaction. This does not prove camera absence.
No camera calibration files were found in the current /data/nvram/APCFG tree.

Reproduce only on the rooted development unit, recording /dev/kmsg before
restarting cameraserver. Set camera_probe_budget to 10, stop/start cameraserver,
capture Q5CAM lines, and reset the parameter to 0. Avoid accidentally treating
the unrelated GC5004 template name as evidence for rear hardware. There is no
reported rear lens. The supplied purchase listing has no camera reference
according to the user's inspection. Further camera-specific changes need
positive hardware identification or evidence of actual camera operation.

## Historical checkpoint package (superseded)

`out/Q5-Mint-Lithium7-D42-development-20261126.zip` contains a full 16MiB D42
boot image, the gnome LOGO partition, and a system snapshot with Home defaults,
browser removal, Open Camera and the launcher prompt fix. Only BOOTIMG/ANDROID/
LOGO are enabled in the scatter; its addresses/sizes are asserted against the
Mint MT6582 layout. No userdata, calibration, NVRAM, recovery, bootloader or
partition-table images are included. This archive predates the FM, recorder, navigation-switch and cleanup changes.
Do not use it as the latest checkpoint. Clean-install validation remains
outstanding.

The original system snapshot is preserved read-only. A separate package copy
needed only the inode-bitmap padding repair from e2fsck; a second read-only fsck
passed. ZIP member CRCs were checked and a SHA256SUMS/manifest included. Use
`build/package_checkpoint.py` to reproduce packaging; it never flashes.

## Superseded direct-route FM checkpoint

`out/Q5-Mint-Lithium7-D42-R3-appfix-development-20261126.zip` used the silent
direct FM route. It is superseded by the FM-confirmed checkpoint below.
Its historical manifest is retained for traceability; do not use it as latest.

## Latest FM-confirmed application/media checkpoint

`out/Q5-Mint-Lithium7-D42-R3-FM-confirmed-development-20261126.zip` includes
the R3 boot, video compatibility/cleanup fixes, user-confirmed Lineage FM with
software rendering and its required HAL property, WebView 119, recorder, F7
navigation settings, branding and app/feature cleanup.
`manifests/checkpoint-fm-confirmed-2026-11-26.json` records member hashes and
remaining checks. All 36 generated changed system files match the installed
device byte-for-byte. The user confirmed hearing 93.7 through wired headphones,
then confirmed it still works after the pause/resume and volume checks.

The user's short spoken recording and requested generated test song are visible
in Music. Recordings, account data, adopted-volume keys and all other userdata
are excluded from the checkpoint. Server sign-in, paired Bluetooth audio,
FM speaker/Bluetooth routing, a full FM station scan and low-battery charging
remain separate checks. No clean-install or factory-reset pass is claimed.
