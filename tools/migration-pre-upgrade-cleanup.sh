#!/usr/bin/env bash
# Pre-upgrade cleanup before F42 -> F43 + RPMFusion -> NVIDIA-CUDA-repo migration.
#
# Minimal scope by design - the eGPU disconnect during the upgrade does the
# heavy lifting. With the eGPU absent, every ConditionPathExists guard in
# the loader, persistenced drop-in, keep-alive unit, and ollama drop-in
# fires and skips the unit. No NVIDIA kernel modules load. The upgrade
# runs cleanly with zero GPU exposure.
#
# What this script does:
#   1. Stop ollama (clean, doesn't hold any /dev/nvidia* fds itself)
#   2. Disable ollama autostart (don't want it firing post-upgrade before
#      we've validated the new install)
#   3. Snapshot what's preserved vs. what's been changed - report only
#
# What this script DOES NOT do:
#   - Stop persistenced or aorus-egpu-uvm-keepalive: they hold /dev/nvidia0
#     and /dev/nvidia-uvm fds; closing those fds at userspace level CAN
#     trigger the close-path bug. Better to power off the host (graceful
#     shutdown closes them all at once at the kernel level) and then
#     disconnect the eGPU before next boot.
#   - Restore renamed ICDs (.aorus-disabled). RPM remove logs warnings
#     for missing files but does NOT error. Renames are harmless during
#     the upgrade transit.
#   - Restore masked nvidia-cdi-refresh files. The /dev/null symlink IS
#     a regular file from RPM's perspective; remove operations work fine.
#   - Touch boot args, udev rules, modprobe.d, scripts, or our systemd units.
#     All of these are hardware-specific and survive the migration intact.
#
# Idempotent and safe to re-run.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "Must run as root." >&2
    exit 1
fi

step() { printf '\n=== %s ===\n' "$*"; }

step "stop ollama (only service we control that runs CUDA workloads)"
if systemctl is-active ollama >/dev/null 2>&1; then
    systemctl stop ollama
    printf '  stopped: ollama.service\n'
else
    printf '  already stopped: ollama.service\n'
fi

step "disable ollama autostart (re-enable manually after migration validation)"
if systemctl is-enabled ollama >/dev/null 2>&1; then
    systemctl disable ollama
    printf '  disabled: ollama.service\n'
else
    printf '  already disabled: ollama.service\n'
fi

step "what's PRESERVED through the migration"
cat <<EOF
The following are kept intact and will be re-evaluated post-install:

  Boot args (cmdline.txt):
    pci=realloc, thunderbolt.host_reset=false, iommu=pt, etc.
    -> Hardware-specific. Required regardless of driver source.

  /etc/udev/rules.d/79,81,82-aorus-egpu-*.rules
    -> Hardware-specific (driver_override, power state, perm tightening).

  /etc/modprobe.d/aorus-egpu-compute-only.conf
  /etc/modprobe.d/nvidia-power-management.conf
    -> NVreg options (DeviceFile{UID,GID,Mode}, DynamicPowerManagement,
       PreserveVideoMemoryAllocations, S0ix, RestrictProfilingToAdminUsers,
       blacklist + install lines for nouveau/nvidia auto-load prevention).
       -> Apply when the new driver loads. F43 dnf may write .rpmsave on
          conflict; we'll reconcile post-install.

  /etc/systemd/system/aorus-egpu-compute-load-nvidia.service
  /etc/systemd/system/aorus-egpu-uvm-keepalive.service
  /etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf
  /etc/systemd/system/ollama.service.d/aorus-egpu.conf
    -> Re-evaluate post-install. Some may need adaptation.

  /usr/local/sbin/aorus-egpu-* (loader, disable-audio, status, keep-alive)
    -> Hardware-specific.

  /root/aorus-5090-egpu/, /root/ollama/, /root/vllm/
    -> Repos persist (under btrfs root subvol).

The following are TRANSIENT through the migration:

  /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json.aorus-disabled
  /usr/share/vulkan/implicit_layer.d/nvidia_layers.json.aorus-disabled
  /usr/share/glvnd/egl_vendor.d/10_nvidia.json.aorus-disabled
  /etc/OpenCL/vendors/nvidia.icd.aorus-disabled
    -> Orphaned during F43+RPMFusion-removal. Deleted post-NVIDIA-install
       (compute-only mode does not install these in the first place).

  /etc/systemd/system/nvidia-cdi-refresh.path        (symlink to /dev/null)
  /etc/systemd/system/nvidia-cdi-refresh.path.aorus-disabled
  /etc/systemd/system/nvidia-cdi-refresh.service     (symlink to /dev/null)
  /etc/systemd/system/nvidia-cdi-refresh.service.aorus-disabled
    -> RPM 'remove nvidia-container-toolkit' clears these. Compute-only
       install does not include nvidia-container-toolkit by default.
EOF

step "next steps"
cat <<EOF
NOW the host is in a safe state to:

  1. (optional) Take btrfs snapshot for rollback:
       sudo /root/aorus-5090-egpu/tools/migration-snapshot.sh

  2. Power off:
       sudo systemctl poweroff

  3. Disconnect the eGPU:
       a. Wait until the NUC is fully powered down.
       b. Power off the AORUS AI Box (rear switch).
       c. Disconnect the Thunderbolt cable from the NUC.

  4. Power on the NUC:
       Boots without eGPU. ConditionPathExists guards skip our services.
       lsmod | grep nvidia shows nothing. Network/display/iGPU all fine.

  5. Run F42 -> F43 system upgrade per Fedora docs:
       sudo dnf upgrade --refresh
       sudo dnf install dnf-plugin-system-upgrade
       sudo dnf system-upgrade download --releasever=43
       sudo dnf system-upgrade reboot
EOF
