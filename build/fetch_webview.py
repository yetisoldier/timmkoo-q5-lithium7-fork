#!/usr/bin/env python3
"""Download the pinned Lineage ARM WebView; verify its Git LFS object hash."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

SPEC = Path(__file__).resolve().parents[1] / 'manifests/webview.json'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('out', type=Path)
    a = p.parse_args()
    spec = json.loads(SPEC.read_text())
    assert not a.out.exists(), 'Refusing to overwrite an existing file'
    pointer_url = ('https://raw.githubusercontent.com/LineageOS/'
                   'android_external_chromium-webview_prebuilt_arm/'
                   + spec['commit'] + '/' + spec['path'])
    with urllib.request.urlopen(pointer_url, timeout=60) as response:
        pointer = response.read().decode('ascii')
    assert 'oid sha256:' + spec['sha256'] in pointer
    assert 'size ' + str(spec['size']) in pointer
    request = urllib.request.Request(spec['lfs_batch'], data=json.dumps({
        'operation': 'download', 'transfers': ['basic'],
        'objects': [{'oid': spec['sha256'], 'size': spec['size']}],
    }).encode(), headers={'Content-Type': 'application/vnd.git-lfs+json',
                         'Accept': 'application/vnd.git-lfs+json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        action = json.load(response)['objects'][0]['actions']['download']
    temporary = a.out.with_suffix(a.out.suffix + '.partial')
    assert not temporary.exists()
    a.out.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(urllib.request.Request(
            action['href'], headers=action.get('header', {})), timeout=60) as response:
        with temporary.open('xb') as output:
            while block := response.read(1024 * 1024):
                digest.update(block)
                size += len(block)
                output.write(block)
    assert size == spec['size'] and digest.hexdigest() == spec['sha256']
    temporary.rename(a.out)
    print(spec['sha256'], a.out)


if __name__ == '__main__':
    main()
