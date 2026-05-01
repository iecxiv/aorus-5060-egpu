# Future investigations

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
   sudo /usr/local/sbin/aorus-5090-compute-load-nvidia
   # The loader does not currently expose this env var; either:
   #   a) edit the loader to accept AORUS_5090_DISABLE_DYNAMIC_PM=1
   #      and pass NVreg_DynamicPowerManagement=0 to modprobe; or
   #   b) bind once with the script, immediately unload, then manually
   #      modprobe nvidia NVreg_DynamicPowerManagement=0
   ```

5. Without persistenced running, run `nvidia-smi` twice in succession.
6. If both succeed: the parameter is the fix. Persist by adding the option to `/etc/modprobe.d/aorus-5090-compute-only.conf` (alongside the existing options). The compute-load loader can then drop persistenced from the requirement chain.
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

If an NVIDIA DRM card appears, GNOME may still freeze on login. Re-check that `aorus-5090-compute-only.conf` is in place and effective.

## 5. CUDA workload close-path stress

We have validated `nvidia-smi` (NVML) repeatability AND a one-shot CUDA Driver API smoke (`archive/cuda-validation-2026-05-01/`), but not long-running CUDA workloads. A real vLLM or PyTorch run that hot-loads / unloads models may exercise a different close path. If you observe freezes during normal CUDA use, capture an ioctl trace of the workload using `archive/diagnostic-tests/aorus-5090-nvml-ioctl-trace.so` to identify the close boundary.

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
