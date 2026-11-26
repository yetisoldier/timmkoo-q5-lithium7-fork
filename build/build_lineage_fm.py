#!/usr/bin/env python3
"""Build the pinned Android 7 FM receiver with this Q5's kernel ABI.

Java tools run locally. On Windows only aapt runs through WSL Ubuntu; on Linux
aapt runs natively. Requires a clean pinned source checkout, downloaded tools,
the matching framework-res.apk, original Lithium JNI and a local signing key.
Does not install, flash, or bundle signing keys.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from patch_lineage_fm_native import patch

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'tools', 'framework', 'native', 'keystore', 'out']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--alias', default='q5-development')
    p.add_argument('--aapt', default='/usr/bin/aapt')
    a = p.parse_args()
    for name in ['source', 'tools', 'framework', 'native', 'keystore', 'out']:
        setattr(a, name, getattr(a, name).resolve())
    spec = json.loads((ROOT / 'manifests/lineage-fm-build.json').read_text())
    revision = subprocess.check_output(['git', '-C', str(a.source), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == spec['commit']
    assert not subprocess.check_output(['git', '-C', str(a.source), 'status', '--porcelain'])
    for name, row in spec['tools'].items():
        assert sha(a.tools / name) == row['sha256'], name
    assert sha(a.framework) == spec['framework_res_sha256']
    assert sha(a.native) == spec['native_sha256']
    windows = os.name == 'nt'
    aapt_prefix = ['wsl', '-d', 'Ubuntu', '--'] if windows else []
    actual_aapt = subprocess.check_output(aapt_prefix + ['sha256sum', a.aapt], text=True).split()[0]
    assert actual_aapt == spec['aapt_sha256'], 'Use the documented aapt build'
    a.out.mkdir(parents=True)
    shutil.copytree(a.source / 'res', a.out / 'res')
    config = a.out / 'res/values/config.xml'
    config_data = config.read_bytes()
    old = b'<bool name="config_useSoftwareRenderingForAudio" translatable="false">true</bool>'
    assert config_data.count(old) == 1
    config.write_bytes(config_data.replace(old, old.replace(b'>true<', b'>false<')))
    with zipfile.ZipFile(a.tools / 'cardview.aar') as z:
        z.extractall(a.out / 'cardview')
    ns = 'http://schemas.android.com/apk/res/android'
    ET.register_namespace('android', ns)
    manifest = ET.parse(a.source / 'AndroidManifest.xml')
    root = manifest.getroot()
    root.attrib.pop('{' + ns + '}sharedUserId')
    # This pre-runtime-permission app assumes a privileged system install.
    # Keep a private app UID rather than borrowing the platform system UID.
    root.find('uses-sdk').set('{' + ns + '}targetSdkVersion', '22')
    root.insert(list(root).index(root.find('application')), ET.Element(
        'uses-permission', {'{' + ns + '}name': 'android.permission.CAPTURE_AUDIO_OUTPUT'}))
    manifest.write(a.out / 'AndroidManifest.xml', encoding='utf-8', xml_declaration=True)
    for directory in ['gen', 'classes', 'dex']:
        (a.out / directory).mkdir()

    def resource_path(path):
        if windows:
            return '/mnt/' + path.drive[0].lower() + path.as_posix()[2:]
        return str(path)

    run(*aapt_prefix, a.aapt, 'package', '-f', '-m',
        '-M', resource_path(a.out / 'AndroidManifest.xml'),
        '-S', resource_path(a.out / 'res'), '-S', resource_path(a.out / 'cardview/res'),
        '-I', resource_path(a.framework), '-J', resource_path(a.out / 'gen'),
        '-F', resource_path(a.out / 'resources.apk'), '--auto-add-overlay',
        '--extra-packages', 'android.support.v7.cardview')
    sources = sorted((a.source / 'src').rglob('*.java')) + sorted((a.out / 'gen').rglob('*.java'))
    args = a.out / 'javac.args'
    args.write_text('\n'.join('"' + path.as_posix() + '"' for path in sources), encoding='utf-8')
    run('javac', '--release', '8', '-encoding', 'UTF-8', '-classpath',
        str(a.tools / 'android-all.jar') + os.pathsep + str(a.out / 'cardview/classes.jar'),
        '-d', a.out / 'classes', '@' + str(args))
    run('jar', 'cf', a.out / 'classes.jar', '-C', a.out / 'classes', '.')
    run('java', '-cp', a.tools / 'r8.jar', 'com.android.tools.r8.D8', '--min-api', '21',
        '--lib', a.tools / 'android-all.jar', '--output', a.out / 'dex',
        a.out / 'classes.jar', a.out / 'cardview/classes.jar')
    native = patch(a.native.read_bytes())
    with zipfile.ZipFile(a.out / 'resources.apk') as before, zipfile.ZipFile(a.out / 'unsigned.apk', 'w') as after:
        for item in before.infolist():
            after.writestr(item, before.read(item))
        after.write(a.out / 'dex/classes.dex', 'classes.dex', compress_type=zipfile.ZIP_DEFLATED)
        after.writestr('lib/armeabi-v7a/libfmjni.so', native, compress_type=zipfile.ZIP_DEFLATED)
    run('jarsigner', '-keystore', a.keystore, '-storepass', 'android', '-keypass', 'android',
        '-signedjar', a.out / 'FMRadio.apk', a.out / 'unsigned.apk', a.alias)
    run('jarsigner', '-verify', a.out / 'FMRadio.apk')
    result = {'source_commit': revision, 'package': 'com.android.fmradio',
              'sha256': sha(a.out / 'FMRadio.apk'),
              'native_sha256': hashlib.sha256(native).hexdigest(),
              'target_sdk': 22, 'shared_system_uid': False, 'force_software_audio': False,
              'note': 'Requires privileged install; physical FM audio validation is separate.'}
    (a.out / 'fm-build-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
