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
check_arg_in_cmdline 'iommu=pt'

# IOMMU should be in passthrough mode for kernel-managed devices. The current
# domain-type setting is recorded in dmesg early in boot.
if [[ -d /sys/class/iommu/dmar0 ]]; then
    iommu_default=$(dmesg 2>/dev/null | awk '/iommu: Default domain type:/ {print $NF; exit}')
    if [[ "$iommu_default" == "Passthrough" ]]; then
        ok "IOMMU default domain: Passthrough (matches iommu=pt)"
    elif [[ "$iommu_default" == "Translated" ]]; then
        warn "IOMMU default domain: Translated (iommu=pt boot arg not in effect; reboot after grubby update)"
    else
        info "IOMMU default domain: ${iommu_default:-unknown}"
    fi
fi

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
    ok "nvidia_uvm: loaded (pre-staged for CUDA)"
else
    fail "nvidia_uvm: NOT loaded (cuInit will try to load it, which is blocked - failed cuInit can kernel-panic the host)"
fi

# -------------------------------------------------------- 3. config files --
section "3. Configuration files (content match against repo)"

check_file_match() {
    local repo_rel="$1" sys_file="$2"
    local repo_file="${repo_root}/${repo_rel}"
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
check_file_match etc/udev/rules.d/82-aorus-5090-nvidia-permissions.rules \
                 /etc/udev/rules.d/82-aorus-5090-nvidia-permissions.rules
check_file_match etc/modprobe.d/aorus-5090-compute-only.conf \
                 /etc/modprobe.d/aorus-5090-compute-only.conf
check_file_match etc/modprobe.d/blacklist-nouveau.conf \
                 /etc/modprobe.d/blacklist-nouveau.conf
check_file_match etc/modprobe.d/nvidia-power-management.conf \
                 /etc/modprobe.d/nvidia-power-management.conf
check_file_match etc/modprobe.d/nvidia.conf \
                 /etc/modprobe.d/nvidia.conf
check_file_match etc/systemd/system/aorus-5090-compute-load-nvidia.service \
                 /etc/systemd/system/aorus-5090-compute-load-nvidia.service
check_file_match etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf \
                 /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf
check_file_match etc/systemd/system/aorus-5090-uvm-keepalive.service \
                 /etc/systemd/system/aorus-5090-uvm-keepalive.service

# -------------------------------------------------------------- 4. scripts --
section "4. Scripts"

check_script() {
    local repo_rel="$1" sys_path="$2"
    local repo_file="${repo_root}/${repo_rel}"
    if [[ ! -e "$sys_path" ]]; then
        fail "$sys_path missing"
    elif [[ ! -x "$sys_path" ]]; then
        fail "$sys_path exists but not executable"
    elif [[ -f "$repo_file" ]] && ! cmp -s "$repo_file" "$sys_path"; then
        warn "$sys_path differs from repo (stale install? re-run apply.sh)"
    else
        ok "$sys_path"
    fi
}

check_script usr/local/sbin/aorus-5090-compute-load-nvidia /usr/local/sbin/aorus-5090-compute-load-nvidia
check_script usr/local/sbin/aorus-5090-disable-audio /usr/local/sbin/aorus-5090-disable-audio
check_script usr/local/sbin/aorus-5090-status /usr/local/sbin/aorus-5090-status
check_script usr/local/sbin/aorus-5090-uvm-keepalive /usr/local/sbin/aorus-5090-uvm-keepalive

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
check_unit_state aorus-5090-uvm-keepalive.service enabled

# These units may not exist at all on a clean compute-only install via the
# NVIDIA CUDA repo (the desktop meta-package nvidia-driver and the
# nvidia-container-toolkit are not pulled in). Treat 'not-found' as a
# valid state - it means there's nothing to mask, which is the desired
# end state. The unit will exist if we accidentally re-pulled the desktop
# meta-package or installed nvidia-container-toolkit; in that case mask
# is the right enforcement.
check_unit_state_or_absent() {
    local unit="$1" expected="$2"
    local actual
    actual="$(systemctl is-enabled "$unit" 2>&1 || true)"
    if [[ "$actual" == "$expected" ]]; then
        ok "$unit: $actual"
    elif [[ "$actual" =~ not-found ]] || [[ "$actual" =~ "Failed to get unit" ]]; then
        ok "$unit: not installed (compute-only does not ship it)"
    else
        fail "$unit: $actual (expected $expected or not-found)"
    fi
}
check_unit_state_or_absent nvidia-fallback.service masked
check_unit_state_or_absent nvidia-powerd.service masked
check_unit_state_or_absent switcheroo-control.service masked
check_unit_state_or_absent nvidia-cdi-refresh.path masked
check_unit_state_or_absent nvidia-cdi-refresh.service masked

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

a="$(active_state aorus-5090-uvm-keepalive.service)"
case "$a" in
    active) ok "aorus-5090-uvm-keepalive.service active state: active" ;;
    failed) fail "aorus-5090-uvm-keepalive.service active state: failed (UVM close-path bug is unmitigated; CUDA processes will eventually freeze the host)" ;;
    inactive)
        if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
            fail "aorus-5090-uvm-keepalive.service: inactive (UVM close-path unmitigated; reboot to align)"
        else
            ok "aorus-5090-uvm-keepalive.service: inactive (eGPU not present)"
        fi
        ;;
    *) warn "aorus-5090-uvm-keepalive.service active state: $a" ;;
esac

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

# UVM keep-alive: complementary to persistenced. Holds /dev/nvidia-uvm and
# /dev/nvidia-uvm-tools open so CUDA processes (vLLM, ollama, etc.) cannot
# be the last closer when they exit. See architecture.md and
# /root/ollama/docs/freeze-2026-05-02-1032.md for the bug evidence.
section "8b. UVM keep-alive (complementary to persistenced)"

ka_pid=""
if [[ "$(active_state aorus-5090-uvm-keepalive.service)" == "active" ]]; then
    ka_pid=$(systemctl show -p MainPID --value aorus-5090-uvm-keepalive.service 2>/dev/null || true)
fi

if [[ -n "$ka_pid" && "$ka_pid" != "0" ]] && kill -0 "$ka_pid" 2>/dev/null; then
    uvm_fds=$(ls -1 /proc/"$ka_pid"/fd 2>/dev/null \
        | xargs -I{} readlink /proc/"$ka_pid"/fd/{} 2>/dev/null \
        | grep -c '^/dev/nvidia-uvm$' || true)
    uvm_tools_fds=$(ls -1 /proc/"$ka_pid"/fd 2>/dev/null \
        | xargs -I{} readlink /proc/"$ka_pid"/fd/{} 2>/dev/null \
        | grep -c '^/dev/nvidia-uvm-tools$' || true)
    if (( uvm_fds >= 1 && uvm_tools_fds >= 1 )); then
        ok "keep-alive holding $uvm_fds fd on /dev/nvidia-uvm, $uvm_tools_fds on /dev/nvidia-uvm-tools (pid=$ka_pid)"
    else
        fail "keep-alive running (pid=$ka_pid) but UVM fds missing: uvm=$uvm_fds, uvm-tools=$uvm_tools_fds"
    fi
else
    if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
        fail "aorus-5090-uvm-keepalive: NOT running (UVM close-path bug unmitigated; CUDA workloads can freeze the host)"
    else
        ok "aorus-5090-uvm-keepalive: not running (eGPU not present, expected)"
    fi
fi

# ----------------------------------------- 8c. NVIDIA loader entries disabled --
section "8c. NVIDIA Vulkan / EGL / OpenCL loader entries (compute-only mode)"

# Files that, if present, cause user-session apps (gnome-shell, ptyxis,
# vulkan-using GUI apps) to dlopen NVIDIA libs and incidentally open
# /dev/nvidia*. Disabled by renaming to .aorus-disabled. An RPM upgrade
# will recreate them; this check catches that regression.
check_loader_disabled() {
    local original="$1" label="$2"
    if [[ -f "$original" ]]; then
        fail "$label: $original is PRESENT (compute-only mode wants this disabled; re-run apply.sh)"
    elif [[ -f "$original.aorus-disabled" ]]; then
        ok "$label: disabled ($original.aorus-disabled)"
    else
        info "$label: not installed (ok)"
    fi
}
check_loader_disabled /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json     "Vulkan ICD"
check_loader_disabled /usr/share/vulkan/implicit_layer.d/nvidia_layers.json "Vulkan implicit layer"
check_loader_disabled /usr/share/glvnd/egl_vendor.d/10_nvidia.json       "EGL vendor"
check_loader_disabled /etc/OpenCL/vendors/nvidia.icd                     "OpenCL ICD"

# ------------------------------------------ 8d. /dev/nvidia* permissions ---
section "8d. /dev/nvidia* device-file permissions"

# Cross-check: the modprobe.conf's NVreg_DeviceFileGID must match the
# actual ollama group's numeric GID. NVreg options are set at module-load
# time and aren't exposed via /sys/module/nvidia/parameters/, so we can't
# inspect the running value. Catching GID drift in the conf is the next
# best signal: if ollama has GID 1234 on this system but NVreg points at
# 968, every nvidia-modprobe call will reset perms to 0660 root:GID-968-
# whatever-that-is, breaking Layer 1.
ollama_gid=$(getent group ollama 2>/dev/null | cut -d: -f3)
modconf=/etc/modprobe.d/aorus-5090-compute-only.conf
if [[ -r "$modconf" ]]; then
    nvreg_gid=$(grep -oE 'NVreg_DeviceFileGID=[0-9]+' "$modconf" 2>/dev/null | tail -1 | cut -d= -f2)
    if [[ -n "$nvreg_gid" && -n "$ollama_gid" ]]; then
        if [[ "$nvreg_gid" == "$ollama_gid" ]]; then
            ok "NVreg_DeviceFileGID=$nvreg_gid matches ollama group GID"
        else
            fail "NVreg_DeviceFileGID=$nvreg_gid in $modconf but actual ollama GID is $ollama_gid (edit modconf to match)"
        fi
    elif [[ -z "$nvreg_gid" ]]; then
        warn "NVreg_DeviceFileGID not set in $modconf (perms will reset to 0666 root:root after every nvidia-smi)"
    fi
fi

# Confirm nvidia-persistenced (system user, runs the daemon on F43+CUDA-repo
# install) is a member of the ollama group. Without this, persistenced can't
# open /dev/nvidia0 + nvidiactl (0660 root:ollama), exits at startup, and the
# close-path bug becomes triggerable on any nvidia-smi call. apply.sh should
# add the membership; this check confirms it took effect.
if id -u nvidia-persistenced >/dev/null 2>&1; then
    if id -nG nvidia-persistenced | grep -qw ollama; then
        ok "nvidia-persistenced is in ollama group (can open /dev/nvidia0 + nvidiactl)"
    else
        fail "nvidia-persistenced is NOT in ollama group (persistenced will fail to open /dev/nvidia0; re-run apply.sh)"
    fi
fi

# check_dev_perms supports two severities:
#   fail (default) - for nvidia0 / nvidiactl, where NVreg_DeviceFile* in
#     modprobe.d makes perms persist through nvidia-modprobe re-runs.
#     Loss-of-perms here means NVreg or apply.sh is broken.
#   warn - for /dev/nvidia-uvm, -uvm-tools, and nvidia-caps/*. The
#     nvidia_uvm module has NO equivalent of NVreg_DeviceFile* (verified
#     via 'modinfo nvidia_uvm'), so nvidia-modprobe will reset their
#     perms to 0666 root:root after every invocation (every nvidia-smi
#     call, every libnvidia-ml init, etc.). Loader chmod converges them
#     at boot but the next nvidia-modprobe wins. Layer 4 (8e exclusivity)
#     is the actual safety net for these devices: lsof confirms nothing
#     unauthorised is opening them, regardless of mode bits. The keep-
#     alive holds them via fd, so kernel ref count stays >= 1.
check_dev_perms() {
    local dev="$1"
    local severity="${2:-fail}"
    if [[ ! -e "$dev" ]]; then
        info "$dev: not present"
        return
    fi
    local mode group
    mode=$(stat -c '%a' "$dev")
    group=$(stat -c '%G' "$dev")
    if [[ "$mode" == "660" && "$group" == "ollama" ]]; then
        ok "$dev: 0660 root:ollama"
    elif [[ "$severity" == "warn" ]]; then
        warn "$dev: 0$mode root:$group (no NVreg-equivalent for nvidia_uvm; resets after every nvidia-modprobe; Layer 4 8e is the real safety check)"
    else
        fail "$dev: 0$mode root:$group (want 0660 root:ollama; NVreg_DeviceFile* in modprobe.d should make this stick)"
    fi
}
check_dev_perms /dev/nvidia0           fail
check_dev_perms /dev/nvidiactl         fail
check_dev_perms /dev/nvidia-uvm        warn
check_dev_perms /dev/nvidia-uvm-tools  warn
if [[ -d /dev/nvidia-caps ]]; then
    for cap in /dev/nvidia-caps/*; do
        check_dev_perms "$cap" warn
    done
fi

# ---------------------------- 8f. NVreg runtime params vs configured -------
section "8f. NVIDIA driver module parameters (runtime vs configured)"

# NVreg_* options in modprobe.d are read by the nvidia kernel module at
# insmod time. Most are exposed via /sys/module/nvidia/parameters/ so we
# can verify the running driver actually picked them up. A few (like
# NVreg_DeviceFile{UID,GID,Mode}) aren't exposed in sysfs - they are
# consumed by libnvidia-modprobe-utils at file-creation time, not stored
# as runtime state. We INFO those (cannot verify) rather than fail.
#
# Mismatch between conf and runtime usually means the conf changed but
# the driver wasn't reloaded - i.e. reboot needed.

modconf=/etc/modprobe.d/aorus-5090-compute-only.conf
if [[ -r "$modconf" ]]; then
    # Extract every "options nvidia K=V K=V ..." pair. awk strips comments
    # and prints one K=V token per line.
    nvreg_pairs=$(awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*options[[:space:]]+nvidia[[:space:]]/ {
            for (i=3; i<=NF; i++) print $i
        }
    ' "$modconf")

    # Match conf value to runtime value: either equal as strings, or equal
    # as integers (so 0x00 matches 0). Returns 0 on match, 1 otherwise.
    match_nvreg() {
        local actual="$1" expected="$2"
        [[ "$actual" == "$expected" ]] && return 0
        # Only attempt arithmetic comparison if both look numeric
        if [[ "$actual" =~ ^-?(0x)?[0-9a-fA-F]+$ ]] \
                && [[ "$expected" =~ ^-?(0x)?[0-9a-fA-F]+$ ]]; then
            (( actual == expected )) && return 0
        fi
        return 1
    }

    # NVIDIA doesn't expose params via /sys/module/nvidia/parameters/ but
    # mirrors them in /proc/driver/nvidia/params with the NVreg_ prefix
    # stripped. A few have different internal names (e.g.,
    # NVreg_RestrictProfilingToAdminUsers -> RmProfilingAdminOnly); for
    # those we INFO that we can't directly verify.
    proc_params=/proc/driver/nvidia/params

    while IFS= read -r kv; do
        [[ -n "$kv" ]] || continue
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ "$key" =~ ^NVreg_ ]] || continue
        # Most NVreg_X are mirrored in /proc as plain X (no NVreg_ prefix).
        # A few are renamed internally; map the known ones explicitly.
        case "$key" in
            NVreg_RestrictProfilingToAdminUsers) proc_key="RmProfilingAdminOnly" ;;
            *) proc_key="${key#NVreg_}" ;;
        esac
        actual=""
        if [[ -r "$proc_params" ]]; then
            actual=$(awk -v k="${proc_key}:" '$1 == k {print $2; exit}' "$proc_params")
        fi
        if [[ -n "$actual" ]]; then
            if match_nvreg "$actual" "$val"; then
                ok "$key = $actual (matches conf $val)"
            else
                fail "$key = $actual at runtime; conf has $val (reboot to reload nvidia with new params)"
            fi
        else
            info "$key (conf=$val): not in /proc/driver/nvidia/params - cannot verify (renamed internally or insmod-only)"
        fi
    done <<< "$nvreg_pairs"
else
    warn "$modconf not present - cannot verify NVreg runtime parameters"
fi

# ------------------ 8g. modprobe softdep on nvidia-drm absence -----------
section "8g. nvidia-drm autoload prevention (softdep + install)"

# The NVIDIA-CUDA-repo nvidia-driver RPM ships /usr/lib/modprobe.d/nvidia.conf
# with a softdep on nvidia-drm:
#   softdep nvidia post: nvidia-uvm nvidia-drm
# Loading nvidia.ko via this softdep auto-loads nvidia-drm.ko, which creates
# a /dev/dri/cardN entry. GNOME mutter picks it up as a display and the
# Blackwell-over-Thunderbolt stack hard-freezes at GNOME login.
#
# Our /etc/modprobe.d/nvidia.conf SHADOW removes this softdep. Verify:
softdep_resolved=$(modprobe --show-depends nvidia 2>&1)
if grep -q 'nvidia-drm' <<<"$softdep_resolved"; then
    fail "modprobe still resolves nvidia-drm in nvidia's dep chain (shadow not effective; expect GNOME freeze)"
elif grep -q 'install /bin/false' <<<"$softdep_resolved"; then
    ok "softdep on nvidia-drm absent + install /bin/false in place (autoload blocked)"
else
    warn "could not confirm nvidia-drm autoload prevention via modprobe --show-depends"
fi

# Belt-and-suspenders: directly resolve nvidia-drm and confirm install /bin/false
drm_resolve=$(modprobe --show-depends nvidia-drm 2>&1)
if grep -q 'install /bin/false' <<<"$drm_resolve"; then
    ok "modprobe nvidia-drm directly resolves to install /bin/false"
else
    fail "modprobe nvidia-drm does NOT hit the install /bin/false guard - check aorus-5090-compute-only.conf"
fi

# --------------------------------------- 8e. exclusivity (lsof check) ------
section "8e. /dev/nvidia* exclusivity (only authorised processes holding)"

# The eGPU is supposed to be a CUDA-only accelerator. Anything other than
# the expected compute-stack processes holding /dev/nvidia* is a regression
# - usually a user-session app that dlopen'd NVIDIA libs and incidentally
# opened the device. Causes close-path-bug exposure on its exit.
authorised_re='^(nvidia-pe|sleep|ollama|ollama_llama_server)$'
nvidia_files=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools)
unauthorised=$(lsof "${nvidia_files[@]}" 2>/dev/null \
    | awk 'NR>1 {print $1, "(pid="$2",user="$3")"}' \
    | sort -u \
    | { while read -r line; do
            cmd=$(awk '{print $1}' <<<"$line")
            if ! [[ "$cmd" =~ $authorised_re ]]; then
                printf '%s\n' "$line"
            fi
        done
      })
if [[ -z "$unauthorised" ]]; then
    ok "no unauthorised holders of /dev/nvidia*"
else
    warn "unauthorised holders of /dev/nvidia*:"
    printf '%s\n' "$unauthorised" | head -10 | sed 's/^/        /'
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

# Verify the kernel module is built for the running kernel.
# Two paths supported:
#   - F43+ NVIDIA CUDA repo + DKMS: dkms status shows nvidia/<ver> for our kernel
#   - F42 RPMFusion akmod: rpm -q kmod-nvidia-<kver>
running_kver="$(uname -r)"
if dkms status 2>/dev/null | grep -q "^nvidia.*${running_kver}.*installed"; then
    ok "DKMS-built nvidia module installed for running kernel ($running_kver)"
elif rpm -q "kmod-nvidia-${running_kver}" >/dev/null 2>&1; then
    ok "kmod-nvidia (RPMFusion akmod) built for running kernel ($running_kver)"
else
    warn "no nvidia kernel module built for running kernel ($running_kver) - 'sudo dkms autoinstall' (CUDA-repo) or 'sudo akmods --force' (RPMFusion)"
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
