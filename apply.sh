#!/usr/bin/env bash
# Idempotent installer for the AORUS RTX 5090 eGPU configuration.
#
# Run from the repo root:
#   sudo ./apply.sh
#
# Safe to run multiple times. Each step checks current state and only acts on
# differences. Does NOT reboot, does NOT change kernel boot args, does NOT
# disturb a running NVIDIA module that is already bound.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "apply.sh must be run as root" >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

step() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- preflight --
step "preflight"

if ! grep -q 'thunderbolt.host_reset=false' /proc/cmdline; then
    yellow "WARNING: 'thunderbolt.host_reset=false' is NOT in /proc/cmdline."
    yellow "The eGPU likely has BAR1=256MiB rather than 32GiB. Boot args are required."
    yellow "After this script finishes, run:"
    yellow "  sudo grubby --update-kernel=ALL --args=\"thunderbolt.host_reset=false pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 module_blacklist=nouveau,nova_core rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core\""
    yellow "Then reboot before relying on the rest of the configuration."
fi

if [[ ! -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
    yellow "WARNING: eGPU is not on PCI at 0000:04:00.0."
    yellow "Configuration will install but services will skip via ConditionPathExists."
fi

# ---------------------------------------------------------------- copy files -
step "copy configuration files"

copy_if_different() {
    local src="$1" dst="$2" mode="$3"

    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        printf '  unchanged: %s\n' "$dst"
        return 0
    fi

    install -D -m "$mode" "$src" "$dst"
    printf '  installed: %s\n' "$dst"
}

# udev rules
copy_if_different etc/udev/rules.d/79-aorus-5090-no-autoload.rules \
                  /etc/udev/rules.d/79-aorus-5090-no-autoload.rules 0644
copy_if_different etc/udev/rules.d/81-aorus-5090-compute-power.rules \
                  /etc/udev/rules.d/81-aorus-5090-compute-power.rules 0644

# modprobe configs
copy_if_different etc/modprobe.d/aorus-5090-compute-only.conf \
                  /etc/modprobe.d/aorus-5090-compute-only.conf 0644
copy_if_different etc/modprobe.d/blacklist-nouveau.conf \
                  /etc/modprobe.d/blacklist-nouveau.conf 0644

# systemd units
copy_if_different etc/systemd/system/aorus-5090-compute-load-nvidia.service \
                  /etc/systemd/system/aorus-5090-compute-load-nvidia.service 0644
copy_if_different etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf \
                  /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf 0644

# scripts
copy_if_different usr/local/sbin/aorus-5090-compute-load-nvidia \
                  /usr/local/sbin/aorus-5090-compute-load-nvidia 0755
copy_if_different usr/local/sbin/aorus-5090-disable-audio \
                  /usr/local/sbin/aorus-5090-disable-audio 0755
copy_if_different usr/local/sbin/aorus-5090-status \
                  /usr/local/sbin/aorus-5090-status 0755

# ----------------------------------------------------- SELinux / udev reload -
step "restore SELinux contexts and reload udev"

restorecon_paths=(
    /etc/udev/rules.d/79-aorus-5090-no-autoload.rules
    /etc/udev/rules.d/81-aorus-5090-compute-power.rules
    /etc/modprobe.d/aorus-5090-compute-only.conf
    /etc/modprobe.d/blacklist-nouveau.conf
    /etc/systemd/system/aorus-5090-compute-load-nvidia.service
    /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf
    /usr/local/sbin/aorus-5090-compute-load-nvidia
    /usr/local/sbin/aorus-5090-disable-audio
    /usr/local/sbin/aorus-5090-status
)
if command -v restorecon >/dev/null; then
    restorecon -F "${restorecon_paths[@]}" 2>/dev/null || true
fi

udevadm control --reload-rules

# ------------------------------------------------------------- cleanup phase -
step "remove vestigial files"

remove_if_exists() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        printf '  removed: %s\n' "$path"
    else
        printf '  absent (ok): %s\n' "$path"
    fi
}

# Old latch files
remove_if_exists /etc/aorus-5090-allow-compute-load
remove_if_exists /etc/aorus-5090-collect-pci-layout

# Vestigial debug collector
if systemctl is-enabled aorus-5090-collect-pci-layout.service >/dev/null 2>&1; then
    systemctl disable aorus-5090-collect-pci-layout.service >/dev/null 2>&1 || true
    printf '  disabled: aorus-5090-collect-pci-layout.service\n'
fi
remove_if_exists /etc/systemd/system/aorus-5090-collect-pci-layout.service
remove_if_exists /usr/local/sbin/aorus-5090-collect-pci-layout

# Handle the merged-/usr layout case: on Fedora, /usr/local/sbin is a symlink
# to /usr/local/bin. If they resolve to the same directory, scripts in
# /usr/local/bin ARE the canonical scripts; do not delete them.
sbin_real="$(readlink -f /usr/local/sbin)"
bin_real="$(readlink -f /usr/local/bin)"
if [[ "$sbin_real" == "$bin_real" ]]; then
    printf '  /usr/local/sbin and /usr/local/bin resolve to the same directory; no duplicate cleanup needed\n'
    # The installed scripts already serve both PATH locations. Just remove the
    # collect-pci-layout vestigial script which has no /sbin install above.
    remove_if_exists /usr/local/bin/aorus-5090-collect-pci-layout
else
    # Separate directories: cleanup duplicates that the prior debugging era left.
    remove_if_exists /usr/local/bin/aorus-5090-compute-load-nvidia
    remove_if_exists /usr/local/bin/aorus-5090-collect-pci-layout
    remove_if_exists /usr/local/bin/aorus-5090-disable-audio
    rm -f /usr/local/bin/aorus-5090-status
    ln -sfn /usr/local/sbin/aorus-5090-status /usr/local/bin/aorus-5090-status
    printf '  /usr/local/bin/aorus-5090-status -> /usr/local/sbin/aorus-5090-status\n'
fi

# ---------------------------------------------------------------- services --
step "reload systemd, mask/disable/enable services"

systemctl daemon-reload

# nvidia-fallback should be masked (loads nouveau on NVIDIA failure - fights us).
if [[ "$(systemctl is-enabled nvidia-fallback.service 2>&1)" != "masked" ]]; then
    systemctl mask nvidia-fallback.service
    printf '  masked: nvidia-fallback.service\n'
fi

# nvidia-powerd should be disabled (opens/closes device files - re-trigger risk).
if [[ "$(systemctl is-enabled nvidia-powerd.service 2>&1)" != "disabled" ]] \
        && [[ "$(systemctl is-enabled nvidia-powerd.service 2>&1)" != "masked" ]]; then
    systemctl disable nvidia-powerd.service >/dev/null 2>&1 || true
    printf '  disabled: nvidia-powerd.service\n'
fi

# Enable the bind service.
if ! systemctl is-enabled aorus-5090-compute-load-nvidia.service >/dev/null 2>&1; then
    systemctl enable aorus-5090-compute-load-nvidia.service
    printf '  enabled: aorus-5090-compute-load-nvidia.service\n'
else
    printf '  already enabled: aorus-5090-compute-load-nvidia.service\n'
fi

# Enable persistenced.
if ! systemctl is-enabled nvidia-persistenced.service >/dev/null 2>&1; then
    systemctl enable nvidia-persistenced.service
    printf '  enabled: nvidia-persistenced.service\n'
else
    printf '  already enabled: nvidia-persistenced.service\n'
fi

# Disable the user's nvidia-settings autostart if not already disabled.
autostart=/etc/xdg/autostart/nvidia-settings-user.desktop
if [[ -f "$autostart" ]] && ! grep -q '^X-GNOME-Autostart-enabled=false' "$autostart"; then
    yellow "  WARNING: $autostart is not disabled; review it manually."
fi

# ---------------------------------------------------- live-state convergence -
step "live state"

# Apply current udev rules to already-enumerated devices (re-runs the
# 81-aorus-5090-compute-power.rules d3cold/power_control rewrites).
udevadm trigger --subsystem-match=pci

# If nvidia is already loaded and bound and persistenced is already running,
# we are done and do not need to start anything. Otherwise, start the chain:
if ! lsmod | grep -q '^nvidia '; then
    if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
        printf '  starting aorus-5090-compute-load-nvidia.service\n'
        systemctl start aorus-5090-compute-load-nvidia.service
    fi
fi

# Persistenced may already be running outside systemd (manually started during
# diagnostic work). Detect that and DO NOT try to start the systemd unit on top
# of it: starting a second instance fails on the pid file lock, AND the unit's
# default ExecStopPost wipes /var/run/nvidia-persistenced even on failure,
# leaving the running daemon's runtime directory missing. Reboot is the clean
# alignment - systemd takes over from boot.
if [[ ! -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
    : # eGPU not present; nothing to start
elif pgrep -x nvidia-persiste >/dev/null \
        && ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    yellow "  nvidia-persistenced is running OUTSIDE systemd (manual start)."
    yellow "  Skipping systemctl start to avoid pid-file lock conflict."
    yellow "  Reboot when convenient - systemd will manage persistenced from boot."
elif systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    printf '  nvidia-persistenced.service is active\n'
else
    printf '  starting nvidia-persistenced.service\n'
    systemctl start nvidia-persistenced.service || true
fi

# --------------------------------------------------------------- final check -
step "post-apply status"
/usr/local/sbin/aorus-5090-status || true

green "\napply.sh complete."
green "Reboot to verify the configuration survives a cold boot."
