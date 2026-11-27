#!/usr/bin/env python3
"""Remove the stale major-193 FM mknod from an Android-v0/MTK boot copy.

The kernel's FM class and ueventd create the correct dynamic node. Preserve
the kernel, all other ramdisk entries and header addresses. Never flashes.
"""
import argparse
import gzip
import hashlib
from pathlib import Path
import struct

def entries(blob):
    pos = 0
    while blob[pos:pos+6] in [b'070701', b'070702']:
        start = pos
        head = blob[pos:pos+110]
        fields = [int(head[i:i+8], 16) for i in range(6, 110, 8)]
        size, namesize = fields[6], fields[11]
        name = blob[pos+110:pos+110+namesize-1].decode()
        dataoff = (pos+110+namesize+3) & ~3
        pos = (dataoff+size+3) & ~3
        yield name, blob[dataoff:dataoff+size], blob[start:pos], head, blob[start+110:dataoff]
        if name == 'TRAILER!!!':
            assert not blob[pos:].strip(b'\0'), 'Unexpected cpio trailer data'
            return
    raise ValueError('Invalid newc cpio archive')

def patch(source, transform=None, target='init.mt6582.rc'):
    fields = list(struct.unpack_from('<8s10I', source))
    magic, ksz, _, rsz, _, ssz, _, _, page, version, _ = fields
    assert magic == b'ANDROID!' and version == 0 and ssz == 0
    align = lambda n: (n+page-1)//page*page
    kernel = source[page:page+ksz]
    roff = page+align(ksz)
    rd = source[roff:roff+rsz]
    assert rd[:4] == bytes.fromhex('88168858') and rd[8:14] == b'ROOTFS'
    assert struct.unpack_from('<I', rd, 4)[0] == len(rd)-512
    raw = gzip.decompress(rd[512:])
    before = list(entries(raw))
    result = bytearray()
    changed = []
    for name, data, record, head, namepad in before:
        if name.lstrip('./') == target:
            if transform is not None:
                data = transform(data)
            else:
                old = b'    exec /system/bin/mknod /dev/fm c 193 0\n    chmod 0777 /dev/fm\n    chown system media /dev/fm\n'
                assert data.count(old) == 1, 'Expected original hardcoded FM node block'
                data = data.replace(old, b'    # FM node is created from its dynamic sysfs dev_t by ueventd.\n')
            h = bytearray(head)
            h[54:62] = f'{len(data):08x}'.encode()
            if h[:6] == b'070702':
                h[102:110] = f'{sum(data)&0xffffffff:08x}'.encode()
            record = bytes(h)+namepad+data+bytes((-len(data)) % 4)
            changed.append(name)
        result.extend(record)
    assert len(changed) == 1
    result.extend(bytes((-len(result)) % 512))
    after = list(entries(result))
    assert [(x[0], x[1]) for x in before if x[0] not in changed] == [(x[0], x[1]) for x in after if x[0] not in changed]
    rules = next(x[1] for x in after if x[0].lstrip('./') == 'ueventd.mt6582.rc')
    assert b'/dev/fm' in rules and b'0660  media       media' in rules
    packed = gzip.compress(bytes(result), mtime=0)
    mtk = bytearray(rd[:512])
    struct.pack_into('<I', mtk, 4, len(packed))
    ramdisk = bytes(mtk)+packed
    fields[3] = len(ramdisk)
    out = bytearray(len(source))
    assert roff+align(len(ramdisk)) <= len(out)
    out[:page] = source[:page]
    struct.pack_into('<8s10I', out, 0, *fields)
    out[page:page+ksz] = kernel
    out[roff:roff+len(ramdisk)] = ramdisk
    bootid = hashlib.sha1()
    for part in [kernel, ramdisk, b'']:
        bootid.update(part)
        bootid.update(struct.pack('<I', len(part)))
    out[576:608] = bootid.digest()+bytes(12)
    assert out[64:576] == source[64:576]
    assert out[page:page+ksz] == kernel
    return bytes(out)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    data = patch(args.source.read_bytes())
    args.output.write_bytes(data)
    print(hashlib.sha256(data).hexdigest(), args.output)
