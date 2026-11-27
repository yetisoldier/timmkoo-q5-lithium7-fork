#!/usr/bin/env bash
# D37: Mint panel selection + two additional firmware/config pairs.
set -euo pipefail
export Q5_KERNEL_TAG=d37
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
