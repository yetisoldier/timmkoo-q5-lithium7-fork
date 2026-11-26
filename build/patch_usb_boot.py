#!/usr/bin/env python3
"""Replace legacy MTP+CD-ROM actions with pure MTP in a boot COPY.

Only init.mt6582.usb.rc changes. ADB-only and other USB modes stay intact.
Uses the same bounded repacker and content-preservation assertions as R1.
"""
import argparse
import hashlib
from pathlib import Path
import re
from patch_fm_boot_node import patch

USB_DONOR = '07259948d9820ca60ac59dc8c23dcebf4f732743ffd186393d693752043a1b74'

def transform(data):
    assert hashlib.sha256(data).hexdigest() == USB_DONOR, 'Unexpected USB init donor'
    def replace(match):
        mode = match.group(1)
        adb = mode == b'mtp,adb'
        lines = [b'on property:sys.usb.config=' + mode,
                 b'    # Pure MTP; no legacy mass-storage/CD-ROM interface.',
                 b'    write /sys/class/android_usb/android0/enable 0',
                 b'    write /sys/class/android_usb/android0/idVendor 18d1',
                 b'    write /sys/class/android_usb/android0/idProduct ' + (b'4ee2' if adb else b'4ee1'),
                 b'    write /sys/class/android_usb/android0/functions ' + mode,
                 b'    write /sys/class/android_usb/android0/enable 1']
        if adb:
            lines.append(b'    start adbd')
        lines.append(b'    setprop sys.usb.state ${sys.usb.config}')
        return b'\n'.join(lines) + b'\n\n'
    result, count = re.subn(rb'(?ms)^on property:sys.usb.config=(mtp(?:,adb)?)\n.*?(?=^on |\Z)', replace, data)
    assert count == 2
    assert result != data
    return result

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    assert not a.output.exists()
    result = patch(a.source.read_bytes(), transform, 'init.mt6582.usb.rc')
    a.output.write_bytes(result)
    print(hashlib.sha256(result).hexdigest(), a.output)
