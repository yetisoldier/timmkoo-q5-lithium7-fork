# Forge — Q5 gnome boot splash (`logo.bin`) report

**Artifact:** `out/logo-gnome.bin` (648,222 B) — SHA256 `81e3004bf11f439cac0897791ad4c3d3ea06dc5589a1de3736715342594a8fba`
**Tool:** `build/logo_pack.py` (committed) — `pack` / `decode` / `verify` / `info`
**Preview:** `out/logo-gnome-preview.png` (rendered from the packed binary itself) and `out/logo-gnome-decoded.png` (independent decode path — byte-identical)
**Reference:** `~/.hermes/q5-recovery/base/Mint_V1.0/logo.bin`
**Not flashed** — Hera owns the device; this file is ready for the LOGO partition only.

---

## 1. Format decoded (byte-level, from the reference)

The Q5's `logo.bin` is the MediaTek "multi-image zlib logo" format. Everything below was
derived from the Mint file and cross-confirmed on `T-ROM_V2.3/logo.bin`,
`Manufactory_latest/logo.bin`, and `T-ROM_V2.3/lk.bin` (the bootloader uses the **same
512-byte partition header family** with signature `LK`).

### 1.1 MTK partition header (512 bytes)

| offset | size | content |
|---|---|---|
| `0x000` | 4 | magic `88 16 88 58` = u32 LE `0x58881688` |
| `0x004` | 4 | payload size, u32 LE (== file size − 512) |
| `0x008` | 32 | signature, NUL padded to byte 40 — `LOGO` here (`LK` in lk.bin) |
| `0x028` | 472 | `0xFF` padding to 512 |

Verified on both samples: `LOGO` sig + NUL pad in `12..40`, uniform `FF` in `40..512`.
Header size field == actual payload length on both (`257,006` for Mint; `277,404` for lk.bin).

> Note: the task brief said Mint's logo.bin is 257,518 B; the actual file is **257,354 B**
> (= 512 + 257,006). Its SHA256 (`c37129d5…`) matches Mint's own `RELEASE_NOTES.md`, so all
> figures here are anchored to the real bytes.

### 1.2 Payload ("logo section")

Laid out at file offset 512:

```
+0     u32 LE  image count N                         (39 in all three ROMs)
+4     u32 LE  payload size, repeated                (== len(payload))
+8     N×u32   start offset of each image blob       (156 B table; blob0 at 8+4N = 164)
+164   blobs   raw zlib streams (level 9, `78 DA`), back to back
```

Blob *i* spans `[offset[i], offset[i+1])`, the last one ending at payload end. The table is
monotonic; every blob inflates cleanly with zero trailing bytes (asserted programmatically
for all 39 blobs).

### 1.3 Pixel format — RGB565, no inner header

Each decompressed blob is a **raw RGB565 image** (`u16` LE, `RRRRRGGG GGGBBBBB`,
row-major, top-to-bottom) with **no dimension header**:

- Full-screen layers decode to exactly `480 × 800 × 2 = 768,000` bytes — the Q5 panel size.
- Smaller layers (battery/charging bitmaps: 4,104 / 5,184 / 6,480 / 270 bytes) are identified
  by their index; LK derives their role from the index (no dimension constants appear inside
  `lk-q5.bin` — the loader is fully table-driven).
- Channel order validated visually: Mint layer 0 renders as beige `0xF71A` (240,224,208) with
  standard R-in-high-bits; orange headphones render orange, battery fills render
  green/red/blue correctly. No R/B swap.

### 1.4 Layer role map (Mint, visual inspection of decoded layers)

| indices | raw size | content |
|---|---|---|
| **0 and 38** | 768,000 | **boot splash** — byte-identical duplicate pair (beige "headphones-#" logo) |
| 1 | 768,000 | low-battery screen (bokeh + empty orange battery) |
| 2–3 | 768,000 | charging / power-off screens (bolt battery) |
| 4–14 | 4,104–5,184 | small battery bitmaps (white/gray on black) |
| 15–24 | 6,480 | small charging-anim bitmaps (blue fill) |
| 25–35 | 768,000 | full-screen charging anim frames (near-black) |
| 36 | 270 | tiny blue bitmap |
| 37 | 768,000 | near-black frame |

**Boot-logo convention:** index 0 == last index is present in **all three** reference
logo.bin files (Mint, T-ROM, Manufactory) — the boot splash is stored twice. T-ROM's copy
targets a different clone panel (layer raw lens exactly 2× Mint's — 600×1280-sized), which
confirms the format generalizes while Mint is the correct 480×800 template for this device.

## 2. What `logo-gnome.bin` contains

- Same structure as Mint, count **39**, table recomputed from the new blob spans.
- **Only layers 0 and 38 replaced** with the gnome splash (identical zlib blob, mirroring the
  dup convention — whichever index LK shows at boot, it displays the gnome). The other **37
  layers are byte-identical to Mint** (charging/battery behaviour preserved).
- Splash blob: 218,068 B compressed from 768,000 B raw RGB565.
- File: 512 (header) + 647,710 (payload = 8 + 156 + 647,546 blobs) = **648,222 B** — fits the
  LOGO partition (0x300000 = 3,145,728 B) with ample headroom.

## 3. Fit / padding note

- Source: 1086×1448 (exactly 3:4) → aspect-fit to **480×640** (Lanczos) — no cropping at all,
  beanie tip through shoe soles preserved, exactly 480 px wide.
- Letterboxed to 480×800: gnome centered with **80 px bands** top and bottom, filled with a
  flat `#050910` — auto-sampled as the mean of the source's four 8×8 corner patches (the dark
  navy studio backdrop). The floor reflection at the artwork's bottom fades into the band;
  no visible seam.
- Alternatives rejected with evidence: mirror padding replicates rendered content (an
  upside-down beanie ghost at the top — artwork is edge-to-edge); edge/gradient extension
  would streak through the beanie; cover-crop would clip the headphone cups (explicitly to
  be avoided).
- RGB565 quantisation uses round-half-up (`(c*31+127)//255` / `(c*63+127)//255`) — slightly
  better than truncation, layout identical to the reference.

## 4. Verification (all green)

`python3 build/logo_pack.py verify --candidate out/logo-gnome.bin --reference <mint> --image <src>`:

- header magic / `LOGO` signature / size fields / NUL+`0xFF` padding byte-exact
- count == 39 and payload structure matches the reference layout
- 37 non-boot layers **byte-identical** to Mint
- both boot layers identical blobs; inflate to exactly 768,000 B
- canonical re-serialization of the candidate payload is byte-identical to the file
- determinism: a fresh encode of the source PNG reproduces the splash blob bit-for-bit
- `decode --index 0` of the packed file == the preview PNG (independent parse path)

Toolchain used: Python 3.14.3, Pillow 12.2.0, numpy 2.4.4, zlib 1.3.1.zlib-ng.

## 5. How to flash (Hera only — not done here)

- **SP Flash Tool** (the Mint-supported path): load `MT6582_Android_scatter.txt` (the fork's
  `out/scatter-fork.txt` has the same LOGO map: `SYS13 / LOGO / 0x5800000 / 0x300000`),
  tick **LOGO**, select `out/logo-gnome.bin`, download-only that partition.
- **fastboot** (if the bootloader exposes it): `fastboot flash logo out/logo-gnome.bin`.
- **dd** (rooted/live): `dd if=out/logo-gnome.bin of=/dev/block/by-name/logo bs=4M` then reboot.

## 6. Regenerating (deterministic + re-runnable)

```bash
python3 build/logo_pack.py pack \
  --image /home/yetisoldier/.hermes/images/upload_9rch1l2h.png \
  --width 480 --height 800 \
  --reference ~/.hermes/q5-recovery/base/Mint_V1.0/logo.bin \
  --out out/logo-gnome.bin --preview out/logo-gnome-preview.png
python3 build/logo_pack.py verify \
  --candidate out/logo-gnome.bin \
  --reference ~/.hermes/q5-recovery/base/Mint_V1.0/logo.bin \
  --image /home/yetisoldier/.hermes/images/upload_9rch1l2h.png
```

Lanczos resize, fixed rounding, zlib level 9 and the fixed layout make the output stable;
zlib stream bytes could theoretically differ on other zlib builds — `verify` re-encodes and
catches any drift.

## 7. Known limitations / notes

- Small-layer (battery bitmap) pixel dimensions are implied by index in LK; they are copied
  from Mint untouched, so this does not affect `logo-gnome.bin`.
- If a future image wants more padding than the panel allows, use `--pad-mode color --bg …`.
- The Mint logo.bin duplicate-layer convention (0 == N−1) is assumed to be a format/tool
  convention; even if LK only ever reads one of the two indices, both hold the gnome.
