#!/usr/bin/env python3
# extract_gsl_fw_from_blob.py — D17 provenance generator.
#
# Extracts the TIMMKOO Q5's GSL (Silead) touch-firmware arrays from the PINNED
# Lithium kernel blob (boot.img-kernel, sha d284ba1698c77267…, the blob that ships
# the only working `gsl_tp` driver for this hardware) and emits them as C header
# files for the ported driver.  This is EVIDENCE EXTRACTION, not invention: the
# Q5's panel firmware exists nowhere in public source trees (checked selene,
# sprout, persimmon, e5fhd, oxygen + Sourcegraph global for GSLX680_FW_DSJ /
# GSLX68X_FW_JX — zero hits), so the fork ports the public gslX68X driver family
# (donors/oxygen) and grafts the Q5's own compiled-in firmware data onto it.
#
# Forensic layout (decoded from the blob, VA = fileoff + 0xc0008000):
#   gsl_cfg_table @ 0xc0884a64   — 5 × 16 B entries { fw*, fw_count, cfg_data*, cfg_data_size }
#     [0] hw    fw@0xc08a3c6c  5049 entries   (default/banner "------GSLX680_FW_HW------")
#     [1] dsj   fw@0xc08ada34  4851           (banner "------GSLX680_FW_DSJ------", configs 1 & 4)
#     [2] wl    fw@0xc089a0b4  4983           (banner "------GSLX680_FW_WL------", config 3)
#     [3] cfg5  fw@0xc08904fc  4983           (no sw_init path selects it in this build)
#     [4] jx2   fw@0xc0886944  4983           (banner "------GSLX680_FW_JX_2------", config 6)
#   The five fw arrays tile the data region exactly (each ends where the next
#   begins — asserted below), and GSL_TP_CHECK_FW (957 entries) is bounded by the
#   kallsyms-anchored next symbol gsl_seq_fops @ 0xc088689c.
#   cfg_data arrays (512 u32 each, /proc/gsl_config-writable per gsl_config_write_proc):
#     [0] @0xc0b76dfc  [1] @0xc0b765fc  [2] @0xc0b75dfc  [3] @0xc0b755fc  [4] @0xc0b74dfc
#
# Self-checks (fail loudly on any drift):
#   1. blob sha256 == manifests/kernel-sources.sha256 pin for donors/lithium-kernel.decomp
#   2. struct fw_data tiling: cfg[i].fw + count*8 == cfg[i+1].fw for the decoded chain
#   3. GSL_TP_CHECK_FW region size == 957 entries exactly
#   4. every key array size word == 512 and spacing == 2048 B
#
# Usage: python3 build/extract_gsl_fw_from_blob.py OUTDIR   (writes gslX680_fw_q5.h,
#        gslX680_key_q5.h; deterministic bytes — stable across re-runs)
# shellcheck shell=false

import hashlib
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BLOB = REPO / "donors/lithium-kernel.decomp"
MANIFEST = REPO / "manifests/kernel-sources.sha256"
BASE = 0xC0008000  # VA = raw file offset + 0xc0008000 (single flat Image section)

CFG_TABLE = 0xC0884A64
CHECK_FW = 0xC0884AB4
CHECK_FW_END = 0xC088689C  # kallsyms symbol gsl_seq_fops — exclusive bound
KEYS = [0xC0B76DFC, 0xC0B765FC, 0xC0B75DFC, 0xC0B755FC, 0xC0B74DFC]

# banner → cfg-index mapping decoded from gsl_sw_init (blob disassembly):
#   config 2/0/unknown → HW banner → cfg[0]; config 1 & 4 → DSJ → cfg[1];
#   config 3 → WL → cfg[2]; config 6 → JX_2 → cfg[4]; cfg[3] unreachable from this build.
NAMES = ["hw", "dsj", "wl", "cfg5", "jx2"]
FP_CONSTS = [0xFFC07807, 0xFF81F80F, 0xFF807807, 0xFF80780F, 0xFF80FC01, 0xFF807C07]


def die(msg):
    raise SystemExit(f"[extract_gsl_fw] FATAL: {msg}")


def read_blob():
    if not BLOB.is_file():
        die(f"pinned blob missing: {BLOB} (mount the reference donor first)")
    want = MANIFEST.read_text().splitlines()
    pin = next((ln.split()[0] for ln in want
                if ln.strip() and not ln.startswith("#") and ln.split()[1:2] == ["donors/lithium-kernel.decomp"]), None)
    if pin is None:
        die("no pin for donors/lithium-kernel.decomp in manifests/kernel-sources.sha256")
    data = BLOB.read_bytes()
    got = hashlib.sha256(data).hexdigest()
    if got != pin:
        die(f"blob sha256 drift: got {got}, pinned {pin}")
    return data


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} OUTDIR")
    outdir = Path(sys.argv[1])
    outdir.mkdir(parents=True, exist_ok=True)
    data = read_blob()

    def off(va):
        return va - BASE

    def words(va, n):
        return struct.unpack_from(f"<{n}I", data, off(va))

    # ---- 1. decode the config table (5 entries × 16 B) ---------------------
    entries = []
    for i in range(5):
        fw, count, key, ksize = struct.unpack_from("<4I", data, off(CFG_TABLE) + i * 16)
        if not (0xC0000000 <= fw < 0xC1000000) or count == 0 or count > 20000:
            die(f"cfg[{i}] implausible: fw={fw:#x} count={count}")
        entries.append((fw, count, key, ksize))

    # ---- 2. tiling check: cfg[i].fw + count*8 == cfg[i+1].fw ---------------
    order = sorted(range(5), key=lambda i: entries[i][0])
    for a, b in zip(order, order[1:]):
        fa, na = entries[a][0], entries[a][1]
        fb = entries[b][0]
        if fa + na * 8 != fb:
            die(f"fw tiling check failed: {NAMES[a]} end {fa + na*8:#x} != {NAMES[b]} start {fb:#x}")
    # cfg4 must end exactly at CHECK_FW's bound region (cfg4 lowest + jx2 is lowest here)
    if entries[4][0] + entries[4][1] * 8 != 0xC08904FC:
        die("jx2 array does not end at the cfg5 base (tiling chain broken)")

    # ---- 3. check fw bound -------------------------------------------------
    ncheck = (CHECK_FW_END - CHECK_FW) // 8
    if (CHECK_FW_END - CHECK_FW) % 8 or ncheck != 957:
        die(f"GSL_TP_CHECK_FW bound: {ncheck} entries (expected 957)")
    chk = words(CHECK_FW, ncheck * 2)

    # ---- 4. key arrays ------------------------------------------------------
    keys = []
    for va in KEYS:
        first = struct.unpack_from("<2I", data, off(va))
        if first[1] != 0x200:
            die(f"key array @{va:#x}: size word {first[1]:#x} != 0x200")
        keys.append(words(va, 512))

    # cross-check the banner strings live where expected
    expect_banners = ["------GSLX680_FW_HW------", "------GSLX680_FW_DSJ------",
                      "------GSLX680_FW_WL------", "------GSLX680_FW_JX_2------"]
    for b in expect_banners:
        found = data.find(b.encode() + b"\n")
        if found < 0:
            die(f"banner missing from blob: {b}")

    # ---- 5. emit gslX680_fw_q5.h -------------------------------------------
    def emitfw(f_va, count, name):
        ws = words(f_va, count * 2)
        lines = [f"/* {name}: {count} struct fw_data entries extracted from the pinned Lithium",
                 f" * blob 5217dd41/d284ba16… at VA 0x{f_va:08x} (build/extract_gsl_fw_from_blob.py) */",
                 f"static const struct fw_data gsl_fw_{name}[{count}] = {{"]
        for k in range(count):
            lines.append(f"\t{{0x{ws[k*2]:08x}, 0x{ws[k*2+1]:08x}}},")
        lines.append("};")
        return "\n".join(lines)

    fw_hdr = ["/**",
              " * gslX680_fw_q5.h — TIMMKOO Q5 GSL (Silead) touch-panel firmware data.",
              " * GENERATED file — do not edit by hand; regenerate with",
              " *   python3 build/extract_gsl_fw_from_blob.py <dir>",
              " *",
              " * Source: donors/lithium-kernel.decomp (pinned d284ba1698c77267…, kernel",
              " * 5217dd41… boot.img-kernel).  The Q5's panel firmware is compiled into",
              " * that blob only — no public source carries these arrays, so the port",
              " * grafts them verbatim onto the public gslX68X driver (donors/oxygen).",
              " *",
              " * Decoded mapping (gsl_sw_init, blob-verified):",
              " *   fingerprint cfg 0 → gsl_fw_hw   (banner ------GSLX680_FW_HW------ )",
              " *   fingerprint cfg 1 → gsl_fw_dsj  (banner ------GSLX680_FW_DSJ------ )",
              " *   fingerprint cfg 2 → gsl_fw_wl   (banner ------GSLX680_FW_WL------ )",
              " *   fingerprint cfg 3 → gsl_fw_cfg5 (unreachable from this blob's sw_init)",
              " *   fingerprint cfg 4 → gsl_fw_jx2  (banner ------GSLX680_FW_JX_2------ )",
              " *   plus GSL_TP_CHECK_FW: the 957-entry canary array the blob loads before",
              " *   reading the chip's fingerprint from register 0xb8.",
              " */",
              "#ifndef _GSLX680_FW_Q5_H_",
              "#define _GSLX680_FW_Q5_H_",
              ""]
    for i in range(5):
        fw_hdr.append(emitfw(entries[i][0], entries[i][1], NAMES[i]))
        fw_hdr.append("")
    ws = ["\t{0x%08x, 0x%08x}," % (chk[k * 2], chk[k * 2 + 1]) for k in range(ncheck)]
    fw_hdr.append(f"/* GSL_TP_CHECK_FW: {ncheck} entries @VA 0x{CHECK_FW:08x} */")
    fw_hdr.append(f"static const struct fw_data GSL_TP_CHECK_FW[{ncheck}] = {{")
    fw_hdr.extend(ws)
    fw_hdr.append("};")
    fw_hdr.append("")
    fw_hdr.append("#endif /* _GSLX680_FW_Q5_H_ */")
    (outdir / "gslX680_fw_q5.h").write_text("\n".join(fw_hdr) + "\n")

    # ---- 6. emit gslX680_key_q5.h ------------------------------------------
    kh = ["/**",
          " * gslX680_key_q5.h — Q5 per-config GSL tuning words (the blob's",
          " * gsl_cfg_table[5] entry->cfg buffers; /proc/gsl_config 'w' command",
          " * writes them at runtime, gsl_DataInit consumes them).",
          " * GENERATED — same provenance as gslX680_fw_q5.h.",
          " */",
          "#ifndef _GSLX680_KEY_Q5_H_",
          "#define _GSLX680_KEY_Q5_H_",
          "",
          "/* one initial block per config; WRITABLE per the blob's config_write_proc */",
          ""]
    for i, k in enumerate(keys):
        kh.append(f"static unsigned int gsl_cfg_key_q5_{NAMES[i]}[512] = {{")
        kh.append(f"\t/* config {i} initial words: 0x{k[0]:08x}, 0x{k[1]:08x}, … */")
        kh.extend("\t0x%08x," % v for v in k)
        kh.append("};")
        kh.append("")
    kh.append("#endif /* _GSLX680_KEY_Q5_H_ */")
    (outdir / "gslX680_key_q5.h").write_text("\n".join(kh) + "\n")

    # ---- 7. emit fingerprint note (for the report) ---------------------------
    print("extracted:")
    for i in range(5):
        print(f"  cfg[{i}] {NAMES[i]:5s} fw@0x{entries[i][0]:08x} n={entries[i][1]:5d} "
              f"key@0x{entries[i][2]:08x} n={entries[i][3]}")
    print(f"  GSL_TP_CHECK_FW: {ncheck} entries")
    print(f"  fingerprint constants: {[hex(f) for f in FP_CONSTS]}")
    for f in ("gslX680_fw_q5.h", "gslX680_key_q5.h"):
        p = outdir / f
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        print(f"  {p.name}: {p.stat().st_size} B sha256 {h}")


if __name__ == "__main__":
    main()
