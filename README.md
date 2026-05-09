# AORUS RTX 5090 AI Box on NUC 15 Pro+

> **Is your symptom in scope?** See [`docs/failure-modes-index.md`](docs/failure-modes-index.md)
> for the master matrix of every failure mode this stack addresses
> (host freezes on first CUDA op, cold-cold-boot WPR2-stuck, GSP_LOCKDOWN
> cascades, close-path bugs, recovery storms, …) mapped to the specific
> levers / patches / services that resolved each. If your hardware is
> similar (Intel TB4 host + AORUS RTX 5090 AI Box), this is the fastest
> way to tell whether the project applies to you.

> **Status as of 2026-05-08 — reliability frontier converged.**
> The CUDA-workload host freeze documented at NVIDIA/open-gpu-kernel-modules#979
> is **empirically mitigated** on this stack. The mitigation has multiple
> contributors landed across the past two weeks; details in
> [`docs/lever-catalog.md`](docs/lever-catalog.md) and
> [`docs/reliability-hypothesis-ledger.md`](docs/reliability-hypothesis-ledger.md)
> (H22 — close-path bug class proven mitigated).
>
> **Current platform**: Fedora 43 + patched build of NVIDIA open kernel
> module **595.71.05-aorus.12** (30-patch series in [`patches/`](patches/),
> built via [`tools/build-patched-driver.sh`](tools/build-patched-driver.sh)
> against the upstream `NVIDIA/open-gpu-kernel-modules` source tree).
> Decode at WSL2 parity for llama3.1:8b (~256 tok/s); cold-load gap
> (~3.95 s vs ~30 ms WSL2) is the only remaining Path A non-parity item.
>
> **Reading order for new sessions:**
> 1. [`docs/failure-modes-index.md`](docs/failure-modes-index.md) — **start here.**
>    Master index mapping every observed failure mode to the levers /
>    patches / services that resolved it. Tells you in one page whether
>    your symptom is in scope and what fixed it.
> 2. [`docs/architecture.md`](docs/architecture.md) — what the system
>    is and how it's structured today.
> 3. [`docs/lever-catalog.md`](docs/lever-catalog.md) — every reliability
>    lever, current status, code surface.
> 4. [`docs/services/`](docs/services/) — **per-service canonical docs**.
>    For any individual service, this is the entry point: purpose,
>    configuration knobs, retirement criteria + procedure, resurrection
>    procedure. Use [`docs/service-retirement-roadmap.md`](docs/service-retirement-roadmap.md)
>    for the cross-cutting status table.
> 5. [`docs/reliability-hypothesis-ledger.md`](docs/reliability-hypothesis-ledger.md) —
>    every hypothesis with status (PROVEN / FALSIFIED / OPEN).
>
> The historical content below describes the older Fedora 42 + RPMFusion
> 580.142 / persistenced-as-load-bearing-stability era. Kept for archive
> value. **Not the current state.**

## What changed (concise summary 2026-05-08)

- 30-patch series landed in `patches/` (Lever I, J-2, M-base, M-recover,
  Q-watchdog, M-recover Commit 3 hardened, close-path DIAG instrumentation
  + UVM analogue).
- Three userspace services retired this week:
  `aorus-egpu-link-monitor.service` (2026-05-07),
  `aorus-egpu-pcie-tune.service` (Lever H9a, 2026-05-08),
  `aorus-egpu-uvm-keepalive.service` (2026-05-08 evening).
- `nvidia-persistenced.service` reclassified from "load-bearing for
  stability" to "load-bearing for warmup latency" — kept as performance
  optimisation.
- `aorus-egpu-wpr2-recovery.service` pending Phase 5 retirement gate
  (5/10 clean cold-cold-boots).
- Phase 5 evidence collection auto-runs per boot
  (`aorus-egpu-lever-m-phase5-snapshot.service` writes
  `archive/phase5-evidence/<boot-iso>.log`).

---

## Historical content (Fedora 42 + RPMFusion 580.142 era)

The clean, minimal, happy-path documentation for running an AORUS GeForce RTX 5090 AI Box (GB202, Blackwell) over Thunderbolt 4 on a Fedora 42 host, with proprietary NVIDIA userspace 580.142.

This config delivers:

- `nvidia-smi` runs reliably, repeatedly.
- Driver-managed thermal control (water cooling and fan run from boot).
- CUDA / vLLM compute use of the eGPU.
- Internal Intel Arc GPU keeps GNOME / display ownership (`i915` only in DRM).

## Validated as of 2026-05-01

- `nvidia-smi` runs repeatedly with `nvidia-persistenced` holding `/dev/nvidia0` open across invocations.
- CUDA Driver API works end-to-end: `cuInit` -> context create -> `cuMemAlloc` -> `cuMemsetD8` -> `cuMemcpyDtoH` -> verified data integrity, no leak. See `archive/cuda-validation-2026-05-01/` for the captured progress markers and post-state.
- Driver-managed thermal control active from boot.
- Internal Intel Arc GPU keeps GNOME / DRM ownership (`i915` only).

NOT yet validated: PyTorch / vLLM workloads. See `docs/future-investigations.md` and `tools/README.md` for the next test progressions.

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
cd /root/aorus-5090-egpu
sudo ./apply.sh
```

`apply.sh` is idempotent. It:

1. Copies all config files into place under `/`.
2. Restores SELinux contexts on copied files.
3. Reloads systemd.
4. Removes vestigial debug tooling (collect-pci-layout service, latch files, duplicates in `/usr/local/bin`).
5. Enables `aorus-egpu-compute-load-nvidia.service` and `nvidia-persistenced.service`.
6. Reports what it did.

It does NOT:

- Reboot the system.
- Modify kernel boot args (those must already be in place; the script verifies them and warns if not).
- Touch a working NVIDIA module that is already bound (the loader is idempotent).

After running:

```bash
sudo aorus-egpu-status
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
sudo aorus-egpu-status
```

Manual smoke test:

```bash
nvidia-smi
nvidia-smi
nvidia-smi
```

All three must show the RTX 5090 with consistent telemetry. Fan should be running at 30%; idle temperature 45-50C; P8 power state.

```bash
systemctl status aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service
```

Both `active`. `aorus-egpu-compute-load-nvidia.service` will be `active (exited)` because it is `Type=oneshot, RemainAfterExit=yes`.

## Reboot test

```bash
sudo reboot
```

After login, run `aorus-egpu-status` and a few `nvidia-smi` invocations. Expected: same state as before reboot, no manual intervention.

If GNOME freezes during boot or login: forced reboot (hold power), then at GRUB add `systemd.unit=multi-user.target` to boot to TTY-only mode. Login at the TTY, run `sudo aorus-egpu-status` and `journalctl -k -b -1` to see what happened, then `sudo systemctl disable aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service` to come up without the eGPU stack while you investigate. See `docs/recovery.md`.

## Day-to-day operation

You normally do not need to touch anything.

```bash
# Status
sudo aorus-egpu-status

# Routine query
nvidia-smi

# Boot without the eGPU (e.g. travel)
sudo systemctl disable aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service
sudo reboot
# Re-enable later:
sudo systemctl enable aorus-egpu-compute-load-nvidia.service nvidia-persistenced.service
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

## What the loader does at boot

`aorus-egpu-compute-load-nvidia.service` runs after `bolt.service` and `systemd-udev-settle.service`, before `graphical.target`. The script:

1. Verifies the eGPU is on PCI; exits cleanly if not.
2. Applies upstream PM policy on the TB -> bridge -> GPU path (`power/control=on`, `d3cold_allowed=0`).
3. Unbinds the HDMI audio function from `snd_hda_intel` (compute-only, no audio needed).
4. Verifies `BAR0` and `BAR1` are correctly assigned (BAR1 must be 32 GiB; the host_reset boot arg handles this).
5. Loads the `nvidia` kernel module via `modprobe --ignore-install nvidia` and confirms the GPU bound.
6. **Pre-loads `nvidia_uvm`** via `modprobe --ignore-install nvidia_uvm`. This is critical: any later `cuInit()` would otherwise try to load `nvidia_uvm` itself, which our compute-only modprobe block would silently reject, leaving the GPU in a partial-init state that has caused delayed kernel panics. Pre-staging avoids that path entirely.

`nvidia-persistenced.service` (with our drop-in `Requires=` and `After=` the bind service) then starts and holds `/dev/nvidiactl` and `/dev/nvidia0` open for its lifetime, masking the second-open close-path bug for `nvidia-smi` and CUDA users.

## Files installed

| Path | Purpose |
|---|---|
| `/etc/udev/rules.d/79-aorus-egpu-no-autoload.rules` | Block auto-bind / auto-load of the eGPU |
| `/etc/udev/rules.d/81-aorus-egpu-compute-power.rules` | Pin TB / GPU path out of D3cold |
| `/etc/modprobe.d/aorus-egpu-compute-only.conf` | Block automatic and explicit nvidia module loads |
| `/etc/modprobe.d/blacklist-nouveau.conf` | Defence-in-depth nouveau blacklist |
| `/etc/systemd/system/aorus-egpu-compute-load-nvidia.service` | Bind the eGPU at boot, pre-load nvidia_uvm |
| `/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` | Order persistenced after the bind step |
| `/usr/local/sbin/aorus-egpu-compute-load-nvidia` | Loader implementation |
| `/usr/local/sbin/aorus-egpu-disable-audio` | HDMI audio function unbinder |
| `/usr/local/sbin/aorus-egpu-status` | Health check |

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

- `docs/architecture.md` - why each piece exists, the bugs it works around.
- `docs/recovery.md` - what to do when things go wrong.
- `docs/future-investigations.md` - upstream bug report drafts, `NVreg_DynamicPowerManagement` test plan, PyTorch/vLLM next steps.
- `tools/` - diagnostic and validation toolkit (CUDA smoke test, TTY-with-fsync test runner). Not installed by `apply.sh`; kept here as templates for future testing.
- `archive/` - historical investigation artefacts (recovery plan, ioctl tracer, freeze-test scripts) and validation evidence (`cuda-validation-2026-05-01/`).
