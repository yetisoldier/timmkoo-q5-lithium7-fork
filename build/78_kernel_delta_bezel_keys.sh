#!/usr/bin/env bash
# D39: route bezel keys only through the keypad input device.
set -euo pipefail
export Q5_KERNEL_TAG=d39
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
