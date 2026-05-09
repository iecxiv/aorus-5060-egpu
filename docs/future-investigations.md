# Future investigations

> **Status: HISTORICAL (2026-05-08).** This document is a historical
> archive of bug filings (Bugs A/B/C/D) and investigation handoffs from
> the 2026-05-01 → 2026-05-03 era. The CUDA-workload host freeze
> documented herein has **converged** — see
> [H22 ledger entry](./reliability-hypothesis-ledger.md#h22) for the
> current state. Specific recommendations below (e.g., DPM=0 in section 1)
> are now either redundant or already deployed (DPM=0 is set via
> `etc/modprobe.d/aorus-egpu-compute-only.conf` and has been since
> early in the project). Preserved for archive value; current state
> lives in [`architecture.md`](./architecture.md), [`lever-catalog.md`](./lever-catalog.md),
> [`service-retirement-roadmap.md`](./service-retirement-roadmap.md).

> **Note (2026-05-03):** the active investigation into the CUDA-workload host
> freeze has moved to `freeze-investigation-plan.md`. That doc has the
> Lever A–G framework, the decision tree pivoting on the WSL2 gate (Lever G),
> evidence catalogue from upstream issue #979, and the recommended working
> order for the next session. Read that first if you're picking up the
> investigation.
>
> This doc still contains the historical Bug A/B/C/D filing-quality material
> from earlier in the project; some of it is now superseded by the broader
> bug-class characterization (the close-path bug on `/dev/nvidia0` and the
> CUDA-write-op freeze appear to be different surface symptoms of the same
> upstream Blackwell × Thunderbolt × open-module class). Sections below are
> kept as-is for reference but not actively maintained.

---

The current configuration works but masks rather than fixes two real bugs. This document captures the open threads that could remove the workaround dependencies or feed upstream fixes. None of these is required for the system to operate.

## What's been validated

- `nvidia-smi` repeats safely with persistenced holding `/dev/nvidia0` open.
- CUDA Driver API smoke (full `cuInit -> cuMemAlloc -> cuMemcpyDtoH -> verify`) passes end-to-end with no leak. See `archive/cuda-validation-2026-05-01/`.
- Loader pre-stages `nvidia_uvm` so `cuInit` never fails on modprobe.
- Driver-managed thermal control active.

## What's NOT yet validated

- PyTorch tensor operations on CUDA. (Next step toward vLLM.)
- vLLM model load + inference.
- Long-running CUDA workloads that may exercise close paths we haven't seen.
- Sustained high-power compute (heat behaviour).
- Suspend / resume cycles with the eGPU connected.

## 1. NVreg_DynamicPowerManagement=0 test

**Hypothesis:** even with D3cold blocked at the udev level, the NVIDIA driver's runtime PM path may still drive close-side teardown that wedges the next open of `/dev/nvidia0`. Setting `NVreg_DynamicPowerManagement=0` (current default on this stack: `3`, fine-grained PCIe-level PM) would disable that path entirely.

**Independent confirmation:** A second-opinion AI (Gemini, 2026-05-01) independently recommended this parameter. Its proposed mechanism (D3cold-on-idle wake failure) does not fit our evidence, but the parameter itself is a reasonable thing to test.

**Best case if it works:** persistenced stops being load-bearing. The system would survive `nvidia-smi` invocations even without persistenced running, removing a single point of failure.

**Worst case:** another freeze, no information gained beyond ruling out PM-on-close as the trigger.

**How to run safely:**

1. Cold boot to a clean state with the current configuration and the eGPU connected.
2. Stop persistenced cleanly: `sudo systemctl stop nvidia-persistenced.service`.
3. Unload `nvidia`: `sudo modprobe -r nvidia`. (Note: per the recovery plan, this can wedge after NVML use. Reboot first if NVML has been called this session.)
4. Bind with the variable:

   ```bash
   sudo /usr/local/sbin/aorus-egpu-compute-load-nvidia
   # The loader does not currently expose this env var; either:
   #   a) edit the loader to accept AORUS_5090_DISABLE_DYNAMIC_PM=1
   #      and pass NVreg_DynamicPowerManagement=0 to modprobe; or
   #   b) bind once with the script, immediately unload, then manually
   #      modprobe nvidia NVreg_DynamicPowerManagement=0
   ```

5. Without persistenced running, run `nvidia-smi` twice in succession.
6. If both succeed: the parameter is the fix. Persist by adding the option to `/etc/modprobe.d/aorus-egpu-compute-only.conf` (alongside the existing options). The compute-load loader can then drop persistenced from the requirement chain.
7. If the second `nvidia-smi` freezes: revert. Persistence-mode remains the only known mitigation.

The loader script already has `AORUS_5090_DISABLE_NONBLOCKING_OPEN` and `AORUS_5090_DISABLE_GSP` env-var hooks; adding `AORUS_5090_DISABLE_DYNAMIC_PM` is a few lines.

## 2. Upstream NVIDIA bug reports

There are now **two** distinct bugs to file, both well-characterised. Either can be filed independently; both are user-side reproducible without further freezes on this hardware.

### Bug A: Kernel hangs in `open()` of `/dev/nvidia0` on second open

**Repository:** https://github.com/NVIDIA/open-gpu-kernel-modules

**Title (suggested):** Kernel hangs in `open()` of `/dev/nvidia0` on second open after a previous open+close, RTX 5090 over Thunderbolt 4, kernel module 580.142

**Body outline:**

- Hardware: NUC 15 Pro+ (Intel TB4 host, JHL9480 retimer), AORUS GeForce RTX 5090 AI Box.
- Software: Fedora 42, kernel 6.19.14-100.fc42.x86_64, RPM Fusion `akmod-nvidia` 580.142 (loads as `NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64 580.142`).
- Reproducer: with `thunderbolt.host_reset=false`, BAR1 stable at 32 GiB, GPU bound to `nvidia`, no other NVIDIA modules loaded:

  ```bash
  python3 -c "import ctypes; n=ctypes.CDLL('libnvidia-ml.so.1'); n.nvmlInit_v2(); n.nvmlShutdown()"
  python3 -c "import ctypes; n=ctypes.CDLL('libnvidia-ml.so.1'); n.nvmlInit_v2()"   # <-- freezes
  ```

  First call returns rc=0 (init+shutdown both succeed). Second call hangs the host inside the kernel `open()` syscall on `/dev/nvidia0`. Forced reboot required.

- Boundary: ioctl trace shows no matching `open64_exit` for `/dev/nvidia0 flags=0x80802 (O_RDWR|O_NONBLOCK|O_CLOEXEC)`.
- Setting `NVreg_EnableNonblockingOpen=0` does not fix; it only relocates the hang from `NV_ESC_WAIT_OPEN_COMPLETE` ioctl into `open()` itself.
- The hang persists across `modprobe -r nvidia ; modprobe nvidia` - so the wedge state survives kernel module unload, suggesting GPU/GSP firmware state or an undocumented per-PCI-device structure.
- Workaround: keep `/dev/nvidia0` open via `nvidia-persistenced` so no "last close" ever runs.

**Attachments to include:**

- `archive/recovery-plan.md`
- `archive/next-diagnostic.md`
- `archive/diagnostic-tests/` (the ioctl tracer source, the test scripts, and the captured progress / ioctl logs from the 2026-05-01 freeze).
- A clean reproducer in 5-10 lines of C or Python.

This bug report does not require any further freeze tests on the user's hardware. All the data already exists.

### Bug B: Failed `cuInit` causes delayed kernel panic

A separate bug, also reproducible without further freezes (we have the kernel log truncation evidence already).

**Title (suggested):** Failed `cuInit()` leaves GPU in panic-prone state when `nvidia_uvm` modprobe is blocked; delayed kernel hard-lock on RTX 5090 over Thunderbolt 4

**Body outline:**

- Hardware / kernel / driver: as Bug A.
- Setup: GPU bound to `nvidia`, `nvidia_uvm` deliberately not loaded, `install nvidia_uvm /bin/false` in modprobe config to simulate a missing-uvm condition.
- Reproducer:

  ```bash
  python3 -c "import ctypes; cuda=ctypes.CDLL('libcuda.so.1'); print('cuInit', cuda.cuInit(0))"
  # prints cuInit 999 (CUDA_ERROR_UNKNOWN)
  # check: nvidia-smi --query-gpu=memory.used --format=csv,noheader
  # observed 1 MiB allocated and never freed
  # wait several minutes -> kernel hard-lock, no flushed logs, forced reboot required
  ```

- Expected behaviour: `cuInit` returns `CUDA_ERROR_NOT_INITIALIZED` or similar specific error AND fully unwinds any partial state.
- Actual behaviour: `cuInit` returns generic `CUDA_ERROR_UNKNOWN` (999), 1 MiB stays allocated, and the host kernel-panics minutes later with no flushed log entries.
- Workaround: pre-load `nvidia_uvm` (e.g. via `modprobe --ignore-install nvidia_uvm`) before any CUDA program runs, so `cuInit` never has to invoke modprobe.

This bug is filed against the same repo and is potentially related to Bug A in that both involve poorly-handled error paths in driver init/teardown on this platform.

### Bug C: NCCL communicator init takes the GPU off the bus on Blackwell over Thunderbolt

Identified during vLLM 0.20.0 bring-up attempts (2026-05-01). Reproducer requires vLLM but the trigger is at the PyTorch / NCCL layer.

**Title (suggested):** `torch.distributed.init_process_group(backend='nccl', world_size=1)` causes `NV_ERR_GPU_IS_LOST` and host hard-lock on RTX 5090 over Thunderbolt 4 with open kernel module 580.142

**Body outline:**

- Hardware / kernel / driver: as Bug A.
- Reproducer (any vLLM 0.20.0 invocation, but minimal:

  ```python
  # in /root/vllm-venv with vllm 0.20.0 and torch 2.11.0+cu130 installed
  import os
  os.environ['MASTER_ADDR']='127.0.0.1'
  os.environ['MASTER_PORT']='29500'
  import torch.distributed as dist
  dist.init_process_group(backend='nccl', init_method='env://',
                          world_size=1, rank=0)
  # host hard-locks within ~1 second of this call
  ```

- Kernel log captured before the freeze:

  ```
  NVRM: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F)
  NVRM: rpcSendMessage failed (multiple, sequences 1310-1318, fn 78)
  NVRM: rpcRmApiFree_GSP: GspRmFree failed
  pcieport 0000:00:07.0: AER: Multiple Uncorrectable (Non-Fatal) error
    message received from 0000:04:00.0
  ```

- `NCCL_P2P_DISABLE=1`, `NCCL_SHM_DISABLE=1`, and vLLM's `--disable-custom-all-reduce` do NOT prevent the freeze; the trigger is in the basic NCCL communicator init, not in P2P probing or shared-memory transport.
- Workaround: pre-initialize `torch.distributed` with the `gloo` (CPU) backend before vLLM gets to call `init_process_group`. vLLM checks `torch.distributed.is_initialized()` and skips its own init when one already exists. At `world_size=1` no actual collective ops execute. See `/root/vllm/tools/vllm-gloo-preinit.py` for a working wrapper.
- This workaround gets past the NCCL-init freeze and into vLLM model loading (model successfully placed in VRAM), but a *second* freeze hits later in vLLM's profile run / first-kernel JIT phase. The second freeze is presumed to be the same `sm_120` Triton-JIT-over-TB pattern that `CUDA_MODULE_LOADING=EAGER` partially mitigates in other contexts (where it instead causes an indefinite CPU spin in EngineCore init).

**Attachments:**

- `/root/vllm/archive/vllm-attempts-2026-05-01/` — captured logs from each freeze configuration including the gloo-preinit run that successfully bypassed the NCCL freeze.
- `/root/vllm/tools/vllm-gloo-preinit.py` — a 30-line reproducer of the workaround.

## 3. Try kernel 6.20+ when available

Recent (2025-2026) Linux kernel work on Thunderbolt power management and PCIe authorization is ongoing. The same bug may have been fixed upstream after 6.19. If a newer kernel becomes available on Fedora 42 (or after a Fedora 43 upgrade), retest:

1. Install the new kernel.
2. Without changing anything else, reboot and run two `nvidia-smi` invocations without persistenced running.
3. If both succeed, the persistenced workaround can be relaxed (or kept as belt-and-suspenders).

## 4. Switcheroo / DRM exposure regression watch

Major Mesa / Wayland / GDM updates have, in the past, changed how `switcheroo-control` discovers GPUs. The current configuration depends on the eGPU not being exposed as a DRM device. After major Fedora updates, verify:

```bash
ls /sys/class/drm/card*
# Expected: card1: i915 only
```

If an NVIDIA DRM card appears, GNOME may still freeze on login. Re-check that `aorus-egpu-compute-only.conf` is in place and effective.

## 5. CUDA workload close-path stress

We have validated `nvidia-smi` (NVML) repeatability AND a one-shot CUDA Driver API smoke (`archive/cuda-validation-2026-05-01/`), but not long-running CUDA workloads. A real vLLM or PyTorch run that hot-loads / unloads models may exercise a different close path. If you observe freezes during normal CUDA use, capture an ioctl trace of the workload using `archive/diagnostic-tests/aorus-egpu-nvml-ioctl-trace.so` to identify the close boundary.

## 6. PyTorch tensor-op smoke (next planned step)

The path from "CUDA Driver API works" to "vLLM works" goes through PyTorch's CUDA backend. Suggested incremental tests:

1. `python -m venv /root/torch-test && pip install torch` (downloads ~3 GB).
2. Test: `torch.cuda.is_available()`, `torch.zeros(1024, 1024, device='cuda')`, `torch.mm(a, b)`. Validates cuBLAS GEMM and basic tensor allocation.
3. Same TTY-with-fsync methodology as `tools/tty-cuda-test.sh` so we have forensic data if anything goes wrong. Adapt the runner to also dump `torch.cuda.memory_allocated()` and `torch.cuda.memory_reserved()` post-test.

Risk profile: similar to the CUDA Driver API smoke we just validated, possibly slightly higher because PyTorch loads more libraries. With `nvidia_uvm` pre-staged, the catastrophic failed-`cuInit` path is closed.

## 7. vLLM bring-up

After PyTorch is validated, the natural target. vLLM-specific concerns to be aware of:

- vLLM officially supports Python 3.9-3.12; the system Python is 3.13. May need a separate Python install or `pyenv`.
- vLLM does its own CUDA context management; whether its hot-load/unload model patterns trigger the close-path bug is an open question.
- A first vLLM test should load a tiny model (e.g. TinyLlama-1.1B or similar) before attempting anything large.
- Watch for `torch.cuda.empty_cache()` calls in particular - those may close+reopen device files in patterns we have not characterised.

## 8. Pivot to NVIDIA's official "compute-only" install on Fedora 43

**Discovered 2026-05-02 via NVIDIA's driver installation guide:**

- Root: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/latest/
- https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/compute-only-and-desktop-installation.html
- https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/driver-assistant.html
- https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/advanced-options.html

NVIDIA documents a first-class **compute-only installation mode** since driver
560+. It includes the CUDA runtime + GPU compute drivers and excludes the
desktop layer (X/Wayland, Vulkan/EGL/OpenCL/libGL ICDs, display power
management). The `nvidia-driver-assistant` tool wraps the install and
supports both kernel-module flavours:

```
nvidia-driver-assistant --install --module-flavor open      # OpenRM
nvidia-driver-assistant --install --module-flavor closed    # Closed RM
```

**This is exactly the configuration we have been building by hand from a
desktop install.** A meaningful chunk of the platform repo's Layer-2 / Layer-3
hardening was reactive — disable Vulkan ICD, EGL vendor, OpenCL ICD, mask
switcheroo-control, mask nvidia-cdi-refresh.path - all aimed at undoing
desktop-install side effects that compute-only mode never installs in the
first place.

### Supported distros and our gap

The compute-only mode supports: Amazon Linux 2023, RHEL 8-10, **Fedora 43**,
openSUSE 15-16, Debian 12-13, Ubuntu 22.04 / 24.04. Notably **NOT Fedora 42**,
which is what this host runs. Two paths forward:

- **Upgrade to Fedora 43, then install via compute-only mode (recommended).**
  Aligns with vendor-supported config; removes the bulk of our reactive
  hardening; gets us the canonical happy path the platform docs describe.
- **Stay on Fedora 42 with the NVIDIA CUDA repo.** Probably works (the
  packages are RHEL-style RPMs) but unsupported. Useful only as a quick
  closed-RM A/B if upgrade cost matters more than vendor support.

### What stays vs goes after the migration

**Stays - genuine hardware/platform fixes:**

- Boot args (`pci=realloc...`, `thunderbolt.host_reset=false`, `iommu=pt`,
  nouveau blacklisting). Layer 2, hardware-specific.
- Loader script (`aorus-egpu-compute-load-nvidia`). Binds the GPU explicitly
  through the manual override and pre-stages `nvidia_uvm`. Hardware-specific.
- udev rules for power state pinning (`81-aorus-egpu-compute-power.rules`)
  and driver_override (`79-aorus-egpu-no-autoload.rules`). Layer 1/2.
- `nvidia-persistenced` drop-in (Restart=no, depends on loader). Workaround
  for the close-path bug.
- `aorus-egpu-uvm-keepalive.service`. Same workaround for /dev/nvidia-uvm.
- NVreg options in modprobe.d (DeviceFile{UID,GID,Mode}, DynamicPowerManagement,
  PreserveVideoMemoryAllocations, S0ix, RestrictProfilingToAdminUsers).
  Driver-tuning, applies regardless of install path.
- `nvidia-power-management.conf` shadow override.

**Goes - reactive cleanup that compute-only mode handles natively:**

- Layer 2 ICD disable (Vulkan/EGL/OpenCL aorus-disabled renames). The
  compute-only install never installs these, so there is nothing to disable.
- Mask of `switcheroo-control.service`. Probably not installed; mask becomes
  inert.
- Mask of `nvidia-cdi-refresh.path` and `.service`. May or may not be
  installed depending on whether nvidia-container-toolkit is pulled in;
  re-evaluate post-migration.
- `82-aorus-egpu-nvidia-permissions.rules`. NVIDIA's compute-only install
  may already set restrictive perms; verify and remove if redundant.

**Migration plan (to be executed in a dedicated session):**

1. Cold-boot to known-good state, run `status.sh`, capture full output as a
   pre-migration snapshot in `archive/compute-only-migration-<date>/`.
2. `dnf system-upgrade` to Fedora 43 (~30-60 min, one reboot).
3. After reboot, validate iGPU is rendering GNOME and host is otherwise sane.
   The eGPU may not be bound at this point (RPMFusion akmod may not have
   rebuilt for the new kernel yet).
4. Remove RPMFusion's nvidia packages: `dnf remove akmod-nvidia kmod-nvidia
   xorg-x11-drv-nvidia*`. This will pull a lot of dependents; review.
5. Add NVIDIA's CUDA repo per docs. Verify with `dnf repolist`.
6. `nvidia-driver-assistant --install --module-flavor open` (start with open;
   later A/B with closed if the kernel-driver freeze persists).
7. Reboot. The new driver install owns kernel module loading; revisit the
   loader script's `modprobe --ignore-install nvidia` step - may need to
   adapt the modprobe.d install lines.
8. Run `status.sh`. Many checks should still pass; the ones in sections 8c
   (ICDs disabled) will now correctly report "not installed" as INFO.
9. Re-test ollama / harness. The kernel-level freeze (if it survives the
   migration) tells us the bug is independent of install path.
10. If freeze persists with `--module-flavor open`, retry with `--module-flavor
    closed`. This is the definitive open-vs-closed-RM A/B.
11. Update apply.sh / remove.sh / status.sh: drop the now-redundant
    Layer-2 hardening (ICD disable, the masks of compute-only-mode-not-needed
    services). Promote sections that catch real issues.
12. Update `docs/architecture.md` to reflect the compute-only-install
    foundation rather than the desktop-install + hand-hardening pattern.

**Rollback plan:**

Keep a Fedora 42 root snapshot via btrfs subvolume / LVM / dd before starting.
If the upgrade or NVIDIA-repo install breaks the host, boot into the snapshot.
RPMFusion install path is well-documented in our existing apply.sh.

**What this does NOT fix:**

The kernel-level freeze that hits when ollama runs sustained CUDA work is
a driver / GSP firmware / Blackwell-over-Thunderbolt bug, not an
install-path bug. Switching to compute-only mode won't make ollama work
where it currently freezes the host. What it DOES do:

- Removes incidental userspace exposure (the desktop-install ICDs / libs).
- Gives us a vendor-blessed config to point at when filing the NVIDIA bug.
- Lets us A/B test open vs closed RM cleanly.
- Reduces our maintenance surface significantly.

### Postscript: what we actually executed (2026-05-02 evening)

We ran the migration plan above. Outcomes:

1. F42 -> F43 system upgrade succeeded (1m 18s download, ~25 min apply).
   Lesson: `dnf system-upgrade` rebuilt the BLS bootloader entries from
   `/etc/kernel/cmdline` template, which had not been kept in sync with
   our grubby-applied args. **All boot args were lost on the upgrade.**
   Resolution: we re-applied via grubby and now also write
   `/etc/kernel/cmdline` to keep both in sync.

2. NVIDIA CUDA repo + `nvidia-driver-assistant --install --module-flavor
   open` was the wrong abstraction. **The assistant only knows the
   desktop meta-packages.** It installed `nvidia-open`, which pulls in
   the desktop superset (X drivers, Vulkan/EGL/OpenCL ICDs, libXNVCtrl,
   FBC, settings). We spent hours re-applying our Layer-2 hardening on
   top of that.

   **The correct command (per the NVIDIA Fedora install guide we
   discovered too late) is:**

   ```
   sudo dnf install nvidia-driver-cuda kmod-nvidia-open-dkms
   ```

   That is the documented compute-only-and-open-module install. It
   excludes the desktop layer entirely. The driver-assistant has no
   compute-only flag; it should not be used for our purpose.

   The `recommended-install-path.md` in this directory captures the
   correct sequence as a clean reference for future installs.

3. Several NVIDIA-CUDA-repo RPMs failed `%post` scriptlets due to
   missing `mkinitrd` (Fedora ships dracut, scriptlets assume mkinitrd).
   Recovery: we manually ran `dkms add/build/install` and reinstalled
   `nvidia-persistenced`. This is a packaging defect on NVIDIA's side,
   filing-quality.

4. `nvidia-persistenced` on the new install runs as a dedicated user
   (UID 967), unlike F42 RPMFusion which ran as root. Without group
   membership in our 0660-root:ollama'd /dev/nvidia0, it fails to start.
   apply.sh now adds nvidia-persistenced to the ollama group; status.sh
   now checks the membership.

5. `/usr/lib/modprobe.d/nvidia.conf` ships a `softdep nvidia post:
   nvidia-uvm nvidia-drm` that auto-loads nvidia-drm.ko, creating a
   /dev/dri/cardN that GNOME mutter picks up at login -> deterministic
   freeze. We shadow with `/etc/modprobe.d/nvidia.conf` to remove the
   softdep. The shadow also flips two NVreg defaults the vendor file
   set to compute-incompatible values.

6. **The freeze bug persists.** Driver 595.71.05 + F43 + open kernel
   module + all hardening still freezes within 30 seconds of ollama's
   discovery dance completing - no inference required, no further
   user actions. Same silent-hang fingerprint as on F42 + 580.142.
   Conclusion: the bug is in the driver / GSP firmware / hardware path,
   not in the userspace exposure we have been hardening against.

   We have eliminated everything userspace can eliminate. Further
   investigation moves to the open-gpu-kernel-modules GitHub repo
   (section 9 below) or to filing an upstream bug.

## 9. Review the open-gpu-kernel-modules GitHub repo (parked)

The NVIDIA open kernel modules are genuinely open source under MIT/GPLv2:
**https://github.com/NVIDIA/open-gpu-kernel-modules**

What's open vs closed:

- Open: kernel module sources (`nvidia.ko`, `nvidia-uvm.ko`,
  `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-peermem.ko`)
- Closed: userspace libraries (libcuda, libnvidia-ml, etc.) - binary
  blobs
- **Closed: GSP firmware** (`gsp_*.bin` files in
  `/usr/lib/firmware/nvidia/`) - runs on the GPU's onboard ARM core.
  On Blackwell, much of what historically lived in the kernel module
  was moved into firmware. The kernel module is largely an RPC stub
  for many operations, including possibly the close-path teardown that
  bites us. So even with the open kernel module source, the actual
  buggy logic may live in closed firmware that we cannot read.

### What to do with the repo

**Tier 1 - search the issue tracker.** Queries that map to our
symptoms:

- `"Xid 79"` (the GPU-fallen-off-bus we captured)
- `"GPU has fallen off the bus"`
- `Thunderbolt eGPU` (variants: `external GPU`, `egpu`)
- `Blackwell` + `freeze` / `hang` / `lost`
- `RTX 5090` + `freeze` / `hang`
- `GB202`
- `_issueRpcAndWait` + `failed`
- `kgspRcAndNotifyAllChannels`
- `ollama` + freeze (community reports)
- `compute-only` + Thunderbolt

If a similar issue exists, status / workaround / planned fix may already
be there.

**Tier 2 - file a new issue with our evidence.** What we have:

- Multiple silent-hang freezes with consistent fingerprint
- One captured Xid 79 with full RPC error chain
  (`/root/aorus-5090-egpu/archive/xid79-disconnect-2026-05-02/`)
- Reproduces on F42 + 580.142 RPMFusion
- Reproduces on F43 + 595.71.05 NVIDIA-CUDA-repo open kernel module
- All known peripheral mitigations applied (compute-only install,
  ICDs disabled, persistenced + UVM keep-alive, NVreg tuning)
- Hardware: NUC 15 Pro+ + AORUS RTX 5090 AI Box over Thunderbolt 4

A bug filed against this repo is the right escalation path: it goes
directly to the maintainers of the kernel module code.

**Tier 3 - browse the source.** Files of interest in
`kernel-open/nvidia/` and `kernel-open/nvidia-uvm/`:

- `file_operations` structs - `release` callbacks are where close-path
  teardown runs
- `_issueRpcAndWait` - shows up in our Xid 79 capture; find the
  surrounding context for what RPC was attempted
- `kgspRcAndNotifyAllChannels` - same
- Diff between the v580.142 and v595.71.05 tags - if the bug was
  patched between releases we should see the relevant change; if not,
  that is evidence the bug persists in 595

### Why parked

The current platform-repo work (refit for the documented compute-only
install path, and possibly the closed-RM A/B test) has clear next steps
and we have momentum on it. The GitHub investigation is open-ended and
could consume significant time without a guaranteed return. Park until:

- The current refit is complete (recommended-install-path.md captures
  the destination)
- We have made or explicitly declined the closed-RM A/B test (task #37)
- We are ready to either accept the bug as upstream-only-fixable or
  make a pivot decision (different hardware, different driver path)

When we resume: start with Tier 1 (search the issue tracker). If a
matching issue exists, no further action needed beyond following along.
If not, proceed to Tier 2 (file the bug) before Tier 3 (read source).
