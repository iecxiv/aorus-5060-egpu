# AORUS RTX 5090 AI Box on Fedora 42 (NUC 15 Pro+, kernel 6.19)

The clean, minimal, happy-path documentation for running an AORUS GeForce RTX 5090 AI Box (GB202, Blackwell) over Thunderbolt 4 on a Fedora 42 host, with proprietary NVIDIA userspace 580.142.

This config delivers:

- `nvidia-smi` runs reliably, repeatedly.
- Driver-managed thermal control (water cooling and fan run from boot).
- CUDA / vLLM compute use of the eGPU.
- Internal Intel Arc GPU keeps GNOME / display ownership (`i915` only in DRM).

## What this is not

- Not a fix for the underlying close-path bug in NVIDIA's open kernel module on Blackwell over Thunderbolt; instead, it works around it cleanly using `nvidia-persistenced`. See `docs/architecture.md` for the bug summary and `docs/future-investigations.md` for the upstream report path.
- Not a desktop / display configuration. The eGPU is compute-only here; GNOME never sees an NVIDIA DRM device.

## Requirements

- ASUS NUC 15 Pro+ (or similar Intel Thunderbolt 4 host).
- AORUS RTX 5090 AI Box.
- Fedora 42, kernel `6.19.14-100.fc42.x86_64` (or newer in the same line).
- RPM Fusion `akmod-nvidia` 580.142 already installed and built for the running kernel.

Verify:

```bash
rpm -qa | grep -E 'akmod-nvidia|kmod-nvidia|nvidia-persistenced'
uname -r
```

Expected (versions may differ, kernel must match):

```
akmod-nvidia-580.142-2.fc42.x86_64
kmod-nvidia-6.19.14-100.fc42.x86_64-580.142-2.fc42.x86_64
nvidia-persistenced-580.142-1.fc42.x86_64
```

## Install

From this repository directory:

```bash
cd /root/aorus-5090-gpu
sudo ./apply.sh
```

`apply.sh` is idempotent. It:

1. Copies all config files into place under `/`.
2. Restores SELinux contexts on copied files.
3. Reloads systemd.
4. Removes vestigial debug tooling (collect-pci-layout service, latch files, duplicates in `/usr/local/bin`).
5. Enables `aorus-5090-compute-load-nvidia.service` and `nvidia-persistenced.service`.
6. Reports what it did.

It does NOT:

- Reboot the system.
- Modify kernel boot args (those must already be in place; the script verifies them and warns if not).
- Touch a working NVIDIA module that is already bound (the loader is idempotent).

After running:

```bash
sudo aorus-5090-status
```

This must show: `host_reset: disabled`, `nvidia: loaded`, `nvidia_drm: unloaded`, GPU bound to `nvidia` driver, BAR1 = 32 GiB, persistenced running with fds on `/dev/nvidia0`, DRM only `i915`.

## Verify

The repository ships three top-level scripts. Each is idempotent and safe to run repeatedly.

| Script | Purpose |
|---|---|
| `apply.sh`  | Install / re-apply the configuration. Safe to run any time. |
| `status.sh` | Comprehensive verification. Checks every load-bearing piece (boot args, modules, udev, modprobe, scripts, services, PCI, Thunderbolt, persistenced, DRM, kernel logs, smoke test). Exit code 0 = healthy, 1 = warnings, 2 = degraded. |
| `remove.sh` | Reverse the install. Removes config files, drop-in, and disables services. Does NOT remove kernel boot args. |

To verify after install:

```bash
sudo ./status.sh
```

Or for a quick operational check (single-page output):

```bash
sudo aorus-5090-status
```

Manual smoke test:

```bash
nvidia-smi
nvidia-smi
nvidia-smi
```

All three must show the RTX 5090 with consistent telemetry. Fan should be running at 30%; idle temperature 45-50C; P8 power state.

```bash
systemctl status aorus-5090-compute-load-nvidia.service nvidia-persistenced.service
```

Both `active`. `aorus-5090-compute-load-nvidia.service` will be `active (exited)` because it is `Type=oneshot, RemainAfterExit=yes`.

## Reboot test

```bash
sudo reboot
```

After login, run `aorus-5090-status` and a few `nvidia-smi` invocations. Expected: same state as before reboot, no manual intervention.

If GNOME freezes during boot or login: forced reboot (hold power), then at GRUB add `systemd.unit=multi-user.target` to boot to TTY-only mode. Login at the TTY, run `sudo aorus-5090-status` and `journalctl -k -b -1` to see what happened, then `sudo systemctl disable aorus-5090-compute-load-nvidia.service nvidia-persistenced.service` to come up without the eGPU stack while you investigate. See `docs/recovery.md`.

## Day-to-day operation

You normally do not need to touch anything.

```bash
# Status
sudo aorus-5090-status

# Routine query
nvidia-smi

# Boot without the eGPU (e.g. travel)
sudo systemctl disable aorus-5090-compute-load-nvidia.service nvidia-persistenced.service
sudo reboot
# Re-enable later:
sudo systemctl enable aorus-5090-compute-load-nvidia.service nvidia-persistenced.service
sudo reboot

# Boot with eGPU disconnected: nothing to do. Both services have
# ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0 and skip cleanly.
```

## Update procedure

NVIDIA driver / kernel updates can rebuild the module and may try to reload it. Best practice:

1. **Before** running `dnf upgrade`, stop persistenced:

   ```bash
   sudo systemctl stop nvidia-persistenced.service
   ```

   (Do NOT stop persistenced and then run `nvidia-smi` from any process; the next NVML use will freeze the host.)

2. Upgrade:

   ```bash
   sudo dnf upgrade
   ```

3. Reboot:

   ```bash
   sudo reboot
   ```

   On the new boot, the service chain restores the working state automatically.

If a kernel update changes `/etc/kernel/cmdline`, re-run `apply.sh` to regenerate the boot args. Verify with `cat /proc/cmdline` after reboot.

## Files installed

| Path | Purpose |
|---|---|
| `/etc/udev/rules.d/79-aorus-5090-no-autoload.rules` | Block auto-bind / auto-load of the eGPU |
| `/etc/udev/rules.d/81-aorus-5090-compute-power.rules` | Pin TB / GPU path out of D3cold |
| `/etc/modprobe.d/aorus-5090-compute-only.conf` | Block automatic and explicit nvidia module loads |
| `/etc/modprobe.d/blacklist-nouveau.conf` | Defence-in-depth nouveau blacklist |
| `/etc/systemd/system/aorus-5090-compute-load-nvidia.service` | Bind the eGPU at boot |
| `/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` | Order persistenced after the bind step |
| `/usr/local/sbin/aorus-5090-compute-load-nvidia` | Loader implementation |
| `/usr/local/sbin/aorus-5090-disable-audio` | HDMI audio function unbinder |
| `/usr/local/sbin/aorus-5090-status` | Health check |

Kernel boot args (managed via `grubby` / `/etc/kernel/cmdline`, see `etc/kernel/cmdline.txt`):

```
module_blacklist=nouveau,nova_core
rd.driver.blacklist=nouveau,nova_core
modprobe.blacklist=nouveau,nova_core
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0
thunderbolt.host_reset=false
```

## Remove

```bash
sudo ./remove.sh
```

Disables the services, removes the persistenced drop-in, and restores the directory to the package-managed state. Does NOT remove kernel boot args (do that manually with `grubby --remove-args=...` if you want).

WARNING: if `nvidia-persistenced` is currently running and the `nvidia` module is loaded, `remove.sh` will stop the daemon - which closes its `/dev/nvidia0` fds. Any subsequent `nvidia-smi` or NVML caller in the same boot will then trigger the close-reopen freeze. Reboot immediately after running `remove.sh` if the eGPU was active.

## More

- `docs/architecture.md` - why each piece exists, the bug it works around.
- `docs/recovery.md` - what to do when things go wrong.
- `docs/future-investigations.md` - upstream bug report draft, `NVreg_DynamicPowerManagement` test plan.
- `archive/` - historical investigation artefacts (recovery plan, ioctl tracer, all freeze-test scripts).
