#!/usr/bin/env python3
"""Apply verified Q5 defaults to a COPY of a raw Lithium ext4 system image.

Linux/WSL tools: debugfs, e2fsck. No mounting or device flashing. Pass branding
and Home framework build output directories, built Lineage FM and pinned recorder.
This deliberately preserves the original Lithium audio HAL, not M1a's donor HAL.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile
from prune_features import prune

HAL = 'a7cc2dbe2cc2b8fd9c06d86f6f9479670a16e66bacc8941660ac81d6a370463e'
RECORDER = 'eba0e28fe6d502c919218912f077407eef952dc39d8df431df31a28683739cc5'

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ['input', 'out', 'branding', 'gestures', 'fm', 'recorder', 'media', 'webview']:
        p.add_argument('--' + arg, required=True, type=Path)
    p.add_argument('--release-version', help='Official Q5 Gen 7 semantic version')
    a = p.parse_args()
    if a.release_version:
        assert re.fullmatch(r'\d+\.\d+\.\d+', a.release_version)
    assert not a.out.exists(), 'Output already exists'
    assert a.input.resolve() != a.out.resolve()
    assert sha(a.recorder) == RECORDER, 'Unexpected Audio Recorder APK'
    webview = json.loads((Path(__file__).resolve().parents[1] / 'manifests/webview.json').read_text())
    assert a.webview.stat().st_size == webview['size']
    assert sha(a.webview) == webview['sha256'], 'Unexpected WebView APK'
    fm_manifest = json.loads((a.fm.parent / 'fm-build-manifest.json').read_text())
    assert sha(a.fm) == fm_manifest['sha256'], 'FM build does not match its manifest'
    assert fm_manifest['package'] == 'com.android.fmradio'
    assert fm_manifest['force_software_audio'] is True
    media_manifest = json.loads((a.media / 'media-compat-manifest.json').read_text())
    for name, expected in media_manifest['outputs'].items():
        assert sha(a.media / name) == expected, name
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
        m4u = tmp / 'unchanged-m4u.so'
        extract('/lib/libm4u.so', m4u)
        assert sha(m4u) == media_manifest['inputs']['libm4u.so'], 'Unexpected shared graphics M4U library'
        for base, name in [('app', 'Jelly'), ('app', 'HTMLViewer'),
                           ('app', 'OpenCamera'), ('priv-app', 'XposedInstaller')]:
            apk, directory = f'/{base}/{name}/{name}.apk', f'/{base}/{name}'
            if exists(apk):
                debug('rm ' + apk)
            if exists(directory):
                debug('rmdir ' + directory)
            assert not exists(directory), f'Unexpected contents remain in {directory}'
            changes[directory] = 'removed'
        for local, remote in [
            (a.webview, '/app/webview/webview.apk'),
            (a.branding / 'framework-res.apk', '/framework/framework-res.apk'),
            (a.branding / 'bootanimation.zip', '/media/bootanimation.zip'),
            (a.gestures / 'services.jar', '/framework/services.jar'),
            (a.gestures / 'org.cyanogenmod.platform.jar', '/framework/org.cyanogenmod.platform.jar'),
            (a.gestures / 'CMParts.apk', '/priv-app/CMParts/CMParts.apk'),
            (a.gestures / 'CMSettingsProvider.apk', '/priv-app/CMSettingsProvider/CMSettingsProvider.apk'),
            (a.gestures / 'Lawnchair.apk', '/priv-app/Lawnchair/Lawnchair.apk'),
        ]:
            put(local, remote)
        for name in ['libMtkOmxVdec.so', 'libstagefright.so', 'libmhalImageCodec.so',
                     'libmmprofile.so', 'libq5.so', 'libvcodec_utility.so']:
            put(a.media / name, '/lib/' + name)
        if exists('/lib/libq5omx.so'):
            debug('rm /lib/libq5omx.so')
        for name, directory in [('media_codecs.xml', '/etc/'),
                                ('mediacodec.rc', '/etc/init/'),
                                ('mediacodec-seccomp.policy', '/etc/seccomp_policy/'),
                                ('q5-codec-limits.sh', '/etc/')]:
            put(a.media / name, directory + name)
        def mkdir(directory):
            if not exists(directory):
                debug('mkdir ' + directory)
            label(directory, directory=True)
        for apk, directory, filename in [
            (a.fm, '/priv-app/Q5FMRadio', 'Q5FMRadio.apk'),
            (a.recorder, '/app/Q5AudioRecorder', 'Q5AudioRecorder.apk'),
        ]:
            mkdir(directory)
            put(apk, directory + '/' + filename)
            mkdir(directory + '/lib')
            mkdir(directory + '/lib/arm')
            with zipfile.ZipFile(apk) as z:
                libraries = [n for n in z.namelist() if n.startswith('lib/armeabi-v7a/') and n.endswith('.so')]
                assert libraries, 'Expected ARMv7 native libraries'
                for name in libraries:
                    native = tmp / Path(name).name
                    native.write_bytes(z.read(name))
                    put(native, directory + '/lib/arm/' + native.name)
            if directory.endswith('Q5FMRadio'):
                for obsolete in ['libq5mintfmjni.so', 'libfmcust.so', 'libfmmt6627.so']:
                    unused = directory + '/lib/arm/' + obsolete
                    if exists(unused):
                        debug('rm ' + unused)
                        changes[unused] = 'removed'
        listing = debug('ls -p /etc/permissions')
        for name in sorted(set(re.findall(r'/([^/\n]+\.xml)/', listing))):
            local = tmp / name
            remote = '/etc/permissions/' + name
            extract(remote, local)
            data, removed = prune(local.read_bytes())
            if removed:
                local.write_bytes(data)
                put(local, remote)
        prop = tmp / 'build.prop'
        extract('/build.prop', prop)
        data = prop.read_text()
        matches = re.findall(r'(?m)^qemu\.hw\.mainkeys=.*$', data)
        assert len(matches) <= 1, 'Review duplicate mainkeys properties'
        data = (re.sub(r'(?m)^qemu\.hw\.mainkeys=.*$', 'qemu.hw.mainkeys=0', data)
                if matches else data.rstrip('\n') + '\nqemu.hw.mainkeys=0\n')
        key = 'persist.af.audio_patch_fm'
        pattern = r'(?m)^' + re.escape(key) + r'=.*$'
        assert len(re.findall(pattern, data)) <= 1
        data = (re.sub(pattern, key + '=1', data) if re.search(pattern, data)
                else data.rstrip('\n') + '\n' + key + '=1\n')
        if a.release_version:
            properties = {
                'ro.build.display.id': 'Q5 Gen 7 Lithium 7 v' + a.release_version,
                'ro.build.version.incremental': 'q5gen7.' + a.release_version,
                'ro.product.model': 'Q5 Gen 7',
                'ro.modversion': 'Q5 Gen 7 Lithium 7 v' + a.release_version,
            }
            for key, value in properties.items():
                pattern = r'(?m)^' + re.escape(key) + r'=.*$'
                assert len(re.findall(pattern, data)) == 1, key
                data = re.sub(pattern, key + '=' + value, data)
            release = tmp / 'q5-release.json'
            release.write_text(json.dumps({
                'name': 'Lithium 7 for Q5 Gen 7 (Q5 Mint)',
                'version': a.release_version, 'source_ref': 'v' + a.release_version,
                'hardware': 'Mint-style MT6582, 480x800, single front Home circle',
                'android': '7.1.2', 'kernel_profile': 'D42-R3',
            }, indent=2) + '\n', encoding='utf-8')
            put(release, '/etc/q5-release.json')
        prop.write_text(data)
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
                'release_version': a.release_version,
                'note': 'Q5 Gen 7 / Q5 Mint only. Camera omitted per product evidence; see release notes for validation limits.'}
    a.out.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
