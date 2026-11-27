# Original Chronicle on Q5 / Android 7

The requested fabiogermann/chronicle fork requires a newer Android version.
The original mattttvaughn/chronicle 0.53.0 freeAsInBeer publisher release still
installs on API 25, but its Fresco decoder unconditionally references the
API-26 ColorSpace class when reading image metadata. It crashes after sign-in.

`build/build_chronicle_compat.py` guards that one metadata assignment below
API 26. It pins the original APK and smali tools, preserves every other ZIP
entry except signing metadata, and signs the modified APK with a local Q5
identity. This is an unofficial compatibility build, not the requested newer
fork or a global framework/API modification. The publisher's freeAsInBeer
variant already unlocks its features; this patch does not change entitlements.

A signer change requires backing up private app data before replacing the
publisher install. The development device's original prefs/files/databases
were backed up privately on-device, restored with the new UID/SELinux labels,
and never committed. Future builds with the same Q5 signer support normal
in-place upgrades. Do not share account data or signing keys.

Validation: the original post-login ColorSpace crash was reproduced; the
patched app loaded successfully and the owner selected Kye and logged into
that managed Plex profile. Playback/offline-book behavior is not yet claimed.
This client is optional userdata, not bundled in the firmware image. Public
source: https://github.com/mattttvaughn/chronicle/tree/0.53.0 (GPL-3.0).
