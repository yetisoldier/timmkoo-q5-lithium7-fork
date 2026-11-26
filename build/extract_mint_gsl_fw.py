#!/usr/bin/env python3
"""Extract Mint's two additional GSL firmware/config pairs, with a source pin."""
import argparse
import hashlib
from pathlib import Path
import struct

KERNEL_SHA = '7738bd7707a77b335146ca35809a1dec619a3ab0df17e0b4eb0a6ea6a6e5d234'
BASE = 0xc0008000
TABLE = 0xc0761064


def extract(kernel):
    blob = kernel.read_bytes()
    assert hashlib.sha256(blob).hexdigest() == KERNEL_SHA, 'Mint kernel source drift'
    text = ['/* Generated from Mint V1.0 kernel SHA256 ' + KERNEL_SHA + '. */',
            '#ifndef _GSLX680_FW_MINT_H_', '#define _GSLX680_FW_MINT_H_', '']
    for index, name, expected_count in [(4, 'ms1_0110', 5016), (5, 'ms1_2038', 4950)]:
        fw, count, cfg, size = struct.unpack_from('<4I', blob, TABLE - BASE + index*16)
        assert count == expected_count and size == 512
        words = struct.unpack_from('<' + str(count*2) + 'I', blob, fw - BASE)
        assert all(words[i] <= 0xf0 and words[i] % 4 == 0 for i in range(0, len(words), 2))
        text.append(f'static const struct fw_data gsl_fw_{name}[{count}] = {{')
        text += [f'\t{{0x{words[i]:08x}, 0x{words[i+1]:08x}}},' for i in range(0, len(words), 2)]
        text += ['};', '', f'static unsigned int gsl_cfg_key_{name}[512] = {{']
        text += [f'\t0x{value:08x},' for value in struct.unpack_from('<512I', blob, cfg - BASE)]
        text += ['};', '']
    text += ['#endif', '']
    return '\n'.join(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.write_text(extract(args.kernel))
