#!/usr/bin/env bash
# Preserve the verified hardware fixes; add a per-device Wi-Fi MAC fallback.
set -euo pipefail
export Q5_KERNEL_TAG=d43
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
