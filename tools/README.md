# Diagnostic / validation toolkit

These scripts are NOT installed by `apply.sh`. They are templates for manual diagnostic and validation work, kept in the repo so they survive context resets and can be reused for future testing (PyTorch validation, vLLM bring-up, kernel updates, etc).

## `cuda-driver-api-smoke-test.py`

A pure-`ctypes` CUDA Driver API smoke test. Runs the full driver-API roundtrip:

```
cuInit -> cuDeviceGet -> cuCtxCreate -> cuMemAlloc(4 KiB) ->
cuMemsetD8(0x5A) -> cuCtxSynchronize -> cuMemcpyDtoH -> verify ->
cuMemFree -> cuCtxDestroy
```

Exits 0 with `cuda_smoke=pass` on success, non-zero with the failed call name on any error.

No dependencies beyond `libcuda.so.1` (which ships with `xorg-x11-drv-nvidia-cuda-libs`). No CUDA toolkit, no PyTorch, no nvcc required.

Run directly:

```bash
python3 tools/cuda-driver-api-smoke-test.py
```

WARNING: do NOT run this directly without first verifying `nvidia_uvm` is loaded (`lsmod | grep nvidia_uvm`). A failed `cuInit` on this stack — caused by `nvidia_uvm` not being loadable — leaves the GPU in a partially-initialised state that has caused delayed kernel panics. The compute-load loader pre-stages `nvidia_uvm` at boot, but if you have manually unloaded it or are diagnosing, the precondition matters.

## `tty-cuda-test.sh`

Runs the smoke test in a controlled multi-user.target context with fsync'd progress markers. Use for any freeze-risk diagnostic where you want forensic data even if the kernel panics.

What it does:

1. Pre-flight: refuses to start if `nvidia_uvm` is not loaded or `nvidia-persistenced.service` is not active.
2. Captures pre-test state.
3. Runs `cuda-driver-api-smoke-test.py` with a 30 s timeout.
4. Captures post-test state, including a `nvidia-smi --query-gpu=memory.used` to detect leaks.
5. Idles 30 s to catch delayed panics while still in multi-user.target.
6. EXIT trap restores `graphical.target` no matter how the script ended.

Output: `/root/aorus-cuda-tty-test/` — overwritten each run.

To launch (drops you to a TTY for ~60-90 seconds, then GNOME returns):

```bash
nohup setsid /root/aorus-5090-gpu/tools/tty-cuda-test.sh </dev/null >/dev/null 2>&1 &
disown
sleep 1
sudo systemctl isolate multi-user.target
```

The `nohup setsid ... &` + `disown` detaches the script from the calling shell so it survives the session disconnection caused by `isolate`. The script's EXIT trap returns the system to graphical when done.

If anything hangs, switch to `Ctrl+Alt+F2`, login, and run `sudo systemctl isolate graphical.target` to recover manually.

## Future tools

This directory is the right place for:

- A PyTorch tensor-op smoke test (next step toward vLLM)
- A vLLM warmup test
- An `NVreg_DynamicPowerManagement=0` experiment (see `docs/future-investigations.md`)
- A kernel/driver-update validation runner

Each tool should follow the same pattern as `tty-cuda-test.sh`:
- Refuse to start if preconditions are not met.
- fsync progress markers.
- Capture pre- and post-test state.
- EXIT trap to restore `graphical.target` if launched from there.
