# Q5 Wi-Fi reconnection (D43 / R4)

Post-v1.0.0 changes, tested on the connected Q5 without clearing saved networks,
app accounts or adopted storage. Published v1.0.0 artifacts remain unchanged.

## Findings and resulting behavior

The vendor Wi-Fi record contained no programmed MAC. The original driver's
`wlanUpdateNetworkAddress()` consequently generated `00:08:22` plus three bytes
of uptime on every Wi-Fi restart. Five baseline reconnect cycles all connected,
but used five different addresses. This is a confirmed address-persistence defect;
it does not establish that MAC churn caused every earlier authentication timeout.

D43 changes only the address fallback in the SOC WLAN glue. Valid factory NVRAM
and eFUSE addresses retain precedence. If both are unavailable, the driver reads
a six-byte locally administered unicast address from
`/data/misc/wifi/q5-stable-mac`. Short, oversized, multicast, globally assigned,
missing and unreadable fallback files are rejected. The original fallback remains
available if initialization fails; boot is not blocked. The new file reader
restores the kernel address-space state on both success and error paths.

`q5-wifi-address.sh` creates that per-device address once during post-fs-data,
with 40 random bits, restrictive ownership/mode and atomic non-overwriting
publication. Later boots preserve it. A data reset generates a new fallback;
do not copy this file between players. No calibration bytes or protected/NVRAM
partitions are modified. Both vendor Wi-Fi data files remained byte-identical
through testing. The system image contains the initializer, never a device MAC.

Address stability alone did not resolve every legacy WPA startup stall. The
owner's workaround was tapping the already saved network. The candidate adds
`q5-wifi-reconnect.sh`, triggered when the supplicant starts. For enabled saved
WPA-PSK profiles it requests at most two fresh associations if startup does not
complete, around polling intervals 10 and 20 (nominally 20/40 seconds, plus
command execution time). It exits immediately once the WPA connection completes
and otherwise gives up after 30 polling intervals. It never enables Wi-Fi,
re-enables disabled profiles, forgets networks, changes passwords, pins an AP,
or runs as a permanent monitor. Enterprise/WPS authentication is excluded.

The init service name is `q5-wifi-retry`, within Android 7's 16-character limit.
Wi-Fi shutdown stops the helper. Once connected, its init state is `stopped`;
there is no additional resident recovery process. This is bounded startup
recovery for the old vendor stack, not a replacement of its WPA implementation
or a guarantee against later router/roaming outages.

## Validation

- Actual kernel functions passed host tests with AddressSanitizer and UBSan:
  factory/eFUSE priority, configured override, valid fallback, malformed/truncated/
  oversized/missing files and read errors. The native touch/Home protocol check
  also passed during the D43 build.
- The initializer ran on Android and preserved the same address on a second run.
  Host checks covered distinct generated identities, file mode, invalid files
  and symlink rejection without overwriting existing data.
- Deterministic tests execute the actual recovery script for normal exit,
  one/two retries, exhausted budget, Wi-Fi off, disabled/no profiles, enterprise
  and WPS. Init names and action targets are checked as well.
- Ten normal stop/start checks connected automatically. Six subsequent rapid
  restart checks all retained the address, obtained IPv4 and reached an external
  IP. See [aggregate results](docs/validation/wifi-d43-rapid.json).
- The sixth rapid cycle reproduced a real stall. The helper logged retry 1 at
  20:02:30 and successful recovery/exiting at 20:02:32, without a screen tap.
  End-to-end readiness was 39.3 seconds for that cycle; the other five were
  about 8.2 seconds. Do not describe every connection as instantaneous.
- Full boots with the corrected init hook connected automatically. Bluetooth
  enabled while Wi-Fi external pings passed and was restored to OFF. This is
  not a Bluetooth audio listening test. The owner deferred headphone/FM testing.
- The D43 boot range matched its readback. The complete R4 ramdisk is unchanged;
  speaker, touch, Home, USB and codec hooks remain intact. The original audio
  HAL and Wi-Fi firmware hashes are retained.

The baseline Android 7 Wi-Fi firmware is SHA-256
`07dc74f8a1bb0c5c554803a0429309552b50caa0b9a956d7c4718016a8125b53`.
The Mint MT6582 Wi-Fi blob was tried and could not initialize with this driver;
the original was restored and verified before final testing. Do not substitute
the Mint blob merely because Mint itself works with its older driver stack.

## Reproduction

Build with `build/kernel-d43.series` / `build/82_kernel_persistent_wifi.sh` and
the R1-R4 ramdisk adjustments in [BUILDING](docs/BUILDING.md). The system defaults
builder installs the two scripts and init hook and verifies the Wi-Fi firmware.

On Linux/WSL:

```sh
python3 build/test_wifi_mac.py /path/to/prepared/kernel-3.10
python3 tests/test_wifi_startup_recovery.py
```

With authorized root ADB, this test briefly interrupts the device's Wi-Fi but
does not modify its saved credentials or print network identifiers:

```sh
python build/test_wifi_reconnect.py --cycles 6 --rapid --timeout 60 --output /private/path/results.json
```

Private packet/event logs and network identifiers are not repository artifacts.
