#!/usr/bin/env python3
"""Adapt the pinned Lithium FM JNI's Thumb ioctl immediates to Q5 kernel UAPI.

Only 15 reviewed MOVT instructions change. No JNI registration, argument
buffer, FM transmitter behavior, or shared audio library is changed.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def patch(blob):
    spec = json.loads((ROOT / 'manifests/fm-lineage-abi-patches.json').read_text())
    requests = json.loads((ROOT / 'manifests/fm-uapi-mt6582.json').read_text())['requests']
    assert hashlib.sha256(blob).hexdigest() == spec['input'], 'Unexpected FM JNI'
    output = bytearray(blob)
    assert len(spec['changes']) == 15
    for row in spec['changes']:
        assert int(row['new'], 16) == int(requests[row['name']], 16)
        offset = int(row['offset'], 16)
        before, after = bytes.fromhex(row['before']), bytes.fromhex(row['after'])
        assert len(before) == len(after) == 4
        assert output[offset:offset + 4] == before, row['name']
        output[offset:offset + 4] = after
    assert hashlib.sha256(output).hexdigest() == spec['output']
    return bytes(output)


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    assert not a.output.exists()
    a.output.write_bytes(patch(a.source.read_bytes()))
