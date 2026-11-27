#!/usr/bin/env python3
"""Disable the two auto-started cellular modem helpers in a boot copy.

Preserves the kernel and every other ramdisk entry, including FM, audio,
touch, Home, USB and media.codec hooks. Does not flash the resulting image.
"""
import argparse
import hashlib
from pathlib import Path
from patch_fm_boot_node import patch
from q5_runtime_defaults import disable_service


def transform(data):
    expected = '272bc3996cee92197debfa8c0979c9433ff0c1ce037df5cb0a9b98db8a2d8a58'
    assert hashlib.sha256(data).hexdigest() == expected, 'Unexpected modem init donor'
    for name in ['ccci_fsd', 'ccci_mdinit']:
        data = disable_service(data, name)
    return data


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    assert not a.output.exists()
    a.output.write_bytes(patch(a.source.read_bytes(), transform, 'init.modem.rc'))
