#!/usr/bin/env python3
"""Install or upgrade a Q5 Gen 7 release from compatible TWRP recovery.

Factory-reset mode erases internal apps/files/keys. Upgrade mode preserves data
and requires an existing supported official Q5 release. This never writes
preloader, partition tables, recovery, NVRAM or calibration partitions.
Python 3.11+ and Android platform-tools (adb on PATH) are required.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

TARGETS = {
    'boot.img': ('/dev/bootimg', 'bootimg', 0x1d80000, 0x1000000),
    'logo.bin': ('/dev/logo', 'logo', 0x4400000, 0x300000),
    'system.img': ('/dev/block/mmcblk0p5', 'android', 0x5100000, 0x33400000),
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def data_fingerprints(shell):
    """Keep private package/adopted-key hashes in memory; never print contents."""
    packages = shell('sha256sum /data/system/packages.xml').strip()
    assert re.fullmatch(r'[0-9a-f]{64}\s+/data/system/packages.xml', packages)
    output = shell('for key in /data/misc/vold/expand_*.key; do '
                   'if [ -f "$key" ]; then sha256sum "$key" || exit 1; fi; done')
    keys = tuple(sorted(line for line in output.splitlines() if line.strip()))
    assert all(re.fullmatch(r'[0-9a-f]{64}\s+/data/misc/vold/expand_[0-9a-fA-F-]+\.key', line) for line in keys)
    return packages, keys


def prepare_upgrade(shell):
    shell('twrp mount system')
    installed = json.loads(shell('cat /system/etc/q5-release.json'))
    assert installed['name'] == 'Lithium 7 for Q5 Gen 7 (Q5 Mint)'
    assert installed['android'] == '7.1.2'
    assert installed['version'] in {'1.0.0', '1.0.1'}, 'Unsupported upgrade source'
    shell('twrp mount data')
    return data_fingerprints(shell)


def finish_data(shell, factory_reset, before):
    assert factory_reset == (before is None), 'Explicit install mode required'
    if not factory_reset:
        assert data_fingerprints(shell) == before, 'Userdata/key state changed; do not reboot'
        print('Verified: existing package state and adopted-storage keys retained.', flush=True)
        return
    print('Formatting internal data and clearing cache...', flush=True)
    print(shell('twrp format data'), flush=True)
    print(shell('twrp wipe cache'), flush=True)
    shell('twrp mount data')
    assert shell('test ! -e /data/system/packages.xml && echo clean').strip() == 'clean'
    assert shell('test ! -d /data/misc/vold && echo clean').strip() == 'clean'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--directory', type=Path, default=Path(__file__).resolve().parent)
    p.add_argument('--serial', required=True, help='Explicit adb recovery serial')
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--factory-reset', action='store_true',
                      help='Erase internal apps/files/adopted-storage keys')
    mode.add_argument('--upgrade', action='store_true',
                      help='Preserve data; v1.0.1 over official v1.0.0/v1.0.1 only')
    p.add_argument('--reboot', action='store_true')
    a = p.parse_args()
    adb = ['adb', '-s', a.serial]

    def shell(command):
        return subprocess.check_output(adb + ['shell', command], text=True, timeout=180)

    manifest = json.loads((a.directory / 'manifest.json').read_text())
    for name in TARGETS:
        path = a.directory / name
        row = manifest[name]
        assert path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], name
        assert path.stat().st_size % 4096 == 0 and path.stat().st_size <= TARGETS[name][3]
    assert (a.directory / 'boot.img').stat().st_size == TARGETS['boot.img'][3]
    assert (a.directory / 'logo.bin').stat().st_size == TARGETS['logo.bin'][3]
    assert 'uid=0(root)' in shell('id'), 'Root recovery shell required'
    assert shell('getprop ro.board.platform').strip() == 'mt6582'
    assert shell('getprop ro.twrp.version').strip(), 'Existing compatible TWRP required'
    layout = shell('cat /proc/dumchar_info')
    for _, partition, start, size in TARGETS.values():
        match = re.search(r'(?m)^' + partition + r'\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s', layout)
        assert match and int(match[1], 16) == size and int(match[2], 16) == start, partition
    assert '/dev/block/mmcblk0p7' in shell('cat /etc/recovery.fstab')
    before = None
    if a.upgrade:
        build = json.loads((a.directory / 'system-build.json').read_text())
        assert build['release_version'] == '1.0.1', 'Upgrade target must be the tested v1.0.1'
        before = prepare_upgrade(shell)
    shell('twrp unmount system')
    mounts = [line.split() for line in shell('cat /proc/mounts').splitlines() if line.strip()]
    assert all(len(row) >= 2 for row in mounts), 'Unexpected recovery mount table'
    assert not any(row[1] == '/system' for row in mounts)
    # Verify the exact no-PTY binary transport before any partition write.
    fixture = bytes(range(256)) * 16
    subprocess.run(adb + ['exec-in', 'dd of=/tmp/q5-transport-test bs=4096'],
                   input=fixture, capture_output=True, check=True, timeout=15)
    assert subprocess.check_output(adb + ['exec-out', 'cat /tmp/q5-transport-test']) == fixture
    shell('rm /tmp/q5-transport-test')
    for name, (device, _, _, _) in TARGETS.items():
        path = a.directory / name
        print('Writing', name, 'to', device, flush=True)
        with path.open('rb') as stream:
            subprocess.run(adb + ['exec-in', 'dd of=' + device + ' bs=1048576'],
                           stdin=stream, check=True, timeout=300)
        shell('sync')
        count = path.stat().st_size // 4096
        process = subprocess.Popen(adb + ['exec-out',
            f'dd if={device} bs=4096 count={count} 2>/dev/null'], stdout=subprocess.PIPE)
        result = hashlib.sha256()
        size = 0
        while block := process.stdout.read(1024 * 1024):
            size += len(block)
            result.update(block)
        assert process.wait(timeout=30) == 0
        assert size == path.stat().st_size and result.hexdigest() == manifest[name]['sha256'], name
        print('Readback verified:', name, flush=True)
    finish_data(shell, a.factory_reset, before)
    shell('sync')
    print('Installation and bounded readback verification complete.', flush=True)
    if a.reboot:
        subprocess.run(adb + ['reboot'], check=True)


if __name__ == '__main__':
    main()
