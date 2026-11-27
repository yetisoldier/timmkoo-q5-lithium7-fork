# Optional audiobook and music clients

These clients are installed separately; none are bundled in the ROM. Account
credentials and private diagnostics are not part of this repository/release.

| Client | Q5 Android 7 result |
|---|---|
| Saga 1.2.0 | Owner signed in through Q5 Plex Sign-in. Library switching exists; Plex Home profile switching is absent from the tested source/UI. |
| Original Chronicle 0.53.0 | Unofficial app-local API-25 image-metadata guard fixes the post-login crash. Owner selected Kye and logged into that managed profile. See CHRONICLE-COMPAT.md. |
| fabiogermann/chronicle (Epilogue) | Current source minSdk 30; incompatible with API 25. This is distinct from original Chronicle. |
| Bookcamp | Not installed. Publisher site checked; temporary F-Droid Aurora Store reached the Google Play listing, but download failed with a server-busy response and no APK was obtained. No verified Android-7-compatible version established. Temporary store removed. Owner then dropped Bookcamp because Chronicle works. |
| Prologue | Official site requires Android 13 or later; cannot install on Android 7. |
| Audiobookshelf | Uses Audiobookshelf servers; not a Plex client. Previously tested; not bundled. |
| Apple Music 4.7.2 | Owner confirmed playback after motion-artwork workaround; see PERFORMANCE-BRINGUP.md. |
| Plexamp 4.12.4 | Installed at final check; Flat background and Android animations off. No measured speed gain claimed. |

Primary sources: [Saga](https://github.com/gaut3/saga),
[original Chronicle](https://github.com/mattttvaughn/chronicle/tree/0.53.0),
[Epilogue](https://github.com/fabiogermann/chronicle),
[Bookcamp](https://www.bookcamp.app/), [Prologue](https://prologue.audio/).
