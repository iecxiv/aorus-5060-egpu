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

# shellcheck source=lib/install-manifest.sh
source "$repo_root/lib/install-manifest.sh"

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
    yellow "  sudo grubby --update-kernel=ALL --args=\"thunderbolt.host_reset=false pci=realloc=off,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 module_blacklist=nouveau,nova_core rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core iommu=pt pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off\""
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

# Iterate the manifest. Each array gets the same install-or-skip treatment
# routed by category. Templated udev rules are NOT copied here — they're
# rendered later after detect-config writes /etc/aorus-egpu/config.env.

for name in "${EGPU_UDEV_STATIC[@]}"; do
    copy_if_different "etc/udev/rules.d/$name" "$(egpu_path_udev "$name")" 0644
done

for name in "${EGPU_MODPROBE_CONFS[@]}"; do
    copy_if_different "etc/modprobe.d/$name" "$(egpu_path_modprobe "$name")" 0644
done

for name in "${EGPU_SYSCTL_CONFS[@]}"; do
    copy_if_different "etc/sysctl.d/$name" "$(egpu_path_sysctl "$name")" 0644
done

# Active + retired services use identical installation. Enable/disable
# distinction is handled in the services step further below.
for name in "${EGPU_SERVICES_ACTIVE[@]}" "${EGPU_SERVICES_RETIRED[@]}"; do
    copy_if_different "etc/systemd/system/$name" "$(egpu_path_service "$name")" 0644
done

for name in "${EGPU_DROP_INS[@]}"; do
    copy_if_different "etc/systemd/system/$name" "$(egpu_path_dropin "$name")" 0644
done

for name in "${EGPU_LIBS[@]}"; do
    copy_if_different "usr/local/lib/aorus-egpu/$name" "$(egpu_path_lib "$name")" 0644
done

for name in "${EGPU_BINARIES[@]}" "${EGPU_BINARIES_RETIRED[@]}"; do
    copy_if_different "usr/local/sbin/$name" "$(egpu_path_binary "$name")" 0755
done

# ------------------------------------------------- auto-detect host topology -
step "auto-detect host topology and write /etc/aorus-egpu/config.env"

# Run aorus-egpu-detect-config to refresh /etc/aorus-egpu/config.env from
# live PCI state. Idempotent — previous file preserved as
# config.env.previous. Safe to run on every apply; required on first
# install before helpers can source the config.
if /usr/local/sbin/aorus-egpu-detect-config >/dev/null 2>&1; then
    printf '  detected: %s\n' "$(grep '^EGPU_BDF=' /etc/aorus-egpu/config.env | cut -d= -f2 | tr -d '"')"
    printf '  config:   /etc/aorus-egpu/config.env\n'
else
    yellow "  aorus-egpu-detect-config failed — eGPU may not be present; helpers will fall back to defaults"
fi

# ------------------------------------------------- render udev rule templates -
step "render udev rule templates from /etc/aorus-egpu/config.env"

# 79-aorus-egpu-no-autoload + 81-aorus-egpu-compute-power are templated; values
# come from auto-detected config.env. Re-rendered idempotently on each apply,
# so a hardware change followed by `sudo ./apply.sh` updates them in place.
if [[ -r /etc/aorus-egpu/config.env ]]; then
    # shellcheck source=/dev/null
    source /etc/aorus-egpu/config.env

    # ---- 79-aorus-egpu-no-autoload: simple variable substitution ----
    sed \
        -e "s|@@EGPU_VENDOR_ID@@|${EGPU_VENDOR_ID}|g" \
        -e "s|@@EGPU_DEVICE_ID@@|${EGPU_DEVICE_ID}|g" \
        -e "s|@@EGPU_AUDIO_DEVICE_ID@@|${EGPU_AUDIO_DEVICE_ID}|g" \
        etc/udev/rules.d/79-aorus-egpu-no-autoload.rules.template \
        > /etc/udev/rules.d/79-aorus-egpu-no-autoload.rules
    chmod 0644 /etc/udev/rules.d/79-aorus-egpu-no-autoload.rules
    printf '  rendered: /etc/udev/rules.d/79-aorus-egpu-no-autoload.rules\n'

    # ---- 81-aorus-egpu-compute-power: variable + array expansion ----
    # Build the TB host path block (one pair of ACTION lines per
    # TB_HOST_VENDOR_DEVICES entry) and the GPU+audio block, then
    # substitute both into the template.
    tb_block=""
    for vd in "${TB_HOST_VENDOR_DEVICES[@]}"; do
        v="${vd%:*}"; d="${vd#*:}"
        tb_block+="ACTION==\"add|bind|change\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"${v}\", ATTR{device}==\"${d}\", TEST==\"power/control\", ATTR{power/control}=\"on\""$'\n'
        tb_block+="ACTION==\"add|bind|change\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"${v}\", ATTR{device}==\"${d}\", TEST==\"d3cold_allowed\", ATTR{d3cold_allowed}=\"0\""$'\n'
    done
    gpu_block=""
    for d in "${EGPU_DEVICE_ID}" "${EGPU_AUDIO_DEVICE_ID}"; do
        gpu_block+="ACTION==\"add|bind|change\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"${EGPU_VENDOR_ID}\", ATTR{device}==\"${d}\", TEST==\"power/control\", ATTR{power/control}=\"on\""$'\n'
        gpu_block+="ACTION==\"add|bind|change\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"${EGPU_VENDOR_ID}\", ATTR{device}==\"${d}\", TEST==\"d3cold_allowed\", ATTR{d3cold_allowed}=\"0\""$'\n'
    done
    # awk handles the multi-line substitution cleanly without sed escape pain.
    # Anchored ^...$ so only standalone-placeholder lines match; placeholder
    # references inside comment text are unaffected.
    awk -v tb="$tb_block" -v gpu="$gpu_block" '
        /^@@TB_HOST_PATH_RULES@@$/  { printf "%s",  tb;  next }
        /^@@EGPU_GPU_AUDIO_RULES@@$/ { printf "%s", gpu; next }
        { print }
    ' etc/udev/rules.d/81-aorus-egpu-compute-power.rules.template \
        > /etc/udev/rules.d/81-aorus-egpu-compute-power.rules
    chmod 0644 /etc/udev/rules.d/81-aorus-egpu-compute-power.rules
    printf '  rendered: /etc/udev/rules.d/81-aorus-egpu-compute-power.rules\n'
else
    yellow "  /etc/aorus-egpu/config.env missing — cannot render templated udev rules"
fi

# ----------------------------------------------------- SELinux / udev reload -
step "restore SELinux contexts and reload udev"

restorecon_paths=()
for name in "${EGPU_UDEV_STATIC[@]}" "${EGPU_UDEV_TEMPLATED[@]}"; do
    restorecon_paths+=("$(egpu_path_udev "$name")")
done
for name in "${EGPU_MODPROBE_CONFS[@]}"; do
    restorecon_paths+=("$(egpu_path_modprobe "$name")")
done
for name in "${EGPU_SYSCTL_CONFS[@]}"; do
    restorecon_paths+=("$(egpu_path_sysctl "$name")")
done
for name in "${EGPU_SERVICES_ACTIVE[@]}" "${EGPU_SERVICES_RETIRED[@]}"; do
    restorecon_paths+=("$(egpu_path_service "$name")")
done
for name in "${EGPU_DROP_INS[@]}"; do
    restorecon_paths+=("$(egpu_path_dropin "$name")")
done
for name in "${EGPU_BINARIES[@]}" "${EGPU_BINARIES_RETIRED[@]}"; do
    restorecon_paths+=("$(egpu_path_binary "$name")")
done

if command -v restorecon >/dev/null; then
    restorecon -F "${restorecon_paths[@]}" 2>/dev/null || true
fi

udevadm control --reload-rules

# ------------------------------------------------------------- cleanup phase -
step "merged-/usr layout handling"

remove_if_exists() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        printf '  removed: %s\n' "$path"
    else
        printf '  absent (ok): %s\n' "$path"
    fi
}

# On Fedora, /usr/local/sbin is a symlink to /usr/local/bin. If they resolve
# to the same directory, scripts in /usr/local/bin ARE the canonical scripts;
# do not delete them. Otherwise (separate directories) cleanup duplicates left
# by prior installs and create a /usr/local/bin/aorus-egpu-status symlink so
# the status command is on a default user PATH.
sbin_real="$(readlink -f /usr/local/sbin)"
bin_real="$(readlink -f /usr/local/bin)"
if [[ "$sbin_real" == "$bin_real" ]]; then
    printf '  /usr/local/sbin and /usr/local/bin resolve to the same directory; no duplicate cleanup needed\n'
else
    for bin in "${EGPU_BINARIES[@]}" "${EGPU_BINARIES_RETIRED[@]}"; do
        remove_if_exists "/usr/local/bin/$bin"
    done
    rm -f /usr/local/bin/aorus-egpu-status
    ln -sfn /usr/local/sbin/aorus-egpu-status /usr/local/bin/aorus-egpu-status
    printf '  /usr/local/bin/aorus-egpu-status -> /usr/local/sbin/aorus-egpu-status\n'
fi

# ----------------------------------------- aorus-5090-* → aorus-egpu-* rename --
# Q3 Tier 2 rename pass (2026-05-09): drop the gpu-model suffix from userspace
# names since most levers generalise across Blackwell + open driver. Old names
# (LEGACY_* arrays in lib/install-manifest.sh) are aliased cleanup targets so
# an existing install can migrate forward idempotently. Once an install has
# run apply.sh post-rename, no aorus-5090-* unit / binary / config remains.
step "migrate from aorus-5090-* / aorus-lever-m-* to aorus-egpu-*"

for svc in "${LEGACY_SERVICES[@]}" "${LEGACY_VESTIGIAL_SERVICES[@]}"; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        systemctl stop "$svc" >/dev/null 2>&1 || true
        printf '  stopped: %s\n' "$svc"
    fi
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        systemctl disable "$svc" >/dev/null 2>&1 || true
        printf '  disabled: %s\n' "$svc"
    fi
    remove_if_exists "/etc/systemd/system/$svc"
done

for bin in "${LEGACY_BINARIES[@]}"; do
    remove_if_exists "/usr/local/sbin/$bin"
    remove_if_exists "/usr/local/bin/$bin"
done

for f in "${LEGACY_MODPROBE[@]}"; do
    remove_if_exists "/etc/modprobe.d/$f"
done

for f in "${LEGACY_SYSCTL[@]}"; do
    remove_if_exists "/etc/sysctl.d/$f"
done

for f in "${LEGACY_UDEV[@]}"; do
    remove_if_exists "/etc/udev/rules.d/$f"
done

for f in "${LEGACY_VESTIGIAL_FILES[@]}"; do
    remove_if_exists "$f"
done

# Protective blacklist stub written by remove.sh on graceful shutdown.
# Removed here so our proper modprobe.d files take effect.
remove_if_exists /etc/modprobe.d/zz-aorus-egpu-blacklist.conf

# ---------------------------------------------------------------- services --
step "reload systemd, mask/disable/enable services"

systemctl daemon-reload

# Robust masker. Handles three cases:
#   - already masked (no-op)
#   - not installed at all (no-op; expected on compute-only when desktop
#     meta-package or nvidia-container-toolkit are not present)
#   - shipped from /etc/ as a regular file (rename + /dev/null symlink, since
#     `systemctl mask` refuses "File already exists")
#   - shipped from /usr/lib/ (standard mask works)
mask_unit_robust() {
    local unit="$1"
    local etc_path="/etc/systemd/system/$unit"
    local enabled
    # systemctl is-enabled returns non-zero for masked/disabled/not-found,
    # which would trip set -e on the assignment. Suppress the rc; we read
    # the captured output to dispatch.
    enabled=$(systemctl is-enabled "$unit" 2>&1) || true
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

# nvidia-fallback should be masked (loads nouveau on NVIDIA failure - fights us).
mask_unit_robust nvidia-fallback.service

# nvidia-powerd: opens/closes device files at runtime, which is exactly
# the close-path-bug trigger we work hard to prevent. On a compute-only
# install via the NVIDIA CUDA repo, nvidia-powerd is not installed at all
# (the desktop meta-package nvidia-driver provided it) - mask_unit_robust
# handles the 'not installed' case as a no-op.
mask_unit_robust nvidia-powerd.service

# Compute-only mode: mask GPU-touching system services that are pointless
# on this host. Each is a potential close-path-bug trigger if it dlopens
# libnvidia-ml or opens /dev/nvidia* during its lifecycle.
#
#   switcheroo-control.service - shipped in /usr/lib/, standard mask works.
#                                Manages display GPU switching for laptops
#                                with hybrid graphics; we are compute-only.
#   nvidia-cdi-refresh.path    - shipped DIRECTLY in /etc/systemd/system/ by
#                                nvidia-container-toolkit RPM. systemctl
#                                mask refuses ("File already exists"); we
#                                rename the original aside and symlink
#                                /dev/null in its place. Same effect.
#                                The .path watches modules.dep + nvidia-ctk
#                                and triggers .service to dlopen libnvml.
mask_unit_robust switcheroo-control.service
mask_unit_robust nvidia-cdi-refresh.path
mask_unit_robust nvidia-cdi-refresh.service
systemctl daemon-reload

# Enable every active service from the manifest (idempotent).
for svc in "${EGPU_SERVICES_ACTIVE[@]}" nvidia-persistenced.service; do
    if ! systemctl is-enabled "$svc" >/dev/null 2>&1; then
        systemctl enable "$svc" >/dev/null 2>&1 && printf '  enabled: %s\n' "$svc" || \
            yellow "  could not enable $svc (unit file not found?)"
    else
        printf '  already enabled: %s\n' "$svc"
    fi
done

# Disable every retired service (kept on disk as historical archive).
# Resurrection: `sudo systemctl enable --now <service>` per
# docs/service-retirement-roadmap.md.
for svc in "${EGPU_SERVICES_RETIRED[@]}"; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
        printf '  disabled (retired): %s\n' "$svc"
    else
        printf '  already retired: %s\n' "$svc"
    fi
done

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

# The 82-aorus-egpu-nvidia-permissions.rules udev rule restricts /dev/nvidia*
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
# 81-aorus-egpu-compute-power.rules d3cold/power_control rewrites).
udevadm trigger --subsystem-match=pci

# Pre-flight: probe the GPU. If degraded, attempt recovery via reset.sh
# (preserves BAR1 sizing — uses ReBAR resize / bus reset / M-recover, never
# remove+rescan). If hard-wedged, skip live-state and let the user reboot;
# files installed by apply.sh are durable and will pick up on next boot.
if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]] && [[ -x "$repo_root/reset.sh" ]]; then
    if ! "$repo_root/reset.sh" --probe >/dev/null 2>&1; then
        yellow "  GPU in degraded state — attempting reset.sh --auto recovery..."
        if "$repo_root/reset.sh" --auto; then
            green "  recovery succeeded; continuing live-state"
        else
            rc=$?
            if [[ $rc -eq 2 ]]; then
                yellow "  GPU is hard-wedged (link/config dead); skipping live-state."
                yellow "  apply.sh files are installed; reboot to converge to live state."
                exit 0  # files installed = success; live-state deferred
            else
                yellow "  recovery did not restore healthy state; continuing best-effort"
            fi
        fi
    fi
fi

# If nvidia is already loaded and bound and persistenced is already running,
# we are done and do not need to start anything. Otherwise, start the chain:
# Read /proc/modules directly to avoid SIGPIPE on lsmod under pipefail.
if ! grep -q '^nvidia ' /proc/modules; then
    if [[ -e /sys/bus/pci/devices/0000:04:00.0 ]]; then
        printf '  starting aorus-egpu-compute-load-nvidia.service\n'
        systemctl start aorus-egpu-compute-load-nvidia.service
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
elif systemctl is-active aorus-egpu-uvm-keepalive.service >/dev/null 2>&1; then
    printf '  aorus-egpu-uvm-keepalive.service is active\n'
else
    printf '  starting aorus-egpu-uvm-keepalive.service\n'
    systemctl start aorus-egpu-uvm-keepalive.service || true
fi

# --------------------------------------------------------------- final check -
step "post-apply status"
/usr/local/sbin/aorus-egpu-status || true

green "\napply.sh complete."
green "Reboot to verify the configuration survives a cold boot."
