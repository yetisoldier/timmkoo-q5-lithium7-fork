#!/usr/bin/env python3
"""Translate pinned Mint FM ioctl request encodings to the Q5 3.10 ARM ABI.

Only the 31 reviewed four-byte literals change. Function code and actual
argument buffers remain intact. Request values were compiled from the pinned
kernel's headers with its ARM compiler/configuration, not inferred on x86.
"""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]

def patch(blob):
    spec = json.loads((ROOT / 'manifests/fm-backend-abi-patches.json').read_text())
    requests = json.loads((ROOT / 'manifests/fm-uapi-mt6582.json').read_text())['requests']
    assert hashlib.sha256(blob).hexdigest() == spec['input'], 'Unexpected Mint backend'
    output = bytearray(blob)
    assert len(spec['changes']) == 31
    for row in spec['changes']:
        offset, old, new = [int(row[k], 16) for k in ['offset', 'old', 'new']]
        assert new == int(requests[row['name']], 16)
        assert struct.unpack_from('<I', output, offset)[0] == old
        struct.pack_into('<I', output, offset, new)
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
