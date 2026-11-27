#!/usr/bin/env bash
# D39 plus opt-in, bounded powered-front-slot camera ID diagnostics.
set -euo pipefail
export Q5_KERNEL_TAG=d40
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
