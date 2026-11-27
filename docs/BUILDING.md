# Build and provenance

v1.0.0 targets only the Q5 Gen 7 / Q5 Mint MT6582 profile. The release combines
the verified D42 kernel/R3 ramdisk with a newly generated versioned system image.
It is an Android binary port; this repository is not a full AOSP source tree.

To reproduce the immutable v1.0.0 release, use the `v1.0.0` tag. Current source
also applies the post-release Wi-Fi-only and ART defaults described in
`PERFORMANCE-BRINGUP.md`; do not replace existing v1.0.0 release assets.

Use Linux/WSL, Python 3.11+, debugfs/e2fsck, Java and the pinned ARM EABI GCC 4.8
toolchain. Windows runs the Python app builder with aapt through WSL Ubuntu.
Do not run the older M1a audio-HAL substitution pipeline on this working profile.

## Kernel

Source anchor: `heyrudra/android_kernel_micromax_a106` at
`96e535524cb10b9e3d9ea2d0e69599726605ae8e`. Ordered changes are in
`build/kernel-d42.series`. The bundled compiler is arm-eabi GCC 4.8.

```sh
Q5_BUILD_WORK=/path/to/new/work bash build/81_kernel_camera_diagnostic_all_adapters.sh \
  /path/to/pinned-kernel-checkout /path/to/reference-boot.img
python3 build/patch_fm_boot_node.py out/boot-d42.img out/boot-d42-r1.img
python3 build/patch_usb_boot.py out/boot-d42-r1.img out/boot-d42-r2.img
python3 build/patch_codec_boot.py out/boot-d42-r2.img out/boot-d42-r3.img
python3 build/patch_wifi_only_boot.py out/boot-d42-r3.img out/boot-d42-r4.img
```

The release's corresponding-source archive contains the already patched
`kernel-3.10` tree. Configure it with `q5_defconfig`, use an out-of-tree build
directory, then build `zImage` with ARCH=arm and CROSS_COMPILE pointing to that
toolchain. Kernel compilation does not reproduce the proprietary userspace.

## System components

- `build/build_branding.py`: user artwork to boot/logo/default wallpaper.
- `build/build_home_gestures.py`: pinned framework inputs and F1–F7 patches.
- `build/build_wifi_only.py`: voice/SMS capability resources, applied after
  branding by the system defaults builder. `ro.radio.noril=true` removes mobile
  network support and its lock-screen carrier text; Wi-Fi remains available.
- `build/build_lineage_fm.py`: pinned Lineage receiver, private app UID and
  corrected original Lithium JNI. Retains software rendering.
- `build/build_media_compat.py`: pinned media donors and the codec-only native
  helper. The original shared audio HAL and graphics M4U library stay unchanged.
- `build/fetch_webview.py`: verifies the pinned source pointer and LFS object.
- Audio Recorder APK: pinned in `manifests/optional-apps.json`; matching source
  is a release asset. Signing keys are local and never included in this repo.

See FM-BRINGUP.md, MEDIA-BRINGUP.md and CURRENT-STATUS.md for donor paths, hashes,
build commands and validation. The `reference-firmware` release archives Mint
and Lithium reference files; it is not a universal device restore image.

Generate a separate raw ext4 system copy, never modify the donor:

```sh
python3 build/apply_system_defaults.py --input /path/to/pinned-system-snapshot.img \
  --out out/system-q5gen7-v1.0.0.img --branding out/branding \
  --gestures out/framework-v4-navigation --fm out/fm-lineage-render/FMRadio.apk \
  --recorder /path/to/AudioRecorder-3.5.23.apk --media out/media-compat-v2 \
  --webview /path/to/Lineage-WebView-119.apk --release-version 1.0.0
```

The defaults builder verifies donor/component hashes, creates release metadata,
applies labels and runs filesystem checks. Package the matching boot, system,
3 MiB padded logo and Mint scatter with `build/package_checkpoint.py` using
`--release-version 1.0.0 --out out/Q5-Gen7-Lithium7-v1.0.0`. Include the other
required arguments shown by `--help`. It produces manifests, checksums, customer
documentation and the recovery installer, verifies ZIP CRCs and never flashes.

The APK signature timestamp may change a rebuilt APK hash. Use the supplied
release checksums for exact artifact verification. Historical development
archives are not substitutes for the v1.0.0 release.
