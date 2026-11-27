#!/usr/bin/env python3
"""Host-test the actual D43 address-selection functions with mock kernel I/O."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def function(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('kernel', type=Path)
    a = p.parse_args()
    relative = 'drivers/misc/mediatek/connectivity/conn_soc/drv_wlan/mt_wifi/wlan/os/linux/gl_kal.c'
    source = (a.kernel / relative).read_text()
    functions = '\n\n'.join(function(source, signature) for signature in [
        'static BOOLEAN\nq5ReadPersistentNetworkAddress(',
        'BOOLEAN\nkalRetrieveNetworkAddress(',
    ])
    template = (Path(__file__).resolve().parents[1] / 'tests/wifi_mac_host.c').read_text()
    with tempfile.TemporaryDirectory(prefix='q5-wifi-test-') as tmp:
        tmp = Path(tmp)
        (tmp / 'test.c').write_text(template.replace('/* KERNEL FUNCTIONS */', functions))
        subprocess.run(['cc', '-std=gnu99', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-g', str(tmp / 'test.c'),
                        '-o', str(tmp / 'test')], check=True)
        subprocess.run([str(tmp / 'test')], check=True)


if __name__ == '__main__':
    main()
