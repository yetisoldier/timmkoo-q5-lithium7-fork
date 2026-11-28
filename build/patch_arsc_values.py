#!/usr/bin/env python3
"""Deterministically patch one named value resource inside an APK's resources.arsc.

Self-verifying binary patch for aapt-compiled APKs (UTF-8 string pools, multiple
configs): no apktool/aapt dependency, raw ARSC chunk walking only. The rebuild
copies every zip entry byte-identical except resources.arsc and preserves entry
order, compression and the 4-byte stored-entry alignment convention of
build/build_branding.py. Emits a JSON manifest (input/output shas, patched ids,
before/after values, arsc byte-diff offsets) consumed by apply_system_defaults
and the release audit. Spec: bob-m5-power-audio §5.2.

T1 (v1.0.1 release recipe):  python3 build/patch_arsc_values.py \
        --apk <donor>/framework/framework-res.apk --out work/v101/framework-res.vc.apk \
        --set-bool config_voice_capable=false --manifest work/v101/framework-res.arsc-manifest.json
T2: same with SettingsProvider.apk and --set-int def_wifi_sleep_policy=0.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import zipfile

ARSC_ENTRY = 'resources.arsc'
RES_TABLE_TYPE = 0x0002
RES_STRING_POOL_TYPE = 0x0001
RES_PACKAGE_TYPE = 0x0200
RES_TABLE_TYPE_SPEC = 0x0202
RES_TABLE_TYPE_TYPE = 0x0201
STRING_POOL_UTF8_FLAG = 0x100
ENTRY_COMPLEX_FLAG = 0x0001
NO_ENTRY = 0xFFFFFFFF
# Data types (Res_value dataType): integer resources use INT_DEC, bools INT_BOOLEAN.
DATA_TYPE_INT_DEC = 0x10
DATA_TYPE_INT_BOOLEAN = 0x12
BOOLEAN_FALSE = 0
BOOLEAN_TRUE = 0xFFFFFFFF
# Matching is by type NAME -> required value dtype (spec §5.2 item 2).
REQUIRED_DTYPE = {'bool': DATA_TYPE_INT_BOOLEAN, 'integer': DATA_TYPE_INT_DEC}


def read_arsc_from_apk(apk_path):
    with zipfile.ZipFile(apk_path) as z:
        assert z.namelist().count(ARSC_ENTRY) == 1, \
            f'APK must contain exactly one {ARSC_ENTRY}: {apk_path}'
        return z.read(ARSC_ENTRY)


def _decode_pool_length(buf, pos):
    """One string-pool length field: 1-byte form, or 2-byte form when the high bit is set."""
    first = buf[pos]
    if first & 0x80:
        return ((first & 0x7F) << 8) | buf[pos + 1], 2
    return first, 1


def _decode_string(buf, flags, pool_start, offset):
    """Decode one pool entry (UTF-8 pools carry utf16len + utf8len length fields)."""
    pos = pool_start + offset
    if flags & STRING_POOL_UTF8_FLAG:
        _utf16_length, first = _decode_pool_length(buf, pos)
        _utf8_length, second = _decode_pool_length(buf, pos + first)
        start = pos + first + second
        end = buf.index(0x00, start)
        return buf[start:end].decode('utf-8', errors='replace')
    length, prefix = _decode_pool_length(buf, pos)
    start = pos + prefix
    return buf[start:start + 2 * length].decode('utf-16-le', errors='replace')


def _parse_string_pool(buf, chunk_start):
    kind, header_size, size, count, _styles, flags, strings_start, _styles_start = \
        struct.unpack_from('<HHIIIIII', buf, chunk_start)
    assert kind == RES_STRING_POOL_TYPE, hex(kind)
    offsets = [struct.unpack_from('<I', buf, chunk_start + header_size + 4 * i)[0]
               for i in range(count)]
    return flags, chunk_start + strings_start, offsets, size


def _config_summary(config):
    return 'default' if config[4:] == bytes(len(config) - 4) else config.hex()[:32]


def scan_named_values(arsc, name, type_name=None):
    """Every config's simple value for resource `name` across all packages.

    Returns a list of hit dicts with the absolute ARSC offsets needed for both
    read-back verification and the byte patch. Entry layout per §5.2: entry
    header = size u16 / flags u16 / key index u32; value = size u16 / res0 u8 /
    dtype u8 / data u32 at entry + size.
    """
    kind, _, _, package_count = struct.unpack_from('<HHII', arsc, 0)
    assert kind == RES_TABLE_TYPE, f'Not a resources.arsc table chunk: {hex(kind)}'
    hits = []
    # headerSize (u16 at +2): the table header spans every chunk before the packages.
    pos = struct.unpack_from('<H', arsc, 2)[0]
    while pos < len(arsc):
        kind, header_size, size = struct.unpack_from('<HHI', arsc, pos)
        if kind != RES_PACKAGE_TYPE:
            pos += size  # global string pool (and anything unexpected): skipped by size
            continue
        package_id, = struct.unpack_from('<I', arsc, pos + 8)
        type_strings, _last_public_type, key_strings, _last_public_key = \
            struct.unpack_from('<IIII', arsc, pos + 268)
        if type_strings and key_strings:
            type_flags, type_pool, type_offsets, _ = \
                _parse_string_pool(arsc, pos + type_strings)
            key_flags, key_pool, key_offsets, _ = \
                _parse_string_pool(arsc, pos + key_strings)
            for index, offset in enumerate(type_offsets):
                type_of = _decode_string(arsc, type_flags, type_pool, offset)
                if type_name is not None and type_of != type_name:
                    continue
                cursor = pos + header_size
                while cursor < pos + size:
                    chunk_kind, chunk_header, chunk_size = \
                        struct.unpack_from('<HHI', arsc, cursor)
                    if chunk_kind == RES_TABLE_TYPE_SPEC:
                        cursor += chunk_size
                        continue
                    if chunk_kind != RES_TABLE_TYPE_TYPE:
                        cursor += chunk_size  # inline pools or library chunks: skipped
                        continue
                    if arsc[cursor + 8] - 1 != index:
                        cursor += chunk_size
                        continue
                    entry_count, entries_start, config_size = \
                        struct.unpack_from('<III', arsc, cursor + 12)
                    config = arsc[cursor + 20:cursor + 20 + config_size]
                    for entry in range(entry_count):
                        entry_offset = struct.unpack_from(
                            '<I', arsc, cursor + chunk_header + 4 * entry)[0]
                        if entry_offset == NO_ENTRY:
                            continue
                        entry_pos = cursor + entries_start + entry_offset
                        entry_size, entry_flags, key_index = \
                            struct.unpack_from('<HHI', arsc, entry_pos)
                        if _decode_string(arsc, key_flags, key_pool,
                                          key_offsets[key_index]) != name:
                            continue
                        assert not entry_flags & ENTRY_COMPLEX_FLAG, \
                            f'{type_of}/{name}: complex (bag) entry cannot be patched'
                        value_pos = entry_pos + entry_size
                        value_size, res0, dtype, data = struct.unpack_from(
                            '<HBBI', arsc, value_pos)
                        data_offset = value_pos + 4
                        assert data_offset % 4 == 0, \
                            f'{type_of}/{name}: value data at unaligned 0x{data_offset:x}'
                        hits.append({
                            'package_id': package_id, 'type_id': arsc[cursor + 8],
                            'entry_index': entry,
                            'resid': (package_id << 24) | (arsc[cursor + 8] << 16) | entry,
                            'name': name, 'type_name': type_of, 'config': _config_summary(config),
                            'entry_pos': entry_pos, 'entry_size': entry_size,
                            'value_size': value_size, 'res0': res0, 'dtype': dtype,
                            'value': data, 'data_offset': data_offset,
                        })
                    cursor += chunk_size
        pos += size
    return hits


def read_named_values(apk_path, name, type_name=None):
    """Verification-side reader (consumed by apply_system_defaults.py): parse an
    APK's resources.arsc and return every config's hit dicts for `name`."""
    return scan_named_values(read_arsc_from_apk(apk_path), name, type_name)


def _differing_dwords(old, new):
    """4-byte-aligned windows that differ between two equal-length blobs."""
    assert len(old) == len(new), 'ARSC length must not change'
    windows = []
    block = 1 << 16
    pos = 0
    while pos < len(old):
        if old[pos:pos + block] == new[pos:pos + block]:
            pos += block
            continue
        for offset in range(pos, min(pos + block, len(old)), 4):
            if old[offset:offset + 4] != new[offset:offset + 4]:
                windows.append(offset)
        pos += block
    return windows


def rebuild_apk(input_path, output_path, replaced_name, data):
    """Copy every entry byte-identical except replaced_name (branding's zip rebuild)."""
    with zipfile.ZipFile(input_path) as before, \
            zipfile.ZipFile(output_path, 'w') as after:
        after.comment = before.comment
        for original_entry in before.infolist():
            entry = copy.copy(original_entry)
            content = data if entry.filename == replaced_name else before.read(entry.filename)
            # Keep stored entries 4-byte aligned, including resources.arsc.
            if entry.compress_type == zipfile.ZIP_STORED:
                entry.extra = b''
                base = after.fp.tell() + 30 + len(entry.filename.encode('utf-8'))
                if base % 4:
                    padding = (-base - 4) % 4
                    entry.extra = struct.pack('<HH', 0xffff, padding) + bytes(padding)
            after.writestr(entry, content)


def patch(apk_path, out_path, manifest_path, operation, name, value):
    """Rewrite `name` to `value` everywhere it matches, then verify and emit a manifest."""
    assert Path(apk_path).resolve() != Path(out_path).resolve(), \
        'Output APK must differ from the input'
    dtype_required = REQUIRED_DTYPE[operation]
    original = read_arsc_from_apk(apk_path)
    hits = scan_named_values(original, name, operation)
    assert hits, (f'No {operation}-typed resource named {name!r} found in {apk_path} '
                  '(matching is by key and type name; refusing to proceed on 0 hits)')
    expected = (BOOLEAN_TRUE if value else BOOLEAN_FALSE) if operation == 'bool' else value
    for hit in hits:
        assert hit['dtype'] == dtype_required, \
            (f"{hit['type_name']}/{name} id=0x{hit['resid']:08x}: dtype "
             f"0x{hit['dtype']:02x} != required 0x{dtype_required:02x} (refusing)")
        assert hit['value_size'] == 8 and hit['entry_size'] >= 8, \
            f"{hit['type_name']}/{name}: unexpected entry/value header sizes"
        print(f"{hit['type_name']}/{name} id=0x{hit['resid']:08x} "
              f"config={hit['config']}: 0x{hit['value']:08x} -> 0x{expected:08x}")
    patched = bytearray(original)
    for hit in hits:
        struct.pack_into('<I', patched, hit['data_offset'], expected)
        hit['before'] = hit['value']
        hit['after'] = expected
    patched = bytes(patched)

    rebuild_apk(apk_path, out_path, ARSC_ENTRY, patched)
    rebuilt = read_arsc_from_apk(out_path)

    # Self-verification 1: the requested values must parse back out of the output APK.
    verified = read_named_values(out_path, name, operation)
    assert len(verified) == len(hits), 'Read-back hit count changed'
    for original_hit, read_back in zip(hits, verified):
        assert original_hit['resid'] == read_back['resid'], \
            (f"Read-back resource moved: 0x{original_hit['resid']:08x} != "
             f"0x{read_back['resid']:08x}")
        assert read_back['dtype'] == dtype_required, \
            f"Read-back dtype drifted: {read_back}"
        assert read_back['value'] == expected, (f"Read-back 0x{read_back['value']:x} != "
                                                f"requested 0x{expected:x} at id="
                                                f"0x{read_back['resid']:08x}")

    # Self-verification 2: the ARSC byte-diff must be exactly the patched value fields.
    diff_offsets = _differing_dwords(original, rebuilt)
    expected_offsets = sorted(hit['data_offset'] for hit in hits if hit['before'] != expected)
    assert diff_offsets == expected_offsets, (
        f'Unexpected ARSC byte changes: diff={diff_offsets} '
        f'expected={expected_offsets}')

    # Self-verification 3: every other zip entry must be byte-identical.
    with zipfile.ZipFile(apk_path) as before, zipfile.ZipFile(out_path) as after:
        assert before.namelist() == after.namelist(), 'Zip entry list must not change'
        assert after.testzip() is None, 'Corrupt entry in the rebuilt APK'
        arsc_compress_before = before.getinfo(ARSC_ENTRY).compress_type
        arsc_compress_after = after.getinfo(ARSC_ENTRY).compress_type
        for name_in_zip in before.namelist():
            if name_in_zip == ARSC_ENTRY:
                continue
            assert (hashlib.sha256(before.read(name_in_zip)).hexdigest()
                    == hashlib.sha256(after.read(name_in_zip)).hexdigest()), name_in_zip
    assert arsc_compress_after == arsc_compress_before, \
        'resources.arsc compression must be preserved'

    manifest = {
        'tool': 'build/patch_arsc_values.py',
        'operation': '--set-' + operation,
        'resource_name': name,
        'resource_id': '0x%08x' % hits[0]['resid'],
        'config_ids': ['0x%08x' % hit['resid'] for hit in hits],
        'patched_count': len(hits),
        'input_apk_sha256': hashlib.sha256(Path(apk_path).read_bytes()).hexdigest(),
        'output_apk_sha256': hashlib.sha256(Path(out_path).read_bytes()).hexdigest(),
        'arsc_sha256': {
            'before': hashlib.sha256(original).hexdigest(),
            'after': hashlib.sha256(rebuilt).hexdigest(),
        },
        'before_values': [hit['before'] for hit in hits],
        'after_values': [hit['after'] for hit in hits],
        'arsc_diff_offsets': diff_offsets,
        'hits': [{'id': '0x%08x' % hit['resid'], 'config': hit['config'],
                  'before': hit['before'], 'after': hit['after'],
                  'dtype': '0x%02x' % hit['dtype'],
                  'arsc_diff_offset': hit['data_offset']} for hit in hits],
        'note': 'All non-arsc zip entries byte-identical (per-entry sha256 verified); '
                'ARSC byte-diff limited to the patched value fields; 4-byte stored-entry '
                'alignment convention preserved.',
    }
    Path(manifest_path).write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


def _parse_operand(operand, operation):
    """Split NAME=VALUE; returns (operation, name, value)."""
    name, separator, raw = operand.partition('=')
    assert separator, f'Expected NAME=VALUE, got {operand!r}'
    if operation == 'bool':
        assert raw in ('false', 'true'), f'--set-bool expects true or false: {raw!r}'
        return operation, name, raw == 'true'
    try:
        return operation, name, int(raw, 10)
    except ValueError:
        raise AssertionError(f'--set-int expects an integer: {raw!r}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument('--set-bool', metavar='NAME=false|true')
    operation.add_argument('--set-int', metavar='NAME=VALUE')
    parser.add_argument('--manifest', required=True, type=Path)
    args = parser.parse_args()
    if args.set_bool:
        parsed = _parse_operand(args.set_bool, 'bool')
    else:
        parsed = _parse_operand(args.set_int, 'integer')
    patch(args.apk, args.out, args.manifest, parsed[0], parsed[1], parsed[2])


if __name__ == '__main__':
    main()
