#!/usr/bin/env bash
# D45 (phantom-input storm kill) + D46 (WLAN AHB ISR window):
# build the d46 kernel. Never flashes a device.
set -euo pipefail
export Q5_KERNEL_TAG=d46
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
