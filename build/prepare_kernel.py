#!/usr/bin/env python3
"""Prepare an isolated, pinned Q5 kernel tree without resetting a checkout."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

SOURCE_REV = '96e535524cb10b9e3d9ea2d0e69599726605ae8e'
REPO = Path(__file__).resolve().parents[1]


def prepare(checkout, work, series):
    names = series.read_text().splitlines()
    patches = [REPO / 'patches/kernel' / name for name in names if name and not name.startswith('#')]
    identity = {'kernel_revision': SOURCE_REV,
                'patches': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in patches}}
    stamp = work / 'prepared.json'
    kernel = work / 'source/kernel-3.10'
    if stamp.exists():
        assert json.loads(stamp.read_text()) == identity, 'patch set changed: choose a new work directory'
        assert kernel.is_dir()
        print(kernel)
        return
    assert not work.exists() or not any(work.iterdir()), 'work directory is not empty'
    subprocess.run(['git', '-C', str(checkout), 'cat-file', '-e', SOURCE_REV + '^{commit}'], check=True)
    source = work / 'source'
    source.mkdir(parents=True)
    archive = subprocess.check_output(['git', '-C', str(checkout), 'archive', SOURCE_REV, 'kernel-3.10'])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(source, filter='data')
    board = kernel / 'arch/arm/mach-mt6582'
    shutil.copytree(board / 'a106', board / 'q5')
    config = kernel / 'arch/arm/configs/q5_defconfig'
    config.write_text((config.with_name('a106_defconfig')).read_text().replace(
        'CONFIG_ARCH_MTK_PROJECT="a106"', 'CONFIG_ARCH_MTK_PROJECT="q5"'))
    for patch in patches:
        subprocess.run(['patch', '-p1', '--batch', '--quiet'], cwd=kernel,
                       input=patch.read_bytes(), check=True)
    fw = kernel / 'drivers/input/touchscreen/mediatek/gslX680/gslX680_fw_q5.h'
    assert hashlib.sha256(fw.read_bytes()).hexdigest() == 'bae204cb4dd1f6adce804af5fad91e9b3424847bd7a09e7faadacf3effbae680'
    stamp.write_text(json.dumps(identity, indent=2) + '\n')
    print(kernel)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('work', type=Path)
    parser.add_argument('--series', type=Path, default=REPO / 'build/kernel-d36.series')
    args = parser.parse_args()
    prepare(args.checkout.resolve(), args.work.resolve(), args.series.resolve())
