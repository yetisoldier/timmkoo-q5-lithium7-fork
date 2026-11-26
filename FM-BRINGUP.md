# FM receiver follow-up — 2026-11-26

The user confirmed FM worked on this unit under Mint. The Mint receiver port
was not a completed audio fix: its volume key crashed and its old
`MEDIATEK://MEDIAPLAYER_PLAYERTYPE_FM` source cannot prepare on this Nougat
MediaPlayer. A successful RF power-up never established audible playback.

## Current implementation

Use the Lineage cm-14.1 receiver, pinned to
`3aa58f54e9c8cdf79aba25e4a71bf1bb6668d8f7`, package `com.android.fmradio`.
It uses STREAM_MUSIC, Android audio patches and a RADIO_TUNER capture/playback
fallback. It replaces `com.mediatek.FMRadio`; do not leave its userdata update
installed over the old system app.

The build retains a separate app UID, removes the upstream shared system UID,
targets 22 because this app has no runtime-permission flow, and requests
CAPTURE_AUDIO_OUTPUT in addition to upstream audio-routing permissions.
Install in priv-app with extracted ARM JNI. The routing/capture permissions
were verified granted. A userdata update alone cannot access all of the old
JNI's private native dependencies on this ROM; use the system install.

The original Lithium JNI matches `com/android/fmradio/FmNative`. Its 15
reviewed Thumb MOVT request-size immediates are corrected to the pinned ARM
kernel UAPI. JNI registration and argument-buffer code stay unchanged. See
`manifests/fm-lineage-abi-patches.json`. The resulting native SHA-256 is
`c009d44270bc948df7f537d1a24ce59ce4930d902db3c6a061f75a146310353f`.
The root Java probe passed open, RX power-up, tune 93.7, mute, power-down and
close. The original uncorrected JNI opened but failed GETCHIPID and power-up.

The user subsequently confirmed the direct-headphone patch was still silent.
The app now retains upstream `config_useSoftwareRenderingForAudio=true`, so
normal listening uses RADIO_TUNER capture followed by a STREAM_MUSIC AudioTrack,
the same software path used for the successful nonzero recording test. This
combination is undergoing a fresh listening check. Crucially, the HAL also
requires **persist.af.audio_patch_fm=1**, read during HardwareInit. Its
default is zero; without it, a registered patch and active audio stream can
remain entirely silent. This was verified in the actual original HAL's
disassembly. Restart audioserver or reboot after changing the property.

With the property enabled, HAL logs show SetFmEnable, successful
FM_IOCTL_GET_AUDIO_INFO and AUDDRV_SET_FM_I2S_GPIO. A subsequent 6.50-second
93.7 recording contains nonzero PCM, approximately -9.38 dBFS RMS; the same
app's earlier capture with the property absent was exactly zero. Read-only
queries showed chip 0x6627, powered=1 and RSSI approximately -65 to -69.
Volume Up/Down leaves the app process alive. Physical intelligibility and
station-listening confirmation remain separate from these measurements.
Temporary FM audit recordings were discarded and private host audio removed.
The user's voice-recorder message is preserved.

Do not treat GET_I2S_INFO's OFF value as measured hardware state: this chip's
implementation returns static config metadata. Its I2S-setting callback is
unimplemented, in a disabled source block; a bounded test returned -1002.
No speculative I2S register writes or new kernel callback were added. The
original audio HAL remains byte-identical, SHA-256
`a7cc2dbe2cc2b8fd9c06d86f6f9479670a16e66bacc8941660ac81d6a370463e`.

## Build

`manifests/lineage-fm-build.json` pins source, resource API, tools and native
donor. Obtain its three build dependencies from the listed primary URLs.
Use a clean checkout at the pinned commit and the documented aapt binary.
Java tools run locally; Windows invokes aapt through WSL Ubuntu.

```sh
python build/build_lineage_fm.py --source /path/to/lineage-fmradio \
  --tools /path/to/fm-build-tools --framework out/branding/framework-res.apk \
  --native /path/to/original-lithium-libfmjni.so \
  --keystore /private/q5-development.jks --out out/fm-lineage
```

The local key is not committed. APK signing timestamps change final APK hashes;
native edits and inputs are hash pinned. Pass the generated APK and adjacent
fm-build-manifest.json to apply_system_defaults.py; it sets the HAL property,
retains the new libfmjni and removes the three obsolete private Mint libraries.
The historical Mint builder/A1–A3 patches remain for review, not as the current
default. R1's dynamic FM node correction is still required.
