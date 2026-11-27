#!/usr/bin/env python3
"""Build the small, launcher-free Plex sign-in window using pinned Android tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['tools', 'framework', 'keystore', 'out']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--alias', default='q5-development')
    a = p.parse_args()
    for name in ['tools', 'framework', 'keystore', 'out']:
        setattr(a, name, getattr(a, name).resolve())
    pinned = json.loads((ROOT / 'manifests/lineage-fm-build.json').read_text())
    for name in ['android-all.jar', 'r8.jar']:
        assert sha(a.tools / name) == pinned['tools'][name]['sha256']
    assert sha(a.framework) == pinned['framework_res_sha256']
    prefix = ['wsl', '-d', 'Ubuntu', '--'] if os.name == 'nt' else []
    assert subprocess.check_output(prefix + ['sha256sum', '/usr/bin/aapt'], text=True).split()[0] == pinned['aapt_sha256']
    a.out.mkdir(parents=True)  # Never replace a previous signed build.
    for name in ['gen', 'classes', 'dex', 'res']:
        (a.out / name).mkdir()
    source = ROOT / 'apps/plex-signin'
    def resource(path):
        return '/mnt/' + path.drive[0].lower() + path.as_posix()[2:] if os.name == 'nt' else str(path)
    def run(*args, **kwargs):
        subprocess.run([str(x) for x in args], check=True, **kwargs)
    run(*prefix, '/usr/bin/aapt', 'package', '-f', '-m', '-M', resource(source / 'AndroidManifest.xml'),
        '-S', resource(a.out / 'res'), '-I', resource(a.framework), '-J', resource(a.out / 'gen'),
        '-F', resource(a.out / 'resources.apk'))
    sources = sorted((source / 'src').rglob('*.java')) + sorted((a.out / 'gen').rglob('*.java'))
    args = a.out / 'javac.args'
    args.write_text('\n'.join('"' + f.as_posix() + '"' for f in sources), encoding='utf-8')
    run('javac', '--release', '8', '-encoding', 'UTF-8', '-classpath', a.tools / 'android-all.jar',
        '-d', a.out / 'classes', '@' + str(args))
    run('javac', '--release', '8', '-classpath', a.out / 'classes', '-d', a.out / 'classes', source / 'AllowedUrlTest.java')
    run('java', '-cp', a.out / 'classes', 'AllowedUrlTest')
    # Unit-test entry point is not part of the shipped application.
    (a.out / 'classes/AllowedUrlTest.class').unlink()
    run('jar', 'cf', a.out / 'classes.jar', '-C', a.out / 'classes', '.')
    run('java', '-cp', a.tools / 'r8.jar', 'com.android.tools.r8.D8', '--min-api', '24',
        '--lib', a.tools / 'android-all.jar', '--output', a.out / 'dex', a.out / 'classes.jar')
    with zipfile.ZipFile(a.out / 'resources.apk') as before, zipfile.ZipFile(a.out / 'unsigned.apk', 'w') as after:
        for item in before.infolist():
            after.writestr(item, before.read(item))
        after.write(a.out / 'dex/classes.dex', 'classes.dex', compress_type=zipfile.ZIP_DEFLATED)
    env = dict(os.environ, Q5_SIGNING_STOREPASS=os.environ.get('Q5_SIGNING_STOREPASS', 'android'))
    run('jarsigner', '-keystore', a.keystore, '-storepass:env', 'Q5_SIGNING_STOREPASS',
        '-keypass:env', 'Q5_SIGNING_STOREPASS', '-signedjar', a.out / 'Q5PlexSignIn.apk',
        a.out / 'unsigned.apk', a.alias, env=env)
    run('jarsigner', '-verify', a.out / 'Q5PlexSignIn.apk')
    result = {'package': 'org.q5.plexsignin', 'version': '1.0', 'versionCode': 1,
              'sha256': sha(a.out / 'Q5PlexSignIn.apk'), 'launcher_entry': False,
              'https_plex_signin_only': True, 'shared_system_uid': False,
              'source': {f.relative_to(ROOT).as_posix(): sha(f) for f in sorted(source.rglob('*')) if f.is_file()}}
    (a.out / 'plex-signin-manifest.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
