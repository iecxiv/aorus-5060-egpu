#!/usr/bin/env bash
# Reproduce perf-capture experiment smoke-test captured 2026-05-08T043550Z.
# Captured on host=obpc kernel=6.19.14-200.fc43.x86_64
# nvidia srcversion at capture: 86134BFCA6328D4D110DADC

set -e
sudo /root/aorus-5090-gpu/tools/perf-capture/perf-capture.sh \
    --experiment "smoke-test-repro" \
    --workload mode-b-stress \
    --duration 60 \
    --samples-interval 10 \
    --changed smoke=true
