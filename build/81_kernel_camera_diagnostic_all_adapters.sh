#!/usr/bin/env bash
# D41 bounded diagnostic, also checking bus 2 without touching amp address 0x58.
set -euo pipefail
export Q5_KERNEL_TAG=d42
exec bash "$(dirname "$0")/75_kernel_delta_coherent_dma.sh" "$@"
