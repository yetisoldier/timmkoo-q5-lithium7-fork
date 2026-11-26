# Forge — Create the gnome boot splash (logo.bin) for the Q5

## Source image
`/home/yetisoldier/.hermes/images/upload_9rch1l2h.png` — 1086×1448 PNG, the blue gnome mascot (3D DJ
gnome: blue beanie, headphones, hoodie, on a dark backdrop). No text. Use it as-is (no wording).

## Goal
Produce a MediaTek `logo.bin` (the Q5 boot splash, flashed to the LOGO partition) from that image.

- Q5 screen: **480×800 portrait**.
- Format reference: `~/.hermes/q5-recovery/base/Mint_V1.0/logo.bin` (257,518 B). Structure: a 512-byte
  MTK header (`88 16 88 58` magic + LE32 payload-size at +4 + `"LOGO"` at +8 + 0xFF padding to 512),
  then the logo payload (257,006 B) which has its OWN internal structure (starts `27 00 00 00 ee eb
  03 00 a4 00 00 00 60 59 00 00 …`). Decode that payload layout and reproduce it exactly.

## What to do
1. Find the MTK `logo_gen.py` (MediaTek source tree) or a compatible logo tool; if none, fully decode
   the Mint logo.bin payload structure (its sub-header fields + pixel layout) and reproduce it by hand.
2. Fit the gnome into 480×800: the source is ~3:4 (1086×1448), screen is 3:5 (480×800). Prefer
   **pad/letterbox on a dark or matching-dark background** to keep the whole gnome (avoid cropping the
   headphones/feet). Center it.
3. Convert to the pixel format the Mint logo.bin uses (RGB565 vs RGB888 — read it off the reference).
4. Emit `out/logo-gnome.bin` with the correct MTK header + payload structure + the gnome pixels.
5. Verify: header + payload layout byte-structurally match the Mint reference; the rendered image is
   the gnome at 480×800 (dump it back to a PNG to eyeball it if a viewer is available).

## Rules
- Do NOT flash anything (Hera owns the device). Commit the conversion script + any notes; the binary
  `logo-gnome.bin` stays in `out/` (gitignored).
- Deterministic + re-runnable.

## Output
- `out/logo-gnome.bin` + `.specs/forge-logo-report.md` (format decoded, how to flash to LOGO partition,
  and a note on the final fit/padding).
