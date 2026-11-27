#!/usr/bin/env python3
"""Encode existing artwork for the Q5 splash, boot display and wallpaper.

No artwork is generated: the original is aspect-fitted using logo_pack's
existing conversion. Only the two boot layers and default wallpaper drawables
change; other logo layers and APK entry contents are verified unchanged.
"""
import argparse
import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import zipfile
import zlib

from PIL import Image
import logo_pack


def build(source, reference_logo, framework, out):
    out.mkdir(parents=True, exist_ok=True)
    rgb, background = logo_pack.fit_letterbox(source, 480, 800)
    image = Image.fromarray(rgb)
    stream = io.BytesIO()
    image.save(stream, format='PNG', optimize=True)
    png = stream.getvalue()
    (out / 'gnome-480x800.png').write_bytes(png)

    header, count, _, original = logo_pack.load_bin(reference_logo)
    assert header['signature'] == b'LOGO' and count == 39
    blobs = list(original)
    splash = zlib.compress(logo_pack.rgb565_encode(rgb), 9)
    for index in (0, count - 1):
        blobs[index] = splash
    payload = logo_pack.serialize_payload(blobs)
    logo = logo_pack.build_header(len(payload), b'LOGO') + payload
    assert len(logo) <= 0x300000
    (out / 'logo-gnome.bin').write_bytes(logo)
    (out / 'logo-gnome.partition').write_bytes(logo + bytes(0x300000 - len(logo)))
    (out / 'wallpaper_info.xml').write_text(
        '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n'
        '<wp id="3" width="480" height="800" cropLeft="0" cropTop="0" '
        'cropRight="480" cropBottom="800" name="" />\n')
    _, _, _, checked = logo_pack.load_bin(out / 'logo-gnome.bin')
    assert all(checked[i] == original[i] for i in range(count) if i not in (0, count - 1))

    with zipfile.ZipFile(out / 'bootanimation.zip', 'w', compression=zipfile.ZIP_STORED) as boot:
        for name, data in [('desc.txt', b'480 800 30\np 0 0 part0\n'), ('part0/00000.png', png)]:
            entry = zipfile.ZipInfo(name, (2026, 11, 26, 0, 0, 0))
            entry.external_attr = 0o100644 << 16
            boot.writestr(entry, data)

    replacements = []
    with zipfile.ZipFile(framework) as before, zipfile.ZipFile(out / 'framework-res.apk', 'w') as after:
        for original_entry in before.infolist():
            entry = copy.copy(original_entry)
            data = before.read(entry.filename)
            if Path(entry.filename).name == 'default_wallpaper.png':
                data = png
                replacements.append(entry.filename)
            # Keep stored entries 4-byte aligned, including resources.arsc.
            if entry.compress_type == zipfile.ZIP_STORED:
                entry.extra = b''
                base = after.fp.tell() + 30 + len(entry.filename.encode('utf-8'))
                if base % 4:
                    padding = (-base - 4) % 4
                    entry.extra = struct.pack('<HH', 0xffff, padding) + bytes(padding)
            after.writestr(entry, data)
    assert replacements, 'no framework default wallpaper resources found'
    with zipfile.ZipFile(framework) as before, zipfile.ZipFile(out / 'framework-res.apk') as after:
        assert before.namelist() == after.namelist()
        changed = [name for name in before.namelist() if before.read(name) != after.read(name)]
        assert changed == replacements
        assert after.testzip() is None
        for name in replacements:
            assert Image.open(io.BytesIO(after.read(name))).size == (480, 800)

    manifest = {
        'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'framework_source_sha256': hashlib.sha256(framework.read_bytes()).hexdigest(),
        'background': '#' + background,
        'size': [480, 800],
        'logo_layers_replaced': [0, count - 1],
        'framework_entries_replaced': replacements,
        'note': 'Existing system APK certificate metadata retained; no APK re-signing.',
    }
    manifest['sha256'] = {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                          for name in ['gnome-480x800.png', 'logo-gnome.bin',
                                       'bootanimation.zip', 'framework-res.apk']}
    (out / 'branding-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--reference-logo', required=True, type=Path)
    parser.add_argument('--framework', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    build(args.source, args.reference_logo, args.framework, args.out)
