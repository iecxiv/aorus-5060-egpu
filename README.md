# aorus-egpu — Thunderbolt eGPU compute stack

Fork of [apnex/aorus-5090-egpu](https://github.com/apnex/aorus-5090-egpu), adapted for:

- **GPU:** NVIDIA GeForce RTX 5060 Ti 16 GB (PCI `0x10de:0x2d04`, audio `0x10de:0x22eb`)
- **Host:** Intel NUC 15 Pro+ (Thunderbolt 4)
- **OS:** Fedora 44
- **Driver:** akmod-nvidia 595.71.05

## Changes vs upstream

| File | Change |
|---|---|
| `apply.sh` | Installer user detected dynamically via `SUDO_USER`/`logname` — no hardcoded username |
| `usr/local/sbin/aorus-egpu-compute-load-nvidia` | BAR1 minimum `32 GiB → 16 GiB`; all labels `RTX 5090 → RTX 5060 Ti` |
| `usr/local/sbin/aorus-egpu-status` | Sources `common.sh` for device IDs; fallback IDs updated to 5060 Ti |
| `usr/local/lib/aorus-egpu/common.sh` | Fallback device IDs `0x2b85/0x22e8 → 0x2d04/0x22eb` |
| `reset.sh` | Fixed double `[[` syntax error on line 183; BAR1 expected size `32→16 GiB` |

## Requirements

- NVIDIA driver installed — see section below
- Kernel boot args applied — see section below
- eGPU connected **before** power-on (cold boot)
- `passim` group: add your user (`sudo usermod -aG passim $USER`) — Fedora assigns `/dev/nvidia*` to group `passim` via udev
- `ollama` group: handled automatically by `apply.sh` (requires Ollama installed first)
- **Suspend disabled** — see troubleshooting below

## NVIDIA driver installation (Fedora)

This stack requires `akmod-nvidia` from RPM Fusion. The proprietary driver is
mandatory — the open `nvidia-open` kmod is **not** used because it lacks the
persistence daemon integration needed for compute-only eGPU operation.

### 1. Enable RPM Fusion repositories

```bash
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
```

### 2. Install akmod-nvidia and CUDA

```bash
# Driver (akmod rebuilds the kernel module automatically on kernel updates)
sudo dnf install -y akmod-nvidia

# CUDA userspace libraries (required for Ollama GPU inference)
sudo dnf install -y xorg-x11-drv-nvidia-cuda

# Optional: CUDA toolkit (nvcc, headers — only if you compile CUDA code)
sudo dnf install -y cuda-toolkit
```

> **Important:** after installing `akmod-nvidia`, wait for the kernel module
> to finish building before rebooting. This can take 2–5 minutes. Check:
>
> ```bash
> sudo akmods --force && sudo dracut --force
> ```

### 3. Reboot

```bash
sudo reboot
```

### 4. Verify driver is loaded

```bash
# Module loaded
lsmod | grep nvidia

# Driver version
cat /proc/driver/nvidia/version

# nvidia-smi (eGPU must be connected)
nvidia-smi
```

Expected output from `nvidia-smi`:

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 595.71.05    Driver Version: 595.71.05    CUDA Version: 13.2               |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA GeForce RTX 5060 Ti     On  | 00000000:04:00.0   Off |                  N/A |
+-----------------------------------------------------------------------------------------+
```

If `nvidia-smi` reports `No devices were found` at this point, the eGPU is
not being enumerated — apply the kernel boot args below and reboot.

### Kernel module notes

`akmod-nvidia` rebuilds the `.ko` automatically after every kernel update via
a systemd service (`akmods.service`). If a kernel update installs before the
build finishes you may boot without the NVIDIA module. Verify any time with:

```bash
modinfo nvidia | grep ^version
```

## Kernel boot args

These args must be set before the first `apply.sh` run.

> **Critical:** use `pci=realloc` (without `=off`). Using `pci=realloc=off`
> prevents the kernel from assigning BAR0 to the GPU over Thunderbolt, causing
> `aorus-egpu-compute-load-nvidia.service` to fail at boot with:
> `RTX 5060 Ti BAR0 is unassigned; refusing to load NVIDIA.`

Without `thunderbolt.host_reset=false` the eGPU BAR1 will be limited to 256 MiB
instead of 16 GiB, causing CUDA to fail.

```bash
sudo grubby --update-kernel=ALL --args="\
  thunderbolt.host_reset=false \
  pci=realloc \
  pcie_bus_perf \
  hpmmioprefsize=128M \
  resource_alignment=34@0000:04:00.0 \
  module_blacklist=nouveau \
  rd.driver.blacklist=nouveau \
  modprobe.blacklist=nouveau \
  iommu=pt \
  pcie_aspm.policy=performance \
  thunderbolt.clx=0 \
  pcie_port_pm=off"
```

Then reboot:

```bash
sudo reboot
```

### Arg reference

| Arg | Purpose |
|---|---|
| `thunderbolt.host_reset=false` | Prevents the TB controller from resetting the tunnel on hotplug events; required for stable BAR1 |
| `pci=realloc` | Lets the kernel reassign PCIe BARs that the BIOS left unmapped — **required** for BAR0 allocation on this eGPU over Thunderbolt |
| `pcie_bus_perf` | Sets PCIe bus to performance MPS/MRRS |
| `hpmmioprefsize=128M` | Reserves prefetchable MMIO space for hotplug bridges |
| `resource_alignment=34@0000:04:00.0` | Forces 16 GiB BAR1 alignment on the GPU (2^34 = 16 GiB) |
| `module_blacklist=nouveau` / `rd.driver.blacklist=nouveau` / `modprobe.blacklist=nouveau` | Prevents the nouveau driver from claiming the GPU at initrd, early boot, and runtime |
| `iommu=pt` | IOMMU passthrough — reduces DMA translation overhead for CUDA workloads |
| `pcie_aspm.policy=performance` | Disables Active State Power Management on PCIe — prevents link retraining that freezes the TB tunnel |
| `thunderbolt.clx=0` | Disables Thunderbolt CL states — prevents TB controller from entering low-power states mid-transfer |
| `pcie_port_pm=off` | Disables PCIe port power management — stabilises the bridge during sustained CUDA loads |

### Apply boot args on Fedora (UEFI)

`grubby` is the preferred method on Fedora and handles both BIOS and UEFI
automatically. If you edit `/etc/default/grub` manually, regenerate with:

```bash
# Do NOT write to /boot/efi/EFI/fedora/grub.cfg directly — it is a wrapper
sudo grub2-mkconfig -o /etc/grub2-efi.cfg   # UEFI
sudo grub2-mkconfig -o /boot/grub2/grub.cfg  # BIOS (optional)
```

### Verify args are active after reboot

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E 'thunderbolt|pci|iommu|nouveau|aspm'
```

Expected: `pci=realloc` present, `pci=realloc=off` **absent**.

### Verify BAR1 is 16 GiB

```bash
nvidia-smi --query-gpu=bar1_memory.total --format=csv,noheader
# Expected: 16384 MiB
# If you see 256 MiB — boot args are not applied or not active
```

## Quick start

```bash
git clone https://github.com/iecxiv/aorus-5060-egpu.git
cd aorus-5060-egpu
# 1. Install NVIDIA driver (see above) and reboot
# 2. Apply boot args (see above) and reboot
# 3. Run installer
sudo ./apply.sh
sudo aorus-egpu-status
nvidia-smi
```

`apply.sh` automatically detects the invoking user via `SUDO_USER` and adds
them to the `ollama` group. To override:

```bash
sudo INSTALL_USER=otherusername ./apply.sh
```

> **Note:** `apply.sh` will print `usermod: group 'ollama' does not exist` on a
> clean install where Ollama has not been installed yet. This is harmless — install
> Ollama afterwards and re-run `apply.sh`, or add the user manually:
> `sudo usermod -aG ollama $USER`

## Verify GPU in Ollama

```bash
# Terminal 1
ollama run llama3.2 "hola"

# Terminal 2 — while model generates
watch -n 1 nvidia-smi
# Expect: Memory-Usage > 0MiB, library=cuda in journalctl
```

## Troubleshooting

### `aorus-egpu-compute-load-nvidia.service` fails: BAR0 is unassigned

Symptom at boot:
```
RTX 5060 Ti BAR0 is unassigned; refusing to load NVIDIA.
Cold boot with the eGPU connected so pci=realloc can allocate BAR0.
```

This means the kernel has not allocated the PCIe BAR0 resource for the GPU.
Root cause is usually one of:

1. **`pci=realloc=off` present in kernel args** — this explicitly disables
   reallocation. Remove it; only `pci=realloc` (without `=off`) should be set.
2. **`pci=realloc` missing entirely** — add it as shown in the boot args section.
3. **eGPU not connected before power-on** — connect the AORUS before pressing
   the power button (cold boot), not after the OS has started.

Verify the fix:
```bash
# Should show pci=realloc and NOT pci=realloc=off
cat /proc/cmdline | grep realloc

# Service should be active (exited) with status=0
sudo systemctl status aorus-egpu-compute-load-nvidia.service
```

### `nvidia-smi: Insufficient Permissions`

Add user to `passim` group:
```bash
sudo usermod -aG passim $USER
newgrp passim
```

### `GPU: not present` after reboot

Run recovery:
```bash
sudo ./reset.sh --auto
```

### Ollama uses CPU instead of CUDA

`ollama` user needs `passim` group:
```bash
sudo usermod -aG passim ollama
sudo systemctl restart ollama
sudo journalctl -u ollama -n 10 --no-pager | grep library
```

### BAR1 = 256 MiB instead of 16 GiB

Boot args not active. Verify:
```bash
cat /proc/cmdline | grep thunderbolt.host_reset
```
If missing, re-apply the boot args from the section above and reboot.

### `nvidia-smi: No devices were found` after suspend/resume

The Thunderbolt tunnel breaks on suspend and the NVIDIA driver cannot re-probe
the device. Recovery without reboot is not reliable on this hardware.
Full recovery procedure:

1. Disconnect the eGPU from the Thunderbolt port
2. Reboot the host
3. Reconnect the eGPU **before** or immediately after power-on
4. Run `sudo ./apply.sh` if the stack services did not start automatically
5. Verify with `nvidia-smi`

Root cause: the Thunderbolt PCIe bridge (`0000:03:00.0`) cannot be reset
post-resume, preventing re-enumeration of the downstream GPU (`0000:04:00.0`).
After resume, `modprobe nvidia` fails with `No such device` because
`/sys/bus/pci/devices/0000:03:00.0/reset` is not writable in this state.

**Recommended: disable suspend permanently** while the eGPU is in use:
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

To re-enable (e.g. when using the machine without the eGPU):
```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
```
