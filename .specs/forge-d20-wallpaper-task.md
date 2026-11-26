# Forge — D20: set the blue gnome as the default wallpaper

## Source image
`/home/yetisoldier/.hermes/images/upload_9rch1l2h.png` (1086×1448, the blue DJ gnome) — same image as
the boot splash.

## Goal
Make the blue gnome the DEFAULT wallpaper on the fork's system.img, so a fresh boot shows it as the
home-screen wallpaper (no user action).

## What to do
1. Find where Lithium 7 stores the default wallpaper: the framework default is
   `framework-res.apk` → `res/drawable-nodpi/default_wallpaper.*` (usually `.jpg`); the launcher may
   also have its own default. Identify the actual file(s) in the M1a system.img
   (`out/system.img` — mount it read-only, or re-extract from `~/q5-flash/rom/system.img`).
2. Derive a wallpaper-appropriate image from the gnome: target the Q5's 480×800 screen; a centered
   fit with a matching dark background (same approach as the splash — see `forge-logo-report.md` for
   the sampled background color). Save as the same format the framework expects (e.g. JPEG).
3. Replace the default wallpaper inside `framework-res.apk` (apktool, or a direct zip replacement of
   the drawable — preserve the APK's signing/zip alignment; note: framework-res is usually signed
   with the platform key, so a raw-replace inside the already-built system.img is the pragmatic path,
   NOT a re-sign).
4. Rebuild `out/system.img` with the wallpaper swapped (debugfs -w on a work copy, same as the M1a
   pipeline `build/00_env.sh`/`10_stage.sh`/`20_ops.sh`/`30_publish.sh` pattern), idempotent +
   hash-gated.
5. Verify: the repacked system.img mounts read-only, the wallpaper file is the gnome, and nothing
   else changed (diff the file list vs M1a).

## Rules
- Do NOT flash anything (Hera owns the device). Follow the M1a pipeline's determinism/hash rules.
- Keep the splash (`logo.bin`) and this wallpaper as separate artifacts.

## Output
- `out/system-gnome-wallpaper.img` + a short `.specs/forge-d20-report.md` (where the wallpaper lives,
  the format used, and how it was swapped in).
