# Recovery

What to do when the eGPU stack goes wrong. Read `docs/architecture.md` first if you have not already.

## Decision tree

```
Is the host responsive?
  YES -> see "Diagnostic" below.
  NO  -> see "Forced recovery" below. The host is frozen; nothing else is going to fix it.
```

## Forced recovery

The freeze fingerprint on this hardware is: full system lock, fans ramp to full, no flushed kernel logs, SSH sessions die, keyboard / mouse unresponsive.

1. Hold the power button until the NUC powers off (or use the reset hardware if available).
2. Power on. As GRUB appears, edit the default entry: press `e`, find the line starting with `linux`, append at the end of that line (a single space then):

   ```
   systemd.unit=multi-user.target
   ```

   Press `Ctrl+X` (or `F10`) to boot. This skips GDM/GNOME and brings up only TTY login.

3. Login at the TTY as your normal user.

4. Inspect the previous boot:

   ```bash
   sudo aorus-egpu-status
   journalctl -k -b -1 --no-pager | tail -200
   journalctl -b -1 --no-pager -g 'nvidia|NVRM|Xid|AER|fallen off|nvidia-persistenced|aorus' | tail -200
   ```

5. If you need to come up without the eGPU stack while you investigate:

   ```bash
   sudo systemctl disable aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service
   sudo reboot
   ```

   Re-enable later with `sudo systemctl enable aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service`.

## Diagnostic (host is responsive)

### CUDA / Python program returned `CUDA_ERROR_UNKNOWN` or `cuInit=999`

This is the failure mode that historically caused **delayed kernel panics** on this stack. The trigger is `cuInit` trying to load `nvidia_uvm` and failing because of our compute-only modprobe blocks.

If you see this:

1. **Do not run any further CUDA / NVML calls.** The GPU is in a partial-init state and may panic the host minutes later.
2. Check whether `nvidia_uvm` is loaded:

   ```bash
   lsmod | grep nvidia_uvm
   ```

   If absent, that is the cause. The loader is supposed to pre-load it at boot.

3. Reboot. Do not try to fix it live - the partial-init state may already have set up a panic trigger.
4. After reboot, run `sudo aorus-egpu-status` and confirm `nvidia_uvm: loaded`. If it is not, the loader did not run or did not get past binding. Check the bind service:

   ```bash
   sudo systemctl status aorus-egpu-compute-load-nvidia.service
   sudo journalctl -u aorus-egpu-compute-load-nvidia.service -b
   ```

5. If diagnostic CUDA runs need to happen even with `nvidia_uvm` somehow not loaded, use `tools/tty-cuda-test.sh` which refuses to start without the precondition met.

### `nvidia-smi` hangs but the rest of the system is fine

This should not happen with persistenced running. If it does, persistenced is probably dead. Do NOT run another `nvidia-smi` - the second invocation will freeze the host. Instead:

```bash
ps -ef | grep nvidia-persistenced
sudo systemctl status nvidia-persistenced.service
```

If the daemon is dead:

```bash
sudo reboot
```

Do not try to restart persistenced while `nvidia` is loaded; restart triggers the same close+reopen wedge. Reboot is the recovery.

### `nvidia-smi` returns "Failed to initialize NVML" or similar

Run the status check:

```bash
sudo aorus-egpu-status
```

Read the output:

| Symptom | Cause | Fix |
|---|---|---|
| `thunderbolt.host_reset: NOT disabled` | Boot args lost | `sudo grubby --update-kernel=ALL --args="thunderbolt.host_reset=false"`, reboot |
| `GPU: not present` | eGPU disconnected, powered off, or TB authorization failed | Power-cycle the eGPU, check Thunderbolt cable, reboot |
| `GPU driver: none` | compute-load service did not run, or failed | `sudo systemctl status aorus-egpu-compute-load-nvidia.service`, check journal |
| `BAR1: ... (less than 32 GiB)` | Thunderbolt host-router reset trashed the layout | Should not happen with `host_reset=false`. Verify boot args, cold boot with eGPU connected |
| `nvidia-persistenced: NOT running` | Persistenced did not start, or died | `sudo systemctl status nvidia-persistenced.service`, check journal. If it's dead and `nvidia` is loaded, reboot rather than restart |
| `nvidia_uvm: NOT loaded` | Loader did not pre-stage uvm, or it was unloaded | Reboot. Loader should re-stage on boot. If persistent, check loader output via `journalctl -u aorus-egpu-compute-load-nvidia.service`. Do NOT run CUDA programs in this state |
| `card2: nvidia` (or similar) under `drm_cards` | `nvidia_drm` loaded; this should never happen | Reboot; if persistent, check that `aorus-egpu-compute-only.conf` is in place |

### Fan stops, GPU heats up

The driver provides thermal control. If `nvidia` unloads or the GPU unbinds, fan / pump stop. Get the driver loaded again immediately:

```bash
sudo systemctl restart aorus-egpu-compute-load-nvidia.service
sudo systemctl restart nvidia-persistenced.service
```

If that does not work, you may already be in a wedged state. Reboot.

### After a kernel update, services fail at boot

The akmod build might not have completed before the new kernel booted. Check:

```bash
ls /lib/modules/$(uname -r)/extra/nvidia/
sudo akmods --force
sudo dracut --force
```

If the module is not built for the running kernel, NVIDIA cannot load. Boot back into the previous kernel from GRUB, run `akmods --force`, then reboot.

### After an `nvidia` package update, `nvidia-smi` froze

NVIDIA's RPM scriptlets can re-enable services we have disabled (e.g. `nvidia-powerd`). They may also try to reload the module while the system is running. If a freeze followed an upgrade, on the next boot:

```bash
sudo systemctl is-enabled nvidia-powerd.service
sudo systemctl is-enabled nvidia-fallback.service
sudo systemctl is-enabled nvidia-persistenced.service
```

Expected: `nvidia-powerd disabled`, `nvidia-fallback masked`, `nvidia-persistenced enabled`. Re-disable / re-mask any that drifted.

Best practice for future updates: stop persistenced before `dnf upgrade`, run the upgrade, then reboot. Do NOT run `nvidia-smi` between stopping persistenced and rebooting.

## Reading kernel logs

The previous boot's kernel log is the single most useful artifact when investigating a freeze. The freezes documented during initial investigation always ended with the kernel log truncated mid-event - the log entries you DO see immediately before the truncation are the freeze trigger.

```bash
journalctl --list-boots
journalctl -k -b -1 --no-pager > /tmp/prev-boot-kernel.log
```

Things to grep for:

- `NVRM` - NVIDIA driver messages
- `Xid` - GPU hardware errors
- `fallen off the bus` - PCI access failure
- `AER` - PCIe Advanced Error Reporting (uncorrectable bus errors)
- `nvidia-persistenced` - daemon activity
- `aorus-5090` - our service activity
- `D3cold` - power management transitions
- `BAR0` / `BAR 0` / `BAR 1` - resource allocation events

If the previous-boot log ends abruptly with no clean shutdown sequence, you had a freeze. The last few lines tell you where.

## Last resort

If the system is repeatedly unbootable to the point that even the multi-user.target recovery does not help:

1. Boot from a Fedora live USB.
2. Mount the system's root subvolume:

   ```bash
   sudo mount -o subvol=root /dev/<your-root-device> /mnt
   sudo arch-chroot /mnt /bin/bash    # or the Fedora equivalent
   ```

3. Disable services:

   ```bash
   systemctl disable aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service
   ```

4. Optional: remove the boot args:

   ```bash
   grubby --remove-args='pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 thunderbolt.host_reset=false' --update-kernel=ALL
   ```

5. Reboot to the host system.

The Git repo at `/root/aorus-5090-egpu/` is the source of truth for the configuration; you can re-apply with `apply.sh` once you have a stable boot.
