#!/usr/bin/env python3
"""Disable voice/SMS capability in the pinned framework resource table.

Keep resource IDs, table layout and every unrelated APK entry unchanged. This
does not rebuild or sign the platform APK. Intended for this Q5 donor only.
"""
import argparse
import copy
import hashlib
from pathlib import Path
import struct
import zipfile

TABLE_SHA = '0e9c86f600ea479f05466436027f4cf0ffa794e55edb9ffd4f81085cf32479c7'
# Verified with aapt dump resources on the pinned Lithium framework.
CAPABILITIES = {0x0112006c: 'config_voice_capable', 0x0112006f: 'config_sms_capable'}


def patch_table(data):
    assert hashlib.sha256(data).hexdigest() == TABLE_SHA, 'Unexpected framework table'
    result = bytearray(data)
    changed = []
    def chunks(start, end):
        while start < end:
            kind, header, size = struct.unpack_from('<HHI', data, start)
            assert 8 <= header <= size and start + size <= end
            yield start, kind, header, size
            start += size
        assert start == end
    for pos, kind, header, size in chunks(12, len(data)):
        if kind != 0x200:
            continue
        package = struct.unpack_from('<I', data, pos + 8)[0]
        for sub, typ, head, length in chunks(pos + header, pos + size):
            if typ != 0x201:
                continue
            type_id, flags, _, count, entries = struct.unpack_from('<BBHII', data, sub + 8)
            if package != 1 or type_id != 0x12:
                continue
            assert flags == 0, 'Sparse/offset16 tables require separate handling'
            for resource, name in CAPABILITIES.items():
                index = resource & 0xffff
                assert index < count
                offset = struct.unpack_from('<I', data, sub + head + 4 * index)[0]
                if offset == 0xffffffff:
                    continue
                entry = sub + entries + offset
                entry_size, entry_flags = struct.unpack_from('<HH', data, entry)
                assert not entry_flags & 1, name
                value = entry + entry_size
                value_size, reserved, value_type, old = struct.unpack_from('<HBBI', data, value)
                assert (value_size, reserved, value_type, old) == (8, 0, 0x12, 0xffffffff), name
                struct.pack_into('<I', result, value + 4, 0)
                changed.append(name)
    assert set(changed) == set(CAPABILITIES.values()), changed
    assert len(result) == len(data)
    return bytes(result)


def build(source, output):
    assert source.resolve() != output.resolve() and not output.exists()
    with zipfile.ZipFile(source) as before, zipfile.ZipFile(output, 'w') as after:
        for item in before.infolist():
            entry = copy.copy(item)
            data = before.read(item.filename)
            if item.filename == 'resources.arsc':
                data = patch_table(data)
            if entry.compress_type == zipfile.ZIP_STORED:
                entry.extra = b''
                base = after.fp.tell() + 30 + len(entry.filename.encode('utf-8'))
                if base % 4:
                    padding = (-base - 4) % 4
                    entry.extra = struct.pack('<HH', 0xffff, padding) + bytes(padding)
            after.writestr(entry, data)
    with zipfile.ZipFile(source) as before, zipfile.ZipFile(output) as after:
        assert before.namelist() == after.namelist()
        assert [n for n in before.namelist() if before.read(n) != after.read(n)] == ['resources.arsc']
        assert after.testzip() is None


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    build(a.source, a.output)
