#!/usr/bin/env python3
"""Build pinned Q5 MT6582 H.264 compatibility files under Linux/WSL.

No flashing. Original Lithium inputs plus the two small T-ROM dependency
libraries are hash-checked; the output manifest is consumed by system defaults.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
COMPILER = 'e10a2d065a8b2c06508f49962735e8e69d9f19c0a5b8c34d846f6f722f88226a'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'compiler', 'out']:
        p.add_argument('--' + name, type=Path, required=True)
    a = p.parse_args()
    pins = json.loads((ROOT / 'manifests/media-compat-donors.json').read_text())
    for name, expected in pins.items():
        assert sha(a.inputs / name) == expected, name
    assert sha(a.compiler) == COMPILER, 'Use the pinned ARM EABI 4.8 compiler'
    a.out.mkdir(parents=True)  # Never overwrite a previous build.
    for name in ['libmhalImageCodec.so', 'libmmprofile.so']:
        shutil.copyfile(a.inputs / name, a.out / name)
    data = (a.inputs / 'libMtkOmxVdec.so').read_bytes()
    old, new = b'libmmprofile.so\0', b'libq5.so\0'
    assert data.count(old) == 1
    (a.out / 'libMtkOmxVdec.so').write_bytes(data.replace(old, new + bytes(len(old)-len(new))))
    data = (a.inputs / 'libvcodec_utility.so').read_bytes()
    old, new = b'libm4u.so\0', b'libq5.so\0'
    assert data.count(old) == 1
    data = data.replace(old, new + bytes(len(old)-len(new)))
    for suffix in [b'13m4u_alloc_mvaEijjiiPj', b'15m4u_dealloc_mvaEijjj']:
        old = b'_ZN9MTKM4UDrv' + suffix
        new = b'_ZN9Q5KM4UDrv' + suffix
        assert data.count(old) == 1
        data = data.replace(old, new)
    (a.out / 'libvcodec_utility.so').write_bytes(data)
    # Restore caller-controlled codec preference. Lithium forces software for
    # every MIME except its special _cam suffix; keep the existing suffix path.
    data = bytearray((a.inputs / 'libstagefright.so').read_bytes())
    assert data[0xc14de:0xc14e2] == bytes.fromhex('45f00105')  # orr r5,r5,#1
    data[0xc14de:0xc14e2] = bytes.fromhex('00bf00bf')          # nop; nop
    (a.out / 'libstagefright.so').write_bytes(data)
    subprocess.run([str(a.compiler.resolve()), '-shared', '-nostdlib', '-fPIC', '-O2',
                    '-Wl,-soname,libq5.so', '-Wl,--no-as-needed',
                    str(ROOT / 'build/media/q5-omx-compat.c'),
                    str((a.inputs / 'libmmprofile.so').resolve()),
                    str((a.inputs / 'libm4u.so').resolve()),
                    '-o', str((a.out / 'libq5.so').resolve())], check=True)
    text = (a.inputs / 'media_codecs.xml').read_text()
    assert text.count('    <Decoders>\n') == 1
    assert 'OMX.MTK.VIDEO.DECODER.AVC' not in text
    entry = '''        <MediaCodec name="OMX.MTK.VIDEO.DECODER.AVC" type="video/avc">
            <Quirk name="wants-NAL-fragments" />
            <Quirk name="requires-allocate-on-input-ports" />
            <Limit name="size" min="16x16" max="1280x736" />
        </MediaCodec>
'''
    (a.out / 'media_codecs.xml').write_bytes(text.replace('    <Decoders>\n', '    <Decoders>\n' + entry).encode())
    data = (a.inputs / 'mediacodec.rc').read_bytes()
    old = b'    group camera drmrpc mediadrm audio'
    assert data.count(old) == 1
    (a.out / 'mediacodec.rc').write_bytes(data.replace(old, old + b' media'))
    data = (a.inputs / 'mediacodec-seccomp.policy').read_bytes()
    assert b'\r' not in data, 'Minijail requires LF policy text'
    calls = ['sched_getparam', 'mlock', 'munlock', 'fsync']
    assert all((name + ':').encode() not in data for name in calls)
    data += b'\n# MT6582 decoder scheduling, DMA page locking and driver control.\n'
    data += ''.join(name + ': 1\n' for name in calls).encode()
    (a.out / 'mediacodec-seccomp.policy').write_bytes(data)
    shutil.copyfile(ROOT / 'build/media/q5-codec-limits.sh', a.out / 'q5-codec-limits.sh')
    outputs = {path.name: sha(path) for path in sorted(a.out.iterdir())}
    manifest = {'inputs': pins, 'compiler_sha256': COMPILER, 'outputs': outputs,
                'note': 'Requires patch_codec_boot.py for the scoped MEMLOCK startup hook.'}
    (a.out / 'media-compat-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
