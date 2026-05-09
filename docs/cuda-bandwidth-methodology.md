# CUDA PCIe Bandwidth Testing Methodology

How to measure end-to-end host↔GPU PCIe bandwidth on this hardware,
how to interpret results, when to re-run, and how to detect regressions.

This is the canonical "how to settle bandwidth questions" doc. When in
doubt about whether the link is performing as expected, run the test
described here.

## Why this doc exists

The OS-reported PCIe link state (lspci `LnkCap`, kernel "available bandwidth"
messages) is heavily virtualized for TB-tunneled devices and does NOT
reflect actual throughput. See `docs/tb4-pcie-topology.md` for the
mechanism. Real bandwidth must be MEASURED, not inferred.

## Tool: NVIDIA nvbandwidth

`nvbandwidth` is NVIDIA's official PCIe bandwidth measurement tool,
the maintained successor to the deprecated `bandwidthTest`
(removed from cuda-samples in CUDA 12.x).

Repo: https://github.com/NVIDIA/nvbandwidth

It uses `cuMemcpyAsync` via copy engines (the actual DMA path that
real CUDA workloads use), pinned host memory by default, runs multiple
iterations with proper warmup and synchronization, reports stable
GB/s figures.

## Build (one-time, ~5 min)

Prerequisites:
- CUDA toolkit minimal-build (compiler + cudart)
- nvml header
- cmake ≥3.20 + boost program-options

```bash
# Install build deps (Fedora 43 with NVIDIA CUDA repo already configured)
sudo dnf install -y \
    cuda-minimal-build-13-2 \
    cuda-nvml-devel-13-2 \
    cmake \
    boost-devel

# Clone + build nvbandwidth
cd /root
git clone --depth 1 https://github.com/NVIDIA/nvbandwidth.git
cd nvbandwidth
mkdir -p build && cd build
PATH=/usr/local/cuda/bin:$PATH cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Confirm binary
ls -lh ./nvbandwidth
```

Build artifact: `/root/nvbandwidth/build/nvbandwidth` (~10 MB).

## Run procedure

Each invocation opens `/dev/nvidia0` and exercises the GPU. Expect:
- Per memory `feedback_avoid_nvidia_smi_for_state_checks`: each invocation
  costs ONE close-path wedge recovery cycle (~17s) when GPU is idle.
  M-recover handles transparently. Wait ~20s between back-to-back runs
  to let the cycle settle, OR run with active workload (no wedge fires
  during sustained CUDA usage).
- nvbandwidth itself takes ~5-10 seconds per test.

```bash
cd /root/nvbandwidth/build

# THE three measurements that matter
./nvbandwidth -t 0    # host_to_device_memcpy_ce  (H2D — model loading)
./nvbandwidth -t 1    # device_to_host_memcpy_ce  (D2H — readback)
./nvbandwidth -t 2    # host_to_device_bidirectional_memcpy_ce

# List all test cases
./nvbandwidth -l

# Detailed all-in-one run (longer, for full characterization)
./nvbandwidth                  # runs default test set
./nvbandwidth --json           # JSON output for parsing/archival
```

For a quick sanity check on the link, **`-t 0` alone is sufficient**.
For full characterization (e.g., post-cap-change validation), run all
three tests.

## Expected results on this hardware

Validated 2026-05-07, port B, Gen3+bit5 cap (LnkCtl2=0x0063 on bridge
2d:00.0), M-recover scaffold + passive watchdog, no other workload:

| Test | Measured | Range (typical) | % of TB4 spec ceiling (32 Gbps) |
|---|---|---|---|
| H2D (`-t 0`) | **2.80 GB/s** | 2.7-2.9 GB/s | 70% |
| D2H (`-t 1`) | **3.29 GB/s** | 3.2-3.4 GB/s | 82% |
| Bidirectional H2D (`-t 2`) | **2.47 GB/s** | 2.4-2.6 GB/s | 62% |

**Interpretation guide:**

| Observed H2D | Likely state |
|---|---|
| 2.7-2.9 GB/s | ✅ Normal — TB4-saturated, hardware behaving correctly |
| 1.8-2.6 GB/s | ⚠️ Degraded — partial bandwidth issue, investigate |
| 0.8-1.2 GB/s | ❌ Real Gen1 limit (would mean TB tunnel actually downgraded) |
| <0.8 GB/s | ❌ Severely degraded — link issue, regression, or hardware fault |

**A measurement materially above 2.9 GB/s is also a flag** — it would
suggest TB5 tunnel mode engaged unexpectedly (possible only with TB5
host hardware, which we don't have on NUC 15 Pro+).

## Baseline log

Append new measurements to this section when re-running for regression
detection. Format: `YYYY-MM-DD HH:MM | port | cap config | H2D | D2H | bidir | notes`.

```
2026-05-07 21:?? | port B | Gen3+bit5 (LnkCtl2=0x0063 on 2d:00.0) | 2.80 | 3.29 | 2.47 | first measurement; H18 falsified; TB4-saturated
```

(Add new lines below as runs accumulate.)

## When to re-run

Run the H2D test (`-t 0`) when:
1. **After any cap config change** (Lever U updates, port swap, BDF change)
2. **After kernel/driver upgrade** (sanity check that nothing regressed)
3. **After firmware updates** (TB controller, AORUS box NVM)
4. **If cold-load TTFT changes unexpectedly** (rule out PCIe regression
   vs. filesystem/parsing changes)
5. **Before vs after any thunderbolt module parameter experiment** to
   measure actual impact (since lspci reports won't change meaningfully)

Skip re-running when:
- No relevant config changed (PCIe state hasn't changed, so nothing to test)
- During active heavy workload (would add measurement noise)

## What this doesn't measure

- **Cold-load time end-to-end** — that's PCIe + filesystem read + parse
  + GPU kernel launch overhead. nvbandwidth measures only the PCIe
  transfer portion. Use ollama timing for cold-load; use nvbandwidth
  for PCIe isolation.
- **Steady-state inference perf** — most ops happen in VRAM, not over
  PCIe. nvbandwidth is not predictive of inference tok/s.
- **Latency** — nvbandwidth reports throughput, not transfer-initiation
  latency. For latency-bound workloads, different tools needed.
- **Per-buffer-size scaling** — nvbandwidth defaults are reasonable;
  for buffer-size sensitivity studies, use `--bufferSize` or the
  range mode.

## Cross-platform comparison

To compare with Windows: NVIDIA `bandwidthTest.exe` (legacy, still
shipped with Windows CUDA toolkit) reports compatible numbers. Also
HWinfo64 has live bandwidth sensors but those are coarse. For
apples-to-apples Linux↔Windows, use nvbandwidth on both (it builds
on Windows too with VS + cmake, same source tree).

## Common mistakes to avoid

1. **Treating lspci `LnkCap` or kernel "available bandwidth" message
   as a measurement.** They're virtualized register reads. Always
   measure with nvbandwidth.

2. **Forgetting pinned memory.** A self-rolled benchmark with
   `cudaMemcpy` on pageable memory will measure ~1 GB/s and falsely
   conclude Gen1. nvbandwidth uses pinned by default.

3. **Single-run noise.** Bandwidth varies ~5% run-to-run from CPU
   caching, IRQ activity, etc. For decision-making, run 3 times and
   take median, OR use `--testIterations 50` for averaged result.

4. **Running during active GPU workload.** Other CUDA contexts compete
   for copy engines. Run on a quiet GPU.

5. **Running with nvidia-persistenced thrashing the GPU.** If
   persistenced is bouncing /dev/nvidia0, nvbandwidth will see
   measurement variance. Per task #109, persistenced is currently
   disabled (BDF condition mismatch on port B); this is fine for
   measurement, just be aware.

## See also

- `docs/tb4-pcie-topology.md` — full topology diagram + measurement
  results in context
- `docs/tb4-tunnel-gen1-investigation.md` — H18 investigation with
  this measurement as the falsifying evidence
- Memory `feedback_lspci_lnkcap_tb_virtual` — quick-reference rule
- Memory `feedback_avoid_nvidia_smi_for_state_checks` — about
  close-path wedge cost of opening /dev/nvidia0
