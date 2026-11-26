#!/usr/bin/env python3
"""Package BOOTIMG/ANDROID/LOGO only, asserting the known Q5 Mint layout.

Inputs must be backed-up/repacked Android boot, clean raw ext4 system, padded
LOGO, and the Mint reference scatter. Never flashes or repartitions anything.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile

LAYOUT = {
    'BOOTIMG': ('boot.img', 0x3180000, 0x1d80000, 0x1000000),
    'LOGO': ('logo.bin', 0x5800000, 0x4400000, 0x300000),
    'ANDROID': ('system.img', 0x6500000, 0x5100000, 0x33400000),
}

def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['boot', 'system', 'logo', 'scatter', 'out']:
        p.add_argument('--' + name, type=Path, required=True)
    a = p.parse_args()
    assert a.boot.stat().st_size == 0x1000000
    assert a.logo.stat().st_size == 0x300000
    assert a.system.stat().st_size <= 0x33400000
    with a.boot.open('rb') as f:
        assert f.read(8) == b'ANDROID!'
    with a.system.open('rb') as f:
        f.seek(1080)
        assert f.read(2) == b'\x53\xef', 'Expected raw ext4 image'
    text = a.scatter.read_text()
    assert 'platform: MT6582' in text
    sections = re.split(r'(?m)(?=^- partition_index:)', text)
    enabled = []
    for i in range(1, len(sections)):
        section = sections[i]
        fields = dict(re.findall(r'^\s+(\w+):\s*(\S+)', section, re.M))
        name = fields['partition_name']
        filename = 'NONE'
        if name in LAYOUT:
            filename, linear, physical, size = LAYOUT[name]
            assert int(fields['linear_start_addr'], 0) == linear, name
            assert int(fields['physical_start_addr'], 0) == physical, name
            assert int(fields['partition_size'], 0) == size, name
            enabled.append(name)
        section = re.sub(r'(?m)^(  file_name:).*$', r'\1 ' + filename, section)
        section = re.sub(r'(?m)^(  is_download:).*$', r'\1 ' + ('true' if filename != 'NONE' else 'false'), section)
        sections[i] = section
    assert sorted(enabled) == sorted(LAYOUT)
    a.out.mkdir(parents=True)  # Refuse to overwrite an existing package.
    for src, name in [(a.boot, 'boot.img'), (a.system, 'system.img'), (a.logo, 'logo.bin')]:
        shutil.copyfile(src, a.out / name)
    (a.out / 'MT6582_Android_scatter.txt').write_text(''.join(sections))
    (a.out / 'README.txt').write_text('''Q5 Mint / MT6582 Lithium 7 DEVELOPMENT CHECKPOINT

Camera remains unresolved. This is not a fully functional release.
Only for the specific Mint-style Q5 hardware investigated in this fork.
Do not use on another Q5 revision, including MT6580/MT6735 devices.

Known working: display/touch, physical Home, speaker and wired headphones.
Tap Home, double-tap Back, hold Recent Apps; on-screen buttons stay visible.
Gnome boot/default wallpaper. Jelly and HTMLViewer browser apps removed.
Unused Lawnfeed update/install prompts disabled. Open Camera is included,
but Android currently detects zero cameras. Xposed cleanup is pending.

Use SP Flash Tool DOWNLOAD ONLY with the included scatter. Only BOOTIMG,
ANDROID and LOGO are selected. Do not enable additional partitions or choose
Format All / Firmware Upgrade. No preloader, partition table, userdata,
recovery, NVRAM or calibration images are included.

System image derives from a read-only snapshot of the tested live system,
cleaned on a separate copy with e2fsck. This is not a clean-install validation.
Installing this package does not reset existing user preferences or apps.
Browser removal is not a complete parental-control or network-filtering system.

Source and detailed limits:
https://github.com/yetisoldier/timmkoo-q5-lithium7-fork
See CURRENT-STATUS.md on the codex/q5-hardware-bringup branch.
''')
    files = sorted(p for p in a.out.iterdir() if p.is_file())
    manifest = {p.name: {'bytes': p.stat().st_size, 'sha256': sha(p)} for p in files}
    (a.out / 'SHA256SUMS').write_text(''.join(f'{v["sha256"]}  {k}\n' for k, v in manifest.items()))
    (a.out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    archive = a.out.with_suffix('.zip')
    assert not archive.exists()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(a.out.iterdir()):
            z.write(path, path.name)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
    archive.with_suffix('.zip.sha256').write_text(sha(archive) + '  ' + archive.name + '\n')
    print(archive)

if __name__ == '__main__':
    main()
