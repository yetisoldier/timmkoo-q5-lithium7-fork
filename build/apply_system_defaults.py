#!/usr/bin/env python3
"""Apply verified Q5 defaults to a COPY of a raw Lithium ext4 system image.

Linux/WSL tools: debugfs, e2fsck. No mounting or device flashing. Pass branding
and Home framework build output directories plus the pinned Open Camera APK.
This deliberately preserves the original Lithium audio HAL, not M1a's donor HAL.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

HAL = 'a7cc2dbe2cc2b8fd9c06d86f6f9479670a16e66bacc8941660ac81d6a370463e'
CAMERA = 'ca5672ca8c7174554ca0b07b5b26e505817a05142f571cf2abe67e790c30249c'

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ['input', 'out', 'branding', 'gestures', 'camera']:
        p.add_argument('--' + arg, required=True, type=Path)
    a = p.parse_args()
    assert not a.out.exists(), 'Output already exists'
    assert a.input.resolve() != a.out.resolve()
    assert sha(a.camera) == CAMERA, 'Unexpected Open Camera APK'
    a.out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(a.input, a.out)
    changes = {}
    def debug(command):
        result = subprocess.run(['debugfs', '-w', '-R', command, str(a.out)],
                                capture_output=True, text=True, check=True)
        return result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='q5-defaults-') as tmp:
        tmp = Path(tmp)
        selinux = tmp / 'selinux-label.bin'
        selinux.write_bytes(b'u:object_r:system_file:s0\0')
        def extract(remote, local):
            debug(f'dump {remote} "{local}"')
            assert local.exists(), remote
        def exists(remote):
            return 'File not found' not in debug('stat ' + remote)
        def label(remote, directory=False):
            debug(f'set_inode_field {remote} mode {"040755" if directory else "0100644"}')
            debug(f'set_inode_field {remote} uid 0')
            debug(f'set_inode_field {remote} gid 0')
            debug(f'ea_set -f "{selinux}" {remote} security.selinux')
            check_label = tmp / 'label-check.bin'
            debug(f'ea_get -f "{check_label}" {remote} security.selinux')
            assert check_label.read_bytes() == selinux.read_bytes(), remote
            check_label.unlink()
        def put(local, remote):
            if exists(remote):
                debug('rm ' + remote)
            debug(f'write "{local.resolve()}" {remote}')
            label(remote)
            check = tmp / 'check'
            extract(remote, check)
            assert sha(check) == sha(local), remote
            check.unlink()
            changes[remote] = sha(local)
        hal = tmp / 'hal.so'
        extract('/lib/hw/audio.primary.mt6582.so', hal)
        assert sha(hal) == HAL, 'Expected tested original Lithium audio HAL'
        for name in ['Jelly', 'HTMLViewer']:
            apk, directory = f'/app/{name}/{name}.apk', f'/app/{name}'
            if exists(apk):
                debug('rm ' + apk)
            if exists(directory):
                debug('rmdir ' + directory)
            assert not exists(directory), f'Unexpected contents remain in {directory}'
            changes[directory] = 'removed'
        for local, remote in [
            (a.branding / 'framework-res.apk', '/framework/framework-res.apk'),
            (a.branding / 'bootanimation.zip', '/media/bootanimation.zip'),
            (a.gestures / 'services.jar', '/framework/services.jar'),
            (a.gestures / 'org.cyanogenmod.platform.jar', '/framework/org.cyanogenmod.platform.jar'),
            (a.gestures / 'CMParts.apk', '/priv-app/CMParts/CMParts.apk'),
            (a.gestures / 'CMSettingsProvider.apk', '/priv-app/CMSettingsProvider/CMSettingsProvider.apk'),
            (a.gestures / 'Lawnchair.apk', '/priv-app/Lawnchair/Lawnchair.apk'),
        ]:
            put(local, remote)
        directory = '/app/OpenCamera'
        if not exists(directory):
            debug('mkdir ' + directory)
        label(directory, directory=True)
        put(a.camera, directory + '/OpenCamera.apk')
        prop = tmp / 'build.prop'
        extract('/build.prop', prop)
        lines = [s for s in prop.read_text().splitlines() if not s.startswith('qemu.hw.mainkeys=')]
        prop.write_text('\n'.join(lines) + '\nqemu.hw.mainkeys=0\n')
        put(prop, '/build.prop')
        hal.unlink()
        extract('/lib/hw/audio.primary.mt6582.so', hal)
        assert sha(hal) == HAL
    repair = subprocess.run(['e2fsck', '-f', '-y', str(a.out)], capture_output=True, text=True)
    a.out.with_suffix('.fsck.txt').write_text(repair.stdout + repair.stderr)
    assert repair.returncode in [0, 1], 'Output filesystem repair failed'
    subprocess.run(['e2fsck', '-f', '-n', str(a.out)], check=True)
    manifest = {'input_sha256': sha(a.input), 'output_sha256': sha(a.out),
                'audio_hal_sha256': HAL, 'changes': changes,
                'note': 'Development image; camera capture still unresolved.'}
    a.out.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
