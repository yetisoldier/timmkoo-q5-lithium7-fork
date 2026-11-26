#!/usr/bin/env python3
"""logo_pack.py - MediaTek logo.bin (boot splash) pack/decode/verify for the Q5.

The Q5 (MT6582, "Q5 Mint" clone) stores its boot splash on the LOGO partition
(scatter: linear_start_addr 0x5800000, size 0x300000).  This tool converts a
PNG into that logo.bin and verifies the result against the Mint_V1.0
reference, byte-structurally.

Format (fully decoded from reference logo.bin files; see .specs/forge-logo-report.md):

  512-byte MTK partition header:
      +0x00  u32 LE   0x58881688 (magic; also used by the LK partition header)
      +0x04  u32 LE   payload size (== file size - 512)
      +0x08  char[32] signature, NUL padded ("LOGO" here; lk.bin uses "LK")
      +0x28  472 x 0xFF padding to 512

  payload:
      +0x00  u32 LE   image count N
      +0x04  u32 LE   payload size (repeated)
      +0x08  N x u32  offsets of each image blob, first blob at 8 + 4*N
      blobs: raw zlib streams (level 9, no framing beyond zlib).  Blob i spans
      [offset[i], offset[i+1]) ; the last blob ends at the payload end.

  Each decompressed blob is a raw RGB565 image (u16 LE, RRRRRGGGGGGBBBBB,
  row-major, top-to-bottom) with NO inner dimension header - full-screen
  layers are exactly width*height*2 bytes (480x800 x 2 = 768000 on the Q5);
  smaller layers (battery / charging animation bitmaps) are indexed by their
  position in the table, and the bootloader derives the role from the index.

  Boot-logo convention (verified in Mint_V1.0, T-ROM_V2.3 and
  Manufactory_latest logo.bin): the boot splash sits at index 0 AND is
  duplicated at the last index; battery / charging / low-battery screens fill
  the middle indices.  We mirror that convention: only indices 0 and N-1 are
  replaced with the new splash, every other blob stays byte-identical.

Determinism: LANCZOS resampling, fixed RGB565 rounding, zlib level 9 and a
fixed header/table layout make the output re-runnable byte-for-byte on the
same toolchain.  `verify --image` re-encodes from the source PNG and asserts
the candidate matches that encoding exactly.

Usage:
  logo_pack.py info   --logo BIN
  logo_pack.py decode --logo BIN --index 0 --width 480 --height 800 --out PNG [--dims WxH]
  logo_pack.py pack   --image PNG --width 480 --height 800 --reference BIN \
                      --out BIN [--boot-indices 0,38] [--pad-mode auto|color|reflect] \
                      [--bg RRGGBB] [--preview PNG]
  logo_pack.py verify --candidate BIN --reference BIN --width 480 --height 800 \
                      [--boot-indices 0,38] [--image PNG] [--preview PNG]
"""

import argparse
import hashlib
import struct
import sys
import zlib

import numpy as np
from PIL import Image

MTK_LOGO_MAGIC = 0x58881688
HEADER_SIZE = 512
SIG_FIELD_SIZE = 32          # signature occupies bytes 8..40, NUL padded
PAD_BYTE = 0xFF              # bytes 40..511 of every observed MTK header


class FormatError(Exception):
    pass


# --------------------------------------------------------------------------- #
# header / payload parsing
# --------------------------------------------------------------------------- #

def build_header(payload_size, signature=b"LOGO"):
    """Byte-exact reproduction of the 512-byte MTK header seen in Mint/lk."""
    if len(signature) >= SIG_FIELD_SIZE:
        raise FormatError("signature too long: %r" % signature)
    sig_field = signature + b"\x00" * (SIG_FIELD_SIZE - len(signature))
    return (struct.pack("<II", MTK_LOGO_MAGIC, payload_size)
            + sig_field
            + bytes([PAD_BYTE]) * (HEADER_SIZE - 4 - 4 - SIG_FIELD_SIZE))


def parse_header(data):
    if len(data) < HEADER_SIZE:
        raise FormatError("file shorter than the 512-byte MTK header")
    magic, size = struct.unpack_from("<II", data, 0)
    if magic != MTK_LOGO_MAGIC:
        raise FormatError("bad magic 0x%08X (expected 0x%08X)" % (magic, MTK_LOGO_MAGIC))
    sig = data[8:40].rstrip(b"\x00")
    if size != len(data) - HEADER_SIZE:
        raise FormatError("header payload size %d != actual %d" % (size, len(data) - HEADER_SIZE))
    if not set(data[40:HEADER_SIZE]) == {PAD_BYTE}:
        raise FormatError("header tail is not uniform 0xFF padding")
    if not set(data[12:40]) == {0x00}:
        raise FormatError("signature field is not NUL padded to byte 40")
    return {"magic": magic, "payload_size": size, "signature": sig}


def parse_payload(payload):
    """Return (count, offsets, [compressed blobs]).  Asserts every invariant."""
    if len(payload) < 8:
        raise FormatError("payload too small")
    count, psize = struct.unpack_from("<II", payload, 0)
    if psize != len(payload):
        raise FormatError("payload-internal size %d != payload length %d" % (psize, len(payload)))
    if count <= 0 or 8 + 4 * count > len(payload):
        raise FormatError("bad image count %d" % count)
    table_end = 8 + 4 * count
    offsets = struct.unpack_from("<%dI" % count, payload, 8)
    if offsets[0] != table_end:
        raise FormatError("first blob offset %d != right after table %d" % (offsets[0], table_end))
    bounds = list(offsets) + [len(payload)]
    for i in range(count):
        if bounds[i] >= bounds[i + 1]:
            raise FormatError("blob %d has empty/invalid span (%d..%d)" % (i, bounds[i], bounds[i + 1]))
    blobs = []
    for i in range(count):
        compressed = payload[bounds[i]:bounds[i + 1]]
        d = zlib.decompressobj()
        raw = d.decompress(compressed)
        if d.unused_data or not d.eof:
            raise FormatError("blob %d is not a single clean zlib stream" % i)
        blobs.append(compressed)
    return count, offsets, blobs


def serialize_payload(blobs):
    """Canonical serialization: table with running offsets + zlib blobs."""
    count = len(blobs)
    sizes = [len(b) for b in blobs]
    offsets = []
    off = 8 + 4 * count
    for s in sizes:
        offsets.append(off)
        off += s
    if off - (8 + 4 * count) == 0 or any(s == 0 for s in sizes):
        raise FormatError("refusing to emit empty blob")
    parts = [struct.pack("<%dI" % count, *offsets)]
    parts.extend(blobs)
    body = b"".join(parts)
    # payload = count word + size word + offset table + blobs (== 8 + len(body));
    # mirrors Mint: 8 + 156 + 256842 = 257006
    return struct.pack("<II", count, 8 + len(body)) + body


# --------------------------------------------------------------------------- #
# pixels
# --------------------------------------------------------------------------- #

def rgb565_encode(rgb):
    """RGB888 (HxWx3 uint8) -> packed RGB565 u16 LE bytes.

    Uses round-half-up scaling (r*31+127)//255 rather than truncation: same
    layout the reference encodes, ~half a quantisation step better.
    """
    r = rgb[..., 0].astype(np.uint32)
    g = rgb[..., 1].astype(np.uint32)
    b = rgb[..., 2].astype(np.uint32)
    r5 = ((r * 31 + 127) // 255).astype(np.uint16)
    g6 = ((g * 63 + 127) // 255).astype(np.uint16)
    b5 = ((b * 31 + 127) // 255).astype(np.uint16)
    px = (r5 << 11) | (g6 << 5) | b5
    return px.astype("<u2").tobytes()


def rgb565_decode(raw, width, height):
    """RGB565 u16 LE bytes -> HxWx3 RGB888 uint8 (bit-replication expansion)."""
    expected = width * height * 2
    if len(raw) != expected:
        raise FormatError("raw layer is %d bytes, expected %d for %dx%d RGB565"
                          % (len(raw), expected, width, height))
    px = np.frombuffer(raw, dtype="<u2").reshape(height, width)
    r5 = (px >> 11) & 0x1F
    g6 = (px >> 5) & 0x3F
    b5 = px & 0x1F
    r8 = ((r5 << 3) | (r5 >> 2)).astype(np.uint8)
    g8 = ((g6 << 2) | (g6 >> 4)).astype(np.uint8)
    b8 = ((b5 << 3) | (b5 >> 2)).astype(np.uint8)
    return np.dstack([r8, g8, b8])


def fit_letterbox(png_path, width, height, pad_mode="auto", bg=None):
    """Scale the PNG to fit inside width x height (aspect kept), then pad the
    remainder to centre it.

    pad_mode:
      'auto'   flat fill, colour sampled as the mean of the image's four 8x8
               corner patches.  The gnome artwork is edge-to-edge (beanie tip
               touches the top edge, floor reflection the bottom), so mirrored
               padding replicates rendered content (visible upside-down beanie
               ghost); side-edge streaks would appear with gradient extension.
               A flat dark fill just below the backdrop brightness blends with
               the vignette and reads as "fading to black".
      'color'  flat fill with explicit --bg RRGGBB.
      'reflect' mirror edge rows/columns (only works for artwork with clean,
               featureless borders; requires pad < dimension).
    """
    src = Image.open(png_path).convert("RGB")
    sw, sh = src.size
    scale = min(width / sw, height / sh)
    fw = min(width, max(1, int(round(sw * scale))))
    fh = min(height, max(1, int(round(sh * scale))))
    resized = src.resize((fw, fh), Image.Resampling.LANCZOS)
    arr = np.asarray(resized, dtype=np.uint8)

    pt = (height - fh) // 2
    pb = height - fh - pt
    pl = (width - fw) // 2
    pr = width - fw - pl

    if pad_mode == "auto":
        a = arr.astype(np.float64)
        patches = [a[:8, :8], a[:8, -8:], a[-8:, :8], a[-8:, -8:]]
        mean = np.concatenate([p.reshape(-1, 3) for p in patches]).mean(axis=0)
        bg = "%02X%02X%02X" % tuple(int(round(v)) for v in mean)
        pad_mode = "color"
    if pad_mode == "color":
        if bg is None:
            raise FormatError("--pad-mode color requires --bg RRGGBB")
        canvas = np.zeros((height, width, 3), dtype=np.uint8)
        canvas[..., 0] = int(bg[0:2], 16)
        canvas[..., 1] = int(bg[2:4], 16)
        canvas[..., 2] = int(bg[4:6], 16)
        canvas[pt:pt + fh, pl:pl + fw] = arr
        return canvas, bg
    if pad_mode == "reflect":
        for v, lim in ((pt, fh), (pb, fh), (pl, fw), (pr, fw)):
            if v >= lim:
                raise FormatError("padding %d too large for reflect mode (dim=%d); use --pad-mode auto" % (v, lim))
        return np.pad(arr, ((pt, pb), (pl, pr), (0, 0)), mode="reflect"), bg
    raise FormatError("unknown pad mode %r" % pad_mode)


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #

def load_bin(path):
    data = open(path, "rb").read()
    hdr = parse_header(data)
    count, offsets, blobs = parse_payload(data[HEADER_SIZE:])
    return hdr, count, offsets, blobs


def cmd_info(args):
    hdr, count, offsets, blobs = load_bin(args.logo)
    raw_lens = [len(zlib.decompress(b)) for b in blobs]
    print("file            : %s (%d bytes)" % (args.logo, HEADER_SIZE + hdr["payload_size"]))
    print("magic           : 0x%08X  signature: %r" % (hdr["magic"], hdr["signature"]))
    print("payload size    : %d  header tail: 0xFF pad to 512" % hdr["payload_size"])
    print("image count     : %d (table %d bytes, first blob at %d)"
          % (count, 4 * count, offsets[0]))
    print("sha256          : %s" % hashlib.sha256(open(args.logo, "rb").read()).hexdigest())
    width = args.width if args.width else None
    for i, n in enumerate(raw_lens):
        tag = ""
        if width:
            full = args.height * args.width * 2
            if n == full:
                tag = " full %dx%d RGB565" % (args.width, args.height)
            elif full % n == 0 and n % 2 == 0:
                tag = " full frame, %d px rows" % (n // 2 // args.width if args.width else 0)
        print("  img%02d  comp=%6d  raw=%7d%s" % (i, len(blobs[i]), n, tag))
    return 0


def cmd_decode(args):
    hdr, count, offsets, blobs = load_bin(args.logo)
    if not (0 <= args.index < count):
        raise FormatError("index %d out of range (count=%d)" % (args.index, count))
    raw = zlib.decompress(blobs[args.index])
    w, h = args.width, args.height
    if args.dims:
        w, h = (int(v) for v in args.dims.lower().split("x"))
    elif len(raw) != w * h * 2:
        raise FormatError("layer %d is %d bytes; pass --dims WxH for non-full-screen layers"
                          % (args.index, len(raw)))
    arr = rgb565_decode(raw, w, h)
    Image.fromarray(arr).save(args.out)
    print("wrote %s (%dx%d from layer index %d)" % (args.out, w, h, args.index))
    return 0


def resolve_boot_indices(spec, count):
    if not spec or spec == "auto":
        return {0, count - 1}
    idx = set()
    for tok in spec.split(","):
        v = int(tok)
        if v == -1:
            v = count - 1
        if not (0 <= v < count):
            raise FormatError("boot index %d out of range" % v)
        idx.add(v)
    return idx


def make_splash_blob(png_path, width, height, pad_mode, bg, level):
    rgb, _bg = fit_letterbox(png_path, width, height, pad_mode, bg)
    return zlib.compress(rgb565_encode(rgb), level)


def cmd_pack(args):
    hdr, count, offsets, blobs = load_bin(args.reference)
    boot = resolve_boot_indices(args.boot_indices, count)
    splash = make_splash_blob(args.image, args.width, args.height, args.pad_mode, args.bg, args.zlib_level)
    if hdr["signature"] != b"LOGO":
        raise FormatError("reference is not a LOGO partition image: %r" % hdr["signature"])
    new_blobs = list(blobs)
    for i in sorted(boot):
        new_blobs[i] = splash
    payload = serialize_payload(new_blobs)
    out = build_header(len(payload), hdr["signature"]) + payload
    open(args.out, "wb").write(out)
    print("wrote %s: %d bytes  (reference %d bytes, splash blob %d compressed)"
          % (args.out, len(out), HEADER_SIZE + sum(len(b) for b in blobs), len(splash)))
    print("replaced indices %s; boot-logo duplication convention preserved"
          % ", ".join(str(i) for i in sorted(boot)))
    if args.preview:
        raw = zlib.decompress(splash)
        Image.fromarray(rgb565_decode(raw, args.width, args.height)).save(args.preview)
        print("preview: %s" % args.preview)
    return 0


def cmd_verify(args):
    ref_hdr, ref_count, _, ref_blobs = load_bin(args.reference)
    cand_hdr, cand_count, _, cand_blobs = load_bin(args.candidate)

    checks = []

    def check(name, ok, detail=""):
        checks.append((name, ok, detail))
        if not ok:
            raise FormatError("VERIFY FAILED: %s %s" % (name, detail))

    check("candidate magic", cand_hdr["magic"] == MTK_LOGO_MAGIC)
    check("candidate signature LOGO", cand_hdr["signature"] == b"LOGO")
    check("header size field", cand_hdr["payload_size"] == len(open(args.candidate, "rb").read()) - HEADER_SIZE)
    check("header 0xFF tail", set(open(args.candidate, "rb").read()[40:HEADER_SIZE]) == {PAD_BYTE})
    check("count matches reference", cand_count == ref_count, "%d vs %d" % (cand_count, ref_count))

    boot = resolve_boot_indices(args.boot_indices, cand_count)
    untouched = [i for i in range(cand_count) if i not in boot]
    for i in untouched:
        if cand_blobs[i] != ref_blobs[i]:
            raise FormatError("VERIFY FAILED: layer %d was modified (must stay byte-identical)" % i)
    check("non-boot layers byte-identical to reference", True, "%d layers" % len(untouched))

    splash_blobs = {cand_blobs[i] for i in boot}
    check("boot layers identical to each other", len(splash_blobs) == 1)
    splash = next(iter(splash_blobs))
    raw = zlib.decompress(splash)
    check("splash raw size", len(raw) == args.width * args.height * 2,
          "%d bytes" % len(raw))

    # canonical re-serialization must reproduce the candidate payload exactly
    payload = serialize_payload(cand_blobs)
    check("payload re-serialization byte-identical",
          payload == open(args.candidate, "rb").read()[HEADER_SIZE:])

    if args.image:
        expected = make_splash_blob(args.image, args.width, args.height, args.pad_mode, args.bg, args.zlib_level)
        check("splash == fresh encode of --image (determinism)", splash == expected,
              "candidate=%d fresh=%d sha=%s vs %s"
              % (len(splash), len(expected),
                 hashlib.sha256(splash).hexdigest()[:16], hashlib.sha256(expected).hexdigest()[:16]))

    print("VERIFY OK: %s" % args.candidate)
    for name, _, detail in checks:
        print("  [ok] %-46s %s" % (name, detail))
    payload_size = 8 + 4 * cand_count + sum(len(b) for b in cand_blobs)
    print("  file  : %d bytes (header 512 + payload %d)"
          % (HEADER_SIZE + payload_size, payload_size))
    print("  sha256: %s"
          % hashlib.sha256(open(args.candidate, "rb").read()).hexdigest())
    if args.preview:
        Image.fromarray(rgb565_decode(raw, args.width, args.height)).save(args.preview)
        print("  preview rendered to %s" % args.preview)
    return 0


def main(argv):
    p = argparse.ArgumentParser(description="MediaTek logo.bin packer/verifier (Q5)")
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("info", help="dump logo.bin structure")
    pi.add_argument("--logo", required=True)
    pi.add_argument("--width", type=int, default=None)
    pi.add_argument("--height", type=int, default=None)
    pi.set_defaults(func=cmd_info)

    pd = sub.add_parser("decode", help="render one layer to PNG")
    pd.add_argument("--logo", required=True)
    pd.add_argument("--index", type=int, required=True)
    pd.add_argument("--width", type=int, default=480)
    pd.add_argument("--height", type=int, default=800)
    pd.add_argument("--dims", default=None, help="WxH for non-full-screen layers")
    pd.add_argument("--out", required=True)
    pd.set_defaults(func=cmd_decode)

    pp = sub.add_parser("pack", help="build a logo.bin from PNG + reference")
    pp.add_argument("--image", required=True)
    pp.add_argument("--width", type=int, default=480)
    pp.add_argument("--height", type=int, default=800)
    pp.add_argument("--reference", required=True)
    pp.add_argument("--out", required=True)
    pp.add_argument("--boot-indices", default="auto", help="comma list or 'auto' (= 0,N-1); -1 = last")
    pp.add_argument("--pad-mode", default="auto", choices=("auto", "color", "reflect"))
    pp.add_argument("--bg", default=None, help="RRGGBB for --pad-mode color")
    pp.add_argument("--zlib-level", type=int, default=9)
    pp.add_argument("--preview")
    pp.set_defaults(func=cmd_pack)

    pv = sub.add_parser("verify", help="verify candidate against reference")
    pv.add_argument("--candidate", required=True)
    pv.add_argument("--reference", required=True)
    pv.add_argument("--width", type=int, default=480)
    pv.add_argument("--height", type=int, default=800)
    pv.add_argument("--boot-indices", default="auto")
    pv.add_argument("--image")
    pv.add_argument("--pad-mode", default="auto", choices=("auto", "color", "reflect"))
    pv.add_argument("--bg", default=None)
    pv.add_argument("--zlib-level", type=int, default=9)
    pv.add_argument("--preview")
    pv.set_defaults(func=cmd_verify)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except FormatError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    except BrokenPipeError:
        # e.g. `logo_pack.py info ... | head` - closing the pipe early is fine
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
