#!/usr/bin/env bash
# reset.sh — recover the eGPU stack from a degraded state without rebooting.
#
# Sibling to apply.sh / status.sh / remove.sh. Sources lib/install-manifest.sh
# and /etc/aorus-egpu/config.env for the same per-host topology used by the
# rest of the stack.
#
# Usage:
#   sudo ./reset.sh --probe              # read-only health check
#   sudo ./reset.sh --recover            # active recovery (escalating levels)
#   sudo ./reset.sh --auto               # probe; if degraded, recover; report
#   sudo ./reset.sh --recover --level N  # run only level N (1..4)
#   sudo ./reset.sh --verbose            # add diagnostic output (any mode)
#
# Exit codes:
#   0  healthy (probe) / recovery succeeded (recover/auto)
#   1  degraded but recoverable; recovery not attempted (--probe only)
#   2  hard-wedged; recovery cannot help (e.g., link down, config space dead)
#   3  recovery attempted and failed; reboot required
#
# Recovery escalation (each level preserves BAR allocations):
#   L1: module reload     — restart aorus-egpu-compute-load-nvidia.service.
#                           Cheapest; clears stuck-driver-state failures.
#   L2: BAR1 resize       — if BAR1 < expected size, write the size index to
#                           /sys/bus/pci/devices/<bdf>/resource1_resize. Use
#                           when an earlier remove+rescan shrank BAR1.
#   L3: secondary bus reset on parent bridge — preserves BAR allocations
#                           because the device isn't removed; just reset.
#   L4: M-recover force-trigger — invokes the in-driver state machine via
#                           /sys/.../tb_egpu_lever_m_force_trigger. Honours
#                           rate-limit (H2) and MaxAttempts gate (H1).
#
# Hard guards (NEVER do):
#   - PCI remove + rescan (loses 16 GiB BAR1 sizing on this hardware class —
#     kernel runtime allocator can't restore firmware-sized prefetchable space)
#   - boltctl power off/on (not supported on this hardware class)
#   - TB tunnel deauthorize/authorize (drops the PCI device → same BAR1 issue)

set -uo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "reset.sh must be run as root" >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

# shellcheck source=lib/install-manifest.sh
source "$repo_root/lib/install-manifest.sh"

# Per-host topology (autodetected by aorus-egpu-detect-config + config.env).
if [[ -r /etc/aorus-egpu/config.env ]]; then
    # shellcheck source=/dev/null
    source /etc/aorus-egpu/config.env
fi
: "${EGPU_VENDOR_ID:=0x10de}"
: "${EGPU_DEVICE_ID:=0x2d04}"
: "${EGPU_BDF:=0000:04:00.0}"
: "${EGPU_AUDIO_BDF:=0000:04:00.1}"
: "${EGPU_BRIDGE_BDF:=0000:03:00.0}"

# Expected BAR1 size for healthy state (16 GiB = 0x400000000 bytes).
# Index is log2(MiB) — 16 GiB = 16384 MiB = 2^14.
EXPECTED_BAR1_BYTES=17179869184
EXPECTED_BAR1_SIZE_INDEX=14

# Mode + verbosity.
MODE=""
LEVEL_FILTER=""
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --probe)    MODE="probe" ;;
        --recover)  MODE="recover" ;;
        --auto)     MODE="auto" ;;
        --level)    shift; LEVEL_FILTER="$1" ;;
        --verbose)  VERBOSE=1 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done
[[ -n "$MODE" ]] || MODE="probe"

# ANSI colours
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_FAIL=''; C_INFO=''; C_BOLD=''; C_RESET=''
fi

ok()    { printf '  %s[OK]%s   %s\n'   "$C_OK"   "$C_RESET" "$*"; }
warn()  { printf '  %s[WARN]%s %s\n'   "$C_WARN" "$C_RESET" "$*"; }
fail()  { printf '  %s[FAIL]%s %s\n'   "$C_FAIL" "$C_RESET" "$*"; }
info()  { printf '  %s[INFO]%s %s\n'   "$C_INFO" "$C_RESET" "$*"; }
debug() { ((VERBOSE)) && printf '  [DBG]  %s\n' "$*" || true; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# ========================================================================
# PROBE — read-only health check.
# Returns 0 (healthy), 1 (degraded), 2 (wedged).
# Sets globals: PROBE_VERDICT, PROBE_RECOMMEND_LEVEL.
# ========================================================================

probe() {
    section "Probe — eGPU health check"
    local verdict=0
    local recommend_level=0

    # ----- Layer 1: PCI device exists and config space responds -----
    if [[ ! -e "/sys/bus/pci/devices/$EGPU_BDF" ]]; then
        fail "GPU not present at $EGPU_BDF — TB tunnel may be down. Reboot or power-cycle eGPU."
        verdict=2
    else
        ok "GPU device present at $EGPU_BDF"
        local vendor
        vendor=$(setpci -s "$EGPU_BDF" VENDOR_ID 2>/dev/null)
        if [[ "$vendor" == "${EGPU_VENDOR_ID#0x}" ]]; then
            ok "PCI config space responsive (vendor=0x$vendor)"
        else
            fail "PCI config space unresponsive (got '$vendor', expected ${EGPU_VENDOR_ID#0x})"
            verdict=2
        fi
    fi

    if [[ $verdict -ge 2 ]]; then
        PROBE_VERDICT=$verdict
        PROBE_RECOMMEND_LEVEL=0
        return $verdict
    fi

    # ----- Layer 2: link active on parent bridge -----
    local lnksta_hex lnksta active speed width
    lnksta_hex=$(setpci -s "$EGPU_BRIDGE_BDF" CAP_EXP+0x12.W 2>/dev/null)
    if [[ -n "$lnksta_hex" ]]; then
        lnksta=$((0x$lnksta_hex))
        active=$(((lnksta >> 13) & 1))
        speed=$((lnksta & 0xf))
        width=$(((lnksta >> 4) & 0x3f))
        if [[ $active -eq 1 ]]; then
            ok "PCIe link active on $EGPU_BRIDGE_BDF (Gen$speed x$width)"
        else
            fail "PCIe link DOWN on $EGPU_BRIDGE_BDF (LnkSta=0x$lnksta_hex)"
            verdict=2
        fi
    fi

    # ----- Layer 3: BAR1 size -----
    local bar1_start bar1_end bar1_size
    read -r bar1_start bar1_end _ < <(awk 'NR==2 {print $1, $2}' "/sys/bus/pci/devices/$EGPU_BDF/resource")
    if [[ -n "${bar1_start:-}" && -n "${bar1_end:-}" ]]; then
        bar1_size=$((bar1_end - bar1_start + 1))
        local bar1_human
        if [[ $bar1_size -ge 1073741824 ]]; then
            bar1_human="$((bar1_size / 1073741824)) GiB"
        else
            bar1_human="$((bar1_size / 1048576)) MiB"
        fi
        if [[ $bar1_size -ge $EXPECTED_BAR1_BYTES ]]; then
            ok "BAR1 size: $bar1_human (>= expected 16 GiB)"
        else
            fail "BAR1 too small: $bar1_human (expected 16 GiB) — runtime ReBAR resize required"
            verdict=$((verdict > 1 ? verdict : 1))
            recommend_level=2
        fi
    else
        warn "could not read BAR1 from $EGPU_BDF/resource"
    fi

    # ----- Layer 4: GPU bound to nvidia driver -----
    if [[ -e "/sys/bus/pci/devices/$EGPU_BDF/driver" ]]; then
        local drv
        drv=$(basename "$(readlink "/sys/bus/pci/devices/$EGPU_BDF/driver")")
        if [[ "$drv" == "nvidia" ]]; then
            ok "GPU bound to nvidia driver"
        else
            warn "GPU bound to unexpected driver: $drv"
            verdict=$((verdict > 1 ? verdict : 1))
            recommend_level=$((recommend_level > 1 ? recommend_level : 1))
        fi
    else
        warn "GPU not bound to any driver"
        verdict=$((verdict > 1 ? verdict : 1))
        recommend_level=$((recommend_level > 1 ? recommend_level : 1))
    fi

    # ----- Layer 5: nvidia kernel module loaded -----
    if lsmod | awk '{print $1}' | grep -qx nvidia; then
        ok "nvidia kernel module loaded ($(cat /sys/module/nvidia/version 2>/dev/null))"
    else
        warn "nvidia kernel module NOT loaded"
        verdict=$((verdict > 1 ? verdict : 1))
        recommend_level=$((recommend_level > 1 ? recommend_level : 1))
    fi

    # ----- Layer 6: Lever M-recover counters -----
    local mr_fires=0 mr_surrenders=0 mr_safe_for_smi=1
    if [[ -e "/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_fires" ]]; then
        mr_fires=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_fires")
        local mr_successes mr_last_jf
        mr_successes=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_successes")
        mr_surrenders=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_surrenders")
        mr_last_jf=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_last_fire_jiffies")
        info "Lever M-recover: fires=$mr_fires successes=$mr_successes surrenders=$mr_surrenders"
        if [[ $mr_surrenders -gt 0 ]]; then
            warn "M-recover has surrendered $mr_surrenders time(s) — driver in lost state; nvidia-smi will be skipped"
            mr_safe_for_smi=0
            verdict=$((verdict > 1 ? verdict : 1))
        fi
    else
        debug "M-recover sysfs absent (driver not loaded, or pre-Lever-M build)"
    fi

    # ----- Layer 7: nvidia-smi smoke test -----
    if [[ $mr_safe_for_smi -eq 1 ]] && { [[ $verdict -eq 0 ]] || ((VERBOSE)); }; then
        local smi_out
        smi_out=$(timeout 5 nvidia-smi -L 2>&1)
        if echo "$smi_out" | grep -qE '^GPU [0-9]+:'; then
            ok "nvidia-smi sees GPU: $(echo "$smi_out" | head -1)"
        else
            warn "nvidia-smi cannot enumerate GPU: $smi_out"
            verdict=$((verdict > 1 ? verdict : 1))
            recommend_level=$((recommend_level > 1 ? recommend_level : 1))
        fi
    elif [[ $mr_safe_for_smi -eq 0 ]]; then
        info "nvidia-smi smoke test skipped (driver in lost state; would escalate wedge)"
    fi

    PROBE_VERDICT=$verdict
    PROBE_RECOMMEND_LEVEL=$recommend_level
    case $verdict in
        0) printf '\n%s✓ HEALTHY%s\n' "$C_OK" "$C_RESET" ;;
        1) printf '\n%s⚠ DEGRADED%s — recoverable (suggested level: %d)\n' "$C_WARN" "$C_RESET" "$recommend_level" ;;
        2) printf '\n%s✗ WEDGED%s — config space / link unresponsive; reboot required\n' "$C_FAIL" "$C_RESET" ;;
    esac
    return $verdict
}

# ========================================================================
# RECOVERY LEVELS
# ========================================================================

recover_l1_service_reload() {
    section "L1 — module reload via aorus-egpu-compute-load-nvidia"
    systemctl stop nvidia-persistenced.service 2>/dev/null || true
    systemctl stop aorus-egpu-uvm-keepalive.service 2>/dev/null || true
    systemctl stop ollama.service 2>/dev/null || true
    modprobe -r nvidia_uvm 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true
    sleep 1
    if systemctl restart aorus-egpu-compute-load-nvidia.service 2>&1; then
        ok "compute-load-nvidia.service restarted"
        systemctl restart nvidia-persistenced.service 2>/dev/null || true
        sleep 1
        return 0
    else
        warn "compute-load-nvidia.service restart failed"
        return 1
    fi
}

recover_l2_bar1_resize() {
    section "L2 — BAR1 resize via resource1_resize"
    local resize_path="/sys/bus/pci/devices/$EGPU_BDF/resource1_resize"
    if [[ ! -e "$resize_path" ]]; then
        warn "resource1_resize not available (kernel < 6.0?); skipping L2"
        return 1
    fi
    systemctl stop nvidia-persistenced.service 2>/dev/null || true
    systemctl stop aorus-egpu-uvm-keepalive.service 2>/dev/null || true
    if [[ -e "/sys/bus/pci/devices/$EGPU_BDF/driver" ]]; then
        echo "$EGPU_BDF" > "/sys/bus/pci/drivers/nvidia/unbind" 2>/dev/null || true
    fi
    modprobe -r nvidia_uvm 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true
    sleep 1
    info "writing size index $EXPECTED_BAR1_SIZE_INDEX to $resize_path"
    if echo "$EXPECTED_BAR1_SIZE_INDEX" > "$resize_path" 2>/dev/null; then
        ok "BAR1 resize accepted by kernel"
    else
        warn "BAR1 resize rejected (bridge window too small or device busy)"
        return 1
    fi
    sleep 1
    if systemctl restart aorus-egpu-compute-load-nvidia.service 2>&1; then
        systemctl restart nvidia-persistenced.service 2>/dev/null || true
        sleep 1
        return 0
    fi
    return 1
}

recover_l3_bus_reset() {
    section "L3 — secondary bus reset on parent bridge $EGPU_BRIDGE_BDF"
    local reset_path="/sys/bus/pci/devices/$EGPU_BRIDGE_BDF/reset"
    if [[ ! -w "$reset_path" ]]; then
        warn "$reset_path not writable; skipping L3"
        return 1
    fi
    systemctl stop nvidia-persistenced.service 2>/dev/null || true
    systemctl stop aorus-egpu-uvm-keepalive.service 2>/dev/null || true
    modprobe -r nvidia_uvm 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true
    info "issuing bus reset on $EGPU_BRIDGE_BDF"
    if echo 1 > "$reset_path" 2>/dev/null; then
        ok "bus reset completed"
    else
        warn "bus reset write failed"
        return 1
    fi
    sleep 2
    if systemctl restart aorus-egpu-compute-load-nvidia.service 2>&1; then
        systemctl restart nvidia-persistenced.service 2>/dev/null || true
        sleep 1
        return 0
    fi
    return 1
}

recover_l4_m_recover_force() {
    section "L4 — Lever M-recover force-trigger (INVASIVE — does pci_reset_bus)"
    local trigger_path="/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_force_trigger"
    if [[ ! -e "$trigger_path" ]]; then
        warn "M-recover sysfs not available (driver not loaded?); skipping L4"
        return 1
    fi
    local pre_fires pre_surrenders
    pre_fires=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_fires")
    pre_surrenders=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_surrenders")
    info "writing 1 to $trigger_path (pre: fires=$pre_fires surrenders=$pre_surrenders)"
    if echo 1 > "$trigger_path" 2>/dev/null; then
        ok "M-recover triggered"
    else
        warn "M-recover trigger write failed (rate-limited or kill-switch engaged)"
        return 1
    fi
    info "waiting for M-recover cycle to complete (up to 30s)..."
    local i
    for ((i=1; i<=30; i++)); do
        sleep 1
        local now_fires now_surrenders
        now_fires=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_fires")
        now_surrenders=$(<"/sys/bus/pci/devices/$EGPU_BDF/tb_egpu_lever_m_surrenders")
        if [[ $now_fires -gt $pre_fires || $now_surrenders -gt $pre_surrenders ]]; then
            debug "M-recover cycle observed at +${i}s"
            sleep 2
            break
        fi
    done
    return 0
}

verify_post_recovery() {
    section "Verify post-recovery state"
    probe
    return $?
}

run_recovery() {
    local levels_to_try=()
    if [[ -n "$LEVEL_FILTER" ]]; then
        levels_to_try=("$LEVEL_FILTER")
    elif [[ "$MODE" == "auto" ]]; then
        case "${PROBE_RECOMMEND_LEVEL:-0}" in
            2) levels_to_try=(2 1 3 4) ;;
            3) levels_to_try=(1 3 4) ;;
            *) levels_to_try=(1 2 3 4) ;;
        esac
    else
        levels_to_try=(1 2 3 4)
    fi

    for level in "${levels_to_try[@]}"; do
        local rc
        case $level in
            1) recover_l1_service_reload; rc=$? ;;
            2) recover_l2_bar1_resize; rc=$? ;;
            3) recover_l3_bus_reset; rc=$? ;;
            4) recover_l4_m_recover_force; rc=$? ;;
            *) fail "unknown level: $level"; return 3 ;;
        esac
        debug "L$level returned $rc"

        verify_post_recovery
        if [[ $PROBE_VERDICT -eq 0 ]]; then
            printf '\n%s✓ Recovery succeeded at L%d%s\n' "$C_OK" "$level" "$C_RESET"
            return 0
        fi
        if [[ $PROBE_VERDICT -eq 2 ]]; then
            printf '\n%s✗ Hard wedge after L%d — config space / link dead.%s Reboot required.\n' \
                "$C_FAIL" "$level" "$C_RESET"
            return 3
        fi
    done

    printf '\n%s✗ All recovery levels exhausted; system still degraded.%s Reboot recommended.\n' \
        "$C_FAIL" "$C_RESET"
    return 3
}

case "$MODE" in
    probe)
        probe
        exit $PROBE_VERDICT
        ;;
    recover)
        run_recovery
        exit $?
        ;;
    auto)
        probe
        if [[ $PROBE_VERDICT -eq 0 ]]; then
            exit 0
        elif [[ $PROBE_VERDICT -eq 2 ]]; then
            printf '\n%s✗ Hard wedge — recovery skipped.%s Reboot required.\n' "$C_FAIL" "$C_RESET"
            exit 2
        fi
        run_recovery
        exit $?
        ;;
esac
