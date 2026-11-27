#!/usr/bin/env python3
"""Adapt the pinned Mint FM app for Nougat and the 3.10 FM ioctl ABI.

Requires Java, git, verified smali-tools, and a local development signing key.
The key stays outside the repository. Does not install or flash anything.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile
from patch_mint_fm_backend import patch

ROOT = Path(__file__).resolve().parents[1]
DONORS = {
    'FMRadio.apk': 'd6afbfa136782b8384b67e7d035d7441fac0d6fed9c6d3fa0f05ce1b017fb1e5',
    'libfmjni.so': '00813d390507050edaf70e40acb11391cef2ee304e19a6125143c1d38d46e3d4',
    'libfmcust.so': '890cbda18095086e8e59af456dc1a9ee37dc165d3dc84eaff58ce259f9f5e8db',
    'libfmmt6627.so': '5c735b833d85719af4d7866346db7b3e9025a078f0df1466ae8fa4493316de53',
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ['donors', 'out', 'tools', 'keystore']:
        p.add_argument('--' + arg, type=Path, required=True)
    p.add_argument('--alias', default='q5-development')
    a = p.parse_args()
    a.out = a.out.resolve()
    a.tools = a.tools.resolve()
    assert a.keystore.is_file(), 'Local development key required (password android)'
    for name, expected in DONORS.items():
        assert sha(a.donors / name) == expected, name
    for row in json.loads((ROOT / 'manifests/smali-tools.json').read_text()):
        assert sha(a.tools / row['name']) == row['sha256'], row['name']
    a.out.mkdir(parents=True)
    original = a.donors / 'FMRadio.apk'
    dex = a.out / 'original.dex'
    with zipfile.ZipFile(original) as z:
        dex.write_bytes(z.read('classes.dex'))
    smali = a.out / 'smali'
    cp = str(a.tools / '*')
    run('java', '-cp', cp, 'org.jf.baksmali.Main', 'd', '-j', '1', '-a', '17', dex, '-o', smali)
    for name in ['A1-mint-fm-nougat-compat.patch', 'A2-mint-fm-registration-companion.patch',
                 'A3-mint-fm-media-stream.patch']:
        path = ROOT / 'patches/apps' / name
        run('git', 'apply', '--check', path, cwd=smali)
        run('git', 'apply', path, cwd=smali)
    modified = a.out / 'classes.dex'
    run('java', '-cp', cp, 'org.jf.smali.Main', 'a', '-j', '1', '-a', '25', smali, '-o', modified)
    libraries = {
        'libq5mintfmjni.so': (a.donors / 'libfmjni.so').read_bytes(),
        'libfmcust.so': (a.donors / 'libfmcust.so').read_bytes(),
        'libfmmt6627.so': patch((a.donors / 'libfmmt6627.so').read_bytes()),
    }
    unsigned = a.out / 'FMRadio-unsigned.apk'
    old = 'android.permission.ACCESS_MTK_MMHW'.encode('utf-16le')
    new = 'android.permission.ACCESS_FM_RADIO'.encode('utf-16le')
    assert len(old) == len(new)
    with zipfile.ZipFile(original) as before, zipfile.ZipFile(unsigned, 'w') as after:
        for info in before.infolist():
            if info.filename.startswith(('META-INF/', 'lib/')):
                continue
            data = before.read(info)
            if info.filename == 'classes.dex':
                data = modified.read_bytes()
            elif info.filename == 'AndroidManifest.xml':
                assert data.count(old) == 1
                data = data.replace(old, new)
            after.writestr(copy.copy(info), data)
        for name, data in libraries.items():
            info = zipfile.ZipInfo('lib/armeabi-v7a/' + name, (2026, 11, 26, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            after.writestr(info, data)
    output = a.out / 'FMRadio.apk'
    run('jarsigner', '-keystore', a.keystore.resolve(), '-storepass', 'android', '-keypass', 'android',
        '-signedjar', output, unsigned, a.alias)
    run('jarsigner', '-verify', output)
    with zipfile.ZipFile(output) as z:
        assert z.testzip() is None
        for name, data in libraries.items():
            assert z.read('lib/armeabi-v7a/' + name) == data
    manifest = {'donors': DONORS, 'sha256': sha(output),
                'native_sha256': {n: hashlib.sha256(b).hexdigest() for n, b in libraries.items()},
                'note': 'Install as a privileged system app to grant ACCESS_FM_RADIO (media GID).'}
    (a.out / 'fm-build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
