# Bob — Design the Q5 Lithium 7 Fork (Milestone 1)

## Read first (both in this repo)
1. `.specs/hermes-brief-v0.1.0-q5-lithium7-fork.md` — objective + verified evidence.
2. `.specs/scout-research-report.md` — Scout's research (tools, techniques, resources, caveats).

## Objective
Design the fork: keep **Lithium 7 (Android 7.1.2)** but carry the correct hardware config for the
**Q5 Mint** variant, fixing four issues: (1) charging/PMIC (stuck 0-1%), (2) internal speaker
silent, (3) button mapping, (4) front camera.

## Key decisions you MUST make (each with options + rationale)

1. **Fork strategy — source-level vs image-level.** Scout found Lithium 7 source at
   `github.com/NoahDomingues/Lithium` (GPL-3.0). Determine whether it is a complete buildable tree
   (system + kernel) or system-only (kernel shipped as binary). This decides source-fork+build vs
   binary-patch of the shipped `boot.img`/`system.img`. Clone `--depth 1` into a gitignored
   `.reference-lithium/` dir and report exactly what is source vs binary.

2. **Charging fix.** Scout caveat: MT6582 (Linux 3.4.67, ALPS) is board-file-based, so `boot.img`
   likely has NO DTB. Verify empirically: unpack `~/.hermes/q5-recovery/base/Mint_V1.0/boot.img`
   and `~/q5-flash/rom/boot.img`, scan the kernel blob for DTB magic `0xD00DFEED`, and diff the
   kernel + ramdisk + any second-stage between the two. Decide where the charging config differs
   (kernel board config vs ramdisk/`init` vs `lk`/preloader) and the fix route (rebuild kernel from
   MT6582 3.4.67 source with Mint board headers vs binary-patch vs other). Reference Google's
   sprout MT6582 3.4.67 tree (`android.googlesource.com/kernel/mediatek`, branch
   `android-mediatek-sprout-3.4-kitkat-mr2`) for the fan5405/MT6323/MAX17050 stack.

3. **Audio fix.** Verified: kernel zImage is byte-identical across working (T-ROM) and broken
   (Lithium); the defect is userspace — `audio.primary.mt6582.so` HAL + `audio_policy.conf`
   (`audio_hal_version 2.0` vs working `3.0`) + a bogus 122-byte `mixer_paths.xml` stub. Scout:
   MTK does NOT use `mixer_paths.xml` (that's Qualcomm); real knobs are `audio_policy.conf` +
   `/system/etc/audio_device.xml` + the HAL. Decide the exact port: graft Mint's audio config
   (primary-module contents, `audio_hal_version 3.0`, `audio_device.xml`, any amp-enable mixer
   control) into a Nougat MT6582 HAL, OR take a known-good Nougat HAL from
   `github.com/T-ROM-Project/android_vendor_t-rom_q5_q3e_mt6582` and graft config. Name the exact
   files + porting steps. For the AW87559 amp: reference `artificery-dev/tempo` `docs/porting/audio.md`
   (enable GPIO + I2C reg sequence, I2C reg `0x58`, chip ID `0x5A`).

4. **Button mapping.** The Q5 Mint has three side buttons + a central home key + a front camera.
   Map every physical button to its key code and action. Diff `/system/usr/keylayout/*.kl` (esp.
   `mtk-kpd.kl`, `Generic.kl`) and any key-character-map (`.kcm`) between Lithium and Mint
   `system.img`; determine which physical button (volume up/down, power, home) maps to which key
   code and why some were dead under Lithium. Also check `qemu.hw.mainkeys` and the navigation-bar
   / hardware-keys framework config. Name the exact fix.

5. **Camera.** The Q5 Mint has a FRONT-facing camera. Its I2C bus shows Hynix sensors + a
   DW9719/DW9714 focus actuator — this is the newer hardware revision Lithium was NOT built for.
   Determine whether Lithium's kernel has the camera sensor driver (and the focus-actuator
   driver); if not, the fix is a kernel-level port from the Mint base (like charging). Identify
   the exact camera hardware present (from the Mint base image and/or the live device), and name
   the port route (sensor driver + lens/focus driver + any camera config in the ramdisk/system).

## Forensic work (bounded — do not over-explore)
- Unpack both `boot.img`s, scan for DTB, diff kernel/ramdisk/second-stage (charging + camera).
- Diff the audio HAL + config across Lithium / T-ROM (working ref) / Mint (system.img).
- Diff `/system/usr/keylayout/` and `/system/usr/keychars/` between Lithium and Mint (buttons).
- Diff camera sensor / focus-actuator config between Lithium and Mint (kernel + system).
- Clone + inspect `NoahDomingues/Lithium` (into `.reference-lithium/`, gitignored).

Reference images (external — read via bash, do NOT copy into the repo):
- Lithium base: `~/q5-flash/rom/boot.img`, `~/q5-flash/rom/system.img`
- T-ROM (working audio ref): `~/.hermes/q5-recovery/base/T-ROM_V2.3/{boot.img,system.img}`
- Mint (correct hardware base): `~/.hermes/q5-recovery/base/Mint_V1.0/{boot.img,system.img}`

Tools (install via bash as needed): `bgcngm/mtk-tools` or AndroidImageKitchen (unpack boot.img),
`extract-dtb` (PyPI, DTB scan), `dtc`/device-tree-compiler (decompile).

## Output — write INCREMENTALLY to `.specs/bob-m1-spec.md` (section by section, so a budget
death still leaves a usable spec):
1. **Architecture Spec** — fork strategy + rationale (source vs image), and the fix approach for
   charging / audio / buttons / camera.
2. **Implementation Spec** — exact per-file changes for Forge (files, nodes/signatures, the
   untouched-surface constraints, which tests/checks apply).
3. **Validation Spec** — what Karen verifies offline + the on-hardware gates Hera runs on the Q5.

End with an explicit "Design complete" verdict, any open questions for Eric, and a short
"remaining entry points" list (for the next stage's task file).
