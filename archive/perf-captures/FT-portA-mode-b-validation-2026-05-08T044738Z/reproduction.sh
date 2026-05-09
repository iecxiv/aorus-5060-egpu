#!/usr/bin/env bash
# Reproduce perf-capture experiment FT-portA-mode-b-validation captured 2026-05-08T044738Z.
# Captured on host=obpc kernel=6.19.14-200.fc43.x86_64
# nvidia srcversion at capture: 86134BFCA6328D4D110DADC

set -e
sudo /root/aorus-5090-gpu/tools/perf-capture/perf-capture.sh \
    --experiment "FT-portA-mode-b-validation-repro" \
    --workload mode-b-stress-light \
    --duration 300 \
    --samples-interval 15 \
    --changed port=A \
    --changed patch=0023-v2 \
    --changed srcversion=86134BFCA6328D4D110DADC \
    --changed h9a-pcie-tune-service=DISABLED \
    --changed workload-rationale=DMA-path-only-thermally-friendly
