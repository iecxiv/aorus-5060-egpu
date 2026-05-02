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
    yellow "  sudo grubby --update-kernel=ALL --args=\"thunderbolt.host_reset=false pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 module_blacklist=nouveau,nova_core rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core iommu=pt\""
    yellow "Then reboot before relying on the rest of the configuration."
elif ! grep -q 'iommu=pt' /proc/cmdline; then
    yellow "NOTICE: 'iommu=pt' is NOT in /proc/cmdline."
    yellow "Other boot args are present, but the IOMMU is in Translated mode rather"
    yellow "than passthrough. Recommended for stability + performance:"
    yellow "  sudo grubby --update-kernel=ALL --args=\"iommu=pt\""
    yellow "Reboot to apply."
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
copy_if_different etc/udev/rules.d/82-aorus-5090-nvidia-permissions.rules \
                  /etc/udev/rules.d/82-aorus-5090-nvidia-permissions.rules 0644

# modprobe configs
copy_if_different etc/modprobe.d/aorus-5090-compute-only.conf \
                  /etc/modprobe.d/aorus-5090-compute-only.conf 0644
copy_if_different etc/modprobe.d/blacklist-nouveau.conf \
                  /etc/modprobe.d/blacklist-nouveau.conf 0644
copy_if_different etc/modprobe.d/nvidia-power-management.conf \
                  /etc/modprobe.d/nvidia-power-management.conf 0644
copy_if_different etc/modprobe.d/nvidia.conf \
                  /etc/modprobe.d/nvidia.conf 0644

# systemd units
copy_if_different etc/systemd/system/aorus-5090-compute-load-nvidia.service \
                  /etc/systemd/system/aorus-5090-compute-load-nvidia.service 0644
copy_if_different etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf \
                  /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf 0644
copy_if_different etc/systemd/system/aorus-5090-uvm-keepalive.service \
                  /etc/systemd/system/aorus-5090-uvm-keepalive.service 0644

# scripts
copy_if_different usr/local/sbin/aorus-5090-compute-load-nvidia \
                  /usr/local/sbin/aorus-5090-compute-load-nvidia 0755
copy_if_different usr/local/sbin/aorus-5090-disable-audio \
                  /usr/local/sbin/aorus-5090-disable-audio 0755
copy_if_different usr/local/sbin/aorus-5090-status \
                  /usr/local/sbin/aorus-5090-status 0755
copy_if_different usr/local/sbin/aorus-5090-uvm-keepalive \
                  /usr/local/sbin/aorus-5090-uvm-keepalive 0755

# ----------------------------------------------------- SELinux / udev reload -
step "restore SELinux contexts and reload udev"

restorecon_paths=(
    /etc/udev/rules.d/79-aorus-5090-no-autoload.rules
    /etc/udev/rules.d/81-aorus-5090-compute-power.rules
    /etc/udev/rules.d/82-aorus-5090-nvidia-permissions.rules
    /etc/modprobe.d/aorus-5090-compute-only.conf
    /etc/modprobe.d/blacklist-nouveau.conf
    /etc/modprobe.d/nvidia-power-management.conf
    /etc/modprobe.d/nvidia.conf
    /etc/systemd/system/aorus-5090-compute-load-nvidia.service
    /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf
    /etc/systemd/system/aorus-5090-uvm-keepalive.service
    /usr/local/sbin/aorus-5090-compute-load-nvidia
    /usr/local/sbin/aorus-5090-disable-audio
    /usr/local/sbin/aorus-5090-status
    /usr/local/sbin/aorus-5090-uvm-keepalive
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

# nvidia-powerd: opens/closes device files at runtime, which is exactly
# the close-path-bug trigger we work hard to prevent. Mask so it cannot
# start. On a compute-only install via the NVIDIA CUDA repo, nvidia-powerd
# is not installed at all (the desktop meta-package nvidia-driver provided
# it) - mask_unit_robust handles the 'not installed' case as a no-op.
mask_unit_robust nvidia-powerd.service

# Compute-only mode: mask GPU-touching system services that are pointless
# on this host. Each is a potential close-path-bug trigger if it dlopens
# libnvidia-ml or opens /dev/nvidia* during its lifecycle.
#
#   switcheroo-control.service - shipped in /usr/lib/, standard mask works.
#                                 Manages display GPU switching for laptops
#                                 with hybrid graphics; we are compute-only.
#   nvidia-cdi-refresh.path    - shipped DIRECTLY in /etc/systemd/system/ by
#                                 nvidia-container-toolkit RPM. systemctl
#                                 mask refuses ("File already exists"); we
#                                 rename the original aside and symlink
#                                 /dev/null in its place. Same effect.
#                                 The .path watches modules.dep + nvidia-ctk
#                                 and triggers .service to dlopen libnvml.
mask_unit_robust() {
    local unit="$1"
    local etc_path="/etc/systemd/system/$unit"
    local enabled
    enabled=$(systemctl is-enabled "$unit" 2>&1)
    if [[ "$enabled" == "masked" ]]; then
        printf '  already masked: %s\n' "$unit"
        return 0
    fi
    # Unit not installed at all (e.g., on a compute-only install where the
    # nvidia-container-toolkit or desktop meta-package never landed). Nothing
    # to mask; treat as success.
    if [[ "$enabled" =~ not-found ]] || [[ "$enabled" =~ "Failed to get unit" ]]; then
        printf '  not installed (compute-only): %s\n' "$unit"
        return 0
    fi
    # Try standard masking first (works when unit is in /usr/lib/).
    if systemctl mask "$unit" >/dev/null 2>&1; then
        printf '  masked: %s\n' "$unit"
        return 0
    fi
    # Standard mask refused: a regular file in /etc/ is blocking the
    # /dev/null symlink. Rename it aside and create the mask symlink.
    if [[ -f "$etc_path" && ! -L "$etc_path" ]]; then
        mv "$etc_path" "$etc_path.aorus-disabled"
        ln -sf /dev/null "$etc_path"
        printf '  masked (via rename + /dev/null symlink): %s\n' "$unit"
        return 0
    fi
    yellow "  WARNING: could not mask $unit"
    return 1
}

mask_unit_robust switcheroo-control.service
mask_unit_robust nvidia-cdi-refresh.path
mask_unit_robust nvidia-cdi-refresh.service
systemctl daemon-reload

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

# Enable the UVM keep-alive (extends persistenced's mitigation to /dev/nvidia-uvm).
if ! systemctl is-enabled aorus-5090-uvm-keepalive.service >/dev/null 2>&1; then
    systemctl enable aorus-5090-uvm-keepalive.service
    printf '  enabled: aorus-5090-uvm-keepalive.service\n'
else
    printf '  already enabled: aorus-5090-uvm-keepalive.service\n'
fi

# Disable the user's nvidia-settings autostart if not already disabled.
autostart=/etc/xdg/autostart/nvidia-settings-user.desktop
if [[ -f "$autostart" ]] && ! grep -q '^X-GNOME-Autostart-enabled=false' "$autostart"; then
    yellow "  WARNING: $autostart is not disabled; review it manually."
fi

# ----------------------------------------------- compute-only ICD/loader disables -
step "compute-only: disable NVIDIA Vulkan / EGL / OpenCL loader entries"

# Compute-only mode means non-CUDA frameworks (Vulkan, EGL, OpenGL, OpenCL)
# have no business loading NVIDIA drivers on this host. The NVIDIA loader-
# registration files cause user-session apps (gnome-shell, mutter, ptyxis,
# etc.) to dlopen NVIDIA libs and incidentally open /dev/nvidia0 + nvidiactl
# during enumeration. Each such open + close is a close-path-bug trigger.
#
# We disable each entry by renaming to a non-matching extension (.aorus-disabled).
# Vulkan and EGL loaders only consider files ending in .json; OpenCL loader
# only considers .icd. The rename is reversible by undoing the suffix.
#
# CAVEAT: an nvidia-driver RPM upgrade will recreate these files. status.sh's
# Layer-4 check will catch the regression; re-run apply.sh to re-disable.

disable_loader_entry() {
    local src="$1"
    if [[ -f "$src" ]]; then
        mv "$src" "$src.aorus-disabled"
        printf '  disabled: %s\n' "$src"
    elif [[ -f "$src.aorus-disabled" ]]; then
        printf '  already disabled: %s\n' "$src"
    else
        printf '  not present (ok): %s\n' "$src"
    fi
}

disable_loader_entry /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
disable_loader_entry /usr/share/vulkan/implicit_layer.d/nvidia_layers.json
disable_loader_entry /usr/share/glvnd/egl_vendor.d/10_nvidia.json
disable_loader_entry /etc/OpenCL/vendors/nvidia.icd

# ----------------------------------------------- ollama group membership ---
step "ollama group membership"

# The 82-aorus-5090-nvidia-permissions.rules udev rule restricts /dev/nvidia*
# to root and the 'ollama' group. Add the human admin user (apnex) to this
# group so unprivileged 'nvidia-smi' continues to work for diagnostics.
# 'sudo nvidia-smi' will work regardless via root.
#
# Note: usermod -aG is APPENDING; existing groups are preserved. The change
# only takes effect for NEW logins / shells; existing shells need 'newgrp
# ollama' or relogin to see the new group.

if id -u apnex >/dev/null 2>&1; then
    if id -nG apnex | grep -qw ollama; then
        printf '  apnex already in ollama group\n'
    else
        usermod -aG ollama apnex
        yellow "  added apnex to ollama group; log out + back in to take effect"
    fi
fi

# nvidia-persistenced (UID 967) is created by the NVIDIA-CUDA-repo
# nvidia-persistenced RPM via sysusers. The daemon runs as that user
# (NOT root, unlike the F42 RPMFusion build which had no sysusers config).
# Without ollama group membership, persistenced cannot open /dev/nvidia0 +
# nvidiactl (which we tighten to 0660 root:ollama). Result: persistenced
# fails to start -> /dev/nvidia0 has no holder -> any subsequent close-path
# event freezes the host. Add to ollama group so it can hold those fds.
if id -u nvidia-persistenced >/dev/null 2>&1; then
    if id -nG nvidia-persistenced | grep -qw ollama; then
        printf '  nvidia-persistenced already in ollama group\n'
    else
        usermod -aG ollama nvidia-persistenced
        printf '  added nvidia-persistenced to ollama group\n'
    fi
fi

# ---------------------------------------------------- live-state convergence -
step "live state"

# Apply current udev rules to already-enumerated devices (re-runs the
# 81-aorus-5090-compute-power.rules d3cold/power_control rewrites).
udevadm trigger --subsystem-match=pci

# If nvidia is already loaded and bound and persistenced is already running,
# we are done and do not need to start anything. Otherwise, start the chain:
# Read /proc/modules directly to avoid SIGPIPE on lsmod under pipefail.
if ! grep -q '^nvidia ' /proc/modules; then
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

# Apply the new udev permissions to existing /dev/nvidia* device files. Without
# this, the rule only fires on next boot. udev rules MODE/GROUP are evaluated
# at device creation, so for already-created devices we converge by hand.
# Note: changing perms on an open file does NOT close existing handles - any
# process currently holding /dev/nvidia0 (e.g. ptyxis after a libGLX_nvidia
# dlopen) keeps its access. Reboot to flush.
if [[ -e /dev/nvidia0 ]]; then
    chgrp ollama /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
    chmod 0660 /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
    if [[ -d /dev/nvidia-caps ]]; then
        chgrp ollama /dev/nvidia-caps/* 2>/dev/null || true
        chmod 0660 /dev/nvidia-caps/* 2>/dev/null || true
    fi
    printf '  converged /dev/nvidia* perms to 0660 root:ollama (udev rule applies on next boot)\n'
fi

# Start the UVM keep-alive last in the chain. This is a freeze-risk event:
# its first open() of /dev/nvidia-uvm runs against whatever the current
# refcount is. If the device's count is 0 AND a prior CUDA process closed
# UVM since boot, the close-side teardown may have already wedged the
# kernel; the next open hangs the host. apply.sh has no way to prove a
# fresh-boot refcount-was-never-nonzero state, so a freeze-prone window
# exists during initial deployment. Once the keep-alive is up at boot
# from this point forward, the window closes.
if [[ ! -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
    : # eGPU not present; nothing to start
elif systemctl is-active aorus-5090-uvm-keepalive.service >/dev/null 2>&1; then
    printf '  aorus-5090-uvm-keepalive.service is active\n'
else
    printf '  starting aorus-5090-uvm-keepalive.service\n'
    systemctl start aorus-5090-uvm-keepalive.service || true
fi

# --------------------------------------------------------------- final check -
step "post-apply status"
/usr/local/sbin/aorus-5090-status || true

green "\napply.sh complete."
green "Reboot to verify the configuration survives a cold boot."
