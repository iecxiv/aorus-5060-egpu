# Architecture

This document explains why each piece of the configuration exists. Read this if you want to understand the system, change it safely, or escalate a bug upstream.

## The three core problems

### Problem 1: BAR1 collapses during Thunderbolt authorization

On boot, the firmware enumerates the eGPU PCI tunnel and assigns the RTX 5090 a 32 GiB resizable BAR1 on a 32 GiB downstream bridge window. The kernel's Thunderbolt authorization path then issues a host-router reset, tears the tunnel down, and re-enumerates. During the re-enumeration, the downstream bridge gets a smaller window (256-288 MiB) and BAR1 is forced down to 256 MiB. NVIDIA driver bind fails with `BAR0 is 0M @ 0x0` or similar.

**Fix:** kernel boot arg `thunderbolt.host_reset=false`. Skips the host-router reset; the firmware-assigned 32 GiB BAR1 survives authorization. `bolt.service` works normally.

Supporting boot args to keep the BAR allocation healthy:

- `pci=realloc,pcie_bus_perf` - allow the kernel to re-allocate PCI resources after Thunderbolt authorization, instead of giving up when initial assignment fails.
- `hpmmioprefsize=256M` - cap empty hotplug bridge prefetchable windows at 256 MiB so they do not starve the actual GPU's bridge.
- `resource_alignment=35@0000:03:00.0` - force the occupied bridge to be aligned for 32 GiB (= 2^35).

### Problem 2: Second open of `/dev/nvidia0` hard-freezes the host

On Blackwell over Thunderbolt with the open kernel module 580.142, the first open+close of `/dev/nvidia0` works. The second open in the same module-load session hangs in the kernel's `open()` syscall and locks up the host. No flushed kernel logs; forced reboot is the only recovery.

The boundary was confirmed with an `LD_PRELOAD` ioctl tracer:

```
open64_enter dirfd=-100 path=/dev/nvidia0 flags=0x80802 mode=00
   (no matching open64_exit)
```

The bug persists across `modprobe -r nvidia ; modprobe nvidia` - so the wedge state lives below the kernel module, in GPU/GSP firmware state or a per-PCI-device kernel structure. Setting `NVreg_EnableNonblockingOpen=0` only relocates the hang from `NV_ESC_WAIT_OPEN_COMPLETE` ioctl into `open()` itself; it is not a fix.

**Workaround:** `nvidia-persistenced`. The daemon opens `/dev/nvidiactl` once and `/dev/nvidia0` four times at startup and holds them for its lifetime. Every subsequent `nvidia-smi` (or any NVML caller) is therefore an "additional open alongside an existing one", never a "first open after last close". The close-side teardown that wedges the next open never runs because the open count never drops to zero.

This is a vendor-supported configuration. It is not a hack. It is, however, **load-bearing** on this hardware in a way it is not on normal NVIDIA setups: stopping persistenced re-exposes the freeze.

### Problem 3: Failed `cuInit` causes delayed kernel panics

A separate failure mode, identified on 2026-05-01:

- The compute-only modprobe config blocks all four NVIDIA modules from auto-loading via `install nvidia* /bin/false` lines. This is needed to prevent any process other than our loader from binding the eGPU before `nvidia-persistenced` is up.
- However, when CUDA's `cuInit()` runs, it ensures `nvidia_uvm` is loaded as part of initialisation. With the blocks in place, `cuInit`'s internal `modprobe nvidia_uvm` call returns 1 (because `/bin/false` ran), and `cuInit` returns `CUDA_ERROR_UNKNOWN` (999) to the caller.
- The catastrophic behaviour: a failed `cuInit` does not unwind cleanly on this stack. Some partial state has already been set up on the GPU (we observed 1 MiB allocated and never freed). Minutes later, the host kernel-panics — no flushed logs, forced reboot the only recovery.

**Fix:** the loader script pre-loads `nvidia_uvm` after `nvidia` binds, via `modprobe --ignore-install nvidia_uvm` (the `--ignore-install` flag bypasses our own block). With `nvidia_uvm` already loaded, no later `cuInit` call ever has to invoke modprobe; CUDA initialisation finds everything it needs and succeeds cleanly.

Validated 2026-05-01: with `nvidia_uvm` pre-staged, the CUDA Driver API smoke test (`cuInit -> cuMemAlloc -> cuMemcpyDtoH`) passes end-to-end, returns 0 MiB used after cleanup (no leak), and the host survives the 30 s post-test idle window without any delayed panic. See `archive/cuda-validation-2026-05-01/` for evidence.

The install lines in `etc/modprobe.d/aorus-5090-compute-only.conf` remain because they still serve their original purpose — preventing arbitrary processes from triggering an `nvidia` or `nvidia_uvm` load before our service has bound them. We just route around them at boot via the loader's `--ignore-install`.

## How the configuration enforces this

### Boot args

See `etc/kernel/cmdline.txt`. Kernel-level fixes for problem 1 plus defence-in-depth nouveau blacklist (in 3 forms, one for each path: cmdline, initramfs, modprobe).

### udev rules

`79-aorus-5090-no-autoload.rules`:

- Sets `driver_override=aorus_5090_manual` on the GPU. PCI's `drivers_autoprobe` will not auto-bind any registered driver to a device with a `driver_override` that does not match. `aorus_5090_manual` is a fictitious driver name, so nothing binds.
- Clears `ENV{MODALIAS}` before systemd-udevd's `80-drivers.rules` matcher runs. This stops `kmod` from loading `nvidia` from a generic PCI modalias autoload event. (Just having `driver_override` is not enough, because the module would still load by alias even without binding.)
- Mirror behaviour for the HDMI audio function (`10de:22e8`), with a `RUN+=` calling `aorus-5090-disable-audio` to actively unbind it from `snd_hda_intel` if it ever did bind.

`81-aorus-5090-compute-power.rules`:

- For each device on the eGPU PCI path (TB controller, bridge, GPU, audio), forces `power/control=on` (no autosuspend) and `d3cold_allowed=0` (no D3cold). Without this, runtime PM can put the path into D3cold; coming back out over the TB tunnel is unreliable.

### modprobe configs

`aorus-5090-compute-only.conf`:

- `blacklist nvidia / nvidia_modeset / nvidia_uvm / nvidia_drm` - blocks udev/modalias autoload.
- `install nvidia /bin/false` - and equivalents - turns explicit `modprobe nvidia` calls (e.g. by NVIDIA's RPM scriptlets, by `nvidia-modprobe`, by other tools) into no-ops.
- `options nvidia_drm modeset=0 fbdev=0` - belt and suspenders: even if `nvidia_drm` somehow loads, it will not register a DRM device.

The loader script bypasses these blocks with `modprobe --ignore-install nvidia`.

`blacklist-nouveau.conf` - additional defence in depth; redundant with cmdline.

### systemd

`aorus-5090-compute-load-nvidia.service`:

- `After=systemd-udev-settle.service bolt.service`, `Before=graphical.target`. The eGPU must be enumerated and authorized before this runs; persistenced and GDM must come after.
- `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` - skip cleanly if the eGPU is not connected.
- `Type=oneshot, RemainAfterExit=yes` - one-shot bind, then stays "active (exited)" so dependents (persistenced) can `Requires=` it.
- Calls `/usr/local/sbin/aorus-5090-compute-load-nvidia`, which: applies upstream PM policy; verifies BAR0 and BAR1; clears `driver_override`; `modprobe --ignore-install nvidia`; pokes `drivers_probe`; restores `driver_override` to prevent any future auto-rebind to a wrong driver.

`nvidia-persistenced.service.d/aorus-egpu.conf` (drop-in):

- `After=` and `Requires=aorus-5090-compute-load-nvidia.service` - persistenced will only start if the GPU is bound, and it will start after the bind.
- `ConditionPathExists=/sys/bus/pci/devices/0000:04:00.0` - skip cleanly with eGPU disconnected (mirrors the bind service).
- `Restart=no` - explicitly disable systemd auto-restart. If persistenced dies while `nvidia` is loaded, restarting it would close+reopen device files and freeze the host. Better to fail loud.

### Other state

- `nvidia-fallback.service` masked. It would run `modprobe nouveau` on NVIDIA failure, fighting our nouveau blacklist.
- `nvidia-powerd.service` disabled. Opens/closes device files; would re-trigger the wedge.
- `nvidia-suspend / -resume / -hibernate` enabled (default). These run during sleep transitions; we accept the small risk of suspend issues for normal sleep behaviour.
- `nvidia-settings` user autostart neutralized via `Hidden=true` in `/etc/xdg/autostart/nvidia-settings-user.desktop`.

## Why GNOME stays stable

GNOME on Wayland uses `i915` as its DRM device for the internal Intel Arc. We never expose an NVIDIA DRM device:

- `nvidia_drm` is blacklisted with `install ... /bin/false`.
- The loader explicitly errors out if `nvidia_drm` ends up loaded.
- `driver_override=aorus_5090_manual` plus cleared `MODALIAS` means GNOME's `switcheroo-control` and friends see the eGPU on PCI but nothing has bound it as a display device.

Validated: across many test boots, `/sys/class/drm/card*` always shows only `card1: i915`.

## Why the eGPU stays cool

The AORUS AI Box's water cooling pump and fan are driven by the NVIDIA driver. With the driver unloaded, the device sits with no thermal control. The boot path here ensures the driver loads as early as possible (right after udev settle and bolt), so thermal management starts in seconds.

Persistence mode keeps the GPU in P8 idle (low power) when not in use, with the fan stable around 30% and idle temperature 45-50C.
