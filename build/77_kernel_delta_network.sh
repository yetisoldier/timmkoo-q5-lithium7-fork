#!/usr/bin/env bash
# D38: avoid the old ARM jump-label write-to-RO-text panic.
set -euo pipefail
export Q5_KERNEL_TAG=d38
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
