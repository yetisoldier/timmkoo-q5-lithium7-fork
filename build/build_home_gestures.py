#!/usr/bin/env python3
"""Add native Back action 13, Q5 Home defaults and the launcher feed fix.

Requires Java and git. Downloads hash-pinned smali 2.5.2 tooling from Maven.
Inputs are read only. Outputs preserve every non-dex ZIP entry byte-for-byte.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INPUTS = {
    'services.jar': ('9343de13b41612570f3ac1b4ae8dd8ad35d14d93218edc5e5d7dbf744ea29e9e', ['F1-home-policy.patch']),
    'CMParts.apk': ('2cebb14ea9e258f88db500fc5a75b243a443260c8b8a2508944f32f8850bc6ea', ['F2-home-action-enum.patch', 'F3-home-settings-ui.patch', 'F7-user-navigation-switch.patch']),
    'org.cyanogenmod.platform.jar': ('12cb612844aacc7c605bed83205c301870c88e750d78b3f63f3205788692a496', ['F4-home-settings-validator.patch']),
    'CMSettingsProvider.apk': ('e30c540e746e0d1900f1ff4c3c10a516578f2cba47ee23033cc2ed3bb2ae8079', ['F5-home-provider-validator.patch']),
    'Lawnchair.apk': ('69c0b465dbad6b397b059d87be3a4ad579085d5a257f0f829a2ff087720d52f7', ['F6-disable-unused-lawnfeed-prompts.patch']),
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--tools', type=Path, required=True)
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.tools = args.tools.resolve()
    args.tools.mkdir(parents=True, exist_ok=True)
    args.out.mkdir(parents=True, exist_ok=True)
    for item in json.loads((ROOT / 'manifests/smali-tools.json').read_text()):
        path = args.tools / item['name']
        if not path.exists():
            urllib.request.urlretrieve(item['url'], path)
        assert digest(path) == item['sha256'], path
    classpath = str(args.tools / '*')
    manifest = {}
    for name, (expected, patches) in INPUTS.items():
        src = args.inputs / name
        assert digest(src) == expected, f'Wrong framework donor: {src}'
        work = args.out / (name + '.work')
        work.mkdir()  # Never overwrite an existing build.
        dex = work / 'original.dex'
        with zipfile.ZipFile(src) as z:
            dex.write_bytes(z.read('classes.dex'))
        smali = work / 'smali'
        run('java', '-cp', classpath, 'org.jf.baksmali.Main', 'd', '-j', '1', '-a', '25', dex, '-o', smali)
        for patch in patches:
            run('git', 'apply', '--check', ROOT / 'patches/framework' / patch, cwd=smali)
            run('git', 'apply', ROOT / 'patches/framework' / patch, cwd=smali)
        patched = work / 'patched.dex'
        run('java', '-cp', classpath, 'org.jf.smali.Main', 'a', '-j', '1', '-a', '25', smali, '-o', patched)
        out = args.out / name
        with zipfile.ZipFile(src) as before, zipfile.ZipFile(out, 'w') as after:
            for entry in before.infolist():
                data = patched.read_bytes() if entry.filename == 'classes.dex' else before.read(entry)
                after.writestr(copy.copy(entry), data)
        with zipfile.ZipFile(src) as before, zipfile.ZipFile(out) as after:
            assert after.testzip() is None
            assert before.namelist() == after.namelist()
            assert [n for n in before.namelist() if before.read(n) != after.read(n)] == ['classes.dex']
        manifest[name] = {'input_sha256': expected, 'output_sha256': digest(out), 'patches': patches}
    (args.out / 'home-gestures-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
