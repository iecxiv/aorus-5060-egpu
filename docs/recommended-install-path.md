# Recommended install path

The clean / minimal / happy-path configuration for running an AORUS GeForce
RTX 5090 AI Box (GB202, Blackwell) over Thunderbolt 4 on a Fedora 43 host
as a CUDA-only inference accelerator.

This document is **the canonical "if you were starting over" recipe**.
It is not the literal sequence of operations executed on this host (that
sequence is captured in git history); rather, it is the cleaned-up
procedure to follow next time on a new host.

> **Status update 2026-05-08.** The freeze bug class is now **empirically
> mitigated** on this stack via the cumulative effect of:
> - Lever T cmdline `iommu=off intel_iommu=off`
> - 30-patch driver series (Lever I/J-2/N/O/Q/M-base/M-recover) built via
>   `tools/build-patched-driver.sh`
> - H9a fix (retired the `aorus-egpu-pcie-tune.service` that was actively
>   harming Port A boots)
>
> See [`reliability-hypothesis-ledger.md` H22](./reliability-hypothesis-ledger.md#h22)
> and [`lever-catalog.md`](./lever-catalog.md) for current state.
> Three userspace workaround services have retired this week
> (link-monitor, pcie-tune, uvm-keepalive); a fourth (wpr2-recovery)
> is in Phase 5 evidence-collection and pending retirement.

## Prerequisites

- AORUS RTX 5090 AI Box (GB202)
- ASUS NUC 15 Pro+ or similar Intel Core Ultra Thunderbolt 4 host
- Fedora 43 Workstation (only documented Fedora release in NVIDIA's
  Tesla driver guide as of writing)
- btrfs root subvolume layout (for snapshot rollback)
- iGPU drives display (NUC 15 has Intel Arc); no plan to use eGPU as
  display device

## Layer 1 - BIOS settings

Set in BIOS before anything else:

| Setting | Value | Why |
|---|---|---|
| Onboard Devices > Thunderbolt Support | Enabled | obvious |
| Power > Dynamic PL1 Support | Enabled | thermal headroom for sustained loads |
| Power > Dynamic PL4 Support | Enabled | as above |
| Power > ErP Ready | Disabled | leaves PCIe BARs allocated across power states |
| Power > PCIe ASPM Support | **Disabled** | load-bearing for eGPU stability; eliminates known PCIe link-state bugs over Thunderbolt |
| Power > Native ACPI OS PCIe Support | Enabled | required for iGPU initialisation |
| Power > USB S4/S5 Power | Enabled | keeps Thunderbolt alive across some power states |
| Power > Power Sense | Enabled | thermal sensor enable |

If the host has a "VT-d" / "IOMMU" BIOS option, enable it. The NUC 15
auto-enables IOMMU via ACPI DMAR tables and exposes no manual switch;
verify with `ls /sys/class/iommu/` after first boot (should show `dmar0`
and `dmar1`).

## Layer 2 - kernel command-line arguments

```
pci=realloc=off,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0
thunderbolt.host_reset=false
iommu=off
intel_iommu=off
module_blacklist=nouveau,nova_core
rd.driver.blacklist=nouveau,nova_core
modprobe.blacklist=nouveau,nova_core
pcie_aspm.policy=performance
thunderbolt.clx=0
pcie_port_pm=off
```

**Updated 2026-05-08:** the `iommu=off intel_iommu=off` pair (Lever T) is
empirically required — `iommu=pt` does NOT work for TB-tunneled devices
because TB devices are marked "untrusted" by kernel security policy and
still go through IOMMU translation regardless of the cmdline pt setting.
The full hypothesis chain is documented in [`iommu-gsp-lockdown-analysis.md`](./iommu-gsp-lockdown-analysis.md).

Apply with both:
```bash
sudo grubby --update-kernel=ALL --args="..."          # current bootloader entries
echo "...full line..." | sudo tee /etc/kernel/cmdline # template for future kernels
```

Why each is needed: see `etc/kernel/cmdline.txt` in this repo for the
full annotated rationale (BAR1 32 GiB allocation, Thunderbolt
authorisation behaviour, IOMMU passthrough mode, defence-in-depth
nouveau blacklist).

## Layer 3 - cold boot rules

The eGPU's PCI BAR1 is allocated by firmware at first power-on. After
`thunderbolt.host_reset=false` is in effect, BAR1 stays at 32 GiB
across Thunderbolt re-authorisation, but **only** if the eGPU was
present when the NUC powered on.

**Boot sequence:**

1. AORUS AI Box rear power switch ON
2. Thunderbolt cable connected
3. NUC powers on
4. (firmware enumerates PCI; eGPU BAR1 = 32 GiB)
5. (kernel boots; Thunderbolt re-auths but does not reset host router)
6. (loader binds NVIDIA driver to the GPU)

If the eGPU is connected to a NUC that is already powered on (hot-plug),
BAR1 may collapse to 256 MiB and the driver will refuse to bind. Cold
boot is mandatory after any disconnect.

## Layer 3 - NVIDIA driver install (compute-only, open kernel module)

This is the step where most setups go wrong. **Do NOT use
`nvidia-driver-assistant --install`** - that tool only knows the
desktop meta-packages (`nvidia-open` or `cuda-drivers`), which pull in
X drivers, Vulkan/EGL/OpenCL ICDs, libnvidia-fbc, libnvidia-libXNVCtrl,
and `nvidia-settings`. Then you spend hours undoing the desktop layer
(disable ICDs, mask switcheroo-control, mask nvidia-cdi-refresh, etc.)
to reach compute-only state.

**Use the explicit compute-only command from NVIDIA's Fedora install
guide instead:**

```bash
# Add NVIDIA's CUDA repo
sudo dnf config-manager addrepo \
    --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora43/x86_64/cuda-fedora43.repo
sudo dnf clean expire-cache

# Prerequisites
sudo dnf install kernel-devel-matched kernel-headers

# THE INSTALL — compute-only, open kernel module
sudo dnf install nvidia-driver-cuda kmod-nvidia-open-dkms
```

Per NVIDIA's compute-only-and-desktop-installation page, this excludes
"GL, EGL, Vulkan, X drivers, and so on." The dependency closure should
include:

- `kmod-nvidia-open-dkms` - kernel module sources, DKMS-built per kernel
- `nvidia-kmod-common` - shared kmod scriptlets, GSP firmware
- `nvidia-driver-cuda` - CUDA runtime tools
- `nvidia-driver-cuda-libs` - libcuda, libnvidia-ml
- `nvidia-driver-libs` - core driver libs
- `libnvidia-cfg` - configuration library
- `libnvidia-gpucomp` - compute helper
- `nvidia-modprobe` - setuid helper for /dev/nvidia* node creation
- `nvidia-persistenced` - persistence daemon

The compute-only path does **not** include:

- `xorg-x11-drv-nvidia*` (X11 / Wayland driver bundle)
- `nvidia-settings` (GUI settings tool)
- `nvidia-libXNVCtrl` (X11 NV-CONTROL extension)
- `libnvidia-fbc` (Frame Buffer Capture lib)
- `nvidia-container-toolkit*` (separate optional install if you want
  containers)
- `nvidia-driver` (the desktop META-package; brings in the above)
- `nvidia-driver-assistant` (the helper script, only useful at install
  time)
- The systemd units that ship via `nvidia-driver`:
  `nvidia-hibernate.service`, `nvidia-resume.service`,
  `nvidia-suspend.service`, `nvidia-suspend-then-hibernate.service`,
  `nvidia-powerd.service`

The compute-only path **does** include (despite the "compute-only" name):

- The Vulkan ICD JSON (`/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json`)
- The Vulkan implicit-layer JSON (`/usr/share/vulkan/implicit_layer.d/nvidia_layers.json`)
- The EGL vendor JSON (`/usr/share/glvnd/egl_vendor.d/10_nvidia.json`)
- The OpenCL ICD (`/etc/OpenCL/vendors/nvidia.icd`)

These are bundled into `nvidia-driver-libs` (Vulkan + EGL) and
`nvidia-driver-cuda` (OpenCL), both of which are required for compute.
NVIDIA's package layout puts the ICD JSONs alongside the core libraries
rather than in a separate "graphics" package.

So the **disable-via-rename approach in
`/etc/modprobe.d/nvidia.conf` and `apply.sh`'s `disable_loader_entry`
function remains load-bearing on the compute-only install too.** Without
the rename, GNOME / mutter / any Vulkan-using app would still find the
NVIDIA Vulkan ICD and dlopen `libGLX_nvidia.so` on the eGPU.

If those packages are absent, the corresponding workarounds in this
repo (rename ICDs to `.aorus-disabled`, mask `switcheroo-control`,
shadow `/usr/lib/modprobe.d/nvidia.conf` to remove `nvidia-drm`
softdep) become **inert** rather than load-bearing - they no-op
gracefully.

### What still needs reactive hardening even on compute-only

`/usr/lib/modprobe.d/nvidia.conf` is owned by `nvidia-kmod-common`,
which IS pulled in even on the compute-only path. That file ships with:

```
softdep nvidia post: nvidia-uvm nvidia-drm
options nvidia NVreg_EnableS0ixPowerManagement=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
```

The softdep auto-loads `nvidia-drm` whenever `nvidia` loads. On a
truly compute-only system there is no `nvidia-drm.ko` (the open-dkms
package only builds nvidia.ko + nvidia-uvm.ko, not nvidia-drm.ko -
verify on a fresh install) so the softdep may resolve to a no-op
naturally. If `nvidia-drm.ko` IS present, GNOME mutter will pick up
the resulting `/dev/dri/cardN` and freeze on login.

Defence: shadow with `/etc/modprobe.d/nvidia.conf` (this repo ships
one). The shadow removes the softdep and flips the two NVreg defaults
to compute-only-friendly values.

## Layer 3 - platform-specific kernel-module bind sequence

The eGPU's PCI device must be bound to the nvidia driver explicitly,
not by udev modalias autoload. This is hardware-specific to this
chassis-over-Thunderbolt setup. Components:

- `etc/udev/rules.d/79-aorus-egpu-no-autoload.rules` -
  `driver_override=aorus_5090_manual` so PCI does not auto-bind
- `etc/udev/rules.d/81-aorus-egpu-compute-power.rules` -
  `power/control=on`, `d3cold_allowed=0` along the eGPU's PCI path
- `etc/udev/rules.d/82-aorus-egpu-nvidia-permissions.rules` -
  `/dev/nvidia*` to `0660 root:ollama` (defence in depth alongside
  NVreg_DeviceFile* options)
- `etc/systemd/system/aorus-egpu-compute-load-nvidia.service` +
  `usr/local/sbin/aorus-egpu-compute-load-nvidia` -
  validates BAR0/BAR1, modprobes nvidia + nvidia_uvm with
  `--ignore-install`, runs `nvidia-modprobe -u -c 0` to materialise
  /dev/nvidia-uvm-tools, chmod/chgrp for user/group convergence

## Layer 3 - close-path bug workarounds (load-bearing, not optional)

Two services that hold device-file fds permanently to prevent the
close-side teardown bug from firing on `/dev/nvidia0` and
`/dev/nvidia-uvm`:

- `nvidia-persistenced.service` (vendor-shipped, our drop-in adds
  `Requires=` + `Restart=no`)
- `aorus-egpu-uvm-keepalive.service` (this repo, holds /dev/nvidia-uvm
  + /dev/nvidia-uvm-tools open via `exec sleep infinity`)

Both **must** be members of the `ollama` group so they can open the
0660 root:ollama device files:

```
sudo usermod -aG ollama nvidia-persistenced
sudo usermod -aG ollama apnex   # for unprivileged nvidia-smi
```

The nvidia-persistenced membership is the empirical fix for a freeze
class we hit on F43+595: the daemon now runs as a dedicated user
(not root, unlike F42's RPMFusion build), and without group access
to /dev/nvidia0 it fails to start, leaving /dev/nvidia0 unprotected.

## Layer 3 - NVreg module options

`etc/modprobe.d/aorus-egpu-compute-only.conf` contains the NVreg tuning:

```
options nvidia NVreg_DeviceFileMode=0660
options nvidia NVreg_DeviceFileUID=0
options nvidia NVreg_DeviceFileGID=968        # ollama group GID
options nvidia NVreg_DynamicPowerManagement=0x00
options nvidia NVreg_PreserveVideoMemoryAllocations=0
options nvidia NVreg_EnableS0ixPowerManagement=0
options nvidia NVreg_RestrictProfilingToAdminUsers=1
```

Why each: see the conf file's inline comments. NVreg_DeviceFile*
makes /dev/nvidia0 + nvidiactl come up at 0660 root:ollama from the
moment nvidia-modprobe (called by nvidia-smi) creates them, so they
are not reset to 0666 root:root after every NVML invocation.
Power-management options drop suspend/resume and S0ix code paths a
headless compute box never exercises.

## Layer 3 - blacklist nouveau / install /bin/false

`etc/modprobe.d/aorus-egpu-compute-only.conf` also defines:

```
blacklist nvidia
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidia_drm
options nvidia_drm modeset=0 fbdev=0
install nvidia /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
install nvidia_drm /bin/false
```

Belt-and-suspenders: blocks udev-triggered autoload via blacklist
(catches modalias autoload) AND turns explicit `modprobe nvidia*`
calls (e.g. by package scriptlets) into no-ops via the install lines.
The loader bypasses the install lines with `modprobe --ignore-install`.

## Layer 4 - LLM substrate

ollama and vLLM still trigger the freeze bug as of driver 595.71.05 +
F43 + open kernel module + all hardening above. **This is the active
unsolved bug.** See `architecture.md` Problem 5 (close-path on UVM)
and `future-investigations.md` section 9 (GitHub investigation).

The recommended posture until upstream fixes it:
- Do not auto-start ollama at boot (`systemctl disable ollama`)
- Do not run sustained CUDA workloads on this combination
- File evidence with NVIDIA via the open-gpu-kernel-modules GitHub
  issue tracker (see future-investigations.md section 9)

When the bug is fixed, this layer becomes trivial:

```
curl -fsSL https://ollama.com/install.sh | sh
# our /etc/systemd/system/ollama.service.d/aorus-egpu.conf drop-in
# already wires Requires=/After= for the loader chain
```

## Validation: status.sh should report green

`/root/aorus-5090-egpu/status.sh` walks every layer of the above and
reports OK / WARN / FAIL per check. On a healthy compute-only F43 +
595 install with this repo applied, expect:

- 70+ OK
- A handful of WARNs (UVM/caps perms reset by nvidia-modprobe;
  documented limitation)
- 0 FAIL

If status.sh shows FAILs, reconcile each before considering the
install correct.

## What this path explicitly does NOT cover

- **Recovering the freeze bug** - that's an upstream issue.
- **Hot-plugging the eGPU** - cold boot is required.
- **Multi-GPU configurations** - one Blackwell card only.
- **VFIO / passthrough into VMs** - documented as a future
  investigation, not implemented.
- **Suspend/resume** - PreserveVideoMemoryAllocations=0 means we
  explicitly opt out of suspend support.
- **GNOME / Wayland integration as a display GPU** - we are
  compute-only by design; the eGPU never drives a display.
