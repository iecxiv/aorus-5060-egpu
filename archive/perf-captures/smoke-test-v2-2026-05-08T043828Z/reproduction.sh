#!/usr/bin/env bash
# Reproduce perf-capture experiment smoke-test-v2 captured 2026-05-08T043828Z.
# Captured on host=obpc kernel=6.19.14-200.fc43.x86_64
# nvidia srcversion at capture: 86134BFCA6328D4D110DADC

set -e
sudo /root/aorus-5090-gpu/tools/perf-capture/perf-capture.sh \
    --experiment "smoke-test-v2-repro" \
    --workload mode-b-stress \
    --duration 90 \
    --samples-interval 10 \
    --changed smoke=true
