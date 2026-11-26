#!/usr/bin/env bash
# A physical front camera may be wired to either logical sensor slot.
set -euo pipefail
export Q5_KERNEL_TAG=d41
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
