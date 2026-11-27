#!/usr/bin/env python3
"""Build an app-local API-25 ColorSpace guard for the original Chronicle 0.53.

Re-signs with a local Q5 key; not an official Chronicle build. Existing publisher
installs need a private app-data backup/restore when changing signing identity.
Does not install or handle credentials. The ROM's graphics APIs are untouched.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def patch(source):
    start = source.index('.method public final J()V')
    end = source.index('.end method', start) + len('.end method')
    method = source[start:end]
    assert '    .registers 13\n' in method
    assert 'v12' not in method, 'The new temporary register must be unused'
    method = method.replace('    .registers 13\n', '    .registers 14\n', 1)
    old = '''    iget-object v6, v1, Landroidx/appcompat/widget/m;->g:Ljava/lang/Object;

    check-cast v6, Landroid/graphics/ColorSpace;

    .line 12
    iput-object v6, p0, Lc5/d;->p:Landroid/graphics/ColorSpace;'''
    new = '''    sget v6, Landroid/os/Build$VERSION;->SDK_INT:I

    const/16 v12, 0x1a

    if-lt v6, v12, :q5_skip_oreo_color_space

    iget-object v6, v1, Landroidx/appcompat/widget/m;->g:Ljava/lang/Object;

    check-cast v6, Landroid/graphics/ColorSpace;

    .line 12
    iput-object v6, p0, Lc5/d;->p:Landroid/graphics/ColorSpace;

    :q5_skip_oreo_color_space'''
    assert method.count(old) == 1
    return source[:start] + method.replace(old, new, 1) + source[end:]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['input', 'tools', 'keystore', 'out']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--alias', default='q5-development')
    a = p.parse_args()
    for name in ['input', 'tools', 'keystore', 'out']:
        setattr(a, name, getattr(a, name).resolve())
    # Exact publisher release input is pinned in the companion manifest.
    spec = json.loads((ROOT / 'manifests/chronicle-compat.json').read_text())
    assert sha(a.input) == spec['input_sha256']
    for item in json.loads((ROOT / 'manifests/smali-tools.json').read_text()):
        assert sha(a.tools / item['name']) == item['sha256']
    a.out.mkdir(parents=True)
    def run(*args, **kwargs):
        subprocess.run([str(x) for x in args], check=True, **kwargs)
    with zipfile.ZipFile(a.input) as z:
        (a.out / 'original.dex').write_bytes(z.read('classes.dex'))
    classpath = str(a.tools / '*')
    run('java', '-cp', classpath, 'org.jf.baksmali.Main', 'disassemble',
        a.out / 'original.dex', '-o', a.out / 'smali')
    f = a.out / 'smali/c5/d.smali'
    original = f.read_text()
    changed = patch(original)
    assert changed != original
    f.write_text(changed, encoding='utf-8', newline='\n')
    (a.out / 'colorspace.patch').write_text(''.join(difflib.unified_diff(
        original.splitlines(True), changed.splitlines(True), fromfile='a/c5/d.smali',
        tofile='b/c5/d.smali')), encoding='utf-8')
    run('java', '-cp', classpath, 'org.jf.smali.Main', 'assemble', a.out / 'smali',
        '-o', a.out / 'classes.dex')
    with zipfile.ZipFile(a.input) as before, zipfile.ZipFile(a.out / 'unsigned.apk', 'w') as after:
        for item in before.infolist():
            if item.filename.upper() == 'META-INF/MANIFEST.MF' or (item.filename.upper().startswith('META-INF/') and item.filename.upper().endswith(('.SF', '.RSA', '.DSA', '.EC'))):
                continue  # The modified app receives its own valid signature.
            data = (a.out / 'classes.dex').read_bytes() if item.filename == 'classes.dex' else before.read(item.filename)
            after.writestr(item, data)
    env = dict(os.environ, Q5_SIGNING_STOREPASS=os.environ.get('Q5_SIGNING_STOREPASS', 'android'))
    target = a.out / 'Chronicle-Q5-0.53.0-compat.apk'
    run('jarsigner', '-keystore', a.keystore, '-storepass:env', 'Q5_SIGNING_STOREPASS',
        '-keypass:env', 'Q5_SIGNING_STOREPASS', '-signedjar', target,
        a.out / 'unsigned.apk', a.alias, env=env)
    run('jarsigner', '-verify', target)
    with zipfile.ZipFile(a.input) as before, zipfile.ZipFile(target) as after:
        for name in before.namelist():
            if name == 'classes.dex' or name.upper() == 'META-INF/MANIFEST.MF' or (name.upper().startswith('META-INF/') and name.upper().endswith(('.SF', '.RSA', '.DSA', '.EC'))):
                continue
            assert before.read(name) == after.read(name), name
    result = dict(spec, output_sha256=sha(target), compatibility='Guard only API-26 ColorSpace metadata access')
    (a.out / 'chronicle-compat-build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
