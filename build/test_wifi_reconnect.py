#!/usr/bin/env python3
"""Cycle the connected Q5's Wi-Fi and verify automatic IPv4/MAC persistence.

Requires authorized root ADB. Briefly interrupts Wi-Fi; never forgets networks,
reads credentials, or prints network names/addresses. Writes aggregate JSON only.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def shell(command):
    return subprocess.run(['adb', 'shell', command], capture_output=True,
                          encoding='utf-8', errors='replace', timeout=15)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cycles', type=int, default=6)
    p.add_argument('--timeout', type=int, default=45)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rapid', action='store_true', help='Stress the asynchronous stop/start path')
    a = p.parse_args()
    assert 1 <= a.cycles <= 10 and 10 <= a.timeout <= 60
    assert 'uid=0(root)' in shell('id').stdout, 'Root ADB required'
    expected = subprocess.check_output(['adb', 'exec-out', 'cat',
                                        '/data/misc/wifi/q5-stable-mac'])
    assert len(expected) == 6 and expected[0] & 3 == 2
    expected_text = ':'.join(f'{b:02x}' for b in expected)
    results = []
    for cycle in range(1, a.cycles + 1):
        shell('svc wifi disable').check_returncode()
        if a.rapid:
            time.sleep(2)
        else:
            for _ in range(15):
                if shell('getprop init.svc.p2p_supplicant').stdout.strip() != 'running':
                    break
                time.sleep(1)
            time.sleep(1)
        start = time.monotonic()
        shell('svc wifi enable').check_returncode()
        status = {}
        while time.monotonic() - start < a.timeout:
            response = shell('wpa_cli -i wlan0 status').stdout
            status = dict(line.split('=', 1) for line in response.splitlines() if '=' in line)
            if status.get('wpa_state') == 'COMPLETED' and status.get('ip_address'):
                break
            time.sleep(1)
        connected = status.get('wpa_state') == 'COMPLETED' and bool(status.get('ip_address'))
        elapsed = round(time.monotonic() - start, 1)
        current = shell('cat /sys/class/net/wlan0/address').stdout.strip()
        # An address can appear before netd installs the per-network routes.
        internet = False
        while connected and time.monotonic() - start < a.timeout:
            internet = shell('ping -c 1 -W 2 1.1.1.1').returncode == 0
            if internet:
                break
            time.sleep(1)
        record = {'cycle': cycle, 'automatic_ipv4': connected, 'seconds': elapsed,
                  'persistent_mac': current == expected_text, 'external_ping': internet,
                  'ready_seconds': round(time.monotonic() - start, 1)}
        results.append(record)
        a.output.write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(record), flush=True)
        assert connected and record['persistent_mac'] and internet, 'Reconnect regression'
        time.sleep(2)


if __name__ == '__main__':
    main()
