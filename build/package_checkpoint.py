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
import struct
import gzip
from patch_fm_boot_node import entries
from q5_runtime_defaults import disable_service

ROOT = Path(__file__).resolve().parents[1]

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
    p.add_argument('--release-version', help='Package a named official release')
    a = p.parse_args()
    assert a.boot.stat().st_size == 0x1000000
    assert a.logo.stat().st_size == 0x300000
    assert a.system.stat().st_size <= 0x33400000
    with a.boot.open('rb') as f:
        assert f.read(8) == b'ANDROID!'
    boot = a.boot.read_bytes()
    _, ksz, _, rsz, _, _, _, _, page, _, _ = struct.unpack_from('<8s10I', boot)
    roff = page + (ksz + page - 1) // page * page
    ramdisk = gzip.decompress(boot[roff + 512:roff + rsz])
    init = next(data for name, data, *_ in entries(ramdisk) if name.lstrip('./') == 'init.mt6582.rc')
    assert b'mknod /dev/fm c 193' not in init, 'Apply patch_fm_boot_node.py before packaging'
    assert b'on property:init.svc.mediacodec=running' in init and b'q5-codec-limits.sh' in init, 'Apply patch_codec_boot.py before packaging'
    modem = next(data for name, data, *_ in entries(ramdisk) if name.lstrip('./') == 'init.modem.rc')
    for name in ['ccci_fsd', 'ccci_mdinit']:
        assert disable_service(modem, name) == modem, 'Apply patch_wifi_only_boot.py before packaging'
    usb = next(data for name, data, *_ in entries(ramdisk) if name.lstrip('./') == 'init.mt6582.usb.rc')
    for mode in [b'mtp', b'mtp,adb']:
        action = re.search(rb'(?ms)^on property:sys.usb.config=' + mode + rb'\n.*?(?=^on |\Z)', usb)
        assert action and b'mass_storage' not in action[0], 'Apply patch_usb_boot.py before packaging'
    with a.system.open('rb') as f:
        f.seek(1080)
        assert f.read(2) == b'\x53\xef', 'Expected raw ext4 image'
    system_manifest_path = a.system.with_suffix('.json')
    system_manifest = json.loads(system_manifest_path.read_text())
    assert system_manifest['output_sha256'] == sha(a.system), 'System differs from its defaults-build manifest'
    if a.release_version:
        assert re.fullmatch(r'\d+\.\d+\.\d+', a.release_version)
        assert system_manifest['release_version'] == a.release_version
        assert '/etc/q5-release.json' in system_manifest['changes']
    for required in ['/etc/q5-codec-limits.sh', '/lib/libq5.so',
                     '/lib/libvcodec_utility.so', '/etc/media_codecs.xml',
                     '/priv-app/CMParts/CMParts.apk',
                     '/priv-app/Q5FMRadio/Q5FMRadio.apk',
                     '/app/Q5AudioRecorder/Q5AudioRecorder.apk',
                     '/app/webview/webview.apk']:
        assert required in system_manifest['changes'], required
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
    shutil.copyfile(system_manifest_path, a.out / 'system-build.json')
    (a.out / 'MT6582_Android_scatter.txt').write_text(''.join(sections))
    (a.out / 'README.txt').write_text('''Q5 Mint / MT6582 Lithium 7 DEVELOPMENT CHECKPOINT

Development checkpoint: see CURRENT-STATUS.md for remaining physical tests.
Only for the specific Mint-style Q5 hardware investigated in this fork.
Do not use on another Q5 revision, including MT6580/MT6735 devices.

Known working: display/touch, physical Home, speaker and wired headphones.
Tap Home, double-tap Back, hold Recent Apps. On-screen buttons default visible;
change Settings > Buttons > Show navigation buttons to hide/show them.
Gnome boot/default wallpaper. Jelly and HTMLViewer browser apps removed.
Unused Lawnfeed update/install prompts disabled. Open Camera and Xposed
Installer removed. Camera omitted per purchase evidence; no fitted sensor is
confirmed. Lineage FM receiver and Audio Recorder included. USB MTP transfer fixed.
FM reception on 93.7 through wired headphones is user-confirmed. Headphones
serve as the antenna. Bluetooth audio remains a physical test.
Hardware H.264 720p playback restored; the 1080p test uses software fallback.
Embedded WebView 119 fixes Audiobookshelf's collapsed server connection controls.
Audiobookshelf, Plexamp and Apple Music are separate test installations in
userdata and are not bundled in this system image.

Use SP Flash Tool DOWNLOAD ONLY with the included scatter. Only BOOTIMG,
ANDROID and LOGO are selected. Do not enable additional partitions or choose
Format All / Firmware Upgrade. No preloader, partition table, userdata,
recovery, NVRAM or calibration images are included.

System image is generated from a read-only development-system snapshot with
the reproducible defaults/media changes applied to a separate copy. Filesystem
checks passed. This is not a factory-reset/clean-install validation.
Installing this package does not reset existing user preferences or apps.
Browser removal is not a complete parental-control or network-filtering system.

Source and detailed limits:
https://github.com/yetisoldier/timmkoo-q5-lithium7-fork
See CURRENT-STATUS.md on the codex/q5-hardware-bringup branch.
''')
    if a.release_version:
        guide = (ROOT / 'docs/INSTALL.md').read_text(encoding='utf-8')
        (a.out / 'README.txt').write_text(
            'Lithium 7 for Q5 Gen 7 (Q5 Mint) v' + a.release_version + '\n\n' + guide,
            encoding='utf-8')
        shutil.copyfile(ROOT / 'README.md', a.out / 'README.md')
        shutil.copyfile(ROOT / 'THIRD-PARTY-NOTICES.md', a.out / 'THIRD-PARTY-NOTICES.md')
        shutil.copyfile(ROOT / 'build/install_adb_recovery.py', a.out / 'install-adb-recovery.py')
        shutil.copytree(ROOT / 'docs', a.out / 'docs')
    files = sorted(p for p in a.out.rglob('*') if p.is_file())
    manifest = {p.relative_to(a.out).as_posix(): {'bytes': p.stat().st_size, 'sha256': sha(p)} for p in files}
    (a.out / 'SHA256SUMS').write_text(''.join(f'{v["sha256"]}  {k}\n' for k, v in manifest.items()))
    (a.out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    archive = Path(str(a.out) + '.zip')
    assert not archive.exists()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(a.out.rglob('*')):
            if path.is_file():
                z.write(path, path.relative_to(a.out).as_posix())
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
    archive.with_suffix('.zip.sha256').write_text(sha(archive) + '  ' + archive.name + '\n')
    print(archive)

if __name__ == '__main__':
    main()
