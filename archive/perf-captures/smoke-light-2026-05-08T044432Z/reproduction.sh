#!/usr/bin/env bash
# Reproduce perf-capture experiment smoke-light captured 2026-05-08T044432Z.
# Captured on host=obpc kernel=6.19.14-200.fc43.x86_64
# nvidia srcversion at capture: 86134BFCA6328D4D110DADC

set -e
sudo /root/aorus-5090-gpu/tools/perf-capture/perf-capture.sh \
    --experiment "smoke-light-repro" \
    --workload mode-b-stress-light \
    --duration 60 \
    --samples-interval 5 \
    --changed smoke=true
