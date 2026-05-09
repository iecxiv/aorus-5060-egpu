#!/usr/bin/env bash
# Run the PyTorch CUDA smoke test from a multi-user.target context.
#
# Same TTY-with-fsync methodology as tty-cuda-test.sh. Activates the venv,
# runs tools/pytorch-cuda-smoke-test.py, captures pre/post state, idles 30 s
# for delayed-panic detection, EXIT trap restores graphical.target.
#
# Venv must already exist at $VENV_PATH (default /root/torch-test) with
# torch installed. To set up:
#
#     python3 -m venv /root/torch-test
#     /root/torch-test/bin/pip install --upgrade pip
#     /root/torch-test/bin/pip install torch
#
# Output directory (overwritten each run):
#   /root/aorus-pytorch-tty-test/

set -uo pipefail

VENV_PATH="${VENV_PATH:-/root/torch-test}"
TEST_SCRIPT="${TEST_SCRIPT:-/root/aorus-5090-egpu/tools/pytorch-cuda-smoke-test.py}"
OUT="${OUT:-/root/aorus-pytorch-tty-test}"

mkdir -p "$OUT"
rm -f "$OUT"/*

# EXIT trap: restore graphical.target no matter how the script exits
# (success, failure, signal, timeout). Kernel panics will not run this.
return_to_graphical() {
    if ! systemctl is-active graphical.target >/dev/null 2>&1; then
        systemctl isolate graphical.target >/dev/null 2>&1 || true
    fi
}
trap return_to_graphical EXIT

mark() {
    printf '%s %s\n' "$(date '+%F %T %Z')" "$*" >> "$OUT/progress.txt"
    sync -f "$OUT/progress.txt" 2>/dev/null || sync
}

set_status() {
    printf '%s\n' "$@" > "$OUT/status.txt"
    sync -f "$OUT/status.txt" 2>/dev/null || sync
}

set_status 'aorus-pytorch-tty-test started' 'stage=precheck'
mark 'started'

# Capture pre-test state, fsync'd
/usr/local/sbin/aorus-egpu-status > "$OUT/pre-status.txt" 2>&1
sync -f "$OUT/pre-status.txt" 2>/dev/null || sync
lsmod | grep -E '^nvidia' > "$OUT/pre-modules.txt" 2>&1
sync -f "$OUT/pre-modules.txt" 2>/dev/null || sync
nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/pre-nvidia-smi.txt" 2>&1
sync -f "$OUT/pre-nvidia-smi.txt" 2>/dev/null || sync
mark 'captured pre-test state'

# Preconditions
if ! grep -q '^nvidia_uvm' "$OUT/pre-modules.txt"; then
    set_status 'aborted' 'reason=nvidia_uvm_not_loaded'
    mark 'abort: nvidia_uvm not loaded'
    exit 95
fi

if ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    set_status 'aborted' 'reason=persistenced_not_active'
    mark 'abort: persistenced not active'
    exit 96
fi

if [[ ! -x "$VENV_PATH/bin/python3" ]]; then
    set_status 'aborted' "reason=venv_missing path=$VENV_PATH"
    mark "abort: venv at $VENV_PATH does not exist (set up per tools/README.md)"
    exit 97
fi

if [[ ! -f "$TEST_SCRIPT" ]]; then
    set_status 'aborted' "reason=test_script_missing path=$TEST_SCRIPT"
    mark "abort: test script $TEST_SCRIPT not found"
    exit 98
fi

# Quick check that torch is importable in the venv before running the smoke.
# This is a low-cost sanity gate that fails fast if the venv is broken.
if ! "$VENV_PATH/bin/python3" -c 'import torch' >/dev/null 2>&1; then
    set_status 'aborted' 'reason=torch_not_importable_in_venv'
    mark 'abort: import torch failed in venv'
    exit 99
fi

mark 'preconditions ok'
set_status 'aorus-pytorch-tty-test running' 'stage=smoke_test'

# Run the smoke test. 60 s timeout because import torch + first cuda init
# can take 5-10 s on cold start.
mark 'before smoke test'
timeout 60s "$VENV_PATH/bin/python3" "$TEST_SCRIPT" > "$OUT/smoke-output.txt" 2>&1
smoke_rc=$?
printf '%s\n' "$smoke_rc" > "$OUT/smoke-rc.txt"
sync -f "$OUT/smoke-rc.txt" 2>/dev/null || sync
mark "after smoke test, rc=$smoke_rc"

# Capture post state. The post-nvidia-smi catches any memory-allocated leak.
sleep 2  # let any deferred allocations settle
nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/post-nvidia-smi.txt" 2>&1
sync -f "$OUT/post-nvidia-smi.txt" 2>/dev/null || sync
mark 'captured post nvidia-smi'

/usr/local/sbin/aorus-egpu-status > "$OUT/post-status.txt" 2>&1
sync -f "$OUT/post-status.txt" 2>/dev/null || sync
lsmod | grep -E '^nvidia' > "$OUT/post-modules.txt" 2>&1
sync -f "$OUT/post-modules.txt" 2>/dev/null || sync
dmesg -T | tail -200 > "$OUT/kernel.log" 2>&1
sync -f "$OUT/kernel.log" 2>/dev/null || sync
mark 'captured post-test state'

# Final status
if [[ "$smoke_rc" -eq 0 ]] && grep -q 'pytorch_smoke=pass' "$OUT/smoke-output.txt"; then
    set_status 'aorus-pytorch-tty-test PASSED' "smoke_rc=$smoke_rc"
    mark 'PASSED'
    final_rc=0
else
    set_status 'aorus-pytorch-tty-test FAILED' "smoke_rc=$smoke_rc"
    mark 'FAILED'
    final_rc="$smoke_rc"
fi

# Idle window for delayed-panic detection.
mark 'idle 30s for delayed-panic detection'
sleep 30
mark 'idle complete - EXIT trap will restore graphical.target'

exit "$final_rc"
