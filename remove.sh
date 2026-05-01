#!/usr/bin/env bash
# Best-effort remover for the AORUS RTX 5090 eGPU configuration.
#
# Disables the services, removes our drop-in and config files. Does NOT
# remove kernel boot args (do that manually if you want, with
# `grubby --remove-args=...`).
#
# After running, the system will not auto-load NVIDIA at boot for the eGPU,
# but the kernel-side cmdline blacklists for nouveau / nova_core remain.
# You will need to choose a different setup (or none) before next boot.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "remove.sh must be run as root" >&2
    exit 1
fi

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

step "stop and disable services"

# Stop persistenced first. If nvidia is loaded, this will leave the host in
# a freeze-prone state until reboot - that is unavoidable on this hardware.
if systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    systemctl stop nvidia-persistenced.service || true
fi
systemctl disable nvidia-persistenced.service >/dev/null 2>&1 || true

if systemctl is-active aorus-5090-compute-load-nvidia.service >/dev/null 2>&1; then
    systemctl stop aorus-5090-compute-load-nvidia.service || true
fi
systemctl disable aorus-5090-compute-load-nvidia.service >/dev/null 2>&1 || true

step "remove configuration files"

remove_if_exists() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        printf '  removed: %s\n' "$path"
    fi
}

# systemd unit + drop-in
remove_if_exists /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf
rmdir /etc/systemd/system/nvidia-persistenced.service.d 2>/dev/null || true
remove_if_exists /etc/systemd/system/aorus-5090-compute-load-nvidia.service

# udev / modprobe / scripts
remove_if_exists /etc/udev/rules.d/79-aorus-5090-no-autoload.rules
remove_if_exists /etc/udev/rules.d/81-aorus-5090-compute-power.rules
remove_if_exists /etc/modprobe.d/aorus-5090-compute-only.conf
remove_if_exists /etc/modprobe.d/blacklist-nouveau.conf
remove_if_exists /usr/local/sbin/aorus-5090-compute-load-nvidia
remove_if_exists /usr/local/sbin/aorus-5090-disable-audio
remove_if_exists /usr/local/sbin/aorus-5090-status
remove_if_exists /usr/local/bin/aorus-5090-status

step "reload systemd and udev"

systemctl daemon-reload
udevadm control --reload-rules

red "\nremove.sh complete."
red "Boot args (thunderbolt.host_reset=false, pci=realloc, nouveau blacklist) are still applied."
red "If you want to remove those too:"
red "  sudo grubby --remove-args='thunderbolt.host_reset=false pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0' --update-kernel=ALL"
red "Reboot to clear in-memory state."
