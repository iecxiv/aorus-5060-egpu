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

# Stop the keep-alive first - it depends on persistenced via Requires=, so
# stopping persistenced while keep-alive is active would also stop keep-alive
# but in an unordered way. Stopping the keep-alive at all closes its UVM fds
# and exposes the close-path bug; this is unavoidable when removing the
# stack. Same caveat as persistenced below: reboot to clear in-memory state.
if systemctl is-active aorus-5090-uvm-keepalive.service >/dev/null 2>&1; then
    systemctl stop aorus-5090-uvm-keepalive.service || true
fi
systemctl disable aorus-5090-uvm-keepalive.service >/dev/null 2>&1 || true

# Stop persistenced. If nvidia is loaded, this will leave the host in
# a freeze-prone state until reboot - that is unavoidable on this hardware.
if systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    systemctl stop nvidia-persistenced.service || true
fi
systemctl disable nvidia-persistenced.service >/dev/null 2>&1 || true

if systemctl is-active aorus-5090-compute-load-nvidia.service >/dev/null 2>&1; then
    systemctl stop aorus-5090-compute-load-nvidia.service || true
fi
systemctl disable aorus-5090-compute-load-nvidia.service >/dev/null 2>&1 || true

# Unmask the compute-only-mode services we masked in apply.sh.
unmask_unit_robust() {
    local unit="$1"
    local etc_path="/etc/systemd/system/$unit"
    # If we did a rename+symlink mask, undo: remove symlink, restore file.
    if [[ -L "$etc_path" ]] && [[ "$(readlink "$etc_path")" == "/dev/null" ]]; then
        rm -f "$etc_path"
        if [[ -f "$etc_path.aorus-disabled" ]]; then
            mv "$etc_path.aorus-disabled" "$etc_path"
        fi
        printf '  unmasked (restored from rename): %s\n' "$unit"
        return
    fi
    # Standard unmask path.
    if [[ "$(systemctl is-enabled "$unit" 2>&1)" == "masked" ]]; then
        systemctl unmask "$unit" >/dev/null 2>&1 || true
        printf '  unmasked: %s\n' "$unit"
    fi
}

unmask_unit_robust switcheroo-control.service
unmask_unit_robust nvidia-cdi-refresh.path
unmask_unit_robust nvidia-cdi-refresh.service
systemctl daemon-reload

# Re-enable NVIDIA Vulkan / EGL / OpenCL loader entries by undoing the rename.
restore_loader_entry() {
    local dst="$1"
    if [[ -f "$dst.aorus-disabled" ]]; then
        mv "$dst.aorus-disabled" "$dst"
        printf '  restored: %s\n' "$dst"
    fi
}
restore_loader_entry /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
restore_loader_entry /usr/share/vulkan/implicit_layer.d/nvidia_layers.json
restore_loader_entry /usr/share/glvnd/egl_vendor.d/10_nvidia.json
restore_loader_entry /etc/OpenCL/vendors/nvidia.icd

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
remove_if_exists /etc/systemd/system/aorus-5090-uvm-keepalive.service

# udev / modprobe / scripts
remove_if_exists /etc/udev/rules.d/79-aorus-5090-no-autoload.rules
remove_if_exists /etc/udev/rules.d/81-aorus-5090-compute-power.rules
remove_if_exists /etc/udev/rules.d/82-aorus-5090-nvidia-permissions.rules
remove_if_exists /etc/modprobe.d/aorus-5090-compute-only.conf
remove_if_exists /etc/modprobe.d/blacklist-nouveau.conf
remove_if_exists /etc/modprobe.d/nvidia-power-management.conf
remove_if_exists /usr/local/sbin/aorus-5090-compute-load-nvidia
remove_if_exists /usr/local/sbin/aorus-5090-disable-audio
remove_if_exists /usr/local/sbin/aorus-5090-status
remove_if_exists /usr/local/sbin/aorus-5090-uvm-keepalive
remove_if_exists /usr/local/bin/aorus-5090-status

step "reload systemd and udev"

systemctl daemon-reload
udevadm control --reload-rules

red "\nremove.sh complete."
red "Boot args (thunderbolt.host_reset=false, pci=realloc, nouveau blacklist) are still applied."
red "If you want to remove those too:"
red "  sudo grubby --remove-args='thunderbolt.host_reset=false pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0' --update-kernel=ALL"
red "Reboot to clear in-memory state."
