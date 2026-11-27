# Component provenance and source

Lithium 7 for Q5 Gen 7 combines existing Android firmware components with this
project's hardware, framework and packaging changes. Components retain their
own licenses; this document does not relicense proprietary donor binaries.

| Component | Source / notice |
|---|---|
| Android / Lineage-derived framework and Lithium base | [Lithium7](https://github.com/T-ROM-Project/Lithium7); existing component notices and licenses remain in the image |
| Q5 Mint reference firmware | [TIMMKOO Q5 Mint](https://github.com/Sendew/TIMMKOO-Q5-Mint-Custom-ROM); used as a hardware/firmware reference |
| Linux kernel | GPL-2.0; [heyrudra/android_kernel_micromax_a106](https://github.com/heyrudra/android_kernel_micromax_a106) at `96e535524cb10b9e3d9ea2d0e69599726605ae8e`, with the patches in `build/kernel-d43.series` |
| FM Radio Java/resources | Apache-2.0; [LineageOS FMRadio](https://github.com/LineageOS/android_packages_apps_FMRadio/tree/3aa58f54e9c8cdf79aba25e4a71bf1bb6668d8f7). Build changes are in `build/build_lineage_fm.py`; JNI donor and edits are hash pinned |
| Android support CardView | Android support library 25.4.0, Apache-2.0; pinned in `manifests/lineage-fm-build.json` |
| Embedded WebView | Lineage ARM prebuilt 119.0.6045.134 at [6d883cfe](https://github.com/LineageOS/android_external_chromium-webview_prebuilt_arm/tree/6d883cfe7f5f50470b29b21c26aa204205186a1a). Chromium and bundled components retain their licenses; upstream license assets remain in the APK. Chromium source corresponds to [119.0.6045.134](https://chromium.googlesource.com/chromium/src/+/refs/tags/119.0.6045.134/) |
| Audio Recorder 3.5.23 (379) | GPL-3.0-or-later; [Axet Audio Recorder](https://gitlab.com/axet/android-audio-recorder). APK and corresponding source supplied by F-Droid |
| Gnome artwork | User-supplied artwork, included for this firmware's branding; no separate artwork reuse license is granted here |

The v1.0.1 release supplies **Q5-Gen7-Lithium7-v1.0.1-kernel-source.tar.gz**,
containing the patched kernel source including its COPYING file and Q5
configuration. The source archive **AudioRecorder-3.5.23-source.tar.gz** is the
unmodified F-Droid corresponding source for the bundled recorder:

- Original: `https://f-droid.org/repo/com.github.axet.audiorecorder_379_src.tar.gz`
- SHA-256: `e74dc61759a7c50780a6875f96661d0bc66f96b4c66fc5396768c2feeb3a08b1`

The repository tag contains the framework/app patches, native compatibility
source and build/installation scripts. See `docs/BUILDING.md`. Existing audio,
graphics, radio firmware and other vendor binaries are donor-derived and have
not been represented as newly authored open-source components.
Component license copies are included under `docs/licenses/`.

Audiobookshelf, Plexamp and Apple Music are not redistributed in this firmware
release. Obtain compatible clients from their respective legitimate sources.

The Q5 Plex sign-in helper is built from `apps/plex-signin` with
`build/build_plex_signin.py`. It uses the existing embedded WebView. Optional
Saga, Chronicle, Bookcamp and Prologue clients are not bundled in the ROM.
