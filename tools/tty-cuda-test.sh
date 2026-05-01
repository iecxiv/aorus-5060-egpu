#!/usr/bin/env bash
# Run the CUDA Driver API smoke test from a multi-user.target context.
#
# Designed to be launched via systemd-run as a transient service so it survives
# the GNOME / OpenCode session disconnection caused by `systemctl isolate
# multi-user.target`. Results are written with fsync at every step so a kernel
# panic does not lose the boundary information.
#
# Output directory (overwritten each run):
#   /root/aorus-cuda-tty-test/
#     status.txt           - high-level state machine
#     progress.txt         - timestamped marker per step (fsync'd line by line)
#     pre-status.txt       - aorus-5090-status before
#     post-status.txt      - aorus-5090-status after (only if not panicked)
#     pre-modules.txt      - lsmod output before
#     post-modules.txt     - lsmod output after
#     smoke-output.txt     - stdout/stderr from the smoke test python
#     smoke-rc.txt         - exit code of the smoke test
#     post-nvidia-smi.txt  - one nvidia-smi after the test (catches leaks)
#     kernel.log           - dmesg dump after the test
#
# After completion (or before, if AORUS_TTY_TEST_NO_RECOVER=1), transitions
# back to graphical.target.

set -uo pipefail

OUT=/root/aorus-cuda-tty-test
mkdir -p "$OUT"

# Safety net: no matter how this script exits (success, failure, signal,
# error from `timeout` killing a child), transition back to graphical.target
# so the user does not get stuck staring at a black TTY. A kernel panic will
# not run this trap; that recovery is via forced reboot.
return_to_graphical() {
    if ! systemctl is-active graphical.target >/dev/null 2>&1; then
        systemctl isolate graphical.target >/dev/null 2>&1 || true
    fi
}
trap return_to_graphical EXIT

# Force pristine outputs - any stale files from a prior run go away.
rm -f "$OUT"/*

mark() {
    printf '%s %s\n' "$(date '+%F %T %Z')" "$*" >> "$OUT/progress.txt"
    sync -f "$OUT/progress.txt" 2>/dev/null || sync
}

set_status() {
    printf '%s\n' "$@" > "$OUT/status.txt"
    sync -f "$OUT/status.txt" 2>/dev/null || sync
}

set_status 'aorus-cuda-tty-test started' 'stage=precheck'
mark 'started'

# Capture full pre-test state, fsync'd
/usr/local/sbin/aorus-5090-status > "$OUT/pre-status.txt" 2>&1
sync -f "$OUT/pre-status.txt" 2>/dev/null || sync
lsmod | grep -E '^nvidia' > "$OUT/pre-modules.txt" 2>&1
sync -f "$OUT/pre-modules.txt" 2>/dev/null || sync
mark 'captured pre-test state'

# Refuse to run if nvidia_uvm is not loaded - that was the failure mode last
# time and must be fixed (and verified) before we attempt cuInit again.
if ! grep -q '^nvidia_uvm' "$OUT/pre-modules.txt"; then
    set_status 'aborted' 'reason=nvidia_uvm_not_pre_loaded'
    mark 'abort: nvidia_uvm not loaded'
    systemctl isolate graphical.target 2>/dev/null
    exit 95
fi

# Refuse to run if persistenced is not active.
if ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    set_status 'aborted' 'reason=persistenced_not_active'
    mark 'abort: persistenced not active'
    systemctl isolate graphical.target 2>/dev/null
    exit 96
fi

mark 'preconditions ok'
set_status 'aorus-cuda-tty-test running' 'stage=smoke_test'

# Run the smoke test with a hard timeout. The test itself exits non-zero on
# any cuda call returning != 0; success is only when it prints 'cuda_smoke=pass'.
mark 'before smoke test'
timeout 30s python3 /root/aorus-5090-gpu/tools/cuda-driver-api-smoke-test.py > "$OUT/smoke-output.txt" 2>&1
smoke_rc=$?
printf '%s\n' "$smoke_rc" > "$OUT/smoke-rc.txt"
sync -f "$OUT/smoke-rc.txt" 2>/dev/null || sync
mark "after smoke test, rc=$smoke_rc"

# Capture post state. If the smoke test actually allocated memory, this will
# show it as leaked (catches the silent-leak failure mode we saw earlier).
sleep 2  # let any deferred allocations settle
timeout 10s nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/post-nvidia-smi.txt" 2>&1
sync -f "$OUT/post-nvidia-smi.txt" 2>/dev/null || sync
mark "captured post nvidia-smi"

/usr/local/sbin/aorus-5090-status > "$OUT/post-status.txt" 2>&1
sync -f "$OUT/post-status.txt" 2>/dev/null || sync
lsmod | grep -E '^nvidia' > "$OUT/post-modules.txt" 2>&1
sync -f "$OUT/post-modules.txt" 2>/dev/null || sync
dmesg -T | tail -200 > "$OUT/kernel.log" 2>&1
sync -f "$OUT/kernel.log" 2>/dev/null || sync
mark 'captured post-test state'

# Final status
if [[ "$smoke_rc" -eq 0 ]] && grep -q 'cuda_smoke=pass' "$OUT/smoke-output.txt"; then
    set_status 'aorus-cuda-tty-test PASSED' "smoke_rc=$smoke_rc"
    mark 'PASSED'
    final_rc=0
else
    set_status 'aorus-cuda-tty-test FAILED' "smoke_rc=$smoke_rc"
    mark 'FAILED'
    final_rc="$smoke_rc"
fi

# Idle 30s before transitioning back. If a delayed panic is going to happen,
# this gives it a chance to occur while we are still in multi-user, where the
# loss is minimal. If we make it past, the EXIT trap restores graphical.
mark 'idle 30s for delayed-panic detection'
sleep 30
mark 'idle complete - EXIT trap will restore graphical.target'

exit "$final_rc"
