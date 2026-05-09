# Performance investigation — Phase 7 design

> Companion to [`stability-roadmap.md`](./stability-roadmap.md). Captures
> the current measured perf baseline on the AORUS RTX 5090 over
> Thunderbolt 4 with the open NVIDIA module, the WSL2 reference (Lever G),
> the calibrated stack-level floor for kernel-side overhead, and the
> investigation plan for closing the gap to Windows feature parity.
>
> **Status:** initial baseline measured 2026-05-04 evening. Investigation
> work itemised; no optimisations yet applied.

---

## Project goal recap

Per [`feedback_project_scope_path_a`](../../.claude/projects/-root/memory/feedback_project_scope_path_a.md):
the AORUS eGPU project requires **full open-driver parity with the Windows
closed driver** in BOTH reliability AND performance. WSL2 is rejected as
the destination — the open module on native Linux must deliver comparable
inference throughput.

---

## Reference numbers — WSL2 (Lever G), same exact hardware

Source: `/root/llm-bench/wsl-fedora43-2026-05-03/results.md` (May 3 run).
Median of warm runs, `short_short` shape.

| Model | Decode tok/s | GPU util % | Peak W |
|---|---:|---:|---:|
| `llama3.2:1b`  | **533.5** | 18% | 168 |
| `llama3.1:8b`  | 219.4 | 46% | 320 |
| `qwen2.5:14b`  | 130.8 | 52% | 421 |
| `gpt-oss:20b`  | 232.5 | 43% | 267 |
| `gemma2:27b`   | 78.9  | 74% | 420 |

These are the bars to clear. They were measured on this exact silicon
running under Windows + closed `nvlddmkm.sys`. The hardware is provably
capable of these throughputs.

Pattern: smaller models show LOWER GPU util (coordination-bound),
larger models show HIGHER GPU util (compute-bound). The implication
for our investigation: small-model gaps reveal coordination overhead;
large-model gaps reveal raw compute / bandwidth ceilings.

---

## Native Linux baseline — measured 2026-05-04 evening

### Multi-model staged test (Step A)

13 successful iterations across 3 model sizes. Loop archives:
- `loop-2026-05-04-203729` — qwen2.5:0.5b × 5
- `loop-2026-05-04-204224` — llama3.2:1b × 5
- `loop-2026-05-04-204701` — llama3.1:8b × 3

| Model | Native median tok/s | WSL2 baseline | Ratio | ioctl_count median | ioctl_avg_us median |
|---|---:|---:|---:|---:|---:|
| qwen2.5:0.5b | **583.89** | (no WSL data) | n/a | 2290 | ~5825 |
| llama3.2:1b | **525.38** | 533.5 | **98%** | 2098 | ~5995 |
| llama3.1:8b | **229.47** | 219.4 | **105%** | 2302 | ~6700 |

**Native Linux open module is at WSL2 parity (98–105%) across these
three model sizes.** llama3.1:8b actually slightly beats WSL2 within
sample noise.

### Reliability across the 13 iterations

| Stage | Success | Freezes | FLRs needed |
|---|---|---|---|
| qwen2.5:0.5b × 5 | 5/5 | 0 | 0 |
| llama3.2:1b × 5 | 5/5 | 0 | 0 |
| llama3.1:8b × 3 | 3/3 | 0 | 0 |

100% success rate. Lever Q (Phase 1b) didn't need to fire — no failures
to catch. Earlier in the day on separate tests, when the bug DID fire,
Lever Q caught it correctly (Q-active marker in dmesg, host stayed
alive, GPU recoverable via remove+rescan+FLR).

### Calibration — `nvidia-smi -q` reference

To establish the per-ioctl floor for this stack independent of ollama:

| Metric | Value |
|---|---:|
| Total ioctls | 168 |
| Total kernel time | 1.34 s |
| **`ioctl_avg_us`** | **7964** (~8 ms) |

`nvidia-smi -q` is a lightweight introspective query — no GPU compute
involved. The 8 ms per ioctl is therefore **the floor for any ioctl
on this TB-tunneled GSP-RPC path**, not specific to ollama.

---

## Native Linux ↔ WSL2 gap — current understanding

**Headline: the gap is essentially closed at WSL2 parity (98–105%).**
This contradicts the earlier hypothesis that there was a ~1000× perf
gap. Below is what we now understand about WHY.

### Project goal: not parity — EXCEED WSL2

User position (2026-05-04): native Linux CAN exceed WSL2 because
WSL2 carries unavoidable virtualization overhead (Hyper-V mediation,
paravirtualized GPU bus, Windows scheduler indirection) that native
Linux structurally avoids. The 8b model already shows native at 105%
of WSL2; with optimization the project goal is systematic exceed
across the WSL2 reference ladder, not just match.

Architectural levers where native should structurally win:
- Lower per-ioctl latency (no hypercall layer)
- Lower cold-load latency (with optimized upload path)
- Better scheduler determinism for compute workloads
- Direct MMIO access (no paravirt translation)

Levers where WSL2 may have advantage we'd need to engineer parity:
- Mature closed-driver UMD-side optimizations
- Direct access to Windows page cache for model files
- Years of NVIDIA-tuned ioctl batching

### Per-ioctl latency is 6–8 ms (real, but pipelined)

Per-ioctl kernel-side latency is ~6–8 ms — fundamentally driven by
TB Gen1 x4 PCIe encapsulation latency × GSP RPC roundtrip.

For comparison, on native PCIe Gen5 x16 with the same architecture,
similar ioctls typically take 10–100 µs. **Our stack is 60–800× slower
per kernel↔driver↔GSP roundtrip in raw latency.**

### But pipelining hides it completely

Despite the 6 ms per-ioctl floor, our llama3.2:1b decode achieved
525 tok/s (98% of WSL2's 533) because async CUDA streams + multiple
ggml-cuda worker threads pipeline ioctls aggressively:

- ~2098 ioctls per inference (median, llama3.2:1b)
- × 6 ms each = ~12.6 s of cumulative kernel-side time
- But only ~0.07 s wall-clock for decode (38 tokens at 525 tok/s)
- → ~180× effective parallelism

This is enough parallelism to fully amortize the per-ioctl latency.
WSL2 (Windows closed driver) presumably has lower per-ioctl latency
but doesn't NEED less because we already match throughput.

### What it looked like was wrong, and the corrected picture

Earlier in the evening (post lite-181844), I claimed a ~1000× perf
gap based on:
- Test wall-clock = ~38 seconds (correct, but includes model load)
- Output = ~20 tokens (correct)
- Math: 20 / 38 = 0.5 tok/s (WRONG — this is end-to-end including 4-5s
  cold model load)

The CORRECT measurement comes from ollama's API metrics:
- `eval_duration` = decode wall-clock (excludes load)
- `eval_count` = output tokens
- decode tok/s = `eval_count` / (`eval_duration` / 1e9)

When measured this way, decode runs at **WSL2-comparable speeds**.
The 1000× claim was a measurement error.

### Where a gap COULD still exist (not yet measured)

The staged test covered 0.5b → 1b → 8b. Pipelining works because async
streams have headroom. But for workloads with less headroom:

- **Larger models** (14b, 20b, 27b) — more compute per launch, may
  shrink amortization advantage. WSL2 saw lower decode tok/s on
  larger models (gemma2:27b → 79 tok/s); we don't yet know what
  native does.
- **Pre-decode init paths** — sequential, not pipelined. cuInit,
  cuMemAlloc, model upload to GPU. This is also where our reliability
  bug fires. Wall-clock model load was 9-19 seconds for llama3.2:1b
  vs WSL2's 81 ms. Significant load-time gap remains.
- **Sync-heavy workloads** — single-token streaming with sync
  after every token, small batch sizes.

Pre-decode latency is the most actionable remaining perf gap.
**Cold-load times of 9-19 s are 100× WSL2's 81 ms** — this is real
and worth investigating. (See updated KPI targets below.)

---

## Headline KPIs for Phase 7

These are the numbers we track per iteration. Master.csv captures
all of them automatically.

### Decode throughput — AT PARITY (largely done)

| KPI | Source | Current native | WSL2 baseline | Status |
|---|---|---:|---:|---|
| `decode_tok_s` (qwen2.5:0.5b) | inference.json | **583** | (no data) | ✅ healthy |
| `decode_tok_s` (llama3.2:1b) | inference.json | **525** | 533 | ✅ **98% parity** |
| `decode_tok_s` (llama3.1:8b) | inference.json | **229** | 219 | ✅ **105% parity** |
| `decode_tok_s` (qwen2.5:14b) | inference.json | TBD | 130 | future |
| `decode_tok_s` (gpt-oss:20b) | inference.json | TBD | 232 | future |
| `decode_tok_s` (gemma2:27b) | inference.json | TBD | 79 | future |

### Cold-load — significant gap remains

| KPI | Source | Current native | WSL2 baseline | Target | Stretch |
|---|---|---:|---:|---:|---:|
| `load_duration_ms` (qwen2.5:0.5b) | inference.json | 4500-12500 | (no data) | <2000 | <500 |
| `load_duration_ms` (llama3.2:1b) | inference.json | 10000-14500 | **81** | <500 | <200 |
| `load_duration_ms` (llama3.1:8b) | inference.json | 11500-19700 | **74** | <500 | <200 |

**Pre-decode model load is 100-200× WSL2 baseline.** This is the actionable
performance gap. Almost all of it is the time to upload model tensors
from CPU to GPU (sequential `cuMemcpyHtoD` calls, each costing the full
~6 ms ioctl latency × no parallelism opportunity since model upload is
inherently dependency-chained).

### Kernel-side metrics — calibrated

| KPI | Source | Median measured | Comment |
|---|---|---:|---|
| `kprobe_ioctl_avg_us` | kprobes | **5825-7000** | Stack-level floor; cannot beat without hardware/firmware change |
| `kprobe_ioctl_count` per token (1b model) | derived | ~55 | Reducing this would scale decode further (currently not bottleneck) |
| `kprobe_ioctl_count` per inference (1b model) | kprobes | ~2098 | Total kernel↔driver crossings |

The actionable lever for cold-load: **batch model upload calls**. If a
single ioctl could carry many MB of model weights instead of one, the
~6 ms latency would amortize across many bytes. WSL2's ~80 ms model
load implies they upload at ~50 GB/s or use a fundamentally different
path (DMA from page cache directly?).

---

## Investigation plan — Phase 7 (revised after parity discovery + exceed-WSL2 pivot)

The original plan assumed a large decode-throughput gap to close.
With parity confirmed at 1b and 8b, **and the project goal updated
to exceed WSL2 (not just match it)**, the work is reorganised
around a single thesis:

> **Native + open-source-driver gives us optimisation surfaces that
> Windows + closed driver structurally cannot reach. Catalogue them,
> exploit them, exceed WSL2.**

For each lever below, **layer assignment** points at the sovereign
module home per [`architecture-and-modularity.md`](./architecture-and-modularity.md).
Most of this work is at L4-L6 (userspace helper, config, inference
engine), explicitly NOT in the NVIDIA fork.

### Phase 7-validate — Steady-state and larger-model measurement

> Prerequisite to all optimisation work. Closes the "we don't yet have
> a true apples-to-apples WSL2 comparison" gap created by the test
> wrapper's `pkill ollama_llama_server` between iterations forcing
> repeat cold-loads.

| Step | Action | Layer |
|---|---|---|
| A | Add `KEEP_RUNNER=1` mode to `loop-with-flr.sh` (skip the inter-iter pkill); run llama3.2:1b ×5 with runner persisted; iters 2-N report `load_duration_ms ≈ 0` | L6 (test harness) |
| B | Compare native-warm decode vs WSL2 — definitive parity number, sample-noise quantified | n/a (analysis) |
| C | Extend native baseline to qwen2.5:14b, gpt-oss:20b, gemma2:27b | n/a (test runs) |
| D | True cold-load measurement: fresh ollama server + first request, vs WSL2's "cold" 81 ms (hypothesis: WSL2's 81 ms is actually warm; we may be closer than the table currently shows) | n/a |

Completion of 7-validate refreshes every row of the headline KPI table
above with confidence intervals.

### Phase 7-native — Exploit Linux-only optimisation surfaces

These are the levers Windows closed driver fundamentally cannot match.
Each is mapped to its sovereign home; **none should add to the L1
NVIDIA fork** unless explicitly noted.

#### 7-native-A — PCIe / Thunderbolt link tuning

> **Layer:** L4 (shell helpers) + L5 (udev / systemd config).
> **Justification for layer:** all interventions are sysfs writes or
> `setpci` invocations on standard PCIe config space. No driver
> modification needed. Windows largely treats TB as opaque; Linux gives
> us full PCIe config-space access and we can tune specifically for
> our chassis.

Audit + tune (one-shot, runs after `aorus-egpu-compute-load-nvidia.service`):

1. **MaxPayloadSize / MaxReadRequestSize** on every device on the eGPU
   path (TB controller, bridge, GPU). Defaults often 128B; negotiate
   to 256B/512B if all devices support it.
2. **ASPM L0s/L1**: force `policy=performance` per device on hot path.
   Power-state transitions add latency that decoded workloads don't
   benefit from.
3. **PCIe completion timeout**: per-device sysfs tuning. Currently
   50 µs - 50 ms range; investigate whether tightening helps
   best-case latency without breaking edge cases.
4. **LTR (Latency Tolerance Reporting)**: tell the controller our
   workload latency requirements. Influences host-side arbitration.
5. **TB link mode**: ensure best-mode TB4 negotiated, no fallback to
   Gen3 on partial degradation.

**Implementation:** new helper `aorus-egpu-pcie-tune` (L4); systemd
service `aorus-egpu-pcie-tune.service` (L5) ordered after the bind
service.

**Estimated effort:** 1 day investigation + helper, 1 test cycle.

#### 7-native-B — CUDA Graphs verification + enablement

> **Layer:** L6 (inference engine / ollama / ggml-cuda).
> **Justification:** entirely above libcuda. ggml-cuda decides whether
> to capture+replay command buffers as graphs.

1. **bpftrace uprobes** on `cuGraphCreate` / `cuGraphLaunch` during a
   real inference — confirm whether graphs are in active use.
2. If not: investigate ggml flags (`GGML_CUDA_USE_GRAPHS=1`,
   compile-time defines), confirm ollama's build has graph support.
3. If in use but reduced count vs Windows: investigate ggml-cuda's
   graph capture decision logic for the per-token forward pass.

**Estimated effort:** 1 day investigation, 1 day fix if needed.

#### 7-native-C — Cold-load: async upload pipelining

> **Layer:** L6 primarily; L1 only as fallback if L6 won't reach goal.
> **Justification:** model upload to GPU is `cuMemcpyHtoD` calls in the
> ggml-cuda loader. Multiple streams + overlap is a workload-level
> concern.

1. **Profile current upload** — `bpftrace -e 'uprobe:libcuda.so:cuMemcpyHtoD*'`
   during `ollama run` first request. Are calls already async / multi-stream?
2. **If sequential**: patch ggml's CUDA model-loader to use multiple
   streams with overlapping `cuMemcpyHtoDAsync`. Even on this stack
   with 6-8 ms per ioctl, parallelism could collapse 12 s of sequential
   uploads to 1-2 s.
3. **Stretch — DMA descriptor coalescing in the open module (L1)**: if
   L6-only effort can't close the gap, fork-side change to coalesce N
   sequential `cuMemcpyHtoD` requests into one multi-descriptor DMA. Very
   high fork debt; defer unless L6 won't reach.

**Estimated effort:** 2-3 days for L6 path; multi-week if L1 stretch needed.

#### 7-native-D — GPUDirect Storage feasibility

> **Layer:** L6 + L7 (consume `nvidia-fs` ecosystem).
> **Justification:** Linux-only NVIDIA feature. File → GPU memory direct,
> bypassing CPU page cache. Closed-driver Windows can't match.

1. **Survey `nvidia-fs` / GDS support**: package availability on Fedora 43,
   filesystem requirements (XFS/ext4 with O_DIRECT path), kernel module
   compatibility with our patched 595.71.05.
2. **Prototype**: write a minimal `cuFileRead`-based model loader,
   measure cold-load vs current path.
3. **Integrate into ggml-cuda** if feasible — would make GDS the default
   model upload path.

**Estimated effort:** 1 week feasibility, 2-3 weeks if integrating into ggml.

#### 7-native-E — System-level tuning for inference workload

> **Layer:** L5 (config) + L6 (ollama-side).
> **Justification:** pure userspace knobs Linux exposes that Windows either
> doesn't or doesn't apply by default for inference workloads.

1. **Hugepages**: 1 GB hugepages reserved at boot (`default_hugepagesz=1G`),
   used as backing for ggml's tensor allocations. Reduces TLB pressure
   on the model file's RAM-side residency.
2. **Transparent hugepages = always for ollama cgroup**.
3. **CPU governor = performance + EPB lowest** during inference.
4. **SCHED_FIFO / `Nice=-20`** for ollama threads via systemd unit slice.
5. **IRQ affinity**: pin nvidia IRQ to a dedicated P-core.
6. **`madvise(MADV_WILLNEED)` + read-ahead** on the model file before
   first inference (ollama-side).
7. **`io_uring`** for model file reads to keep upload pipeline saturated.

Each of these is small, reversible, and additive. Most are pure config
(L5); a few need ollama-side changes (L6).

**Estimated effort:** 1-2 days for the L5 config bundle, 1 week for the
L6 io_uring/madvise integration.

#### 7-native-F (research) — Custom batched-submit ioctl

> **Layer:** L1 + L6 (last resort).
> **Justification:** if 7-native-A through E exhaust easy gains and we
> still want to push past WSL2 for sync-heavy workloads, the next
> structural lever is reducing kernel boundary crossings.

Concept: add a new ioctl to the open module that takes N command
submissions in one entry, processes in a single kernel-side batch.
ggml-cuda would use it via a new entrypoint. **Very high fork debt;
fundamentally a research project, not a near-term lever.** Document for
completeness; revisit only after the easier work is done.

### Phase 7-windows-specific (deprio'd)

The original Phase 7c/d/e centred on "match Windows behaviour." With
parity confirmed at decode and the goal updated to exceed WSL2, this
becomes a low-priority cross-check rather than a workstream:

- WSL2 ETW / WPR traces (if accessible) for verification of where their
  per-launch overhead actually lies.
- Comparing kernel-launch counts on identical workloads.

Useful for sanity-checking our optimisations, not for driving them.

---

## Tools available (already built)

- **`/root/ollama/tools/loop-with-flr.sh`** — orchestration harness;
  captures perf KPIs in `master.csv` per iter
- **`/root/ollama/tools/perf-kprobes.bt`** — 4-kprobe measurement of
  `nvidia_unlocked_ioctl` count + duration; minimal overhead, kept
  always-on
- **`/root/ollama/tools/cuda-trace.bt`** — 54-uprobe userspace CUDA
  call trace; HIGH overhead, opt-in only via `ENABLE_BPFTRACE=1`
- **`/root/llm-bench/bench.py`** — proper benchmarking harness used
  for the WSL2 reference. Could be used directly on native Linux
  for one-to-one comparison

## Recommended sequence

1. Run llama3.2:1b iter (~45 s) → first WSL2-comparable data point
2. Run llama3.1:8b iter (~75 s) → medium-model data
3. Examine `ioctl_count` / token across models
4. Decide on 7b CUDA Graphs investigation based on the slope

Each iter produces structured master.csv data. After 3-5 iters per
model size, we have enough data to update the headline KPI table and
identify the lowest-hanging fruit.

---

## Cross-references

- [`stability-roadmap.md`](./stability-roadmap.md) — overall project
  roadmap. Phase 7 a/b/c are also tracked there.
- [`recovery-mechanism-findings.md`](./recovery-mechanism-findings.md) —
  FLR works as recovery mechanism (Phase 4 simplified).
- [`lever-Q-design.md`](./lever-Q-design.md) — reliability mechanism
  (Phase 1b delivered).
- `/root/llm-bench/wsl-fedora43-2026-05-03/` — WSL2 reference run
  artifacts and harness.

## Update log

- **2026-05-04 evening** — initial publication. Captures baseline data
  from `loop-2026-05-04-201826` and `nvidia-smi -q` calibration.
- **2026-05-04 night** — staged Step A across 3 model sizes confirmed
  WSL2 parity for decode throughput (98% on 1b, 105% on 8b). Cold-load
  gap identified as the major remaining performance issue (100-200× vs
  WSL2). Earlier "1000× perf gap" claim corrected to a measurement
  error. Reliability also clean: 13/13 successful inferences.
- **2026-05-04 night (later)** — Project goal updated from "match
  WSL2" to "exceed WSL2 by exploiting Linux + open-source-driver
  optimisation surfaces Windows structurally cannot match."
  Investigation plan reorganised around 7-validate (steady-state
  measurement) + 7-native (the native-advantage levers, A through F).
  Each lever assigned to its sovereign module home per
  [`architecture-and-modularity.md`](./architecture-and-modularity.md);
  the explicit goal is to keep new optimisation work *out of* the
  L1 NVIDIA fork wherever possible. UMD primer added as appendix.
- TBD — 7-validate steady-state measurement (warm decode without
  inter-iter pkill) + larger-model coverage (14b, 20b, 27b)
- TBD — 7-native-A PCIe/TB tuning audit and helper

---

## Appendix A — UMD vs KMD: where the optimisation surface actually lives

NVIDIA's driver stack is split into two halves on every platform:

```
┌────────────────────────────────────────────────────┐
│  Application (ollama / llama.cpp / pytorch)        │
├────────────────────────────────────────────────────┤
│  UMD — User-Mode Driver                             │  libcuda.so / nvcuda.dll
│  • command buffer assembly                          │  (closed, NVIDIA-shipped)
│  • state tracking, parameter validation             │
│  • stream/event ordering                            │
│  • batches before kernel boundary                   │
├────────────────────────────────────────────────────┤
│  ─── kernel boundary (~6-8 µs even fast; ~6-8 ms   │
│      on this TB+GSP stack) ──────────────────────  │
├────────────────────────────────────────────────────┤
│  KMD — Kernel-Mode Driver                           │  nvidia.ko / nvlddmkm.sys
│  • hardware ownership (MMIO, DMA, IRQ)              │  (Linux KMD is what we
│  • GSP firmware RPC                                 │   forked; Windows KMD is
│  • context/channel allocation                       │   closed)                
└────────────────────────────────────────────────────┘
```

### Why the split exists

Kernel boundary crossings are expensive. UMD does as much as possible
without crossing — directly writes to GPU command buffers via mmap'd
memory, only entering the kernel when genuinely required (allocations,
channel creation, sync primitives). Most of CUDA's "API call" cost is
UMD work; the kernel boundary is hit relatively rarely in well-pipelined
code.

This is why throughput is similar across Windows/Linux despite different
KMDs — UMD does the heavy lifting, and **NVIDIA ships the same UMD
architecture across both platforms.**

### What "open driver" gives us — and what it doesn't

The "NVIDIA open kernel module" project open-sourced the **KMD** only.
The **UMD** (`libcuda.so` on Linux, `nvcuda.dll` on Windows) remains
closed-source on both platforms. So when we discuss "what we control":

| Component | Linux native + open KMD | Windows + closed driver |
|---|---|---|
| KMD | **open (we can patch)** | closed |
| UMD (libcuda) | closed | closed |
| Kernel itself | **open (full control)** | closed |
| User-mode tooling above libcuda (ollama, ggml-cuda, llama.cpp) | **open (we can patch)** | open (but not their default ecosystem) |
| Host-system tunables (PCIe, scheduler, IRQ, hugepages) | **fully exposed** | partially exposed |

### Where this lands for the project

**We cannot directly optimise libcuda.** Closed source on both platforms.
We CAN optimise:

1. **The KMD** (L1 NVIDIA fork) — high cost, only justified for hot-path
   driver-internal work. See `architecture-and-modularity.md`.
2. **Above libcuda** (L6 ggml/ollama/llama.cpp) — most of the CUDA-
   side perf work belongs here.
3. **Below libcuda's expectations** (L4-L5 host-system config) — PCIe,
   scheduler, hugepages, IRQ. Linux gives us full control; Windows
   exposes a smaller subset; WSL2 inherits Windows defaults.

The native-advantage thesis: even with a closed UMD shared with Windows,
optimising L4-L6 in ways Windows fundamentally cannot is the path to
exceeding WSL2.

### What WSL2 carries that native doesn't

WSL2 inserts extra layers between application and hardware:

```
WSL2 path:  process → libcuda (in WSL Linux) → /dev/nvidia (in WSL kernel)
            → Hyper-V hypercall → Windows kernel → nvlddmkm.sys (Windows
            KMD) → MMIO/GSP → hardware

Native:     process → libcuda → /dev/nvidia (host kernel) → nvidia.ko
            (Linux KMD, our patched version) → MMIO/GSP → hardware
```

Hyper-V mediation, paravirtualised GPU bus translation, and Windows
scheduler indirection are unavoidable in WSL2. Native eliminates them
entirely — the structural argument for native > WSL2 even before any
optimisation work. The 8b data point (105% of WSL2) is consistent with
this.
