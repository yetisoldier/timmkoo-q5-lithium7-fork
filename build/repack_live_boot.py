#!/usr/bin/env python3
"""Replace only the kernel in a backed-up Android v0/MTK boot partition.

Preserves header addresses, board, cmdline and ramdisk. Outputs a complete,
zero-padded partition image; unrelated stale bytes after the boot payload are
not copied. The source image is never modified.
"""
import argparse
import hashlib
from pathlib import Path
import struct


def repack(source, zimage):
    fields = list(struct.unpack_from('<8s10I', source))
    magic, old_ksz, _, rsz, _, ssz, _, _, page, version, _ = fields
    assert magic == b'ANDROID!' and version == 0, 'Android v0 boot required'
    assert page in (2048, 4096) and ssz == 0, 'unsupported boot layout'
    assert zimage[0x24:0x28] == bytes.fromhex('18286f01'), 'ARM zImage required'
    align = lambda size: (size + page - 1) // page * page
    old_kernel = source[page:page + old_ksz]
    assert old_kernel[:4] == bytes.fromhex('88168858')
    assert old_kernel[8:14] == b'KERNEL'
    ramoff = page + align(old_ksz)
    ramdisk = source[ramoff:ramoff + rsz]
    assert len(ramdisk) == rsz
    mtk = bytearray(old_kernel[:512])
    struct.pack_into('<I', mtk, 4, len(zimage))
    kernel = bytes(mtk) + zimage
    fields[1] = len(kernel)
    out = bytearray(len(source))
    assert page + align(len(kernel)) + align(rsz) <= len(out), 'partition overflow'
    out[:page] = source[:page]
    struct.pack_into('<8s10I', out, 0, *fields)
    out[page:page + len(kernel)] = kernel
    new_ramoff = page + align(len(kernel))
    out[new_ramoff:new_ramoff + rsz] = ramdisk
    boot_id = hashlib.sha1()
    for data in (kernel, ramdisk, b''):
        boot_id.update(data)
        boot_id.update(struct.pack('<I', len(data)))
    out[576:608] = boot_id.digest() + b'\0' * 12
    assert out[new_ramoff:new_ramoff + rsz] == ramdisk
    assert out[64:576] == source[64:576]
    return bytes(out)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('zimage', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = repack(args.source.read_bytes(), args.zimage.read_bytes())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(result)
    print(hashlib.sha256(result).hexdigest(), args.output)
