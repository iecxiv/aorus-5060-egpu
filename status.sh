#!/usr/bin/env bash
# Comprehensive health check for the AORUS RTX 5090 eGPU stack.
#
# Verifies every load-bearing piece of the configuration: boot args, kernel
# modules, udev rules, modprobe configs, scripts, systemd units, PCI device
# state, Thunderbolt, persistenced, DRM, and recent kernel log signals.
#
# Exit codes:
#   0  all checks pass
#   1  warnings present (system functional but suboptimal)
#   2  failures present (system broken or freeze-prone)

set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ANSI colours; only emit if stdout is a TTY.
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
else
    C_OK=''; C_WARN=''; C_FAIL=''; C_INFO=''; C_RESET=''; C_BOLD=''
fi

# Counters for the summary footer
ok_count=0
warn_count=0
fail_count=0

ok()   { printf '  %s[OK]%s   %s\n'   "$C_OK"   "$C_RESET" "$*"; ok_count=$((ok_count+1)); }
warn() { printf '  %s[WARN]%s %s\n'   "$C_WARN" "$C_RESET" "$*"; warn_count=$((warn_count+1)); }
fail() { printf '  %s[FAIL]%s %s\n'   "$C_FAIL" "$C_RESET" "$*"; fail_count=$((fail_count+1)); }
info() { printf '  %s[INFO]%s %s\n'   "$C_INFO" "$C_RESET" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

check_arg_in_cmdline() {
    local arg="$1"
    if grep -qE "(^| )${arg}( |$)" /proc/cmdline; then
        ok "$arg"
    else
        fail "$arg missing from /proc/cmdline"
    fi
}

# -------------------------------------------------------------- 1. boot args -
section "1. Boot arguments (/proc/cmdline)"

check_arg_in_cmdline 'thunderbolt.host_reset=false'
check_arg_in_cmdline 'pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0'
check_arg_in_cmdline 'module_blacklist=nouveau,nova_core'
check_arg_in_cmdline 'rd.driver.blacklist=nouveau,nova_core'
check_arg_in_cmdline 'modprobe.blacklist=nouveau,nova_core'

if [[ -r /sys/module/thunderbolt/parameters/host_reset ]]; then
    hr="$(</sys/module/thunderbolt/parameters/host_reset)"
    if [[ "$hr" == "N" ]]; then
        ok "thunderbolt host_reset runtime: N (matches boot arg)"
    else
        fail "thunderbolt host_reset runtime: $hr (boot arg not in effect)"
    fi
else
    warn "/sys/module/thunderbolt/parameters/host_reset not readable"
fi

# ---------------------------------------------------------- 2. kernel modules -
section "2. Kernel modules"

mod_loaded() {
    local m="$1"
    awk '$1 == "'"$m"'" {found=1; exit} END {exit !found}' /proc/modules
}

mod_refcount() {
    local m="$1"
    awk '$1 == "'"$m"'" {print $3; exit}' /proc/modules
}

if mod_loaded nouveau; then fail "nouveau is LOADED (should never happen)"; else ok "nouveau: unloaded"; fi
if mod_loaded nova_core; then fail "nova_core is LOADED (should never happen)"; else ok "nova_core: unloaded"; fi

if mod_loaded nvidia; then
    rc=$(mod_refcount nvidia)
    ok "nvidia: loaded (refcount=$rc)"
else
    fail "nvidia: NOT loaded"
fi

if mod_loaded nvidia_drm; then
    fail "nvidia_drm is LOADED (compute-only mode requires this NOT loaded)"
else
    ok "nvidia_drm: unloaded (compute-only)"
fi

if mod_loaded nvidia_modeset; then
    warn "nvidia_modeset: loaded (unexpected for compute-only)"
else
    ok "nvidia_modeset: unloaded"
fi

if mod_loaded nvidia_uvm; then
    info "nvidia_uvm: loaded (auto-loads on first CUDA use; not required at idle)"
else
    info "nvidia_uvm: unloaded (will load on first CUDA use)"
fi

# -------------------------------------------------------- 3. config files --
section "3. Configuration files (content match against repo)"

check_file_match() {
    local repo_file="$1" sys_file="$2"
    if [[ ! -e "$sys_file" ]]; then
        fail "$sys_file missing"
    elif cmp -s "$repo_file" "$sys_file"; then
        ok "$sys_file"
    else
        warn "$sys_file installed but differs from repo"
    fi
}

check_file_match etc/udev/rules.d/79-aorus-5090-no-autoload.rules \
                 /etc/udev/rules.d/79-aorus-5090-no-autoload.rules
check_file_match etc/udev/rules.d/81-aorus-5090-compute-power.rules \
                 /etc/udev/rules.d/81-aorus-5090-compute-power.rules
check_file_match etc/modprobe.d/aorus-5090-compute-only.conf \
                 /etc/modprobe.d/aorus-5090-compute-only.conf
check_file_match etc/modprobe.d/blacklist-nouveau.conf \
                 /etc/modprobe.d/blacklist-nouveau.conf
check_file_match etc/systemd/system/aorus-5090-compute-load-nvidia.service \
                 /etc/systemd/system/aorus-5090-compute-load-nvidia.service
check_file_match etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf \
                 /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf

# -------------------------------------------------------------- 4. scripts --
section "4. Scripts"

check_script() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        fail "$path missing"
    elif [[ ! -x "$path" ]]; then
        fail "$path exists but not executable"
    else
        ok "$path"
    fi
}

check_script /usr/local/sbin/aorus-5090-compute-load-nvidia
check_script /usr/local/sbin/aorus-5090-disable-audio
check_script /usr/local/sbin/aorus-5090-status

# ---------------------------------------------------- 5. systemd unit state -
section "5. systemd units"

check_unit_state() {
    local unit="$1" expected="$2"
    local actual
    actual="$(systemctl is-enabled "$unit" 2>&1 || true)"
    if [[ "$actual" == "$expected" ]]; then
        ok "$unit: $actual"
    else
        fail "$unit: $actual (expected $expected)"
    fi
}

check_unit_state aorus-5090-compute-load-nvidia.service enabled
check_unit_state nvidia-persistenced.service enabled
check_unit_state nvidia-fallback.service masked
check_unit_state nvidia-powerd.service disabled

active_state() {
    local unit="$1"
    systemctl is-active "$unit" 2>&1 || true
}

a="$(active_state aorus-5090-compute-load-nvidia.service)"
case "$a" in
    active|activating)
        ok "aorus-5090-compute-load-nvidia.service active state: $a"
        ;;
    failed)
        fail "aorus-5090-compute-load-nvidia.service active state: failed"
        ;;
    inactive)
        if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
            warn "aorus-5090-compute-load-nvidia.service: inactive (eGPU is present, expected active)"
        else
            ok "aorus-5090-compute-load-nvidia.service: inactive (eGPU not present, condition skip is correct)"
        fi
        ;;
    *)
        warn "aorus-5090-compute-load-nvidia.service active state: $a"
        ;;
esac

a="$(active_state nvidia-persistenced.service)"
case "$a" in
    active) ok "nvidia-persistenced.service active state: active" ;;
    failed) fail "nvidia-persistenced.service active state: failed" ;;
    inactive)
        if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
            if pgrep -x nvidia-persiste >/dev/null; then
                warn "nvidia-persistenced.service: inactive but daemon is running outside systemd (manual start) - reboot to align"
            else
                fail "nvidia-persistenced.service: inactive AND no daemon running (nvidia-smi will freeze on second invocation)"
            fi
        else
            ok "nvidia-persistenced.service: inactive (eGPU not present)"
        fi
        ;;
    *) warn "nvidia-persistenced.service active state: $a" ;;
esac

# Drop-in for persistenced
if [[ -f /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf ]]; then
    ok "persistenced drop-in: /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf"
else
    fail "persistenced drop-in missing"
fi

# ----------------------------------------------------- 6. PCI device state --
section "6. PCI device state"

gpu_dev=""
audio_dev=""
for dev in /sys/bus/pci/devices/*; do
    [[ -r "$dev/vendor" && -r "$dev/device" ]] || continue
    if [[ "$(<"$dev/vendor")" == "0x10de" && "$(<"$dev/device")" == "0x2b85" ]]; then
        gpu_dev="$dev"
    fi
    if [[ "$(<"$dev/vendor")" == "0x10de" && "$(<"$dev/device")" == "0x22e8" ]]; then
        audio_dev="$dev"
    fi
done

if [[ -z "$gpu_dev" ]]; then
    fail "RTX 5090 GPU not present on PCI"
else
    ok "GPU present: ${gpu_dev##*/}"

    drv=""
    [[ -L "$gpu_dev/driver" ]] && drv="$(basename "$(readlink "$gpu_dev/driver")")"
    if [[ "$drv" == "nvidia" ]]; then
        ok "GPU bound to: nvidia"
    elif [[ -z "$drv" ]]; then
        fail "GPU not bound to any driver"
    else
        fail "GPU bound to: $drv (expected nvidia)"
    fi

    ps="$(<"$gpu_dev/power_state")"
    if [[ "$ps" == "D0" ]]; then
        ok "GPU power_state: D0"
    else
        fail "GPU power_state: $ps (expected D0)"
    fi

    pc="$(<"$gpu_dev/power/control")"
    if [[ "$pc" == "on" ]]; then
        ok "GPU power/control: on"
    else
        warn "GPU power/control: $pc (expected on; udev rule should set this)"
    fi

    d3c="$(<"$gpu_dev/d3cold_allowed")"
    if [[ "$d3c" == "0" ]]; then
        ok "GPU d3cold_allowed: 0"
    else
        warn "GPU d3cold_allowed: $d3c (expected 0)"
    fi

    drvo="$(<"$gpu_dev/driver_override")"
    if [[ "$drvo" == "aorus_5090_manual" ]]; then
        ok "GPU driver_override: aorus_5090_manual"
    else
        warn "GPU driver_override: '$drvo' (expected aorus_5090_manual)"
    fi

    mapfile -t res < "$gpu_dev/resource"
    read -r b0s b0e _ <<< "${res[0]}"
    read -r b1s b1e _ <<< "${res[1]}"
    if [[ "$b0s" == "0x0000000000000000" && "$b0e" == "0x0000000000000000" ]]; then
        fail "BAR0: unassigned (driver bind would fail)"
    else
        ok "BAR0: $b0s-$b0e"
    fi
    bar1_size=$((b1e - b1s + 1))
    bar1_gib=$((bar1_size / 1024 / 1024 / 1024))
    if (( bar1_size >= 32 * 1024 * 1024 * 1024 )); then
        ok "BAR1: $b1s-$b1e (${bar1_gib} GiB)"
    else
        fail "BAR1: ${bar1_gib} GiB (expected 32+ GiB; verify thunderbolt.host_reset=false took effect)"
    fi
fi

if [[ -z "$audio_dev" ]]; then
    warn "RTX 5090 HDMI audio function not present"
else
    drv=""
    [[ -L "$audio_dev/driver" ]] && drv="$(basename "$(readlink "$audio_dev/driver")")"
    if [[ -z "$drv" ]]; then
        ok "HDMI audio: present, unbound (correct)"
    elif [[ "$drv" == "snd_hda_intel" ]]; then
        warn "HDMI audio bound to snd_hda_intel (compute-only expects unbound)"
    else
        info "HDMI audio bound to: $drv"
    fi

    drvo_a="$(<"$audio_dev/driver_override")"
    if [[ "$drvo_a" == "aorus_5090_disabled" ]]; then
        ok "HDMI audio driver_override: aorus_5090_disabled"
    else
        warn "HDMI audio driver_override: '$drvo_a'"
    fi
fi

# --------------------------------------------------------- 7. Thunderbolt --
section "7. Thunderbolt"

if systemctl is-active bolt.service >/dev/null 2>&1; then
    ok "bolt.service: active"
else
    warn "bolt.service: not active (manual sysfs auth would still work)"
fi

if command -v boltctl >/dev/null; then
    bolt_out=$(boltctl 2>/dev/null || true)
    if grep -qE 'AORUS|GIGABYTE' <<< "$bolt_out"; then
        # Parse the `status:` field (NOT `authorized:` which is a timestamp).
        status=$(awk '/AORUS|GIGABYTE/ {flag=1} flag && /^[[:space:]]*\|- status:/ {print $3; exit}' <<< "$bolt_out")
        case "$status" in
            authorized)   ok "AORUS device boltctl status: authorized" ;;
            connected|auth-error|unauthorized|"")
                fail "AORUS device boltctl status: ${status:-unknown}" ;;
            *)            warn "AORUS device boltctl status: $status" ;;
        esac

        rx=$(awk '/AORUS|GIGABYTE/ {flag=1} flag && /rx speed:/ {sub(/.*rx speed:[[:space:]]*/,""); print; exit}' <<< "$bolt_out")
        [[ -n "$rx" ]] && info "AORUS rx speed: $rx"
    else
        warn "AORUS device not visible to boltctl"
    fi
else
    warn "boltctl not installed"
fi

# ----------------------------------------------------- 8. nvidia-persistenced
section "8. nvidia-persistenced"

pid=""
pid_file=/var/run/nvidia-persistenced/nvidia-persistenced.pid
if [[ -r "$pid_file" ]]; then
    pid=$(<"$pid_file")
fi
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    pid=$(pgrep -x nvidia-persiste | head -1 || true)
fi

if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    nvidia0_fds=$(ls -1 /proc/"$pid"/fd 2>/dev/null \
        | xargs -I{} readlink /proc/"$pid"/fd/{} 2>/dev/null \
        | grep -c '^/dev/nvidia0$' || true)
    nvidiactl_fds=$(ls -1 /proc/"$pid"/fd 2>/dev/null \
        | xargs -I{} readlink /proc/"$pid"/fd/{} 2>/dev/null \
        | grep -c '^/dev/nvidiactl$' || true)
    started_via=$(systemctl is-active nvidia-persistenced.service 2>/dev/null || true)
    if [[ "$started_via" == "active" ]]; then
        ok "persistenced running via systemd (pid=$pid, $nvidia0_fds fds on /dev/nvidia0, $nvidiactl_fds on /dev/nvidiactl)"
    else
        warn "persistenced running OUTSIDE systemd (pid=$pid). Functional but reboot to align."
    fi
    if (( nvidia0_fds < 1 )); then
        fail "persistenced is not holding /dev/nvidia0 - close-reopen wedge unguarded"
    fi
else
    if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
        fail "nvidia-persistenced: NOT running (nvidia-smi will freeze on second invocation)"
    else
        ok "nvidia-persistenced: not running (eGPU not present, expected)"
    fi
fi

# ------------------------------------------------------------- 9. DRM cards --
section "9. DRM ownership"

cards_seen=0
nvidia_drm_card=0
for card in /sys/class/drm/card*; do
    [[ -e "$card" ]] || continue
    case "${card##*/}" in *-*) continue ;; esac
    cards_seen=1
    drv=""
    [[ -L "$card/device/driver" ]] && drv="$(basename "$(readlink "$card/device/driver")")"
    case "$drv" in
        i915|xe)        ok "${card##*/}: $drv (Intel GPU, correct)" ;;
        nvidia*)        fail "${card##*/}: $drv (NVIDIA must NOT have a DRM card in compute-only mode)" ; nvidia_drm_card=1 ;;
        '')             info "${card##*/}: no-driver" ;;
        *)              info "${card##*/}: $drv" ;;
    esac
done
[[ "$cards_seen" -eq 0 ]] && warn "no DRM cards found"

# ----------------------------------------------------- 10. Driver versions --
section "10. Driver and kernel versions"

info "kernel: $(uname -r)"
if [[ -r /proc/driver/nvidia/version ]]; then
    info "nvidia: $(awk -F:'?' '/Module/ {print substr($0, index($0, "Module"))}' /proc/driver/nvidia/version | head -1)"
fi
nvidia_pkgs=$(rpm -qa 2>/dev/null \
    | grep -E '^(akmod|kmod)-nvidia-?[0-9]|^nvidia-persistenced-' | sort)
if [[ -n "$nvidia_pkgs" ]]; then
    while IFS= read -r p; do info "rpm: $p"; done <<< "$nvidia_pkgs"
fi

# Verify the akmod is built for the running kernel
running_kver="$(uname -r)"
if rpm -q "kmod-nvidia-${running_kver}" >/dev/null 2>&1; then
    ok "kmod-nvidia built for running kernel ($running_kver)"
else
    warn "no kmod-nvidia built for running kernel ($running_kver) - run 'sudo akmods --force' if NVIDIA fails to load"
fi

# --------------------------------------------- 11. Recent kernel signals --
section "11. Recent kernel error signals (last 24h)"

if command -v journalctl >/dev/null; then
    bad_lines=$(journalctl -k --no-pager --since '24 hours ago' 2>/dev/null \
        | grep -E 'Xid|fallen off|NV_ERR_GPU_IS_LOST|AER:.*[Uu]ncorrectable|NVRM:.*Failed|nvidia_drm.*registered|kernel panic|hard lockup' \
        | grep -v 'warning' || true)
    if [[ -z "$bad_lines" ]]; then
        ok "no Xid / fallen-off-bus / uncorrectable AER / NVRM Failed in last 24h"
    else
        fail "kernel error signals found:"
        printf '%s\n' "$bad_lines" | head -10 | sed 's/^/        /'
        if [[ $(wc -l <<< "$bad_lines") -gt 10 ]]; then
            info "(truncated; see 'journalctl -k --since 24 hours ago' for full)"
        fi
    fi
else
    warn "journalctl not available"
fi

# -------------------------------------------------------- 12. nvidia-smi --
section "12. nvidia-smi smoke test"

if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]] && mod_loaded nvidia; then
    if timeout 10 nvidia-smi --query-gpu=name,temperature.gpu,fan.speed,power.draw,pstate \
            --format=csv,noheader 2>/dev/null > /tmp/aorus-status-smi.$$; then
        out=$(< /tmp/aorus-status-smi.$$)
        rm -f /tmp/aorus-status-smi.$$
        ok "nvidia-smi: $out"
    else
        rm -f /tmp/aorus-status-smi.$$
        fail "nvidia-smi failed or timed out"
    fi
else
    info "skipped (eGPU not present or nvidia not loaded)"
fi

# ----------------------------------------------------------------- summary --
section "Summary"

total=$((ok_count + warn_count + fail_count))
printf '  %s%d OK%s, %s%d WARN%s, %s%d FAIL%s (of %d checks)\n' \
    "$C_OK" "$ok_count" "$C_RESET" \
    "$C_WARN" "$warn_count" "$C_RESET" \
    "$C_FAIL" "$fail_count" "$C_RESET" \
    "$total"

if (( fail_count > 0 )); then
    printf '\n%sStatus: DEGRADED%s - see FAIL items above. The system may be freeze-prone.\n' "$C_FAIL" "$C_RESET"
    exit 2
elif (( warn_count > 0 )); then
    printf '\n%sStatus: HEALTHY WITH WARNINGS%s - functional, see WARN items.\n' "$C_WARN" "$C_RESET"
    exit 1
else
    printf '\n%sStatus: HEALTHY%s\n' "$C_OK" "$C_RESET"
    exit 0
fi
