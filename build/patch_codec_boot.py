#!/usr/bin/env python3
"""Add a scoped media.codec MEMLOCK startup hook to a boot COPY (D42-R3)."""
import argparse
import hashlib
from pathlib import Path
from patch_fm_boot_node import patch

INIT_DONOR = '5ff11fa56824aa88e207f5f42e497273dbdf9608d9638df0124853a77db7000b'

def transform(data):
    assert hashlib.sha256(data).hexdigest() == INIT_DONOR, 'Expected FM-corrected MT6582 init'
    assert b'q5-codec-limits' not in data
    return data.rstrip() + b'''

# Android 7 init lacks per-service rlimit options. Set only this service PID.
on property:init.svc.mediacodec=running
    exec u:r:su:s0 root root -- /system/bin/sh /system/etc/q5-codec-limits.sh
'''

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    assert not a.output.exists()
    result = patch(a.source.read_bytes(), transform)
    a.output.write_bytes(result)
    print(hashlib.sha256(result).hexdigest(), a.output)
