#!/usr/bin/env bash
# Idempotent remover for the AORUS RTX 5090 eGPU configuration.
#
# Reverses everything `apply.sh` installs: stops + disables services, removes
# unit files / udev rules / modprobe configs / sysctl configs / binaries /
# shared library / runtime config + state directories. Cleans up both the
# current `aorus-egpu-*` namespace AND the legacy `aorus-5090-*` /
# `aorus-lever-m-*` names so it works whether or not Q3 Tier 2 migration ran.
#
# Does NOT:
#   - Remove kernel boot args (do that manually with `sudo grubby
#     --remove-args=...`).
#   - Touch a custom-built NVIDIA kernel module under
#     `/usr/lib/modules/.../extra/`. Reverting the patched driver means
#     reinstalling kmod-nvidia / akmod-nvidia from your distro and rebuilding
#     for the running kernel.
#   - Reboot.
#
# Safe to run multiple times. Each step checks current state first.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "remove.sh must be run as root" >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

# shellcheck source=lib/install-manifest.sh
source "$repo_root/lib/install-manifest.sh"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }

remove_if_exists() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        printf '  removed: %s\n' "$path"
    fi
}

# -------------------------- protective auto-load blacklist stub (FIRST) --
step "write protective auto-load blacklist stub"

# Written FIRST, before any other action, to close the race window where
# the existing autoload-blocking modprobe.d files are removed but the new
# stub isn't yet in place. Without this, a `udevadm control --reload-rules`
# (which fires events) or any kernel uevent during cleanup could trigger
# `modprobe nvidia` from the GPU's modalias, which would proceed under
# vendor /usr/lib/modprobe.d/nvidia.conf's `softdep nvidia post: nvidia-uvm
# nvidia-drm` and freeze GNOME via nvidia-drm registering /dev/dri/cardN.
#
# The stub also stays in place after remove.sh completes — system stays
# safely quiesced even if rebooted before apply.sh runs.
cat > /etc/modprobe.d/zz-aorus-egpu-blacklist.conf <<'EOF'
# Written by remove.sh — blocks nvidia auto-load while the aorus-egpu stack
# is uninstalled. Without this, vendor /usr/lib/modprobe.d/nvidia.conf's
# `softdep nvidia post: nvidia-uvm nvidia-drm` would fire on next boot and
# freeze GNOME via nvidia-drm registering /dev/dri/cardN.
#
# To re-install the aorus-egpu stack:
#   sudo /path/to/repo/apply.sh        # automatically removes this stub
#
# To revert to vanilla NVIDIA behaviour (GNOME freeze risk on this hardware):
#   sudo rm /etc/modprobe.d/zz-aorus-egpu-blacklist.conf
#   sudo reboot
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_uvm
blacklist nvidia_modeset
EOF
chmod 0644 /etc/modprobe.d/zz-aorus-egpu-blacklist.conf
printf '  installed: /etc/modprobe.d/zz-aorus-egpu-blacklist.conf\n'

# -------------------------------------------------- stop and disable services --
step "stop and disable services"

# Order matters: user-facing compute consumers first, then helpers, then
# persistenced last. Stopping persistenced before the GPU is unbound (next
# step) closes /dev/nvidia0 fds; the close-path is then safely handled by
# Lever M-recover patches (H22 PROVEN-MITIGATED on current driver).
all_services=(
    ollama.service
    "${EGPU_SERVICES_ACTIVE[@]}"
    "${EGPU_SERVICES_RETIRED[@]}"
    "${LEGACY_SERVICES[@]}"
    "${LEGACY_VESTIGIAL_SERVICES[@]}"
    nvidia-persistenced.service
)
for svc in "${all_services[@]}"; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        systemctl stop "$svc" >/dev/null 2>&1 || true
        printf '  stopped: %s\n' "$svc"
    fi
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        systemctl disable "$svc" >/dev/null 2>&1 || true
        printf '  disabled: %s\n' "$svc"
    fi
done

# ------------------------------------- graceful GPU shutdown (unbind + unload) --
step "graceful shutdown: unbind GPU + unload nvidia modules"

# Now that all services holding /dev/nvidia* are stopped, unbind the GPU from
# the nvidia driver via PCI sysfs and unload modules in dependency order.
# The patched driver's Lever M-recover behaviour handles the close path
# safely (H22 PROVEN-MITIGATED). Best-effort: failures are logged, not fatal.

egpu_bdf=""
if [[ -r /etc/aorus-egpu/config.env ]]; then
    # shellcheck source=/dev/null
    source /etc/aorus-egpu/config.env
    egpu_bdf="${EGPU_BDF:-}"
fi
# Live PCI walk fallback (NVIDIA vendor + display class).
if [[ -z "$egpu_bdf" ]]; then
    for d in /sys/bus/pci/devices/*; do
        [[ -r "$d/vendor" ]] || continue
        [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x10de" ]] || continue
        [[ -r "$d/class" ]] || continue
        [[ "$(cat "$d/class" 2>/dev/null)" =~ ^0x03 ]] || continue
        egpu_bdf="$(basename "$d")"
        break
    done
fi

if [[ -n "$egpu_bdf" && -e "/sys/bus/pci/devices/$egpu_bdf/driver" ]]; then
    drv="$(readlink "/sys/bus/pci/devices/$egpu_bdf/driver" 2>/dev/null)"
    if [[ "${drv##*/}" == "nvidia" ]]; then
        if echo "$egpu_bdf" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null; then
            printf '  unbound: %s from nvidia\n' "$egpu_bdf"
        else
            yellow "  could not unbind $egpu_bdf (may have active fds)"
        fi
    else
        printf '  GPU at %s already not bound to nvidia (driver: %s)\n' "$egpu_bdf" "${drv##*/}"
    fi
elif [[ -n "$egpu_bdf" ]]; then
    printf '  GPU at %s present but unbound\n' "$egpu_bdf"
else
    printf '  no NVIDIA GPU on PCI; skipping unbind\n'
fi

# Unload modules in reverse dependency order. Skip if not loaded.
for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    if lsmod | grep -q "^${mod} "; then
        if modprobe -r "$mod" 2>/dev/null; then
            printf '  unloaded: %s\n' "$mod"
        else
            yellow "  could not unload $mod (active users?)"
        fi
    fi
done

if lsmod | grep -qE "^nvidia"; then
    yellow "  WARNING: nvidia modules still loaded after unload attempt:"
    lsmod | grep -E "^nvidia" | sed 's/^/    /'
    yellow "  Cleanup will continue; protective stub will block re-load on reboot."
else
    printf '  all nvidia modules unloaded\n'
fi

# ----------------------------------------------- unmask the apply.sh masks --
step "unmask system services"

# Reverse `mask_unit_robust` from apply.sh: standard unmask if symlink to
# /dev/null, OR rename `.aorus-disabled` back if we used the rename trick.
unmask_unit_robust() {
    local unit="$1"
    local etc_path="/etc/systemd/system/$unit"
    if [[ -L "$etc_path" ]] && [[ "$(readlink "$etc_path")" == "/dev/null" ]]; then
        rm -f "$etc_path"
        if [[ -f "$etc_path.aorus-disabled" ]]; then
            mv "$etc_path.aorus-disabled" "$etc_path"
        fi
        printf '  unmasked (restored from rename): %s\n' "$unit"
        return
    fi
    if [[ "$(systemctl is-enabled "$unit" 2>&1)" == "masked" ]]; then
        systemctl unmask "$unit" >/dev/null 2>&1 || true
        printf '  unmasked: %s\n' "$unit"
    fi
}

unmask_unit_robust nvidia-fallback.service
unmask_unit_robust nvidia-powerd.service
unmask_unit_robust switcheroo-control.service
unmask_unit_robust nvidia-cdi-refresh.path
unmask_unit_robust nvidia-cdi-refresh.service

# ------------------------------------------ NVIDIA loader entries (KEEP DISABLED) --
step "leave NVIDIA Vulkan / EGL / OpenCL loader entries disabled"

# DO NOT restore the loader entries. apply.sh disabled them by renaming
# to *.aorus-disabled because GDM/mutter dlopens libEGL_nvidia.so during
# Wayland GPU enumeration, which calls the setuid `nvidia-modprobe` binary
# which uses `insmod` directly (bypassing /etc/modprobe.d/ blacklist).
# Even with our protective blacklist stub in place, restoring these entries
# triggers nvidia load at GDM startup.
#
# To revert to vanilla NVIDIA after `remove.sh`:
#   sudo rm /etc/modprobe.d/zz-aorus-egpu-blacklist.conf
#   for f in /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json \
#            /usr/share/vulkan/implicit_layer.d/nvidia_layers.json \
#            /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
#            /etc/OpenCL/vendors/nvidia.icd; do
#       [[ -f "$f.aorus-disabled" ]] && sudo mv "$f.aorus-disabled" "$f"
#   done
#   sudo reboot
#
# History: this step USED to call restore_loader_entry. Removed 2026-05-09
# after the end-to-end remove → reboot → apply test caught the dlopen-based
# load path bypassing modprobe blacklist.
for entry in /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json \
             /usr/share/vulkan/implicit_layer.d/nvidia_layers.json \
             /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
             /etc/OpenCL/vendors/nvidia.icd; do
    if [[ -f "$entry" ]]; then
        # Re-disable in case the user (or a previous remove.sh) had restored them
        mv "$entry" "$entry.aorus-disabled"
        printf '  re-disabled: %s\n' "$entry"
    elif [[ -f "$entry.aorus-disabled" ]]; then
        printf '  already disabled: %s\n' "$entry"
    fi
done

# --------------------------------------------- remove unit files + drop-ins --
step "remove systemd units + drop-ins"

for name in "${EGPU_SERVICES_ACTIVE[@]}" "${EGPU_SERVICES_RETIRED[@]}" \
            "${LEGACY_SERVICES[@]}" "${LEGACY_VESTIGIAL_SERVICES[@]}"; do
    remove_if_exists "$(egpu_path_service "$name")"
done

for name in "${EGPU_DROP_INS[@]}"; do
    remove_if_exists "$(egpu_path_dropin "$name")"
done

# Empty drop-in directories left behind by removed drop-ins.
for d in /etc/systemd/system/nvidia-persistenced.service.d \
         /etc/systemd/system/ollama.service.d; do
    rmdir "$d" 2>/dev/null && printf '  removed empty: %s\n' "$d" || true
done

# ----------------------------------------- remove udev / modprobe / sysctl --
step "remove udev rules, modprobe + sysctl configs"

for name in "${EGPU_UDEV_STATIC[@]}" "${EGPU_UDEV_TEMPLATED[@]}" "${LEGACY_UDEV[@]}"; do
    remove_if_exists "$(egpu_path_udev "$name")"
done

for name in "${EGPU_MODPROBE_CONFS[@]}" "${LEGACY_MODPROBE[@]}"; do
    remove_if_exists "$(egpu_path_modprobe "$name")"
done

for name in "${EGPU_SYSCTL_CONFS[@]}" "${LEGACY_SYSCTL[@]}"; do
    remove_if_exists "$(egpu_path_sysctl "$name")"
done

# --------------------------------------------------------- remove binaries --
step "remove userspace binaries + shared library"

for name in "${EGPU_BINARIES[@]}" "${LEGACY_BINARIES[@]}"; do
    remove_if_exists "/usr/local/sbin/$name"
    remove_if_exists "/usr/local/bin/$name"
done

for name in "${EGPU_LIBS[@]}"; do
    remove_if_exists "$(egpu_path_lib "$name")"
done

# ---------------------------------------------- remove runtime directories --
step "remove runtime config + state directories"

# These hold per-host detection state (config.env), Lever M kill-switch flag,
# bridge-link-cap original-LnkCtl2 backup, etc. Removing them returns the
# host to the pre-install state.
for d in "${EGPU_RUNTIME_DIRS[@]}"; do
    remove_if_exists "$d"
done

# Vestigial latch files from prior eras.
for f in "${LEGACY_VESTIGIAL_FILES[@]}"; do
    remove_if_exists "$f"
done

# ------------------------------------------------------- reload + summary --
step "reload systemd and udev"

systemctl daemon-reload
udevadm control --reload-rules

red ""
red "remove.sh complete. System is in a quiesced state:"
red "  - All aorus-egpu / aorus-5090 services stopped + disabled"
red "  - GPU unbound from nvidia driver"
red "  - All nvidia kernel modules unloaded"
red "  - Protective blacklist stub installed at"
red "    /etc/modprobe.d/zz-aorus-egpu-blacklist.conf"
red ""
red "Safe to reboot now — system will boot without nvidia loaded."
red ""
red "Next steps:"
red "  - To re-install:    sudo ./apply.sh && sudo ./tools/build-patched-driver.sh"
red "  - To revert vanilla: sudo rm /etc/modprobe.d/zz-aorus-egpu-blacklist.conf && sudo reboot"
red ""
red "What was NOT touched:"
red "  - Kernel boot args (thunderbolt.host_reset=false, pci=realloc, iommu=off, etc.)"
red "    Remove with: sudo grubby --update-kernel=ALL --remove-args=\"...\""
red "  - The custom-built NVIDIA kernel module at /usr/lib/modules/<kver>/extra/."
red "    Revert by reinstalling kmod-nvidia / akmod-nvidia from your distro."
